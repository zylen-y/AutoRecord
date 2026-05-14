import Foundation

/// Reads and writes Claude Desktop's `claude_desktop_config.json` to register
/// this app's bundled `autorecord-mcp` binary as an MCP server, without disturbing
/// any other keys the user already has in the file.
enum MCPInstallService {
    static let claudeConfigURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Claude/claude_desktop_config.json")
    }()

    static let serverKey = "autorecord"

    enum InstallStatus: Equatable {
        case claudeConfigMissing
        case notInstalled
        case installedCurrent
        case installedStale(existingPath: String)
        case readError(String)
    }

    enum InstallError: Error {
        case bundleResourceMissing
        case writeFailed(String)
        case readFailed(String)
    }

    /// Path to the embedded `autorecord-mcp` binary for the running app bundle.
    static var bundleBinaryPath: String? {
        Bundle.main.resourceURL?.appendingPathComponent("autorecord-mcp").path
    }

    /// Inspects the current state without modifying anything.
    static func currentStatus() -> InstallStatus {
        guard FileManager.default.fileExists(atPath: claudeConfigURL.path) else {
            return .claudeConfigMissing
        }
        guard let desired = bundleBinaryPath else {
            return .readError("Bundle resource URL unavailable")
        }
        do {
            let data = try Data(contentsOf: claudeConfigURL)
            guard !data.isEmpty,
                  let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .notInstalled
            }
            let servers = root["mcpServers"] as? [String: Any]
            guard let entry = servers?[serverKey] as? [String: Any],
                  let command = entry["command"] as? String else {
                return .notInstalled
            }
            return command == desired ? .installedCurrent : .installedStale(existingPath: command)
        } catch {
            return .readError(String(describing: error))
        }
    }

    /// Adds or updates the `mcpServers.autorecord` entry to point at the current
    /// bundle. Preserves every other top-level key and every other server entry.
    /// Creates the file (and its parent directory) if missing.
    static func installOrUpdate() throws {
        guard let desired = bundleBinaryPath else {
            throw InstallError.bundleResourceMissing
        }

        var root: [String: Any]
        if FileManager.default.fileExists(atPath: claudeConfigURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: claudeConfigURL)
            } catch {
                throw InstallError.readFailed(String(describing: error))
            }
            if data.isEmpty {
                root = [:]
            } else {
                do {
                    root = try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                } catch {
                    throw InstallError.readFailed(String(describing: error))
                }
            }
        } else {
            root = [:]
        }

        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers[serverKey] = ["command": desired]
        root["mcpServers"] = servers

        let parent = claudeConfigURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        do {
            let out = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            let tmp = claudeConfigURL.appendingPathExtension("tmp")
            try out.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(claudeConfigURL, withItemAt: tmp)
        } catch {
            throw InstallError.writeFailed(String(describing: error))
        }
    }
}
