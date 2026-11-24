import Darwin
import Foundation

public enum WorkspaceNativeToolEntryKind: Int {
    case unknown = 0
    case file = 1
    case directory = 2
    case symbolicLink = 3
    case other = 4
}

public struct WorkspaceNativeToolDirectoryEntry {
    public let name: String
    public let kind: WorkspaceNativeToolEntryKind
    public let size: UInt64
}

public struct WorkspaceNativeToolFailure: Error {
    public let errno: Int32
    public init(errno: Int32) { self.errno = errno }
}

/// Descriptor-relative file bytes and the identity of their authorized parent. This exposes no
/// additional directory authority; atomic replacement of the file keeps its workspace identity.
public struct WorkspaceNativeFileSnapshot {
    public let url: URL
    public let parentMetadata: stat
    public let data: Data
}

/// Thread-safe native process callbacks bound to one WorkspaceFileSystem directory grant.
/// Descriptors returned by `open` belong to the caller and must be closed by that caller.
public final class WorkspaceNativeToolAccess {
    internal var binding: WorkspaceNamespace.Binding?
    public let rootPath: String
    public let rootCString: UnsafeMutablePointer<CChar>
    public let accessGeneration: UInt64

    private var parent: WorkspaceNativeToolAccess?
    private let acquireBody: (String) throws -> WorkspaceNativeToolAccess
    private let release: () -> Void
    private var lock = NSRecursiveLock()
    private let openBody: (String, Int32, UInt32) throws -> Int32
    private let statBody: (String, UnsafeMutablePointer<stat>) throws -> Int32
    private let mkdirBody: (String, UInt32) throws -> Int32
    private let unlinkBody: (String, Bool) throws -> Int32
    private let renameBody: (String, String) throws -> Int32
    private let chdirBody: (String, UnsafeMutablePointer<CChar>, Int) throws -> Int32
    private let listDirectoryBody: (String) throws -> [WorkspaceNativeToolDirectoryEntry]
    private let symlinkBody: (String, String) throws -> Int32
    private let readlinkBody: (String, UnsafeMutablePointer<CChar>, Int, UnsafeMutablePointer<Int>) throws -> Int32

    internal init(rootPath: String, accessGeneration: UInt64,
                  open: @escaping (String, Int32, UInt32) throws -> Int32,
                  stat: @escaping (String, UnsafeMutablePointer<stat>) throws -> Int32,
                  mkdir: @escaping (String, UInt32) throws -> Int32,
                  unlink: @escaping (String, Bool) throws -> Int32,
                  rename: @escaping (String, String) throws -> Int32,
                  chdir: @escaping (String, UnsafeMutablePointer<CChar>, Int) throws -> Int32,
                  listDirectory: @escaping (String) throws -> [WorkspaceNativeToolDirectoryEntry],
                  symlink: @escaping (String, String) throws -> Int32,
                  readlink: @escaping (String, UnsafeMutablePointer<CChar>, Int, UnsafeMutablePointer<Int>) throws -> Int32,
                  acquire: @escaping (String) throws -> WorkspaceNativeToolAccess,
                  release: @escaping () -> Void = {}) {
        self.acquireBody = acquire
        self.release = release
        self.rootPath = rootPath
        self.rootCString = strdup(rootPath)!
        self.accessGeneration = accessGeneration
        self.openBody = open
        self.statBody = stat
        self.mkdirBody = mkdir
        self.unlinkBody = unlink
        self.renameBody = rename
        self.chdirBody = chdir
        self.listDirectoryBody = listDirectory
        self.symlinkBody = symlink
        self.readlinkBody = readlink
    }

    deinit { release(); free(rootCString) }

    /// A separately owned cwd adapter; absolute paths still use the original root authority.
    public func acquireDirectory(path: String) throws -> WorkspaceNativeToolAccess {
        lock.lock(); defer { lock.unlock() }
        let child = try acquireBody(path)
        child.lock = self.lock
        child.parent = self.parent ?? self
        return child
    }

    public func getcwd(resolved: UnsafeMutablePointer<CChar>, capacity: Int) -> Int32 {
        chdir(path: ".", resolved: resolved, capacity: capacity)
    }

    public func open(path: String, flags: Int32, mode: UInt32) -> Int32 {
        run { try openBody(path, flags, mode) }
    }

    /// lstat semantics: inspect the final link itself; intermediate relative links may be followed.
    public func stat(path: String, into result: UnsafeMutablePointer<stat>) -> Int32 {
        run { try statBody(path, result) }
    }

    public func mkdir(path: String, mode: UInt32) -> Int32 {
        run { try mkdirBody(path, mode) }
    }

    public func unlink(path: String, directory: Bool) -> Int32 {
        run { try unlinkBody(path, directory) }
    }

    public func rename(from: String, to: String) -> Int32 {
        run { try renameBody(from, to) }
    }

    public func chdir(path: String, resolved: UnsafeMutablePointer<CChar>, capacity: Int) -> Int32 {
        run { try chdirBody(path, resolved, capacity) }
    }

    public func listDirectory(path: String) -> Result<[WorkspaceNativeToolDirectoryEntry], WorkspaceNativeToolFailure> {
        lock.lock()
        defer { lock.unlock() }
        do { return .success(try listDirectoryBody(path)) }
        catch let error as WorkspaceFileSystemError { return .failure(WorkspaceNativeToolFailure(errno: errno(for: error))) }
        catch { return .failure(WorkspaceNativeToolFailure(errno: -EIO)) }
    }

    public func symlink(target: String, linkPath: String) -> Int32 {
        run { try symlinkBody(target, linkPath) }
    }

    public func readlink(path: String, into buffer: UnsafeMutablePointer<CChar>, capacity: Int,
                         outLength: UnsafeMutablePointer<Int>) -> Int32 {
        run { try readlinkBody(path, buffer, capacity, outLength) }
    }

    private func run(_ operation: () throws -> Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        do { return try operation() }
        catch let error as WorkspaceFileSystemError {
            return errno(for: error)
        } catch {
            return -EIO
        }
    }

    private func errno(for error: WorkspaceFileSystemError) -> Int32 {
        if let code = error.posixCode { return -code }
        switch error.code {
        case "FileNotFound": return -ENOENT
        case "FileExists": return -EEXIST
        case "NoPermissions": return -EACCES
        case "FileNotADirectory": return -ENOTDIR
        case "FileIsADirectory": return -EISDIR
        default: return -EIO
        }
    }
}
