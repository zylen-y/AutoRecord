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
        let writerCount = 50
        let expectedTitles: Set<String> = Set((0..<writerCount).map { "Writer\($0)" })
        let q = DispatchQueue(label: "concurrent", attributes: .concurrent)
        let g = DispatchGroup()
        for i in 0..<writerCount {
            let title = "Writer\(i)"
            let storageN = ScheduleStorage(fileURL: fileURL)
            q.async(group: g) {
                let s = Schedule(
                    title: title,
                    start: Date(timeIntervalSince1970: TimeInterval(100 + i)),
                    end: Date(timeIntervalSince1970: TimeInterval(200 + i))
                )
                try? storageN.write([s])
            }
        }
        g.wait()

        // The on-disk file must decode (no torn writes) and contain exactly one
        // schedule whose title comes from the expected set (no garbage entry, no
        // mixed state). Which writer wins is OS-scheduling-dependent and not asserted.
        let final = try storage.read()
        XCTAssertEqual(final.count, 1, "Expected exactly one surviving schedule after 50 serialized last-writer-wins writes")
        if let winner = final.first {
            XCTAssertTrue(expectedTitles.contains(winner.title), "Surviving title \(winner.title) is not in the expected set")
        }
    }

    func testReadOnCorruptFileThrowsDecodeFailure() throws {
        // Write garbage bytes that are not valid JSON.
        try Data("not-valid-json".utf8).write(to: fileURL)
        XCTAssertThrowsError(try storage.read()) { error in
            guard case ScheduleStorage.StorageError.decodeFailure = error else {
                return XCTFail("Expected decodeFailure, got \(error)")
            }
        }
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
