import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum WorkspaceWatchPhase: String {
    case initial
    case refresh
}

/// Path-free details for a watcher scan failure. `posixErrno` is nil for non-POSIX failures.
public struct WorkspaceWatchFailure: Equatable {
    public let phase: WorkspaceWatchPhase
    public let operation: String
    public let posixErrno: Int32?
    /// Zero for the watched root, positive for a descendant, nil for coordination failures.
    public let relativeDepth: Int?

    internal init(phase: WorkspaceWatchPhase, operation: String, posixErrno: Int32?, relativeDepth: Int?) {
        self.phase = phase
        self.operation = operation
        self.posixErrno = posixErrno
        self.relativeDepth = relativeDepth
    }
}

/// Watches one authorized directory tree without following symlinks. A source is attached to each
/// existing regular file and directory, so file-content writes and atomic name replacement are
/// both observed. Directory events trigger a descriptor-relative rescan to discover new entries.
/// Dispatch sources are hints; the emitted event is a diff of the actual authorized tree.
final class WorkspaceFileWatcher {
    private struct Entry: Equatable {
        let type: Int
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let mtimeSeconds: Int
        let mtimeNanos: Int
        let ctimeSeconds: Int
        let ctimeNanos: Int
    }

    private struct Source {
        let descriptor: Int32
        let entry: Entry?
        let dispatch: DispatchSourceFileSystemObject
    }

    private let rootFD: Int32
    private let rootPath: String
    private let recursive: Bool
    private let pruneNames: Set<String>
    private let subscriptionID: Int
    private let coordinateScan: (@escaping () throws -> Void) throws -> Void
    private let queue = DispatchQueue(label: "dev.codipad.workspace.watch", qos: .utility)
    private let canceledSources = DispatchGroup()
    private let onChanges: (Int, [[String: Any]]) -> Void
    private let onWatchError: (Int, String) -> Void
    private let onWatchFailure: (Int, WorkspaceWatchFailure) -> Void
    private let onDiagnostic: ((Int, String, Int) -> Void)?
    private let maxDiagnosticEvents = 16
    private var sources: [String: Source] = [:]
    private var previous: [String: Entry] = [:]
    private var diagnosticEventCount = 0
    private var resourceLimitRetryPending = false
    private var resourceLimitRetryCount = 0
    private var stopped = false

    init(rootFD: Int32, rootPath: String, recursive: Bool, pruneNames: Set<String> = [], subscriptionID: Int,
         coordinateScan: @escaping (@escaping () throws -> Void) throws -> Void,
         onChanges: @escaping (Int, [[String: Any]]) -> Void,
         onWatchError: @escaping (Int, String) -> Void,
         onWatchFailure: @escaping (Int, WorkspaceWatchFailure) -> Void,
         onDiagnostic: ((Int, String, Int) -> Void)? = nil) {
        self.rootFD = rootFD
        self.rootPath = rootPath
        self.recursive = recursive
        self.pruneNames = pruneNames
        self.subscriptionID = subscriptionID
        self.coordinateScan = coordinateScan
        self.onChanges = onChanges
        self.onWatchError = onWatchError
        self.onWatchFailure = onWatchFailure
        self.onDiagnostic = onDiagnostic
    }

    func start() throws {
        do {
            try queue.sync { try refresh(initial: true) }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        queue.sync { stopOnQueue() }
        // Cancellation handlers run on `queue`, so wait only after leaving its synchronous block.
        // This keeps descriptors open until DispatchSource has finished every queued callback.
        canceledSources.wait()
    }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        cancelSources()
        close(rootFD)
    }

    private func refresh(initial: Bool) throws {
        guard !stopped, !resourceLimitRetryPending else { return }
        // Attach to the root first. Events arriving while the initial snapshot is collected stay
        // queued on this serial queue and trigger a second diff after the current refresh returns.
        var current: [String: Entry] = [:]
        var currentSources: Set<String> = [""]
        do {
            if sources[""] == nil {
                let rootWatchFD = dup(rootFD)
                guard rootWatchFD >= 0 else {
                    throw Self.watchError(errno, operation: "dup")
                }
                try arm(fd: rootWatchFD, relative: "")
            }
            try coordinateScan {
                try self.scan(directoryFD: self.rootFD, relative: "", entries: &current,
                              currentSources: &currentSources, phase: initial ? .initial : .refresh)
            }
        } catch {
            let phase: WorkspaceWatchPhase = initial ? .initial : .refresh
            onWatchFailure(subscriptionID, Self.failure(error, phase: phase))
            if !initial,
               let scanError = error as? WatchScanError,
               (scanError.posixErrno == EMFILE || scanError.posixErrno == ENFILE),
               resourceLimitRetryCount == 0 {
                resourceLimitRetryCount += 1
                resourceLimitRetryPending = true
                cancelSources()
                let canceledSources = self.canceledSources
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    // Cancellation handlers run on `queue`; wait elsewhere, then rescan after
                    // their descriptors have closed instead of failing with temporary pressure.
                    canceledSources.wait()
                    self?.queue.async { [weak self] in
                        guard let self, !self.stopped else { return }
                        self.resourceLimitRetryPending = false
                        try? self.refresh(initial: false)
                    }
                }
                return
            }
            // Root access and non-permission failures cannot leave a usable subscription.
            emitDiagnostic(initial ? "scan.initial.failure" : "scan.refresh.failure", count: 1)
            emitDiagnostic(initial ? "sources.initial.failure" : "sources.refresh.failure", count: sources.count)
            if initial {
                if let scanError = error as? WatchScanError {
                    throw WorkspaceFileSystemError(
                        code: "Unavailable",
                        message: scanError.localizedDescription,
                        posixCode: scanError.posixErrno)
                }
                throw error
            }
            onWatchError(subscriptionID, error.localizedDescription)
            stopOnQueue()
            return
        }

        cancelSources(except: currentSources)
        emitDiagnostic(initial ? "snapshot.initial" : "snapshot.refresh", count: current.count)
        emitDiagnostic(initial ? "sources.initial" : "sources.refresh", count: sources.count)
        if !initial {
            var changes: [[String: Any]] = []
            for (relative, entry) in current {
                let type = previous[relative] == nil ? 1 : (previous[relative] == entry ? nil : 0)
                if let type { changes.append(change(relative, type)) }
            }
            for relative in previous.keys where current[relative] == nil {
                changes.append(change(relative, 2))
            }
            emitDiagnostic("changes.generated", count: changes.count)
            if !changes.isEmpty { onChanges(subscriptionID, changes) }
        }
        resourceLimitRetryCount = 0
        previous = current
    }

    private func scan(directoryFD: Int32, relative: String, entries: inout [String: Entry],
                      currentSources: inout Set<String>, phase: WorkspaceWatchPhase) throws {
        let listingFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard listingFD >= 0 else {
            throw Self.watchError(errno, operation: "openat", relative: relative)
        }
        guard let listing = fdopendir(listingFD) else {
            let code = errno
            close(listingFD)
            throw Self.watchError(code, operation: "fdopendir", relative: relative)
        }
        defer { closedir(listing) }
        while true {
            errno = 0
            guard let item = readdir(listing) else {
                if errno != 0 { throw Self.watchError(errno, operation: "readdir", relative: relative) }
                break
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            let path = relative.isEmpty ? name : relative + "/" + name
            do {
                var info = stat()
                guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT || errno == ENOTDIR { continue }
                    throw Self.watchError(errno, operation: "fstatat", relative: path)
                }
                let mode = info.st_mode & mode_t(S_IFMT)
                let type: Int
                if mode == mode_t(S_IFDIR) { type = 2 }
                else if mode == mode_t(S_IFREG) { type = 1 }
                else if mode == mode_t(S_IFLNK) { type = 64 }
                else { continue }
                let entry = Entry(type: type, device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                    size: Int64(info.st_size), mtimeSeconds: Int(info.st_mtimespec.tv_sec),
                    mtimeNanos: Int(info.st_mtimespec.tv_nsec), ctimeSeconds: Int(info.st_ctimespec.tv_sec),
                    ctimeNanos: Int(info.st_ctimespec.tv_nsec))
                entries[path] = entry

                if type == 2 || type == 1 {
                    let fd: Int32
                    if let source = sources[path], source.entry?.device == entry.device,
                       source.entry?.inode == entry.inode {
                        fd = source.descriptor
                    } else {
                        // Event access also observes permission restoration on an unreadable directory.
                        let flags = O_EVTONLY | (type == 2 ? O_DIRECTORY : 0)
                        fd = openat(directoryFD, name, flags | O_NOFOLLOW | O_CLOEXEC)
                        guard fd >= 0 else {
                            if errno == ENOENT || errno == ENOTDIR { continue }
                            throw Self.watchError(errno, operation: "openat", relative: path)
                        }
                        do {
                            try arm(fd: fd, relative: path, entry: entry)
                        } catch {
                            close(fd)
                            throw error
                        }
                    }
                    currentSources.insert(path)
                    if type == 2 && recursive && !pruneNames.contains(name) {
                        try scan(directoryFD: fd, relative: path, entries: &entries,
                                 currentSources: &currentSources, phase: phase)
                    }
                }
            } catch let error as WatchScanError where error.posixErrno == EACCES || error.posixErrno == EPERM {
                onWatchFailure(subscriptionID, Self.failure(error, phase: phase))
                // An unobservable subtree is not evidence that its known children were deleted.
                for (knownPath, entry) in previous where knownPath == path || knownPath.hasPrefix(path + "/") {
                    if entries[knownPath] == nil { entries[knownPath] = entry }
                }
                for knownPath in sources.keys where knownPath == path || knownPath.hasPrefix(path + "/") {
                    currentSources.insert(knownPath)
                }
            }
        }
    }

    private func arm(fd: Int32, relative: String, entry: Entry? = nil) throws {
        guard fd >= 0 else { throw Self.watchError(errno, operation: "dispatchSource", relative: relative) }
        let mask: DispatchSource.FileSystemEvent = [.write, .delete, .rename, .attrib, .extend, .link, .revoke]
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            try? self.refresh(initial: false)
        }
        // Apple requires descriptor closure in the cancellation handler: closing immediately
        // after cancel() can race an already queued event handler and descriptor-number reuse.
        let canceledSources = self.canceledSources
        canceledSources.enter()
        source.setCancelHandler {
            close(fd)
            canceledSources.leave()
        }
        let replaced = sources.updateValue(Source(descriptor: fd, entry: entry, dispatch: source), forKey: relative)
        replaced?.dispatch.cancel()
        source.resume()
    }

    private static func watchError(_ code: Int32, operation: String, relative: String = "") -> WatchScanError {
        WatchScanError(operation: operation, posixErrno: code, relativeDepth: relative.split(separator: "/").count)
    }

    private static func failure(_ error: Error, phase: WorkspaceWatchPhase) -> WorkspaceWatchFailure {
        if let scanError = error as? WatchScanError {
            return WorkspaceWatchFailure(phase: phase, operation: scanError.operation,
                                         posixErrno: scanError.posixErrno, relativeDepth: scanError.relativeDepth)
        }
        if let fileSystemError = error as? WorkspaceFileSystemError {
            return WorkspaceWatchFailure(phase: phase, operation: "coordinateScan",
                                         posixErrno: fileSystemError.posixCode, relativeDepth: nil)
        }
        return WorkspaceWatchFailure(phase: phase, operation: "coordinateScan", posixErrno: nil, relativeDepth: nil)
    }

    private struct WatchScanError: Error, LocalizedError {
        let operation: String
        let posixErrno: Int32
        let relativeDepth: Int

        var errorDescription: String? {
            "watch \(operation) failed (errno \(posixErrno))"
        }
    }

    private func cancelSources(except retained: Set<String> = []) {
        for (path, source) in sources where !retained.contains(path) {
            source.dispatch.cancel()
            sources.removeValue(forKey: path)
        }
    }

    private func emitDiagnostic(_ step: String, count: Int) {
        guard diagnosticEventCount < maxDiagnosticEvents else { return }
        diagnosticEventCount += 1
        onDiagnostic?(subscriptionID, step, count)
    }

    private func change(_ relative: String, _ type: Int) -> [String: Any] {
        let path = rootPath + "/" + relative
        return ["uri": URL(fileURLWithPath: path).absoluteString, "type": type]
    }
}
