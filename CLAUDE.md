# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project generation & build

The Xcode project is **generated** — `AutoRecord.xcodeproj` is gitignored and must be regenerated from `project.yml` (XcodeGen) before opening or building. Edit `project.yml`, not the `.xcodeproj`.

```sh
brew install xcodegen      # one-time
xcodegen generate          # after editing project.yml or pulling
open AutoRecord.xcodeproj  # then ⌘R in Xcode

# headless build
xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -configuration Debug build
```

Deployment target: macOS 14.0, Swift 5.9. Frameworks: AVFoundation + AppKit + SwiftUI + ScreenCaptureKit (linked in `project.yml` under `targets.AutoRecord.dependencies`).

## Tests

`AutoRecordTests/` contains `XCTest` sources but **the test target is intentionally omitted from `project.yml`** (see the comment at the bottom of that file): Xcode 26 + xcodegen + `@testable import` triggers a duplicate-output build failure. To run tests, add a Unit Testing Bundle target manually in Xcode (File → New → Target → macOS Unit Testing Bundle), pointing it at `AutoRecordTests/`. Don't try to fix this by adding the target back to `project.yml`.

The MCP package (`Packages/AutoRecordMCP/`) and the shared package (`Packages/AutoRecordShared/`) have their own SPM test bundles, which run with `swift test` and are NOT affected by the Xcode quirk above. They cover `ScheduleStorage`, `ISO8601`, `ScheduleService`, and `Tools`.

## Architecture

Hybrid Dock + menu-bar app. Three scenes in `AutoRecordApp.swift`: a main `WindowGroup(id: "main")` that hosts `ScheduleListView` (opens on launch), a `MenuBarExtra` popover for at-a-glance recording state, and `Settings`. An `NSApplicationDelegateAdaptor(AppDelegate.self)` returns `false` from `applicationShouldTerminateAfterLastWindowClosed` so the scheduler keeps firing when the main window is closed, and `true` from `applicationShouldHandleReopen` so clicking the Dock icon brings the window back. Three `@StateObject`s — `ScheduleStore`, `AudioRecorder`, `SchedulerService` — are created once and injected via `.environmentObject` into every scene. `SchedulerService.attach(store:recorder:)` wires them together on first appear.

### Two-track audio capture (the non-obvious part)

A recording is **two parallel captures muxed at save time**, not a single stream:

1. `AudioRecorder` — `AVAudioRecorder` writes the **mic** track to a temp `.m4a` (mono, 44.1 kHz).
2. `SystemAudioRecorder` — wraps an `SCStream` from ScreenCaptureKit with `capturesAudio = true` and `excludesCurrentProcessAudio = true`, writing **system audio** (everything other apps play — Zoom, browser, etc.) to a second temp `.m4a` via `AVAssetWriter` on a dedicated dispatch queue (`com.autorecord.sysaudio.write`). Video is set to 2×2 px / 1 fps to minimise work.
3. On stop, `AudioRecorder.finalizeSave` muxes both temp files into a single `.m4a` via `AVMutableComposition` + `AVAssetExportSession` (preset `AVAssetExportPresetAppleM4A`). If the system track is missing (permission denied, mux failure), it **falls back to mic-only** by moving the temp file to the final URL — recording never fails just because system audio is unavailable.

System audio capture requires **Screen Recording** permission (Apple gates ScreenCaptureKit on it even when you only want audio). `PermissionService.screenRecordingAuthorized` uses `CGPreflightScreenCaptureAccess()`; if not granted at start time, the recording proceeds mic-only and a permission prompt is surfaced.

### Scheduler

`SchedulerService` arms one-shot `Timer`s for each schedule's start and end. It subscribes to `ScheduleStore.$schedules` via Combine and **rebuilds all timers from scratch** on any change. On rebuild, schedules whose window already encloses `now` are started immediately (covers app launch mid-window). **Known limitation:** `Timer` does not fire while the Mac is asleep — recordings starting during sleep will be late or skipped. Don't add workarounds without discussing scope.

Closing the main window does **not** stop the scheduler — `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `false`, so the process stays alive in the Dock and the menu bar and timers continue firing. The user must explicitly Quit (popover button, Dock right-click, or ⌘Q) to stop scheduled recordings.

### End-of-window UX

At the schedule's end time, `AudioRecorder.stopAndPrompt()` **pauses** the mic recorder (does not stop it), then shows an `NSAlert` with three actions:

- **Save** → `commitStop` finalizes both tracks, muxes, writes to `outputDirectory`.
- **Continue Recording** → resumes via `record()`; the user must stop manually from the popover.
- **Discard** → deletes both temp files.

Manual stop from the popover calls `stopAndSaveNow()` which skips the dialog.

### Persistence & paths

- Schedules: `~/Library/Application Support/AutoRecord/schedules.json` (`AppPaths.schedulesFile`, ISO8601 dates, pretty-printed). Sorted by `start` on every write.
- Recordings: `~/Documents/AutoRecord/` by default, overridable via `UserDefaults["outputDirectory"]` (settable from `SettingsView`). Filenames: `Title_yyyy-MM-dd_HHmm.m4a`, title sanitized of path-unsafe characters.

### Concurrency

All stateful services are `@MainActor`. `SystemAudioRecorder` uses an internal `WriteContext: @unchecked Sendable` to let the non-isolated `SCStreamOutput` callback feed `AVAssetWriter` from `writeQueue` without crossing actor boundaries. When editing, preserve this pattern — moving the writer onto the main actor will deadlock the sample callback.

### MCP server (`autorecord-mcp`)

A bundled CLI exposes the schedule CRUD over the Model Context Protocol so Claude can read another tool's calendar (Outlook, Google) and add the meetings to AutoRecord. Lives in `Packages/AutoRecordMCP/` as a local SPM package; built and copied into `AutoRecord.app/Contents/Resources/autorecord-mcp` by a `preBuildScripts` entry in `project.yml`. Tools: `list_schedules`, `add_schedule`, `update_schedule`, `delete_schedule` — all four operate on the same `schedules.json` as the app.

Both processes share `AutoRecordShared.ScheduleStorage`, which serialises writes with `flock(2)` + atomic rename. The app's `ScheduleStore` adds a `DispatchSource` file watcher so MCP-driven edits surface in the UI within ~1 s without restart. Self-writes are suppressed via a one-shot flag to avoid reload loops, and the watcher is rearmed on `.rename`/`.delete` events because `replaceItemAt` unlinks the watched inode.

The MCP package has its own `swift test` suite (unaffected by the Xcode quirk that blocks the app's test target). Run from `Packages/AutoRecordMCP/`:

```sh
swift test
```

`Packages/AutoRecordShared/` likewise has its own `swift test` suite.

**One-click install (two clients):** `MCPInstallService` is a value type parameterized by `(configURL, serverKey, clientName)`. Two preconfigured static instances ship:

- `MCPInstallService.claudeDesktop` → `~/Library/Application Support/Claude/claude_desktop_config.json`
- `MCPInstallService.claudeCode` → `~/.claude.json`

Settings has a section per client; each shows its own status and an Install/Reinstall/Update button. The merge logic is identical for both: read existing JSON, add or replace `mcpServers.<serverKey>`, write atomically via `replaceItemAt`. Every other top-level key and every other server entry is preserved — critical for `~/.claude.json`, which is large (~120 KB on a real user's machine) and holds Claude Code's own settings. `currentStatus()` distinguishes `installedCurrent` from `installedStale` (path no longer matches this bundle — e.g., app moved) so the UI can offer "Update" vs "Install".

### Distribution (DMG + GitHub Releases)

Public releases live at https://github.com/zylen-y/AutoRecord (current: [v1.0.0](https://github.com/zylen-y/AutoRecord/releases/tag/v1.0.0)). Users download `AutoRecord.dmg` from the Releases page — that DMG is what end-users see, so the Finder layout and bundled `autorecord-mcp` matter.

`scripts/build-dmg.sh` produces `dist/AutoRecord.dmg`. It archives a Release build (`xcodebuild archive` — which runs the `autorecord-mcp` preBuildScript), copies the `.app` into a writable HFS+ image alongside an `/Applications` symlink and a `.background/background.png`, then drives Finder via AppleScript to set window bounds, icon positions, and the background image. `sync` + `sleep` are deliberate: `.DS_Store` must flush before `hdiutil detach`, or the layout will be lost when the DMG is reopened. Final step converts to compressed UDZO. The script asserts that `autorecord-mcp` is embedded in the archived bundle before packaging — don't remove that check. `scripts/generate-app-icon.sh` regenerates the `AppIcon` asset catalog from a source image.

### Sandbox & entitlements

App sandbox is **off** (`ENABLE_APP_SANDBOX: NO` in `project.yml`); entitlements only declare `com.apple.security.device.audio-input`. The remaining capabilities (screen recording, Documents folder writes, login-item registration) work via TCC / `SMAppService` and don't need sandbox entitlements as long as the sandbox stays off. Don't enable the sandbox without re-evaluating all three.
