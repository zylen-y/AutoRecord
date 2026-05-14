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
