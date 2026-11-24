import Foundation

/// Errors from acquiring a workspace lease.
public enum WorkspaceAccessError: Error, Equatable, CustomStringConvertible {
    /// Not a usable local `file:` URL: wrong scheme, non-local authority, C/empty path, or NUL byte.
    case notFileURL
    /// No file or directory exists at the canonical path.
    case rootNotFound(String)
    /// The canonical path exists but is not a directory.
    case notDirectory(String)
    /// The OS refused to start security-scoped access for a scope-requiring root.
    case scopeDenied(String)

    public var description: String {
        switch self {
        case .notFileURL: return "workspace root is not a usable local file URL"
        case .rootNotFound(let path): return "workspace root does not exist: \(path)"
        case .notDirectory(let path): return "workspace root is not a directory: \(path)"
        case .scopeDenied(let path): return "security-scoped access was denied: \(path)"
        }
    }
}

/// Owns access to one workspace root for as long as a caller holds its lease.
///
/// One `WorkspaceAccess` keeps one shared registry, so any number of owners of the same
/// canonical root share a single durable OS security scope. The scope starts on the first
/// scope-requiring lease and stops when the last lease is released, explicitly or by `deinit`.
///
/// Ordering rule: an external selection is authorized *before* it is touched. `acquire` starts a
/// security scope on the originally selected URL, then performs every filesystem resolution and
/// validation under that scope. A probe that does not become the durable scope is balanced.
public final class WorkspaceAccess {
    private let registry: ScopeRegistry

    /// Default hooks use the OS security-scope API on the originally selected URL.
    public convenience init() {
        self.init(
            beginScope: { $0.startAccessingSecurityScopedResource() },
            endScope: { $0.stopAccessingSecurityScopedResource() }
        )
    }

    /// Injectable hooks; tests use these to observe scope lifetime without a real OS scope.
    /// `willValidate` runs after authorization and before the first filesystem operation.
    internal init(
        beginScope: @escaping (URL) -> Bool,
        endScope: @escaping (URL) -> Void,
        willValidate: @escaping (URL) -> Void = { _ in }
    ) {
        registry = ScopeRegistry(beginScope: beginScope, endScope: endScope)
        self.willValidate = willValidate
    }

    private let willValidate: (URL) -> Void

    /// Canonicalizes an existing directory root and leases it.
    ///
    /// Apple requires `NSFileCoordinator` to touch content inside an external folder
    /// (developer.apple.com/documentation/uikit/providing-access-to-directories), so the lease
    /// exposes `selectedURL` — the URL whose authorization the registry actually holds — for
    /// native coordinators. `rootURL` stays the canonical identity used for path mapping.
    ///
    /// - Parameter rootURL: The URL the user or trusted code selected. The security scope is
    ///   started and stopped on this URL, never on the canonicalized replacement.
    /// - Parameter securityScoped: `true` for external directories the user authorized; `false`
    ///   only for app-container roots chosen by trusted code. A failed scope is never downgraded.
    public func acquire(rootURL: URL, securityScoped: Bool) throws -> WorkspaceLease {
        try Self.validateSelection(rootURL)

        // Authorize first: an external directory may be unreadable until the scope is active.
        let probeHeld = securityScoped && registry.beginProbe(rootURL)
        if securityScoped && !probeHeld {
            throw WorkspaceAccessError.scopeDenied(rootURL.path)
        }

        do {
            willValidate(rootURL)
            // Only now may the filesystem be consulted.
            let canonicalURL = try Self.canonicalRoot(rootURL)
            let held = registry.retain(
                identity: canonicalURL.path,
                selectedURL: rootURL,
                probeHeld: probeHeld
            )
            return WorkspaceLease(
                rootURL: canonicalURL,
                identity: canonicalURL.path,
                selectedURL: held.selectedURL,
                securityScoped: held.scopeActive,
                registry: registry
            )
        } catch {
            // Balance the probe: nothing was retained and no durable scope was adopted.
            if probeHeld { registry.endProbe(rootURL) }
            throw error
        }
    }

    /// Rejects unusable selections without touching the filesystem.
    private static func validateSelection(_ url: URL) throws {
        guard url.isFileURL else { throw WorkspaceAccessError.notFileURL }
        // `file://host/share` is not a local directory this app can authorize.
        if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" {
            throw WorkspaceAccessError.notFileURL
        }
        // Decode percent escapes so an explicit `%00` is seen as the NUL it stands for; the OS
        // would refuse that path anyway, and we must not start a scope for it.
        let decodedPath = url.path(percentEncoded: false)
        guard !decodedPath.isEmpty, !decodedPath.contains("\0") else {
            throw WorkspaceAccessError.notFileURL
        }
    }

    /// Resolves symlinks and confirms the root is an existing directory.
    private static func canonicalRoot(_ rootURL: URL) throws -> URL {
        let canonicalPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalPath, isDirectory: &isDirectory) else {
            throw WorkspaceAccessError.rootNotFound(canonicalPath)
        }
        guard isDirectory.boolValue else {
            throw WorkspaceAccessError.notDirectory(canonicalPath)
        }
        return URL(fileURLWithPath: canonicalPath, isDirectory: true)
    }
}

/// A held claim on one canonical workspace root.
///
/// `release()` is idempotent; `deinit` releases if the caller did not.
public final class WorkspaceLease {
    /// Canonical directory: the identity used for native/emulated path mapping.
    public let rootURL: URL
    /// Stable identity string of the canonical root.
    public let identity: String
    /// The originally selected URL whose security scope the registry holds for this root.
    /// Native code coordinating external folder content must use this URL, not an alias.
    public let selectedURL: URL
    /// `true` when a durable security scope covers this root; stop it through `release()` only.
    public let securityScoped: Bool
    /// `true` when callers must wrap content access in `NSFileCoordinator`.
    public let needsCoordination: Bool

    private let registry: ScopeRegistry
    private let lock = NSLock()
    private var released = false

    internal init(rootURL: URL, identity: String, selectedURL: URL,
                  securityScoped: Bool, registry: ScopeRegistry) {
        self.rootURL = rootURL
        self.identity = identity
        self.selectedURL = selectedURL
        self.securityScoped = securityScoped
        self.needsCoordination = securityScoped
        self.registry = registry
    }

    /// `true` until `release()` runs (or `deinit`); the registry outlives this flag.
    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !released
    }

    /// Drops this owner's claim. The durable OS scope stops only when the last claim is dropped.
    public func release() {
        lock.lock()
        if released {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        registry.release(identity: identity)
    }

    deinit {
        release()
    }
}

/// Per-`WorkspaceAccess` bookkeeping. Holds no lease references, so no cycle exists.
internal final class ScopeRegistry {
    private struct Entry {
        var selectedURL: URL
        var owners: Int
        var scopeActive: Bool
    }

    private let lock = NSLock()
    private let beginScope: (URL) -> Bool
    private let endScope: (URL) -> Void
    private var entries: [String: Entry] = [:]

    init(beginScope: @escaping (URL) -> Bool, endScope: @escaping (URL) -> Void) {
        self.beginScope = beginScope
        self.endScope = endScope
    }

    /// Starts a temporary scope so the root can be validated. Balanced by `endProbe` unless
    /// `retain` adopts it as the durable scope.
    func beginProbe(_ url: URL) -> Bool {
        beginScope(url)
    }

    func endProbe(_ url: URL) {
        endScope(url)
    }

    /// Adds one owner. The probe becomes the durable scope if none is active; otherwise it is
    /// balanced here so exactly one durable scope covers the root.
    ///
    /// Returns the durable authorization URL and whether that scope is active, so an aliased
    /// acquire never hands a consumer a URL whose authorization is not actually held.
    func retain(identity: String, selectedURL: URL, probeHeld: Bool) -> (selectedURL: URL, scopeActive: Bool) {
        lock.lock()
        defer { lock.unlock() }

        var entry = entries[identity] ?? Entry(selectedURL: selectedURL, owners: 0, scopeActive: false)
        if probeHeld {
            if entry.scopeActive {
                endScope(selectedURL)
            } else {
                entry.scopeActive = true
                entry.selectedURL = selectedURL
            }
        }
        entry.owners += 1
        entries[identity] = entry
        return (entry.selectedURL, entry.scopeActive)
    }

    /// Removes one owner, stopping the durable scope when the last one goes.
    func release(identity: String) {
        lock.lock()
        defer { lock.unlock() }

        guard var entry = entries[identity] else { return }
        entry.owners -= 1
        guard entry.owners <= 0 else {
            entries[identity] = entry
            return
        }
        entries[identity] = nil
        // Stopped under the lock so a racing acquire cannot open a second durable scope.
        if entry.scopeActive {
            endScope(entry.selectedURL)
        }
    }
}
