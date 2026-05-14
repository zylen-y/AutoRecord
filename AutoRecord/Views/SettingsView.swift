import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var recorder: AudioRecorder
    @State private var outputPath: String = ""
    @State private var quality: AudioQuality = .medium
    @State private var launchAtLogin: Bool = false

    var body: some View {
        Form {
            Section("Recordings") {
                HStack {
                    Text("Save to:")
                    Text(outputPath.isEmpty ? "—" : outputPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                    Button("Reveal") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: outputPath))
                    }
                    .disabled(outputPath.isEmpty)
                }

                Picker("Audio quality", selection: $quality) {
                    ForEach(AudioQuality.allCases) { q in
                        Text(q.displayName).tag(q)
                    }
                }
                .onChange(of: quality) { _, newValue in
                    recorder.audioQuality = newValue
                }
            }

            Section("Startup") {
                Toggle("Launch AutoRecord at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        LoginItemService.setEnabled(newValue)
                    }
            }

            Section("Microphone") {
                HStack {
                    Text(micStatusText)
                    Spacer()
                    if PermissionService.current != .authorized {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private var micStatusText: String {
        switch PermissionService.current {
        case .authorized: return "Authorized ✓"
        case .denied: return "Denied — open System Settings to grant access"
        case .notDetermined: return "Not yet requested"
        case .restricted: return "Restricted by system policy"
        }
    }

    private func refresh() {
        outputPath = recorder.outputDirectory.path
        quality = recorder.audioQuality
        launchAtLogin = LoginItemService.isEnabled
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = recorder.outputDirectory
        if panel.runModal() == .OK, let url = panel.url {
            recorder.outputDirectory = url
            outputPath = url.path
        }
    }
}
