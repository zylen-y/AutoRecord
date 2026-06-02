# Dock-App Conversion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert AutoRecord from a menu-bar-only agent app into a hybrid Dock + menu-bar app with a main window, while preserving the menu-bar extra for at-a-glance recording state.

**Architecture:** Three SwiftUI scenes (`WindowGroup` main window, `MenuBarExtra` popover, `Settings`) backed by an `NSApplicationDelegateAdaptor` that keeps the process alive when the main window closes. Removing `LSUIElement: true` is what makes the app appear in the Dock; the `AppDelegate` is what stops it from quitting on window close (which would kill the scheduler).

**Tech Stack:** Swift 5.9, SwiftUI, AppKit (`NSApplicationDelegate`), XcodeGen (`project.yml`).

**Spec:** `docs/superpowers/specs/2026-06-02-dock-app-conversion-design.md`

**Testing note:** The macOS app target has no automated test bundle (intentionally — Xcode 26 + xcodegen + `@testable import` duplicate-output quirk; see `CLAUDE.md`). Verification per task is: (a) `xcodebuild build` succeeds with no warnings, then (b) launch the `.app` and check the named behavior. The SPM packages' `swift test` suites are unaffected and continue to pass — but no task in this plan modifies them.

---

## File Structure

| File | Purpose | Change type |
|---|---|---|
| `project.yml` | XcodeGen config — generates the Xcode project, defines Info.plist properties. | Modify (remove `LSUIElement`). |
| `AutoRecord/AutoRecordApp.swift` | App entry point, scene composition, environment-object wiring. | Modify (add `AppDelegate`, change `Window` → `WindowGroup`). |
| `AutoRecord/Views/MenuBarPopoverView.swift` | Menu-bar popover; "Open Manager…" button currently opens the secondary window. | Modify (one-line: window id rename). |
| `AutoRecord/Views/ScheduleListView.swift` | Schedule manager; will become the main window content. | Modify (add a "now recording" banner above the list). |
| `CLAUDE.md` | Project guidance for future Claude sessions. | Modify (architecture description). |

No new files created. Banner UI lives inline in `ScheduleListView.swift` (small, single-purpose, YAGNI on extraction).

---

## Task 1: Remove `LSUIElement` from Info.plist

**Files:**
- Modify: `project.yml` (lines containing `LSUIElement: true`)

**Why this is first:** the Dock icon appearing is the smallest, most visible verification step. Doing it first proves the foundation works before we touch any Swift code.

- [ ] **Step 1: Open `project.yml` and remove the `LSUIElement: true` line**

Current Info.plist properties block (around line ~30-37 of `project.yml`):

```yaml
    info:
      path: AutoRecord/Resources/Info.plist
      properties:
        LSUIElement: true
        LSMinimumSystemVersion: $(MACOSX_DEPLOYMENT_TARGET)
        NSHighResolutionCapable: true
        NSMicrophoneUsageDescription: "AutoRecord records audio during your scheduled meetings."
        CFBundleShortVersionString: "1.0"
        CFBundleVersion: "1"
```

After:

```yaml
    info:
      path: AutoRecord/Resources/Info.plist
      properties:
        LSMinimumSystemVersion: $(MACOSX_DEPLOYMENT_TARGET)
        NSHighResolutionCapable: true
        NSMicrophoneUsageDescription: "AutoRecord records audio during your scheduled meetings."
        CFBundleShortVersionString: "1.0"
        CFBundleVersion: "1"
```

- [ ] **Step 2: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: prints `Loaded project`… and `Created project at AutoRecord.xcodeproj`. No errors.

- [ ] **Step 3: Build the app**

Run: `xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`. No warnings related to `LSUIElement`.

- [ ] **Step 4: Launch and verify Dock icon**

Find the built `.app`: `ls -d ~/Library/Developer/Xcode/DerivedData/AutoRecord-*/Build/Products/Debug/AutoRecord.app | head -1`
Open it: `open <path-from-above>`
Expected:
- AutoRecord icon appears in the Dock.
- AutoRecord appears in ⌘-Tab.
- The menu-bar mic icon is still present (the `MenuBarExtra` is unaffected by this change).
- The schedule manager window does **not** open on launch yet (the `Window("schedules")` is still on-demand). This is expected — Task 3 makes it the main window.

If the Dock icon doesn't appear, double-check that `LSUIElement` is not lingering in `AutoRecord/Resources/Info.plist` itself (the file is generated from `project.yml` but check anyway).

- [ ] **Step 5: Quit the app**

From the menu-bar popover: click "Quit AutoRecord", or right-click the Dock icon → Quit.

- [ ] **Step 6: Commit**

```bash
git add project.yml AutoRecord/Resources/Info.plist AutoRecord.xcodeproj
git commit -m "feat(app): remove LSUIElement to give AutoRecord Dock presence"
```

Note on staging: `xcodegen generate` regenerates `AutoRecord/Resources/Info.plist` (and may touch `.xcodeproj`). The `.xcodeproj` is gitignored per `.gitignore`, so `git add AutoRecord.xcodeproj` will be a no-op — that's fine. Don't force-add it.

---

## Task 2: Add `AppDelegate` to keep app alive when main window closes

**Files:**
- Modify: `AutoRecord/AutoRecordApp.swift`

**Why before Task 3:** if we promote the schedule manager to the main window *before* the AppDelegate is in place, closing it would quit the app — and the scheduler would die. Wiring the delegate first means Task 3 is safe to verify by closing the window.

- [ ] **Step 1: Add the AppDelegate class and adaptor**

Open `AutoRecord/AutoRecordApp.swift`. Current content (full file is 41 lines; see it for context):

```swift
import SwiftUI

@main
struct AutoRecordApp: App {
    @StateObject private var store = ScheduleStore()
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var scheduler = SchedulerService()

    var body: some Scene {
        MenuBarExtra { … } label: { … }
        .menuBarExtraStyle(.window)

        Window("AutoRecord — Schedules", id: "schedules") { … }

        Settings { … }
    }

    private var menuBarIcon: String { … }
}
```

Modify to:

```swift
import SwiftUI
import AppKit

@main
struct AutoRecordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var store = ScheduleStore()
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var scheduler = SchedulerService()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView()
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(scheduler)
                .frame(width: 320)
                .onAppear {
                    scheduler.attach(store: store, recorder: recorder)
                }
        } label: {
            Image(systemName: menuBarIcon)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        Window("AutoRecord — Schedules", id: "schedules") {
            ScheduleListView()
                .environmentObject(store)
                .environmentObject(recorder)
                .frame(minWidth: 480, minHeight: 360)
        }

        Settings {
            SettingsView()
                .environmentObject(recorder)
                .frame(width: 460)
                .padding()
        }
    }

    private var menuBarIcon: String {
        if recorder.isRecording { return "record.circle.fill" }
        if PermissionService.micStatus == .denied { return "mic.slash" }
        return "mic"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}
```

Changes from current:
- Added `import AppKit`.
- Added `@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate` as the first stored property.
- Added the `AppDelegate` class at the bottom of the file.
- Everything else (scenes, `menuBarIcon`) is unchanged.

- [ ] **Step 2: Build**

Run: `xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Launch and verify lifecycle**

Open the built `.app` (same path as Task 1, Step 4).

Verify:
1. App launches; Dock icon visible; menu-bar icon visible.
2. From the popover, click "Open Manager…" — the schedule window opens.
3. Close the schedule window (red traffic-light button or ⌘W).
4. App is **still running**: Dock icon still present, menu-bar icon still present, popover still works.
5. Right-click Dock icon → Quit, or click "Quit AutoRecord" from the popover to stop.

The "Continue Recording" / scheduler-fires-while-window-closed flow will be verified in Task 7 end-to-end. For now we're checking that closing the window doesn't kill the process.

- [ ] **Step 4: Commit**

```bash
git add AutoRecord/AutoRecordApp.swift
git commit -m "feat(app): add AppDelegate to keep app alive on window close"
```

---

## Task 3: Promote schedule manager to main `WindowGroup`

**Files:**
- Modify: `AutoRecord/AutoRecordApp.swift`

- [ ] **Step 1: Replace `Window("schedules")` with `WindowGroup(id: "main")`**

In `AutoRecord/AutoRecordApp.swift`, find:

```swift
        Window("AutoRecord — Schedules", id: "schedules") {
            ScheduleListView()
                .environmentObject(store)
                .environmentObject(recorder)
                .frame(minWidth: 480, minHeight: 360)
        }
```

Replace with:

```swift
        WindowGroup(id: "main") {
            ScheduleListView()
                .environmentObject(store)
                .environmentObject(recorder)
                .frame(minWidth: 480, minHeight: 360)
                .navigationTitle("AutoRecord")
        }
```

Move this scene to be **first** in the `body` (before `MenuBarExtra`). In SwiftUI, the first `WindowGroup` is the one that opens on launch. The full scenes block becomes, in order:

1. `WindowGroup(id: "main")` — main window.
2. `MenuBarExtra { … }` — popover.
3. `Settings { … }` — preferences.

- [ ] **Step 2: Build**

Run: `xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Launch and verify**

Open the built `.app`.

Verify:
1. The schedule manager window **opens automatically** on launch (it's now the main window).
2. Dock icon present; menu-bar icon present.
3. From the popover, "Open Manager…" still opens the manager (or brings it forward if already open). It won't yet — that's Task 4. For now expect it to do nothing or log a "no window with id schedules" warning to the console.
4. Close the main window → app stays alive (verified in Task 2 still applies).
5. Click the Dock icon while no windows are open → the main window reopens. This is the `applicationShouldHandleReopen` behavior from Task 2 combined with `WindowGroup` (which AppKit knows how to reinstantiate).

- [ ] **Step 4: Commit**

```bash
git add AutoRecord/AutoRecordApp.swift
git commit -m "feat(app): promote schedule manager to main WindowGroup"
```

---

## Task 4: Update popover "Open Manager…" to use new window id

**Files:**
- Modify: `AutoRecord/Views/MenuBarPopoverView.swift` (around line 92-99)

- [ ] **Step 1: Change the window id from "schedules" to "main"**

In `AutoRecord/Views/MenuBarPopoverView.swift`, find:

```swift
            Button {
                openWindow(id: "schedules")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Manager…", systemImage: "calendar")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
```

Replace with:

```swift
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Manager…", systemImage: "calendar")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
```

Only the string `"schedules"` → `"main"` changes. Everything else is identical.

- [ ] **Step 2: Build**

Run: `xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Launch and verify**

Open the built `.app`.

Verify:
1. Main window opens on launch.
2. Close the main window.
3. Open the menu-bar popover, click "Open Manager…" — the main window reopens and comes forward.
4. With the main window already open and another app focused, click "Open Manager…" — AutoRecord becomes the focused app, main window comes forward.

- [ ] **Step 4: Commit**

```bash
git add AutoRecord/Views/MenuBarPopoverView.swift
git commit -m "feat(popover): point Open Manager at new main window id"
```

---

## Task 5: Add "now recording" banner to `ScheduleListView`

**Files:**
- Modify: `AutoRecord/Views/ScheduleListView.swift`

**Goal:** when a recording is active, show a thin red banner at the top of the main window with the schedule title, elapsed time, and a "Stop" button. When not recording, the banner is hidden.

Data sources are already on the `@EnvironmentObject var recorder: AudioRecorder` that `ScheduleListView` holds. The popover uses the same data — we're just adding a second view of the same state.

- [ ] **Step 1: Bump the ticker frequency and add the banner**

Open `AutoRecord/Views/ScheduleListView.swift`. Two changes:

**1a.** The current ticker fires every 30 seconds (sufficient for status badges that only change minute-to-minute). The banner shows elapsed seconds and needs a 1-second ticker. Change line 11:

```swift
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
```

to:

```swift
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
```

**1b.** Wrap the existing `Group { … }` inside `NavigationStack` with a `VStack` that hosts the banner. Current `body` (lines 13-44):

```swift
    var body: some View {
        NavigationStack {
            Group {
                if store.schedules.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Schedules")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNew = true
                    } label: {
                        Label("New schedule", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingNew) {
            ScheduleEditorView(mode: .create) { newSchedule in
                store.add(newSchedule)
            }
        }
        .sheet(item: $editing) { schedule in
            ScheduleEditorView(mode: .edit(schedule)) { updated in
                store.update(updated)
            }
        }
        .onReceive(ticker) { now = $0 }
    }
```

Replace with:

```swift
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                recordingBanner
                Group {
                    if store.schedules.isEmpty {
                        emptyState
                    } else {
                        list
                    }
                }
            }
            .navigationTitle("Schedules")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNew = true
                    } label: {
                        Label("New schedule", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingNew) {
            ScheduleEditorView(mode: .create) { newSchedule in
                store.add(newSchedule)
            }
        }
        .sheet(item: $editing) { schedule in
            ScheduleEditorView(mode: .edit(schedule)) { updated in
                store.update(updated)
            }
        }
        .onReceive(ticker) { now = $0 }
    }
```

- [ ] **Step 2: Add the `recordingBanner` view and helpers**

After the `emptyState` computed property (around line 67, before `private var list`), add:

```swift
    @ViewBuilder
    private var recordingBanner: some View {
        if recorder.isRecording,
           let schedule = recorder.currentSchedule,
           let startedAt = recorder.startedAt {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording — \(schedule.title)")
                        .font(.subheadline.bold())
                    Text("Elapsed \(formatElapsed(now.timeIntervalSince(startedAt)))")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(role: .destructive) {
                    recorder.stopAndPrompt()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .controlSize(.regular)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.10))
            .overlay(
                Rectangle()
                    .fill(Color.red.opacity(0.30))
                    .frame(height: 1),
                alignment: .bottom
            )
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
```

This duplicates the `formatDuration` logic from `MenuBarPopoverView` rather than extracting it to a shared helper, per YAGNI / "three similar lines is better than a premature abstraction" (CLAUDE.md guidance). If a third caller appears, extract then.

- [ ] **Step 3: Build**

Run: `xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Launch and verify the banner**

Open the built `.app`. Verify:

1. Main window open, no recording active: **no banner**, list looks the same as before.
2. Add a schedule starting in ~10 seconds, ending ~30 seconds after that, via the "+" button.
3. When the start time hits, the banner appears: red dot, "Recording — <title>", elapsed seconds counting up.
4. The popover and the banner both update in lockstep.
5. Click "Stop" on the banner: the same Save/Continue/Discard alert appears (it's the same `stopAndPrompt()` flow as the popover button).
6. Choose "Save" — banner disappears, recording saved to the output directory.

- [ ] **Step 5: Commit**

```bash
git add AutoRecord/Views/ScheduleListView.swift
git commit -m "feat(views): show recording banner in main window"
```

---

## Task 6: Update CLAUDE.md architecture description

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the architecture section**

Open `CLAUDE.md`. Find the line starting with "Menu-bar-only app":

```
Menu-bar-only app (`LSUIElement: true`, no Dock icon). Three scenes in `AutoRecordApp.swift`: `MenuBarExtra` popover, an explicit `Window("schedules")` manager, and `Settings`. Three `@StateObject`s — `ScheduleStore`, `AudioRecorder`, `SchedulerService` — are created once and injected via `.environmentObject` into every scene. `SchedulerService.attach(store:recorder:)` wires them together on first appear.
```

Replace with:

```
Hybrid Dock + menu-bar app. Three scenes in `AutoRecordApp.swift`: a main `WindowGroup(id: "main")` that hosts `ScheduleListView` (opens on launch), a `MenuBarExtra` popover for at-a-glance recording state, and `Settings`. An `NSApplicationDelegateAdaptor(AppDelegate.self)` returns `false` from `applicationShouldTerminateAfterLastWindowClosed` so the scheduler keeps firing when the main window is closed, and `true` from `applicationShouldHandleReopen` so clicking the Dock icon brings the window back. Three `@StateObject`s — `ScheduleStore`, `AudioRecorder`, `SchedulerService` — are created once and injected via `.environmentObject` into every scene. `SchedulerService.attach(store:recorder:)` wires them together on first appear.
```

- [ ] **Step 2: Add a note under the Scheduler section**

Find the line in the Scheduler section that mentions sleep:

```
**Known limitation:** `Timer` does not fire while the Mac is asleep — recordings starting during sleep will be late or skipped. Don't add workarounds without discussing scope.
```

Add a new paragraph immediately after it:

```
Closing the main window does **not** stop the scheduler — `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `false`, so the process stays alive in the Dock and the menu bar, and timers continue firing. The user must explicitly Quit (popover button, Dock right-click, or ⌘Q) to stop scheduled recordings.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for hybrid Dock + menu-bar architecture"
```

---

## Task 7: End-to-end manual verification

**Files:** none — this task is verification only.

- [ ] **Step 1: Clean build from scratch**

Run:
```bash
xcodegen generate
xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -configuration Debug clean build
```
Expected: `** CLEAN SUCCEEDED **` followed by `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Find and launch the app**

```bash
APP="$(ls -d ~/Library/Developer/Xcode/DerivedData/AutoRecord-*/Build/Products/Debug/AutoRecord.app | head -1)"
open "$APP"
```

- [ ] **Step 3: Verify the full conversion checklist**

Go through every item below. Treat any failure as a bug — re-open the relevant task and fix.

- [ ] Dock icon appears on launch (AutoRecord icon, not generic).
- [ ] AutoRecord appears in ⌘-Tab.
- [ ] Main window (Schedules) opens automatically on launch.
- [ ] Menu-bar mic icon still present.
- [ ] Popover opens when menu-bar icon clicked.
- [ ] "Open Manager…" in popover reopens / focuses the main window.
- [ ] ⌘, opens Settings.
- [ ] ⌘W closes the main window. App stays alive (Dock + menu bar still present).
- [ ] Clicking the Dock icon with no windows open reopens the main window.
- [ ] Add a schedule starting in ~30s, close the main window, wait. Recording starts on time (menu-bar icon turns red).
- [ ] Reopen the main window during recording → banner is visible with elapsed time updating each second.
- [ ] Click "Stop" on the banner → Save/Continue/Discard alert appears, Save writes a `.m4a` to the output folder.
- [ ] Settings → MCP for Claude install/status still works (run the install button; verify Claude Desktop config is updated).
- [ ] Settings → Login at login toggle still works (toggle off, on, restart Mac if you want full verification; smoke-test by quitting and `open`ing the app — no permission errors).
- [ ] No console errors / warnings that mention `LSUIElement`, `Window("schedules")`, or unknown window ids.

- [ ] **Step 4: Quit and tag the work**

After all checkboxes are green:

```bash
git log --oneline -8
```

You should see Tasks 1–6 as separate commits. No final commit is needed — Task 7 is verification.

---

## Out of scope (do not implement)

These were considered during brainstorming and explicitly deferred:

- Custom `CommandGroup`s for ⌘N "New Schedule" etc. — SwiftUI defaults are fine.
- `NavigationSplitView` / sidebar redesign of the schedule list.
- Dock badge counts, custom Dock tile during recording.
- Removing the `MenuBarExtra` (keeping the hybrid is the whole point).
- Extracting `formatDuration` / `formatElapsed` to a shared helper (only two callers; YAGNI).
- Automated UI tests (no test infrastructure for the app target; see CLAUDE.md).
