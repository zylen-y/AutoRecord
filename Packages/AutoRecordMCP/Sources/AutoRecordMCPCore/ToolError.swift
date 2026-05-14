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
