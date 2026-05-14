import XCTest
@testable import AutoRecordMCPCore

final class ISO8601Tests: XCTestCase {
    func testParsesUTCZuluForm() throws {
        let d = try ISO8601.parse("2026-05-15T09:00:00Z")
        XCTAssertEqual(d.timeIntervalSince1970, 1778835600)
    }

    func testParsesPositiveOffset() throws {
        let d = try ISO8601.parse("2026-05-15T18:00:00+09:00")
        XCTAssertEqual(d.timeIntervalSince1970, 1778835600)
    }

    func testParsesFractionalSeconds() throws {
        let d = try ISO8601.parse("2026-05-15T09:00:00.500Z")
        XCTAssertEqual(d.timeIntervalSince1970, 1778835600.5, accuracy: 0.001)
    }

    func testRejectsNonISOInput() {
        XCTAssertThrowsError(try ISO8601.parse("tomorrow at noon"))
        XCTAssertThrowsError(try ISO8601.parse("2026-05-15"))
        XCTAssertThrowsError(try ISO8601.parse(""))
    }

    func testFormatRoundTripsViaUTC() {
        let d = Date(timeIntervalSince1970: 1778835600)
        let s = ISO8601.format(d)
        XCTAssertEqual(try ISO8601.parse(s), d)
    }
}
