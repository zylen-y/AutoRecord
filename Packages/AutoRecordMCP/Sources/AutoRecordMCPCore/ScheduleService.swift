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
        // Truncate createdAt to whole-seconds so the returned value compares equal
        // to the post-roundtrip value (ScheduleStorage's JSONEncoder.iso8601 strategy
        // drops sub-second precision). Without this, callers using `==` on createdAt
        // across an add/update boundary would fail.
        let createdAt = Date(timeIntervalSince1970: trunc(Date().timeIntervalSince1970))
        let schedule = Schedule(title: trimmed, start: startDate, end: endDate, createdAt: createdAt)
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
