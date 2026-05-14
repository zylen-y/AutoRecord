import XCTest
@testable import AutoRecord

@MainActor
final class ScheduleStoreTests: XCTestCase {
    func testAddUpdateDeleteRoundTripsToDisk() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ar-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ScheduleStore(fileURL: tmp)
        XCTAssertTrue(store.schedules.isEmpty)

        let now = Date()
        let s1 = Schedule(title: "Earlier", start: now.addingTimeInterval(60), end: now.addingTimeInterval(120))
        let s2 = Schedule(title: "Later", start: now.addingTimeInterval(300), end: now.addingTimeInterval(600))
        store.add(s2)
        store.add(s1)

        // Sorted by start
        XCTAssertEqual(store.schedules.map(\.title), ["Earlier", "Later"])

        // Reload from disk
        let store2 = ScheduleStore(fileURL: tmp)
        XCTAssertEqual(store2.schedules.map(\.title), ["Earlier", "Later"])

        // Update
        var updated = s1
        updated.title = "Renamed"
        store2.update(updated)
        XCTAssertEqual(store2.schedules.first { $0.id == s1.id }?.title, "Renamed")

        // Delete
        store2.delete(id: s2.id)
        XCTAssertEqual(store2.schedules.count, 1)
    }

    func testStatusComputation() {
        let now = Date()
        let upcoming = Schedule(title: "u", start: now.addingTimeInterval(60), end: now.addingTimeInterval(120))
        let active = Schedule(title: "a", start: now.addingTimeInterval(-30), end: now.addingTimeInterval(60))
        let past = Schedule(title: "p", start: now.addingTimeInterval(-120), end: now.addingTimeInterval(-60))
        XCTAssertEqual(upcoming.status(now: now), .upcoming)
        XCTAssertEqual(active.status(now: now), .active)
        XCTAssertEqual(past.status(now: now), .past)
    }
}
