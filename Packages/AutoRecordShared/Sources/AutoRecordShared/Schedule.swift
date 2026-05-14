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
