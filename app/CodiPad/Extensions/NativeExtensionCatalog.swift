import Foundation
import CryptoKit
import Darwin

/// Scans bundled and installed extensions and resolves the app-private storage homes.
///
/// Contract (consumed by the workbench's extension service through the native bridge):
///   {
///     "extensions": [{ "manifest": <parsed package.json>,
///                      "extensionLocation": <file URL string>,
///                      "isBuiltin": true }],
///     "appRoot": <file URL string>,
///     "globalStorageHome": <file URL string>,
///     "workspaceStorageHome": <file URL string>,
///     "logsLocation": <file URL string>
///   }
///
/// Reads the bundle and the private Marketplace installation directory. There is no user-workspace
/// storage or caller-selected search path. Symlinks are
/// checked for the catalog entry, its manifest, and its `main`; deeper JS imports are not walked.
final class NativeExtensionCatalog {
    private static let appFolderName = "CodiPad"
    private static let hostFolderName = "Exthost"
    private static let catalogFolderName = "extensions"
    private static let manifestName = "package.json"
    private static let installMetadataName = ".codipad-install.json"
    private static let uninstalledPackagesName = ".codipad-uninstalled.json"
    private static let resourcePreparationQueue = DispatchQueue(
        label: "dev.codipad.extension.resources.prepare", qos: .utility
    )

    private static var prewarmedRoot: (bundle: URL, support: URL?, result: Result<URL, Error>)?

    /// - Parameters:
    ///   - bundle: app bundle containing `Exthost/extensions` and its build receipt.
    ///   - applicationSupport: override for the Application Support root (tests only).
    static func scan(bundle: Bundle = .main, applicationSupport: URL? = nil, linuxHost: Bool = false,
                     preparedRoot: URL? = nil, userSnapshot: (URL) throws -> (installed: [[String: Any]], packages: [[String: Any]]) = userInventory) throws -> [String: Any] {
        let appRoot = try preparedRoot ?? bundledHostRoot(bundle: bundle, applicationSupport: applicationSupport)
        let catalogRoot = appRoot.appendingPathComponent(catalogFolderName, isDirectory: true)
        try requireDirectory(catalogRoot, code: "CatalogMissing")

        let homes = try privateHomes(applicationSupport: applicationSupport)
        let allBundled = try extensionEntries(in: catalogRoot, isBuiltin: true)
        let bundled = try runtimeCompatibleBuiltins(allBundled, appRoot: appRoot, linuxHost: linuxHost)
        let userRoot = try userExtensionsRoot(applicationSupport: applicationSupport)
        let inventory = try userSnapshot(userRoot)
        let extensions = (bundled + inventory.installed).sorted { lhs, rhs in
            let left = lhs["extensionLocation"] as? String ?? ""
            let right = rhs["extensionLocation"] as? String ?? ""
            return left < right
        }

        return [
            "extensions": extensions,
            "packages": bundled + inventory.packages,
            "appRoot": appRoot.absoluteString,
            "globalStorageHome": homes.global.absoluteString,
            "workspaceStorageHome": homes.workspace.absoluteString,
            "logsLocation": homes.logs.absoluteString,
            "extensionsHome": userRoot.absoluteString,
        ]
    }

    /// Filters native built-ins by the runtime that will execute them, without changing user packages.
    static func runtimeCompatibleBuiltins(_ allBundled: [[String: Any]], appRoot: URL, linuxHost: Bool) throws -> [[String: Any]] {
        let targetURL = appRoot.appendingPathComponent("builtin-runtime-targets.json")
        var linuxOnly = Set<String>()
        let descriptor = open(targetURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor >= 0 {
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw NativeExtensionCatalogError(code: "InvalidRuntimeTargets", message: "built-in runtime targets must be a regular file")
            }
            let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
            guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  raw["schemaVersion"] as? Int == 1, let targets = raw["targets"] as? [String: String],
                  targets.allSatisfy({ key, value in
                      !key.isEmpty && key != "." && key != ".." && !key.contains("/") && value == "linux-arm64"
                  }) else { throw NativeExtensionCatalogError(code: "InvalidRuntimeTargets", message: "invalid built-in runtime targets") }
            linuxOnly = Set(targets.keys)
        } else if errno != ENOENT {
            throw NativeExtensionCatalogError(code: "InvalidRuntimeTargets", message: "cannot open built-in runtime targets")
        }
        let bundled: [[String: Any]] = allBundled.compactMap { entry in
            guard let uri = entry["extensionLocation"] as? String, let url = URL(string: uri),
                  linuxOnly.contains(url.lastPathComponent) else { return entry }
            guard linuxHost else { return nil }
            var targeted = entry
            var metadata = targeted["metadata"] as? [String: Any] ?? [:]
            metadata["targetPlatform"] = "linux-arm64"
            targeted["metadata"] = metadata
            return targeted
        }
        return bundled
    }

    /// The caller supplies the already receipt-verified, canonical Exthost root. No page paths
    /// participate in selecting the stock agent entry or its mandatory native binding.
    static func agentHostArtifacts(in root: URL) throws -> (script: URL, scriptHash: String, sqlite: URL, sqliteHash: String) {
        let receiptURL = root.appendingPathComponent("agent-host/receipt.json")
        let metadata = try receiptURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard metadata.isRegularFile == true, let size = metadata.fileSize, size > 0, size <= 16 * 1024 * 1024,
              let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any],
              receipt["schemaVersion"] as? Int == 1, receipt["completionState"] as? String == "passed",
              receipt["target"] as? String == "linux-arm64",
              let launcher = receipt["launcher"] as? [String: Any], let entry = launcher["path"] as? String,
              entry.hasPrefix("agent-host/"), !entry.contains("\\"),
              entry.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let scriptHash = launcher["sha256"] as? String,
              let files = receipt["files"] as? [String: String],
              files[String(entry.dropFirst("agent-host/".count))] == scriptHash,
              let sqlite = receipt["sqlite"] as? [String: Any], let sqliteHash = sqlite["binarySha256"] as? String,
              files["node_modules/@vscode/sqlite3/build/Release/vscode-sqlite3.node"] == sqliteHash else {
            throw NativeExtensionCatalogError(code: "ArtifactUnavailable", message: "the verified stock agent host package is unavailable")
        }
        return (root.appendingPathComponent(entry), scriptHash,
            root.appendingPathComponent("agent-host/node_modules/@vscode/sqlite3/build/Release/vscode-sqlite3.node"), sqliteHash)
    }

    // MARK: - Bundled catalog

    /// All validated immutable packages, including versions retained by other profiles or hosts.
    static func packageEntries(in root: URL) throws -> [[String: Any]] {
        try extensionEntries(in: root, isBuiltin: false, includeTombstoned: true)
    }

    /// Keep older package directories available to a running host, but expose only the last
    /// installed version of each extension. This also preserves an intentional downgrade.
    static func installedEntries(in root: URL) throws -> [[String: Any]] {
        selectInstalled(try extensionEntries(in: root, isBuiltin: false))
    }

    private static func selectInstalled(_ entries: [[String: Any]]) -> [[String: Any]] {
        var selected: [String: [String: Any]] = [:]
        func timestamp(_ entry: [String: Any]) -> Double {
            (entry["metadata"] as? [String: Any])?["installedTimestamp"] as? Double ?? 0
        }
        for entry in entries {
            let manifest = entry["manifest"] as! [String: Any]
            let id = "\(manifest["publisher"] as! String).\(manifest["name"] as! String)".lowercased()
            if let previous = selected[id] {
                let previousTimestamp = timestamp(previous)
                let entryTimestamp = timestamp(entry)
                let previousLocation = previous["extensionLocation"] as? String ?? ""
                let entryLocation = entry["extensionLocation"] as? String ?? ""
                if previousTimestamp > entryTimestamp ||
                    (previousTimestamp == entryTimestamp && previousLocation >= entryLocation) {
                    continue
                }
            }
            selected[id] = entry
        }
        return selected.keys.sorted().compactMap { selected[$0] }
    }

    /// Atomically updates the sidecar for one exact immutable package directory. The URL must
    /// resolve to a visible direct child of the native extension home; callers cannot choose
    /// another path. Visible legacy install directory names remain valid catalog locations.
    /// Package files are never rewritten, so a live extension host keeps the bytes it loaded.
    static func updateMetadata(in root: URL, at location: URL, metadata changes: [String: Any]) throws -> [String: Any] {
        let package = try installedPackageLocation(in: root, at: location)
        let entry = try extensionDescription(at: package, isBuiltin: false)
        let manifest = entry["manifest"] as? [String: Any] ?? [:]
        guard manifest["publisher"] is String, manifest["name"] is String else {
            throw NativeExtensionCatalogError(code: "InvalidManifest", message: "installed extension identity is missing")
        }

        let metadataURL = package.appendingPathComponent(installMetadataName)
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            try rejectSymlink(metadataURL, code: "SymlinkMetadata")
        }
        var merged = entry["metadata"] as? [String: Any] ?? [:]
        for (key, value) in changes {
            if value is NSNull {
                merged.removeValue(forKey: key)
            } else {
                merged[key] = value
            }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            throw NativeExtensionCatalogError(code: "MetadataUpdateFailed", message: "cannot atomically update extension metadata: \(error.localizedDescription)")
        }

        var updated = entry
        updated["metadata"] = merged
        return updated
    }

    /// Hide every installed version with one atomic catalog change. Package paths and bytes
    /// remain available to active hosts; a later install receives a new, visible UUID path.
    static func markUninstalled(in root: URL, at location: URL) throws {
        let package = try installedPackageLocation(in: root, at: location)
        let entry = try extensionDescription(at: package, isBuiltin: false)
        let manifest = entry["manifest"] as! [String: Any]
        let id = "\(manifest["publisher"] as! String).\(manifest["name"] as! String)".lowercased()
        var removed = try uninstalledPackages(in: root)
        let entries = try extensionEntries(in: root, isBuiltin: false)
        let selected = selectInstalled(entries).first { candidate in
            let candidateManifest = candidate["manifest"] as! [String: Any]
            return "\(candidateManifest["publisher"] as! String).\(candidateManifest["name"] as! String)".lowercased() == id
        }
        guard let selected else {
            if removed.contains(package.lastPathComponent) { return }
            throw NativeExtensionCatalogError(code: "InvalidExtensionLocation", message: "extension is not selected in the installed catalog")
        }
        guard selected["extensionLocation"] as? String == package.absoluteString else {
            throw NativeExtensionCatalogError(code: "StaleExtensionLocation", message: "a newer package is selected for this extension")
        }
        for candidate in entries {
            let candidateManifest = candidate["manifest"] as! [String: Any]
            if "\(candidateManifest["publisher"] as! String).\(candidateManifest["name"] as! String)".lowercased() == id,
               let text = candidate["extensionLocation"] as? String, let url = URL(string: text) {
                removed.insert(url.lastPathComponent)
            }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: removed.sorted())
            try data.write(to: root.appendingPathComponent(uninstalledPackagesName), options: .atomic)
        } catch {
            throw NativeExtensionCatalogError(code: "UninstallFailed", message: "cannot atomically update installed extension state: \(error.localizedDescription)")
        }
    }

    private static func uninstalledPackages(in root: URL) throws -> Set<String> {
        let state = root.appendingPathComponent(uninstalledPackagesName)
        var info = stat()
        guard state.path.withCString({ lstat($0, &info) }) == 0 else {
            if errno == ENOENT { return [] }
            throw NativeExtensionCatalogError(code: "InvalidInstalledState", message: "cannot inspect installed extension state")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw NativeExtensionCatalogError(code: "InvalidInstalledState", message: "installed extension state is not a regular file")
        }
        do {
            guard let names = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String],
                  names.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0") }) else {
                throw NativeExtensionCatalogError(code: "InvalidInstalledState", message: "installed extension state has invalid package names")
            }
            return Set(names)
        } catch let error as NativeExtensionCatalogError { throw error }
        catch { throw NativeExtensionCatalogError(code: "InvalidInstalledState", message: "cannot read installed extension state: \(error.localizedDescription)") }
    }

    private static func installedPackageLocation(in root: URL, at location: URL) throws -> URL {
        guard location.isFileURL, location.host == nil,
              location.query == nil, location.fragment == nil, !location.path.contains("\0"),
              !location.lastPathComponent.isEmpty, !location.lastPathComponent.hasPrefix(".") else {
            throw NativeExtensionCatalogError(code: "InvalidExtensionLocation", message: "extension location is not an installed package directory")
        }

        try rejectSymlink(root, code: "InvalidHome")
        try rejectSymlink(location, code: "SymlinkExtension")
        let home = try canonicalDirectory(root, code: "InvalidHome")
        let package = try canonicalDirectory(location, code: "InvalidExtensionLocation")
        guard package.deletingLastPathComponent().path == home.path else {
            throw NativeExtensionCatalogError(code: "InvalidExtensionLocation", message: "extension location is not a direct child of the installed extension home")
        }
        try rejectSymlink(package, code: "SymlinkExtension")
        try requireDirectory(package, code: "InvalidExtensionLocation")

        return package
    }

    /// realpath is used for authority checks, while its spelling is retained in the returned
    /// URL. Foundation's standardizedFileURL can turn macOS `/private/var` into `/var`, which
    /// does not match the POSIX path identity used by the extension host.
    static func canonicalDirectory(_ url: URL, code: String) throws -> URL {
        guard let pointer = realpath(url.path, nil) else {
            throw NativeExtensionCatalogError(code: code, message: "cannot resolve extension directory: \(url.path)")
        }
        let path = String(cString: pointer)
        free(pointer)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Returns the single receipt-verified native resource tree used by both the catalog and
    /// extension-host runtime. Materialization happens on the caller's background queue.
    static func bundledHostRoot(bundle: Bundle = .main, applicationSupport: URL? = nil) throws -> URL {
        try BundledExtensionHostResources.resolve(bundle: bundle, applicationSupport: applicationSupport)
    }

    /// Start the same verification used by the first bridge request while the workbench loads.
    static func prewarmBundledHostRoot(
        bundle: Bundle = .main, applicationSupport: URL? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        resourcePreparationQueue.async {
            let result = Result { try bundledHostRoot(bundle: bundle, applicationSupport: applicationSupport) }
            prewarmedRoot = (bundle.bundleURL, applicationSupport, result)
            completion(result)
        }
    }

    /// Materializes and verifies bundled resources away from the workspace bridge's serial I/O
    /// queue. Callers publish catalog grants only after this completion returns to their queue.
    static func prepareBundledHostRoot(
        bundle: Bundle = .main,
        applicationSupport: URL? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        resourcePreparationQueue.async {
            if let prewarmed = prewarmedRoot,
               prewarmed.bundle == bundle.bundleURL, prewarmed.support == applicationSupport {
                prewarmedRoot = nil
                completion(prewarmed.result)
                return
            }
            do {
                completion(.success(try bundledHostRoot(bundle: bundle, applicationSupport: applicationSupport)))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// One directory snapshot, with visible entries checked before retained tombstones.
    static func userInventory(in root: URL) throws -> (installed: [[String: Any]], packages: [[String: Any]]) {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw NativeExtensionCatalogError(code: "CatalogUnreadable", message: "cannot list \(root.path): \(error.localizedDescription)")
        }
        let removed = try uninstalledPackages(in: root)
        let visible = try validateExtensionEntries(entries.filter { !removed.contains($0.lastPathComponent) }, isBuiltin: false)
        let hidden = try validateExtensionEntries(entries.filter { removed.contains($0.lastPathComponent) }, isBuiltin: false)
        let packages = (visible + hidden).sorted { ($0["extensionLocation"] as? String ?? "") < ($1["extensionLocation"] as? String ?? "") }
        return (selectInstalled(visible), packages)
    }

    private static func extensionEntries(in catalogRoot: URL, isBuiltin: Bool, includeTombstoned: Bool = false) throws -> [[String: Any]] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: catalogRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw NativeExtensionCatalogError(
                code: "CatalogUnreadable",
                message: "cannot list \(catalogRoot.path): \(error.localizedDescription)"
            )
        }

        let removed = isBuiltin || includeTombstoned ? Set<String>() : try uninstalledPackages(in: catalogRoot)
        return try validateExtensionEntries(entries.filter { !removed.contains($0.lastPathComponent) }, isBuiltin: isBuiltin)
    }

    /// Validates the package directories using the same strict path as a shipping scan.
    /// Kept internal so the host probe can exercise every package in a generated bundle
    /// without copying its potentially large language-server payloads.
    static func validateExtensionEntries(_ entries: [URL], isBuiltin: Bool) throws -> [[String: Any]] {
        var manifests: [[String: Any]] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try resourceValues(entry)
            if entry.lastPathComponent == "node_modules" {
                guard values.isSymbolicLink != true else {
                    throw NativeExtensionCatalogError(
                        code: "SymlinkDependencyDirectory",
                        message: "shared extension dependencies are a symlink"
                    )
                }
                guard values.isDirectory == true else {
                    throw NativeExtensionCatalogError(
                        code: "InvalidDependencyDirectory",
                        message: "shared extension dependencies are not a directory"
                    )
                }
                continue
            }
            if values.isSymbolicLink == true {
                throw NativeExtensionCatalogError(
                    code: "SymlinkExtension",
                    message: "extension entry is a symlink: \(entry.lastPathComponent)"
                )
            }
            guard values.isDirectory == true else {
                throw NativeExtensionCatalogError(
                    code: "InvalidExtensionEntry",
                    message: "extension entry is not a directory: \(entry.lastPathComponent)"
                )
            }
            try manifests.append(extensionDescription(at: entry, isBuiltin: isBuiltin))
        }
        // Deterministic output independent of directory order.
        return manifests.sorted { lhs, rhs in
            let left = lhs["extensionLocation"] as? String ?? ""
            let right = rhs["extensionLocation"] as? String ?? ""
            return left < right
        }
    }

    private static func extensionDescription(at root: URL, isBuiltin: Bool) throws -> [String: Any] {
        let manifestURL = root.appendingPathComponent(manifestName, isDirectory: false)
        let manifestValues: URLResourceValues
        do {
            manifestValues = try manifestURL.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
            )
        } catch {
            throw NativeExtensionCatalogError(
                code: "MissingManifest",
                message: "\(root.lastPathComponent) has no \(manifestName)"
            )
        }
        if manifestValues.isSymbolicLink == true {
            throw NativeExtensionCatalogError(
                code: "SymlinkManifest",
                message: "\(root.lastPathComponent)/\(manifestName) is a symlink"
            )
        }
        guard manifestValues.isRegularFile == true else {
            throw NativeExtensionCatalogError(
                code: "MissingManifest",
                message: "\(root.lastPathComponent)/\(manifestName) is not a regular file"
            )
        }

        let manifest: [String: Any]
        do {
            let data = try Data(contentsOf: manifestURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NativeExtensionCatalogError(
                    code: "InvalidManifest",
                    message: "\(root.lastPathComponent)/\(manifestName) root is not an object"
                )
            }
            manifest = object
        } catch let error as NativeExtensionCatalogError {
            throw error
        } catch {
            throw NativeExtensionCatalogError(
                code: "InvalidManifest",
                message: "cannot read \(root.lastPathComponent)/\(manifestName): \(error.localizedDescription)"
            )
        }

        try validate(manifest: manifest, at: root)
        var result: [String: Any] = [
            "manifest": manifest,
            "extensionLocation": root.absoluteString,
            "isBuiltin": isBuiltin,
        ]
        if !isBuiltin {
            let metadataURL = root.appendingPathComponent(installMetadataName)
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                try rejectSymlink(metadataURL, code: "SymlinkMetadata")
                do {
                    guard let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any] else {
                        throw NativeExtensionCatalogError(code: "InvalidMetadata", message: "extension install metadata is not an object")
                    }
                    result["metadata"] = metadata
                } catch let error as NativeExtensionCatalogError {
                    throw error
                } catch {
                    throw NativeExtensionCatalogError(code: "InvalidMetadata", message: "cannot read extension install metadata: \(error.localizedDescription)")
                }
            }
        }
        return result
    }

    private static func userExtensionsRoot(applicationSupport: URL?) throws -> URL {
        let base: URL
        if let applicationSupport {
            base = applicationSupport
        } else if let found = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = found
        } else {
            throw NativeExtensionCatalogError(code: "HomeUnavailable", message: "Application Support is unavailable")
        }
        let root = base.appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent(catalogFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try rejectSymlink(root, code: "InvalidHome")
        } catch let error as NativeExtensionCatalogError {
            throw error
        } catch {
            throw NativeExtensionCatalogError(code: "HomeUnavailable", message: "cannot create user extension home: \(error.localizedDescription)")
        }
        return root
    }

    // MARK: - Manifest validation

    private static func validate(manifest: [String: Any], at root: URL) throws {
        let label = root.lastPathComponent
        func string(_ key: String) throws -> String {
            guard let value = manifest[key] as? String, !value.isEmpty else {
                throw NativeExtensionCatalogError(
                    code: "InvalidManifest",
                    message: "\(label) is missing a non-empty \(key)"
                )
            }
            return value
        }

        _ = try string("publisher")
        _ = try string("name")
        _ = try string("version")

        guard let engines = manifest["engines"] as? [String: Any],
              let vscode = engines["vscode"] as? String, !vscode.isEmpty
        else {
            throw NativeExtensionCatalogError(
                code: "InvalidManifest",
                message: "\(label) is missing engines.vscode"
            )
        }

        if let rawMain = manifest["main"] {
            guard let main = rawMain as? String, !main.isEmpty else {
                throw NativeExtensionCatalogError(
                    code: "InvalidManifest",
                    message: "\(label) has a non-string or empty main"
                )
            }
            try validateMainPath(main, at: root, label: label)
        }
    }

    /// Validate the declared path. The upstream Node host owns CommonJS/ESM resolution,
    /// including extensionless files and directory entrypoints, and reports missing modules.
    static func validateMainPath(_ main: String, at root: URL, label: String) throws {
        guard !main.isEmpty, !main.contains("\0"), !main.contains("\\") else {
            throw NativeExtensionCatalogError(
                code: "InvalidManifest",
                message: "\(label) main is empty or contains an invalid path character"
            )
        }
        guard !main.hasPrefix("/") else {
            throw NativeExtensionCatalogError(
                code: "MainEscapesExtension",
                message: "\(label) main is absolute: \(main)"
            )
        }
        guard let rootPointer = realpath(root.path, nil) else {
            throw NativeExtensionCatalogError(code: "Unreadable", message: "cannot resolve extension directory: \(label)")
        }
        let canonicalRoot = String(cString: rootPointer)
        free(rootPointer)
        // Foundation can normalize an existing /private/var root to /var while leaving a
        // missing, extensionless child unchanged. Compare POSIX paths throughout instead.
        var candidate = canonicalRoot
        for part in main.split(separator: "/") where part != "." {
            if part == ".." {
                guard candidate != canonicalRoot else {
                    throw NativeExtensionCatalogError(code: "MainEscapesExtension", message: "\(label) main escapes the extension directory: \(main)")
                }
                candidate = String(candidate.prefix(upTo: candidate.lastIndex(of: "/")!))
            } else {
                candidate += "/" + part
            }
            if let pointer = realpath(candidate, nil) {
                candidate = String(cString: pointer)
                free(pointer)
            } else {
                // Missing suffixes are resolved by Node (for example extension -> extension.js).
                // A dangling symlink or an unreadable existing prefix is not such a suffix.
                let resolutionError = errno
                var info = stat()
                if resolutionError != ENOENT || lstat(candidate, &info) == 0 {
                    throw NativeExtensionCatalogError(code: "Unreadable", message: "cannot resolve extension main path: \(label)")
                }
            }
            guard candidate == canonicalRoot || candidate.hasPrefix(canonicalRoot + "/") else {
                throw NativeExtensionCatalogError(code: "SymlinkEscape", message: "\(label) main resolves outside the extension directory: \(main)")
            }
        }
    }

    // MARK: - Private homes

    private static func privateHomes(applicationSupport: URL?) throws -> (global: URL, workspace: URL, logs: URL) {
        let base: URL
        if let applicationSupport {
            base = applicationSupport
        } else if let found = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = found
        } else {
            throw NativeExtensionCatalogError(
                code: "HomeUnavailable",
                message: "Application Support is unavailable"
            )
        }

        let root = base.appendingPathComponent(appFolderName, isDirectory: true)
        let global = root.appendingPathComponent("globalStorage", isDirectory: true)
        let workspace = root.appendingPathComponent("workspaceStorage", isDirectory: true)
        let logs = root.appendingPathComponent("logs", isDirectory: true)

        for directory in [global, workspace, logs] {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw NativeExtensionCatalogError(
                    code: "HomeUnavailable",
                    message: "cannot create \(directory.path): \(error.localizedDescription)"
                )
            }
        }
        return (global, workspace, logs)
    }

    // MARK: - Helpers

    private static func requireDirectory(_ url: URL, code: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NativeExtensionCatalogError(
                code: code,
                message: "not an existing directory: \(url.path)"
            )
        }
    }

    private static func rejectSymlink(_ url: URL, code: String) throws {
        let values = try resourceValues(url)
        if values.isSymbolicLink == true {
            throw NativeExtensionCatalogError(code: code, message: "is a symlink: \(url.path)")
        }
    }

    private static func resourceValues(_ url: URL) throws -> URLResourceValues {
        do {
            return try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        } catch {
            throw NativeExtensionCatalogError(
                code: "Unreadable",
                message: "cannot inspect \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

}

/// Copies the immutable app-bundled extension host into the native filesystem with the
/// executable permissions lost by the app-bundle resource copy restored from its manifest.
/// The receipt inventory is the trust anchor; content-addressed roots are never rewritten.
private enum BundledExtensionHostResources {
    private struct FileRecord: Codable, Hashable {
        let path: String
        let sha256: String
    }

    private struct ReceiptDocument: Decodable {
        let extensionHostBundle: [ReceiptRecord]
    }
    private struct ReceiptRecord: Decodable {
        let path: String?
        let sha256: String?
        enum CodingKeys: String, CodingKey { case path, sha256 }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try? c.decode(String.self, forKey: .path)
            sha256 = try? c.decode(String.self, forKey: .sha256)
        }
    }

    private struct ModeManifest: Decodable {
        let schemaVersion: Int
        let entries: [ModeEntry]
    }

    private struct ModeEntry: Decodable {
        let path: String
        let mode: Int
    }

    private static let lock = NSLock()
    private static var resolvedRoots: [String: URL] = [:]
    private static let resourceFolder = "ExtensionHostResources"

    static func resolve(bundle: Bundle, applicationSupport: URL?) throws -> URL {
        lock.lock()
        defer { lock.unlock() }

        guard let source = bundle.url(forResource: "Exthost", withExtension: nil) else {
            throw NativeExtensionCatalogError(code: "BundleMissing", message: "Exthost/ is not in the app bundle")
        }
        try requireDirectory(source, code: "BundleMissing")
        let inventory = try receiptInventory(bundle: bundle)
        let contentKey = sha256(try JSONEncoder.sorted.encode(inventory))

        let base: URL
        if let applicationSupport {
            base = applicationSupport
        } else if let found = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = found
        } else {
            throw NativeExtensionCatalogError(code: "HomeUnavailable", message: "Application Support is unavailable")
        }
        if !pathExists(base) { try ensurePrivateDirectory(base) }
        let canonicalBase = try NativeExtensionCatalog.canonicalDirectory(base, code: "HomeUnavailable")
        let resolutionKey = canonicalBase.path + ":" + contentKey
        if let root = resolvedRoots[resolutionKey] { return root }

        let codipadHome = canonicalBase.appendingPathComponent("CodiPad", isDirectory: true)
        try ensurePrivateDirectory(codipadHome)
        let parent = codipadHome.appendingPathComponent(resourceFolder, isDirectory: true)
        try ensurePrivateDirectory(parent)
        let destination = parent.appendingPathComponent(contentKey, isDirectory: true)

        if pathExists(destination) {
            try verify(directory: destination, inventory: inventory)
            let canonical = try NativeExtensionCatalog.canonicalDirectory(destination, code: "InvalidResourceCache")
            resolvedRoots[resolutionKey] = canonical
            return canonical
        }

        let stage = parent.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        let sourceDirectories = try validateSourceTree(source, inventory: inventory, collectDirectories: true)
        let modes = try modeEntries(directory: source, inventory: inventory)
        do {
            try parallelCopy(source: source, stage: stage, files: inventory.map(\.path), directories: sourceDirectories)
        } catch {
            throw NativeExtensionCatalogError(code: "ResourceCopyFailed", message: "cannot stage extension-host resources: \(error.localizedDescription)")
        }
        do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.path) }
        catch { throw NativeExtensionCatalogError(code: "ResourceCacheUnavailable", message: "cannot secure staged resource root: \(error.localizedDescription)") }
        try markExcludedFromBackup(stage)
        for entry in modes {
            let file = stage.appendingPathComponent(entry.path)
            do {
                try FileManager.default.setAttributes([.posixPermissions: entry.mode], ofItemAtPath: file.path)
            } catch {
                throw NativeExtensionCatalogError(code: "PermissionRestoreFailed", message: "cannot restore mode for \(entry.path): \(error.localizedDescription)")
            }
        }
        try verify(directory: stage, inventory: inventory, modes: modes)
        try markExcludedFromBackup(stage)

        if rename(stage.path, destination.path) != 0 {
            // A second process may have published the same key while this process copied it.
            if pathExists(destination) {
                try verify(directory: destination, inventory: inventory)
                let canonical = try NativeExtensionCatalog.canonicalDirectory(destination, code: "InvalidResourceCache")
                resolvedRoots[resolutionKey] = canonical
                return canonical
            }
            throw NativeExtensionCatalogError(code: "ResourcePublishFailed", message: "cannot atomically publish extension-host resources (errno \(errno))")
        }
        let canonical = try NativeExtensionCatalog.canonicalDirectory(destination, code: "InvalidResourceCache")
        resolvedRoots[resolutionKey] = canonical
        return canonical
    }

    private static func receiptInventory(bundle: Bundle) throws -> [FileRecord] {
        guard let url = bundle.url(forResource: "BuildReceipt", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(ReceiptDocument.self, from: data) else {
            throw NativeExtensionCatalogError(code: "ReceiptMissing", message: "BuildReceipt.json has no extensionHostBundle inventory")
        }
        var seen = Set<String>()
        let records = try document.extensionHostBundle.map { item -> FileRecord in
            guard let path = item.path, validRelativePath(path),
                  let digest = item.sha256, validDigest(digest),
                  seen.insert(path).inserted else {
                throw NativeExtensionCatalogError(code: "InvalidReceipt", message: "extensionHostBundle has an invalid or duplicate file record")
            }
            return FileRecord(path: path, sha256: digest)
        }.sorted { $0.path < $1.path }
        guard !records.isEmpty, seen.contains("executable-modes.json") else {
            throw NativeExtensionCatalogError(code: "InvalidReceipt", message: "extensionHostBundle inventory is empty or lacks executable-modes.json")
        }
        return records
    }

    private static func validateSourceTree(_ root: URL, inventory: [FileRecord], collectDirectories: Bool) throws -> [String] {
        let tree = try regularFiles(root, collectDirectories: collectDirectories)
        let actual = tree.files
        let expected = Set(inventory.map(\.path))
        guard actual == expected else {
            throw NativeExtensionCatalogError(code: "InvalidResourceTree", message: "bundled Exthost file list does not match BuildReceipt.json")
        }
        return tree.directories
    }

    fileprivate static func parallelCopy(source: URL, stage: URL, files: [String], directories: [String],
                                         copy: ((URL, URL) throws -> Void)? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let ordered = directories.sorted { $0.split(separator: "/").count < $1.split(separator: "/").count }
        for path in ordered {
            try fm.createDirectory(at: stage.appendingPathComponent(path), withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        }
        let state = ParallelCopyState(files: files)
        DispatchQueue.concurrentPerform(iterations: min(4, files.count)) { _ in
            let worker = FileManager()
            while let path = state.next() {
                let from = source.appendingPathComponent(path), to = stage.appendingPathComponent(path)
                do {
                    try autoreleasepool {
                        if let copy { try copy(from, to) }
                        else { try worker.copyItem(at: from, to: to) }
                    }
                } catch { state.fail(error) }
            }
        }
        if let error = state.error() { throw error }
        for path in ordered.reversed() + [""] {
            let from = path.isEmpty ? source : source.appendingPathComponent(path)
            let to = path.isEmpty ? stage : stage.appendingPathComponent(path)
            let result = from.path.withCString { src in
                to.path.withCString { dst in
                    copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW))
                }
            }
            if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    private final class ParallelCopyState {
        private let lock = NSLock()
        private let files: [String]
        private var index = 0
        private var failure: Error?
        init(files: [String]) { self.files = files }
        func next() -> String? {
            lock.lock(); defer { lock.unlock() }
            guard failure == nil, index < files.count else { return nil }
            defer { index += 1 }
            return files[index]
        }
        func fail(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            if failure == nil { failure = error }
        }
        func error() -> Error? {
            lock.lock(); defer { lock.unlock() }
            return failure
        }
    }
    private static func verify(directory: URL, inventory: [FileRecord], modes suppliedModes: [ModeEntry]? = nil) throws {
        try requireDirectory(directory, code: "InvalidResourceCache")
        let actual = try regularFiles(directory).files
        let expected = Set(inventory.map(\.path))
        guard actual == expected else {
            throw NativeExtensionCatalogError(code: "InvalidResourceCache", message: "cached Exthost file list does not match BuildReceipt.json")
        }
        try verifyContents(directory: directory, inventory: inventory)
        let modes = try suppliedModes ?? modeEntries(directory: directory, inventory: inventory)
        for entry in modes {
            let path = directory.appendingPathComponent(entry.path).path
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw NativeExtensionCatalogError(code: "InvalidResourceCache", message: "cannot inspect executable at \(entry.path): errno \(errno)")
            }
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                throw NativeExtensionCatalogError(code: "InvalidResourceCache", message: "executable is not a regular file at \(entry.path)")
            }
            let observedMode = Int(info.st_mode & 0o777)
            guard observedMode == entry.mode else {
                throw NativeExtensionCatalogError(code: "InvalidResourceCache", message: "executable mode differs at \(entry.path): expected \(String(entry.mode, radix: 8)), observed \(String(observedMode, radix: 8))")
            }
        }
    }

    /// At most eight independent readers; choose the earliest inventory error so
    /// failure behavior stays deterministic even when workers finish out of order.
    private static func verifyContents(directory: URL, inventory: [FileRecord]) throws {
        let workerCount = min(inventory.count, max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))
        guard workerCount > 0 else { return }
        let failures = ResourceVerificationFailures()
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            var index = worker
            while index < inventory.count {
                if failures.isAfterFirstFailure(index) { break }
                let record = inventory[index]
                do {
                    let file = directory.appendingPathComponent(record.path)
                    let digest = try autoreleasepool { try fileSHA256(file) }
                    guard digest == record.sha256 else {
                        throw NativeExtensionCatalogError(code: "InvalidResourceCache", message: "cached Exthost content differs at \(record.path)")
                    }
                } catch {
                    failures.record(index: index, error: error)
                    break
                }
                index += workerCount
            }
        }
        if let error = failures.firstError() { throw error }
    }

    private final class ResourceVerificationFailures {
        private let lock = NSLock()
        private var failure: (index: Int, error: Error)?

        func isAfterFirstFailure(_ index: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return failure.map { index > $0.index } ?? false
        }

        func record(index: Int, error: Error) {
            lock.lock(); defer { lock.unlock() }
            if failure == nil || index < failure!.index { failure = (index, error) }
        }

        func firstError() -> Error? {
            lock.lock(); defer { lock.unlock() }
            return failure?.error
        }
    }

    private static func modeEntries(directory: URL, inventory: [FileRecord]) throws -> [ModeEntry] {
        let manifestURL = directory.appendingPathComponent("executable-modes.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ModeManifest.self, from: data),
              manifest.schemaVersion == 1 else {
            throw NativeExtensionCatalogError(code: "InvalidModeManifest", message: "executable-modes.json is missing or has an unsupported schema")
        }
        let files = Set(inventory.map(\.path))
        var seen = Set<String>()
        for entry in manifest.entries {
            guard validRelativePath(entry.path), files.contains(entry.path), seen.insert(entry.path).inserted,
                  (0...0o777).contains(entry.mode), entry.mode & 0o111 != 0 else {
                throw NativeExtensionCatalogError(code: "InvalidModeManifest", message: "executable-modes.json has an invalid, duplicate, or non-executable entry")
            }
            let target = directory.appendingPathComponent(entry.path).path
            var info = stat()
            guard lstat(target, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                throw NativeExtensionCatalogError(code: "InvalidModeManifest", message: "mode target is not a regular file: \(entry.path)")
            }
        }
        return manifest.entries
    }

    private static func regularFiles(_ root: URL, collectDirectories: Bool = false) throws -> (files: Set<String>, directories: [String]) {
        var directories = [String]()
        var tasks: [(URL, String)] = []
        var result = Set<String>()
        func walk(_ directory: URL, _ prefix: String, _ depth: Int, _ local: inout Set<String>, _ localDirectories: inout [String],
                  enqueue: ((URL, String) -> Void)?) throws {
            guard let stream = opendir(directory.path) else {
                throw NativeExtensionCatalogError(code: "InvalidResourceTree", message: "cannot list \(directory.path): errno \(errno)")
            }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    guard errno == 0 else { throw NativeExtensionCatalogError(code: "InvalidResourceTree", message: "cannot list \(directory.path): errno \(errno)") }
                    break
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingUTF8: $0) }
                }
                guard let name else { throw NativeExtensionCatalogError(code: "InvalidResourceTree", message: "invalid Exthost path in \(directory.path)") }
                if name == "." || name == ".." { continue }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                guard validRelativePath(relative) else { throw NativeExtensionCatalogError(code: "InvalidResourceTree", message: "invalid Exthost path: \(relative)") }
                var type = Int32(entry.pointee.d_type)
                if type == DT_UNKNOWN {
                    var info = stat()
                    guard fstatat(dirfd(stream), name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw NativeExtensionCatalogError(code: "InvalidResourceTree", message: "cannot inspect Exthost path: \(relative)") }
                    switch info.st_mode & mode_t(S_IFMT) {
                    case mode_t(S_IFDIR): type = DT_DIR
                    case mode_t(S_IFREG): type = DT_REG
                    default: type = DT_UNKNOWN
                    }
                }
                if type == DT_DIR {
                    let child = directory.appendingPathComponent(name, isDirectory: true)
                    if collectDirectories { localDirectories.append(relative) }
                    if depth == 2, let enqueue { enqueue(child, relative) }
                    else { try walk(child, relative, depth + 1, &local, &localDirectories, enqueue: enqueue) }
                } else if type == DT_REG {
                    guard local.insert(relative).inserted else { throw NativeExtensionCatalogError(code: "InvalidResourceTree", message: "duplicate Exthost path: \(relative)") }
                } else { throw NativeExtensionCatalogError(code: "InvalidResourceTree", message: "Exthost contains a symlink or unsupported file: \(relative)") }
            }
        }
        try requireDirectory(root, code: "InvalidResourceTree")
        try walk(root, "", 0, &result, &directories) { tasks.append(($0, $1)) }
        let work = tasks
        let mergeLock = NSLock()
        var failures: [(Int, Error)] = []
        let workerCount = min(work.count, max(1, min(4, ProcessInfo.processInfo.activeProcessorCount)))
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            var i = worker
            while i < work.count {
                var local = Set<String>()
                var localDirectories = [String]()
                do {
                    try walk(work[i].0, work[i].1, 3, &local, &localDirectories, enqueue: nil)
                    mergeLock.lock()
                    if let duplicate = local.first(where: { result.contains($0) }) {
                        failures.append((i, NativeExtensionCatalogError(code: "InvalidResourceTree", message: "duplicate Exthost path: \(duplicate)")))
                    } else {
                        result.formUnion(local)
                        directories.append(contentsOf: localDirectories)
                    }
                    mergeLock.unlock()
                } catch {
                    mergeLock.lock(); failures.append((i,error)); mergeLock.unlock()
                }
                i += workerCount
            }
        }
        if let failure = failures.min(by: { $0.0 < $1.0 }) { throw failure.1 }
        return (result, directories)
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        if pathExists(url) {
            try requireDirectory(url, code: "InvalidResourceCache")
            return
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw NativeExtensionCatalogError(code: "ResourceCacheUnavailable", message: "cannot create private resource cache: \(error.localizedDescription)")
        }
        try requireDirectory(url, code: "InvalidResourceCache")
    }

    private static func requireDirectory(_ url: URL, code: String) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw NativeExtensionCatalogError(code: code, message: "not a regular directory: \(url.path)")
        }
    }

    private static func markExcludedFromBackup(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try target.setResourceValues(values) }
        catch { throw NativeExtensionCatalogError(code: "ResourceCacheUnavailable", message: "cannot exclude resource cache from backup: \(error.localizedDescription)") }
    }

    private static func pathExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    private static func fileSHA256(_ url: URL) throws -> String {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
            return hexadecimal(hasher.finalize())
        } catch {
            throw NativeExtensionCatalogError(code: "ResourceReadFailed", message: "cannot hash \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func sha256(_ data: Data) -> String {
        hexadecimal(SHA256.hash(data: data))
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func hexadecimal<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        var result = [UInt8]()
        result.reserveCapacity(64)
        for byte in bytes {
            result.append(hexDigits[Int(byte >> 4)])
            result.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0") else { return false }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// Named failure for catalog scanning; the bridge maps `code` and `message` into `exthost.scan`.
enum NativeExtensionCatalogError: Error, CustomStringConvertible {
    case failure(code: String, message: String)

    init(code: String, message: String) {
        self = .failure(code: code, message: message)
    }

    var code: String {
        guard case .failure(let code, _) = self else { return "Unknown" }
        return code
    }

    var message: String {
        guard case .failure(_, let message) = self else { return "unknown catalog failure" }
        return message
    }

    var description: String { "\(code): \(message)" }
}
