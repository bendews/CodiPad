import Darwin
import Foundation
import CoreFoundation
import CodiPadWorkspace

/// A long canonical iPad directory can exceed Linux AF_UNIX pathname limits.
enum NativeProcessRuntime {
    case embedded, linux

    func temporaryDirectory(nativeDirectory: String) -> String {
        switch self {
        case .embedded: return nativeDirectory
        case .linux: return "/tmp"
        }
    }
}

private let terminalOutputByteLimit = Int(CODIPAD_TERMINAL_OUTPUT_MAX_BYTES)
private let terminalOutputEventLimit = Int(CODIPAD_TERMINAL_OUTPUT_MAX_EVENTS)

/// The pty host's JSON launch envelope. Limits apply before mounting or allocating a process.
/// Launch identity cannot be overwritten by the presentation-update RPC.
enum NativeTerminalMetadata {
    private static func invalid() -> NativeTerminalHostError { .invalidRequest("invalid or oversized terminal restoration metadata") }
    private static func object(_ v: Any, _ fields: Set<String>) -> [String: Any]? {
        guard let d = v as? [String: Any], Set(d.keys).isSubset(of: fields) else { return nil }; return d
    }
    private static func optional(_ d: [String: Any], _ k: String, _ check: (Any) -> Bool) -> Bool { d[k].map(check) ?? true }
    private static func string(_ v: Any) -> Bool { v is String }
    private static func boolean(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    private static func integer(_ v: Any, _ min: Double, _ max: Double) -> Bool {
        guard let n = v as? NSNumber, !boolean(n) else { return false }
        let x = n.doubleValue; return x.isFinite && x.rounded(.towardZero) == x && x >= min && x <= max
    }
    private static func uri(_ v: Any) -> Bool {
        guard let d = object(v, ["$mid", "scheme", "authority", "path", "query", "fragment", "fsPath", "external"]), d["scheme"] is String else { return false }
        return ["authority", "path", "query", "fragment", "fsPath", "external"].allSatisfy { optional(d, $0, string) } && optional(d, "$mid") { integer($0, 1, 1) }
    }
    private static func themeIcon(_ v: Any) -> Bool {
        guard let d = object(v, ["id", "color"]), d["id"] is String else { return false }
        return optional(d, "color") { object($0, ["id"])?["id"] is String }
    }
    private static func icon(_ v: Any) -> Bool {
        if themeIcon(v) || uri(v) { return true }
        guard let d = object(v, ["light", "dark"]), let light = d["light"], let dark = d["dark"] else { return false }
        return uri(light) && uri(dark)
    }
    private static func dimensions(_ v: Any) -> Bool {
        guard let d = object(v, ["cols", "rows"]) else { return false }
        return optional(d, "cols") { integer($0, 1, 1000) } && optional(d, "rows") { integer($0, 1, 500) }
    }
    private static func scope(_ v: Any) -> Bool {
        guard let d = object(v, ["workspaceFolder"]) else { return false }
        return optional(d, "workspaceFolder") {
            guard let f = object($0, ["uri", "name", "index"]), let u = f["uri"], let i = f["index"], f["name"] is String else { return false }
            return uri(u) && integer(i, 0, 9_007_199_254_740_991)
        }
    }
    private static func pairs(_ v: Any, _ check: (Any) -> Bool) -> Bool {
        guard let a = v as? [[Any]] else { return false }
        var seen = Set<String>()
        return a.allSatisfy { e in
            guard e.count == 2, let key = e[0] as? String, seen.insert(key).inserted else { return false }
            return check(e[1])
        }
    }
    private static func collections(_ v: Any) -> Bool {
        guard let a = v as? [[Any]] else { return false }
        var seen = Set<String>()
        return a.allSatisfy { e in
            guard e.count == 3, let key = e[0] as? String, seen.insert(key).inserted else { return false }
            return pairs(e[1]) { value in
                guard let m = object(value, ["variable", "value", "type", "scope", "options"]), m["variable"] is String, m["value"] is String, let type = m["type"] else { return false }
                return integer(type, 1, 3) && optional(m, "scope", scope) && optional(m, "options") {
                    guard let o = object($0, ["applyAtProcessCreation", "applyAtShellIntegration"]) else { return false }; return o.values.allSatisfy(boolean)
                }
            } && pairs(e[2]) { value in
                guard let d = object(value, ["description", "scope"]) else { return false }
                return optional(d, "description", string) && optional(d, "scope", scope)
            }
        }
    }
    static func validate(_ value: [String: Any], launch: Bool) throws -> [String: Any] {
        var nodes = 0
        func visit(_ v: Any, _ depth: Int) throws {
            nodes += 1
            guard nodes <= 16384, depth <= 32 else { throw invalid() }
            if let s = v as? String { guard s.utf8.count <= 256 * 1024 else { throw invalid() }; return }
            if let n = v as? NSNumber { guard n.doubleValue.isFinite else { throw invalid() }; return }
            if v is NSNull { return }
            if let a = v as? [Any] { for item in a { try visit(item, depth + 1) }; return }
            if let d = v as? [String: Any] { for (key, item) in d { try visit(key, depth + 1); try visit(item, depth + 1) }; return }
            throw invalid()
        }
        try visit(value, 0)
        let presentation: Set<String> = ["title", "titleSource", "icon", "color", "fixedDimensions"]
        let launchFields: Set<String> = ["workspaceName", "environmentVariableCollections", "reconnectionProperties", "waitOnExit", "hideFromUser", "isFeatureTerminal", "type", "tabActions"]
        guard object(value, launch ? presentation.union(launchFields) : presentation) != nil,
              optional(value, "title", string), optional(value, "titleSource", { integer($0, 0, 3) }),
              optional(value, "icon", icon), optional(value, "color", { $0 is NSNull || string($0) }),
              optional(value, "fixedDimensions", dimensions) else { throw invalid() }
        if launch {
            guard value["workspaceName"] is String, optional(value, "environmentVariableCollections", collections),
                  optional(value, "reconnectionProperties", { object($0, ["ownerId", "data"])?["ownerId"] is String }),
                  optional(value, "waitOnExit", { boolean($0) || string($0) }), optional(value, "hideFromUser", boolean),
                  optional(value, "isFeatureTerminal", boolean), optional(value, "type", { ["Task", "Local"].contains($0 as? String ?? "") }),
                  optional(value, "tabActions", { v in
                      guard let a = v as? [[String: Any]] else { return false }
                      return a.allSatisfy { object($0, ["id", "label", "icon"]) != nil && $0["id"] is String && $0["label"] is String && optional($0, "icon", themeIcon) }
                  }) else { throw invalid() }
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        guard data.count <= 256 * 1024 else { throw invalid() }
        // Value semantics and JSON decoding prevent retention of a caller-owned NSMutableDictionary.
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}

/// Native terminal host over the one app-owned process authority (`native/CodiPadProcess/IshKernel.h`).
///
/// Transport/bookkeeping only: no second process model, no second workspace, no workspace copy.
/// Fresh terminal profiles use `/bin/bash`; `create` preserves the requested guest executable.
/// The first create boots the guest kernel with the bundled rootfs
/// and mounts authorized Linux workspaces at their canonical native paths. The embedded backend
/// retains its one-workspace `/workspace` compatibility alias. Output is copied off the guest
/// thread and emitted as `terminal.data`. `terminal.exit`
/// is emitted only after `codipad_kernel_close()` returns 0, i.e. the authority reaped the session;
/// a close ACK alone never fabricates an exit. `terminal.error` names failures.
///
/// Lifetime limit: the iSH kernel is process-wide and never torn down, so the shared
/// filesystem/scope owner passed to `init` is retained for the mounted kernel's lifetime, not just
/// while terminals are open. There is no app-level kernel shutdown.
final class NativeTerminalHost {
    typealias EventHandler = ([String: Any]) -> Void

    /// Delivered on the main queue: `terminal.data`, `terminal.exit`, `terminal.error`.
    var onEvent: EventHandler?

    static let shellExecutable = "/bin/bash"
    static let guestWorkspace = "/workspace"

    /// Linux process defaults are per-launch snapshots; never written to the app process env.
    private static let guestEnvironmentBase: [String: String] = [
        "TERM": "xterm-256color",
        "SHELL": shellExecutable,
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "LANG": "C.UTF-8",
    ]

    private let ioQueue = DispatchQueue(label: "dev.codipad.terminal", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private let leaseOwner: WorkspaceFileSystem
    private let processRuntime: NativeProcessRuntime

    private var sessions: [UInt64: SessionRecord] = [:]
    private var autoReplies: [String: String] = [:]
    private let revivalJournal = NativeTerminalRevival()
    private var rendererPage: String?
    private var layouts: [String: [String: Any]] = [:]
    private var cleanupIncompleteFlag = false
    private var preparedEnvironment: [String: String]?

    private let maxPendingOutputBytes = terminalOutputByteLimit
    private let maxPendingOutputEvents = terminalOutputEventLimit
    private let maxInputBytes = 4 * 1024 * 1024
    private let maxInputEvents = 4096
    private let maxCwdBytes = 4096

    private static let activeLock = NSLock()
    /// Strong hold while any C session record can still call back. Incomplete cleanup quarantines
    /// the host here instead of letting ARC drop the callback contexts under the authority.
    private static var activeHosts: [NativeTerminalHost] = []
    private struct TransferOwner {
        let source: NativeTerminalHost
        let target: NativeTerminalHost
        let workspace: String
    }
    private static let transferLock = NSLock()
    private static var transferred: [Int: TransferOwner] = [:]

    static func transferredHost(sessionId: Int, target: NativeTerminalHost) -> NativeTerminalHost? {
        transferLock.lock(); defer { transferLock.unlock() }
        guard let owner = transferred[sessionId], owner.target === target else { return nil }
        return owner.source
    }

    static func routeHandoff(sessionId: Int, source: NativeTerminalHost,
                             previous: NativeTerminalHost, target: NativeTerminalHost, workspace: String) throws {
        transferLock.lock(); defer { transferLock.unlock() }
        if let owner = transferred[sessionId] {
            guard owner.source === source, owner.target === previous else {
                throw NativeTerminalHostError.invalidRequest("terminal already has another owner")
            }
        } else if source !== previous {
            throw NativeTerminalHostError.invalidRequest("terminal owner changed during handoff")
        }
        transferred[sessionId] = TransferOwner(source: source, target: target, workspace: workspace)
    }

    static func restoreHandoffRoute(sessionId: Int, source: NativeTerminalHost,
                                    previous: NativeTerminalHost, target: NativeTerminalHost, workspace: String) {
        transferLock.lock(); defer { transferLock.unlock() }
        guard let owner = transferred[sessionId], owner.source === source, owner.target === target else { return }
        transferred[sessionId] = previous === source ? nil : TransferOwner(source: source, target: previous, workspace: workspace)
    }

    static func releaseHandoff(sessionId: Int, source: NativeTerminalHost) {
        transferLock.lock(); defer { transferLock.unlock() }
        if transferred[sessionId]?.source === source { transferred[sessionId] = nil }
    }

    private static func borrowedSessions(target: NativeTerminalHost, workspace: String? = nil) -> [(Int, NativeTerminalHost)] {
        transferLock.lock(); defer { transferLock.unlock() }
        return transferred.compactMap { id, owner in
            guard owner.target === target, workspace == nil || owner.workspace == workspace else { return nil }
            return (id, owner.source)
        }
    }

    static func transferredHost(identity: String, target: NativeTerminalHost, workspace: String) -> NativeTerminalHost? {
        for (id, source) in borrowedSessions(target: target, workspace: workspace) {
            if (try? source.onSessionQueue(id) { source.processIdentity(try source.session(id)) }) == identity { return source }
        }
        return nil
    }

    func updateBorrowedAutoReplies(match: String? = nil, reply: String? = nil) throws {
        for (id, owner) in Self.borrowedSessions(target: self) {
            if let match, let reply { try owner.installAutoReply(sessionId: id, match: match, reply: reply) }
            else { try owner.uninstallAllAutoReplies(sessionId: id) }
        }
    }

    func copyAutoReplies(to owner: NativeTerminalHost, sessionId: Int) throws {
        let rules = onQueue { autoReplies }
        try owner.uninstallAllAutoReplies(sessionId: sessionId)
        for (match, reply) in rules { try owner.installAutoReply(sessionId: sessionId, match: match, reply: reply) }
    }

    private static func handoffTarget(sessionId: Int, source: NativeTerminalHost) -> NativeTerminalHost? {
        transferLock.lock(); defer { transferLock.unlock() }
        guard let owner = transferred[sessionId], owner.source === source else { return nil }
        return owner.target
    }

    private static let kernelLock = NSLock()
    private static var bootedWorkspacePath: String?
    /// Strong hold for the entire mounted-kernel lifetime; intentionally never released.
    private static var kernelOwner: WorkspaceFileSystem?
    /// Other window authorities may join only after a complete successful kernel preparation.
    private static var kernelReadyForOtherOwners = false
    private var processAccess: [WorkspaceNativeToolAccess] = []
    private var workspaceRootAccess: [WorkspaceNativeToolAccess] = []
    /// Direct mounts borrow their native authorization for the kernel's entire lifetime.
    private static var mountedProcessAccess: [String: WorkspaceNativeToolAccess] = [:]

    /// True when a session could not be confirmed closed; no new terminal is accepted.
    var cleanupIncomplete: Bool {
        onQueue { cleanupIncompleteFlag }
    }

    init(leaseOwner: WorkspaceFileSystem, processRuntime: NativeProcessRuntime = .embedded) {
        self.leaseOwner = leaseOwner
        self.processRuntime = processRuntime
        ioQueue.setSpecific(key: queueKey, value: ())
    }

    // MARK: - Public surface

    /// Read-only view of the configured guest launch environment (same values `create` merges).
    func environment() throws -> [String: String] {
        try onQueue {
            guard let preparedEnvironment else {
                throw NativeTerminalHostError.processHomeUnavailable("process directories have not been prepared")
            }
            return preparedEnvironment
        }
    }

    func installAutoReply(match: String, reply: String) throws {
        try onQueue {
            autoReplies[match] = reply
            for record in sessions.values where Self.handoffTarget(sessionId: Self.safeInt(record.id), source: self) == nil { try record.state.installAutoReply(match, reply: reply) }
        }
    }

    func uninstallAllAutoReplies() throws {
        try onQueue {
            autoReplies.removeAll()
            for record in sessions.values where Self.handoffTarget(sessionId: Self.safeInt(record.id), source: self) == nil { try record.state.uninstallAllAutoReplies() }
        }
    }

    func installAutoReply(sessionId: Int, match: String, reply: String) throws {
        try onSessionQueue(sessionId) { try session(sessionId).state.installAutoReply(match, reply: reply) }
    }

    func uninstallAllAutoReplies(sessionId: Int) throws {
        try onSessionQueue(sessionId) { try session(sessionId).state.uninstallAllAutoReplies() }
    }

    /// Query only an already prepared, live authority. This must never boot or mount the guest.
    func lookupProfile(path: String? = nil, shells: Bool = false) throws -> Any {
        if let path {
            guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count < 4096 else {
                throw NativeTerminalHostError.invalidRequest("profile lookup requires a bounded absolute guest path")
            }
        }
        return try onQueue {
            Self.kernelLock.lock()
            defer { Self.kernelLock.unlock() }
            guard Self.kernelOwner != nil, !cleanupIncompleteFlag,
                  let preparedEnvironment, !processAccess.isEmpty else {
                throw NativeTerminalHostError.processHomeUnavailable("guest profile lookup requires a live prepared authority")
            }
            for access in processAccess {
                guard let mounted = Self.mountedProcessAccess[access.rootPath],
                      Self.sameValidatedRoot(access, mounted),
                      access.rootPath.withCString({ codipad_kernel_native_path_is_mounted($0) }) else {
                    throw NativeTerminalHostError.processHomeUnavailable("guest profile mount binding is unavailable")
                }
                var metadata = stat()
                guard access.stat(path: WorkspacePaths.guestRoot, into: &metadata) == 0 else {
                    throw NativeTerminalHostError.processHomeUnavailable("guest profile mount authorization is unavailable")
                }
            }
            return try withExtendedLifetime((leaseOwner, processAccess, Self.mountedProcessAccess)) {
                var isFile = false
                // Even the environment read verifies that the existing kernel context is live.
                let result = (path ?? "/").withCString { codipad_kernel_path_is_file($0, &isFile) }
                guard result == 0 else {
                    throw NativeTerminalHostError.processHomeUnavailable("guest profile lookup is unavailable (\(result))")
                }
                if shells {
                    var bytes = [CChar](repeating: 0, count: 64 * 1024)
                    var length = 0
                    let status = codipad_kernel_read_shells(&bytes, bytes.count, &length)
                    guard status == 0, let contents = String(bytes: bytes.prefix(length).map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                        throw NativeTerminalHostError.processHomeUnavailable("guest shell list is unavailable (\(status))")
                    }
                    return contents
                }
                if path != nil { return isFile as Any }
                return preparedEnvironment as Any
            }
        }
    }

    // MARK: - Shell integration

    enum ShellIntegrationOperation: String {
        case chmod, mkdir, copyRc, copyProfile, copyEnv, copyLogin
    }

    /// Inputs come only from the bridge's receipt-verified catalog and retained process grants.
    func shellIntegrationContext(appRootAccess: WorkspaceNativeToolAccess,
                                 processHomeAccess: WorkspaceNativeToolAccess,
                                 applicationName: String, quality: String?) throws -> [String: Any] {
        try withShellIntegrationFiles(appRootAccess: appRootAccess, processHomeAccess: processHomeAccess,
                                      applicationName: applicationName) { files, home in
            ["platform": "linux", "scriptsRoot": files.scriptsRoot, "tmpDir": files.tmpRoot,
             "stagingDirectory": files.directory, "homedir": home, "username": NSNull(),
             "applicationName": applicationName, "quality": quality as Any? ?? NSNull()]
        }
    }

    func prepareShellIntegration(operation: ShellIntegrationOperation,
                                 appRootAccess: WorkspaceNativeToolAccess,
                                 processHomeAccess: WorkspaceNativeToolAccess,
                                 applicationName: String, quality: String?) throws -> [String: Any] {
        try withShellIntegrationFiles(appRootAccess: appRootAccess, processHomeAccess: processHomeAccess,
                                      applicationName: applicationName) { files, _ in
            try files.perform(operation)
            return ["completed": true]
        }
    }

    private func withShellIntegrationFiles<T>(appRootAccess: WorkspaceNativeToolAccess,
                                              processHomeAccess: WorkspaceNativeToolAccess,
                                              applicationName: String,
                                              body: (ShellIntegrationFiles, String) throws -> T) throws -> T {
        try onQueue {
            Self.kernelLock.lock()
            defer { Self.kernelLock.unlock() }
            guard Self.kernelOwner != nil, !cleanupIncompleteFlag,
                  let home = preparedEnvironment?["HOME"], !home.isEmpty else {
                throw NativeTerminalHostError.processHomeUnavailable("shell integration requires a live prepared authority")
            }
            let access = try Self.canonicalProcessAccess([appRootAccess, processHomeAccess],
                                                        owner: leaseOwner, retaining: processAccess)
            guard access.count == 2 else {
                throw NativeTerminalHostError.processHomeUnavailable("shell integration requires distinct catalog and process roots")
            }
            for item in access {
                guard processAccess.contains(where: { $0 === item }),
                      Self.mountedProcessAccess[item.rootPath].map({ Self.sameValidatedRoot(item, $0) }) == true,
                      item.rootPath.withCString({ codipad_kernel_native_path_is_mounted($0) }) else {
                    throw NativeTerminalHostError.processHomeUnavailable("shell integration capability is not bound to this live host")
                }
            }
            let files = try ShellIntegrationFiles(app: access[0], process: access[1], applicationName: applicationName)
            return try withExtendedLifetime((leaseOwner, access)) { try body(files, home) }
        }
    }

    /// Descriptor-relative staging under the already authorized process-home/tmp. This is not
    /// guest /tmp and does not modify TMPDIR (short guest socket paths must remain available).
    private struct ShellIntegrationFiles {
        let app: WorkspaceNativeToolAccess
        let process: WorkspaceNativeToolAccess
        let name: String
        static let scripts = "terminal-scripts"
        var scriptsRoot: String { app.rootPath + "/" + Self.scripts }
        var tmpRoot: String { process.rootPath + "/tmp" }
        var directory: String { tmpRoot + "/" + name }
        var relativeDirectory: String { WorkspacePaths.guestRoot + "/tmp/" + name }

        init(app: WorkspaceNativeToolAccess, process: WorkspaceNativeToolAccess, applicationName: String) throws {
            guard !applicationName.isEmpty, applicationName.utf8.count <= 128,
                  applicationName.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }) else {
                throw NativeTerminalHostError.invalidRequest("invalid verified product application name")
            }
            self.app = app; self.process = process
            // No guest username is available. The upstream userInfo catch uses this same fallback.
            name = "unknown-" + applicationName + "-zsh"
            let temporary = try Self.openDirectory(process, WorkspacePaths.guestRoot + "/tmp")
            close(temporary)
            let scripts = try Self.openDirectory(app, WorkspacePaths.guestRoot + "/" + Self.scripts)
            close(scripts)
        }

        static func failure(_ operation: String, _ code: Int32) -> NativeTerminalHostError {
            // Upstream's unchanged chmod/create sequence recognizes ENOENT in the error message.
            .processHomeUnavailable("shell integration \(operation): \(code == ENOENT ? "ENOENT" : String(code))")
        }

        static func openDirectory(_ access: WorkspaceNativeToolAccess, _ path: String) throws -> Int32 {
            let fd = access.open(path: path, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW, mode: 0)
            guard fd >= 0 else { throw failure("open directory", -fd) }
            return fd
        }

        func perform(_ operation: ShellIntegrationOperation) throws {
            if operation == .mkdir {
                let result = process.mkdir(path: relativeDirectory, mode: 0o1700)
                guard result == 0 || result == -EEXIST else { throw Self.failure("mkdir", -result) }
                let fd = try Self.openDirectory(process, relativeDirectory)
                close(fd)
                return
            }
            let directoryFD = try Self.openDirectory(process, relativeDirectory)
            defer { close(directoryFD) }
            if operation == .chmod {
                guard fchmod(directoryFD, 0o1700) == 0 else { throw Self.failure("chmod", errno) }
                var info = stat()
                guard fstat(directoryFD, &info) == 0, info.st_mode & 0o7777 == 0o1700 else {
                    throw Self.failure("verify directory mode", EACCES)
                }
                return
            }
            let script: String, destination: String
            switch operation {
            case .copyRc: script = "shellIntegration-rc.zsh"; destination = ".zshrc"
            case .copyProfile: script = "shellIntegration-profile.zsh"; destination = ".zprofile"
            case .copyEnv: script = "shellIntegration-env.zsh"; destination = ".zshenv"
            case .copyLogin: script = "shellIntegration-login.zsh"; destination = ".zlogin"
            case .chmod, .mkdir: preconditionFailure("handled above")
            }
            var directoryInfo = stat()
            guard fstat(directoryFD, &directoryInfo) == 0, directoryInfo.st_mode & 0o7777 == 0o1700 else {
                throw Self.failure("unprotected staging directory", EACCES)
            }
            let source = app.open(path: WorkspacePaths.guestRoot + "/" + Self.scripts + "/" + script,
                                  flags: O_RDONLY | O_NOFOLLOW, mode: 0)
            guard source >= 0 else { throw Self.failure("open stock script", -source) }
            defer { close(source) }
            var sourceInfo = stat()
            guard fstat(source, &sourceInfo) == 0, sourceInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  sourceInfo.st_size >= 0, sourceInfo.st_size <= 1024 * 1024 else {
                throw Self.failure("invalid stock script", EINVAL)
            }
            let temporaryName = ".codipad-shell-" + UUID().uuidString
            let temporary = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard temporary >= 0 else { throw Self.failure("create temporary script", errno) }
            defer { close(temporary); unlinkat(directoryFD, temporaryName, 0) }
            guard fchmod(temporary, 0o600) == 0 else { throw Self.failure("chmod script", errno) }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            var total = 0
            while true {
                let count = read(source, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw Self.failure("read stock script", errno) }
                if count == 0 { break }
                total += count
                guard total <= 1024 * 1024 else { throw Self.failure("oversized stock script", EFBIG) }
                try buffer.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < count {
                        let written = write(temporary, bytes.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw Self.failure("write stock script", written == 0 ? EIO : errno) }
                        offset += written
                    }
                }
            }
            guard total == sourceInfo.st_size else { throw Self.failure("stock script changed", EIO) }
            guard fchmod(temporary, sourceInfo.st_mode & 0o777) == 0 else { throw Self.failure("preserve stock script mode", errno) }
            guard renameat(directoryFD, temporaryName, directoryFD, destination) == 0 else {
                throw Self.failure("publish stock script", errno)
            }
            let current = try Self.openDirectory(process, relativeDirectory)
            defer { close(current) }
            var currentInfo = stat()
            guard fstat(current, &currentInfo) == 0,
                  currentInfo.st_dev == directoryInfo.st_dev, currentInfo.st_ino == directoryInfo.st_ino else {
                throw Self.failure("staging directory changed", ESTALE)
            }
        }
    }

    // MARK: - Process directory preparation

    /// These directory URIs must already be granted by the shared filesystem authority.
    func prepareProcessDirectories(_ uris: [String], homeURI: String) throws {
        let access = try uris.map { try leaseOwner.nativeToolAccess(rootURI: $0) }
        let homeAccess = try leaseOwner.nativeToolAccess(rootURI: homeURI)
        guard access.contains(where: { $0.rootPath == homeAccess.rootPath }) else {
            throw NativeTerminalHostError.processHomeUnavailable("the granted process home is missing from the mount set")
        }
        let homePath = homeAccess.rootPath
        let environment = Self.guestEnvironmentBase.merging([
            "HOME": homePath + "/home",
            "XDG_DATA_HOME": homePath + "/data",
            "XDG_CACHE_HOME": homePath + "/cache",
            "NODE_COMPILE_CACHE": homePath + "/cache/node-compile-cache",
            "XDG_CONFIG_HOME": homePath + "/config",
            "TMPDIR": processRuntime.temporaryDirectory(nativeDirectory: homePath + "/tmp"),
        ]) { _, processValue in processValue }
        try onQueue {
            Self.kernelLock.lock()
            defer { Self.kernelLock.unlock() }
            let merged = try Self.canonicalProcessAccess(access + workspaceRootAccess,
                owner: leaseOwner, retaining: processAccess)
            if Self.kernelOwner != nil { try Self.mountProcessDirectories(merged) }
            let workspacePaths = Set(workspaceRootAccess.map { $0.rootPath })
            workspaceRootAccess = merged.filter { workspacePaths.contains($0.rootPath) }
            processAccess = merged
            preparedEnvironment = environment
        }
    }

    /// Preparation holds adapters in the bridge. Install only after its grant transaction has
    /// succeeded. Mounts are app-global: partial successes retain their scopes even if a later
    /// mount or workspace-state save fails; there is no kernel unmount API.
    func installAuthorizedWorkspaceRoots(_ access: [WorkspaceNativeToolAccess]) throws {
        try onQueue {
            if case .embedded = processRuntime, access.count > 1 {
                throw NativeTerminalHostError.invalidWorkspace("multiple workspace roots require the Linux process authority")
            }
            Self.kernelLock.lock()
            defer { Self.kernelLock.unlock() }
            let roots = try Self.canonicalProcessAccess(workspaceRootAccess + access,
                owner: leaseOwner, retaining: processAccess)
            let merged = try Self.canonicalProcessAccess(processAccess + roots,
                owner: leaseOwner, retaining: roots)
            if Self.kernelOwner != nil { try Self.mountProcessDirectories(merged) }
            workspaceRootAccess = roots
            processAccess = merged
        }
    }

    /// Prepare the same mounted workspace before extension subprocesses can start.
    /// This does not create a terminal or a second process registry.
    func prepareProcessWorkspace(workspaceURL: URL) throws {
        let workspace = try canonicalWorkspace(workspaceURL)
        try onQueue {
            _ = try Self.prepareKernel(workspace: workspace, owner: leaseOwner, processAccess: processAccess,
                                       runtime: processRuntime)
        }
    }

    /// Resolver extensions can run before a folder is opened. Mount their already-authorized
    /// process directories without claiming HOME as the kernel's one native workspace.
    func prepareProcessRuntime() throws {
        try onQueue {
            guard preparedEnvironment != nil else {
                throw NativeTerminalHostError.processHomeUnavailable("process directories have not been prepared")
            }
            _ = try Self.prepareKernel(workspace: nil, owner: leaseOwner, processAccess: processAccess,
                                       runtime: processRuntime)
        }
    }

    @discardableResult
    func create(
        workspaceURL: URL,
        cols: Int,
        rows: Int,
        cwdURI: String? = nil,
        executable: String,
        args: [String],
        env: [String: String] = [:],
        unsetEnv: [String] = [],
        pageId: String, workspaceId: String, shouldPersist: Bool, unicodeVersion: String, shellIntegrationNonce: String, scrollback: Int, launchMetadata: [String: Any], launchConfig: [String: Any]? = nil, revival: [String: Any]? = nil
    ) throws -> [String: Any] {
        let launchMetadata = try NativeTerminalMetadata.validate(launchMetadata, launch: true)
        if let launchConfig { try NativeTerminalRevival.validateLaunch(launchConfig) }
        let revivalToken = try revival.map { try NativeTerminalRevival.validate($0, incarnation: revivalJournal.incarnation) }
        try NativeTerminalState.validateConfiguration(cols: cols == 0 ? 80 : cols, rows: rows == 0 ? 24 : rows, scrollback: scrollback)
        guard !executable.isEmpty, !executable.contains("\0") else {
            throw NativeTerminalHostError.invalidRequest("executable must be non-empty and contain no NUL byte")
        }
        guard cols >= 0, rows >= 0 else {
            throw NativeTerminalHostError.invalidRequest("cols/rows must be non-negative")
        }
        guard !cleanupIncomplete else {
            throw NativeTerminalHostError.incomplete("previous session cleanup is incomplete")
        }
        // Validate argv/env before rootfs import or kernel boot: NULs would truncate in C.
        for argument in args where argument.contains("\0") {
            throw NativeTerminalHostError.invalidRequest("argument contains a NUL byte")
        }
        let environment = try mergedEnvironment(env, unsetEnv: unsetEnv)
        let workspace = try canonicalWorkspace(workspaceURL)
        let guestCwd = try guestPath(cwdURI: cwdURI, workspace: workspace)
        // Keep the requested command and argv intact. codipad_kernel_spawn resolves bare names
        // against this cwd and environment inside the guest filesystem, then preflights that path.
        let argv = [executable] + args

        let reply: [String: Any] = try onQueue {
            try requirePage(pageId)
            if let token = revivalToken, revivalJournal.revived[token] != nil {
                guard let identity = revivalJournal.revivedIdentities[token] else { throw NativeTerminalHostError.invalidRequest("revived record identity is unavailable") }
                return ["attachIdentity": identity]
            }
            guard sessions.count < 32 else { throw NativeTerminalHostError.invalidRequest("close retained terminals before creating more") }
            let state = try NativeTerminalState(cols: cols == 0 ? 80 : cols, rows: rows == 0 ? 24 : rows, scrollback: scrollback, unicodeVersion: unicodeVersion, shellIntegrationNonce: shellIntegrationNonce)
            for (match, reply) in autoReplies { try state.installAutoReply(match, reply: reply) }
            _ = try Self.prepareKernel(workspace: workspace, owner: leaseOwner, processAccess: processAccess,
                                       runtime: processRuntime)

            // History is output only. Do not transfer a pending parser/UTF8 suffix to a new PTY.
            if let revival {
                do {
                    let data = Data((revival["data"] as! String).utf8)
                    for offset in stride(from: 0, to: data.count, by: 1024 * 1024) {
                        try state.write(data.subdata(in: offset..<min(offset + 1024 * 1024, data.count)))
                    }
                    if let commands = revival["commands"] as? [String: Any] { try state.restoreCommands(commands) }
                }
                catch { state.dispose(); throw error }
            }
            if let token = revivalToken {
                do { try revivalJournal.claim(token) }
                catch { state.dispose(); throw error }
            }
            let context = SessionContext(host: self)
            var session: codipad_session_t = 0
            var info = codipad_session_info()

            let result: Int32 = guestCwd.withCString { cwdPath in
                executable.withCString { exePath in
                    withCStringArray(argv) { argvPtr in
                        withCStringArray(environment.map { "\($0.key)=\($0.value)" }.sorted()) { envPtr in
                                var opts = codipad_spawn_opts()
                                opts.exe = exePath
                                opts.argv = UnsafeRawPointer(argvPtr.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                                opts.envp = UnsafeRawPointer(envPtr.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                                opts.cwd = cwdPath
                                opts.cols = UInt32(cols == 0 ? 80 : cols)
                                opts.rows = UInt32(rows == 0 ? 24 : rows)
                                opts.flags = 0
                                opts.on_output = terminalOutputCallback
                                opts.on_exit = terminalExitCallback
                                opts.ctx = Unmanaged.passUnretained(context).toOpaque()
                                let spawnResult = codipad_kernel_spawn(&opts, &session)
                                if spawnResult == 0 {
                                    _ = codipad_kernel_info(session, &info)
                                }
                                return spawnResult
                            }
                        }
                    }
                }

            guard result == 0 else {
                state.dispose()
                throw NativeTerminalHostError.spawnFailed(result, Self.posixMessage(result))
            }

            let id = UInt64(session)
            let record = SessionRecord(
                id: id,
                context: context,
                workspace: workspace,
                guestCwd: guestCwd,
                pid: info.guest_pid, shellIntegrationNonce: shellIntegrationNonce, state: state, workspaceId: workspaceId, pageId: pageId, shouldPersist: shouldPersist, launchMetadata: launchMetadata
            )
            record.launchConfig = launchConfig
            record.processEnvironment = environment
            record.wasRevived = revivalToken != nil
            sessions[id] = record
            if let token = revivalToken { revivalJournal.record(token, sessionId: Self.safeInt(id), processIdentity: processIdentity(record)) }
            retainActiveHost()
            context.attach(record)
            if revivalToken != nil { return ["attachIdentity": processIdentity(record)] }

            return [
                "sessionId": Self.safeInt(id),
                "generation": record.generation, "pageId": record.pageId, "processIdentity": processIdentity(record),
                "pid": Self.safeInt(info.guest_pid),
                "cwd": URL(fileURLWithPath: guestCwd, isDirectory: true).absoluteString,
                "guestCwd": guestCwd,
            ]
        }
        if let identity = reply["attachIdentity"] as? String {
            return try attachIdentity(identity, workspaceId: workspaceId, pageId: pageId)
        }
        return reply
    }

    /// Atomically admits a complete payload to the bounded session queue. PTY delivery continues
    /// asynchronously across short writes and EAGAIN, preserving the unsent suffix.
    func input(sessionId: Int, data base64: String) throws -> [String: Any] {
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            let encodedCount = base64.utf8.count
            guard (encodedCount / 4) * 3 <= maxInputBytes else {
                throw NativeTerminalHostError.invalidRequest("input exceeds \(maxInputBytes) bytes")
            }
            guard let data = Data(base64Encoded: base64) else {
                throw NativeTerminalHostError.invalidRequest("data must be base64")
            }
            guard data.count <= maxInputBytes else {
                throw NativeTerminalHostError.invalidRequest("input exceeds \(maxInputBytes) bytes")
            }
            guard !data.isEmpty else {
                return ["acceptedBytes": 0, "queuedBytes": record.pendingInputBytes]
            }
            guard record.enqueueInput(data, byteLimit: maxInputBytes, eventLimit: maxInputEvents) else {
                throw NativeTerminalHostError.inputQueueFull
            }
            scheduleInputPump(record)
            return ["acceptedBytes": data.count, "queuedBytes": record.pendingInputBytes]
        }
    }

    /// Navigation invalidates outgoing commands/completions without destroying the owned PTYs.
    func setRendererPage(_ page: String?) {
        let oldPage = onQueue { rendererPage }
        onQueue {
            rendererPage = page
            for record in sessions.values { record.queue.async { if record.pageId == oldPage { record.attached = false } } }
        }
        for (id, source) in Self.borrowedSessions(target: self) {
            source.performRequest(sessionId: id) {
                if let record = try? source.session(id), record.pageId == oldPage { record.attached = false }
            }
        }
    }

    /// Only a dead page loses its nonpersistent terminals; ordinary navigation just detaches.
    func retireRendererPage(_ page: String) throws {
        let records = onQueue { Array(sessions.values) }
        var failure: Error?
        for record in records {
            record.onQueue {
                guard owns(record), record.pageId == page, !record.shouldPersist else { return }
                record.removeAfterSettlement = true
                record.attached = false
                do {
                    try closeRecord(record, graceMs: 500)
                    finishRecord(record)
                } catch {
                    record.cleanupPending = true
                    confirmOrReconcile(record, attempt: 0)
                    if owns(record) { failure = error }
                }
            }
        }
        if let failure { throw failure }
    }

    func requirePage(_ page: String) throws {
        try onQueue {
            guard rendererPage == page else { throw NativeTerminalHostError.invalidRequest("stale terminal page") }
        }
    }

    func requireAttachment(sessionId: Int, pageId: String, generation: String) throws {
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            guard record.pageId == pageId, record.generation == generation else {
                throw NativeTerminalHostError.invalidRequest("stale terminal attachment")
            }
        }
    }

    /// Snapshot and output revision are captured on the same queue as parser writes and resize.
    func attach(sessionId: Int, workspaceId: String, pageId: String, foreignPage: Bool = false) throws -> [String: Any] {
        try onSessionQueue(sessionId) {
            if !foreignPage { try requirePage(pageId) }
            let record = try session(sessionId)
            guard record.workspaceId == workspaceId, record.shouldPersist, !record.stateFailed else {
                throw NativeTerminalHostError.invalidRequest("terminal is not restorable in this workspace")
            }
            let wasAttached = record.attached
            record.attached = false
            let snapshot: [String: Any]
            do { try flushOutput(record); snapshot = try record.state.snapshot() }
            catch { record.attached = wasAttached; throw error }
            record.pageId = pageId
            record.generation = UUID().uuidString
            record.snapshotCut = record.mirroredThrough
            record.exitEmitted = false
            return ["sessionId": sessionId, "pid": Self.safeInt(record.pid),
                    "cwd": URL(fileURLWithPath: record.guestCwd).absoluteString, "guestCwd": record.guestCwd,
                    "generation": record.generation, "pageId": record.pageId, "processIdentity": processIdentity(record), "snapshot": snapshot, "throughDataId": record.mirroredThrough, "details": processDetails(record)]
        }
    }

    func handoffDetails(sessionId: Int, pageId: String, generation: String) throws -> [String: Any] {
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            guard record.pageId == pageId, record.generation == generation,
                  record.attached, record.shouldPersist, !record.stateFailed,
                  !record.settled, record.handoff == nil else {
                throw NativeTerminalHostError.invalidRequest("terminal cannot be transferred")
            }
            return processDetails(record)
        }
    }

    /// Freeze delivery while a second window restores a snapshot. The original host retains
    /// the session, parser, callback context and all process and mount authorization leases.
    func beginHandoff(sessionId: Int, pageId: String, generation: String,
                      targetPage: String, targetWorkspace: String, handoffId: String) throws -> [String: Any] {
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            guard record.pageId == pageId, record.generation == generation, record.attached,
                  record.shouldPersist, !record.stateFailed, !record.settled,
                  record.handoff == nil else {
                throw NativeTerminalHostError.invalidRequest("terminal cannot be transferred")
            }
            try flushOutput(record)
            record.attached = false
            do {
                let snapshot = try record.state.snapshot()
                let nextGeneration = UUID().uuidString
                let cut = record.mirroredThrough
                record.handoff = SessionRecord.Handoff(id: handoffId, targetPage: targetPage,
                                                       targetWorkspace: targetWorkspace, generation: nextGeneration, cut: cut)
                return ["sessionId": sessionId, "pid": Self.safeInt(record.pid),
                        "cwd": URL(fileURLWithPath: record.guestCwd).absoluteString,
                        "guestCwd": record.guestCwd, "generation": nextGeneration,
                        "pageId": targetPage, "processIdentity": processIdentity(record),
                        "snapshot": snapshot, "throughDataId": cut, "details": processDetails(record)]
            } catch {
                record.attached = true
                try? flushOutput(record)
                throw error
            }
        }
    }

    /// Commit only after the destination has consumed the snapshot. Unsent output remains in
    /// the original ledger and is replayed after the captured revision.
    func commitHandoff(sessionId: Int, handoffId: String, pageId: String,
                       generation: String, throughDataId: UInt64) throws {
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            guard let handoff = record.handoff, handoff.id == handoffId,
                  handoff.targetPage == pageId, handoff.generation == generation,
                  handoff.cut == throughDataId, !record.attached else {
                throw NativeTerminalHostError.invalidRequest("terminal handoff acknowledgement does not match")
            }
            for (id, _) in record.outputEvents() where id <= handoff.cut {
                _ = try acknowledgeOutput(sessionId: sessionId, dataId: Int(id))
            }
            record.pageId = pageId
            record.workspaceId = handoff.targetWorkspace
            record.generation = generation
            record.handoff = nil
            record.sentThrough = handoff.cut
            record.attached = true
            do { try flushOutput(record) } catch { outputStateFailed(record) }
            if record.settled { emitExit(record, code: record.leaderCode, signal: record.leaderSignal) }
        }
    }

    /// A failed target leaves the original view and generation alive.
    func cancelHandoff(sessionId: Int, handoffId: String) throws {
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            guard record.handoff?.id == handoffId else { return }
            record.handoff = nil
            record.attached = true
            try flushOutput(record)
            if record.settled { emitExit(record, code: record.leaderCode, signal: record.leaderSignal) }
        }
    }

    func resumeOutput(sessionId: Int, throughDataId: UInt64) throws {
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            guard let cut = record.snapshotCut, cut == throughDataId, !record.attached else {
                throw NativeTerminalHostError.invalidRequest("snapshot acknowledgement does not match attachment")
            }
            for (id, _) in record.outputEvents() where id <= cut {
                _ = try acknowledgeOutput(sessionId: sessionId, dataId: Int(id))
            }
            record.snapshotCut = nil
            record.sentThrough = cut
            record.attached = true
            try flushOutput(record)
            if record.settled { emitExit(record, code: record.leaderCode, signal: record.leaderSignal) }
        }
    }

    func detach(sessionId: Int) throws {
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            guard record.handoff == nil else { throw NativeTerminalHostError.invalidRequest("terminal handoff is pending") }
            record.attached = false
            record.generation = UUID().uuidString
        }
    }

    /// Bytes remain charged until xterm commits them (or commits a snapshot covering them).
    func acknowledgeOutput(sessionId: Int, dataId: Int) throws -> [String: Any] {
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            guard dataId > 0, let bytes = record.outputEventByteCount(UInt64(dataId)) else {
                return ["releasedBytes": 0, "pendingBytes": record.pendingOutputByteCount]
            }
            if !record.settled {
                let result = codipad_kernel_output_ack(record.id, bytes)
                guard result == 0 else { throw NativeTerminalHostError.outputAckFailed(result) }
            }
            let released = record.acknowledgeOutput(UInt64(dataId))
            return ["releasedBytes": released, "pendingBytes": record.pendingOutputByteCount]
        }
    }

    func acknowledgeOutputBatch(sessionId: Int, dataIds: [Int]) throws -> [String: Any] {
        try onSessionQueue(sessionId) {
            guard !dataIds.isEmpty, dataIds.count <= 512,
                  dataIds.allSatisfy({ $0 > 0 }), Set(dataIds).count == dataIds.count else {
                throw NativeTerminalHostError.invalidRequest("invalid output acknowledgement batch")
            }
            var released = 0
            for id in dataIds {
                let reply = try acknowledgeOutput(sessionId: sessionId, dataId: id)
                released += reply["releasedBytes"] as? Int ?? 0
            }
            return ["releasedBytes": released, "pendingBytes": try session(sessionId).pendingOutputByteCount]
        }
    }

    func acknowledgeExit(sessionId: Int) throws {
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            guard record.settled, record.pendingOutputByteCount == 0 else {
                throw NativeTerminalHostError.invalidRequest("terminal exit still has unread output")
            }
            finishRecord(record)
        }
    }

    func failOutputDelivery(sessionId: Int, dataId: Int, pageId: String, generation: String, reason: String) {
        performRequest(sessionId: sessionId) { [weak self] in
            guard let self,
                  (try? self.requireAttachment(sessionId: sessionId, pageId: pageId, generation: generation)) != nil,
                  let record = try? self.session(sessionId), record.outputEventByteCount(UInt64(dataId)) != nil else { return }
            // A missing WK receiver is a detach. Keep the parser, unread bytes and process owners.
            record.attached = false
        }
    }

    func setLayout(workspaceId: String, layout: [String: Any]?) throws {
        try onQueue {
            if let layout {
                guard try JSONSerialization.data(withJSONObject: layout).count <= 256 * 1024,
                      layouts[workspaceId] != nil || layouts.count < 32 else {
                    throw NativeTerminalHostError.invalidRequest("terminal layout limit exceeded")
                }
            }
            layouts[workspaceId] = layout
        }
    }

    func incarnationInfo() -> [String: Any] {
        onQueue { ["incarnation": revivalJournal.incarnation, "revived": revivalJournal.revived, "revivedIdentities": revivalJournal.revivedIdentities] }
    }

    func serialize(workspaceId: String, includeTransferred: Bool = false) throws -> [String: Any] {
        let records = onQueue { sessions.values.sorted(by: { $0.id < $1.id }) }
        var states: [[String: Any]] = []
        for record in records {
            try record.onQueue {
                guard owns(record), record.workspaceId == workspaceId, record.shouldPersist, !record.settled,
                      includeTransferred || Self.handoffTarget(sessionId: Self.safeInt(record.id), source: self) == nil else { return }
                guard let launch = record.launchConfig else { throw NativeTerminalHostError.invalidRequest("terminal launch record missing") }
                try flushOutput(record)
                guard record.mirroredThrough > 0 || record.wasRevived else { return }
                _ = try cwd(sessionId: Self.safeInt(record.id))
                let snapshot = try record.state.snapshotNormal()
                var details = processDetails(record)
                guard let native = nativeURL(forGuest: record.guestCwd, workspace: record.workspace) else {
                    throw NativeTerminalHostError.invalidRequest("terminal cwd cannot be authorized for restart")
                }
                details["cwd"] = native.path
                states.append(["id": Self.safeInt(record.id), "shellLaunchConfig": launch["shellLaunchConfig"]!,
                    "processDetails": details, "processLaunchConfig": ["env": record.processEnvironment, "executableEnv": try environment(), "options": launch["options"]!],
                    "unicodeVersion": snapshot["unicodeVersion"]!,
                    "replayEvent": ["events": [["data": snapshot["data"]!, "cols": snapshot["cols"]!, "rows": snapshot["rows"]!]], "commands": snapshot["commands"] as Any? ?? NSNull()],
                    "timestamp": Date().timeIntervalSince1970 * 1000])
            }
        }
        if !includeTransferred {
            for (id, owner) in Self.borrowedSessions(target: self, workspace: workspaceId) {
                let other = try owner.serialize(workspaceId: workspaceId, includeTransferred: true)
                if let entries = other["state"] as? [[String: Any]], let entry = entries.first(where: { $0["id"] as? Int == id }) {
                    states.append(entry)
                }
            }
        }
        return try onQueue {
            let value: [String: Any] = ["version": 1, "state": states,
                "codipad": ["incarnation": revivalJournal.incarnation, "checkpoint": UUID().uuidString, "layout": layouts[workspaceId] ?? ["tabs": [], "background": []]]]
            guard try JSONSerialization.data(withJSONObject: value).count <= 16 * 1024 * 1024 else {
                throw NativeTerminalHostError.invalidRequest("terminal checkpoint exceeds storage limit")
            }
            return value
        }
    }

    func getLayout(workspaceId: String) -> [String: Any]? { onQueue { layouts[workspaceId] } }

    func updateMetadata(sessionId: Int, metadata: [String: Any]) throws {
        let metadata = try NativeTerminalMetadata.validate(metadata, launch: false)
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            let combined = record.metadata.merging(metadata) { _, value in value }
            _ = try NativeTerminalMetadata.validate(record.launchMetadata.merging(combined) { _, value in value }, launch: true)
            record.metadata = combined
        }
    }

    func updateState(sessionId: Int, _ operation: (NativeTerminalState) throws -> Void) throws {
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            try flushOutput(record)
            try operation(record.state)
        }
    }

    func resize(sessionId: Int, cols: Int, rows: Int) throws {
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            try record.state.validateResize(cols: cols, rows: rows)
            try flushOutput(record)
            let result = codipad_kernel_resize(record.id, UInt32(cols), UInt32(rows))
            guard result == 0 else {
                throw NativeTerminalHostError.resizeFailed(result)
            }
            do { try record.state.resize(cols: cols, rows: rows) }
            catch {
                outputStateFailed(record)
                throw error
            }
        }
    }

    func signal(sessionId: Int, signal: Int32) throws {
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            let result = codipad_kernel_signal(record.id, signal)
            guard result == 0 else {
                if result == -Int32(CODIPAD_EINCOMPLETE) {
                    throw NativeTerminalHostError.incomplete("signal coverage could not be confirmed")
                }
                throw NativeTerminalHostError.signalFailed(result)
            }
        }
    }

    /// Requests close. The exit event is emitted only when the authority confirms the reap.
    func stop(sessionId: Int, graceMs: UInt32 = 500) throws {
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            try closeRecord(record, graceMs: graceMs)
            finishRecord(record)
        }
    }

    func cwd(sessionId: Int) throws -> [String: Any] {
        try onSessionQueue(sessionId) {
            let record = try session(sessionId)
            var buffer = [CChar](repeating: 0, count: maxCwdBytes)
            let result = buffer.withUnsafeMutableBufferPointer { pointer in
                codipad_kernel_getcwd(record.id, pointer.baseAddress, pointer.count)
            }
            guard result == 0 else {
                throw NativeTerminalHostError.cwdUnavailable(result)
            }
            let guest = String(cString: buffer)
            record.guestCwd = guest
            return [
                "sessionId": Self.safeInt(record.id),
                "guestCwd": guest,
                "cwd": nativeURL(forGuest: guest, workspace: record.workspace).map { $0.absoluteString } as Any? ?? NSNull(),
            ]
        }
    }

    private func processIdentity(_ record: SessionRecord) -> String {
        revivalJournal.incarnation + ":" + record.recordIdentity
    }

    func attachIdentity(_ identity: String, workspaceId: String, pageId: String, foreignPage: Bool = false) throws -> [String: Any] {
        let id: Int = try onQueue {
            if !foreignPage { try requirePage(pageId) }
            let parts = identity.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil, UUID(uuidString: String(parts[1])) != nil,
                  parts[0] == revivalJournal.incarnation,
                  let record = sessions.values.first(where: { $0.workspaceId == workspaceId && processIdentity($0) == identity }) else {
                throw NativeTerminalHostError.invalidRequest("unknown terminal process identity or workspace owner")
            }
            return Self.safeInt(record.id)
        }
        return try attach(sessionId: id, workspaceId: workspaceId, pageId: pageId, foreignPage: foreignPage)
    }

    private func processDetails(_ record: SessionRecord) -> [String: Any] {
        let presentation = record.launchMetadata.merging(record.metadata) { _, value in value }
        return ["title": record.guestCwd, "titleSource": 1].merging(presentation) { _, value in value }
            .merging(["processIdentity": processIdentity(record), "id": Self.safeInt(record.id), "sessionId": Self.safeInt(record.id), "pid": Self.safeInt(record.pid),
                      "cwd": record.guestCwd, "guestCwd": record.guestCwd, "workspaceId": record.workspaceId,
                      "isOrphan": !record.attached, "hasChildProcesses": !record.settled,
                      "shellIntegrationNonce": record.shellIntegrationNonce, "exited": record.settled, "cleanupPending": record.cleanupPending,
                      "code": record.statusObserved ? Int(record.leaderCode) as Any : NSNull(),
                      "signal": record.statusObserved ? Int(record.leaderSignal) as Any : NSNull()]) { _, value in value }
    }

    func list(workspaceId: String) -> [[String: Any]] {
        let records = onQueue { sessions.values.filter { $0.workspaceId == workspaceId && $0.shouldPersist }.sorted { $0.id < $1.id } }
        var result = records.compactMap { record in record.onQueue {
            owns(record) && Self.handoffTarget(sessionId: Self.safeInt(record.id), source: self) == nil ? processDetails(record) : nil
        } }
        for (id, owner) in Self.borrowedSessions(target: self, workspace: workspaceId) {
            if let details = try? owner.onSessionQueue(id, { owner.processDetails(try owner.session(id)) }) { result.append(details) }
        }
        return result
    }

    /// Closes open sessions. The kernel is process-wide and not torn down, so the scope owner
    /// stays retained for the mounted kernel's remaining lifetime.
    func shutdown() {
        Self.transferLock.lock()
        let borrowed = Self.transferred.filter { $0.value.target === self }
        for (id, _) in borrowed { Self.transferred[id] = nil }
        Self.transferLock.unlock()
        for (id, owner) in borrowed {
            try? owner.source.onSessionQueue(id) {
                let record = try owner.source.session(id)
                do {
                    try owner.source.closeRecord(record, graceMs: 500)
                    owner.source.finishRecord(record)
                } catch {
                    record.cleanupPending = true
                    owner.source.quarantine("transferred session cleanup could not be confirmed: \(error)")
                }
            }
        }
        let records = onQueue { Array(sessions.values) }
        for record in records {
            record.onQueue {
                guard owns(record), Self.handoffTarget(sessionId: Self.safeInt(record.id), source: self) == nil else { return }
                do {
                    try closeRecord(record, graceMs: 500)
                    finishRecord(record)
                } catch {
                    record.cleanupPending = true
                    quarantine("shutdown could not confirm every session: \(error)")
                }
            }
        }
        releaseActiveHostIfIdle()
        onEvent = nil
    }

    // MARK: - Kernel bootstrap

    /// Called under kernelLock after the shared mount exists and before creating any session.
    private static func bindProcessWorkspace(workspace: URL) throws {
        let mounted = workspace.path.withCString { codipad_node_set_workspace($0) }
        guard mounted == 0 else {
            throw NativeTerminalHostError.workspaceMismatch("process workspace is already mounted")
        }
    }

    /// Caller holds kernelLock. Keep this host's grants and verify any shared mounted root separately.
    private static func canonicalProcessAccess(_ access: [WorkspaceNativeToolAccess], owner: WorkspaceFileSystem,
                                               retaining retained: [WorkspaceNativeToolAccess] = []) throws -> [WorkspaceNativeToolAccess] {
        guard kernelOwner == nil || kernelOwner === owner || kernelReadyForOtherOwners else {
            throw NativeTerminalHostError.processHomeUnavailable("kernel initialization belongs to another filesystem authority")
        }
        var canonical: [String: WorkspaceNativeToolAccess] = [:]
        for item in retained where canonical[item.rootPath] == nil { canonical[item.rootPath] = item }
        var roots = Set<String>()
        var result: [WorkspaceNativeToolAccess] = []
        for item in access {
            var requested = stat()
            guard item.stat(path: WorkspacePaths.guestRoot, into: &requested) == 0 else {
                throw NativeTerminalHostError.processHomeUnavailable("requested process root authorization is unavailable")
            }
            let held = canonical[item.rootPath] ?? item
            guard sameValidatedRoot(item, held),
                  mountedProcessAccess[item.rootPath].map({ sameValidatedRoot(item, $0) }) ?? true else {
                throw NativeTerminalHostError.processHomeUnavailable("retained process root authorization changed")
            }
            canonical[item.rootPath] = held
            if roots.insert(item.rootPath).inserted { result.append(held) }
        }
        return result
    }

    private static func sameValidatedRoot(_ first: WorkspaceNativeToolAccess, _ second: WorkspaceNativeToolAccess) -> Bool {
        guard first.rootPath == second.rootPath else { return false }
        var left = stat(), right = stat()
        return first.stat(path: WorkspacePaths.guestRoot, into: &left) == 0 &&
            second.stat(path: WorkspacePaths.guestRoot, into: &right) == 0 &&
            left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    /// Caller holds kernelLock. A failed single canonical call never publishes a mount.
    private static func mountProcessDirectories(_ access: [WorkspaceNativeToolAccess]) throws {
        for item in access.sorted(by: { $0.rootPath.count < $1.rootPath.count }) {
            if let mounted = mountedProcessAccess[item.rootPath], !sameValidatedRoot(item, mounted) {
                throw NativeTerminalHostError.processHomeUnavailable("retained process root authorization changed")
            }
            let fd = item.open(path: WorkspacePaths.guestRoot, flags: O_RDONLY | O_DIRECTORY, mode: 0)
            guard fd >= 0 else { throw NativeTerminalHostError.nativeWorkspaceFailed(fd) }
            defer { close(fd) }
            let result = item.rootPath.withCString { codipad_kernel_mount_authorized_root($0, fd) }
            guard result == 0 else { throw NativeTerminalHostError.nativeWorkspaceFailed(result) }
            if mountedProcessAccess[item.rootPath] == nil { mountedProcessAccess[item.rootPath] = item }
        }
    }

    private static func prepareKernel(workspace: URL?, owner: WorkspaceFileSystem,
                                      processAccess: [WorkspaceNativeToolAccess],
                                      runtime: NativeProcessRuntime) throws -> URL {
        kernelLock.lock()
        defer { kernelLock.unlock() }

        let legacyWorkspace: URL?
        let directWorkspaceAccess: [WorkspaceNativeToolAccess]
        switch runtime {
        case .embedded:
            legacyWorkspace = workspace
            if let workspace {
                let held = processAccess.first(where: { $0.rootPath == workspace.path })
                directWorkspaceAccess = [try held ?? owner.authorizedDirectoryAccess(rootURI: workspace.absoluteString)]
            } else {
                directWorkspaceAccess = []
            }
        case .linux:
            legacyWorkspace = nil
            if let workspace {
                if let held = processAccess.first(where: { $0.rootPath == workspace.path }) {
                    directWorkspaceAccess = [held]
                } else {
                    directWorkspaceAccess = [try owner.authorizedDirectoryAccess(rootURI: workspace.absoluteString)]
                }
            } else {
                directWorkspaceAccess = []
            }
        }
        let access = try canonicalProcessAccess(processAccess + directWorkspaceAccess, owner: owner)
        let legacyAccess = legacyWorkspace.flatMap { workspace in access.first { $0.rootPath == workspace.path } }
        let legacyFD: Int32
        if let legacyAccess {
            legacyFD = legacyAccess.open(path: WorkspacePaths.guestRoot, flags: O_RDONLY | O_DIRECTORY, mode: 0)
            guard legacyFD >= 0 else { throw NativeTerminalHostError.nativeWorkspaceFailed(legacyFD) }
        } else {
            legacyFD = -1
        }
        defer { if legacyFD >= 0 { close(legacyFD) } }

        #if CODIPAD_ENABLE_SHARED_EXECUTION
        try NativeExecutionPages.prepare()
        #endif

        if kernelOwner != nil {
            guard codipad_kernel_initialization_state() == CODIPAD_KERNEL_INITIALIZED else {
                throw NativeTerminalHostError.kernelBootFailed(-EBUSY, "kernel bootstrap incomplete")
            }
            if let workspace = legacyWorkspace {
                if let booted = bootedWorkspacePath, booted != workspace.path {
                    throw NativeTerminalHostError.workspaceMismatch(
                        "kernel is already mounted at \(booted); refusing \(workspace.path)"
                    )
                }
                let result = workspace.path.withCString { codipad_kernel_mount_workspace($0, legacyFD, false) }
                if let legacyAccess, mountedProcessAccess[legacyAccess.rootPath] == nil,
                   result == 0 || workspace.path.withCString({ codipad_kernel_authorized_root_status($0, legacyFD) }) != 0 {
                    mountedProcessAccess[legacyAccess.rootPath] = legacyAccess
                }
                guard result == 0 else { throw NativeTerminalHostError.nativeWorkspaceFailed(result) }
                bootedWorkspacePath = workspace.path
                try bindProcessWorkspace(workspace: workspace)
            }
            try mountProcessDirectories(access)
            refreshDNS()
            let rootfs = try importRootfs()
            kernelReadyForOtherOwners = true
            return rootfs
        }

        let data = try importRootfs()
        // Reserve before C can publish. Only authoritative pristine state permits release.
        kernelOwner = owner
        let result: Int32 = data.path.withCString { rootfsPath in
            if let workspace = legacyWorkspace {
                return workspace.path.withCString { codipad_kernel_boot(rootfsPath, $0, legacyFD) }
            }
            return codipad_kernel_boot(rootfsPath, nil, -1)
        }
        if let legacyAccess {
            let status = legacyAccess.rootPath.withCString { codipad_kernel_authorized_root_status($0, legacyFD) }
            if mountedProcessAccess[legacyAccess.rootPath] == nil && (result == 0 || status != 0) {
                mountedProcessAccess[legacyAccess.rootPath] = legacyAccess
            }
        }
        if codipad_kernel_initialization_state() == CODIPAD_KERNEL_PRISTINE { kernelOwner = nil; kernelReadyForOtherOwners = false }
        guard result == 0 else {
            var phase = String(cString: codipad_kernel_boot_phase())
            if phase == "workspace-mount" {
                phase += ":" + String(cString: codipad_kernel_workspace_mount_stage())
            }
            throw NativeTerminalHostError.kernelBootFailed(result, phase)
        }
        guard codipad_kernel_initialization_state() == CODIPAD_KERNEL_INITIALIZED else {
            throw NativeTerminalHostError.kernelBootFailed(-EBUSY, "kernel bootstrap incomplete")
        }
        if let workspace = legacyWorkspace {
            bootedWorkspacePath = workspace.path
            try bindProcessWorkspace(workspace: workspace)
        }
        try mountProcessDirectories(access)
        refreshDNS()
        kernelReadyForOtherOwners = true
        return data
    }

    private static func refreshDNS() {
        let result = codipad_kernel_refresh_dns()
        if result != 0 { print("codipad-linux-dns: host resolver unavailable (\(result))") }
    }

    /// Installs the development base once. Published Linux packages survive later launches.
    private static func importRootfs(bundle: Bundle = .main) throws -> URL {
        guard let archive = bundle.url(forResource: "ShellRootfs", withExtension: "tar.gz"),
              let digest = BuildReceipt.rootfsSHA256(bundle: bundle) else {
            throw NativeTerminalHostError.rootfsMissing("Linux archive or build receipt is missing")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Keep the earlier minimal shell root intact. The development base has its own published root.
        let linux = support.appendingPathComponent("CodiPad/Linux", isDirectory: true)
        try FileManager.default.createDirectory(at: linux, withIntermediateDirectories: true)
        let root = linux.appendingPathComponent("root", isDirectory: true)
        try LinuxRootFilesystem.prepare(archive: archive, expectedSHA256: digest, root: root) { archive, staging in
            let result = archive.path.withCString { archivePath in
                staging.path.withCString { destination in
                    codipad_shell_import_rootfs(archivePath, destination)
                }
            }
            guard result == 0 else {
                let detail = String(cString: codipad_shell_import_message())
                throw NativeTerminalHostError.rootfsImportFailed(
                    result, detail.isEmpty ? "rootfs import failed" : detail
                )
            }
        }
        return root.appendingPathComponent("data", isDirectory: true)
    }

    // MARK: - Sessions

    private func session(_ sessionId: Int) throws -> SessionRecord {
        guard sessionId > 0, let record = onQueue({ sessions[UInt64(sessionId)] }) else {
            throw NativeTerminalHostError.unknownSession(sessionId)
        }
        return record
    }

    /// Confirms the reap with the authority, then emits the real exit status.
    private func closeRecord(_ record: SessionRecord, graceMs: UInt32) throws {
        if record.settled { return }
        var info = codipad_session_info()
        let infoResult = codipad_kernel_info(record.id, &info)

        guard infoResult == 0 else { throw NativeTerminalHostError.closeFailed(infoResult) }
        if info.has_status {
            record.leaderCode = info.code
            record.leaderSignal = info.terminating_signal
            record.statusObserved = true
        }

        // The settled status must be read from the close itself: a running record can exit and
        // be dropped inside close() before the queued exit callback runs.
        var settled = codipad_session_info()
        let closeResult = codipad_kernel_close_status(record.id, graceMs, &settled)
        switch closeResult {
        case 0:
            guard settled.session == record.id, settled.has_status,
                  settled.reaped, settled.all_descendants_reaped else {
                throw NativeTerminalHostError.incomplete("close did not confirm matching settled status")
            }
            record.leaderCode = settled.code
            record.leaderSignal = settled.terminating_signal
            record.statusObserved = true
            record.reaped = true
            record.settled = true
            record.cleanupPending = false
            record.discardInput()
            record.context.detach()
            // close_status fences the C callbacks; include output received during close before exit.
            do { try flushOutput(record) }
            catch {
                record.stateFailed = true
                emitError(record, code: "TerminalStateFailed", message: "terminal closed with unread output retained")
            }
            emitExit(record, code: record.leaderCode, signal: record.leaderSignal)
        case -EINPROGRESS:
            throw NativeTerminalHostError.incomplete("session has not reported exit yet")
        case -Int32(CODIPAD_EINCOMPLETE):
            throw NativeTerminalHostError.incomplete("a descendant survived close")
        default:
            throw NativeTerminalHostError.closeFailed(closeResult)
        }
    }

    private func finishRecord(_ record: SessionRecord) {
        record.discardInput()
        record.context.detach()
        record.state.dispose()
        Self.releaseHandoff(sessionId: Self.safeInt(record.id), source: self)
        onQueue { sessions[record.id] = nil }
        releaseActiveHostIfIdle()
    }

    private func retainActiveHost() {
        Self.activeLock.lock()
        if !Self.activeHosts.contains(where: { $0 === self }) {
            Self.activeHosts.append(self)
        }
        Self.activeLock.unlock()
    }

    private func releaseActiveHostIfIdle() {
        onQueue {
            guard sessions.isEmpty, !cleanupIncompleteFlag else { return }
            Self.activeLock.lock()
            Self.activeHosts.removeAll { $0 === self }
            Self.activeLock.unlock()
        }
    }

    private func quarantine(_ reason: String) {
        onQueue { cleanupIncompleteFlag = true }
        retainActiveHost()
        emitError(nil, code: "CleanupIncomplete", message: reason)
    }

    private func emitExit(_ record: SessionRecord, code: Int32, signal: Int32) {
        guard record.attached, !record.exitEmitted else { return }
        record.exitEmitted = true
        guard record.statusObserved else {
            emitError(record, code: "ExitStatusUnavailable",
                      message: "authority closed the session without an exit status")
            return
        }
        emit([
            "kind": "terminal.exit",
            "pageId": record.pageId, "generation": record.generation,
            "sessionId": Self.safeInt(record.id),
            "code": Int(code),
            "signal": Int(signal),
        ])
    }

    private func emit(_ event: [String: Any]) {
        let recipient = (event["sessionId"] as? Int).flatMap { Self.handoffTarget(sessionId: $0, source: self) } ?? self
        DispatchQueue.main.async { [weak recipient] in recipient?.onEvent?(event) }
    }

    /// One nonblocking write per queue turn keeps cancellation and close requests responsive.
    private func scheduleInputPump(_ record: SessionRecord, after delay: DispatchTimeInterval = .nanoseconds(0)) {
        guard owns(record), record.hasPendingInput, record.scheduleInputPump() else { return }
        record.queue.asyncAfter(deadline: .now() + delay) { [weak self, record] in
            guard let self else { return }
            record.clearInputPumpScheduled()
            guard self.owns(record),
                  let chunk = record.inputChunk(maxLength: 16 * 1024) else { return }
            let written = chunk.withUnsafeBytes { pointer in
                codipad_kernel_input(record.id, pointer.baseAddress, pointer.count)
            }
            if written > 0 {
                record.consumeInput(min(Int(written), chunk.count))
                self.scheduleInputPump(record, after: .nanoseconds(0))
            } else if written == 0 || written == -Int32(EAGAIN) || written == -Int32(EWOULDBLOCK) {
                let result = codipad_kernel_set_input_ready_callback(record.id, terminalInputReadyCallback)
                if result != 0 {
                    record.discardInput()
                    self.emitError(record, code: "InputWriteFailed", message: "terminal input readiness failed: \(result)")
                }
            } else {
                record.discardInput()
                self.emitError(record, code: "InputWriteFailed",
                              message: "terminal input write failed: \(Self.posixMessage(Int32(written)))")
                _ = codipad_kernel_signal(record.id, SIGHUP)
            }
        }
    }

    fileprivate func inputReady(_ record: SessionRecord) {
        // Kernel invokes this under its tty lock. Never call back into the kernel here.
        record.queue.async { [weak self, record] in
            guard let self, self.owns(record) else { return }
            self.scheduleInputPump(record)
        }
    }

    private func emitError(_ record: SessionRecord?, code: String, message: String) {
        var event: [String: Any] = ["kind": "terminal.error", "code": code, "message": message]
        if let record {
            event["sessionId"] = Self.safeInt(record.id)
            event["pageId"] = record.pageId; event["generation"] = record.generation
        }
        emit(event)
    }

    // MARK: - Callback delivery

    /// Runs on the guest thread (or the attach flush). Copies before returning; no kernel call.
    fileprivate func deliverOutput(_ record: SessionRecord, data: Data, context: SessionContext) {
        guard record.appendOutput(data, byteLimit: maxPendingOutputBytes,
                                               eventLimit: maxPendingOutputEvents) != nil else {
            deliverOutputOverflow(record)
            return
        }
        scheduleOutputDrain(record)
    }

    private func scheduleOutputDrain(_ record: SessionRecord) {
        guard record.scheduleOutputDrain() else { return }
        record.queue.async { [weak self, record] in
            guard let self, self.owns(record) else { return }
            guard record.outputWrite == nil, !record.stateFailed else { return }
            // A bounded batch gives input and other sessions a turn between parser operations.
            let events = record.outputEvents(after: record.mirroredThrough, byteLimit: 64 * 1024, eventLimit: 256)
            guard !events.isEmpty else {
                record.clearOutputDrainScheduled()
                // A producer may append after the empty read while the scheduled flag is still set.
                // Recheck after clearing it so that producer cannot lose its only wakeup.
                if record.lastOutputDataId > record.mirroredThrough { scheduleOutputDrain(record) }
                return
            }
            var bytes = Data()
            for (_, data) in events { bytes.append(data) }
            let task = record.state.writeAsync(bytes) { [weak self, record] completed in
                record.queue.async { [weak self, record] in
                    guard let self, self.owns(record),
                          record.outputWrite?.1 === completed else { return }
                    do {
                        try self.finishOutputWrite(record)
                        self.scheduleOutputDrain(record)
                    } catch { self.outputStateFailed(record) }
                }
            }
            record.outputWrite = (events, task)
        }
    }

    private func outputStateFailed(_ record: SessionRecord) {
        record.stateFailed = true
        emitError(record, code: "TerminalStateFailed", message: "terminal state could not consume output")
    }

    private func finishOutputWrite(_ record: SessionRecord) throws {
        guard let (events, task) = record.outputWrite else { return }
        let replies = try task.wait()
        for reply in replies {
            let data = Data(reply.utf8)
            guard data.isEmpty || record.enqueueInput(data, byteLimit: maxInputBytes, eventLimit: maxInputEvents) else {
                throw NativeTerminalHostError.inputQueueFull
            }
        }
        if !replies.isEmpty { scheduleInputPump(record) }
        record.outputWrite = nil
        record.clearOutputDrainScheduled()
        record.mirroredThrough = events.last!.0
        emitOutput(record, events: events)
    }

    private func emitOutput(_ record: SessionRecord, events: [(UInt64, Data)]) {
        guard record.attached else { return }
        let unsent = events.filter { $0.0 > record.sentThrough }
        guard let last = unsent.last else { return }
        var data = Data()
        for (_, bytes) in unsent { data.append(bytes) }
        emit(["kind": "terminal.data", "sessionId": Self.safeInt(record.id),
              "pageId": record.pageId, "generation": record.generation,
              "dataId": Self.safeInt(last.0), "dataIds": unsent.map { Self.safeInt($0.0) },
              "byteCount": data.count, "data": data.base64EncodedString()])
        record.sentThrough = last.0
    }

    /// Explicit state/exit barriers drain only the output present when the barrier began.
    /// Ordinary delivery uses asynchronous bounded drains above.
    private func flushOutput(_ record: SessionRecord) throws {
        guard !record.stateFailed else { throw NativeTerminalHostError.invalidRequest("terminal state failed") }
        let through = record.lastOutputDataId
        try finishOutputWrite(record)
        var after = record.attached ? min(record.mirroredThrough, record.sentThrough) : record.mirroredThrough
        while after < through {
            let events = record.outputEvents(after: after, through: through, byteLimit: 64 * 1024, eventLimit: 256)
            guard let last = events.last else { break }
            let fresh = events.filter { $0.0 > record.mirroredThrough }
            if !fresh.isEmpty {
                var data = Data()
                for (_, bytes) in fresh { data.append(bytes) }
                try record.state.write(data)
                record.mirroredThrough = fresh.last!.0
            }
            emitOutput(record, events: events)
            after = last.0
        }
    }

    fileprivate func deliverOutputOverflow(_ record: SessionRecord) {
        record.queue.async { [weak self, record] in
            guard let self, self.owns(record) else { return }
            self.emitError(record, code: "OutputOverflow", message: "terminal output buffer exceeded")
            _ = codipad_kernel_signal(record.id, SIGHUP)
        }
    }

    /// Runs on the main->io handoff. Completion is decided by the authority, never by this alone.
    fileprivate func deliverExit(
        _ record: SessionRecord,
        code: Int32,
        signal: Int32,
        allReaped: Bool,
        context: SessionContext
    ) {
        record.queue.async { [weak self, context] in
            _ = context
            guard let self, self.owns(record) else { return }
            record.leaderCode = code
            record.leaderSignal = signal
            record.statusObserved = true
            if allReaped {
                record.reaped = true
                self.confirmOrReconcile(record, attempt: 0)
            } else {
                // Leader exit only: the authority still owns members. Poll until it confirms.
                record.cleanupPending = true
                self.reconcileLeaderExit(record, attempt: 0)
            }
        }
    }

    /// Polls the authority (not a lifetime fix) until close==0 confirms the real exit.
    private func reconcileLeaderExit(_ record: SessionRecord, attempt: Int) {
        guard owns(record) else { return }
        guard attempt < 40 else {
            record.cleanupPending = true
            if record.removeAfterSettlement {
                emitError(record, code: "CleanupIncomplete", message: "terminal cleanup has not been confirmed")
            } else {
                quarantine("session \(record.id) did not confirm cleanup after leader exit")
            }
            return
        }
        record.queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            guard let self, self.owns(record) else { return }
            var info = codipad_session_info()
            let result = codipad_kernel_info(record.id, &info)
            if result == 0, info.reaped, info.all_descendants_reaped {
                self.confirmOrReconcile(record, attempt: 0)
            } else {
                self.reconcileLeaderExit(record, attempt: attempt + 1)
            }
        }
    }

    private func confirmOrReconcile(_ record: SessionRecord, attempt: Int) {
        guard owns(record) else { return }
        do {
            try closeRecord(record, graceMs: 0)
            if record.removeAfterSettlement { finishRecord(record) }
        } catch {
            guard attempt < 40 else {
                record.cleanupPending = true
                if record.removeAfterSettlement {
                    emitError(record, code: "CleanupIncomplete", message: "terminal cleanup has not been confirmed")
                } else {
                    quarantine("close could not confirm session \(record.id): \(error)")
                }
                return
            }
            record.queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                self?.confirmOrReconcile(record, attempt: attempt + 1)
            }
        }
    }

    /// Per-session guest defaults; caller values override. Never touches process-global env.
    private func mergedEnvironment(_ provided: [String: String], unsetEnv: [String]) throws -> [String: String] {
        try onQueue {
            guard let defaults = preparedEnvironment else {
                throw NativeTerminalHostError.processHomeUnavailable("process directories have not been prepared")
            }
            return try Self.mergeEnvironment(defaults: defaults, provided: provided, unsetEnv: unsetEnv)
        }
    }

    private static func mergeEnvironment(defaults: [String: String], provided: [String: String],
                                         unsetEnv: [String]) throws -> [String: String] {
        var merged = defaults
        for key in unsetEnv {
            guard !key.isEmpty, !key.contains("="), !key.contains("\0") else {
                throw NativeTerminalHostError.invalidRequest("invalid environment removal key: \(key)")
            }
            merged.removeValue(forKey: key)
        }
        for (key, value) in provided {
            guard !key.isEmpty,
                  !key.contains("="),
                  !key.contains("\0"),
                  !value.contains("\0") else {
                throw NativeTerminalHostError.invalidRequest("invalid environment entry: \(key)")
            }
            merged[key] = value
        }
        return merged
    }

    // MARK: - Workspace mapping

    private func canonicalWorkspace(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw NativeTerminalHostError.invalidWorkspace("workspace must be a file URL")
        }
        // The grant already stores the POSIX realpath spelling. Foundation URL resolution can
        // rewrite /private/var back to /var, which is a different string from C realpath even
        // though both names reach the same directory. Keep the filesystem authority's path.
        let rootPath: String
        do {
            rootPath = try leaseOwner.authorizedDirectoryAccess(rootURI: url.absoluteString).rootPath
        } catch {
            throw NativeTerminalHostError.invalidWorkspace("workspace is not an authorized directory")
        }
        let canonical = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard canonical.path == rootPath else {
            throw NativeTerminalHostError.invalidWorkspace("workspace path could not be preserved")
        }
        return canonical
    }

    /// Resolves an optional native cwd URI to its canonical guest path. The native absolute path is
    /// primary; the embedded backend retains `/workspace` for older shell fixtures.
    private func guestPath(cwdURI: String?, workspace: URL) throws -> String {
        guard let cwdURI else { return workspace.path }
        guard let url = URL(string: cwdURI), url.isFileURL else {
            throw NativeTerminalHostError.invalidRequest("cwdURI must be a file URL")
        }
        // Validate cwd by the same held directory authority as the editor, including a
        // secondary root. An empty workspace never substitutes its config file's parent.
        let candidate: String
        do { candidate = try leaseOwner.authorizedDirectoryAccess(rootURI: url.absoluteString).rootPath }
        catch { throw NativeTerminalHostError.invalidRequest("cwdURI is not an authorized directory") }
        let roots = onQueue { workspaceRootAccess.map { $0.rootPath } }
        // The validated session root can be the private process home even if earlier
        // workspace grants remain retained by this window.
        let allowedRoots = roots + [workspace.path]
        guard allowedRoots.contains(where: { candidate == $0 || candidate.hasPrefix($0 + "/") }) else {
            throw NativeTerminalHostError.cwdOutsideWorkspace(candidate)
        }
        return candidate
    }

    private func nativeURL(forGuest guest: String, workspace: URL) -> URL? {
        let workspacePath = workspace.path
        if guest.withCString({ codipad_kernel_native_path_is_mounted($0) }) {
            return URL(fileURLWithPath: guest, isDirectory: true)
        }
        guard case .embedded = processRuntime else { return nil }
        guard guest == Self.guestWorkspace || guest.hasPrefix(Self.guestWorkspace + "/") else {
            return nil
        }
        let relative = String(guest.dropFirst(Self.guestWorkspace.count))
        return relative.isEmpty ? workspace : URL(fileURLWithPath: workspacePath + relative, isDirectory: true)
    }

    // MARK: - Helpers

    /// Request execution never waits on the bridge queue or another session's parser.
    func performRequest(sessionId: Int?, processIdentity: String? = nil, _ operation: @escaping () -> Void) {
        let record: SessionRecord? = onQueue {
            if let sessionId, sessionId > 0 { return sessions[UInt64(sessionId)] }
            if let processIdentity { return sessions.values.first { self.processIdentity($0) == processIdentity } }
            return nil
        }
        if let record { record.queue.async(execute: operation) }
        else { DispatchQueue.global(qos: .userInitiated).async(execute: operation) }
    }

    private func owns(_ record: SessionRecord) -> Bool {
        onQueue { sessions[record.id] === record }
    }

    private func onSessionQueue<T>(_ sessionId: Int, _ body: () throws -> T) throws -> T {
        let record = try session(sessionId)
        return try record.onQueue {
            guard owns(record) else { throw NativeTerminalHostError.unknownSession(sessionId) }
            return try body()
        }
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try ioQueue.sync(execute: body)
    }

    private static func safeInt(_ value: UInt64) -> Int {
        value > UInt64(Int.max) ? Int.max : Int(value)
    }

    private static func posixMessage(_ code: Int32) -> String {
        String(cString: strerror(code < 0 ? -code : code))
    }
}

// MARK: - Session bookkeeping

private final class SessionRecord {
    let queue = DispatchQueue(label: "dev.codipad.terminal.session", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()

    func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }

    let id: UInt64
    let context: SessionContext
    let workspace: URL
    let state: NativeTerminalState
    let shellIntegrationNonce: String
    var workspaceId: String
    let shouldPersist: Bool
    let launchMetadata: [String: Any]
    let recordIdentity = UUID().uuidString
    var launchConfig: [String: Any]?
    var wasRevived = false
    var processEnvironment: [String: String] = [:]
    var pageId: String
    var generation = UUID().uuidString
    var attached = true
    struct Handoff {
        let id: String
        let targetPage: String
        let targetWorkspace: String
        let generation: String
        let cut: UInt64
    }
    var handoff: Handoff?
    var snapshotCut: UInt64?
    var mirroredThrough: UInt64 = 0
    var sentThrough: UInt64 = 0
    var settled = false
    var stateFailed = false
    var metadata: [String: Any] = [:]
    var guestCwd: String
    var pid: UInt64
    var leaderCode: Int32 = 0
    var leaderSignal: Int32 = 0
    var reaped = false
    var statusObserved = false
    var exitEmitted = false
    var cleanupPending = false
    var removeAfterSettlement = false
    var outputDeliveryFailed = false
    private var inputQueue: [Data] = []
    private var inputOffset = 0
    private(set) var pendingInputBytes = 0
    private var inputPumpScheduled = false
    private let outputLock = NSLock()
    private var pendingOutputBytes = 0
    private var nextOutputDataId: UInt64 = 1
    private var outputEventData: [UInt64: Data] = [:]
    private var outputEventIds: [UInt64] = []
    private var outputHead = 0
    private var outputDrainScheduled = false
    var outputWrite: ([(UInt64, Data)], NativeTerminalState.Write)?

    func scheduleOutputDrain() -> Bool {
        outputLock.lock(); defer { outputLock.unlock() }
        guard !outputDrainScheduled else { return false }
        outputDrainScheduled = true
        return true
    }

    func clearOutputDrainScheduled() {
        outputLock.lock(); defer { outputLock.unlock() }
        outputDrainScheduled = false
    }

    init(id: UInt64, context: SessionContext, workspace: URL, guestCwd: String, pid: UInt64, shellIntegrationNonce: String,
         state: NativeTerminalState, workspaceId: String, pageId: String, shouldPersist: Bool, launchMetadata: [String: Any]) {
        queue.setSpecific(key: queueKey, value: ())
        self.launchMetadata = launchMetadata
        self.shellIntegrationNonce = shellIntegrationNonce
        self.state = state; self.workspaceId = workspaceId; self.pageId = pageId; self.shouldPersist = shouldPersist
        self.id = id
        self.context = context
        self.workspace = workspace
        self.guestCwd = guestCwd
        self.pid = pid
    }

    var pendingOutputByteCount: Int {
        outputLock.lock()
        defer { outputLock.unlock() }
        return pendingOutputBytes
    }

    func enqueueInput(_ data: Data, byteLimit: Int, eventLimit: Int) -> Bool {
        guard data.count <= byteLimit - pendingInputBytes, inputQueue.count < eventLimit else { return false }
        inputQueue.append(data)
        pendingInputBytes += data.count
        return true
    }

    var hasPendingInput: Bool { pendingInputBytes > 0 }

    func scheduleInputPump() -> Bool {
        guard !inputPumpScheduled else { return false }
        inputPumpScheduled = true
        return true
    }

    func clearInputPumpScheduled() { inputPumpScheduled = false }

    func inputChunk(maxLength: Int) -> Data? {
        guard let first = inputQueue.first else { return nil }
        return first.subdata(in: inputOffset..<min(first.count, inputOffset + maxLength))
    }

    func consumeInput(_ count: Int) {
        guard count > 0, let first = inputQueue.first else { return }
        let consumed = min(count, first.count - inputOffset)
        inputOffset += consumed
        pendingInputBytes -= consumed
        if inputOffset == first.count {
            inputQueue.removeFirst()
            inputOffset = 0
        }
    }

    func discardInput() {
        inputQueue.removeAll(keepingCapacity: false)
        inputOffset = 0
        pendingInputBytes = 0
        inputPumpScheduled = false
    }

    func appendOutput(_ data: Data, byteLimit: Int, eventLimit: Int) -> UInt64? {
        outputLock.lock()
        defer { outputLock.unlock() }
        guard data.count <= byteLimit - pendingOutputBytes,
              outputEventData.count < eventLimit else { return nil }
        let dataId = nextOutputDataId
        guard dataId <= 9_007_199_254_740_991 else { return nil }
        nextOutputDataId += 1
        pendingOutputBytes += data.count
        outputEventData[dataId] = data
        outputEventIds.append(dataId)
        return dataId
    }

    var lastOutputDataId: UInt64 {
        outputLock.lock(); defer { outputLock.unlock() }
        return nextOutputDataId - 1
    }

    func outputEvents(after: UInt64 = 0, through: UInt64 = UInt64.max,
                      byteLimit: Int = Int.max, eventLimit: Int = Int.max) -> [(UInt64, Data)] {
        outputLock.lock(); defer { outputLock.unlock() }
        var result: [(UInt64, Data)] = []
        var bytes = 0
        // IDs are append-ordered; binary search avoids rescanning unacknowledged output.
        var lo = outputHead, hi = outputEventIds.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if outputEventIds[mid] <= after { lo = mid + 1 } else { hi = mid }
        }
        for index in lo..<outputEventIds.count {
            let id = outputEventIds[index]
            if id > through { break }
            guard let data = outputEventData[id] else { continue }
            if !result.isEmpty && (data.count > byteLimit - bytes || result.count == eventLimit) { break }
            result.append((id, data)); bytes += data.count
        }
        return result
    }

    func acknowledgeOutput(_ dataId: UInt64) -> Int {
        outputLock.lock()
        let released = outputEventData.removeValue(forKey: dataId)?.count ?? 0
        pendingOutputBytes = max(0, pendingOutputBytes - released)
        while outputHead < outputEventIds.count && outputEventData[outputEventIds[outputHead]] == nil { outputHead += 1 }
        if outputHead > 1024 && outputHead * 2 >= outputEventIds.count {
            outputEventIds.removeFirst(outputHead); outputHead = 0
        }
        outputLock.unlock()
        return released
    }

    func outputEventByteCount(_ dataId: UInt64) -> Int? {
        outputLock.lock()
        defer { outputLock.unlock() }
        return outputEventData[dataId]?.count
    }
}

/// Context handed to the C callbacks. Retained for the whole session (including leader-only exit),
/// and holds bytes that arrive before the Swift record is attached.
private final class SessionContext {
    weak var host: NativeTerminalHost?
    private let lock = NSLock()
    private var record: SessionRecord?
    private var earlyOutput: [Data] = []
    private var earlyBytes = 0
    private var earlyOverflowed = false
    private var earlyExit: (code: Int32, signal: Int32, allReaped: Bool)?

    init(host: NativeTerminalHost) {
        self.host = host
    }

    func attach(_ record: SessionRecord) {
        lock.lock()
        let output = earlyOutput
        earlyOutput = []
        earlyBytes = 0
        let exit = earlyExit
        earlyExit = nil

        if earlyOverflowed {
            host?.deliverOutputOverflow(record)
        }
        for data in output {
            host?.deliverOutput(record, data: data, context: self)
        }
        // Keep callbacks queued on this lock until early output has entered the host byte ledger.
        self.record = record
        lock.unlock()
        if let exit {
            host?.deliverExit(record, code: exit.code, signal: exit.signal, allReaped: exit.allReaped, context: self)
        }
    }

    /// Breaks the context<->record cycle once the authority confirms cleanup.
    func detach() {
        lock.lock()
        record = nil
        earlyOutput = []
        earlyBytes = 0
        earlyExit = nil
        lock.unlock()
    }

    func receiveInputReady() {
        lock.lock()
        let target = record
        lock.unlock()
        if let target { host?.inputReady(target) }
    }

    func receiveOutput(_ data: Data) {
        lock.lock()
        if let record {
            lock.unlock()
            host?.deliverOutput(record, data: data, context: self)
            return
        }
        if data.count <= terminalOutputByteLimit - earlyBytes &&
            earlyOutput.count < terminalOutputEventLimit {
            earlyOutput.append(data)
            earlyBytes += data.count
        } else {
            earlyOverflowed = true
        }
        lock.unlock()
    }

    func receiveExit(code: Int32, signal: Int32, allReaped: Bool) {
        lock.lock()
        if let record {
            lock.unlock()
            host?.deliverExit(record, code: code, signal: signal, allReaped: allReaped, context: self)
            return
        }
        earlyExit = (code, signal, allReaped)
        lock.unlock()
    }
}

private func terminalInputReadyCallback(_ session: UInt64, _ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    Unmanaged<SessionContext>.fromOpaque(ctx).takeUnretainedValue().receiveInputReady()
}

private func terminalOutputCallback(
    _ session: codipad_session_t,
    _ bytes: UnsafeRawPointer?,
    _ length: Int,
    _ context: UnsafeMutableRawPointer?
) {
    guard let bytes, length > 0, let context else { return }
    let box = Unmanaged<SessionContext>.fromOpaque(context).takeUnretainedValue()
    box.receiveOutput(Data(bytes: bytes, count: length))
}

private func terminalExitCallback(
    _ session: codipad_session_t,
    _ code: Int32,
    _ signal: Int32,
    _ allMembersReaped: Bool,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let box = Unmanaged<SessionContext>.fromOpaque(context).takeUnretainedValue()
    box.receiveExit(code: code, signal: signal, allReaped: allMembersReaped)
}

private func withCStringArray<T>(
    _ values: [String],
    _ body: (UnsafeMutableBufferPointer<UnsafeMutablePointer<CChar>?>) throws -> T
) rethrows -> T {
    var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    pointers.append(nil)
    defer {
        for pointer in pointers {
            if let pointer { free(pointer) }
        }
    }
    return try pointers.withUnsafeMutableBufferPointer { try body($0) }
}

// MARK: - Errors

enum NativeTerminalHostError: LocalizedError, CustomStringConvertible {
    case processHomeUnavailable(String)
    case invalidWorkspace(String)
    case workspaceMismatch(String)
    case cwdOutsideWorkspace(String)
    case rootfsMissing(String)
    case rootfsImportFailed(Int32, String)
    case kernelBootFailed(Int32, String)
    case nativeWorkspaceFailed(Int32)
    case spawnFailed(Int32, String)
    case writeFailed(Int32)
    case outputAckFailed(Int32)
    case inputQueueFull
    case resizeFailed(Int32)
    case signalFailed(Int32)
    case closeFailed(Int32)
    case cwdUnavailable(Int32)
    case unknownSession(Int)
    case incomplete(String)
    case invalidRequest(String)

    var code: String {
        switch self {
        case .processHomeUnavailable: return "ProcessHomeUnavailable"
        case .invalidWorkspace: return "InvalidWorkspace"
        case .workspaceMismatch: return "WorkspaceMismatch"
        case .cwdOutsideWorkspace: return "CwdOutsideWorkspace"
        case .rootfsMissing: return "RootfsMissing"
        case .rootfsImportFailed: return "RootfsImportFailed"
        case .kernelBootFailed: return "KernelBootFailed"
        case .nativeWorkspaceFailed: return "NativeWorkspaceFailed"
        case .spawnFailed: return "SpawnFailed"
        case .writeFailed: return "WriteFailed"
        case .outputAckFailed: return "OutputAckFailed"
        case .inputQueueFull: return "InputQueueFull"
        case .resizeFailed: return "ResizeFailed"
        case .signalFailed: return "SignalFailed"
        case .closeFailed: return "CloseFailed"
        case .cwdUnavailable: return "CwdUnavailable"
        case .unknownSession: return "UnknownSession"
        case .incomplete: return "Incomplete"
        case .invalidRequest: return "InvalidRequest"
        }
    }

    var message: String {
        switch self {
        case .processHomeUnavailable(let detail): return "process home is unavailable: \(detail)"
        case .invalidWorkspace(let detail): return detail
        case .workspaceMismatch(let detail): return detail
        case .cwdOutsideWorkspace(let path): return "cwd is outside the mounted workspace: \(path)"
        case .rootfsMissing(let detail): return detail
        case .rootfsImportFailed(let code, let detail): return "rootfs import failed (\(code)): \(detail)"
        case .kernelBootFailed(let code, let phase): return "kernel boot failed during \(phase) (\(code))"
        case .nativeWorkspaceFailed(let code): return "native workspace binding failed (\(code))"
        case .spawnFailed(let code, let detail): return "spawn failed (\(code)): \(detail)"
        case .writeFailed(let code): return "pty write failed (\(code))"
        case .outputAckFailed(let code): return "pty output acknowledgement failed (\(code))"
        case .inputQueueFull: return "terminal input queue is full"
        case .resizeFailed(let code): return "pty resize failed (\(code))"
        case .signalFailed(let code): return "signal failed (\(code))"
        case .closeFailed(let code): return "close failed (\(code))"
        case .cwdUnavailable(let code): return "guest cwd unavailable (\(code))"
        case .unknownSession(let id): return "session \(id) is not retained"
        case .incomplete(let detail): return detail
        case .invalidRequest(let detail): return detail
        }
    }

    var errorDescription: String? { message }
    var description: String { "\(code): \(message)" }
}
