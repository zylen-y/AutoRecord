import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var recorder: AudioRecorder
    @State private var outputPath: String = ""
    @State private var quality: AudioQuality = .medium
    @State private var launchAtLogin: Bool = false
    @State private var mcpStatus: MCPInstallService.InstallStatus = .notInstalled
    @State private var mcpActionMessage: String?

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
                    if PermissionService.micStatus != .authorized {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }

            Section("System Audio (Zoom / other apps)") {
                HStack {
                    Text(screenRecordingStatusText)
                    Spacer()
                    if !PermissionService.screenRecordingAuthorized {
                        Button("Open System Settings") {
                            PermissionService.requestScreenRecordingAccess()
                        }
                    }
                }
                if !PermissionService.screenRecordingAuthorized {
                    Text("Without Screen Recording access, only your microphone is recorded.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("MCP for Claude") {
                Text("Claude can manage your AutoRecord schedules through an MCP server bundled with the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(alignment: .firstTextBaseline) {
                    Text(mcpStatusText)
                        .foregroundColor(mcpStatusColor)
                    Spacer()
                    Button(mcpButtonTitle) { runMCPInstall() }
                        .disabled(mcpButtonDisabled)
                }

                if case .installedStale(let existing) = mcpStatus {
                    Text("Existing path:\n\(existing)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let msg = mcpActionMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if mcpStatus != .claudeConfigMissing {
                    Text("After install, fully quit and reopen Claude Desktop so it picks up the new server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    private var mcpStatusText: String {
        switch mcpStatus {
        case .claudeConfigMissing:
            return "Claude Desktop config not found — install Claude Desktop and launch it once first."
        case .notInstalled:
            return "Not registered with Claude Desktop."
        case .installedCurrent:
            return "Registered with Claude Desktop ✓"
        case .installedStale:
            return "Registered, but path is out of date — Claude will fail to start the server."
        case .readError(let m):
            return "Could not read config: \(m)"
        }
    }

    private var mcpStatusColor: Color {
        switch mcpStatus {
        case .installedCurrent: return .secondary
        case .installedStale, .readError: return .orange
        case .claudeConfigMissing: return .secondary
        case .notInstalled: return .primary
        }
    }

    private var mcpButtonTitle: String {
        switch mcpStatus {
        case .installedCurrent: return "Reinstall"
        case .installedStale: return "Update path"
        default: return "Install for Claude Desktop"
        }
    }

    private var mcpButtonDisabled: Bool {
        if case .claudeConfigMissing = mcpStatus { return true }
        return false
    }

    private func runMCPInstall() {
        do {
            try MCPInstallService.installOrUpdate()
            mcpStatus = MCPInstallService.currentStatus()
            mcpActionMessage = "Registered. Restart Claude Desktop to apply."
        } catch {
            mcpActionMessage = "Install failed: \(error)"
        }
    }

    private var screenRecordingStatusText: String {
        PermissionService.screenRecordingAuthorized
            ? "Authorized ✓"
            : "Not authorized — system audio will not be captured"
    }

    private var micStatusText: String {
        switch PermissionService.micStatus {
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
        mcpStatus = MCPInstallService.currentStatus()
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
