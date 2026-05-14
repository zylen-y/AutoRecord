import Foundation
import AVFoundation
import ScreenCaptureKit

// Non-isolated container so AVAssetWriter can be fed from SCStream's sample queue.
private final class WriteContext: @unchecked Sendable {
    var writer: AVAssetWriter?
    var input: AVAssetWriterInput?
}

@MainActor
final class SystemAudioRecorder: NSObject {
    private(set) var tempFileURL: URL?

    private var stream: SCStream?
    private let ctx = WriteContext()
    private let writeQueue = DispatchQueue(label: "com.autorecord.sysaudio.write", qos: .userInitiated)

    func start() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Minimise video work — audio is all we need.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_sys")
            .appendingPathExtension("m4a")

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        ctx.writer = writer
        ctx.input = input
        tempFileURL = url

        let captureStream = SCStream(filter: filter, configuration: config, delegate: self)
        try captureStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writeQueue)
        try await captureStream.startCapture()
        self.stream = captureStream
    }

    func stop() async {
        guard let s = stream else { return }
        self.stream = nil
        try? await s.stopCapture()
        await withCheckedContinuation { continuation in
            writeQueue.async { [ctx] in
                ctx.input?.markAsFinished()
                if let w = ctx.writer, w.status == .writing {
                    w.finishWriting { continuation.resume() }
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

extension SystemAudioRecorder: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer buffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        let writer = ctx.writer
        let input = ctx.input

        if writer?.status == .unknown {
            writer?.startWriting()
            writer?.startSession(atSourceTime: buffer.presentationTimeStamp)
        }
        guard writer?.status == .writing, input?.isReadyForMoreMediaData == true else { return }
        input?.append(buffer)
    }
}

extension SystemAudioRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("SystemAudioRecorder: stream stopped with error: \(error)")
    }
}

enum SystemAudioError: Error {
    case noDisplay
}
