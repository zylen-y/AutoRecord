import XCTest
import AutoRecordShared
@testable import AutoRecordMCPCore

final class ScheduleServiceTests: XCTestCase {
    var tmp: URL!
    var service: ScheduleService!

    override func setUp() {
        super.setUp()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SS-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let storage = ScheduleStorage(fileURL: tmp.appendingPathComponent("schedules.json"))
        service = ScheduleService(storage: storage)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - list

    func testListReturnsEmptyInitially() throws {
        XCTAssertEqual(try service.list().count, 0)
    }

    // MARK: - add

    func testAddCreatesScheduleAndAssignsID() throws {
        let s = try service.add(
            title: "Demo",
            start: "2026-05-15T09:00:00Z",
            end:   "2026-05-15T09:30:00Z"
        )
        XCTAssertEqual(s.title, "Demo")
        XCTAssertEqual(try service.list().count, 1)
    }

    func testAddTrimsTitle() throws {
        let s = try service.add(title: "  Demo  ", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:30:00Z")
        XCTAssertEqual(s.title, "Demo")
    }

    func testAddRejectsEmptyTitle() {
        XCTAssertThrowsError(try service.add(title: "   ", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:30:00Z")) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }

    func testAddRejectsEndBeforeStart() {
        XCTAssertThrowsError(try service.add(title: "Demo", start: "2026-05-15T09:30:00Z", end: "2026-05-15T09:00:00Z")) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }

    func testAddRejectsEndEqualToStart() {
        XCTAssertThrowsError(try service.add(title: "Demo", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:00:00Z")) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }

    func testAddRejectsUnparseableDate() {
        XCTAssertThrowsError(try service.add(title: "Demo", start: "tomorrow", end: "2026-05-15T09:00:00Z")) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }

    // MARK: - update

    func testUpdateChangesTitle() throws {
        let s = try service.add(title: "Old", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:30:00Z")
        let updated = try service.update(id: s.id.uuidString, title: "New", start: nil, end: nil)
        XCTAssertEqual(updated.title, "New")
        XCTAssertEqual(updated.id, s.id)
        XCTAssertEqual(try service.list().first?.title, "New")
    }

    func testUpdateRejectsUnknownId() {
        XCTAssertThrowsError(try service.update(id: UUID().uuidString, title: "x", start: nil, end: nil)) {
            XCTAssertEqual(($0 as? ToolError)?.code, "not_found")
        }
    }

    func testUpdateRejectsInvalidDate() throws {
        let s = try service.add(title: "X", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:30:00Z")
        XCTAssertThrowsError(try service.update(id: s.id.uuidString, title: nil, start: "yesterday", end: nil)) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }

    func testUpdateRejectsResultingEndBeforeStart() throws {
        let s = try service.add(title: "X", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:30:00Z")
        XCTAssertThrowsError(try service.update(id: s.id.uuidString, title: nil, start: "2026-05-15T10:00:00Z", end: nil)) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }

    func testUpdateDoesNotChangeCreatedAt() throws {
        let s = try service.add(title: "X", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:30:00Z")
        let updated = try service.update(id: s.id.uuidString, title: "Y", start: nil, end: nil)
        XCTAssertEqual(updated.createdAt, s.createdAt)
    }

    // MARK: - delete

    func testDeleteRemovesSchedule() throws {
        let s = try service.add(title: "X", start: "2026-05-15T09:00:00Z", end: "2026-05-15T09:30:00Z")
        try service.delete(id: s.id.uuidString)
        XCTAssertEqual(try service.list().count, 0)
    }

    func testDeleteRejectsUnknownId() {
        XCTAssertThrowsError(try service.delete(id: UUID().uuidString)) {
            XCTAssertEqual(($0 as? ToolError)?.code, "not_found")
        }
    }

    func testDeleteRejectsMalformedUUID() {
        XCTAssertThrowsError(try service.delete(id: "not-a-uuid")) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }
}
