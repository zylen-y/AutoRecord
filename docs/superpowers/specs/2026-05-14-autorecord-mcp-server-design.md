# AutoRecord MCP Server — Design

**Status:** Draft for review · **Date:** 2026-05-14 · **Owner:** zylenyoung@gmail.com

## Goal

Let an LLM (Claude) create, read, update, and delete AutoRecord schedules through the Model Context Protocol so workflows like *"pull tomorrow's Outlook meetings and add them to AutoRecord"* are one chat away.

## Non-goals

- **Reading calendars** (Outlook, Google, iCal). The MCP server is calendar-source-agnostic; Claude obtains events from whatever calendar access it already has and translates them into `add_schedule` calls.
- **Recording control** (start/stop/cancel an in-progress recording).
- **Listing past recordings** (the `.m4a` files in the output directory).
- **Recurring schedules.** v1 is one-off only, matching the app's current model.
- **Conflict / overlap detection.** Surface to Claude; if needed, Claude can call `list_schedules` first and decide.

Each of the above is plausibly v2 work — they are deferred, not rejected.

## Architecture

```
┌──────────────┐  stdio   ┌────────────────────┐   atomic write    ┌─────────────────────┐
│  Claude /    │ ───────► │  autorecord-mcp    │ ─────────────────►│  schedules.json     │
│  MCP client  │ ◄─────── │  (Swift CLI)       │   flock + rename  │  (Application       │
└──────────────┘          └────────────────────┘                    │   Support/         │
                                                                    │   AutoRecord/)      │
                                                                    └──────────┬──────────┘
                                                                               │ DispatchSource
                                                                               ▼ file watcher
                                                                    ┌─────────────────────┐
                                                                    │  AutoRecord.app     │
                                                                    │  (ScheduleStore)    │
                                                                    └─────────────────────┘
```

### Pieces

1. **`autorecord-mcp`** — new Swift CLI executable. Speaks MCP over stdio using the [official Swift SDK](https://github.com/modelcontextprotocol/swift-sdk). Has no UI, no networking, no persistent state beyond the on-disk JSON.
2. **`AutoRecordShared`** — new static library target containing `Schedule.swift` and `AppPaths.swift`, consumed by both the app and the MCP CLI. Replaces the current in-app copies so the two processes can never disagree about the data shape or file path.
3. **File watcher in `ScheduleStore`** — a `DispatchSource.makeFileSystemObjectSource` on `schedulesFile` that re-reads the JSON when an external writer (the MCP server) modifies it. Posts to the `@Published` array on `@MainActor`.
4. **`flock(2)` coordination** — both writers (the app and the MCP server) take an exclusive advisory lock on the schedules file for the read-modify-write window. Combined with the existing atomic-rename write, this makes simultaneous edits deterministic.

### Why this shape

- **File-based sync over an embedded HTTP/socket server in the app:** works whether the app is running or not, avoids port/socket management, no new attack surface, no protocol drift between two services. Cost is the brief race window addressed by `flock`.
- **Swift CLI over Node/Python:** lets us share `Schedule` and `AppPaths` directly, no second toolchain, ships in the app bundle. Cost is the Swift MCP SDK being less mature than the TS SDK — acceptable for four CRUD tools.

## Tool surface

All times are ISO 8601 strings with a timezone offset (e.g. `2026-05-15T09:00:00+09:00`). UUIDs are lower-case canonical.

### `list_schedules`

- **Input:** none
- **Output:**
  ```json
  {
    "schedules": [
      {
        "id": "…uuid…",
        "title": "Standup",
        "start": "2026-05-15T09:00:00+09:00",
        "end":   "2026-05-15T09:30:00+09:00",
        "createdAt": "2026-05-14T12:34:56+09:00",
        "status": "upcoming"   // "upcoming" | "active" | "past"
      }
    ]
  }
  ```
- `status` is computed at call time from the server's local clock.

### `add_schedule`

- **Input:** `{ title: string, start: string, end: string }`
- **Output:** `{ schedule: <Schedule> }` (full object, including server-assigned `id` and `createdAt`)
- **Validation:**
  - `title` non-empty after trimming
  - `start` and `end` parse as ISO 8601
  - `end > start`
- **No past-start check.** A start in the past with `end > now` is legal — the app's existing scheduler treats it as "active now, begin recording immediately," which matches user intent for "add the meeting that's happening right now."

### `update_schedule`

- **Input:** `{ id: string, title?: string, start?: string, end?: string }`
- **Output:** `{ schedule: <Schedule> }`
- **Errors:** `not_found` if `id` does not exist; same validation as `add_schedule` for any provided fields.
- `createdAt` is immutable.

### `delete_schedule`

- **Input:** `{ id: string }`
- **Output:** `{ deleted: true }`
- **Errors:** `not_found` if `id` does not exist.

### Errors

All errors are returned via MCP `isError: true` with a `code` (machine-readable) and `message` (human-readable). Codes used: `validation_error`, `not_found`, `io_error`, `lock_timeout`.

## Concurrency model

The schedules file is a shared resource between two processes. The protocol both processes must follow:

1. Open file `O_RDWR | O_CREAT`.
2. `flock(LOCK_EX)` with a 2-second timeout (implemented as `flock(LOCK_EX | LOCK_NB)` in a poll loop with `usleep`). On timeout, return `lock_timeout` (MCP server) or log and surface a non-blocking error in the UI (app — the in-memory edit is reverted so disk and memory stay in sync).
3. Read full contents.
4. Mutate in memory.
5. Encode and write to a sibling `schedules.json.tmp` in the same directory.
6. `rename(tmp, schedules.json)` (atomic on the same volume).
7. Release the lock.

The app's `ScheduleStore.save()` already uses atomic write; we extend it with `flock`. The file watcher fires on the `rename`, the app reloads, the `@Published` array updates, `SchedulerService.rebuild()` runs via its existing Combine subscription, and timers are re-armed.

**Race-window guarantee:** with `flock`, two writers serialize. The slower writer's read picks up the faster writer's commit, so neither edit is silently lost.

**Watcher loop guard:** when the app writes, it briefly suppresses its own watcher to avoid a self-trigger reload (set an "internal write in progress" flag for the duration of `save()`).

## Repo changes

```
AutoRecord/
├── (existing files; Schedule.swift and AppPaths.swift MOVED out)
└── Services/ScheduleStore.swift                     # gains file watcher + flock
AutoRecordShared/                                    # NEW static lib target
├── Schedule.swift
└── AppPaths.swift
AutoRecordMCP/                                       # NEW executable target
├── main.swift                                       # MCP server bootstrap (stdio transport)
├── ScheduleService.swift                            # flock + atomic-rename read/write
└── Tools.swift                                      # four tool handlers
project.yml                                          # +2 targets, +SPM dep on swift-sdk
docs/superpowers/specs/2026-05-14-autorecord-mcp-server-design.md
```

`project.yml` gains:

- An SPM package reference to `https://github.com/modelcontextprotocol/swift-sdk` (pinned `from: 0.11.0`).
- `AutoRecordShared` as a `framework` or `library.static` target.
- `AutoRecordMCP` as an executable target depending on `AutoRecordShared` and the MCP SDK.
- The existing `AutoRecord` target gains a dependency on `AutoRecordShared` and copies `autorecord-mcp` into `Contents/Resources/`.

## Distribution & setup

The MCP binary ships inside the signed app bundle:

```
AutoRecord.app/Contents/Resources/autorecord-mcp
```

To wire it up, the user adds one block to `~/Library/Application Support/Claude/claude_desktop_config.json` (or the equivalent Claude Code config):

```json
{
  "mcpServers": {
    "autorecord": {
      "command": "/Applications/AutoRecord.app/Contents/Resources/autorecord-mcp"
    }
  }
}
```

A **Settings → MCP** panel in the app will show this snippet with a "Copy" button so users don't have to find it themselves. (Out of scope to *write* the config file for them — Claude Desktop owns it.)

## Validation rules (summary)

| Rule | Where enforced | Error code |
|---|---|---|
| `title` non-empty after trim | MCP server | `validation_error` |
| `start`, `end` parse as ISO 8601 | MCP server | `validation_error` |
| `end > start` | MCP server | `validation_error` |
| `id` exists for update/delete | MCP server | `not_found` |
| Lock acquired within 2 s | MCP server | `lock_timeout` |

The app does no extra validation on incoming JSON beyond what `JSONDecoder` already does — invalid records would have been rejected by the MCP server.

## Open risks

1. **Swift MCP SDK maturity.** v0.x. Mitigation: keep the tool surface tiny so any breaking SDK change is a small port.
2. **Code-signing the embedded binary.** `autorecord-mcp` must be signed with the same identity as the app to avoid Gatekeeper blocking it. The existing `CODE_SIGN_IDENTITY: "-"` (ad-hoc) is fine for local dev; release signing is a build-time concern.
3. **Watcher coalescing.** macOS coalesces `DispatchSource` file events. Two writes in quick succession may fire one event; we always re-read the full file, so this is benign.
4. **Crash mid-write.** The atomic-rename pattern means the old file is intact until the rename. The `.tmp` file may linger after a crash; cleanup on next launch is a 5-line addition to `ScheduleStore.load()`.
5. **MCP server invoked while file is missing.** `schedules.json` doesn't exist until the app has saved at least once. The MCP server treats a missing file as an empty list and creates it on first write.

## Acceptance criteria

- From a fresh Claude session with the MCP wired up:
  - `"list my AutoRecord schedules"` returns the same array the app's popover shows.
  - `"add a schedule called 'Demo' from 2026-05-15 09:00 to 09:30"` returns a new schedule object; within 1 s the running app's popover shows it as the next upcoming entry.
  - `"delete the Demo schedule"` returns `{deleted: true}`; within 1 s the popover no longer shows it.
- Killing the app, modifying via MCP, relaunching: the app loads the MCP's edits.
- Modifying via MCP while the app is running with no schedules: scheduler arms timers without restart.
- Two simultaneous writes (one from MCP, one from the app's UI) both succeed; the final on-disk state contains both edits.

## What this spec does NOT decide

These are implementation-plan-level decisions, deferred to the plan:

- Whether `AutoRecordShared` is a static library, a framework, or just a Swift package added to the workspace.
- Exact MCP SDK API shapes (`Server.Tool` definition style varies by SDK version).
- Whether the file watcher lives directly in `ScheduleStore` or in a separate `ScheduleFileWatcher` helper.
- Test target — still blocked by the Xcode 26 / xcodegen quirk documented in `CLAUDE.md`; v1 ships with manual acceptance testing only.
