import CoreFoundation
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Typed error returned across the native file-service boundary.
public struct WorkspaceFileSystemError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String
    public let posixCode: Int32?

    public init(code: String, message: String, posixCode: Int32? = nil) {
        self.code = code
        self.message = message
        self.posixCode = posixCode
    }

    public static func fileNotFound(_ message: String) -> Self { .init(code: "FileNotFound", message: message) }
    public static func fileExists(_ message: String) -> Self { .init(code: "FileExists", message: message) }
    public static func noPermissions(_ message: String) -> Self { .init(code: "NoPermissions", message: message) }
    public static func fileNotADirectory(_ message: String) -> Self { .init(code: "FileNotADirectory", message: message) }
    public static func fileIsADirectory(_ message: String) -> Self { .init(code: "FileIsADirectory", message: message) }
    public static func fileTooLarge(_ message: String) -> Self { .init(code: "FileTooLarge", message: message) }
    public static func unavailable(_ message: String) -> Self { .init(code: "Unavailable", message: message) }
    public static func unknown(_ message: String) -> Self { .init(code: "Unknown", message: message) }

    public var description: String { "\(code): \(message)" }
}

/// App-owned native filesystem session over one or more authorized roots.
///
/// This is the single backing store: grants name real directories and files, and every operation
/// works on them in place. Nothing is copied or synchronized.
///
/// Authorization model:
/// - A grant retains its `WorkspaceLease` (directory) or its own OS scope (file) for the lifetime
///   of this object, and releases them on `deinit`.
/// - The root anchor is opened directly from the authorized canonical path, never by walking from
///   `/`; the app has no authority over a folder's ancestors, only over the selection itself.
/// - Relative paths are resolved with `openat` + `O_NOFOLLOW` from a directory descriptor held for
///   the grant. Operations act on held descriptors. Moves observed before resolution fail closed;
///   concurrent external renames retain descriptor capability semantics, not atomic containment.
///   Without an explicit WorkspaceNamespace, links resolve only within the same retained grant.
///   A namespace admits only its original adapters and coordinates through destination owners.
/// - Before every operation the grant's authorized directory is re-stat'ed and compared with the
///   descriptor's `dev`/`ino`. A moved or replaced root/parent fails closed with `Unavailable`
///   instead of silently operating on whatever now answers at the old URI.
/// - External grants (security-scoped directories and files) coordinate every operation with
///   `NSFileCoordinator` on the originally selected URL, with the descriptor-relative I/O kept
///   inside the coordinator block, as Apple requires for directories the app was given access to.
/// - Ordinary writes update the existing inode; atomic writes stage in the authorized parent
///   and publish by rename, except for symlinks, which follow desktop's in-place behavior.
///
/// Not thread-safe: the caller serializes calls on its I/O queue.
public final class WorkspaceFileSystem {
    /// Maximum bytes in one `fs.readFile` or `fs.writeFile` payload.
    public static let maxTransferBytes = 16 * 1024 * 1024

    internal typealias BeginScope = (URL) -> Bool
    internal typealias EndScope = (URL) -> Void
    /// `(url, forWriting, body)`: run `body` inside one coordinated access to `url`.
    internal typealias Coordinator = (URL, Bool, @escaping () throws -> Any) throws -> Any
    /// Coordinate a source and destination together for an atomic provider-aware move.
    internal typealias MoveCoordinator = (URL, URL, @escaping () throws -> Any) throws -> Any
    /// Reports the name-case semantics of the volume containing an authorized selection.
    internal typealias CaseSensitivity = (URL) throws -> Bool?

    private let access: WorkspaceAccess
    private let beginFileScope: BeginScope
    private let endFileScope: EndScope
    private let coordinateHook: Coordinator
    private let coordinateMoveHook: MoveCoordinator
    private let caseSensitivity: CaseSensitivity
    private var grants: [Grant] = []
    internal var namespace: WorkspaceNamespace?
    private var watchers: [Int: WorkspaceFileWatcher] = [:]
    private var nextWatcherID = 1
    private var nextAccessGeneration: UInt64 = 1
    private struct OpenFile {
        let fd: Int32
        let uri: String
        let writing: Bool
        let device: dev_t
        let inode: ino_t
    }
    private var openFiles: [Int: OpenFile] = [:]
    private var nextOpenFileID = 1
    private struct StagedFile {
        let fd: Int32
        let params: [String: Any]
        let parentFD: Int32
        let temporary: String
        var length: Int
    }
    private var stagedFiles: [Int: StagedFile] = [:]

    public convenience init(access: WorkspaceAccess) {
        self.init(
            access: access,
            beginFileScope: { $0.startAccessingSecurityScopedResource() },
            endFileScope: { $0.stopAccessingSecurityScopedResource() },
            coordinate: WorkspaceFileSystem.systemCoordinate,
            coordinateMove: WorkspaceFileSystem.systemCoordinateMove,
            caseSensitivity: { url in
                try url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                    .volumeSupportsCaseSensitiveNames
            }
        )
    }

    internal init(access: WorkspaceAccess, beginFileScope: @escaping BeginScope,
                  endFileScope: @escaping EndScope, coordinate: @escaping Coordinator,
                  coordinateMove: @escaping MoveCoordinator,
                  caseSensitivity: @escaping CaseSensitivity = { url in
                      try url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
                          .volumeSupportsCaseSensitiveNames
                  }) {
        self.access = access
        self.beginFileScope = beginFileScope
        self.endFileScope = endFileScope
        self.coordinateHook = coordinate
        self.coordinateMoveHook = coordinateMove
        self.caseSensitivity = caseSensitivity
    }

    deinit {
        for file in openFiles.values { close(file.fd) }
        for file in stagedFiles.values { Self.cleanupStage(file) }
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        for grant in grants { grant.releaseResources() }
        grants.removeAll()
    }

    /// Default coordination uses the real `NSFileCoordinator` on the selected URL.
    internal static func systemCoordinate(_ url: URL, forWriting: Bool,
                                          _ body: @escaping () throws -> Any) throws -> Any {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<Any, Error>?
        let accessor: (URL) -> Void = { _ in outcome = Result { try body() } }
        if forWriting {
            coordinator.coordinate(writingItemAt: url, options: .forMerging,
                                   error: &coordinationError, byAccessor: accessor)
        } else {
            coordinator.coordinate(readingItemAt: url, options: [],
                                   error: &coordinationError, byAccessor: accessor)
        }
        if let coordinationError {
            throw WorkspaceFileSystemError.unavailable(
                "file coordination failed: \(coordinationError.localizedDescription)")
        }
        guard let outcome else {
            throw WorkspaceFileSystemError.unavailable("file coordination did not run the operation")
        }
        return try outcome.get()
    }

    /// Coordinates both sides of an external rename as one file-provider move.
    internal static func systemCoordinateMove(_ source: URL, _ destination: URL,
                                              _ body: @escaping () throws -> Any) throws -> Any {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<Any, Error>?
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: destination, options: .forReplacing,
                               error: &coordinationError) { _, _ in
            outcome = Result { try body() }
        }
        if let coordinationError {
            throw WorkspaceFileSystemError.unavailable(
                "file coordination failed: \(coordinationError.localizedDescription)")
        }
        guard let outcome else {
            throw WorkspaceFileSystemError.unavailable("file coordination did not run the move")
        }
        return try outcome.get()
    }

    // MARK: - Grants

    /// Capture the selected volume's semantics while its grant is active. Unknown metadata fails
    /// closed because callers need a truthful resource-specific identity answer.
    private func caseSensitiveNames(for url: URL) throws -> Bool {
        guard let value = try caseSensitivity(url) else {
            throw WorkspaceFileSystemError.unavailable("cannot determine case sensitivity for authorized volume")
        }
        return value
    }

    /// Authorizes an existing directory for the session and returns its canonical `file:` URI.
    public func grantDirectory(_ url: URL, securityScoped: Bool) throws -> String {
        let lease: WorkspaceLease
        do {
            lease = try access.acquire(rootURL: url, securityScoped: securityScoped)
        } catch let error as WorkspaceAccessError {
            throw Self.map(error)
        }

        let caseSensitiveNames: Bool
        do {
            caseSensitiveNames = try self.caseSensitiveNames(for: lease.selectedURL)
        } catch {
            lease.release()
            throw error
        }

        // `realpath` resolves every component (Foundation leaves `/var` unresolved); the anchored
        // descriptors are opened from this fully resolved path.
        guard let path = Self.realPath(lease.rootURL.path(percentEncoded: false)) else {
            lease.release()
            throw WorkspaceFileSystemError.fileNotFound("workspace root disappeared")
        }
        let rootFD: Int32
        do {
            rootFD = try Self.openCanonicalDirectory(path, context: "granted directory")
        } catch {
            lease.release()
            throw error
        }
        var info = stat()
        guard fstat(rootFD, &info) == 0 else {
            let error = Self.posixError(errno, "cannot inspect workspace root")
            close(rootFD)
            lease.release()
            throw error
        }

        grants.append(Grant(
            kind: .directory,
            path: path,
            accessGeneration: allocateAccessGeneration(),
            anchorFD: rootFD,
            fileName: nil,
            selectedURL: lease.selectedURL,
            pickedURL: url,
            needsCoordination: lease.needsCoordination,
            caseSensitiveNames: caseSensitiveNames,
            identityPath: path,
            identityDev: info.st_dev,
            identityIno: info.st_ino,
            finish: { lease.release() }
        ))
        return Self.uri(forPath: path, isDirectory: true)
    }

    /// Authorizes exactly one existing regular file and returns its canonical `file:` URI.
    ///
    /// The grant carries no authority over siblings or the parent directory: any URI other than
    /// this file's own is refused, even though the anchor descriptor is a directory.
    ///
    /// Authority is over the **directory entry** (held canonical parent + basename), not over an
    /// immutable inode. Normal atomic editor saves and external tools replace the inode at that
    /// name, and that replacement is intentionally allowed; only the name is authorized. Moving
    /// the parent directory still fails closed (see `verifyIdentity`).
    public func grantFile(_ url: URL, securityScoped: Bool) throws -> String {
        try Self.validateSelection(url)

        var scopeStarted = false
        if securityScoped {
            // Authorize before touching the directory entry: an external file may be unreadable
            // until the scope is active. The scope stays on this selected URL, not the canonical one.
            guard beginFileScope(url) else {
                throw WorkspaceFileSystemError.noPermissions("scope: security-scoped access was denied: \(url.path)")
            }
            scopeStarted = true
        }
        do {
            let caseSensitiveNames = try self.caseSensitiveNames(for: url)
            let originalPath = url.path(percentEncoded: false)
            // A selected symlink is not a file grant; refuse explicitly instead of following it.
            var entryStat = stat()
            guard lstat(originalPath, &entryStat) == 0 else {
                throw Self.posixError(errno, "cannot inspect \(originalPath)")
            }
            if (entryStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                throw WorkspaceFileSystemError.noPermissions("symbolic link cannot be granted as a file: \(originalPath)")
            }

            guard let path = Self.realPath(originalPath) else {
                throw WorkspaceFileSystemError.fileNotFound("file disappeared: \(originalPath)")
            }
            let parent = try Self.openParent(of: path)
            var adopted = false
            defer { if !adopted { close(parent.fd) } }
            // O_NONBLOCK so a FIFO can never block this open; only regular files are granted.
            let fd = openat(parent.fd, parent.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else {
                throw Self.posixError(errno, "cannot open \(path)")
            }
            var canonicalStat = stat()
            let statResult = fstat(fd, &canonicalStat)
            close(fd)
            guard statResult == 0 else {
                throw Self.posixError(errno, "cannot inspect \(path)")
            }
            guard (canonicalStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                throw WorkspaceFileSystemError.fileNotADirectory("not a regular file: \(path)")
            }
            var parentStat = stat()
            guard fstat(parent.fd, &parentStat) == 0 else {
                throw Self.posixError(errno, "cannot inspect parent directory")
            }
            guard let parentPath = Self.realPath(
                (path as NSString).deletingLastPathComponent) else {
                throw WorkspaceFileSystemError.fileNotFound("parent directory disappeared")
            }

            let endScope = endFileScope
            let scopeURL = url
            let grantedScope = securityScoped
            grants.append(Grant(
                kind: .file,
                path: path,
                accessGeneration: allocateAccessGeneration(),
                anchorFD: parent.fd,
                fileName: parent.name,
                selectedURL: scopeURL,
                needsCoordination: securityScoped,
                caseSensitiveNames: caseSensitiveNames,
                identityPath: parentPath,
                identityDev: parentStat.st_dev,
                identityIno: parentStat.st_ino,
                finish: {
                    if grantedScope { endScope(scopeURL) }
                }
            ))
            adopted = true
            // Ownership of the scope moved into the grant.
            scopeStarted = false
            return Self.uri(forPath: path, isDirectory: false)
        } catch {
            if scopeStarted { endFileScope(url) }
            throw error
        }
    }

    /// Runs a batch of grants atomically from the caller's point of view.
    ///
    /// If `body` throws, only the grants appended during this call are closed and released
    /// (including their scopes) and removed; earlier grants and their authorization survive.
    /// The caller still serializes on its I/O queue.
    public func withGrantTransaction<T>(_ body: (WorkspaceFileSystem) throws -> T) rethrows -> T {
        let start = grants.count
        do {
            return try body(self)
        } catch {
            for grant in grants[start...] { grant.releaseResources() }
            grants.removeSubrange(start...)
            throw error
        }
    }

    /// Creates a process-thread-safe adapter bound to one existing directory grant. The returned
    /// object retains this authority and grant until its owner releases it after a successful join.
    public func nativeToolAccess(rootURI: String) throws -> WorkspaceNativeToolAccess {
        let target = try authorize(rootURI)
        guard target.grant.kind == .directory, target.components.isEmpty else {
            throw WorkspaceFileSystemError.noPermissions("native tools require the granted workspace root")
        }
        return toolAccess(grant: target.grant)
    }

    /// Inspect only the exact retained picker selection, never an ancestor grant. For a file,
    /// the identity is its authorized parent and the final entry must remain a regular file.
    public func selectedGrantMetadata(canonicalURI: String, selectedURL: URL, isDirectory: Bool) throws -> (anchorURL: URL, metadata: stat) {
        guard let grant = grants.last(where: {
            $0.kind == (isDirectory ? .directory : .file) &&
            Self.uri(forPath: $0.path, isDirectory: isDirectory) == canonicalURI &&
            $0.pickedURL.standardizedFileURL == selectedURL.standardizedFileURL
        }) else { throw WorkspaceFileSystemError.noPermissions("no exact picker grant for selection") }
        return try withAuthorization(Target(grant: grant, components: []), writing: false) {
            var anchor = stat()
            guard fstat(grant.anchorFD, &anchor) == 0,
                  (anchor.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  anchor.st_dev == grant.identityDev, anchor.st_ino == grant.identityIno else {
                throw WorkspaceFileSystemError.unavailable("authorized anchor changed")
            }
            if let name = grant.fileName {
                var entry = stat()
                guard fstatat(grant.anchorFD, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
                      (entry.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                    throw WorkspaceFileSystemError.unavailable("authorized file is not a regular file")
                }
            }
            return (URL(fileURLWithPath: grant.identityPath, isDirectory: true), anchor)
        }
    }

    /// Retains the grant that authorized this exact file or directory; callers own returned descriptors.
    public func browserResourceAccess(rootURI: String) throws -> (isDirectory: Bool, generation: UInt64, open: (String) -> Int32) {
        if let directory = try? authorizedDirectoryAccess(rootURI: rootURI) {
            return (true, directory.accessGeneration, { path in directory.open(path: path, flags: O_RDONLY | O_NONBLOCK, mode: 0) })
        }
        let target = try authorize(rootURI)
        let descriptor = try withAuthorization(target, writing: false) { try self.openRegularFile(target) }
        var info = stat()
        let regular = fstat(descriptor, &info) == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        close(descriptor)
        guard regular else { throw WorkspaceFileSystemError.noPermissions("browser resource is not a regular file") }
        let lock = NSLock()
        return (false, target.grant.accessGeneration, { path in
            guard path.isEmpty else { return -1 }
            lock.lock(); defer { lock.unlock() }
            do { return try self.withAuthorization(target, writing: false) { try self.openRegularFile(target) } }
            catch { return -1 }
        })
    }

    /// Narrows an existing live directory grant to a descriptor-anchored descendant. It does not
    /// install or promote a grant, and retains the covering scope for the returned adapter's life.
    public func authorizedDirectoryAccess(rootURI: String) throws -> WorkspaceNativeToolAccess {
        try withAuthorization(rootURI, writing: false) { target in
            guard target.grant.kind == .directory else {
                throw WorkspaceFileSystemError.noPermissions("a file grant cannot authorize a workspace root")
            }
            if target.components.isEmpty { return self.toolAccess(grant: target.grant) }
            let fd = try self.withParent(target) { parent, name in
                try Self.refuseSymlink(parent, name)
                let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw Self.posixError(errno, "cannot anchor workspace directory") }
                return fd
            }
            var adopted = false
            defer { if !adopted { close(fd) } }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw Self.posixError(errno, "cannot inspect workspace directory") }
            let path = try Self.descriptorPath(fd)
            let covering = target.grant
            let expectedPath = target.components.reduce(covering.path) { ($0 as NSString).appendingPathComponent($1) }
            guard path == expectedPath else { throw WorkspaceFileSystemError.unavailable("workspace directory moved while anchoring") }
            try covering.verifyIdentity()
            let grant = Grant(kind: .directory, path: path, accessGeneration: self.allocateAccessGeneration(),
                anchorFD: fd, fileName: nil, selectedURL: URL(fileURLWithPath: path, isDirectory: true),
                needsCoordination: covering.needsCoordination, caseSensitiveNames: covering.caseSensitiveNames,
                identityPath: path, identityDev: info.st_dev, identityIno: info.st_ino,
                finish: { _ = covering })
            try grant.verifyIdentity()
            let access = self.toolAccess(grant: grant, covering: covering, release: { grant.releaseResources() })
            adopted = true
            return access
        }
    }

    internal func toolAccess(grant: Grant, covering: Grant? = nil, cwd: Int32? = nil, source: Grant? = nil, release: @escaping () -> Void = {}) -> WorkspaceNativeToolAccess {
        // Retain the filesystem (and its live scopes) and revalidate the covering identity too.
        func checked<T>(_ body: () throws -> T) throws -> T {
            try covering?.verifyIdentity()
            return try body()
        }
        let adapter = WorkspaceNativeToolAccess(
            rootPath: (source ?? grant).path,
            accessGeneration: (source ?? grant).accessGeneration,
            open: { path, flags, mode in try checked { try self.nativeToolOpen(path, flags: flags, mode: mode, grant: grant, cwd: cwd) } },
            stat: { path, result in try checked { try self.nativeToolStat(path, result: result, grant: grant, cwd: cwd) } },
            mkdir: { path, mode in try checked { try self.nativeToolMkdir(path, mode: mode, grant: grant, cwd: cwd) } },
            unlink: { path, directory in try checked { try self.nativeToolUnlink(path, directory: directory, grant: grant, cwd: cwd) } },
            rename: { from, to in try checked { try self.nativeToolRename(from, to: to, grant: grant, cwd: cwd) } },
            chdir: { path, buffer, capacity in try checked { try self.nativeToolChdir(path, resolved: buffer, capacity: capacity, grant: grant, cwd: cwd) } },
            listDirectory: { path in try checked { try self.nativeToolListDirectory(path, grant: grant, cwd: cwd) } },
            symlink: { linkTarget, linkPath in try checked { try self.nativeToolSymlink(linkTarget, linkPath: linkPath, grant: grant, cwd: cwd) } },
            readlink: { path, buffer, capacity, length in
                try checked { try self.nativeToolReadlink(path, buffer: buffer, capacity: capacity, outLength: length, grant: grant, cwd: cwd) }
            },
            acquire: { path in
                try checked {
                    let target = try self.nativeToolTarget(path, grant: grant, cwd: cwd)
                    if self.namespace != nil {
                        return try self.withParent(target, followFinal: true, resolved: { destination, parent, name in
                            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                            guard fd >= 0 else { throw Self.posixError(errno, "cannot acquire cwd") }
                            return self.toolAccess(grant: destination, cwd: fd, source: source ?? grant)
                        }) { _, _ in fatalError("resolved callback required") }
                    }
                    let fd = try self.nativeToolOpen(path, flags: O_RDONLY | O_DIRECTORY, mode: 0, grant: grant, cwd: cwd)
                    return self.toolAccess(grant: grant, covering: covering, cwd: fd, source: source ?? grant)
                }
            },
            release: { if let cwd { close(cwd) }; release() }
        )
        adapter.binding = WorkspaceNamespace.Binding(owner: self, grant: grant, covering: covering, isRoot: cwd == nil)
        return adapter
    }

    internal func namespaceFileSystem(_ view: WorkspaceNamespace) -> WorkspaceFileSystem {
        let result = WorkspaceFileSystem(access: access, beginFileScope: beginFileScope,
            endFileScope: endFileScope, coordinate: coordinateHook,
            coordinateMove: coordinateMoveHook, caseSensitivity: caseSensitivity)
        result.namespace = view
        return result
    }

    // MARK: - RPC

    /// Runs one file-service request. Unknown methods are rejected before any side effect.
    public func perform(_ method: String, params: [String: Any]) throws -> Any {
        switch method {
        case "fs.stat":
            return try statAuthorized(params)
        case "fs.pathCapabilities":
            return try pathCapabilitiesAuthorized(params)
        case "fs.readdir":
            return try readdirAuthorized(params)
        case "fs.readFile":
            return try readFileAuthorized(params)
        case "fs.writeFile":
            return try writeFileAuthorized(params)
        case "fs.open":
            return try openAuthorized(params)
        case "fs.close":
            let id = try integer(params, "handle")
            guard let file = openFiles.removeValue(forKey: id) else { throw WorkspaceFileSystemError.unavailable("invalid file handle") }
            guard close(file.fd) == 0 else { throw Self.posixError(errno, "cannot close file") }
            return NSNull()
        case "fs.read":
            return try transferAuthorized(params, writing: false)
        case "fs.write":
            return try transferAuthorized(params, writing: true)
        case "fs.stageBegin":
            return try stageBegin(params)
        case "fs.stageWrite":
            return try stageWrite(params)
        case "fs.stageCommit":
            let id = try integer(params, "handle")
            guard let file = stagedFiles.removeValue(forKey: id) else { throw WorkspaceFileSystemError.unavailable("invalid staged file") }
            defer { Self.cleanupStage(file) }
            return try writeAuthorized(file.params, stage: file) { destination in
                var offset = 0
                var buffer = [UInt8](repeating: 0, count: Self.chunkBytes)
                while offset < file.length {
                    let count = pread(file.fd, &buffer, min(buffer.count, file.length - offset), off_t(offset))
                    guard count > 0 else { throw Self.posixError(count < 0 ? errno : EIO, "cannot read staged file") }
                    try Self.writeData(Data(buffer.prefix(count)), to: destination)
                    offset += count
                }
            }
        case "fs.stageAbort":
            let id = try integer(params, "handle")
            if let file = stagedFiles.removeValue(forKey: id) { Self.cleanupStage(file) }
            return NSNull()
        case "fs.mkdir":
            return try mkdirAuthorized(params)
        case "fs.rename":
            return try renameAuthorized(params)
        case "fs.delete":
            return try deleteAuthorized(params)
        case "fs.watch":
            return try watchAuthorized(params)
        case "fs.unwatch":
            try unwatchAuthorized(params)
            return NSNull()
        default:
            throw WorkspaceFileSystemError.unknown("unknown file operation: \(method)")
        }
    }

    /// Reports identity semantics only for a path already covered by a live grant.
    private func pathCapabilitiesAuthorized(_ params: [String: Any]) throws -> Any {
        try withAuthorization(string(params, "uri"), writing: false) { target in
            ["pathCaseSensitive": target.grant.caseSensitiveNames]
        }
    }

    /// Starts a descriptor-backed watcher for an authorized directory. The subscription retains
    /// its grant through this authority until `fs.unwatch` or authority teardown.
    private func watchAuthorized(_ params: [String: Any]) throws -> Any {
        let uri = try string(params, "uri")
        let recursive = try bool(params, "recursive", default: false)
        let pruneNames = params["pruneNames"] as? [String] ?? []
        guard pruneNames.count <= 1024,
              pruneNames.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 255 && $0.utf8.allSatisfy {
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
              } }) else { throw WorkspaceFileSystemError.unknown("invalid watch prune names") }
        return try withAuthorization(uri, writing: false) { target in
            guard target.grant.fileName == nil else {
                throw WorkspaceFileSystemError.noPermissions("watch requires an authorized directory")
            }
            var destination = target.grant
            let fd: Int32
            if target.components.isEmpty {
                fd = openat(target.grant.anchorFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            } else {
                fd = try self.withParent(target, followFinal: self.namespace != nil, resolved: { grant, parent, name in
                    destination = grant
                    try Self.refuseSymlink(parent, name)
                    let opened = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard opened >= 0 else { throw Self.posixError(errno, "cannot open watched directory") }
                    return opened
                }) { _, _ in fatalError("resolved callback required") }
            }
            guard fd >= 0 else { throw Self.posixError(errno, "cannot open watched directory") }
            let id = self.nextWatcherID
            self.nextWatcherID += 1
            let basePath = target.grant.path + (target.components.isEmpty ? "" : "/" + target.components.joined(separator: "/"))
            let coordinator = self.coordinateHook
            let view = self.namespace
            let changeHandler = self.onFileChanges
            let watchErrorHandler = self.onWatchError
            let watchFailureHandler = self.onWatchFailure
            let diagnosticHandler = self.onWatchDiagnostic
            let coordinationURL = target.grant.coordinationURL(target.components)
            let watcher = WorkspaceFileWatcher(rootFD: fd, rootPath: basePath, recursive: recursive, pruneNames: Set(pruneNames),
                subscriptionID: id,
                coordinateScan: { [grant = destination] body in
                    if let view { return try view.authorize(grant, writing: false, body) }
                    guard grant.needsCoordination else { try body(); return }
                    var outcome: Result<Void, Error>?
                    _ = try coordinator(coordinationURL, false) {
                        do { try body(); outcome = .success(()) }
                        catch { outcome = .failure(error) }
                        return NSNull()
                    }
                    guard let outcome else {
                        throw WorkspaceFileSystemError.unavailable("file coordination did not run the watch scan")
                    }
                    try outcome.get()
                },
                onChanges: { id, changes in changeHandler?(id, changes) },
                onWatchError: { id, message in watchErrorHandler?(id, message) },
                onWatchFailure: { id, failure in watchFailureHandler?(id, failure) },
                onDiagnostic: diagnosticHandler)
            try watcher.start()
            self.watchers[id] = watcher
            return ["subscriptionId": id]
        }
    }

    private func unwatchAuthorized(_ params: [String: Any]) throws {
        guard let raw = params["subscriptionId"] as? NSNumber,
              CFGetTypeID(raw) != CFBooleanGetTypeID(), raw.intValue > 0 else {
            throw WorkspaceFileSystemError.unknown("missing or invalid 'subscriptionId'")
        }
        watchers.removeValue(forKey: raw.intValue)?.stop()
    }

    /// Stops all renderer subscriptions before the native bridge releases the workspace owner.
    public func stopAllWatches() {
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
    }

    /// Called on the dispatch source queue with canonical file URIs and VS Code change values.
    public var onFileChanges: ((Int, [[String: Any]]) -> Void)?

    /// Reports a terminal watcher failure after startup; keyed by subscription ID.
    public var onWatchError: ((Int, String) -> Void)?

    /// Uncapped, path-free scan failures, including temporarily inaccessible descendants.
    public var onWatchFailure: ((Int, WorkspaceWatchFailure) -> Void)?

    /// Optional metadata-only watch trace: subscription ID, step, and count. Nil by default.
    public var onWatchDiagnostic: ((Int, String, Int) -> Void)?

    // MARK: - Native tool workspace callbacks

    private func nativeToolTarget(_ path: String, grant: Grant, cwd: Int32? = nil) throws -> Target {
        guard !path.isEmpty, !path.contains("\0") else {
            throw WorkspaceFileSystemError.noPermissions("invalid native tool path")
        }
        if path.hasPrefix("/"), let namespace {
            var target = try namespace.target(path)
            target.absoluteAlias = WorkspacePaths.guestRoot
            return target
        }
        if !path.hasPrefix("/") {
            let suffix = path.hasSuffix("/") ? ["."] : []
            return Target(grant: grant, components: path.split(separator: "/").map(String.init) + suffix,
                          baseFD: cwd ?? grant.anchorFD, absoluteAlias: WorkspacePaths.guestRoot)
        }
        guard path == WorkspacePaths.guestRoot || path.hasPrefix(WorkspacePaths.guestRoot + "/") else {
            throw WorkspaceFileSystemError.noPermissions("native tool path is outside /workspace")
        }
        let suffix = path == WorkspacePaths.guestRoot ? "" : String(path.dropFirst(WorkspacePaths.guestRoot.count + 1))
        var components: [String] = []
        for component in suffix.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            if component == "." { continue }
            guard component != ".." else {
                throw WorkspaceFileSystemError.noPermissions("native tool parent traversal is unsupported")
            }
            components.append(component)
        }
        return Target(grant: grant, components: components, absoluteAlias: WorkspacePaths.guestRoot)
    }

    private func nativeToolOpen(_ path: String, flags: Int32, mode: UInt32, grant: Grant, cwd: Int32? = nil) throws -> Int32 {
        let target = try nativeToolTarget(path, grant: grant, cwd: cwd)
        let writing = flags & O_ACCMODE != O_RDONLY || flags & (O_CREAT | O_TRUNC | O_APPEND) != 0
        return try withAuthorization(target, writing: writing) {
            let fd: Int32
            if target.components.isEmpty {
                fd = openat(target.grant.anchorFD, ".", flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(mode))
            } else {
                let followFinal = flags & O_NOFOLLOW == 0 && flags & (O_CREAT | O_EXCL) != (O_CREAT | O_EXCL)
                fd = try self.withParent(target, followFinal: followFinal, writing: writing) { parent, name in
                    let opened = openat(parent, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(mode))
                    guard opened >= 0 else { throw Self.posixError(errno, "cannot open native workspace path") }
                    return opened
                }
            }
            guard fd >= 0 else { throw Self.posixError(errno, "cannot open native workspace root") }
            var info = stat()
            guard fstat(fd, &info) == 0 else {
                let error = Self.posixError(errno, "cannot inspect native workspace file")
                close(fd)
                throw error
            }
            let type = info.st_mode & mode_t(S_IFMT)
            guard type == mode_t(S_IFREG) || type == mode_t(S_IFDIR) else {
                close(fd)
                throw WorkspaceFileSystemError.unavailable("native tools support regular files and directories only")
            }
            return fd
        }
    }

    private func nativeToolStat(_ path: String, result: UnsafeMutablePointer<stat>, grant: Grant, cwd: Int32? = nil) throws -> Int32 {
        let target = try nativeToolTarget(path, grant: grant, cwd: cwd)
        return try withAuthorization(target, writing: false) {
            if target.components.isEmpty {
                guard fstat(target.grant.anchorFD, result) == 0 else { throw Self.posixError(errno, "cannot stat workspace root") }
            } else {
                try self.withParent(target) { parent, name in
                    guard fstatat(parent, name, result, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw Self.posixError(errno, "cannot stat native workspace path")
                    }
                }
            }
            return 0
        }
    }

    private func nativeToolMkdir(_ path: String, mode: UInt32, grant: Grant, cwd: Int32? = nil) throws -> Int32 {
        let target = try nativeToolTarget(path, grant: grant, cwd: cwd)
        guard !target.components.isEmpty else { throw WorkspaceFileSystemError.fileExists("workspace root exists") }
        return try withAuthorization(target, writing: true) {
            try self.withParent(target, writing: true) { parent, name in
                guard mkdirat(parent, name, mode_t(mode)) == 0 else { throw Self.posixError(errno, "cannot create native workspace directory") }
            }
            return 0
        }
    }

    private func nativeToolUnlink(_ path: String, directory: Bool, grant: Grant, cwd: Int32? = nil) throws -> Int32 {
        let target = try nativeToolTarget(path, grant: grant, cwd: cwd)
        guard !target.components.isEmpty else { throw WorkspaceFileSystemError.noPermissions("cannot remove workspace root") }
        return try withAuthorization(target, writing: true) {
            try self.withParent(target, writing: true) { parent, name in
                let flags: Int32 = directory ? AT_REMOVEDIR : 0
                guard unlinkat(parent, name, flags) == 0 else { throw Self.posixError(errno, "cannot remove native workspace path") }
            }
            return 0
        }
    }

    private func nativeToolRename(_ fromPath: String, to toPath: String, grant: Grant, cwd: Int32? = nil) throws -> Int32 {
        let from = try nativeToolTarget(fromPath, grant: grant, cwd: cwd)
        let to = try nativeToolTarget(toPath, grant: grant, cwd: cwd)
        guard !from.components.isEmpty, !to.components.isEmpty else {
            throw WorkspaceFileSystemError.noPermissions("cannot rename the workspace root")
        }
        let operation: () throws -> Int32 = {
            try from.grant.verifyIdentity()
            return try self.withParent(from, writing: true) { sourceParent, sourceName in
                try self.withParent(to, writing: true) { destinationParent, destinationName in
                    guard renameat(sourceParent, sourceName, destinationParent, destinationName) == 0 else {
                        throw Self.posixError(errno, "cannot rename native workspace path")
                    }
                    return 0
                }
            }
        }
        let coordinateDestination: () throws -> Int32 = {
            guard to.grant.needsCoordination else { return try operation() }
            return try self.withAuthorization(to, writing: true) { try operation() }
        }
        guard from.grant.needsCoordination else { return try coordinateDestination() }
        return try withAuthorization(from, writing: true) { try coordinateDestination() }
    }

    private func nativeToolChdir(_ path: String, resolved: UnsafeMutablePointer<CChar>, capacity: Int, grant: Grant, cwd: Int32? = nil) throws -> Int32 {
        guard capacity > 0 else { throw WorkspaceFileSystemError.unknown("cwd output buffer is empty") }
        let target = try nativeToolTarget(path, grant: grant, cwd: cwd)
        if let namespace {
            return try withParent(target, followFinal: true, resolved: { destination, parent, name in
                let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw Self.posixError(errno, "cannot enter directory") }
                defer { close(fd) }
                let actual = try Self.descriptorPath(fd)
                guard let relative = Self.relativePath(of: actual, under: destination.path) else {
                    throw WorkspaceFileSystemError.noPermissions("cwd moved outside retained root")
                }
                let label = try namespace.label(destination)
                let display = relative.isEmpty ? label : label + "/" + relative
                guard display.utf8.count < capacity else { throw Self.posixError(ERANGE, "cwd buffer too small") }
                _ = display.withCString { strlcpy(resolved, $0, capacity) }
                return 0
            }) { _, _ in fatalError("resolved callback required") }
        }
        return try withAuthorization(target, writing: false) {
            let fd: Int32
            if target.components.isEmpty {
                fd = openat(target.grant.anchorFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            } else {
                fd = try self.withParent(target, followFinal: true) { parent, name in
                    let opened = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard opened >= 0 else { throw Self.posixError(errno, "cannot enter native workspace directory") }
                    return opened
                }
            }
            guard fd >= 0 else { throw Self.posixError(errno, "cannot enter native workspace root") }
            defer { close(fd) }
            try grant.verifyIdentity()
            let rootPath = try Self.descriptorPath(grant.anchorFD)
            let directoryPath = try Self.descriptorPath(fd)
            guard rootPath == grant.path,
                  let relative = Self.relativePath(of: directoryPath, under: rootPath) else {
                throw WorkspaceFileSystemError.unavailable("resolved cwd moved outside its granted root")
            }
            let cwd = relative.isEmpty ? WorkspacePaths.guestRoot : WorkspacePaths.guestRoot + "/" + relative
            guard cwd.utf8.count < capacity else {
                throw WorkspaceFileSystemError.unavailable("resolved cwd exceeds output buffer")
            }
            // Display only: relative operations use the acquired cwd descriptor, never this path.
            _ = cwd.withCString { strlcpy(resolved, $0, capacity) }
            return 0
        }
    }

    private func nativeToolListDirectory(_ path: String, grant: Grant, cwd: Int32? = nil) throws -> [WorkspaceNativeToolDirectoryEntry] {
        let target = try nativeToolTarget(path, grant: grant, cwd: cwd)
        return try withAuthorization(target, writing: false) {
            let fd: Int32
            if target.components.isEmpty {
                fd = openat(target.grant.anchorFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            } else {
                fd = try self.withParent(target, followFinal: true) { parent, name in
                    let opened = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard opened >= 0 else { throw Self.posixError(errno, "cannot open native workspace directory") }
                    return opened
                }
            }
            guard fd >= 0 else { throw Self.posixError(errno, "cannot open native workspace root") }
            guard let directory = fdopendir(fd) else {
                close(fd)
                throw Self.posixError(errno, "cannot list native workspace directory")
            }
            defer { closedir(directory) }
            var names: [String] = []
            while let entry = try Self.checkedDirectoryRead({ readdir(directory) }) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingUTF8: $0) }
                }
                guard let name else { throw Self.posixError(EILSEQ, "native workspace entry name is not UTF-8") }
                if name != "." && name != ".." { names.append(name) }
            }
            return names.sorted().compactMap { name in
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
                let kind: WorkspaceNativeToolEntryKind
                switch info.st_mode & mode_t(S_IFMT) {
                case mode_t(S_IFREG): kind = .file
                case mode_t(S_IFDIR): kind = .directory
                case mode_t(S_IFLNK): kind = .symbolicLink
                default: kind = .other
                }
                return WorkspaceNativeToolDirectoryEntry(name: name, kind: kind,
                    size: info.st_size > 0 ? UInt64(info.st_size) : 0)
            }
        }
    }

    /// Link contents are metadata, not authority to follow the target.
    private func nativeToolSymlink(_ linkTarget: String, linkPath: String, grant: Grant, cwd: Int32? = nil) throws -> Int32 {
        guard !linkTarget.isEmpty, !linkTarget.contains("\0") else {
            throw WorkspaceFileSystemError.noPermissions("invalid native workspace symlink target")
        }
        let link = try nativeToolTarget(linkPath, grant: grant, cwd: cwd)
        guard !link.components.isEmpty else { throw WorkspaceFileSystemError.noPermissions("cannot replace workspace root") }
        return try withAuthorization(link, writing: true) {
            try self.withParent(link, writing: true) { parent, name in
                guard symlinkat(linkTarget, parent, name) == 0 else { throw Self.posixError(errno, "cannot create native workspace symlink") }
            }
            return 0
        }
    }

    private func nativeToolReadlink(_ path: String, buffer: UnsafeMutablePointer<CChar>, capacity: Int,
                                    outLength: UnsafeMutablePointer<Int>, grant: Grant, cwd: Int32? = nil) throws -> Int32 {
        guard capacity >= 0 else { throw WorkspaceFileSystemError.unknown("negative readlink buffer size") }
        let target = try nativeToolTarget(path, grant: grant, cwd: cwd)
        guard !target.components.isEmpty else { throw WorkspaceFileSystemError.fileNotFound("workspace root is not a symlink") }
        return try withAuthorization(target, writing: false) {
            try self.withParent(target) { parent, name in
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw Self.posixError(errno, "cannot inspect native workspace symlink")
                }
                guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) else {
                    throw Self.posixError(EINVAL, "native workspace path is not a symlink")
                }
                var bytes = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let count = readlinkat(parent, name, &bytes, bytes.count)
                guard count >= 0 else { throw Self.posixError(errno, "cannot read native workspace symlink") }
                guard count <= capacity else { throw Self.posixError(ERANGE, "native workspace symlink target exceeds buffer") }
                if count > 0 { buffer.update(from: bytes, count: count) }
                outLength.pointee = count
            }
            return 0
        }
    }

    // MARK: - fs.stat

    private func statAuthorized(_ params: [String: Any]) throws -> Any {
        try withAuthorization(string(params, "uri"), writing: false) { target in
            let (info, type) = try self.rendererMetadata(target)
            return [
                "type": type,
                "size": Int(info.st_size),
                "mtime": Self.milliseconds(info.st_mtimespec),
                "ctime": Self.milliseconds(info.st_ctimespec)
            ]
        }
    }

    private func rendererMetadata(_ target: Target) throws -> (stat, Int) {
        var info = stat()
        if target.components.isEmpty && target.grant.fileName == nil {
            guard fstat(target.grant.anchorFD, &info) == 0 else {
                throw Self.posixError(errno, "cannot stat granted directory")
            }
        } else {
            try withParent(target) { parent, name in
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw Self.posixError(errno, "cannot stat path")
                }
            }
        }
        let isLink = info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
        if isLink {
            guard target.grant.fileName == nil else {
                throw WorkspaceFileSystemError.noPermissions("file grant cannot follow a replacement link")
            }
            do {
                try withParent(target, followFinal: true) { parent, name in
                    var resolved = stat()
                    guard fstatat(parent, name, &resolved, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw Self.posixError(errno, "cannot stat link target")
                    }
                    guard resolved.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else {
                        throw Self.posixError(ELOOP, "link target changed during stat")
                    }
                    info = resolved
                }
            } catch let error as WorkspaceFileSystemError where error.posixCode == ENOENT {
                return (info, 64)
            }
        }
        let type: Int
        switch info.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG): type = 1
        case mode_t(S_IFDIR): type = 2
        default: type = 0
        }
        return (info, type | (isLink ? 64 : 0))
    }

    // MARK: - fs.readdir

    private func readdirAuthorized(_ params: [String: Any]) throws -> Any {
        try withAuthorization(string(params, "uri"), writing: false) { target in
            guard target.grant.fileName == nil else {
                throw WorkspaceFileSystemError.fileNotADirectory("not a directory")
            }

            var directoryGrant = target.grant
            let dirFD: Int32
            if target.components.isEmpty {
                // A fresh open file description for "." — never `dup`, which would share (and
                // consume) the grant anchor's directory offset and make later listings empty.
                dirFD = openat(target.grant.anchorFD, ".",
                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard dirFD >= 0 else { throw Self.posixError(errno, "cannot reopen granted directory") }
            } else {
                dirFD = try self.withParent(target, followFinal: true, resolved: { destination, parent, name in
                    directoryGrant = destination
                    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { throw Self.posixError(errno, "cannot open directory \(name)") }
                    return fd
                }) { _, _ in fatalError("resolved callback required") }
            }
            guard dirFD >= 0, let dir = fdopendir(dirFD) else {
                close(dirFD)
                throw Self.posixError(errno, "cannot read directory")
            }
            defer { closedir(dir) }

            var names: [String] = []
            while let entry = try Self.checkedDirectoryRead({ readdir(dir) }) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                names.append(name)
            }

            var entries: [[Any]] = []
            for name in names.sorted() {
                var info = stat()
                guard fstatat(dirFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let type: Int
                switch info.st_mode & mode_t(S_IFMT) {
                case mode_t(S_IFREG): type = 1
                case mode_t(S_IFDIR): type = 2
                case mode_t(S_IFLNK):
                    let child = Target(grant: directoryGrant, components: [name], baseFD: dirFD)
                    // Like desktop, skip entries that disappear or deny target access.
                    guard let (_, resolvedType) = try? self.rendererMetadata(child) else { continue }
                    type = resolvedType
                default: type = 0
                }
                entries.append([name, type])
            }
            return entries
        }
    }

    // MARK: - fs.readFile

    private static let chunkBytes = 256 * 1024

    private func stageBegin(_ params: [String: Any]) throws -> Any {
        let uri = try string(params, "uri")
        let create = try bool(params, "create", default: true)
        let overwrite = try bool(params, "overwrite", default: true)
        guard stagedFiles.count < 32 else { throw WorkspaceFileSystemError.unavailable("too many staged files") }
        let stage: StagedFile = try withAuthorization(uri, writing: true) { target in
            try self.withParent(target, writing: true) { parent, _ in
                let temporary = ".codipad-tmp-\(UUID().uuidString)"
                let fd = openat(parent, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw Self.posixError(errno, "cannot create staged file") }
                let retainedParent = dup(parent)
                guard retainedParent >= 0 else {
                    let error = Self.posixError(errno, "cannot retain staged parent")
                    close(fd); unlinkat(parent, temporary, 0)
                    throw error
                }
                return StagedFile(fd: fd, params: ["uri": uri, "create": create, "overwrite": overwrite, "atomic": true], parentFD: retainedParent, temporary: temporary, length: 0)
            }
        }
        let id = nextOpenFileID
        nextOpenFileID += 1
        stagedFiles[id] = stage
        return ["handle": id]
    }

    private func stageWrite(_ params: [String: Any]) throws -> Any {
        let id = try integer(params, "handle")
        guard var file = stagedFiles.removeValue(forKey: id) else { throw WorkspaceFileSystemError.unavailable("invalid staged file") }
        do {
            let position = try integer(params, "position")
            guard position == file.length else { throw WorkspaceFileSystemError.unavailable("invalid staged position") }
            let encoded = try string(params, "data")
            guard encoded.utf8.count <= ((Self.chunkBytes + 2) / 3) * 4,
                  let data = Data(base64Encoded: encoded), data.count <= Self.chunkBytes,
                  file.length <= Int.max - data.count else {
                throw WorkspaceFileSystemError.unavailable("invalid staged chunk")
            }
            try Self.writeData(data, to: file.fd)
            file.length += data.count
            stagedFiles[id] = file
            return NSNull()
        } catch {
            Self.cleanupStage(file)
            throw error
        }
    }

    private static func sameFile(_ fd: Int32, parent: Int32, name: String) -> Bool {
        var descriptor = stat(), entry = stat()
        return fstat(fd, &descriptor) == 0 && fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 &&
            descriptor.st_dev == entry.st_dev && descriptor.st_ino == entry.st_ino
    }

    private static func cleanupStage(_ file: StagedFile) {
        var descriptor = stat(), entry = stat()
        if fstat(file.fd, &descriptor) == 0 && fstatat(file.parentFD, file.temporary, &entry, AT_SYMLINK_NOFOLLOW) == 0 &&
            descriptor.st_dev == entry.st_dev && descriptor.st_ino == entry.st_ino {
            unlinkat(file.parentFD, file.temporary, 0)
        }
        close(file.fd)
        close(file.parentFD)
    }

    public func stopAllFileTransfers() {
        for file in openFiles.values { close(file.fd) }
        openFiles.removeAll()
        for file in stagedFiles.values { Self.cleanupStage(file) }
        stagedFiles.removeAll()
    }

    private func openAuthorized(_ params: [String: Any]) throws -> Any {
        let uri = try string(params, "uri")
        let writing = try bool(params, "writing", default: false)
        let inlineIfSmall = try bool(params, "inlineIfSmall", default: false)
        let create = try bool(params, "create", default: true)
        let overwrite = try bool(params, "overwrite", default: true)
        guard !writing || !inlineIfSmall else {
            throw WorkspaceFileSystemError(code: "InvalidRequest", message: "inline reads require a read-only handle")
        }
        guard openFiles.count < 128 else { throw WorkspaceFileSystemError.unavailable("too many open files") }
        return try withAuthorization(uri, writing: writing) { target in
            if writing && !overwrite {
                try self.withParent(target, writing: true) { parent, name in
                    var info = stat()
                    if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw WorkspaceFileSystemError.fileExists("file exists: \(name)") }
                    if errno != ENOENT { throw Self.posixError(errno, "cannot inspect file") }
                }
            }
            return try self.withParent(target, followFinal: true, writing: writing) { parent, name -> [String: Any] in
                var created = false
                var fd: Int32 = -1
                if writing && create {
                    fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o666)
                    created = fd >= 0
                    if fd < 0 && errno != EEXIST { throw Self.posixError(errno, "cannot create file") }
                }
                if fd < 0 {
                    if writing && !overwrite {
                        var metadata = stat()
                        if fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
                            throw WorkspaceFileSystemError.fileExists("file exists: \(name)")
                        }
                        throw Self.posixError(errno, "cannot inspect file")
                    }
                    fd = openat(parent, name, (writing ? O_WRONLY : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                }
                guard fd >= 0 else { throw Self.posixError(errno, "cannot open file") }
                do {
                    var metadata = stat()
                    guard fstat(fd, &metadata) == 0 else { throw Self.posixError(errno, "cannot inspect file") }
                    if metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) { throw WorkspaceFileSystemError.fileIsADirectory("not a file") }
                    guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw WorkspaceFileSystemError.unavailable("not a regular file") }
                    if inlineIfSmall && metadata.st_size <= Self.chunkBytes {
                        do {
                            let data = try Self.readRegularFile(fd, maximumBytes: Self.chunkBytes)
                            close(fd)
                            return ["data": data.base64EncodedString()]
                        } catch let error as WorkspaceFileSystemError where error.code == "FileTooLarge" {
                            // The file grew during the read. Keep this descriptor for positioned reads.
                        }
                    }
                    if writing && ftruncate(fd, 0) != 0 { throw Self.posixError(errno, "cannot truncate file") }
                    let id = self.nextOpenFileID
                    self.nextOpenFileID += 1
                    self.openFiles[id] = OpenFile(fd: fd, uri: uri, writing: writing, device: metadata.st_dev, inode: metadata.st_ino)
                    return ["handle": id, "created": created]
                } catch { close(fd); throw error }
            }
        }
    }

    private func transferAuthorized(_ params: [String: Any], writing: Bool) throws -> Any {
        let id = try integer(params, "handle")
        let position = try integer(params, "position")
        guard position >= 0, let file = openFiles[id], file.writing == writing else {
            throw WorkspaceFileSystemError.unavailable("invalid file handle or position")
        }
        let payload: Data
        if writing {
            let encoded = try string(params, "data")
            guard encoded.utf8.count <= ((Self.chunkBytes + 2) / 3) * 4,
                  let decoded = Data(base64Encoded: encoded), decoded.count <= Self.chunkBytes else {
                throw WorkspaceFileSystemError.unavailable("invalid transfer chunk")
            }
            payload = decoded
        } else {
            let length = try integer(params, "length")
            guard length >= 0 && length <= Self.chunkBytes else { throw WorkspaceFileSystemError.unavailable("invalid transfer length") }
            payload = Data(count: length)
        }
        return try withAuthorization(file.uri, writing: writing) { target in
            try self.withParent(target, followFinal: true, writing: writing) { parent, name in
                var metadata = stat()
                guard fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                      metadata.st_dev == file.device, metadata.st_ino == file.inode else {
                    throw WorkspaceFileSystemError.unavailable("open file was replaced")
                }
                if writing {
                    let count = payload.withUnsafeBytes { raw in pwrite(file.fd, raw.baseAddress, raw.count, off_t(position)) }
                    guard count > 0 || payload.isEmpty else { throw Self.posixError(count < 0 ? errno : EIO, "cannot write file") }
                    return count
                }
                var data = payload
                let count = data.withUnsafeMutableBytes { raw in pread(file.fd, raw.baseAddress, raw.count, off_t(position)) }
                guard count >= 0 else { throw Self.posixError(errno, "cannot read file") }
                data.count = count
                return data.base64EncodedString()
            }
        }
    }

    private func readFileAuthorized(_ params: [String: Any]) throws -> Any {
        try readFileData(string(params, "uri"), maximumBytes: Self.maxTransferBytes).base64EncodedString()
    }

    /// Native consumers keep descriptor-relative authorization and coordination without sending
    /// large package archives through the renderer's smaller base64 transfer boundary.
    public func readFileData(_ uri: String, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0 else {
            throw WorkspaceFileSystemError(code: "InvalidRequest", message: "negative read limit")
        }
        return try withAuthorization(uri, writing: false) { target in
            let fd = try self.openRegularFile(target)
            defer { close(fd) }
            return try Self.readRegularFile(fd, maximumBytes: maximumBytes)
        }
    }

    /// Captures a file and its parent identity through the same authorized descriptors.
    public func readFileSnapshot(_ uri: String, maximumBytes: Int) throws -> WorkspaceNativeFileSnapshot {
        guard maximumBytes >= 0 else {
            throw WorkspaceFileSystemError(code: "InvalidRequest", message: "negative read limit")
        }
        return try withAuthorization(uri, writing: false) { target in
            guard !target.components.isEmpty || target.grant.fileName != nil else {
                throw WorkspaceFileSystemError.fileIsADirectory("not a file")
            }
            return try self.withParent(target, followFinal: true) { parent, name in
                var metadata = stat()
                guard fstat(parent, &metadata) == 0 else { throw Self.posixError(errno, "cannot inspect parent") }
                let parentPath = try Self.descriptorPath(parent)
                let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw Self.posixError(errno, "cannot open \(name)") }
                defer { close(fd) }
                let data = try Self.readRegularFile(fd, maximumBytes: maximumBytes)
                let url = URL(fileURLWithPath: try Self.descriptorPath(fd))
                guard url.deletingLastPathComponent().path == parentPath else {
                    throw WorkspaceFileSystemError.unavailable("workspace file moved while reading")
                }
                try target.grant.verifyIdentity()
                return WorkspaceNativeFileSnapshot(url: url, parentMetadata: metadata, data: data)
            }
        }
    }

    private func openRegularFile(_ target: Target) throws -> Int32 {
        guard !target.components.isEmpty || target.grant.fileName != nil else {
            throw WorkspaceFileSystemError.fileIsADirectory("not a file")
        }
        return try withParent(target, followFinal: true) { parent, name in
            // O_NONBLOCK so opening a FIFO cannot hang before the type check.
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw Self.posixError(errno, "cannot open \(name)") }
            return fd
        }
    }

    private static func readRegularFile(_ fd: Int32, maximumBytes: Int) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Self.posixError(errno, "cannot inspect file") }
        if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
            throw WorkspaceFileSystemError.fileIsADirectory("not a file")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw WorkspaceFileSystemError.unavailable("not a regular file")
        }
        guard info.st_size <= maximumBytes else {
            throw WorkspaceFileSystemError.fileTooLarge("file exceeds \(maximumBytes) bytes")
        }

        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let readCount = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw Self.posixError(errno, "cannot read file")
            }
            if readCount == 0 { break }
            data.append(contentsOf: buffer[0..<readCount])
            guard data.count <= maximumBytes else {
                throw WorkspaceFileSystemError.fileTooLarge("file exceeds \(maximumBytes) bytes")
            }
        }
        return data
    }

    // MARK: - fs.writeFile

    private func writeFileAuthorized(_ params: [String: Any]) throws -> Any {
        let encoded = try string(params, "data")
        // Bound the encoded text before decoding allocates the payload.
        let maxEncoded = (Self.maxTransferBytes / 3 + 1) * 4
        guard encoded.utf8.count <= maxEncoded else {
            throw WorkspaceFileSystemError.fileTooLarge("payload exceeds \(Self.maxTransferBytes) bytes")
        }
        guard let data = Data(base64Encoded: encoded) else {
            throw WorkspaceFileSystemError.unknown("data is not valid base64")
        }
        // Refuse oversized payloads before touching the filesystem at all.
        guard data.count <= Self.maxTransferBytes else {
            throw WorkspaceFileSystemError.fileTooLarge("payload exceeds \(Self.maxTransferBytes) bytes")
        }
        return try writeAuthorized(params) { try Self.writeData(data, to: $0) }
    }

    private func writeAuthorized(_ params: [String: Any], stage: StagedFile? = nil, contents: @escaping (Int32) throws -> Void) throws -> Any {
        let uri = try string(params, "uri")
        let create = try bool(params, "create", default: true)
        let overwrite = try bool(params, "overwrite", default: true)
        let atomic = try bool(params, "atomic", default: false)

        return try withAuthorization(uri, writing: true) { target in
            guard !target.components.isEmpty || target.grant.fileName != nil else {
                throw WorkspaceFileSystemError.fileIsADirectory("not a file")
            }

            return try self.withParent(target, writing: self.namespace == nil, resolved: { destination, parent, name in
                var existing = stat()
                let exists = fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0
                if !exists && errno != ENOENT {
                    throw Self.posixError(errno, "cannot inspect write target")
                }
                if exists && existing.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                    guard overwrite else { throw WorkspaceFileSystemError.fileExists("file exists: \(name)") }
                    guard target.grant.fileName == nil else {
                        throw WorkspaceFileSystemError.noPermissions("file grant cannot follow a replacement link")
                    }
                    return try self.withParent(target, followFinal: true, writing: true) { resolvedParent, resolvedName in
                        let flags = O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (create ? O_CREAT : 0)
                        let fd = openat(resolvedParent, resolvedName, flags, 0o644)
                        guard fd >= 0 else { throw Self.posixError(errno, "cannot open link target") }
                        defer { close(fd) }
                        var metadata = stat()
                        guard fstat(fd, &metadata) == 0 else { throw Self.posixError(errno, "cannot inspect link target") }
                        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                            throw WorkspaceFileSystemError.unavailable("link target is not a regular file")
                        }
                        guard ftruncate(fd, 0) == 0 else { throw Self.posixError(errno, "cannot truncate link target") }
                        try contents(fd)
                        return ["created": false]
                    }
                }
                let publish: () throws -> Any = {
                    if exists {
                        guard overwrite else {
                            throw WorkspaceFileSystemError.fileExists("file exists: \(name)")
                        }
                        let format = existing.st_mode & mode_t(S_IFMT)
                        if format == mode_t(S_IFDIR) {
                            throw WorkspaceFileSystemError.fileIsADirectory("not a file: \(name)")
                        }
                        // Never trade a special file (FIFO, socket, device) for a regular one silently.
                        guard format == mode_t(S_IFREG) else {
                            throw WorkspaceFileSystemError.unavailable("refusing to replace a special file: \(name)")
                        }
                    } else {
                        guard create else {
                            throw WorkspaceFileSystemError.fileNotFound("file does not exist: \(name)")
                        }
                    }

                    if !atomic {
                        var created = false
                        var fd: Int32 = -1
                        if create {
                            fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o666)
                            created = fd >= 0
                            if fd < 0 && errno != EEXIST { throw Self.posixError(errno, "cannot create file") }
                        }
                        if fd < 0 {
                            guard overwrite else { throw WorkspaceFileSystemError.fileExists("file exists: \(name)") }
                            fd = openat(parent, name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                        }
                        guard fd >= 0 else { throw Self.posixError(errno, "cannot open file") }
                        defer { close(fd) }
                        var metadata = stat()
                        guard fstat(fd, &metadata) == 0 else { throw Self.posixError(errno, "cannot inspect file") }
                        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                            throw WorkspaceFileSystemError.unavailable("not a regular file")
                        }
                        guard ftruncate(fd, 0) == 0 else { throw Self.posixError(errno, "cannot truncate file") }
                        try contents(fd)
                        return ["created": created]
                    }

                    let temporary = stage?.temporary ?? ".codipad-tmp-\(UUID().uuidString)"
                    let tempFD: Int32
                    if let stage {
                        var expectedParent = stat(), actualParent = stat(), descriptor = stat(), entry = stat()
                        guard fstat(stage.parentFD, &expectedParent) == 0, fstat(parent, &actualParent) == 0,
                              expectedParent.st_dev == actualParent.st_dev, expectedParent.st_ino == actualParent.st_ino,
                              fstat(stage.fd, &descriptor) == 0, fstatat(parent, temporary, &entry, AT_SYMLINK_NOFOLLOW) == 0,
                              descriptor.st_dev == entry.st_dev, descriptor.st_ino == entry.st_ino else {
                            throw WorkspaceFileSystemError.unavailable("staged file or parent was replaced")
                        }
                        tempFD = stage.fd
                    } else {
                        tempFD = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                        guard tempFD >= 0 else { throw Self.posixError(errno, "cannot create temporary file") }
                    }
                    var published = false
                    defer {
                        if stage == nil {
                            if !published && Self.sameFile(tempFD, parent: parent, name: temporary) { unlinkat(parent, temporary, 0) }
                            close(tempFD)
                        }
                    }

                    if exists {
                        let sourceFD = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                        guard sourceFD >= 0 else { throw Self.posixError(errno, "cannot open original metadata") }
                        defer { close(sourceFD) }
                        var current = stat()
                        guard fstat(sourceFD, &current) == 0, current.st_dev == existing.st_dev, current.st_ino == existing.st_ino else {
                            throw WorkspaceFileSystemError.unavailable("write target changed")
                        }
                        guard fcopyfile(sourceFD, tempFD, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL)) == 0 else {
                            throw Self.posixError(errno, "cannot preserve file attributes")
                        }
                    }
                    // Preserve the supported original mode, notably the executable bit.
                    let existingFormat = existing.st_mode & mode_t(S_IFMT)
                    let mode: mode_t = (exists && existingFormat == mode_t(S_IFREG))
                        ? (existing.st_mode & 0o7777) : 0o644
                    guard fchmod(tempFD, mode) == 0 else {
                        throw Self.posixError(errno, "cannot set file mode")
                    }

                    if stage == nil { try contents(tempFD) }

                    guard Self.sameFile(tempFD, parent: parent, name: temporary) else {
                        throw WorkspaceFileSystemError.unavailable("temporary file was replaced")
                    }
                    var created = false
                    if renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 {
                        created = true
                    } else if !overwrite || errno != EEXIST {
                        throw Self.posixError(errno, "cannot publish file \(name)")
                    }
                    if !created {
                        guard overwrite else { throw WorkspaceFileSystemError.fileExists("file exists: \(name)") }
                        guard renameat(parent, temporary, parent, name) == 0 else {
                            throw Self.posixError(errno, "cannot publish file \(name)")
                        }
                    }
                    published = true
                    return ["created": created]
                }
                if let namespace = self.namespace {
                    return try namespace.authorize(destination, writing: true) {
                        try namespace.checkMutation(parent: parent, name: name, grant: destination)
                        return try publish()
                    }
                }
                return try publish()
            }) { _, _ in fatalError("resolved callback required") }
        }
    }

    private static func writeData(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Self.posixError(written < 0 ? errno : EIO, "cannot write file") }
                offset += written
            }
        }
    }

    // MARK: - fs.mkdir

    private func mkdirAuthorized(_ params: [String: Any]) throws -> Any {
        try withAuthorization(string(params, "uri"), writing: true) { target in
            guard !target.components.isEmpty || target.grant.fileName != nil else {
                throw WorkspaceFileSystemError.fileExists("directory exists")
            }
            return try self.withParent(target, writing: true) { parent, name in
                guard mkdirat(parent, name, 0o755) == 0 else {
                    throw Self.posixError(errno, "cannot create directory \(name)")
                }
                return NSNull()
            }
        }
    }

    // MARK: - fs.rename

    private func renameAuthorized(_ params: [String: Any]) throws -> Any {
        let fromURI = try string(params, "from")
        let toURI = try string(params, "to")
        let overwrite = try bool(params, "overwrite", default: false)

        let from = try authorize(fromURI)
        let to = try authorize(toURI)
        // Renaming a granted file would invalidate its grant and could move it outside
        // the authorized name; refuse rather than silently re-map.
        guard from.grant.fileName == nil, to.grant.fileName == nil else {
            throw WorkspaceFileSystemError.noPermissions("rename is not supported for file grants")
        }
        guard !from.components.isEmpty, !to.components.isEmpty else {
            throw WorkspaceFileSystemError.noPermissions("cannot rename a granted root")
        }

        let run: () throws -> Any = {
            try from.grant.verifyIdentity()
            try to.grant.verifyIdentity()
            return try self.withParent(from, writing: true) { fromParent, fromName in
                try self.withParent(to, writing: true) { toParent, toName in
                    if overwrite {
                        guard renameat(fromParent, fromName, toParent, toName) == 0 else {
                            throw Self.posixError(errno, "cannot rename \(fromName)")
                        }
                    } else {
                        guard renameatx_np(fromParent, fromName, toParent, toName, UInt32(RENAME_EXCL)) == 0 else {
                            throw Self.posixError(errno, "cannot rename \(fromName)")
                        }
                    }
                    return NSNull()
                }
            }
        }

        guard namespace == nil, from.grant.needsCoordination || to.grant.needsCoordination else { return try run() }
        return try coordinateMove(
            from.grant.coordinationURL(from.components),
            to.grant.coordinationURL(to.components),
            run)
    }

    // MARK: - fs.delete

    private func deleteAuthorized(_ params: [String: Any]) throws -> Any {
        let uri = try string(params, "uri")
        let recursive = try bool(params, "recursive", default: false)

        return try withAuthorization(uri, writing: true) { target in
            if let file = target.grant.fileName {
                guard unlinkat(target.grant.anchorFD, file, 0) == 0 else {
                    throw Self.posixError(errno, "cannot delete granted file")
                }
                return NSNull()
            }
            guard !target.components.isEmpty else {
                throw WorkspaceFileSystemError.noPermissions("cannot delete a granted root")
            }
            return try self.withParent(target, writing: true) { parent, name in
                var info = stat()
                guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw Self.posixError(errno, "cannot inspect \(name)")
                }
                if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
                    if recursive {
                        try Self.removeTree(parent: parent, name: name)
                    } else {
                        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
                            throw Self.posixError(errno, "cannot delete directory \(name)")
                        }
                    }
                } else {
                    guard unlinkat(parent, name, 0) == 0 else {
                        throw Self.posixError(errno, "cannot delete \(name)")
                    }
                }
                return NSNull()
            }
        }
    }

    internal static func checkedDirectoryRead(_ read: () -> UnsafeMutablePointer<dirent>?) throws -> UnsafeMutablePointer<dirent>? {
        errno = 0
        let entry = read()
        if entry == nil && errno != 0 { throw posixError(errno, "cannot read directory") }
        return entry
    }

    /// Deletes a directory tree through descriptors; symlinks are unlinked, never followed.
    private static func removeTree(parent: Int32, name: String) throws {
        let dirFD = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dirFD >= 0 else { throw posixError(errno, "cannot open directory \(name)") }
        var children: [String] = []
        if let dir = fdopendir(dirFD) {
            defer { closedir(dir) }
            while let entry = try Self.checkedDirectoryRead({ readdir(dir) }) {
                let child = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if child == "." || child == ".." { continue }
                children.append(child)
            }
            for child in children {
                var info = stat()
                guard fstatat(dirFD, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
                    try removeTree(parent: dirFD, name: child)
                } else {
                    guard unlinkat(dirFD, child, 0) == 0 else {
                        throw posixError(errno, "cannot delete \(child)")
                    }
                }
            }
        } else {
            let error = posixError(errno, "cannot read directory \(name)")
            close(dirFD)
            throw error
        }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
            throw posixError(errno, "cannot delete directory \(name)")
        }
    }

    // MARK: - Grants storage

    internal final class Grant {
        enum Kind: Equatable { case directory, file }
        let kind: Kind
        let path: String
        let accessGeneration: UInt64
        let anchorFD: Int32
        let fileName: String?
        let selectedURL: URL
        let pickedURL: URL
        let needsCoordination: Bool
        let caseSensitiveNames: Bool
        let identityPath: String
        let identityDev: dev_t
        let identityIno: UInt64
        private let finish: () -> Void

        init(kind: Kind, path: String, accessGeneration: UInt64, anchorFD: Int32, fileName: String?, selectedURL: URL, pickedURL: URL? = nil,
             needsCoordination: Bool, caseSensitiveNames: Bool, identityPath: String, identityDev: dev_t, identityIno: UInt64,
             finish: @escaping () -> Void) {
            self.kind = kind
            self.path = path
            self.accessGeneration = accessGeneration
            self.anchorFD = anchorFD
            self.fileName = fileName
            self.selectedURL = selectedURL
            self.pickedURL = pickedURL ?? selectedURL
            self.needsCoordination = needsCoordination
            self.caseSensitiveNames = caseSensitiveNames
            self.identityPath = identityPath
            self.identityDev = identityDev
            self.identityIno = identityIno
            self.finish = finish
        }

        /// Fails closed when the authorized directory object is gone or replaced.
        func verifyIdentity() throws {
            var info = stat()
            guard stat(identityPath, &info) == 0 else {
                throw WorkspaceFileSystemError.unavailable(
                    "authorized directory is no longer reachable at its granted path")
            }
            guard info.st_dev == identityDev, info.st_ino == identityIno else {
                throw WorkspaceFileSystemError.unavailable(
                    "authorized directory was moved or replaced; reopen the workspace")
            }
        }

        /// The selected (authorized) URL for this entry, as required for `NSFileCoordinator`.
        func coordinationURL(_ components: [String]) -> URL {
            if fileName != nil { return selectedURL }
            return components.reduce(selectedURL) { $0.appendingPathComponent($1) }
        }

        func releaseResources() {
            close(anchorFD)
            finish()
        }
    }

    internal struct Target {
        let grant: Grant
        /// Components below the root, or relative to baseFD for an owned native cwd.
        /// Empty means the grant root (or the granted file).
        let components: [String]
        var baseFD: Int32? = nil
        // Only native callbacks define /workspace as an alias of this retained grant.
        var absoluteAlias: String? = nil
    }

    // MARK: - Authorization

    /// Authorizes a URI, verifies the root identity, then runs `body` — inside one coordinated
    /// access when the grant is external.
    private func withAuthorization<T>(_ uri: String, writing: Bool,
                                     _ body: @escaping (Target) throws -> T) throws -> T {
        let target = try authorize(uri)
        if namespace != nil { return try withAuthorization(target, writing: writing) { try body(target) } }
        let run: () throws -> T = {
            try target.grant.verifyIdentity()
            return try body(target)
        }
        guard target.grant.needsCoordination else { return try run() }
        return try coordinate(target.grant.coordinationURL(target.baseFD == nil ? target.components : []), writing: writing, run)
    }

    private func withAuthorization<T>(_ target: Target, writing: Bool,
                                      _ body: @escaping () throws -> T) throws -> T {
        if let namespace {
            // Traversal reads the source. withParent authorizes the resolved mutation endpoint.
            return try namespace.authorize(target.grant, writing: writing && target.components.isEmpty, body)
        }
        let run: () throws -> T = {
            try target.grant.verifyIdentity()
            return try body()
        }
        guard target.grant.needsCoordination else { return try run() }
        return try coordinate(target.grant.coordinationURL(target.baseFD == nil ? target.components : []), writing: writing, run)
    }

    internal func coordinate<T>(_ url: URL, writing: Bool, _ body: @escaping () throws -> T) throws -> T {
        let result = CoordinationResult()
        _ = try coordinateHook(url, writing) {
            do { result.value = try body() } catch { result.error = error }
            return NSNull()
        }
        if let error = result.error { throw error }
        guard let value = result.value as? T else {
            throw WorkspaceFileSystemError.unavailable("file coordination did not run the operation")
        }
        return value
    }

    private func coordinateMove<T>(_ source: URL, _ destination: URL,
                                   _ body: @escaping () throws -> T) throws -> T {
        let result = CoordinationResult()
        _ = try coordinateMoveHook(source, destination) {
            do { result.value = try body() } catch { result.error = error }
            return NSNull()
        }
        if let error = result.error { throw error }
        guard let value = result.value as? T else {
            throw WorkspaceFileSystemError.unavailable("file coordination did not run the move")
        }
        return value
    }

    private final class CoordinationResult {
        var value: Any?
        var error: Error?
    }

    /// Maps a URI to a grant using lexical containment and rejects anything else.
    private func authorize(_ uri: String) throws -> Target {
        guard let url = URL(string: uri), url.isFileURL else {
            throw WorkspaceFileSystemError.noPermissions("not a local file URI")
        }
        if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" {
            throw WorkspaceFileSystemError.noPermissions("non-local file authority")
        }
        var path = url.path(percentEncoded: false)
        guard !path.isEmpty, !path.contains("\0") else {
            throw WorkspaceFileSystemError.noPermissions("invalid file URI")
        }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

        if let namespace { return try namespace.target(path, allowAlias: false) }

        var best: Target?
        for grant in grants.reversed() {
            guard let relative = Self.relativePath(of: path, under: grant.path) else { continue }
            let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard components.allSatisfy({ $0 != "." && $0 != ".." }) else {
                throw WorkspaceFileSystemError.noPermissions("path traversal is refused")
            }
            if grant.kind == .file {
                // Exact file only: no sibling, no parent, no descendant.
                if components.isEmpty && path == grant.path { return Target(grant: grant, components: []) }
                continue
            }
            if best == nil { best = Target(grant: grant, components: components) }
        }
        guard let target = best else {
            throw WorkspaceFileSystemError.noPermissions("URI is outside every granted root")
        }
        return target
    }

    /// Returns the path below `root`, or nil when `path` is not inside it.
    private static func relativePath(of path: String, under root: String) -> String? {
        if path == root { return "" }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// Walks only held directory descriptors. Link replacement can change which relative target
    /// we see, but cannot make an OS open follow a link or escape the grant.
    private func withParent<T>(_ target: Target, followFinal: Bool = false, writing: Bool = false,
                               resolved: ((Grant, Int32, String) throws -> T)? = nil,
                               _ body: (Int32, String) throws -> T) throws -> T {
        if let file = target.grant.fileName {
            if let resolved { return try resolved(target.grant, target.grant.anchorFD, file) }
            return try body(target.grant.anchorFD, file)
        }
        guard !target.components.isEmpty || namespace != nil else {
            throw WorkspaceFileSystemError.noPermissions("operation needs a path below the granted root")
        }
        if let namespace { try namespace.authorize(target.grant, writing: false) { () } }
        var currentGrant = target.grant
        func finish(_ parent: Int32, _ name: String) throws -> T {
            if let namespace { return try withoutActuallyEscaping(body) { body in
                try namespace.authorize(currentGrant, writing: writing) {
                    if writing {
                        try namespace.checkMutation(parent: parent, name: name, grant: currentGrant)
                    }
                    if let resolved { return try resolved(currentGrant, parent, name) }
                    return try body(parent, name)
                }
            } }
            if let resolved { return try resolved(currentGrant, parent, name) }
            return try body(parent, name)
        }
        var directories = try Self.directoryAncestry(target.baseFD ?? target.grant.anchorFD, root: target.grant.anchorFD)
        defer { for fd in directories { close(fd) } }
        if let namespace {
            // A held cwd may have moved into a narrower mount since acquisition.
            for index in directories.indices.reversed() {
                var info = stat()
                guard fstat(directories[index], &info) == 0 else { throw Self.posixError(errno, "cannot inspect cwd authority") }
                if let destination = namespace.mount(matching: info) {
                    try namespace.authorize(destination, writing: false) { () }
                    currentGrant = destination
                    for fd in directories.prefix(index) { close(fd) }
                    directories.removeFirst(index)
                    break
                }
            }
        }
        var pending = target.components
        var links = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." { continue }
            if component == ".." {
                if directories.count == 1, let namespace {
                    let label = try namespace.label(currentGrant)
                    let next = try namespace.target((label as NSString).deletingLastPathComponent + "/" + pending.joined(separator: "/"))
                    try namespace.authorize(next.grant, writing: false) { () }
                    for fd in directories { close(fd) }
                    directories.removeAll()
                    directories = try Self.directoryAncestry(next.grant.anchorFD, root: next.grant.anchorFD)
                    currentGrant = next.grant
                    pending = next.components
                    continue
                }
                guard directories.count > 1 else {
                    throw WorkspaceFileSystemError.noPermissions("symlink target escapes the granted root")
                }
                close(directories.removeLast())
                continue
            }
            let parent = directories.last!
            if let namespace {
                let physical = try Self.descriptorPath(parent)
                var entry = stat()
                let identified = fstatat(parent, component, &entry, AT_SYMLINK_NOFOLLOW) == 0
                    ? namespace.mount(matching: entry) : nil
                if let nested = namespace.mount(at: physical + "/" + component) ?? identified, nested !== currentGrant {
                    try namespace.authorize(nested, writing: writing && pending.isEmpty) { () }
                    if pending.isEmpty && writing {
                        throw WorkspaceFileSystemError.noPermissions("cannot mutate an admitted mount root")
                    }
                    for fd in directories { close(fd) }
                    directories.removeAll()
                    directories = try Self.directoryAncestry(nested.anchorFD, root: nested.anchorFD)
                    currentGrant = nested
                    continue
                }
            }
            if !pending.isEmpty || followFinal {
                var info = stat()
                if fstatat(parent, component, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                    if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                        links += 1
                        guard links <= 40 else { throw Self.posixError(ELOOP, "too many symbolic links") }
                        var bytes = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                        let count = readlinkat(parent, component, &bytes, bytes.count)
                        guard count >= 0 else { throw Self.posixError(errno, "cannot read symbolic link") }
                        guard count < bytes.count else { throw Self.posixError(ENAMETOOLONG, "symbolic link target is too long") }
                        bytes[count] = 0
                        guard let destination = String(validatingUTF8: bytes) else {
                            throw Self.posixError(EILSEQ, "symbolic link target is not UTF-8")
                        }
                        let relative: String
                        if destination.hasPrefix("/") {
                            if let namespace {
                                let next = try namespace.target(destination, allowAlias: target.absoluteAlias != nil)
                                try namespace.authorize(next.grant, writing: false) { () }
                                for fd in directories { close(fd) }
                                directories.removeAll()
                                directories = try Self.directoryAncestry(next.grant.anchorFD, root: next.grant.anchorFD)
                                currentGrant = next.grant
                                pending = next.components + pending
                                continue
                            }
                            let canonical = Self.relativePath(of: destination, under: target.grant.path)
                            let alias = target.absoluteAlias.flatMap { Self.relativePath(of: destination, under: $0) }
                            guard let suffix = canonical ?? alias else {
                                throw WorkspaceFileSystemError.noPermissions("absolute symbolic link target requires namespace authority")
                            }
                            relative = suffix
                            while directories.count > 1 { close(directories.removeLast()) }
                        } else {
                            relative = destination
                        }
                        let suffix = destination.hasSuffix("/") ? ["."] : []
                        pending = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init) + suffix + pending
                        continue
                    }
                } else if errno != ENOENT || !pending.isEmpty {
                    throw Self.posixError(errno, "cannot inspect path component")
                }
            }
            if pending.isEmpty { return try finish(parent, component) }
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Self.posixError(errno, "cannot open \(component)") }
            directories.append(next)
        }
        return try finish(directories.last!, ".")
    }

    /// Capture the current ancestry by descriptors, stopping only at the held grant inode.
    /// A move observed before the call fails closed. Concurrent external rename cannot be
    /// serialized with Darwin *at mutations; held descriptors remain the operation's capability.
    private static func directoryAncestry(_ directory: Int32, root: Int32) throws -> [Int32] {
        var rootInfo = stat()
        guard fstat(root, &rootInfo) == 0 else { throw posixError(errno, "cannot inspect root") }
        let first = dup(directory)
        guard first >= 0 else { throw posixError(errno, "cannot retain cwd") }
        var chain = [first]
        var adopted = false
        defer { if !adopted { for fd in chain { close(fd) } } }
        for _ in 0..<1024 {
            var info = stat()
            guard fstat(chain.last!, &info) == 0 else { throw posixError(errno, "cannot inspect cwd ancestry") }
            if info.st_dev == rootInfo.st_dev && info.st_ino == rootInfo.st_ino {
                adopted = true
                return Array(chain.reversed())
            }
            let parent = openat(chain.last!, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw posixError(errno, "cannot inspect cwd parent") }
            chain.append(parent)
            var parentInfo = stat()
            guard fstat(parent, &parentInfo) == 0 else { throw posixError(errno, "cannot inspect cwd parent") }
            if parentInfo.st_dev == info.st_dev && parentInfo.st_ino == info.st_ino { break }
        }
        throw WorkspaceFileSystemError.noPermissions("cwd is outside its retained workspace authority")
    }

    // MARK: - Helpers

    private static func map(_ error: WorkspaceAccessError) -> WorkspaceFileSystemError {
        switch error {
        case .notFileURL: return .noPermissions("not a local file URL")
        case .rootNotFound(let path): return .fileNotFound("workspace root does not exist: \(path)")
        case .notDirectory(let path): return .fileNotADirectory("workspace root is not a directory: \(path)")
        case .scopeDenied(let path): return .noPermissions("scope: security-scoped access was denied: \(path)")
        }
    }

    private static func validateSelection(_ url: URL) throws {
        guard url.isFileURL else { throw WorkspaceFileSystemError.noPermissions("not a local file URL") }
        if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" {
            throw WorkspaceFileSystemError.noPermissions("non-local file authority")
        }
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty, !path.contains("\0") else {
            throw WorkspaceFileSystemError.noPermissions("invalid file URL")
        }
    }

    private static func uri(forPath path: String, isDirectory: Bool) -> String {
        URL(fileURLWithPath: path, isDirectory: isDirectory).absoluteString
    }

    /// Gives symlink components a clear refusal. `openat` still uses `O_NOFOLLOW`, so this check
    /// only improves the error, it is not what makes the walk safe.
    private static func refuseSymlink(_ parent: Int32, _ name: String) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
            throw WorkspaceFileSystemError.noPermissions("symbolic links are not followed: \(name)")
        }
    }

    /// Fully resolves a path with `realpath`, including `/var`-style prefix symlinks.
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func milliseconds(_ time: timespec) -> Double {
        Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000
    }

    private func allocateAccessGeneration() -> UInt64 {
        let generation = nextAccessGeneration
        nextAccessGeneration &+= 1
        if nextAccessGeneration == 0 { nextAccessGeneration = 1 }
        return generation
    }

    private static func posixError(_ code: Int32, _ context: String) -> WorkspaceFileSystemError {
        let message = "\(context): \(String(cString: strerror(code)))"
        switch code {
        case ENOENT: return .init(code: "FileNotFound", message: message, posixCode: code)
        case EEXIST, ENOTEMPTY: return .init(code: "FileExists", message: message, posixCode: code)
        case EACCES, EPERM, ELOOP: return .init(code: "NoPermissions", message: message, posixCode: code)
        case ENOTDIR: return .init(code: "FileNotADirectory", message: message, posixCode: code)
        case EISDIR: return .init(code: "FileIsADirectory", message: message, posixCode: code)
        default: return .init(code: "Unavailable", message: message, posixCode: code)
        }
    }

    private static func descriptorPath(_ fd: Int32) throws -> String {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &path) == 0 else { throw posixError(errno, "cannot resolve anchored path") }
        return String(cString: path)
    }

    /// Opens the authorized canonical directory directly.
    ///
    /// Deliberately does not walk from the filesystem root: iOS grants this app nothing over its
    /// ancestors or over `/`, so an ancestor walk fails with `EPERM` even when the selected folder
    /// is inside the app container. The security scope (or container ownership) plus the picker's
    /// selection is the only authority; anchoring here confers no authority over parents.
    /// The path is already `realpath`-resolved, so `O_NOFOLLOW` here only guards the final
    /// component. Every operation below this descriptor stays `openat` + `O_NOFOLLOW`.
    private static func openCanonicalDirectory(_ path: String, context: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw WorkspaceFileSystemError.unavailable(
                "anchor-open: cannot open \(context) \(path): \(String(cString: strerror(errno)))")
        }
        return fd
    }

    /// Opens the parent directory of the canonical file path and returns its descriptor and name.
    private static func openParent(of path: String) throws -> (fd: Int32, name: String) {
        let components = path.split(separator: "/").map(String.init)
        guard let name = components.last else {
            throw WorkspaceFileSystemError.noPermissions("path has no file name")
        }
        let parentPath = "/" + components.dropLast().joined(separator: "/")
        return (try openCanonicalDirectory(parentPath, context: "parent directory"), name)
    }

    private func string(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String else {
            throw WorkspaceFileSystemError.unknown("missing or invalid '\(key)'")
        }
        return value
    }

    private func integer(_ params: [String: Any], _ key: String) throws -> Int {
        guard let number = params[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue == Double(number.intValue) else {
            throw WorkspaceFileSystemError.unknown("invalid integer '\(key)'")
        }
        return number.intValue
    }

    /// Strict options: only a real boolean is accepted, never a coerced number or string.
    private func bool(_ params: [String: Any], _ key: String, default fallback: Bool) throws -> Bool {
        guard let raw = params[key] else { return fallback }
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        throw WorkspaceFileSystemError.unknown("invalid '\(key)': expected a boolean")
    }
}
