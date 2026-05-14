import Foundation
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

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var currentSchedule: Schedule?
    @Published private(set) var currentFileURL: URL?
    @Published private(set) var startedAt: Date?

    private var recorder: AVAudioRecorder?

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
        if PermissionService.current == .notDetermined {
            _ = await PermissionService.requestAccess()
        }
        guard PermissionService.current == .authorized else {
            PermissionService.showDeniedAlert()
            return
        }

        // Ensure output dir exists
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let url = makeFileURL(for: schedule)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: audioQuality.avQuality.rawValue
        ]

        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self
            r.prepareToRecord()
            guard r.record() else {
                NSLog("AudioRecorder: record() returned false")
                return
            }
            self.recorder = r
            self.currentSchedule = schedule
            self.currentFileURL = url
            self.startedAt = Date()
            self.isRecording = true
        } catch {
            NSLog("AudioRecorder: failed to start: \(error)")
            showSimpleAlert(title: "Recording failed to start", message: error.localizedDescription)
        }
    }

    /// Stops recording and asks the user what to do. Returns when the user has decided.
    func stopAndPrompt() {
        guard let recorder = recorder, let schedule = currentSchedule, let url = currentFileURL else { return }
        // Pause so we don't lose audio while the user decides.
        recorder.pause()

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Meeting ended: \(schedule.title)"
        alert.informativeText = "The scheduled end time has been reached. Save the recording, discard it, or keep recording?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Continue Recording")
        alert.addButton(withTitle: "Discard")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: // Save
            recorder.stop()
            self.recorder = nil
            self.isRecording = false
            self.currentSchedule = nil
            self.startedAt = nil
            self.currentFileURL = nil
            showSimpleAlert(title: "Recording saved", message: "Saved to \(url.path)")
        case .alertSecondButtonReturn: // Continue
            _ = recorder.record()
        case .alertThirdButtonReturn: // Discard
            recorder.stop()
            try? FileManager.default.removeItem(at: url)
            self.recorder = nil
            self.isRecording = false
            self.currentSchedule = nil
            self.startedAt = nil
            self.currentFileURL = nil
        default:
            // treat as continue
            _ = recorder.record()
        }
    }

    /// Manual stop from the menu bar UI (Save without prompt).
    func stopAndSaveNow() {
        guard let recorder = recorder, let url = currentFileURL else { return }
        recorder.stop()
        self.recorder = nil
        self.isRecording = false
        self.currentSchedule = nil
        self.startedAt = nil
        self.currentFileURL = nil
        showSimpleAlert(title: "Recording saved", message: "Saved to \(url.path)")
    }

    private func makeFileURL(for schedule: Schedule) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let timestamp = formatter.string(from: schedule.start)
        let safeTitle = sanitize(schedule.title.isEmpty ? "Recording" : schedule.title)
        return outputDirectory.appendingPathComponent("\(safeTitle)_\(timestamp).m4a")
    }

    private func sanitize(_ name: String) -> String {
        let bad: Set<Character> = ["/", "\\", ":", "<", ">", "|", "?", "*", "\""]
        let cleaned = String(name.map { bad.contains($0) ? "-" : $0 })
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
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
