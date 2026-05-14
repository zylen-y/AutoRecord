import XCTest
@testable import AutoRecordShared

final class ScheduleStorageTests: XCTestCase {
    var tmpDir: URL!
    var fileURL: URL!
    var storage: ScheduleStorage!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AutoRecordStorageTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        fileURL = tmpDir.appendingPathComponent("schedules.json")
        storage = ScheduleStorage(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func testReadReturnsEmptyArrayWhenFileMissing() throws {
        XCTAssertEqual(try storage.read(), [])
    }

    func testWriteThenReadRoundTrips() throws {
        let s = Schedule(title: "Demo", start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 2000))
        try storage.write([s])
        let read = try storage.read()
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].id, s.id)
        XCTAssertEqual(read[0].title, "Demo")
    }

    func testWriteIsAtomic_TempFileIsRemovedOnSuccess() throws {
        let s = Schedule(title: "T", start: Date(), end: Date().addingTimeInterval(60))
        try storage.write([s])
        let tmp = fileURL.appendingPathExtension("tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
    }

    func testWriteSortsByStartAscending() throws {
        let later = Schedule(title: "B", start: Date(timeIntervalSince1970: 2000), end: Date(timeIntervalSince1970: 3000))
        let earlier = Schedule(title: "A", start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 1500))
        try storage.write([later, earlier])
        let read = try storage.read()
        XCTAssertEqual(read.map(\.title), ["A", "B"])
    }

    func testConcurrentWritesAreSerialized() throws {
        // Two ScheduleStorage instances on the same file: both should succeed,
        // and the final state should contain a non-empty valid JSON document.
        let storage2 = ScheduleStorage(fileURL: fileURL)
        let a = Schedule(title: "A", start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
        let b = Schedule(title: "B", start: Date(timeIntervalSince1970: 300), end: Date(timeIntervalSince1970: 400))
        let q = DispatchQueue(label: "concurrent", attributes: .concurrent)
        let g = DispatchGroup()
        q.async(group: g) { try? self.storage.write([a]) }
        q.async(group: g) { try? storage2.write([b]) }
        g.wait()
        let final = try storage.read()
        XCTAssertFalse(final.isEmpty)
    }

    func testLockTimeoutThrowsLockTimeoutError() throws {
        // Hold the file's flock manually, then attempt a write with a tight timeout.
        let fd = open(fileURL.path, O_RDWR | O_CREAT, 0o644)
        XCTAssertNotEqual(fd, -1)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        defer { _ = flock(fd, LOCK_UN) }

        let tightStorage = ScheduleStorage(fileURL: fileURL, lockTimeoutSeconds: 0.1)
        let s = Schedule(title: "X", start: Date(), end: Date().addingTimeInterval(60))
        XCTAssertThrowsError(try tightStorage.write([s])) { error in
            guard case ScheduleStorage.StorageError.lockTimeout = error else {
                return XCTFail("Expected lockTimeout, got \(error)")
            }
        }
    }
}
