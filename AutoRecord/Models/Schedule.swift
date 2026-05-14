import Foundation

struct Schedule: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var start: Date
    var end: Date
    var createdAt: Date

    init(id: UUID = UUID(), title: String, start: Date, end: Date, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.createdAt = createdAt
    }

    enum Status {
        case upcoming
        case active
        case past
    }

    func status(now: Date = Date()) -> Status {
        if now < start { return .upcoming }
        if now >= end { return .past }
        return .active
    }
}
