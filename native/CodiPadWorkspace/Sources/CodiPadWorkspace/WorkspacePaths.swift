import Foundation

/// Translates between the fixed guest path space (`/workspace`) and one native
/// root directory. Returned URLs and guest strings preserve the user-visible
/// path, including in-root symlink names and `..`; a separate sequential walk
/// resolves symlinks only to validate containment. This is path translation
/// only, not race-resistant filesystem authorization: a consumer must still
/// guard against TOCTOU changes between translation and file access. Escaped or
/// dangling symlink referents are rejected by the default API; a full lstat
/// policy outside the referent is left to the filesystem authority. Nothing is
/// mounted or copied.
public struct WorkspacePaths: Sendable {
    public static let guestRoot = "/workspace"

    /// Canonical, existing native directory. Symlinks are resolved.
    public let rootURL: URL

    public init(rootURL: URL) throws {
        guard rootURL.isFileURL else {
            throw WorkspacePathsError.rootIsNotFileURL
        }
        guard rootURL.host == nil || rootURL.host!.isEmpty else {
            throw WorkspacePathsError.nonLocalFileURL(rootURL.absoluteString)
        }
        guard !rootURL.path(percentEncoded: false).contains("\0") else {
            throw WorkspacePathsError.invalidPath(rootURL.absoluteString)
        }
        // Resolve symlinks first; standardizing beforehand would collapse ".."
        // against the wrong side of a symlink.
        let canonical = rootURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspacePathsError.rootIsNotDirectory(canonical.path)
        }
        self.rootURL = canonical
    }

    public func nativeURL(forGuestPath guestPath: String) throws -> URL {
        let components = try Self.absoluteComponents(of: guestPath, isGuestPath: true)
        guard components.first == "workspace" else {
            throw WorkspacePathsError.guestPathOutsideWorkspace(guestPath)
        }
        let relative = Array(components.dropFirst())
        _ = try map(components: relative, original: guestPath, isGuestPath: true)
        return rawURL(relativeComponents: relative)
    }

    public func guestPath(forNativeURL nativeURL: URL) throws -> String {
        guard nativeURL.isFileURL else {
            throw WorkspacePathsError.nativeURLIsNotFileURL(nativeURL.absoluteString)
        }
        guard nativeURL.host == nil || nativeURL.host!.isEmpty else {
            throw WorkspacePathsError.nonLocalFileURL(nativeURL.absoluteString)
        }
        let path = nativeURL.path(percentEncoded: false)
        guard !path.contains("\0") else {
            throw WorkspacePathsError.invalidPath(nativeURL.absoluteString)
        }
        let components = try Self.absoluteComponents(of: path, isGuestPath: false)
        let rootComponents = Array(rootURL.pathComponents.dropFirst())

        // Match the canonical native root literally; only components after it
        // are resolved one at a time.
        var index = 0
        for rootComponent in rootComponents {
            while index < components.count && components[index] == "." {
                index += 1
            }
            guard index < components.count, components[index] == rootComponent else {
                throw WorkspacePathsError.nativePathOutsideWorkspace(path)
            }
            index += 1
        }

        let relative = Array(components[index...])
        _ = try map(components: relative, original: path, isGuestPath: false)
        return ([Self.guestRoot] + relative).joined(separator: "/")
    }

    private static func absoluteComponents(of path: String, isGuestPath: Bool) throws -> [String] {
        guard !path.contains("\0") else {
            throw WorkspacePathsError.invalidPath(path)
        }
        guard path.hasPrefix("/") else {
            throw isGuestPath
                ? WorkspacePathsError.guestPathOutsideWorkspace(path)
                : WorkspacePathsError.nativePathOutsideWorkspace(path)
        }
        return path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Walks components from the canonical root, resolving existing symlinks
    /// before following later components. `.` and `..` therefore apply to the
    /// real location (`link/../x` uses link's target parent), and `..` cannot
    /// leave the mount root.
    private func map(components: [String], original: String, isGuestPath: Bool) throws -> URL {
        let fileManager = FileManager.default
        var current = rootURL
        var index = 0

        func outside() -> WorkspacePathsError {
            isGuestPath
                ? .guestPathOutsideWorkspace(original)
                : .nativePathOutsideWorkspace(original)
        }

        func requireDirectory(_ url: URL) throws {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                throw WorkspacePathsError.notDirectory(url.path)
            }
        }

        while index < components.count {
            try requireDirectory(current)
            let component = components[index]

            if component == "." {
                index += 1
                continue
            }

            if component == ".." {
                guard current.standardizedFileURL.path != rootURL.path else {
                    throw outside()
                }
                let parent = current.deletingLastPathComponent().standardizedFileURL
                guard isInsideRoot(parent) else { throw outside() }
                current = parent
                index += 1
                continue
            }

            let next = current.appendingPathComponent(component)
            let isSymlink = (try? fileManager.destinationOfSymbolicLink(atPath: next.path)) != nil
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: next.path, isDirectory: &isDirectory)

            if isSymlink || exists {
                let resolved = next.resolvingSymlinksInPath().standardizedFileURL
                guard isInsideRoot(resolved) else {
                    throw WorkspacePathsError.symlinkEscapesWorkspace(next.path)
                }
                if isSymlink && !fileManager.fileExists(atPath: resolved.path) {
                    throw WorkspacePathsError.symlinkTargetMissing(next.path)
                }
                current = resolved
                index += 1
                continue
            }

            // First missing component: fold the remaining suffix lexically
            // against the last canonical parent.
            var suffix = [component]
            for rest in components[(index + 1)...] {
                if rest == "." {
                    continue
                }
                if rest == ".." {
                    // A missing ancestor is ambiguous: "missing/../x" may not
                    // alias an existing sibling. Reject instead of guessing.
                    throw WorkspacePathsError.missingAncestorTraversal(original)
                } else {
                    suffix.append(rest)
                }
            }

            var result = current
            for rest in suffix {
                result.appendPathComponent(rest)
            }
            guard isInsideRoot(result.standardizedFileURL) else { throw outside() }
            return result
        }

        return current
    }

    /// Rebuilds the user-visible path without resolving symlinks or collapsing
    /// `..`; the OS resolves those at access time, preserving link identity.
    private func rawURL(relativeComponents: [String]) -> URL {
        var url = rootURL
        for component in relativeComponents {
            url.appendPathComponent(component)
        }
        return url
    }

    private func isInsideRoot(_ candidate: URL) -> Bool {
        let rootComponents = rootURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}

public enum WorkspacePathsError: Error, Equatable, CustomStringConvertible {
    case rootIsNotFileURL
    case rootIsNotDirectory(String)
    case guestPathOutsideWorkspace(String)
    case nativeURLIsNotFileURL(String)
    case nonLocalFileURL(String)
    case nativePathOutsideWorkspace(String)
    case symlinkEscapesWorkspace(String)
    case symlinkTargetMissing(String)
    case notDirectory(String)
    case invalidPath(String)
    case missingAncestorTraversal(String)

    public var description: String {
        switch self {
        case .rootIsNotFileURL:
            return "workspace root must be a file URL"
        case .rootIsNotDirectory(let path):
            return "workspace root is not an existing directory: \(path)"
        case .guestPathOutsideWorkspace(let path):
            return "guest path is outside \(WorkspacePaths.guestRoot): \(path)"
        case .nativeURLIsNotFileURL(let url):
            return "native URL must be a file URL: \(url)"
        case .nonLocalFileURL(let url):
            return "file URL must be local, with no host authority: \(url)"
        case .nativePathOutsideWorkspace(let path):
            return "native path is outside the workspace root: \(path)"
        case .symlinkEscapesWorkspace(let path):
            return "existing symlink escapes the workspace root: \(path)"
        case .symlinkTargetMissing(let path):
            return "existing symlink has a missing target: \(path)"
        case .notDirectory(let path):
            return "path component is not a directory: \(path)"
        case .invalidPath(let path):
            return "path contains an unsupported NUL character: \(path)"
        case .missingAncestorTraversal(let path):
            return "path traverses above a missing ancestor: \(path)"
        }
    }
}
