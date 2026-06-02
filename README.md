# AutoRecord

A macOS app that automatically records audio between scheduled start and end times and prompts you to save when the meeting ends. Captures both your microphone and system audio (Zoom, browser, anything other apps play), and lets Claude manage your schedules over MCP.

**Latest release:** [v1.1.0](https://github.com/zylen-y/AutoRecord/releases/latest) — download `AutoRecord.dmg` and drag to `/Applications`.

## Features

- Add, edit, and delete one-off recording schedules (date + start/end time).
- Lives in the Dock and the menu bar; launches at login (optional).
- Starts recording automatically at the start time.
- Captures **mic + system audio** simultaneously and muxes them into a single `.m4a` (system-audio track requires Screen Recording permission; falls back to mic-only if not granted).
- Inline "now recording" banner in the main window with elapsed time and a Stop button.
- At the end time, surfaces a dialog: **Save / Continue Recording / Discard**.
- Saves AAC `.m4a` files to a folder you choose (defaults to `~/Documents/AutoRecord/`).
- **MCP server bundled in.** One-click install registers AutoRecord with **Claude Desktop** and/or **Claude Code** so Claude can list, add, update, and delete your schedules from any conversation.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ (Xcode 26 tested)
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Build

```sh
xcodegen generate
open AutoRecord.xcodeproj
# In Xcode: select the AutoRecord scheme, then ⌘R to run.
```

Headless build:

```sh
xcodegen generate
xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -configuration Debug build
```

Package a release DMG:

```sh
./scripts/build-dmg.sh
# Output: dist/AutoRecord.dmg
```

## How it works

| Component | Responsibility |
|---|---|
| `Schedule` | `Codable` model: `id`, `title`, `start`, `end`. |
| `ScheduleStore` | Persists schedules as JSON in `~/Library/Application Support/AutoRecord/schedules.json`. Watches the file so MCP-driven edits surface in the UI live. |
| `SchedulerService` | Arms `Timer`s for each schedule's start and end events. Rebuilds whenever the schedule list changes. |
| `AudioRecorder` | Mic capture via `AVAudioRecorder`. Mux + save at end of window. Writes `Title_yyyy-MM-dd_HHmm.m4a`. |
| `SystemAudioRecorder` | System audio capture via ScreenCaptureKit. Optional — falls back to mic-only if Screen Recording permission is denied. |
| `PermissionService` | Mic + Screen Recording permission checks and "open System Settings" affordances. |
| `LoginItemService` | `SMAppService` wrapper for launch-at-login. |
| `MCPInstallService` | One-click registration of the bundled `autorecord-mcp` binary with Claude Desktop and Claude Code. |
| `AppDelegate` | Keeps the app alive when the main window closes so the scheduler keeps firing. |
| SwiftUI views | Main `WindowGroup` (schedule manager), `MenuBarExtra` popover, editor sheet, Settings. |

## Claude integration (MCP)

AutoRecord ships an MCP server (`autorecord-mcp`, bundled inside the app) that exposes four tools to any MCP client: `list_schedules`, `add_schedule`, `update_schedule`, `delete_schedule`. Both processes share the same `schedules.json`, so edits made by Claude surface in the UI within ~1 s without restart.

To register the server:

- **Claude Desktop:** Settings → MCP for Claude Desktop → **Install for Claude Desktop**.
- **Claude Code:** Settings → MCP for Claude Code → **Install for Claude Code**.

After install, quit and reopen the relevant client. You can verify in Claude Code with `claude mcp list` — `autorecord` should appear as `✓ Connected`.

## Permissions

On first run, macOS will ask for **microphone** access. If you accidentally deny, re-grant via **System Settings → Privacy & Security → Microphone**.

To capture system audio (the audio other apps are playing — Zoom, browser, etc.), AutoRecord also needs **Screen Recording** permission. macOS gates ScreenCaptureKit on this even when only audio is requested. Without it, recordings still work but contain only your mic track.

## Upgrading from v1.0.0

1. Quit AutoRecord (Dock right-click → Quit, or popover → Quit).
2. Open the new DMG, drag AutoRecord.app onto Applications, click **Replace**.
3. Open the new AutoRecord — schedules and Settings carry over automatically.
4. Re-grant Microphone / Screen Recording permissions if prompted (ad-hoc signing means macOS may treat the new build as a separate identity).
5. The Claude Desktop MCP entry still works; install the new Claude Code one from Settings if you use Claude Code.

## Known limitations

- **Sleep:** if the Mac is asleep at the scheduled start time, the timer fires once the system wakes — recordings will be late or missed entirely.
- **Schedules are one-off.** Recurrence (daily/weekly) is not yet supported.
- **No iCloud sync.** Schedules live on this Mac.

## File layout

```
AutoRecord/
├── AutoRecordApp.swift          # @main, scene composition, AppDelegate
├── Services/
│   ├── AppPaths.swift
│   ├── AudioRecorder.swift
│   ├── SystemAudioRecorder.swift
│   ├── LoginItemService.swift
│   ├── PermissionService.swift
│   ├── MCPInstallService.swift
│   ├── ScheduleStore.swift
│   └── SchedulerService.swift
├── Views/
│   ├── MenuBarPopoverView.swift
│   ├── ScheduleEditorView.swift
│   ├── ScheduleListView.swift
│   └── SettingsView.swift
├── Resources/Info.plist
└── AutoRecord.entitlements
Packages/
├── AutoRecordShared/            # Schedule model + storage shared with MCP
└── AutoRecordMCP/               # `autorecord-mcp` executable + tools
scripts/
├── build-dmg.sh                 # Release archive → polished DMG
└── generate-app-icon.sh
```

## Manual end-to-end test

1. Run the app, grant microphone permission when prompted (and Screen Recording for system audio).
2. The main schedule window opens on launch; the menu-bar icon is also present.
3. Add a schedule starting ~30 s from now, ending ~60 s after that.
4. When recording starts: menu-bar icon turns red; main window shows a red banner with elapsed seconds counting up.
5. At the end time, a dialog appears: pick **Save** → confirm `.m4a` lands in your output folder.
6. Repeat with **Discard** (file removed) and **Continue Recording** (recording resumes; stop manually from the banner or popover).
7. Close the main window mid-schedule — the app stays alive in the Dock/menu bar and the scheduler keeps firing. Click the Dock icon to reopen the window.
