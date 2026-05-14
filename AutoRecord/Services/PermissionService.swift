import Foundation
import AVFoundation
import AppKit
import CoreGraphics

enum MicAuthState {
    case authorized
    case denied
    case notDetermined
    case restricted
}

enum PermissionService {
    // MARK: Microphone

    static var micStatus: MicAuthState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    static func requestMicAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    @MainActor
    static func showMicDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone access required"
        alert.informativeText = "AutoRecord needs microphone access to record audio. Open System Settings → Privacy & Security → Microphone and enable AutoRecord."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Screen Recording (required for system audio capture via ScreenCaptureKit)

    static var screenRecordingAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system permission prompt (or opens System Settings on macOS 14+).
    static func requestScreenRecordingAccess() {
        CGRequestScreenCaptureAccess()
    }

    @MainActor
    static func showScreenRecordingDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording access required"
        alert.informativeText = "To capture Zoom (and other app) audio, AutoRecord needs Screen Recording access. Open System Settings → Privacy & Security → Screen Recording and enable AutoRecord.\n\nWithout this, only your microphone will be recorded."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Skip")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
