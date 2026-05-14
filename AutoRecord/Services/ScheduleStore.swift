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

    /// Reload from disk. Called on init and (in Task 5) from the file watcher.
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
