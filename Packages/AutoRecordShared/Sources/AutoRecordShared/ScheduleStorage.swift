import Foundation
#if canImport(Darwin)
import Darwin
#endif

public final class ScheduleStorage {
    public enum StorageError: Error, Equatable {
        case lockTimeout
        case ioFailure(String)
        case decodeFailure(String)
    }

    public let fileURL: URL
    public let lockTimeoutSeconds: TimeInterval

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL = AppPaths.schedulesFile, lockTimeoutSeconds: TimeInterval = 2.0) {
        self.fileURL = fileURL
        self.lockTimeoutSeconds = lockTimeoutSeconds
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        self.encoder = e
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
    }

    /// Reads all schedules. Missing file returns []. Acquires a shared lock.
    public func read() throws -> [Schedule] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try withLock(exclusive: false) {
            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else { return [] }
            do {
                return try decoder.decode([Schedule].self, from: data)
            } catch {
                throw StorageError.decodeFailure(String(describing: error))
            }
        }
    }

    /// Writes schedules sorted by `start` ascending. Acquires an exclusive lock,
    /// writes to a sibling `.tmp` file, and atomically renames into place.
    public func write(_ schedules: [Schedule]) throws {
        let sorted = schedules.sorted { $0.start < $1.start }
        try withLock(exclusive: true) {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data: Data
            do {
                data = try encoder.encode(sorted)
            } catch {
                throw StorageError.ioFailure(String(describing: error))
            }
            let tmp = fileURL.appendingPathExtension("tmp")
            do {
                try data.write(to: tmp, options: .atomic)
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                throw StorageError.ioFailure(String(describing: error))
            }
            return ()
        }
    }

    // MARK: - Lock helper

    private func withLock<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
        // Open (or create) the file so flock has something to lock.
        let fd = open(fileURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw StorageError.ioFailure("open failed: errno \(errno)")
        }
        defer { close(fd) }

        let op = (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB
        let deadline = Date().addingTimeInterval(lockTimeoutSeconds)
        while true {
            if flock(fd, op) == 0 { break }
            if errno != EWOULDBLOCK {
                throw StorageError.ioFailure("flock errno \(errno)")
            }
            if Date() >= deadline {
                throw StorageError.lockTimeout
            }
            usleep(20_000) // 20ms
        }
        defer { _ = flock(fd, LOCK_UN) }

        return try body()
    }
}
