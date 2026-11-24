import Foundation
import Darwin

/// Only consumption markers live here. Buffer/layout/launch records use IStorageService.
/// A claim is durable before spawn: uncertain requests are never automatically retried.
final class NativeTerminalRevival {
    let incarnation = UUID().uuidString
    private let directory: URL
    private(set) var revived: [String: Int] = [:]
    private(set) var revivedIdentities: [String: String] = [:]

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TerminalRevivalClaims", isDirectory: true)) {
        self.directory = directory
    }

    static func validateLaunch(_ value: [String: Any]) throws {
        guard Set(value.keys) == ["shellLaunchConfig", "options"],
              value["shellLaunchConfig"] is [String: Any], let options = value["options"] as? [String: Any],
              let integration = options["shellIntegration"] as? [String: Any], integration["nonce"] is String,
              JSONSerialization.isValidJSONObject(value),
              try JSONSerialization.data(withJSONObject: value).count <= 256 * 1024 else {
            throw NativeTerminalHostError.invalidRequest("invalid saved terminal launch")
        }
    }

    static func validate(_ value: [String: Any], incarnation: String) throws -> String {
        guard Set(value.keys).isSubset(of: ["token", "sourceIncarnation", "data", "commands"]),
              value["commands"] == nil || value["commands"] is [String: Any],
              let token = value["token"] as? String,
              let source = value["sourceIncarnation"] as? String, UUID(uuidString: source) != nil, source != incarnation,
              let data = value["data"] as? String, data.utf8.count <= 8 * 1024 * 1024,
              JSONSerialization.isValidJSONObject(value),
              try JSONSerialization.data(withJSONObject: value["commands"] as? [String: Any] ?? [:]).count <= 256 * 1024 else {
            throw NativeTerminalHostError.invalidRequest("invalid revival request")
        }
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
              let id = UInt64(parts[1]), id > 0, id <= 9_007_199_254_740_991,
              String(id) == parts[1] else { throw NativeTerminalHostError.invalidRequest("invalid revival token") }
        return token
    }

    func claim(_ token: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(token.replacingOccurrences(of: ":", with: "-")).path
        let fd = path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR) }
        guard fd >= 0 else { throw NativeTerminalHostError.invalidRequest("revival already consumed or journal unavailable") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw NativeTerminalHostError.invalidRequest("revival claim could not be persisted") }
        let parent = directory.path.withCString { open($0, O_RDONLY) }
        guard parent >= 0 else { throw NativeTerminalHostError.invalidRequest("revival journal unavailable") }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw NativeTerminalHostError.invalidRequest("revival journal could not be persisted") }
    }

    func record(_ token: String, sessionId: Int, processIdentity: String) {
        revived[token] = sessionId
        revivedIdentities[token] = processIdentity
    }
}
