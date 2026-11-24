import Darwin
import Foundation

/// An immutable admitted set. Labels never acquire authority; the original adapters own it.
public final class WorkspaceNamespace {
    public struct Mount {
        public let access: WorkspaceNativeToolAccess
        public let canonicalPath: String
        public let readOnly: Bool
        public init(access: WorkspaceNativeToolAccess, canonicalPath: String, readOnly: Bool = false) {
            self.access = access
            self.canonicalPath = canonicalPath
            self.readOnly = readOnly
        }
    }

    internal struct Binding {
        let owner: WorkspaceFileSystem
        let grant: WorkspaceFileSystem.Grant
        let covering: WorkspaceFileSystem.Grant?
        let isRoot: Bool
    }

    public let mounts: [Mount]
    private let workspace: WorkspaceNativeToolAccess

    public init(mounts: [Mount], workspace: WorkspaceNativeToolAccess) throws {
        guard !mounts.isEmpty, mounts.contains(where: { $0.access === workspace }) else {
            throw WorkspaceFileSystemError.noPermissions("workspace alias must name an admitted adapter")
        }
        for (index, mount) in mounts.enumerated() {
            let path = mount.canonicalPath
            guard path.hasPrefix("/"), path != "/", !path.hasSuffix("/"), !path.contains("\0"),
                  path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  path != "/workspace", !path.hasPrefix("/workspace/"),
                  let binding = mount.access.binding, binding.owner.namespace == nil, binding.isRoot, path == mount.access.rootPath else {
                throw WorkspaceFileSystemError.noPermissions("invalid namespace mount or adapter")
            }
            try binding.covering?.verifyIdentity()
            try binding.grant.verifyIdentity()
            for other in mounts.prefix(index) {
                guard path != other.canonicalPath,
                      binding.grant !== other.access.binding?.grant,
                      !(binding.grant.identityDev == other.access.binding?.grant.identityDev && binding.grant.identityIno == other.access.binding?.grant.identityIno) else {
                    throw WorkspaceFileSystemError.noPermissions("ambiguous namespace mounts")
                }
            }
        }
        self.mounts = mounts
        self.workspace = workspace
    }

    public func nativeToolAccess(root: WorkspaceNativeToolAccess) throws -> WorkspaceNativeToolAccess {
        guard mounts.contains(where: { $0.access === root }), let binding = root.binding else {
            throw WorkspaceFileSystemError.noPermissions("root adapter is not admitted")
        }
        return binding.owner.namespaceFileSystem(self).toolAccess(grant: binding.grant, covering: binding.covering)
    }

    /// Renderer requests use exactly the same admitted set as native callbacks.
    public func fileSystem() -> WorkspaceFileSystem {
        workspace.binding!.owner.namespaceFileSystem(self)
    }

    public func perform(_ method: String, params: [String: Any]) throws -> Any {
        // Watch registrations need a persistent service owner, not a transient request facade.
        guard method != "fs.watch", method != "fs.unwatch" else {
            throw WorkspaceFileSystemError.unavailable("namespace watches require a retained filesystem service")
        }
        return try workspace.binding!.owner.namespaceFileSystem(self).perform(method, params: params)
    }

    private func sameName(_ left: String, _ right: String, grant: WorkspaceFileSystem.Grant) -> Bool {
        grant.caseSensitiveNames ? left == right : left.compare(right, options: .caseInsensitive) == .orderedSame
    }

    /// Inspect only directories. A hard link to a regular file does not confer mount authority.
    internal func mount(matching info: stat) -> WorkspaceFileSystem.Grant? {
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
        return mounts.first {
            $0.access.binding!.grant.identityDev == info.st_dev && $0.access.binding!.grant.identityIno == info.st_ino
        }?.access.binding?.grant
    }

    internal func checkMutation(parent: Int32, name: String, grant: WorkspaceFileSystem.Grant) throws {
        var entry = stat()
        guard fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw WorkspaceFileSystemError.noPermissions("cannot inspect mutation entry")
        }
        guard entry.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return }
        func check(_ fd: Int32) throws {
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw WorkspaceFileSystemError.noPermissions("cannot inspect mount ancestor") }
            guard info.st_dev != entry.st_dev || info.st_ino != entry.st_ino else {
                throw WorkspaceFileSystemError.noPermissions("cannot mutate an admitted mount or its ancestor")
            }
        }
        let root = (grant.path as NSString).pathComponents
        for mount in mounts {
            let binding = mount.access.binding!
            let components = (mount.canonicalPath as NSString).pathComponents
            guard components.count >= root.count,
                  zip(root, components).allSatisfy({ sameName($0.0, $0.1, grant: grant) }) else { continue }
            try binding.covering?.verifyIdentity()
            try binding.grant.verifyIdentity()
            var directory = dup(grant.anchorFD)
            guard directory >= 0 else { throw WorkspaceFileSystemError.noPermissions("cannot retain mount ancestor") }
            defer { close(directory) }
            try check(directory)
            // Descend from an admitted descriptor; never open a host ancestor to discover mounts.
            for component in components.dropFirst(root.count) {
                let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw WorkspaceFileSystemError.noPermissions("cannot inspect mount ancestor") }
                close(directory)
                directory = next
                try check(directory)
            }
        }
    }

    internal func mount(at path: String) -> WorkspaceFileSystem.Grant? {
        mounts.first { sameName($0.canonicalPath, path, grant: $0.access.binding!.grant) }?.access.binding?.grant
    }

    internal func label(_ grant: WorkspaceFileSystem.Grant) throws -> String {
        guard let mount = mounts.first(where: { $0.access.binding?.grant === grant }) else {
            throw WorkspaceFileSystemError.noPermissions("destination is not admitted")
        }
        return mount.canonicalPath
    }

    private func suffix(_ path: String, mount: Mount) -> String? {
        let options: String.CompareOptions = mount.access.binding!.grant.caseSensitiveNames
            ? [.anchored] : [.anchored, .caseInsensitive]
        guard let range = path.range(of: mount.canonicalPath, options: options) else { return nil }
        let tail = String(path[range.upperBound...])
        return tail.isEmpty || tail.hasPrefix("/") ? tail : nil
    }

    internal func target(_ path: String, allowAlias: Bool = true) throws -> WorkspaceFileSystem.Target {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw WorkspaceFileSystemError.noPermissions("invalid namespace path")
        }
        let alias = allowAlias && (path == "/workspace" || path.hasPrefix("/workspace/"))
        let mount = alias ? mounts.first(where: { $0.access === workspace }) : mounts.sorted { $0.canonicalPath.count > $1.canonicalPath.count }.first {
            suffix(path, mount: $0) != nil
        }
        guard let mount, let binding = mount.access.binding else {
            // Virtual ancestors carry no host descriptor authority. Walk them only until an
            // explicitly admitted mount is reached; never open an unadmitted host parent.
            var virtual: [String] = []
            let components = path.split(separator: "/").map(String.init)
            for (index, component) in components.enumerated() {
                if component == "." { continue }
                if component == ".." {
                    guard !virtual.isEmpty else { throw WorkspaceFileSystemError.noPermissions("namespace escape") }
                    virtual.removeLast()
                } else { virtual.append(component) }
                let prefix = "/" + virtual.joined(separator: "/")
                if self.mount(at: prefix) != nil {
                    let tail = components.dropFirst(index + 1).joined(separator: "/")
                    return try target(prefix + (tail.isEmpty ? "" : "/" + tail) + (path.hasSuffix("/") ? "/" : ""), allowAlias: allowAlias)
                }
                guard prefix == "/" || mounts.contains(where: { $0.canonicalPath.hasPrefix(prefix + "/") }) else {
                    throw WorkspaceFileSystemError.noPermissions("path is outside the admitted namespace")
                }
            }
            throw WorkspaceFileSystemError.noPermissions("virtual namespace ancestors are not file authority")
        }
        let relativePath = alias ? String(path.dropFirst("/workspace".count)) : self.suffix(path, mount: mount)!
        return WorkspaceFileSystem.Target(grant: binding.grant,
            components: relativePath.split(separator: "/").map(String.init) + (path.hasSuffix("/") ? ["."] : []))
    }

    internal func authorize<T>(_ grant: WorkspaceFileSystem.Grant, writing: Bool,
                               _ body: () throws -> T) throws -> T {
        guard let mount = mounts.first(where: { $0.access.binding?.grant === grant }), let binding = mount.access.binding else {
            throw WorkspaceFileSystemError.noPermissions("destination is not admitted")
        }
        guard !writing || !mount.readOnly else { throw WorkspaceFileSystemError.noPermissions("destination is read only") }
        try binding.covering?.verifyIdentity()
        try grant.verifyIdentity()
        guard grant.needsCoordination else { return try body() }
        return try withoutActuallyEscaping(body) { operation in
            try binding.owner.coordinate(grant.selectedURL, writing: writing) {
                try binding.covering?.verifyIdentity()
                try grant.verifyIdentity()
                return try operation()
            }
        }
    }
}
