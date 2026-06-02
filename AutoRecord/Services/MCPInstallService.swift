import Foundation

/// Reads and writes an MCP client's config JSON to register this app's bundled
/// `autorecord-mcp` binary as a server, without disturbing any other keys the
/// user already has. Supports multiple MCP clients via preconfigured static
/// instances (see `claudeDesktop`, `claudeCode`).
struct MCPInstallService {
    let configURL: URL
    let serverKey: String
    let clientName: String

    static let claudeDesktop = MCPInstallService(
        configURL: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Claude/claude_desktop_config.json"),
        serverKey: "autorecord",
        clientName: "Claude Desktop"
    )

    static let claudeCode = MCPInstallService(
        configURL: FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json"),
        serverKey: "autorecord",
        clientName: "Claude Code"
    )

    enum InstallStatus: Equatable {
        case configMissing
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
    func currentStatus() -> InstallStatus {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return .configMissing
        }
        guard let desired = Self.bundleBinaryPath else {
            return .readError("Bundle resource URL unavailable")
        }
        do {
            let data = try Data(contentsOf: configURL)
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

    /// Adds or updates `mcpServers.<serverKey>` to point at the current bundle.
    /// Preserves every other top-level key and every other server entry.
    /// Creates the file (and its parent directory) if missing.
    func installOrUpdate() throws {
        guard let desired = Self.bundleBinaryPath else {
            throw InstallError.bundleResourceMissing
        }

        var root: [String: Any]
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: configURL)
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

        let parent = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        do {
            let out = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys]
            )
            let tmp = configURL.appendingPathExtension("tmp")
            try out.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmp)
        } catch {
            throw InstallError.writeFailed(String(describing: error))
        }
    }
}
