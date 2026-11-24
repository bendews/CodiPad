import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Serializes profile manifest transactions across workbench scenes.
final class NativeExtensionProfileFence {
    static let shared = NativeExtensionProfileFence()
    private let lock = NSLock()
    private var active: (owner: UUID, token: String)?
    private var waiting: [(owner: UUID, reply: (String) -> Void)] = []
    private var interruptedThisProcess = false

    func perform<T>(owner: UUID, token: String, _ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard active?.owner == owner, active?.token == token else {
            throw NativeExtensionStoreError(code: "InvalidFence", message: "Extension profile fence is not owned by this scene")
        }
        let marker = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodiPad/extension-profile-recovery")
        guard !interruptedThisProcess else {
            throw NativeExtensionStoreError(code: "RecoveryRequired", message: "Extension profile references require recovery before cleanup")
        }
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
        return try body()
    }

    func acquire(owner: UUID, reply: @escaping (String) -> Void) {
        lock.lock()
        if active != nil { waiting.append((owner, reply)); lock.unlock(); return }
        let token = UUID().uuidString.lowercased()
        active = (owner, token)
        lock.unlock()
        reply(token)
    }

    func release(owner: UUID, token: String, mutated: Bool = false) -> Bool {
        lock.lock()
        guard active?.owner == owner, active?.token == token else { lock.unlock(); return false }
        if mutated { NativeExtensionStore.noteProfileMutation() }
        active = nil
        let next = nextLocked()
        lock.unlock()
        if let next { next.reply(next.token) }
        return true
    }

    func abandon(owner: UUID) {
        lock.lock()
        waiting.removeAll { $0.owner == owner }
        let owns = active?.owner == owner
        if owns { interruptedThisProcess = true }
        // A discarded renderer may have submitted a profile write whose outcome is unknown.
        // Keep a durable recovery marker before allowing another scene to proceed.
        let mayRelease = !owns || markRecoveryRequired()
        if owns && mayRelease { active = nil }
        let next = owns && mayRelease ? nextLocked() : nil
        lock.unlock()
        if let next { next.reply(next.token) }
    }

    private func markRecoveryRequired() -> Bool {
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CodiPad", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("profile-write-outcome-unknown\n".utf8).write(to: root.appendingPathComponent("extension-profile-recovery"), options: .atomic)
            return true
        } catch { return false }
    }

    private func nextLocked() -> (token: String, reply: (String) -> Void)? {
        guard !waiting.isEmpty else { return nil }
        let next = waiting.removeFirst()
        let token = UUID().uuidString.lowercased()
        active = (next.owner, token)
        return (token, next.reply)
    }
}

/// Installs Marketplace and authorized local VSIX packages into the app-wide native extension home.
/// The host selects the destination; no renderer-supplied filesystem path is accepted.
final class NativeExtensionStore {
    private static let appFolderName = "CodiPad"
    private static let extensionsFolderName = "extensions"
    private static let metadataName = ".codipad-install.json"
    private let marketplace: NativeMarketplaceClient
    // All windows publish into the same extension home.
    private static let commitLock = NSLock()
    private static var generation: UInt64 = 0
    private static var generationExhausted = false
    private let publicationOwner = UUID()
    private static var processPublications: [String: UUID] = [:]
    private static var hostLeases: [UUID: Set<String>] = [:]
    private static var assetLeases: [UUID: Set<String>] = [:]

    private static func packageKey(_ uri: String) -> String {
        URL(string: uri)?.standardizedFileURL.path ?? uri
    }

    static func retainHostPackages(owner: UUID, packages: Set<String>) {
        commitLock.lock(); defer { commitLock.unlock() }
        hostLeases[owner] = Set(packages.map(packageKey)).union(assetLeases[owner] ?? [])
    }

    static func setRegisteredPackages(owner: UUID, packages: Set<String>) {
        commitLock.lock(); defer { commitLock.unlock() }
        let keys = Set(packages.map(packageKey))
        assetLeases[owner] = keys
        // A live host can still lazy-load code it received before an update.
        hostLeases[owner]?.formUnion(keys)
    }

    static func releaseHostPackages(owner: UUID) {
        commitLock.lock(); defer { commitLock.unlock() }; hostLeases.removeValue(forKey: owner)
    }

    static func releaseAssetPackages(owner: UUID) {
        commitLock.lock(); defer { commitLock.unlock() }; assetLeases.removeValue(forKey: owner)
    }

    func releasePublication(_ uri: String) {
        Self.commitLock.lock(); defer { Self.commitLock.unlock() }
        let key = Self.packageKey(uri)
        if Self.processPublications[key] == publicationOwner { Self.processPublications.removeValue(forKey: key) }
    }

    deinit {
        Self.commitLock.lock(); defer { Self.commitLock.unlock() }
        Self.processPublications = Self.processPublications.filter { $0.value != publicationOwner }
    }

    func collectUnreferenced(references: Set<String>) throws -> [String] {
        Self.commitLock.lock(); defer { Self.commitLock.unlock() }
        var removed: [String] = []
        var deleting = false
        defer { if deleting { Self.advanceCatalogGeneration() } }
        let root = try extensionsRoot()
        let inventory = try NativeExtensionCatalog.userInventory(in: root).packages
        let protected = Self.hostLeases.values.reduce(Set(references.map(Self.packageKey)).union(Self.processPublications.keys)) { $0.union($1) }
        let retained = Self.assetLeases.values.reduce(protected) { $0.union($1) }
        for entry in inventory {
            guard let text = entry["extensionLocation"] as? String, !retained.contains(Self.packageKey(text)),
                  let url = URL(string: text), url.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
                  url.lastPathComponent.hasPrefix("package-") else { continue }
            deleting = true
            try FileManager.default.removeItem(at: url)
            removed.append(text)
        }
        // Also finish a previous collection interrupted between removing a package and its archive.
        let archives = root.appendingPathComponent(".archives", isDirectory: true)
        let manager = FileManager.default
        if manager.fileExists(atPath: archives.path) {
            let attributes = try manager.attributesOfItem(atPath: archives.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw NativeExtensionStoreError(code: "InvalidHome", message: "The retained extension archive directory is invalid")
            }
            for archive in try manager.contentsOfDirectory(at: archives, includingPropertiesForKeys: nil) where archive.pathExtension == "vsix" {
                let name = archive.deletingPathExtension().lastPathComponent
                guard name.hasPrefix("package-"), UUID(uuidString: String(name.dropFirst("package-".count))) != nil,
                      !manager.fileExists(atPath: root.appendingPathComponent(name).path) else { continue }
                try manager.removeItem(at: archive)
            }
        }
        return removed
    }

    private static func advanceCatalogGeneration() {
        if generation == UInt64.max { generationExhausted = true }
        else { generation += 1 }
    }

    static func noteProfileMutation() {
        commitLock.lock(); defer { commitLock.unlock() }
        advanceCatalogGeneration()
    }

    /// The same lock protects catalog snapshots and every process-owned mutation.
    static func withCatalogSnapshot<T>(_ body: () throws -> T) rethrows -> (T, UInt64?) {
        commitLock.lock()
        defer { commitLock.unlock() }
        return (try body(), generationExhausted ? nil : generation)
    }

    static func catalogGeneration() -> UInt64? {
        commitLock.lock()
        defer { commitLock.unlock() }
        return generationExhausted ? nil : generation
    }
    private let applicationSupport: URL?

    init(marketplace: NativeMarketplaceClient = NativeMarketplaceClient(), applicationSupport: URL? = nil) {
        self.marketplace = marketplace
        self.applicationSupport = applicationSupport
    }

    func install(id: String, version: String, targetPlatform: String, downloadURI: URL, options: [String: Bool] = [:]) async throws -> [String: Any] {
        let (archive, gallery, digest) = try await downloadGalleryArchive(id: id, version: version, targetPlatform: targetPlatform, downloadURI: downloadURI)
        return try commitVSIX(archive, id: id, version: version, targetPlatform: targetPlatform,
                              digest: digest, options: options, provenance: [
                                "id": gallery.extensionID, "publisherId": gallery.publisherID,
                                "publisherDisplayName": gallery.publisherDisplayName, "source": "gallery",
                              ])
    }

    func downloadGalleryVSIX(id: String, version: String, targetPlatform: String, downloadURI: URL) async throws -> Data {
        try await downloadGalleryArchive(id: id, version: version, targetPlatform: targetPlatform, downloadURI: downloadURI).0
    }

    private func downloadGalleryArchive(id: String, version: String, targetPlatform: String, downloadURI: URL) async throws -> (Data, GalleryMetadata, String) {
        try Task.checkCancellation()
        try Self.validateIdentity(id: id, version: version, targetPlatform: targetPlatform)
        try NativeMarketplaceClient.validate(downloadURI)

        let gallery = try await galleryMetadata(id: id, version: version, targetPlatform: targetPlatform)
        try Task.checkCancellation()
        let response = try await marketplace.request(url: downloadURI)
        try Task.checkCancellation()
        guard (200..<300).contains(response.status) else {
            throw NativeExtensionStoreError(code: "DownloadFailed", message: "Marketplace returned HTTP \(response.status)")
        }
        guard response.body.count <= NativeMarketplaceClient.maximumResponseBodyBytes else {
            throw NativeExtensionStoreError(code: "PackageTooLarge", message: "VSIX package exceeds the size limit")
        }
        let actualDigest = SHA256.hash(data: response.body).map { String(format: "%02x", $0) }.joined()
        guard actualDigest == gallery.sha256 else {
            throw NativeExtensionStoreError(code: "PackageHashMismatch", message: "VSIX SHA-256 does not match the Marketplace gallery")
        }

        return (response.body, gallery, actualDigest)
    }

    /// The bridge reads these bytes through its existing filesystem authority, retaining the
    /// grant for that read. The renderer cannot select a native installation destination.
    func getVSIXManifest(_ archive: Data) throws -> [String: Any] {
        try Self.validateArchiveSize(archive)
        let root = try Self.withCatalogSnapshot { try extensionsRoot() }.0
        return try withStagedVSIX(archive, in: root) { packageRoot, manifest in
            guard let publisher = manifest["publisher"] as? String, let name = manifest["name"] as? String,
                  let version = manifest["version"] as? String else {
                throw NativeExtensionStoreError(code: "InvalidManifest", message: "VSIX manifest identity is missing")
            }
            try Self.validateIdentity(id: "\(publisher).\(name)", version: version, targetPlatform: "undefined")
            _ = try validate(manifest: manifest, id: "\(publisher).\(name)", version: version, targetPlatform: nil, packageRoot: packageRoot)
            return manifest
        }
    }

    func installVSIX(_ archive: Data, id: String, version: String, targetPlatform: String,
                     options: [String: Bool] = [:]) throws -> [String: Any] {
        try Task.checkCancellation()
        try Self.validateIdentity(id: id, version: version, targetPlatform: targetPlatform)
        try Self.validateArchiveSize(archive)
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        return try commitVSIX(archive, id: id, version: version, targetPlatform: targetPlatform,
                              digest: digest, options: options, provenance: ["source": "vsix"])
    }

    func retainedVSIX(extensionLocation: URL) throws -> Data {
        try Self.withCatalogSnapshot {
            let root = try extensionsRoot()
            let location = extensionLocation.standardizedFileURL
            guard location.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
                  location.lastPathComponent.hasPrefix("package-"),
                  let entry = try NativeExtensionCatalog.userInventory(in: root).packages.first(where: {
                      ($0["extensionLocation"] as? String).flatMap(URL.init(string:))?.standardizedFileURL.path == location.path
                  }) else {
                throw NativeExtensionStoreError(code: "InvalidPackage", message: "Extension package identity is unavailable")
            }
            let archive = root.appendingPathComponent(".archives", isDirectory: true)
                .appendingPathComponent(location.lastPathComponent + ".vsix")
            if !FileManager.default.fileExists(atPath: archive.path) {
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vsix")
                defer { try? FileManager.default.removeItem(at: temporary) }
                var error = [CChar](repeating: 0, count: 512)
                let result = location.path.withCString { source in
                    temporary.path.withCString { destination in
                        codipad_vsix_pack(source, destination, &error, error.count)
                    }
                }
                guard result == 0 else {
                    throw NativeExtensionStoreError(code: "PackageExportFailed", message: String(cString: error))
                }
                let bytes = try Data(contentsOf: temporary, options: .mappedIfSafe)
                try Self.validateArchiveSize(bytes)
                return bytes
            }
            guard let metadata = entry["metadata"] as? [String: Any],
                  let expected = metadata["vsixSha256"] as? String else {
                throw NativeExtensionStoreError(code: "InvalidPackage", message: "Retained archive provenance is unavailable")
            }
            let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
            try Self.validateArchiveSize(bytes)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else {
                throw NativeExtensionStoreError(code: "PackageHashMismatch", message: "Retained extension archive was changed")
            }
            return bytes
        }.0
    }

    /// Removal changes catalog selection only. Loaded packages retain their exact paths until
    /// host cleanup is confirmed; this operation never deletes extension code or user storage.
    func uninstall(extensionLocation: URL) throws {
        Self.commitLock.lock()
        defer { Self.advanceCatalogGeneration(); Self.commitLock.unlock() }
        do { try NativeExtensionCatalog.markUninstalled(in: extensionsRoot(), at: extensionLocation) }
        catch let error as NativeExtensionCatalogError {
            throw NativeExtensionStoreError(code: error.code, message: error.message)
        }
    }

    private func commitVSIX(_ archive: Data, id: String, version: String, targetPlatform: String,
                            digest: String, options: [String: Bool], provenance: [String: Any]) throws -> [String: Any] {
        try Self.validateArchiveSize(archive)
        try Task.checkCancellation()
        let root = try Self.withCatalogSnapshot { try extensionsRoot() }.0
        return try withStagedVSIX(archive, in: root) { packageRoot, manifest in
            let packagePlatform = try validate(manifest: manifest, id: id, version: version, targetPlatform: targetPlatform, packageRoot: packageRoot)
            Self.commitLock.lock()
            defer { Self.advanceCatalogGeneration(); Self.commitLock.unlock() }
            try Task.checkCancellation()
            let existing = try NativeExtensionCatalog.installedEntries(in: root).first { entry in
                guard let manifest = entry["manifest"] as? [String: Any],
                      let publisher = manifest["publisher"] as? String, let name = manifest["name"] as? String else { return false }
                return "\(publisher).\(name)".lowercased() == id.lowercased()
            }
            let previousMetadata = existing?["metadata"] as? [String: Any] ?? [:]
            let installedAt = try Self.nextInstallationTimestamp(after: previousMetadata["installedTimestamp"])
            let metadata: [String: Any] = provenance.merging([
                "targetPlatform": packagePlatform,
                "isApplicationScoped": options["isApplicationScoped"] ?? false,
                "isMachineScoped": options["isMachineScoped"] ?? false,
                "isPreReleaseVersion": options["isPreReleaseVersion"] ?? false,
                "hasPreReleaseVersion": options["hasPreReleaseVersion"] ?? false,
                "preRelease": options["preRelease"] ?? (options["installPreReleaseVersion"] == true || options["isPreReleaseVersion"] == true),
                "vsixSha256": digest,
                "size": archive.count,
                "installedTimestamp": installedAt,
                "updated": existing != nil,
                "pinned": options["pinned"] ?? false,
                "private": false,
            ]) { _, value in value }
            let metadataURL = packageRoot.appendingPathComponent(Self.metadataName)
            try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: metadataURL, options: .atomic)

            // Every install gets a new package location, including reinstalling the same
            // version. A live host may still lazily load files from its previous location.
            let extensionDirectory = "package-\(UUID().uuidString.lowercased())"
            let destination = root.appendingPathComponent(extensionDirectory, isDirectory: true)
            let archives = root.appendingPathComponent(".archives", isDirectory: true)
            try FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
            let retainedArchive = archives.appendingPathComponent(extensionDirectory + ".vsix")
            try archive.write(to: retainedArchive, options: .atomic)
            var published = false
            defer { if !published { try? FileManager.default.removeItem(at: retainedArchive) } }
            // Publication is the commit point. Never check cancellation after this move.
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: packageRoot, to: destination)
            published = true
            Self.processPublications[Self.packageKey(destination.absoluteString)] = publicationOwner

            return ["manifest": manifest, "extensionLocation": destination.absoluteString, "isBuiltin": false, "metadata": metadata]
        }
    }

    private func withStagedVSIX<T>(_ archive: Data, in root: URL,
                                   operation: (URL, [String: Any]) throws -> T) throws -> T {
        let stage = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: stage) }
            let archiveURL = stage.appendingPathComponent("package.vsix")
            try archive.write(to: archiveURL, options: .atomic)
            try extract(archive: archiveURL, to: stage)
            let packageRoot = stage.appendingPathComponent("extension", isDirectory: true)
            return try operation(packageRoot, packageManifest(at: packageRoot))
        } catch {
            if error is CancellationError { throw error }
            if let typed = error as? NativeExtensionStoreError { throw typed }
            if let typed = error as? NativeMarketplaceError {
                throw NativeExtensionStoreError(code: typed.code, message: typed.message)
            }
            if let typed = error as? NativeExtensionCatalogError {
                throw NativeExtensionStoreError(code: typed.code, message: typed.message)
            }
            throw NativeExtensionStoreError(code: "InstallFailed", message: error.localizedDescription)
        }
    }

    /// Updates VS Code's installed-extension metadata without replacing the package directory.
    /// The location is validated against the one app-owned extension home before any write.
    func updateMetadata(extensionLocation: URL, metadata: [String: Any]) throws -> [String: Any] {
        Self.commitLock.lock()
        defer { Self.advanceCatalogGeneration(); Self.commitLock.unlock() }
        do {
            return try NativeExtensionCatalog.updateMetadata(
                in: extensionsRoot(),
                at: extensionLocation,
                metadata: metadata
            )
        } catch let error as NativeExtensionCatalogError {
            throw NativeExtensionStoreError(code: error.code, message: error.message)
        } catch {
            throw NativeExtensionStoreError(code: "MetadataUpdateFailed", message: error.localizedDescription)
        }
    }

    // Serialized commits advance this value even within one clock tick or after a clock
    // adjustment. Keep it exactly representable by the JavaScript catalog consumer.
    static func nextInstallationTimestamp(after previous: Any?, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> Int64 {
        let prior = previous as? Int64 ?? 0
        guard prior >= 0, prior < 9_007_199_254_740_990, now >= 0, now < 9_007_199_254_740_990 else {
            throw NativeExtensionStoreError(code: "InvalidMetadata", message: "extension installation timestamp is invalid")
        }
        return max(now, prior + 1)
    }

    private func galleryMetadata(id: String, version: String, targetPlatform: String) async throws -> GalleryMetadata {
        let body: [String: Any] = [
            "filters": [["criteria": [["filterType": 7, "value": id]]]],
            // IncludeVersions | IncludeFiles | IncludeVersionProperties | IncludeAssetUri.
            // IncludeLatestVersionOnly would hide an explicitly selected older version.
            "flags": 0x1 | 0x2 | 0x10 | 0x80,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await marketplace.request(
            url: try NativeMarketplaceClient.galleryServiceURL().appendingPathComponent("extensionquery"),
            method: "POST",
            headers: ["Accept": "application/json;api-version=7.2-preview.1", "Content-Type": "application/json", "X-Market-Client-Id": "CodiPad"],
            body: data
        )
        guard (200..<300).contains(response.status),
              let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let extensions = results.first?["extensions"] as? [[String: Any]],
              let extensionInfo = extensions.first,
              let publisher = extensionInfo["publisher"] as? [String: Any],
              let publisherName = publisher["publisherName"] as? String,
              let extensionName = extensionInfo["extensionName"] as? String,
              "\(publisherName).\(extensionName)".lowercased() == id.lowercased(),
              let publisherID = publisher["publisherId"] as? String,
              let extensionID = extensionInfo["extensionId"] as? String,
              let versions = extensionInfo["versions"] as? [[String: Any]],
              let selected = Self.matchingGalleryVersion(versions, version: version, targetPlatform: targetPlatform),
              let properties = selected["properties"] as? [[String: String]],
              let hash = properties.first(where: { $0["key"] == "Microsoft.VisualStudio.Services.VsixSha256" })?["value"],
              hash.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else {
            throw NativeExtensionStoreError(code: "GalleryMetadataUnavailable", message: "Marketplace did not return a matching extension version, target platform and SHA-256")
        }
        guard let extensionUUID = UUID(uuidString: extensionID),
              let publisherUUID = UUID(uuidString: publisherID) else {
            throw NativeExtensionStoreError(code: "GalleryMetadataUnavailable", message: "Marketplace returned invalid extension identity metadata")
        }
        return GalleryMetadata(
            extensionID: extensionUUID.uuidString.lowercased(),
            publisherID: publisherUUID.uuidString.lowercased(),
            publisherDisplayName: (publisher["displayName"] as? String) ?? publisherName,
            sha256: hash.lowercased()
        )
    }

    static func matchingGalleryVersion(_ versions: [[String: Any]], version: String, targetPlatform: String) -> [String: Any]? {
        versions.first { entry in
            let platform = entry["targetPlatform"] as? String
            // Match upstream getTargetPlatformForExtensionVersion: absent gallery metadata is
            // TargetPlatform.UNDEFINED, distinct from an explicit "universal" value.
            let normalizedPlatform = platform.flatMap { $0.isEmpty ? nil : $0 } ?? "undefined"
            return entry["version"] as? String == version && normalizedPlatform == targetPlatform
        }
    }

    private func extensionsRoot() throws -> URL {
        guard let support = applicationSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NativeExtensionStoreError(code: "HomeUnavailable", message: "Application Support is unavailable")
        }
        let appRoot = support.appendingPathComponent(Self.appFolderName, isDirectory: true)
        try createPrivateDirectory(appRoot)
        let root = appRoot.appendingPathComponent(Self.extensionsFolderName, isDirectory: true)
        try createPrivateDirectory(root)
        return try NativeExtensionCatalog.canonicalDirectory(root, code: "InvalidHome")
    }

    private func createPrivateDirectory(_ url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try rejectSymlink(url)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw NativeExtensionStoreError(code: "InvalidHome", message: "extension home component is not a directory")
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            try rejectSymlink(url)
        }
    }

    private func extract(archive: URL, to destination: URL) throws {
        var error = [CChar](repeating: 0, count: 512)
        let result = archive.path.withCString { archivePath in
            destination.path.withCString { destinationPath in
                codipad_vsix_extract_cancellable(archivePath, destinationPath, &error, error.count, { _ in
                    Task<Never, Never>.isCancelled ? 1 : 0
                }, nil)
            }
        }
        if result == -2 { throw CancellationError() }
        guard result == 0 else {
            let message = String(cString: error)
            throw NativeExtensionStoreError(code: message.contains("native Node addons") ? "NativeAddonUnsupported" : "InvalidVSIX", message: message)
        }
    }

    private func packageManifest(at root: URL) throws -> [String: Any] {
        try rejectSymlink(root)
        let manifestURL = root.appendingPathComponent("package.json")
        try rejectSymlink(manifestURL)
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any] else {
                throw NativeExtensionStoreError(code: "InvalidManifest", message: "extension package.json root is not an object")
            }
            return object
        } catch let error as NativeExtensionStoreError { throw error }
        catch { throw NativeExtensionStoreError(code: "InvalidManifest", message: "cannot read extension package.json: \(error.localizedDescription)") }
    }

    private func validate(manifest: [String: Any], id: String, version: String, targetPlatform: String?, packageRoot: URL) throws -> String {
        guard let publisher = manifest["publisher"] as? String,
              let name = manifest["name"] as? String,
              "\(publisher).\(name)".lowercased() == id.lowercased(),
              manifest["version"] as? String == version else {
            throw NativeExtensionStoreError(code: "ManifestIdentityMismatch", message: "VSIX manifest publisher, name, or version does not match the requested package")
        }
        let packagePlatform = (manifest["__metadata"] as? [String: Any])?["targetPlatform"] as? String
        let declaredPlatform = try VSIXTargetPlatform.read(at: packageRoot.deletingLastPathComponent().appendingPathComponent("extension.vsixmanifest"))
        if let packagePlatform, let declaredPlatform, packagePlatform != declaredPlatform {
            throw NativeExtensionStoreError(code: "UnsupportedTargetPlatform", message: "VSIX platform declarations disagree")
        }
        if let targetPlatform, let packagePlatform = declaredPlatform ?? packagePlatform,
           packagePlatform != "universal", packagePlatform != "undefined", packagePlatform != targetPlatform {
            throw NativeExtensionStoreError(code: "UnsupportedTargetPlatform", message: "VSIX targets \(packagePlatform), requested \(targetPlatform)")
        }
        if let rawMain = manifest["main"] {
            guard let main = rawMain as? String else {
                throw NativeExtensionStoreError(code: "InvalidManifest", message: "extension main is not a string")
            }
            do {
                try NativeExtensionCatalog.validateMainPath(main, at: packageRoot, label: id)
            } catch let error as NativeExtensionCatalogError {
                throw NativeExtensionStoreError(code: error.code, message: error.message)
            }
        }
        return declaredPlatform ?? packagePlatform ?? "undefined"
    }

    private func rejectSymlink(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw NativeExtensionStoreError(code: "SymlinkRejected", message: "symlinks are not accepted in an extension install: \(url.lastPathComponent)")
        }
    }

    private static func isSafeIdentifier(_ part: Substring) -> Bool {
        !part.isEmpty && part.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    private static func isSafeVersion(_ value: String) -> Bool {
        value.count <= 64 && value.range(of: "^[A-Za-z0-9.+_-]+$", options: .regularExpression) != nil
    }

    private static func validateIdentity(id: String, version: String, targetPlatform: String) throws {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy(isSafeIdentifier), isSafeVersion(version) else {
            throw NativeExtensionStoreError(code: "InvalidExtensionId", message: "extension id or version is invalid")
        }
        guard !targetPlatform.isEmpty, targetPlatform.count <= 64,
              targetPlatform.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw NativeExtensionStoreError(code: "UnsupportedTargetPlatform", message: "target platform is malformed")
        }
    }

    private static func validateArchiveSize(_ archive: Data) throws {
        guard !archive.isEmpty else { throw NativeExtensionStoreError(code: "InvalidVSIX", message: "VSIX package is empty") }
        guard archive.count <= NativeMarketplaceClient.maximumResponseBodyBytes else {
            throw NativeExtensionStoreError(code: "PackageTooLarge", message: "VSIX package exceeds the size limit")
        }
    }
}

private final class VSIXTargetPlatform: NSObject, XMLParserDelegate {
    private var target: String?
    private var conflicting = false

    static func read(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let parser = XMLParser(contentsOf: url) else {
            throw NativeExtensionStoreError(code: "InvalidVSIX", message: "cannot read VSIX manifest")
        }
        let reader = VSIXTargetPlatform()
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), !reader.conflicting else {
            throw NativeExtensionStoreError(code: "InvalidVSIX", message: "VSIX manifest XML is invalid or ambiguous")
        }
        if let target = reader.target,
           target.count > 64 || target.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil {
            throw NativeExtensionStoreError(code: "UnsupportedTargetPlatform", message: "VSIX target platform is malformed")
        }
        return reader.target
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName.split(separator: ":").last == "Identity", let value = attributeDict["TargetPlatform"] {
            if let target, target != value { conflicting = true }
            target = value
        }
    }
}

private struct GalleryMetadata {
    let extensionID: String
    let publisherID: String
    let publisherDisplayName: String
    let sha256: String
}

struct NativeExtensionStoreError: Error, CustomStringConvertible {
    let code: String
    let message: String
    var description: String { "\(code): \(message)" }

    init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

