# AutoRecord

A simple macOS menu-bar app that automatically records audio between scheduled start and end times and prompts you to save when the meeting ends.

## Features

- Add, edit, and delete one-off recording schedules (date + start/end time).
- Lives in the menu bar; launches at login (optional).
- Starts recording automatically at the start time.
- At the end time, surfaces a dialog: **Save / Continue Recording / Discard**.
- Saves AAC `.m4a` files to a folder you choose (defaults to `~/Documents/AutoRecord/`).
- Shows the active recording, elapsed time, and the next upcoming schedule in the menu bar popover.

## Requirements

- macOS 13 (Ventura) or later
- Xcode 15+ (Xcode 26 tested)
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Build

```sh
xcodegen generate
open AutoRecord.xcodeproj
# In Xcode: select the AutoRecord scheme, then ⌘R to run.
```

You can also build & run from the command line:

```sh
xcodegen generate
xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -configuration Debug build
open build/Debug/AutoRecord.app
```

## How it works

| Component | Responsibility |
|---|---|
| `Schedule` | Plain `Codable` model: `id`, `title`, `start`, `end`. |
| `ScheduleStore` | Persists schedules as JSON in `~/Library/Application Support/AutoRecord/schedules.json`. |
| `SchedulerService` | Arms `Timer`s for each schedule's start and end events. Rebuilds whenever the schedule list changes. |
| `AudioRecorder` | Wraps `AVAudioRecorder`. Writes `Title_yyyy-MM-dd_HHmm.m4a`. |
| `PermissionService` | Mic permission check + "open System Settings" affordance. |
| `LoginItemService` | `SMAppService` wrapper for launch-at-login. |
| SwiftUI views | `MenuBarExtra` popover, schedule list, editor sheet, settings. |

## Permissions

On first run, macOS will ask for microphone access. If you accidentally deny, re-grant via **System Settings → Privacy & Security → Microphone**.

## Known limitations (v1)

- **Sleep:** If the Mac is asleep at the scheduled start time, the timer fires once the system wakes — recordings will be late or missed entirely. A future version could prevent sleep when a recording is imminent or use `pmset` to schedule wake.
- **Schedules are one-off only.** Recurrence (daily/weekly) is intentionally out of scope for v1.
- **No iCloud sync.** Schedules live on this Mac.

## File layout

```
AutoRecord/
├── AutoRecordApp.swift          # @main, scene composition
├── Models/Schedule.swift
├── Services/
│   ├── AppPaths.swift
│   ├── AudioRecorder.swift
│   ├── LoginItemService.swift
│   ├── PermissionService.swift
│   ├── ScheduleStore.swift
│   └── SchedulerService.swift
├── Views/
│   ├── MenuBarPopoverView.swift
│   ├── ScheduleEditorView.swift
│   ├── ScheduleListView.swift
│   └── SettingsView.swift
├── Resources/Info.plist
└── AutoRecord.entitlements
```

## Manual end-to-end test

1. Run the app, grant microphone permission when prompted.
2. Open the manager (menu bar → **Open Manager…**).
3. Add a schedule starting ~30 s from now, ending ~60 s after that.
4. The menu bar icon turns red when recording starts; the popover shows the elapsed time.
5. At the end time, a dialog appears: pick **Save** → confirm `.m4a` lands in your output folder.
6. Repeat with **Discard** (file removed) and **Continue Recording** (recording resumes; stop manually from the popover).
