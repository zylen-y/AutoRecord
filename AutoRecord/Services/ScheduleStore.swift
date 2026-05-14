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
            // If the file was renamed/deleted (atomic write replaces the inode),
            // reopen the watcher on the new path after reloading.
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
