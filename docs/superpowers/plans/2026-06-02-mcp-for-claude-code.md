# MCP for Claude Code — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add a one-click "Install for Claude Code" affordance in Settings, mirroring the existing Claude Desktop install. Same bundled `autorecord-mcp` binary; different config file.

**Architecture:** Convert `MCPInstallService` from an enum-namespace with static funcs into a value type with `configURL`, `serverKey`, and `clientName` properties. Expose two preconfigured static instances: `.claudeDesktop` (`~/Library/Application Support/Claude/claude_desktop_config.json`) and `.claudeCode` (`~/.claude.json`). `SettingsView` gets two MCP sections, one per target, each with independent status state.

**Tech Stack:** Swift 5.9, SwiftUI, `JSONSerialization`, atomic write via `replaceItemAt`.

**Spec reference:** Design approved in conversation 2026-06-02. No separate spec doc — scope is small and design is already pinned (see plan body).

**Why no automated tests:** `MCPInstallService` lives in the app target which has no test bundle (per `CLAUDE.md`). Moving it into an SPM package to enable tests is out of scope for this change. Verification is manual: install via the new button, then inspect `~/.claude.json` for the merged `mcpServers.autorecord` entry without disturbance to other keys, and (if `claude` CLI is on PATH) run `claude mcp list` to confirm registration.

---

## File Structure

| File | Change |
|---|---|
| `AutoRecord/Services/MCPInstallService.swift` | Convert enum → struct; add `.claudeDesktop` and `.claudeCode` static instances; methods become instance methods. |
| `AutoRecord/Views/SettingsView.swift` | Split MCP UI into two sections (one per target); two `@State` status fields; rename existing labels to disambiguate. |
| `CLAUDE.md` | Update the MCP server paragraph to mention both Claude Desktop and Claude Code install paths. |

No new files. The `autorecord-mcp` binary, its build pipeline (`preBuildScripts`), and the protocol-level code in `Packages/AutoRecordMCP/` are **unchanged**.

---

## Task 1: Refactor `MCPInstallService` to be target-parameterized

**Files:**
- Modify: `AutoRecord/Services/MCPInstallService.swift` (whole file)

- [ ] **Step 1: Replace the file with the parameterized version**

Replace the entire contents of `AutoRecord/Services/MCPInstallService.swift` with:

```swift
import Foundation

/// Reads and writes an MCP client's config JSON to register this app's bundled
/// `autorecord-mcp` binary as a server, without disturbing any other keys the
/// user already has. Supports multiple MCP clients via preconfigured static
/// instances (see `claudeDesktop`, `claudeCode`).
struct MCPInstallService {
    /// Path to the client's MCP config JSON.
    let configURL: URL
    /// Key under `mcpServers` to write.
    let serverKey: String
    /// Human name of the client, used in status messages.
    let clientName: String

    static let claudeDesktop = MCPInstallService(
        configURL: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Claude/claude_desktop_config.json"),
        serverKey: "autorecord",
        clientName: "Claude Desktop"
    )

    static let claudeCode = MCPInstallService(
        configURL: FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json"),
        serverKey: "autorecord",
        clientName: "Claude Code"
    )

    enum InstallStatus: Equatable {
        case configMissing
        case notInstalled
        case installedCurrent
        case installedStale(existingPath: String)
        case readError(String)
    }

    enum InstallError: Error {
        case bundleResourceMissing
        case writeFailed(String)
        case readFailed(String)
    }

    /// Path to the embedded `autorecord-mcp` binary for the running app bundle.
    static var bundleBinaryPath: String? {
        Bundle.main.resourceURL?.appendingPathComponent("autorecord-mcp").path
    }

    /// Inspects the current state without modifying anything.
    func currentStatus() -> InstallStatus {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return .configMissing
        }
        guard let desired = Self.bundleBinaryPath else {
            return .readError("Bundle resource URL unavailable")
        }
        do {
            let data = try Data(contentsOf: configURL)
            guard !data.isEmpty,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .notInstalled
            }
            let servers = root["mcpServers"] as? [String: Any]
            guard let entry = servers?[serverKey] as? [String: Any],
                  let command = entry["command"] as? String else {
                return .notInstalled
            }
            return command == desired ? .installedCurrent : .installedStale(existingPath: command)
        } catch {
            return .readError(String(describing: error))
        }
    }

    /// Adds or updates `mcpServers.<serverKey>` to point at the current bundle.
    /// Preserves every other top-level key and every other server entry.
    /// Creates the file (and its parent directory) if missing.
    func installOrUpdate() throws {
        guard let desired = Self.bundleBinaryPath else {
            throw InstallError.bundleResourceMissing
        }

        var root: [String: Any]
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: configURL)
            } catch {
                throw InstallError.readFailed(String(describing: error))
            }
            if data.isEmpty {
                root = [:]
            } else {
                do {
                    root = try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                } catch {
                    throw InstallError.readFailed(String(describing: error))
                }
            }
        } else {
            root = [:]
        }

        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers[serverKey] = ["command": desired]
        root["mcpServers"] = servers

        let parent = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        do {
            let out = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            let tmp = configURL.appendingPathExtension("tmp")
            try out.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmp)
        } catch {
            throw InstallError.writeFailed(String(describing: error))
        }
    }
}
```

Key changes from the previous version:
- `enum MCPInstallService` → `struct MCPInstallService`.
- `claudeConfigURL` static is replaced by two static instances `.claudeDesktop` and `.claudeCode`.
- `serverKey` and a new `clientName` are instance properties.
- `currentStatus()` and `installOrUpdate()` are instance methods (drop the `static`).
- `InstallStatus.claudeConfigMissing` → `.configMissing` (generic; either client could be missing).
- Otherwise the JSON-merge logic is byte-identical to before.

- [ ] **Step 2: Build**

Run: `xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -configuration Debug build`

Expected: this will FAIL because `SettingsView.swift` still calls the old API (`MCPInstallService.currentStatus()` static, `MCPInstallService.InstallStatus.claudeConfigMissing`). Task 2 fixes the call sites.

If the error count is anything other than what's caused by `SettingsView` referencing `MCPInstallService.<static>` or `.claudeConfigMissing`, stop and review — there's a regression elsewhere.

- [ ] **Step 3: Do not commit yet**

Task 1 leaves the build broken. Commit happens at the end of Task 2 so HEAD is always green.

---

## Task 2: Add Claude Code section to `SettingsView` + fix existing call sites

**Files:**
- Modify: `AutoRecord/Views/SettingsView.swift`

- [ ] **Step 1: Rewrite the MCP-related parts of `SettingsView`**

Open `AutoRecord/Views/SettingsView.swift`. Apply these edits:

**1a.** Replace the single `mcpStatus` state with two:

Find:
```swift
    @State private var mcpStatus: MCPInstallService.InstallStatus = .notInstalled
    @State private var mcpActionMessage: String?
```

Replace with:
```swift
    @State private var desktopStatus: MCPInstallService.InstallStatus = .notInstalled
    @State private var desktopMessage: String?
    @State private var codeStatus: MCPInstallService.InstallStatus = .notInstalled
    @State private var codeMessage: String?
```

**1b.** Replace the existing `Section("MCP for Claude") { … }` block with two sections. Find the existing block (starts with `Section("MCP for Claude") {` and ends with the closing `}` for the section — the block that includes "Claude can manage your AutoRecord schedules through an MCP server…" through the "After install, fully quit and reopen Claude Desktop…" hint).

Replace with:

```swift
            Section("MCP for Claude Desktop") {
                mcpSection(
                    service: .claudeDesktop,
                    status: desktopStatus,
                    message: desktopMessage,
                    restartHint: "After install, fully quit and reopen Claude Desktop so it picks up the new server.",
                    missingHint: "Claude Desktop config not found — install Claude Desktop and launch it once first.",
                    action: { runInstall(\.desktopStatus, \.desktopMessage, service: .claudeDesktop, restartLine: "Restart Claude Desktop to apply.") }
                )
            }

            Section("MCP for Claude Code") {
                mcpSection(
                    service: .claudeCode,
                    status: codeStatus,
                    message: codeMessage,
                    restartHint: "Restart any running Claude Code sessions so the new server is loaded.",
                    missingHint: "Claude Code config (~/.claude.json) not found — install Claude Code and run it once first.",
                    action: { runInstall(\.codeStatus, \.codeMessage, service: .claudeCode, restartLine: "Restart Claude Code to apply.") }
                )
            }
```

**1c.** Delete the old per-status helpers tied to a single `mcpStatus`. Find and **delete entirely**:

```swift
    private var mcpStatusText: String { … }
    private var mcpStatusColor: Color { … }
    private var mcpButtonTitle: String { … }
    private var mcpButtonDisabled: Bool { … }
    private func runMCPInstall() { … }
```

(All five members. They are now replaced by the helpers below.)

**1d.** Add new helpers. Place them just after `chooseFolder()` (or anywhere inside the `SettingsView` struct):

```swift
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

    private func runInstall(
        _ statusKP: ReferenceWritableKeyPath<SettingsView, MCPInstallService.InstallStatus>,
        _ messageKP: ReferenceWritableKeyPath<SettingsView, String?>,
        service: MCPInstallService,
        restartLine: String
    ) {
        do {
            try service.installOrUpdate()
            // SwiftUI views are value types — write back through the @State projected values.
            // We can't actually use KeyPaths on a struct here; use direct switch.
            let newStatus = service.currentStatus()
            if service.clientName == "Claude Desktop" {
                desktopStatus = newStatus
                desktopMessage = "Registered. \(restartLine)"
            } else {
                codeStatus = newStatus
                codeMessage = "Registered. \(restartLine)"
            }
        } catch {
            if service.clientName == "Claude Desktop" {
                desktopMessage = "Install failed: \(error)"
            } else {
                codeMessage = "Install failed: \(error)"
            }
        }
    }
```

Note: the KeyPath signature is included for forward-compatibility / readability, but in the body we branch on `clientName` because SwiftUI `@State` cannot be addressed by `ReferenceWritableKeyPath` on a value-type View. Two clients is a tolerable amount of branching; if we add a third we'll extract a real model.

**1e.** Update `refresh()`. Find:
```swift
    private func refresh() {
        outputPath = recorder.outputDirectory.path
        quality = recorder.audioQuality
        launchAtLogin = LoginItemService.isEnabled
        mcpStatus = MCPInstallService.currentStatus()
    }
```

Replace with:
```swift
    private func refresh() {
        outputPath = recorder.outputDirectory.path
        quality = recorder.audioQuality
        launchAtLogin = LoginItemService.isEnabled
        desktopStatus = MCPInstallService.claudeDesktop.currentStatus()
        codeStatus = MCPInstallService.claudeCode.currentStatus()
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`. If errors remain, address them — do not commit until green.

- [ ] **Step 3: Launch and verify**

```bash
pkill -f "AutoRecord.app" 2>/dev/null; sleep 1
APP="$(ls -td ~/Library/Developer/Xcode/DerivedData/AutoRecord-*/Build/Products/Debug/AutoRecord.app | head -1)"
open "$APP"
```

Open Settings (⌘,) and verify:
1. Two distinct sections: "MCP for Claude Desktop" and "MCP for Claude Code".
2. Each shows its own status.
3. Claude Code section says "Not registered with Claude Code." with an "Install for Claude Code" button (assuming you haven't installed yet).

Then click "Install for Claude Code". Verify:
4. Button label changes to "Reinstall" or status updates.
5. The success message line appears.

Verify the actual `~/.claude.json` was updated correctly:
```bash
python3 -c "
import json
d = json.load(open('/Users/doyoung07/.claude.json'))
print('top-level key count:', len(d))
print('has mcpServers:', 'mcpServers' in d)
print('autorecord entry:', d.get('mcpServers', {}).get('autorecord'))
print('sample preserved keys:', [k for k in ['numStartups','projects','userID','theme'] if k in d])
"
```
Expected:
- top-level key count is ≥19 (i.e., we did not nuke the file)
- `has mcpServers: True`
- `autorecord entry: {'command': '/path/to/.../AutoRecord.app/Contents/Resources/autorecord-mcp'}`
- All four sample preserved keys present.

If `claude` CLI is on PATH, also run:
```bash
claude mcp list 2>&1 | grep -i autorecord || echo "(claude CLI not on PATH or autorecord not listed)"
```
Expected: a line mentioning `autorecord` (this only works if you're in a directory where Claude Code can read user-scope MCPs — usually any directory works for user scope).

- [ ] **Step 4: Commit**

```bash
pkill -f "AutoRecord.app" 2>/dev/null; sleep 1
git add AutoRecord/Services/MCPInstallService.swift AutoRecord/Views/SettingsView.swift
git commit -m "feat(mcp): one-click MCP install for Claude Code"
```

---

## Task 3: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the one-click install paragraph**

Find:
```
**One-click install:** Settings → MCP for Claude runs `MCPInstallService.installOrUpdate()`, which merges an `mcpServers.autorecord` entry pointing at the embedded binary into `~/Library/Application Support/Claude/claude_desktop_config.json`. The merge preserves every other top-level key and other server entries (atomic write via `replaceItemAt`). `MCPInstallService.currentStatus()` distinguishes `installedCurrent` from `installedStale` (path no longer matches this bundle — e.g., app moved) so the UI can offer "Update" vs "Install".
```

Replace with:
```
**One-click install (two clients):** `MCPInstallService` is parameterized by `(configURL, serverKey, clientName)`. Two preconfigured instances ship:

- `MCPInstallService.claudeDesktop` → `~/Library/Application Support/Claude/claude_desktop_config.json`
- `MCPInstallService.claudeCode` → `~/.claude.json`

Settings has a section per client; each shows status and an Install/Reinstall/Update button. The merge logic is identical for both: read existing JSON, add or replace `mcpServers.<serverKey>`, write atomically via `replaceItemAt`. Every other top-level key and every other server entry is preserved — important for `~/.claude.json`, which is large (~120KB on a real user's machine) and contains Claude Code's own settings. `currentStatus()` distinguishes `installedCurrent` from `installedStale` (path no longer matches this bundle — e.g., app moved) so the UI can offer "Update" vs "Install".
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document Claude Code MCP install path in CLAUDE.md"
```

---

## Out of scope

- Moving `MCPInstallService` into the `AutoRecordShared` SPM package to enable unit tests. The logic is small and a refactor into a package needs its own design pass.
- Auto-detecting whether Claude Code is installed (we can't reliably tell — `~/.claude.json` only exists after the user has run Claude Code at least once; the missing-config status text covers this case).
- Project-scoped MCP installs (`.mcp.json` in a repo). User-scope is the right default.
- A "show as JSON" or "copy snippet" affordance for users who want to inspect/manually edit. The button-based UX is enough.
