import Foundation
import Combine

@MainActor
final class ScheduleStore: ObservableObject {
    @Published private(set) var schedules: [Schedule] = []

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL = AppPaths.schedulesFile) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        load()
    }

    func add(_ schedule: Schedule) {
        schedules.append(schedule)
        sortAndSave()
    }

    func update(_ schedule: Schedule) {
        guard let idx = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[idx] = schedule
        sortAndSave()
    }

    func delete(id: UUID) {
        schedules.removeAll { $0.id == id }
        save()
    }

    func schedule(id: UUID) -> Schedule? {
        schedules.first { $0.id == id }
    }

    func nextUpcoming(now: Date = Date()) -> Schedule? {
        schedules
            .filter { $0.start > now }
            .min(by: { $0.start < $1.start })
    }

    func activeSchedule(now: Date = Date()) -> Schedule? {
        schedules.first { $0.status(now: now) == .active }
    }

    private func sortAndSave() {
        schedules.sort { $0.start < $1.start }
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try decoder.decode([Schedule].self, from: data)
            self.schedules = decoded.sorted { $0.start < $1.start }
        } catch {
            NSLog("ScheduleStore: failed to load schedules: \(error)")
        }
    }

    private func save() {
        do {
            let data = try encoder.encode(schedules)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("ScheduleStore: failed to save schedules: \(error)")
        }
    }
}
