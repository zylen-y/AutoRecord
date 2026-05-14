import Foundation
import AutoRecordShared
import AVFoundation
import AppKit
import Combine

enum AudioQuality: Int, CaseIterable, Identifiable, Codable {
    case low, medium, high
    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .low: return "Low (smaller files)"
        case .medium: return "Medium (recommended)"
        case .high: return "High (larger files)"
        }
    }
    var avQuality: AVAudioQuality {
        switch self {
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        }
    }
}

enum MuxError: Error {
    case exportFailed(String?)
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var currentSchedule: Schedule?
    @Published private(set) var currentFileURL: URL?   // final output destination
    @Published private(set) var startedAt: Date?

    private var avRecorder: AVAudioRecorder?
    private var micTempURL: URL?
    private let systemRecorder = SystemAudioRecorder()

    var outputDirectory: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "outputDirectory"),
               !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return AppPaths.defaultRecordingsDirectory
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: "outputDirectory")
        }
    }

    var audioQuality: AudioQuality {
        get {
            let raw = UserDefaults.standard.integer(forKey: "audioQuality")
            return AudioQuality(rawValue: raw) ?? .medium
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "audioQuality")
        }
    }

    func startRecording(for schedule: Schedule) async {
        if PermissionService.micStatus == .notDetermined {
            _ = await PermissionService.requestMicAccess()
        }
        guard PermissionService.micStatus == .authorized else {
            PermissionService.showMicDeniedAlert()
            return
        }

        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let tempMic = makeMicTempURL()
        let finalURL = makeFinalOutputURL(for: schedule)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: audioQuality.avQuality.rawValue
        ]

        do {
            let r = try AVAudioRecorder(url: tempMic, settings: settings)
            r.delegate = self
            r.prepareToRecord()
            guard r.record() else {
                NSLog("AudioRecorder: record() returned false")
                return
            }
            avRecorder = r
            micTempURL = tempMic
            currentSchedule = schedule
            currentFileURL = finalURL
            startedAt = Date()
            isRecording = true
        } catch {
            NSLog("AudioRecorder: failed to start mic: \(error)")
            showSimpleAlert(title: "Recording failed to start", message: error.localizedDescription)
            return
        }

        // Start system audio capture; fall back gracefully if not authorised.
        if PermissionService.screenRecordingAuthorized {
            do {
                try await systemRecorder.start()
            } catch {
                NSLog("AudioRecorder: system audio capture failed to start: \(error)")
            }
        } else {
            PermissionService.requestScreenRecordingAccess()
        }
    }

    /// Called at the scheduled end time — pauses mic, shows decision alert, then acts.
    func stopAndPrompt() {
        guard let r = avRecorder, let schedule = currentSchedule, let finalURL = currentFileURL else { return }
        r.pause()

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Meeting ended: \(schedule.title)"
        alert.informativeText = "The scheduled end time has been reached. Save the recording, discard it, or keep recording?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Continue Recording")
        alert.addButton(withTitle: "Discard")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            commitStop(finalURL: finalURL)
        case .alertThirdButtonReturn:
            commitDiscard()
        default: // Continue
            _ = r.record()
        }
    }

    /// Manual stop from the popover — saves without a decision prompt.
    func stopAndSaveNow() {
        guard let finalURL = currentFileURL else { return }
        commitStop(finalURL: finalURL)
    }

    // MARK: - Private

    private func commitStop(finalURL: URL) {
        avRecorder?.stop()
        avRecorder = nil
        isRecording = false
        currentSchedule = nil
        startedAt = nil
        currentFileURL = nil

        let micURL = micTempURL
        micTempURL = nil

        Task {
            await self.systemRecorder.stop()
            let sysURL = self.systemRecorder.tempFileURL
            await self.finalizeSave(micURL: micURL, sysURL: sysURL, finalURL: finalURL)
        }
    }

    private func commitDiscard() {
        avRecorder?.stop()
        avRecorder = nil
        isRecording = false
        currentSchedule = nil
        startedAt = nil
        currentFileURL = nil

        let micURL = micTempURL
        micTempURL = nil

        Task {
            await self.systemRecorder.stop()
            let sysURL = self.systemRecorder.tempFileURL
            if let micURL { try? FileManager.default.removeItem(at: micURL) }
            if let sysURL { try? FileManager.default.removeItem(at: sysURL) }
        }
    }

    private func finalizeSave(micURL: URL?, sysURL: URL?, finalURL: URL) async {
        if let micURL, let sysURL, FileManager.default.fileExists(atPath: sysURL.path) {
            do {
                try await mux(micURL: micURL, sysURL: sysURL, outputURL: finalURL)
            } catch {
                NSLog("AudioRecorder: mux failed (\(error)), falling back to mic-only")
                try? FileManager.default.moveItem(at: micURL, to: finalURL)
            }
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: sysURL)
        } else if let micURL {
            try? FileManager.default.moveItem(at: micURL, to: finalURL)
            if let sysURL { try? FileManager.default.removeItem(at: sysURL) }
        }

        showSimpleAlert(title: "Recording saved", message: "Saved to \(finalURL.path)")
    }

    private func mux(micURL: URL, sysURL: URL, outputURL: URL) async throws {
        let micAsset = AVURLAsset(url: micURL)
        let sysAsset = AVURLAsset(url: sysURL)

        let composition = AVMutableComposition()

        if let track = try await micAsset.loadTracks(withMediaType: .audio).first {
            let duration = try await micAsset.load(.duration)
            let comp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try comp?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        }

        if let track = try await sysAsset.loadTracks(withMediaType: .audio).first {
            let duration = try await sysAsset.load(.duration)
            let comp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try comp?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw MuxError.exportFailed("Could not create export session")
        }
        session.outputURL = outputURL
        session.outputFileType = .m4a
        await session.export()

        if session.status != .completed {
            throw MuxError.exportFailed(session.error?.localizedDescription)
        }
    }

    private func makeFinalOutputURL(for schedule: Schedule) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let timestamp = formatter.string(from: schedule.start)
        let safeTitle = sanitize(schedule.title.isEmpty ? "Recording" : schedule.title)
        return outputDirectory.appendingPathComponent("\(safeTitle)_\(timestamp).m4a")
    }

    private func makeMicTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_mic")
            .appendingPathExtension("m4a")
    }

    private func sanitize(_ name: String) -> String {
        let bad: Set<Character> = ["/", "\\", ":", "<", ">", "|", "?", "*", "\""]
        return String(name.map { bad.contains($0) ? "-" : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showSimpleAlert(title: String, message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .informational
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        NSLog("AudioRecorder: encode error: \(error?.localizedDescription ?? "unknown")")
    }
}
