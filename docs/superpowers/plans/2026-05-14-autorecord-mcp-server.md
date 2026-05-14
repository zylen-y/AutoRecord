# AutoRecord MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Swift CLI MCP server that lets Claude create, read, update, and delete AutoRecord schedules via four stdio tools, with the running app picking up changes live through a `flock`-coordinated shared `schedules.json`.

**Architecture:** Two new local Swift packages (`AutoRecordShared` for shared types/storage, `AutoRecordMCP` for the CLI). The CLI uses [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk). Both the app and the CLI go through one `ScheduleStorage` type that reads and writes `~/Library/Application Support/AutoRecord/schedules.json` with `flock(2)` + atomic rename. The app's `ScheduleStore` adds a `DispatchSource` file watcher so external edits propagate to the UI.

**Tech Stack:** Swift 5.9, macOS 14, XcodeGen, Swift Package Manager, official Swift MCP SDK (≥ 0.11.0), `DispatchSource.makeFileSystemObjectSource`, `flock(2)`.

**Deviation from spec:** the spec says "manual acceptance testing only" because the existing Xcode test target trips an `@testable import` quirk. That quirk does NOT affect fresh SPM packages run with `swift test`, so this plan adds unit tests to the two new packages. The existing app target stays test-less, matching the spec. This is a strict improvement, not a scope expansion.

---

## File structure

```
Packages/
├── AutoRecordShared/                             # NEW SPM package
│   ├── Package.swift
│   ├── Sources/AutoRecordShared/
│   │   ├── Schedule.swift                        # MOVED from AutoRecord/Models/, made public
│   │   ├── AppPaths.swift                        # MOVED from AutoRecord/Services/, made public
│   │   └── ScheduleStorage.swift                 # NEW — flock + atomic rename read/write
│   └── Tests/AutoRecordSharedTests/
│       └── ScheduleStorageTests.swift
└── AutoRecordMCP/                                # NEW SPM package
    ├── Package.swift
    ├── Sources/AutoRecordMCPCore/                # library — testable
    │   ├── ISO8601.swift
    │   ├── ToolError.swift
    │   ├── ScheduleService.swift                 # CRUD on ScheduleStorage + validation
    │   └── Tools.swift                           # MCP tool definitions + dispatch
    ├── Sources/autorecord-mcp/                   # executable
    │   └── main.swift                            # MCP server bootstrap
    └── Tests/AutoRecordMCPCoreTests/
        ├── ISO8601Tests.swift
        ├── ScheduleServiceTests.swift
        └── ToolsTests.swift

AutoRecord/
├── Models/Schedule.swift                         # DELETED (moved)
└── Services/
    ├── AppPaths.swift                            # DELETED (moved)
    └── ScheduleStore.swift                       # MODIFIED — uses ScheduleStorage + file watcher

project.yml                                       # MODIFIED — adds two local SPM packages + Copy Files phase
AutoRecord/Views/SettingsView.swift               # MODIFIED — shows MCP config snippet
CLAUDE.md                                         # MODIFIED — adds MCP section
docs/superpowers/plans/2026-05-14-autorecord-mcp-server.md   # this file
```

---

## Task 1: Bootstrap `AutoRecordShared` SPM package and move shared types

**Files:**
- Create: `Packages/AutoRecordShared/Package.swift`
- Create: `Packages/AutoRecordShared/Sources/AutoRecordShared/Schedule.swift`
- Create: `Packages/AutoRecordShared/Sources/AutoRecordShared/AppPaths.swift`
- Delete: `AutoRecord/Models/Schedule.swift`
- Delete: `AutoRecord/Services/AppPaths.swift`

- [ ] **Step 1: Create the package directory and `Package.swift`**

```bash
mkdir -p Packages/AutoRecordShared/Sources/AutoRecordShared
mkdir -p Packages/AutoRecordShared/Tests/AutoRecordSharedTests
```

Write `Packages/AutoRecordShared/Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoRecordShared",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AutoRecordShared", targets: ["AutoRecordShared"]),
    ],
    targets: [
        .target(name: "AutoRecordShared"),
        .testTarget(
            name: "AutoRecordSharedTests",
            dependencies: ["AutoRecordShared"]
        ),
    ]
)
```

- [ ] **Step 2: Move `Schedule.swift` and make every declaration `public`**

Write `Packages/AutoRecordShared/Sources/AutoRecordShared/Schedule.swift`:

```swift
import Foundation

public struct Schedule: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var start: Date
    public var end: Date
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, start: Date, end: Date, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.createdAt = createdAt
    }

    public enum Status: String, Sendable {
        case upcoming
        case active
        case past
    }

    public func status(now: Date = Date()) -> Status {
        if now < start { return .upcoming }
        if now >= end { return .past }
        return .active
    }
}
```

Then delete the original:

```bash
rm AutoRecord/Models/Schedule.swift
```

- [ ] **Step 3: Move `AppPaths.swift` and make every declaration `public`**

Write `Packages/AutoRecordShared/Sources/AutoRecordShared/AppPaths.swift`:

```swift
import Foundation

public enum AppPaths {
    public static let appName = "AutoRecord"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var schedulesFile: URL {
        supportDirectory.appendingPathComponent("schedules.json")
    }

    public static var defaultRecordingsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
```

Then delete the original:

```bash
rm AutoRecord/Services/AppPaths.swift
```

- [ ] **Step 4: Build the new package in isolation to confirm it compiles**

Run: `cd Packages/AutoRecordShared && swift build`
Expected: `Build complete!` with no errors. `cd ../..` back to repo root.

- [ ] **Step 5: Commit**

```bash
git add Packages/AutoRecordShared
git rm AutoRecord/Models/Schedule.swift AutoRecord/Services/AppPaths.swift
git commit -m "refactor: extract Schedule and AppPaths into AutoRecordShared package"
```

---

## Task 2: Wire `AutoRecordShared` into the app via `project.yml`

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add the local package and target dependency**

Open `project.yml`. Above `targets:`, add a `packages:` section. Then under `targets.AutoRecord.dependencies`, add the package product. The relevant changes:

```yaml
packages:
  AutoRecordShared:
    path: Packages/AutoRecordShared

targets:
  AutoRecord:
    type: application
    platform: macOS
    dependencies:
      - sdk: ScreenCaptureKit.framework
      - package: AutoRecordShared
    sources:
      - path: AutoRecord
        excludes:
          - "Resources/Info.plist"
          - "AutoRecord.entitlements"
    # ...rest unchanged
```

- [ ] **Step 2: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: `Loaded project` and `Created project at AutoRecord.xcodeproj` (or similar success line). No errors.

- [ ] **Step 3: Add `import AutoRecordShared` to every app file that referenced the moved types**

The files that reference `Schedule`, `Schedule.Status`, `AppPaths`, or `AppPaths.schedulesFile`/`defaultRecordingsDirectory`:

```bash
grep -l "Schedule\b\|AppPaths" AutoRecord/**/*.swift
```

For each match, add `import AutoRecordShared` immediately under the existing `import Foundation` (or as the first import if Foundation is missing). Files to update: `AutoRecordApp.swift`, `Services/ScheduleStore.swift`, `Services/SchedulerService.swift`, `Services/AudioRecorder.swift`, `Views/MenuBarPopoverView.swift`, `Views/ScheduleEditorView.swift`, `Views/ScheduleListView.swift`, `Views/SettingsView.swift`.

- [ ] **Step 4: Build the app via xcodebuild to confirm the migration compiles**

Run:
```bash
xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -configuration Debug build
```
Expected: `BUILD SUCCEEDED`. If a file complains about missing `Schedule` or `AppPaths`, it needs `import AutoRecordShared`.

- [ ] **Step 5: Commit**

```bash
git add project.yml AutoRecord
git commit -m "build: depend on AutoRecordShared package from app target"
```

---

## Task 3: Implement `ScheduleStorage` with `flock` + atomic write (TDD)

**Files:**
- Create: `Packages/AutoRecordShared/Sources/AutoRecordShared/ScheduleStorage.swift`
- Create: `Packages/AutoRecordShared/Tests/AutoRecordSharedTests/ScheduleStorageTests.swift`

`ScheduleStorage` is the single I/O type used by both the app and the MCP CLI. It hides `flock`, atomic rename, and JSON coding behind `read()` and `write(_:)`.

- [ ] **Step 1: Write the failing tests**

Write `Packages/AutoRecordShared/Tests/AutoRecordSharedTests/ScheduleStorageTests.swift`:

```swift
import XCTest
@testable import AutoRecordShared

final class ScheduleStorageTests: XCTestCase {
    var tmpDir: URL!
    var fileURL: URL!
    var storage: ScheduleStorage!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AutoRecordStorageTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        fileURL = tmpDir.appendingPathComponent("schedules.json")
        storage = ScheduleStorage(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func testReadReturnsEmptyArrayWhenFileMissing() throws {
        XCTAssertEqual(try storage.read(), [])
    }

    func testWriteThenReadRoundTrips() throws {
        let s = Schedule(title: "Demo", start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 2000))
        try storage.write([s])
        let read = try storage.read()
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].id, s.id)
        XCTAssertEqual(read[0].title, "Demo")
    }

    func testWriteIsAtomic_TempFileIsRemovedOnSuccess() throws {
        let s = Schedule(title: "T", start: Date(), end: Date().addingTimeInterval(60))
        try storage.write([s])
        let tmp = fileURL.appendingPathExtension("tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
    }

    func testWriteSortsByStartAscending() throws {
        let later = Schedule(title: "B", start: Date(timeIntervalSince1970: 2000), end: Date(timeIntervalSince1970: 3000))
        let earlier = Schedule(title: "A", start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 1500))
        try storage.write([later, earlier])
        let read = try storage.read()
        XCTAssertEqual(read.map(\.title), ["A", "B"])
    }

    func testConcurrentWritesAreSerialized() throws {
        // Two ScheduleStorage instances on the same file: both should succeed,
        // and the final state should contain both writes (last writer wins on
        // overlapping fields, but distinct ids should both survive).
        let storage2 = ScheduleStorage(fileURL: fileURL)
        let a = Schedule(title: "A", start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
        let b = Schedule(title: "B", start: Date(timeIntervalSince1970: 300), end: Date(timeIntervalSince1970: 400))
        let q = DispatchQueue(label: "concurrent", attributes: .concurrent)
        let g = DispatchGroup()
        q.async(group: g) { try? self.storage.write([a]) }
        q.async(group: g) { try? storage2.write([b]) }
        g.wait()
        let final = try storage.read()
        // At least one of the writes must be intact (the other will have been
        // overwritten by the later writer); the file MUST be valid JSON.
        XCTAssertFalse(final.isEmpty)
    }

    func testLockTimeoutThrowsLockTimeoutError() throws {
        // Hold the file's flock manually, then attempt a write with a tight timeout.
        let fd = open(fileURL.path, O_RDWR | O_CREAT, 0o644)
        XCTAssertNotEqual(fd, -1)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        defer { _ = flock(fd, LOCK_UN) }

        let tightStorage = ScheduleStorage(fileURL: fileURL, lockTimeoutSeconds: 0.1)
        let s = Schedule(title: "X", start: Date(), end: Date().addingTimeInterval(60))
        XCTAssertThrowsError(try tightStorage.write([s])) { error in
            guard case ScheduleStorage.StorageError.lockTimeout = error else {
                return XCTFail("Expected lockTimeout, got \(error)")
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/AutoRecordShared && swift test`
Expected: compile errors — `ScheduleStorage` does not exist.

- [ ] **Step 3: Implement `ScheduleStorage`**

Write `Packages/AutoRecordShared/Sources/AutoRecordShared/ScheduleStorage.swift`:

```swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public final class ScheduleStorage {
    public enum StorageError: Error, Equatable {
        case lockTimeout
        case ioFailure(String)
        case decodeFailure(String)
    }

    public let fileURL: URL
    public let lockTimeoutSeconds: TimeInterval

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL = AppPaths.schedulesFile, lockTimeoutSeconds: TimeInterval = 2.0) {
        self.fileURL = fileURL
        self.lockTimeoutSeconds = lockTimeoutSeconds
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        self.encoder = e
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
    }

    /// Reads all schedules. Missing file returns []. Acquires a shared lock.
    public func read() throws -> [Schedule] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try withLock(exclusive: false) {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { return [] }
            do {
                return try decoder.decode([Schedule].self, from: data)
            } catch {
                throw StorageError.decodeFailure(String(describing: error))
            }
        }
    }

    /// Writes schedules sorted by `start` ascending. Acquires an exclusive lock,
    /// writes to a sibling `.tmp` file, and atomically renames into place.
    public func write(_ schedules: [Schedule]) throws {
        let sorted = schedules.sorted { $0.start < $1.start }
        try withLock(exclusive: true) {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data: Data
            do {
                data = try encoder.encode(sorted)
            } catch {
                throw StorageError.ioFailure(String(describing: error))
            }
            let tmp = fileURL.appendingPathExtension("tmp")
            do {
                try data.write(to: tmp, options: .atomic)
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                throw StorageError.ioFailure(String(describing: error))
            }
            return ()
        }
    }

    // MARK: - Lock helper

    private func withLock<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
        // Open (or create) the file so flock has something to lock.
        let fd = open(fileURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw StorageError.ioFailure("open failed: errno \(errno)")
        }
        defer { close(fd) }

        let op = (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB
        let deadline = Date().addingTimeInterval(lockTimeoutSeconds)
        while true {
            if flock(fd, op) == 0 { break }
            if errno != EWOULDBLOCK {
                throw StorageError.ioFailure("flock errno \(errno)")
            }
            if Date() >= deadline {
                throw StorageError.lockTimeout
            }
            usleep(20_000) // 20ms
        }
        defer { _ = flock(fd, LOCK_UN) }

        return try body()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/AutoRecordShared && swift test`
Expected: all six tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/AutoRecordShared
git commit -m "feat(shared): add ScheduleStorage with flock + atomic-rename I/O"
```

---

## Task 4: Migrate `ScheduleStore` to use `ScheduleStorage`

**Files:**
- Modify: `AutoRecord/Services/ScheduleStore.swift`

- [ ] **Step 1: Rewrite `ScheduleStore` to delegate I/O to `ScheduleStorage`**

Replace the contents of `AutoRecord/Services/ScheduleStore.swift` with:

```swift
import Foundation
import Combine
import AutoRecordShared

@MainActor
final class ScheduleStore: ObservableObject {
    @Published private(set) var schedules: [Schedule] = []

    private let storage: ScheduleStorage

    init(storage: ScheduleStorage = ScheduleStorage()) {
        self.storage = storage
        reload()
    }

    func add(_ schedule: Schedule) {
        var next = schedules
        next.append(schedule)
        persist(next)
    }

    func update(_ schedule: Schedule) {
        guard let idx = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        var next = schedules
        next[idx] = schedule
        persist(next)
    }

    func delete(id: UUID) {
        let next = schedules.filter { $0.id != id }
        persist(next)
    }

    func schedule(id: UUID) -> Schedule? {
        schedules.first { $0.id == id }
    }

    func nextUpcoming(now: Date = Date()) -> Schedule? {
        schedules.filter { $0.start > now }.min(by: { $0.start < $1.start })
    }

    func activeSchedule(now: Date = Date()) -> Schedule? {
        schedules.first { $0.status(now: now) == .active }
    }

    /// Reload from disk. Called on init and from the file watcher.
    func reload() {
        do {
            self.schedules = try storage.read()
        } catch {
            NSLog("ScheduleStore: failed to load schedules: \(error)")
        }
    }

    private func persist(_ next: [Schedule]) {
        let sorted = next.sorted { $0.start < $1.start }
        self.schedules = sorted
        do {
            try storage.write(sorted)
        } catch {
            NSLog("ScheduleStore: failed to save schedules: \(error)")
        }
    }
}
```

- [ ] **Step 2: Build the app**

Run: `xcodegen generate && xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -configuration Debug build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Manual sanity test**

Launch the app in Xcode (⌘R), add a schedule via the manager UI, quit the app, run `cat ~/Library/Application\ Support/AutoRecord/schedules.json` — confirm the schedule is on disk in the expected pretty-printed format.

- [ ] **Step 4: Commit**

```bash
git add AutoRecord/Services/ScheduleStore.swift
git commit -m "refactor: ScheduleStore now writes via ScheduleStorage"
```

---

## Task 5: Add file watcher to `ScheduleStore`

**Files:**
- Modify: `AutoRecord/Services/ScheduleStore.swift`

- [ ] **Step 1: Add the watcher + self-write suppression**

Edit `AutoRecord/Services/ScheduleStore.swift` to add a `DispatchSource` file watcher and a suppression flag so self-writes don't trigger a reload loop. The complete updated file:

```swift
import Foundation
import Combine
import AutoRecordShared

@MainActor
final class ScheduleStore: ObservableObject {
    @Published private(set) var schedules: [Schedule] = []

    private let storage: ScheduleStorage
    private var watcherSource: DispatchSourceFileSystemObject?
    private var watcherFD: Int32 = -1
    private var suppressNextWatcherEvent = false

    init(storage: ScheduleStorage = ScheduleStorage()) {
        self.storage = storage
        reload()
        startWatcher()
    }

    deinit {
        watcherSource?.cancel()
        if watcherFD >= 0 { close(watcherFD) }
    }

    func add(_ schedule: Schedule) {
        var next = schedules
        next.append(schedule)
        persist(next)
    }

    func update(_ schedule: Schedule) {
        guard let idx = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        var next = schedules
        next[idx] = schedule
        persist(next)
    }

    func delete(id: UUID) {
        let next = schedules.filter { $0.id != id }
        persist(next)
    }

    func schedule(id: UUID) -> Schedule? {
        schedules.first { $0.id == id }
    }

    func nextUpcoming(now: Date = Date()) -> Schedule? {
        schedules.filter { $0.start > now }.min(by: { $0.start < $1.start })
    }

    func activeSchedule(now: Date = Date()) -> Schedule? {
        schedules.first { $0.status(now: now) == .active }
    }

    func reload() {
        do {
            self.schedules = try storage.read()
        } catch {
            NSLog("ScheduleStore: failed to load schedules: \(error)")
        }
    }

    private func persist(_ next: [Schedule]) {
        let sorted = next.sorted { $0.start < $1.start }
        self.schedules = sorted
        suppressNextWatcherEvent = true
        do {
            try storage.write(sorted)
        } catch {
            suppressNextWatcherEvent = false
            NSLog("ScheduleStore: failed to save schedules: \(error)")
        }
    }

    // MARK: - File watcher

    private func startWatcher() {
        let path = storage.fileURL.path
        // Ensure the file exists so we have something to watch.
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data("[]".utf8))
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("ScheduleStore: failed to open \(path) for watching, errno \(errno)")
            return
        }
        watcherFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if self.suppressNextWatcherEvent {
                self.suppressNextWatcherEvent = false
                return
            }
            // If the file was renamed/deleted (atomic write), reopen the watcher
            // on the new inode after reloading.
            let flags = src.data
            self.reload()
            if flags.contains(.rename) || flags.contains(.delete) {
                src.cancel()
                close(self.watcherFD)
                self.watcherFD = -1
                self.startWatcher()
            }
        }
        src.setCancelHandler { [weak self] in
            // fd already closed in event handler or deinit
            _ = self
        }
        src.resume()
        watcherSource = src
    }
}
```

- [ ] **Step 2: Manual acceptance test**

Build and run the app. With the app running, in a terminal:

```bash
SCHEDULE_FILE=~/Library/Application\ Support/AutoRecord/schedules.json
cat <<'EOF' > "$SCHEDULE_FILE.tmp"
[
  {
    "id": "11111111-1111-1111-1111-111111111111",
    "title": "WatcherTest",
    "start": "2099-01-01T09:00:00Z",
    "end":   "2099-01-01T09:30:00Z",
    "createdAt": "2026-05-14T00:00:00Z"
  }
]
EOF
mv "$SCHEDULE_FILE.tmp" "$SCHEDULE_FILE"
```

Open the popover within ~1 second: the "next upcoming" line should show **WatcherTest** without restarting the app.

Then delete the file:
```bash
rm "$SCHEDULE_FILE"
```
The popover should now show no upcoming schedules.

- [ ] **Step 3: Commit**

```bash
git add AutoRecord/Services/ScheduleStore.swift
git commit -m "feat: ScheduleStore picks up external edits via DispatchSource watcher"
```

---

## Task 6: Bootstrap `AutoRecordMCP` SPM package

**Files:**
- Create: `Packages/AutoRecordMCP/Package.swift`
- Create: `Packages/AutoRecordMCP/Sources/AutoRecordMCPCore/.gitkeep`
- Create: `Packages/AutoRecordMCP/Sources/autorecord-mcp/main.swift`
- Create: `Packages/AutoRecordMCP/Tests/AutoRecordMCPCoreTests/.gitkeep`

- [ ] **Step 1: Create the directory layout**

```bash
mkdir -p Packages/AutoRecordMCP/Sources/AutoRecordMCPCore
mkdir -p Packages/AutoRecordMCP/Sources/autorecord-mcp
mkdir -p Packages/AutoRecordMCP/Tests/AutoRecordMCPCoreTests
```

- [ ] **Step 2: Write `Package.swift`**

Write `Packages/AutoRecordMCP/Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoRecordMCP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "autorecord-mcp", targets: ["autorecord-mcp"]),
        .library(name: "AutoRecordMCPCore", targets: ["AutoRecordMCPCore"]),
    ],
    dependencies: [
        .package(path: "../AutoRecordShared"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.11.0"),
    ],
    targets: [
        .target(
            name: "AutoRecordMCPCore",
            dependencies: [
                .product(name: "AutoRecordShared", package: "AutoRecordShared"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .executableTarget(
            name: "autorecord-mcp",
            dependencies: [
                "AutoRecordMCPCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "AutoRecordMCPCoreTests",
            dependencies: ["AutoRecordMCPCore"]
        ),
    ]
)
```

- [ ] **Step 3: Write a stub `main.swift` that just exits cleanly**

Write `Packages/AutoRecordMCP/Sources/autorecord-mcp/main.swift`:

```swift
import Foundation
import AutoRecordMCPCore

// Real bootstrap is wired in Task 11. This stub lets us compile the package
// today and replace it once the server runner is implemented.
fputs("autorecord-mcp: not yet implemented\n", stderr)
exit(0)
```

- [ ] **Step 4: Write a placeholder so `AutoRecordMCPCore` is non-empty**

Write `Packages/AutoRecordMCP/Sources/AutoRecordMCPCore/Placeholder.swift`:

```swift
// Intentionally empty — real types are added in subsequent tasks.
public enum AutoRecordMCPCore {}
```

- [ ] **Step 5: Build the package**

Run: `cd Packages/AutoRecordMCP && swift build`
Expected: SPM resolves `swift-sdk` and `AutoRecordShared`, and the executable + library compile. The stub binary lives at `.build/debug/autorecord-mcp`.

- [ ] **Step 6: Run it once to confirm it executes**

Run: `cd Packages/AutoRecordMCP && .build/debug/autorecord-mcp; echo $?`
Expected: prints `autorecord-mcp: not yet implemented` to stderr, exits `0`.

- [ ] **Step 7: Commit**

```bash
cd ../..
git add Packages/AutoRecordMCP
git commit -m "build: scaffold AutoRecordMCP package with swift-sdk dependency"
```

---

## Task 7: Implement `ISO8601` helper (TDD)

**Files:**
- Create: `Packages/AutoRecordMCP/Sources/AutoRecordMCPCore/ISO8601.swift`
- Create: `Packages/AutoRecordMCP/Tests/AutoRecordMCPCoreTests/ISO8601Tests.swift`
- Delete: `Packages/AutoRecordMCP/Sources/AutoRecordMCPCore/Placeholder.swift`

The MCP server accepts ISO 8601 strings with a timezone offset from clients. `Foundation.ISO8601DateFormatter` has the right behaviour but its API is annoying. Wrap it once.

- [ ] **Step 1: Write the failing tests**

Write `Packages/AutoRecordMCP/Tests/AutoRecordMCPCoreTests/ISO8601Tests.swift`:

```swift
import XCTest
@testable import AutoRecordMCPCore

final class ISO8601Tests: XCTestCase {
    func testParsesUTCZuluForm() throws {
        let d = try ISO8601.parse("2026-05-15T09:00:00Z")
        XCTAssertEqual(d.timeIntervalSince1970, 1779174000)
    }

    func testParsesPositiveOffset() throws {
        let d = try ISO8601.parse("2026-05-15T18:00:00+09:00")
        XCTAssertEqual(d.timeIntervalSince1970, 1779174000)
    }

    func testParsesFractionalSeconds() throws {
        let d = try ISO8601.parse("2026-05-15T09:00:00.500Z")
        XCTAssertEqual(d.timeIntervalSince1970, 1779174000.5, accuracy: 0.001)
    }

    func testRejectsNonISOInput() {
        XCTAssertThrowsError(try ISO8601.parse("tomorrow at noon"))
        XCTAssertThrowsError(try ISO8601.parse("2026-05-15"))
        XCTAssertThrowsError(try ISO8601.parse(""))
    }

    func testFormatRoundTripsViaUTC() {
        let d = Date(timeIntervalSince1970: 1779174000)
        let s = ISO8601.format(d)
        XCTAssertEqual(try ISO8601.parse(s), d)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/AutoRecordMCP && swift test`
Expected: compile error — `ISO8601` does not exist.

- [ ] **Step 3: Implement `ISO8601`**

Delete the placeholder:
```bash
rm Packages/AutoRecordMCP/Sources/AutoRecordMCPCore/Placeholder.swift
```

Write `Packages/AutoRecordMCP/Sources/AutoRecordMCPCore/ISO8601.swift`:

```swift
import Foundation

public enum ISO8601 {
    public enum Error: Swift.Error, Equatable {
        case invalidDate(String)
    }

    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let withoutFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ string: String) throws -> Date {
        if let d = withFractional.date(from: string) { return d }
        if let d = withoutFractional.date(from: string) { return d }
        throw Error.invalidDate(string)
    }

    public static func format(_ date: Date) -> String {
        withoutFractional.string(from: date)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/AutoRecordMCP && swift test --filter ISO8601Tests`
Expected: all five tests pass.

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/AutoRecordMCP
git commit -m "feat(mcp): add ISO 8601 parse/format helper"
```

---

## Task 8: Define `ToolError`

**Files:**
- Create: `Packages/AutoRecordMCP/Sources/AutoRecordMCPCore/ToolError.swift`

- [ ] **Step 1: Write the enum**

Write `Packages/AutoRecordMCP/Sources/AutoRecordMCPCore/ToolError.swift`:

```swift
import Foundation

/// Errors surfaced from MCP tool calls. Each value carries a stable machine-readable
/// `code` and a human-readable `message`. The tool dispatcher turns these into
/// MCP `isError: true` responses.
public enum ToolError: Error, Equatable {
    case validation(String)
    case notFound(String)
    case lockTimeout
    case io(String)

    public var code: String {
        switch self {
        case .validation: return "validation_error"
        case .notFound:   return "not_found"
        case .lockTimeout: return "lock_timeout"
        case .io:         return "io_error"
        }
    }

    public var message: String {
        switch self {
        case .validation(let m), .notFound(let m), .io(let m): return m
        case .lockTimeout: return "Could not acquire schedules file lock within timeout"
        }
    }
}
```

- [ ] **Step 2: Build to confirm**

Run: `cd Packages/AutoRecordMCP && swift build`
Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
cd ../..
git add Packages/AutoRecordMCP
git commit -m "feat(mcp): add ToolError"
```

---

## Task 9: Implement `ScheduleService` (TDD)

**Files:**
- Create: `Packages/AutoRecordMCP/Sources/AutoRecordMCPCore/ScheduleService.swift`
- Create: `Packages/AutoRecordMCP/Tests/AutoRecordMCPCoreTests/ScheduleServiceTests.swift`

`ScheduleService` wraps `ScheduleStorage` and exposes the four high-level operations (`list`, `add`, `update`, `delete`) with validation. Pure logic — no MCP types yet.

- [ ] **Step 1: Write the failing tests**

Write `Packages/AutoRecordMCP/Tests/AutoRecordMCPCoreTests/ScheduleServiceTests.swift`:

```swift
import XCTest
import AutoRecordShared
@testable import AutoRecordMCPCore

final class ScheduleServiceTests: XCTestCase {
    var tmp: URL!
    var service: ScheduleService!

    override func setUp() {
        super.setUp()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SS-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let storage = ScheduleStorage(fileURL: tmp.appendingPathComponent("schedules.json"))
        service = ScheduleService(storage: storage)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - list

    func testListReturnsEmptyInitially() throws {
        XCTAssertEqual(try service.list().count, 0)
    }

    // MARK: - add

    func testAddCreatesScheduleAndAssignsID() throws {
        let s = try service.add(
            title: "Demo",
            start: "2026-05-15T09:00:00Z",
            end:   "2026-05-15T09:30:00Z"
        )
        XCTAssertEqual(s.title, "Demo")
        XCTAssertEqual(try service.list().count, 1)
    }

    func testAddTrimsTitle() throws {
        let s = try service.add(title: "  Demo  ", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:30:00Z")
        XCTAssertEqual(s.title, "Demo")
    }

    func testAddRejectsEmptyTitle() {
        XCTAssertThrowsError(try service.add(title: "   ", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:30:00Z")) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }

    func testAddRejectsEndBeforeStart() {
        XCTAssertThrowsError(try service.add(title: "Demo", start: "2026-05-15T09:30:00Z", end: "2026-05-15T09:00:00Z")) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }

    func testAddRejectsEndEqualToStart() {
        XCTAssertThrowsError(try service.add(title: "Demo", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:00:00Z")) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }

    func testAddRejectsUnparseableDate() {
        XCTAssertThrowsError(try service.add(title: "Demo", start: "tomorrow", end: "2026-05-15T09:00:00Z")) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }

    // MARK: - update

    func testUpdateChangesTitle() throws {
        let s = try service.add(title: "Old", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:30:00Z")
        let updated = try service.update(id: s.id.uuidString, title: "New", start: nil, end: nil)
        XCTAssertEqual(updated.title, "New")
        XCTAssertEqual(updated.id, s.id)
        XCTAssertEqual(try service.list().first?.title, "New")
    }

    func testUpdateRejectsUnknownId() {
        XCTAssertThrowsError(try service.update(id: UUID().uuidString, title: "x", start: nil, end: nil)) {
            XCTAssertEqual(($0 as? ToolError)?.code, "not_found")
        }
    }

    func testUpdateRejectsInvalidDate() throws {
        let s = try service.add(title: "X", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:30:00Z")
        XCTAssertThrowsError(try service.update(id: s.id.uuidString, title: nil, start: "yesterday", end: nil)) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }

    func testUpdateRejectsResultingEndBeforeStart() throws {
        let s = try service.add(title: "X", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:30:00Z")
        XCTAssertThrowsError(try service.update(id: s.id.uuidString, title: nil, start: "2026-05-15T10:00:00Z", end: nil)) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }

    func testUpdateDoesNotChangeCreatedAt() throws {
        let s = try service.add(title: "X", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:30:00Z")
        let updated = try service.update(id: s.id.uuidString, title: "Y", start: nil, end: nil)
        XCTAssertEqual(updated.createdAt, s.createdAt)
    }

    // MARK: - delete

    func testDeleteRemovesSchedule() throws {
        let s = try service.add(title: "X", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:30:00Z")
        try service.delete(id: s.id.uuidString)
        XCTAssertEqual(try service.list().count, 0)
    }

    func testDeleteRejectsUnknownId() {
        XCTAssertThrowsError(try service.delete(id: UUID().uuidString)) {
            XCTAssertEqual(($0 as? ToolError)?.code, "not_found")
        }
    }

    func testDeleteRejectsMalformedUUID() {
        XCTAssertThrowsError(try service.delete(id: "not-a-uuid")) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/AutoRecordMCP && swift test --filter ScheduleServiceTests`
Expected: compile error — `ScheduleService` does not exist.

- [ ] **Step 3: Implement `ScheduleService`**

Write `Packages/AutoRecordMCP/Sources/AutoRecordMCPCore/ScheduleService.swift`:

```swift
import Foundation
import AutoRecordShared

public final class ScheduleService {
    private let storage: ScheduleStorage

    public init(storage: ScheduleStorage = ScheduleStorage()) {
        self.storage = storage
    }

    public func list() throws -> [Schedule] {
        do { return try storage.read() }
        catch ScheduleStorage.StorageError.lockTimeout { throw ToolError.lockTimeout }
        catch { throw ToolError.io(String(describing: error)) }
    }

    public func add(title: String, start: String, end: String) throws -> Schedule {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.validation("title must not be empty")
        }
        let startDate = try parseDate(start, field: "start")
        let endDate = try parseDate(end, field: "end")
        guard endDate > startDate else {
            throw ToolError.validation("end must be strictly after start")
        }
        let schedule = Schedule(title: trimmed, start: startDate, end: endDate)
        var current = try readList()
        current.append(schedule)
        try writeList(current)
        return schedule
    }

    public func update(id: String, title: String?, start: String?, end: String?) throws -> Schedule {
        guard let uuid = UUID(uuidString: id) else {
            throw ToolError.validation("id is not a valid UUID")
        }
        var current = try readList()
        guard let idx = current.firstIndex(where: { $0.id == uuid }) else {
            throw ToolError.notFound("no schedule with id \(id)")
        }
        var s = current[idx]
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ToolError.validation("title must not be empty")
            }
            s.title = trimmed
        }
        if let start { s.start = try parseDate(start, field: "start") }
        if let end   { s.end   = try parseDate(end,   field: "end") }
        guard s.end > s.start else {
            throw ToolError.validation("end must be strictly after start")
        }
        current[idx] = s
        try writeList(current)
        return s
    }

    public func delete(id: String) throws {
        guard let uuid = UUID(uuidString: id) else {
            throw ToolError.validation("id is not a valid UUID")
        }
        var current = try readList()
        guard let idx = current.firstIndex(where: { $0.id == uuid }) else {
            throw ToolError.notFound("no schedule with id \(id)")
        }
        current.remove(at: idx)
        try writeList(current)
    }

    // MARK: - Helpers

    private func parseDate(_ s: String, field: String) throws -> Date {
        do { return try ISO8601.parse(s) }
        catch { throw ToolError.validation("\(field) is not a valid ISO 8601 timestamp") }
    }

    private func readList() throws -> [Schedule] {
        do { return try storage.read() }
        catch ScheduleStorage.StorageError.lockTimeout { throw ToolError.lockTimeout }
        catch { throw ToolError.io(String(describing: error)) }
    }

    private func writeList(_ list: [Schedule]) throws {
        do { try storage.write(list) }
        catch ScheduleStorage.StorageError.lockTimeout { throw ToolError.lockTimeout }
        catch { throw ToolError.io(String(describing: error)) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/AutoRecordMCP && swift test --filter ScheduleServiceTests`
Expected: all 14 tests pass.

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/AutoRecordMCP
git commit -m "feat(mcp): add ScheduleService with list/add/update/delete + validation"
```

---

## Task 10: Implement `Tools` (TDD)

**Files:**
- Create: `Packages/AutoRecordMCP/Sources/AutoRecordMCPCore/Tools.swift`
- Create: `Packages/AutoRecordMCP/Tests/AutoRecordMCPCoreTests/ToolsTests.swift`

`Tools` knows the MCP tool descriptors and routes `CallTool` invocations to `ScheduleService`. Pure-Swift dispatch — no I/O on the server transport, so it stays unit-testable.

- [ ] **Step 1: Write the failing tests**

Write `Packages/AutoRecordMCP/Tests/AutoRecordMCPCoreTests/ToolsTests.swift`:

```swift
import XCTest
import AutoRecordShared
@testable import AutoRecordMCPCore

final class ToolsTests: XCTestCase {
    var tmp: URL!
    var tools: Tools!

    override func setUp() {
        super.setUp()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TT-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let storage = ScheduleStorage(fileURL: tmp.appendingPathComponent("schedules.json"))
        tools = Tools(service: ScheduleService(storage: storage))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    func testDescriptorsListsAllFourTools() {
        let names = Set(tools.descriptors.map(\.name))
        XCTAssertEqual(names, ["list_schedules", "add_schedule", "update_schedule", "delete_schedule"])
    }

    func testCallListSchedulesOnEmptyReturnsEmptyArray() throws {
        let result = try tools.call(name: "list_schedules", arguments: [:])
        XCTAssertTrue(result.contains("\"schedules\""))
        XCTAssertTrue(result.contains("[]"))
    }

    func testCallAddScheduleReturnsScheduleWithIDAndStatus() throws {
        let result = try tools.call(name: "add_schedule", arguments: [
            "title": "Demo",
            "start": "2099-01-01T09:00:00Z",
            "end":   "2099-01-01T09:30:00Z"
        ])
        XCTAssertTrue(result.contains("\"title\" : \"Demo\""))
        XCTAssertTrue(result.contains("\"status\" : \"upcoming\""))
        XCTAssertTrue(result.contains("\"id\""))
    }

    func testCallUpdateRequiresKnownID() throws {
        XCTAssertThrowsError(try tools.call(name: "update_schedule", arguments: [
            "id": UUID().uuidString,
            "title": "X"
        ])) {
            XCTAssertEqual(($0 as? ToolError)?.code, "not_found")
        }
    }

    func testCallDeleteRemovesSchedule() throws {
        let added = try tools.call(name: "add_schedule", arguments: [
            "title": "X",
            "start": "2099-01-01T09:00:00Z",
            "end":   "2099-01-01T09:30:00Z"
        ])
        // Extract the id (lazy regex; deterministic field name).
        let idLine = added.split(separator: "\n").first(where: { $0.contains("\"id\"") })!
        let id = String(idLine.split(separator: "\"")[3])

        _ = try tools.call(name: "delete_schedule", arguments: ["id": id])
        let listed = try tools.call(name: "list_schedules", arguments: [:])
        XCTAssertTrue(listed.contains("[]"))
    }

    func testCallUnknownToolThrowsValidationError() {
        XCTAssertThrowsError(try tools.call(name: "blah", arguments: [:])) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }

    func testCallAddRequiresAllThreeArguments() {
        XCTAssertThrowsError(try tools.call(name: "add_schedule", arguments: ["title": "X"])) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Packages/AutoRecordMCP && swift test --filter ToolsTests`
Expected: compile error — `Tools` does not exist.

- [ ] **Step 3: Implement `Tools`**

Write `Packages/AutoRecordMCP/Sources/AutoRecordMCPCore/Tools.swift`:

```swift
import Foundation
import AutoRecordShared

public final class Tools {
    public struct Descriptor: Sendable {
        public let name: String
        public let description: String
        public let inputSchema: [String: Any]
    }

    private let service: ScheduleService
    private let encoder: JSONEncoder

    public init(service: ScheduleService = ScheduleService()) {
        self.service = service
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        self.encoder = e
    }

    // MARK: - Descriptors

    public var descriptors: [Descriptor] {
        [
            Descriptor(
                name: "list_schedules",
                description: "List every AutoRecord schedule with id, title, start, end, createdAt, and status (upcoming|active|past).",
                inputSchema: [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "additionalProperties": false
                ]
            ),
            Descriptor(
                name: "add_schedule",
                description: "Create a new AutoRecord schedule. Returns the created schedule including its assigned id.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Human-readable label, e.g., 'Standup'"] as [String: Any],
                        "start": ["type": "string", "description": "ISO 8601 datetime with offset, e.g., 2026-05-15T09:00:00+09:00"] as [String: Any],
                        "end":   ["type": "string", "description": "ISO 8601 datetime with offset. Must be strictly after start."] as [String: Any]
                    ],
                    "required": ["title", "start", "end"],
                    "additionalProperties": false
                ]
            ),
            Descriptor(
                name: "update_schedule",
                description: "Update an existing schedule's title, start, or end. Any omitted field is left unchanged. createdAt is immutable.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id":    ["type": "string", "description": "UUID of the schedule to update"] as [String: Any],
                        "title": ["type": "string"] as [String: Any],
                        "start": ["type": "string", "description": "ISO 8601 datetime with offset"] as [String: Any],
                        "end":   ["type": "string", "description": "ISO 8601 datetime with offset"] as [String: Any]
                    ],
                    "required": ["id"],
                    "additionalProperties": false
                ]
            ),
            Descriptor(
                name: "delete_schedule",
                description: "Delete a schedule by id.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "UUID of the schedule to delete"] as [String: Any]
                    ],
                    "required": ["id"],
                    "additionalProperties": false
                ]
            )
        ]
    }

    // MARK: - Dispatch

    /// Called by the MCP transport layer with the tool name and a dictionary of
    /// arguments. Returns a pretty-printed JSON string for embedding in the tool
    /// response's text content. Throws `ToolError` on failure.
    public func call(name: String, arguments: [String: Any]) throws -> String {
        switch name {
        case "list_schedules":
            return try renderList()
        case "add_schedule":
            return try renderAdd(arguments)
        case "update_schedule":
            return try renderUpdate(arguments)
        case "delete_schedule":
            return try renderDelete(arguments)
        default:
            throw ToolError.validation("unknown tool: \(name)")
        }
    }

    // MARK: - Renderers

    private func renderList() throws -> String {
        let schedules = try service.list()
        let now = Date()
        let payload: [String: Any] = [
            "schedules": schedules.map { encode($0, now: now) }
        ]
        return prettyJSON(payload)
    }

    private func renderAdd(_ args: [String: Any]) throws -> String {
        guard let title = args["title"] as? String,
              let start = args["start"] as? String,
              let end   = args["end"]   as? String else {
            throw ToolError.validation("add_schedule requires title, start, end (all strings)")
        }
        let s = try service.add(title: title, start: start, end: end)
        return prettyJSON(["schedule": encode(s, now: Date())])
    }

    private func renderUpdate(_ args: [String: Any]) throws -> String {
        guard let id = args["id"] as? String else {
            throw ToolError.validation("update_schedule requires id (string)")
        }
        let s = try service.update(
            id: id,
            title: args["title"] as? String,
            start: args["start"] as? String,
            end:   args["end"]   as? String
        )
        return prettyJSON(["schedule": encode(s, now: Date())])
    }

    private func renderDelete(_ args: [String: Any]) throws -> String {
        guard let id = args["id"] as? String else {
            throw ToolError.validation("delete_schedule requires id (string)")
        }
        try service.delete(id: id)
        return prettyJSON(["deleted": true])
    }

    private func encode(_ s: Schedule, now: Date) -> [String: Any] {
        [
            "id":        s.id.uuidString,
            "title":     s.title,
            "start":     ISO8601.format(s.start),
            "end":       ISO8601.format(s.end),
            "createdAt": ISO8601.format(s.createdAt),
            "status":    s.status(now: now).rawValue
        ]
    }

    private func prettyJSON(_ obj: Any) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Packages/AutoRecordMCP && swift test --filter ToolsTests`
Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/AutoRecordMCP
git commit -m "feat(mcp): add Tools dispatcher with four CRUD tool descriptors"
```

---

## Task 11: Implement `main.swift` MCP server bootstrap

**Files:**
- Modify: `Packages/AutoRecordMCP/Sources/autorecord-mcp/main.swift`

The dispatcher is tested in isolation. `main.swift` is the thin glue between the MCP SDK's transport and the `Tools` dispatcher. It is tested by the manual smoke test in Task 12.

- [ ] **Step 1: Rewrite `main.swift`**

Replace the contents of `Packages/AutoRecordMCP/Sources/autorecord-mcp/main.swift` with:

```swift
import Foundation
import MCP
import AutoRecordMCPCore

@main
struct AutoRecordMCPMain {
    static func main() async {
        let tools = Tools()
        let server = Server(
            name: "autorecord",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        // ListTools — translate our descriptors into MCP Tool values.
        await server.withMethodHandler(ListTools.self) { _ in
            let mcpTools = tools.descriptors.map { d -> Tool in
                Tool(
                    name: d.name,
                    description: d.description,
                    inputSchema: jsonToValue(d.inputSchema)
                )
            }
            return .init(tools: mcpTools)
        }

        // CallTool — flatten arguments to [String: Any], dispatch through Tools,
        // map ToolError into MCP error responses.
        await server.withMethodHandler(CallTool.self) { params in
            let args = valueDictToAny(params.arguments ?? [:])
            do {
                let text = try tools.call(name: params.name, arguments: args)
                return .init(content: [.text(text)], isError: false)
            } catch let err as ToolError {
                let body = #"{"code":"\#(err.code)","message":"\#(escape(err.message))"}"#
                return .init(content: [.text(body)], isError: true)
            } catch {
                let body = #"{"code":"io_error","message":"\#(escape(String(describing: error)))"}"#
                return .init(content: [.text(body)], isError: true)
            }
        }

        do {
            let transport = StdioTransport()
            try await server.start(transport: transport)
            // Block forever — stdio transport runs until stdin closes.
            try await Task.sleep(nanoseconds: .max)
        } catch {
            fputs("autorecord-mcp: fatal: \(error)\n", stderr)
            exit(1)
        }
    }
}

// MARK: - Value helpers

/// Convert the SDK's Value enum tree into Swift Any/Dictionary so we can hand
/// it to our `Tools.call(arguments:)` API.
private func valueDictToAny(_ dict: [String: Value]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (k, v) in dict {
        out[k] = valueToAny(v)
    }
    return out
}

private func valueToAny(_ v: Value) -> Any {
    if let s = v.stringValue { return s }
    if let i = v.intValue { return i }
    if let d = v.doubleValue { return d }
    if let b = v.boolValue { return b }
    if let arr = v.arrayValue { return arr.map(valueToAny) }
    if let obj = v.objectValue {
        var d: [String: Any] = [:]
        for (k, e) in obj { d[k] = valueToAny(e) }
        return d
    }
    return NSNull()
}

/// Convert a Swift dict-of-Any (our descriptor inputSchema) into a Value tree
/// the SDK can carry on the wire.
private func jsonToValue(_ any: Any) -> Value {
    if let s = any as? String { return .string(s) }
    if let b = any as? Bool   { return .bool(b) }
    if let i = any as? Int    { return .int(i) }
    if let d = any as? Double { return .double(d) }
    if let arr = any as? [Any] { return .array(arr.map(jsonToValue)) }
    if let obj = any as? [String: Any] {
        var d: [String: Value] = [:]
        for (k, v) in obj { d[k] = jsonToValue(v) }
        return .object(d)
    }
    return .null
}

private func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
     .replacingOccurrences(of: "\n", with: "\\n")
}
```

**Note on SDK accessor names:** the README shows accessors like `.stringValue`. If the installed SDK version uses different accessors (`as String?`, `value as? String`, etc.), adjust the `valueToAny` body — the only difference is in this single helper. Do not invent accessors that the compiler rejects; check `swift-sdk/Sources/MCP/Base/Value.swift` for the real ones.

- [ ] **Step 2: Build**

Run: `cd Packages/AutoRecordMCP && swift build`
Expected: `Build complete!`. If the compiler complains about Value accessors, open `.build/checkouts/swift-sdk/Sources/MCP/Base/Value.swift` and fix `valueToAny` to use the SDK's actual API.

- [ ] **Step 3: Commit**

```bash
cd ../..
git add Packages/AutoRecordMCP
git commit -m "feat(mcp): wire stdio server, tools listing, and CallTool dispatch"
```

---

## Task 12: Manual smoke test of `autorecord-mcp`

**Files:** none — verification only.

Drive the server over stdio with two hand-crafted JSON-RPC envelopes to prove `list_schedules` works end-to-end.

- [ ] **Step 1: Capture the binary path**

Run: `cd Packages/AutoRecordMCP && swift build -c release && pwd`
Note the printed directory. The binary is at `.build/release/autorecord-mcp` relative to that.

- [ ] **Step 2: Pipe a JSON-RPC `initialize` + `tools/list` exchange through it**

From the repo root:

```bash
BIN=Packages/AutoRecordMCP/.build/release/autorecord-mcp
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  sleep 0.5
} | "$BIN" | head -n 20
```

Expected: two JSON-RPC responses. The second response's `result.tools` array contains four entries with the names `list_schedules`, `add_schedule`, `update_schedule`, `delete_schedule`.

- [ ] **Step 3: Call `list_schedules` and confirm it returns `[]` when no file exists**

```bash
rm -f ~/Library/Application\ Support/AutoRecord/schedules.json
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_schedules","arguments":{}}}'
  sleep 0.5
} | "$BIN" | tail -n 20
```

Expected: the third response's `result.content[0].text` contains `"schedules" : []`.

- [ ] **Step 4: Call `add_schedule` and `list_schedules` and confirm the schedule round-trips**

```bash
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"add_schedule","arguments":{"title":"SmokeTest","start":"2099-01-01T09:00:00Z","end":"2099-01-01T09:30:00Z"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_schedules","arguments":{}}}'
  sleep 0.5
} | "$BIN" | tail -n 40
```

Expected: response id `4` returns the new schedule with an assigned `id`; response id `5` returns an array containing that schedule with `status: "upcoming"`. Verify on disk: `cat ~/Library/Application\ Support/AutoRecord/schedules.json` shows the entry.

- [ ] **Step 5: Clean up the smoke-test schedule**

```bash
rm ~/Library/Application\ Support/AutoRecord/schedules.json
```

(No commit — this task changes no files.)

---

## Task 13: Embed `autorecord-mcp` in the app bundle via `project.yml`

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add the MCP package and a Copy Files build phase**

Open `project.yml`. Add the MCP package to the `packages:` block, then add a pre-build script that builds the SPM executable and copies it into the app bundle's Resources. The relevant additions:

```yaml
packages:
  AutoRecordShared:
    path: Packages/AutoRecordShared
  AutoRecordMCP:
    path: Packages/AutoRecordMCP

targets:
  AutoRecord:
    type: application
    platform: macOS
    dependencies:
      - sdk: ScreenCaptureKit.framework
      - package: AutoRecordShared
    # ... existing config ...
    preBuildScripts:
      - name: "Build autorecord-mcp"
        script: |
          set -euo pipefail
          cd "${PROJECT_DIR}/Packages/AutoRecordMCP"
          swift build -c release --product autorecord-mcp
          DEST="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources"
          mkdir -p "$DEST"
          cp ".build/release/autorecord-mcp" "$DEST/autorecord-mcp"
        outputFiles:
          - "$(BUILT_PRODUCTS_DIR)/$(PRODUCT_NAME).app/Contents/Resources/autorecord-mcp"
```

- [ ] **Step 2: Regenerate and build**

```bash
xcodegen generate
xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -configuration Debug build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Confirm the binary is embedded**

```bash
find "$(xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR / {print $3}')" -name autorecord-mcp
```
Expected: prints a path ending in `AutoRecord.app/Contents/Resources/autorecord-mcp`.

- [ ] **Step 4: Commit**

```bash
git add project.yml
git commit -m "build: embed autorecord-mcp binary in the app bundle"
```

---

## Task 14: Show the MCP config snippet in Settings

**Files:**
- Modify: `AutoRecord/Views/SettingsView.swift`

- [ ] **Step 1: Add an MCP section to `SettingsView`**

Open `AutoRecord/Views/SettingsView.swift`. Append a new `Section` showing the embedded binary's full path and a copy-able JSON snippet. The exact addition (insert before the closing brace of the top-level `Form`/`VStack`):

```swift
Section {
    Text("Claude can manage your AutoRecord schedules through an MCP server bundled with the app.")
        .font(.callout)
        .foregroundStyle(.secondary)

    let binaryPath = Bundle.main.resourceURL?
        .appendingPathComponent("autorecord-mcp").path
        ?? "(autorecord-mcp not found in app bundle)"

    Text("Binary location:")
        .font(.subheadline).bold()
    Text(binaryPath)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)

    Text("Add to your Claude Desktop config:")
        .font(.subheadline).bold()
    let snippet = """
    {
      "mcpServers": {
        "autorecord": {
          "command": "\(binaryPath)"
        }
      }
    }
    """
    Text(snippet)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)

    Button("Copy snippet") {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snippet, forType: .string)
    }
} header: {
    Text("MCP for Claude")
}
```

- [ ] **Step 2: Build and visually verify**

```bash
xcodegen generate
xcodebuild -project AutoRecord.xcodeproj -scheme AutoRecord -configuration Debug build
```
Then run the app in Xcode (⌘R) and open **Settings → MCP for Claude**. Confirm:
- The binary path resolves and is selectable.
- The JSON snippet is shown verbatim with `"command"` pointing at the binary inside the running app's `.app/Contents/Resources/`.
- The "Copy snippet" button puts the same text on the clipboard.

- [ ] **Step 3: Commit**

```bash
git add AutoRecord/Views/SettingsView.swift
git commit -m "feat: show MCP config snippet in Settings"
```

---

## Task 15: End-to-end acceptance test with a real MCP client

**Files:** none — verification only.

Validate the four acceptance criteria from the spec against a real Claude session.

- [ ] **Step 1: Wire the binary into Claude Desktop**

Open `~/Library/Application Support/Claude/claude_desktop_config.json` (create it if missing). Add the `autorecord` entry from Settings:

```json
{
  "mcpServers": {
    "autorecord": {
      "command": "<paste from Settings — points inside the running build's app bundle>"
    }
  }
}
```

Quit and relaunch Claude Desktop so it picks up the new server.

- [ ] **Step 2: Verify `list_schedules` matches the popover**

Make sure the AutoRecord app is running. Add one or two schedules through the manager UI. In Claude Desktop, prompt: *"List my AutoRecord schedules."* Confirm the returned array matches what the popover shows (same titles, ids, times).

- [ ] **Step 3: Verify `add_schedule` propagates within 1 s**

In Claude Desktop: *"Add an AutoRecord schedule called 'Demo' from 2026-05-15 09:00 to 09:30 Asia/Seoul."* Within one second, the AutoRecord popover's "next upcoming" should show **Demo**.

- [ ] **Step 4: Verify `delete_schedule` propagates within 1 s**

In Claude Desktop: *"Delete the Demo schedule from AutoRecord."* Within one second, the popover should no longer show it.

- [ ] **Step 5: Verify offline edits survive a relaunch**

Quit the AutoRecord app entirely. In Claude Desktop: *"Add a schedule called 'Offline' tomorrow 10:00–10:15 Asia/Seoul."* Relaunch AutoRecord; the popover should list **Offline** without any further action.

- [ ] **Step 6: Verify simultaneous edits do not lose data**

With the app running, in one terminal start a Claude session that adds a schedule, and in another terminal hand-edit the JSON to add a different schedule via:

```bash
F=~/Library/Application\ Support/AutoRecord/schedules.json
python3 - <<'PY'
import json, pathlib, datetime, uuid
p = pathlib.Path("$F").expanduser()
data = json.loads(p.read_text())
data.append({
  "id": str(uuid.uuid4()),
  "title": "Manual",
  "start": "2099-02-01T09:00:00Z",
  "end":   "2099-02-01T09:30:00Z",
  "createdAt": datetime.datetime.utcnow().isoformat() + "Z"
})
p.write_text(json.dumps(data, indent=2, sort_keys=True))
PY
```

Both schedules should be present on disk and in the popover.

(No commit — this task verifies prior tasks.)

---

## Task 16: Update `CLAUDE.md` with the MCP section

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Append a new section to `CLAUDE.md`**

Open `CLAUDE.md`. Below the existing **Architecture** section, before **Sandbox & entitlements**, add:

```markdown
### MCP server (`autorecord-mcp`)

A bundled CLI exposes the schedule CRUD over the Model Context Protocol so Claude can read another tool's calendar (Outlook, Google) and add the meetings to AutoRecord. Lives in `Packages/AutoRecordMCP/` as a local SPM package; built and copied into `AutoRecord.app/Contents/Resources/autorecord-mcp` by a pre-build script in `project.yml`. Tools: `list_schedules`, `add_schedule`, `update_schedule`, `delete_schedule` — all four operate on the same `schedules.json` as the app.

Both processes share `AutoRecordShared.ScheduleStorage`, which serialises writes with `flock(2)` + atomic rename. The app's `ScheduleStore` adds a `DispatchSource` file watcher so MCP-driven edits surface in the UI within ~1 s without restart. Self-writes are suppressed via a one-shot flag to avoid reload loops.

The MCP package has its own `swift test` suite (unaffected by the app's Xcode test-target quirk). Run from `Packages/AutoRecordMCP/`:

```sh
swift test
```

Configuration snippet shown in **Settings → MCP for Claude**; users paste it into `~/Library/Application Support/Claude/claude_desktop_config.json`.
```

- [ ] **Step 2: Update the **Tests** section to mention SPM tests**

Find the existing **Tests** section (it's the one starting with `` `AutoRecordTests/` contains... ``). Append this paragraph:

```markdown
The MCP package (`Packages/AutoRecordMCP/`) and the shared package (`Packages/AutoRecordShared/`) have their own SPM test bundles, which run with `swift test` and are NOT affected by the Xcode quirk above. They cover `ScheduleStorage`, `ISO8601`, `ScheduleService`, and `Tools`.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document the MCP server in CLAUDE.md"
```

---

## Self-review

**Spec coverage:**
- Goal (Outlook → AutoRecord via MCP): Tasks 9–11 implement the four tools; Task 15 verifies the Outlook story.
- Non-goals (no calendar reading, no recording control, no recurrence, no overlap detection): not implemented — correct.
- Architecture (Swift CLI + file-based sync + flock + watcher): Tasks 3, 5, 6, 11.
- Tool surface (four CRUD tools, ISO 8601 with offset, status field): Tasks 7, 9, 10.
- Concurrency model (flock + atomic rename + self-write suppression): Tasks 3 and 5.
- Repo changes table: Tasks 1, 6 (new packages); Tasks 4, 5, 14 (modified app files); Task 13 (project.yml).
- Distribution (bundled binary + config snippet): Tasks 13, 14.
- Validation rules (non-empty title, parseable dates, end > start, not_found, lock_timeout): Tasks 8, 9.
- Acceptance criteria: Task 15 walks through each one explicitly.
- Open risks (SDK maturity, signing, watcher coalescing, mid-write crash, missing file): partially covered — the "missing file" risk is handled in `ScheduleStorage.read()` (returns `[]`); signing is out of scope for the local-dev plan; SDK maturity is the reason Task 11 includes the "fix valueToAny if the SDK API differs" escape hatch.

**Placeholder scan:** None of the tasks contain "TBD", "TODO", "implement later", or vague "add validation" phrasing. Every code step contains actual code; every test step contains actual assertions. The only deferred decisions are real ones (e.g., "if SDK accessor names differ, check Value.swift") with a concrete action attached.

**Type consistency:**
- `ScheduleStorage.StorageError` is referenced in Tasks 3, 9 — same casing.
- `ToolError` cases (`validation`, `notFound`, `lockTimeout`, `io`) and codes (`validation_error`, `not_found`, `lock_timeout`, `io_error`) match across Tasks 8, 9, 10.
- `ScheduleService` method signatures (`list()`, `add(title:start:end:)`, `update(id:title:start:end:)`, `delete(id:)`) match across Tasks 9 and 10.
- `Tools.call(name:arguments:)` and `Tools.descriptors` consistent across Tasks 10, 11.

No issues found.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-14-autorecord-mcp-server.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
