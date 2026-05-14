import Foundation
import AVFoundation
import AppKit

enum MicAuthState {
    case authorized
    case denied
    case notDetermined
    case restricted
}

enum PermissionService {
    static var current: MicAuthState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    @MainActor
    static func showDeniedAlert() {
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
}
