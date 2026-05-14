import XCTest
import AutoRecordShared
@testable import AutoRecordMCPCore

final class ToolsTests: XCTestCase {
    var tmp: URL!
    var tools: Tools!

    override func setUp() {
        super.setUp()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TT-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let storage = ScheduleStorage(fileURL: tmp.appendingPathComponent("schedules.json"))
        tools = Tools(service: ScheduleService(storage: storage))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    func testDescriptorsListsAllFourTools() {
        let names = Set(tools.descriptors.map(\.name))
        XCTAssertEqual(names, ["list_schedules", "add_schedule", "update_schedule", "delete_schedule"])
    }

    func testCallListSchedulesOnEmptyReturnsEmptyArray() throws {
        let result = try tools.call(name: "list_schedules", arguments: [:])
        XCTAssertTrue(result.contains("\"schedules\""))
        XCTAssertTrue(result.contains("[]"))
    }

    func testCallAddScheduleReturnsScheduleWithIDAndStatus() throws {
        let result = try tools.call(name: "add_schedule", arguments: [
            "title": "Demo",
            "start": "2099-01-01T09:00:00Z",
            "end":   "2099-01-01T09:30:00Z"
        ])
        XCTAssertTrue(result.contains("\"title\" : \"Demo\""))
        XCTAssertTrue(result.contains("\"status\" : \"upcoming\""))
        XCTAssertTrue(result.contains("\"id\""))
    }

    func testCallUpdateRequiresKnownID() throws {
        XCTAssertThrowsError(try tools.call(name: "update_schedule", arguments: [
            "id": UUID().uuidString,
            "title": "X"
        ])) {
            XCTAssertEqual(($0 as? ToolError)?.code, "not_found")
        }
    }

    func testCallDeleteRemovesSchedule() throws {
        let added = try tools.call(name: "add_schedule", arguments: [
            "title": "X",
            "start": "2099-01-01T09:00:00Z",
            "end":   "2099-01-01T09:30:00Z"
        ])
        // Extract the id (lazy regex; deterministic field name).
        let idLine = added.split(separator: "\n").first(where: { $0.contains("\"id\"") })!
        let id = String(idLine.split(separator: "\"")[3])

        _ = try tools.call(name: "delete_schedule", arguments: ["id": id])
        let listed = try tools.call(name: "list_schedules", arguments: [:])
        XCTAssertTrue(listed.contains("[]"))
    }

    func testCallUnknownToolThrowsValidationError() {
        XCTAssertThrowsError(try tools.call(name: "blah", arguments: [:])) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }

    func testCallAddRequiresAllThreeArguments() {
        XCTAssertThrowsError(try tools.call(name: "add_schedule", arguments: ["title": "X"])) {
            XCTAssertEqual(($0 as? ToolError)?.code, "validation_error")
        }
    }
}
