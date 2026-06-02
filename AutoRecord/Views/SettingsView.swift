import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var recorder: AudioRecorder
    @State private var outputPath: String = ""
    @State private var quality: AudioQuality = .medium
    @State private var launchAtLogin: Bool = false
    @State private var desktopStatus: MCPInstallService.InstallStatus = .notInstalled
    @State private var desktopMessage: String?
    @State private var codeStatus: MCPInstallService.InstallStatus = .notInstalled
    @State private var codeMessage: String?

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

            Section("MCP for Claude Desktop") {
                mcpSection(
                    service: .claudeDesktop,
                    status: desktopStatus,
                    message: desktopMessage,
                    restartHint: "After install, fully quit and reopen Claude Desktop so it picks up the new server.",
                    missingHint: "Claude Desktop config not found — install Claude Desktop and launch it once first.",
                    action: { runInstall(service: .claudeDesktop, restartLine: "Restart Claude Desktop to apply.") }
                )
            }

            Section("MCP for Claude Code") {
                mcpSection(
                    service: .claudeCode,
                    status: codeStatus,
                    message: codeMessage,
                    restartHint: "Restart any running Claude Code sessions so the new server is loaded.",
                    missingHint: "Claude Code config (~/.claude.json) not found — install Claude Code and run it once first.",
                    action: { runInstall(service: .claudeCode, restartLine: "Restart Claude Code to apply.") }
                )
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func mcpSection(
        service: MCPInstallService,
        status: MCPInstallService.InstallStatus,
        message: String?,
        restartHint: String,
        missingHint: String,
        action: @escaping () -> Void
    ) -> some View {
        Text("Claude can manage your AutoRecord schedules through an MCP server bundled with the app.")
            .font(.callout)
            .foregroundStyle(.secondary)

        HStack(alignment: .firstTextBaseline) {
            Text(statusText(status, clientName: service.clientName, missingHint: missingHint))
                .foregroundColor(statusColor(status))
            Spacer()
            Button(buttonTitle(status, clientName: service.clientName), action: action)
                .disabled(buttonDisabled(status))
        }

        if case .installedStale(let existing) = status {
            Text("Existing path:\n\(existing)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }

        if let message {
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
        }

        if status != .configMissing {
            Text(restartHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statusText(_ s: MCPInstallService.InstallStatus, clientName: String, missingHint: String) -> String {
        switch s {
        case .configMissing: return missingHint
        case .notInstalled: return "Not registered with \(clientName)."
        case .installedCurrent: return "Registered with \(clientName) ✓"
        case .installedStale: return "Registered, but path is out of date — \(clientName) will fail to start the server."
        case .readError(let m): return "Could not read config: \(m)"
        }
    }

    private func statusColor(_ s: MCPInstallService.InstallStatus) -> Color {
        switch s {
        case .installedCurrent: return .secondary
        case .installedStale, .readError: return .orange
        case .configMissing: return .secondary
        case .notInstalled: return .primary
        }
    }

    private func buttonTitle(_ s: MCPInstallService.InstallStatus, clientName: String) -> String {
        switch s {
        case .installedCurrent: return "Reinstall"
        case .installedStale: return "Update path"
        default: return "Install for \(clientName)"
        }
    }

    private func buttonDisabled(_ s: MCPInstallService.InstallStatus) -> Bool {
        if case .configMissing = s { return true }
        return false
    }

    private func runInstall(service: MCPInstallService, restartLine: String) {
        do {
            try service.installOrUpdate()
            let newStatus = service.currentStatus()
            if service.clientName == MCPInstallService.claudeDesktop.clientName {
                desktopStatus = newStatus
                desktopMessage = "Registered. \(restartLine)"
            } else {
                codeStatus = newStatus
                codeMessage = "Registered. \(restartLine)"
            }
        } catch {
            if service.clientName == MCPInstallService.claudeDesktop.clientName {
                desktopMessage = "Install failed: \(error)"
            } else {
                codeMessage = "Install failed: \(error)"
            }
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
        desktopStatus = MCPInstallService.claudeDesktop.currentStatus()
        codeStatus = MCPInstallService.claudeCode.currentStatus()
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
