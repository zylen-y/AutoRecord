import Foundation
import AutoRecordShared

public final class Tools {
    /// Tool descriptor. `[String: Any]` for the schema is not statically `Sendable`,
    /// but descriptors are constructed inside this actor-free type and serialised on
    /// the wire by the SDK before crossing actor boundaries, so the runtime guarantee
    /// holds. Marked `@unchecked Sendable` to silence strict-concurrency warnings.
    public struct Descriptor: @unchecked Sendable {
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
        var s = String(decoding: data, as: UTF8.self)
        // `.prettyPrinted` renders empty arrays as "[\n\n  ]" on Darwin; collapse
        // them to "[]" so MCP clients (and tests) see compact empty arrays.
        if let regex = try? NSRegularExpression(pattern: #"\[\s*\n\s*\]"#) {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: "[]")
        }
        return s
    }
}
