import Darwin
import Foundation
import CodiPadWorkspace

struct NativeWorkspaceIdentity {
    let folderURI: String?
    let workspaceID: String
    var previousFolderURIs: [String] = []
    var workspaceURI: String? = nil
    var folderURIs: [String] = []
    var preparationToken: String? = nil
}

struct RestoredDocumentGrant {
    let selectedURL: URL
    let uri: String
    let isDirectory: Bool
    var previousURIs: [String] = []
}

struct DocumentRelocationAcknowledgement {
    let uri: String
    let previousURIs: [String]
}

/// Called synchronously on the bridge's I/O queue. This stores window identity, not userdata.
final class NativeWorkspaceState {
    private struct DirectoryIdentity: Codable, Hashable {
        let volume: String
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
    }
    private struct RootReference: Codable, Equatable {
        let identity: DirectoryIdentity
        let documentsComponents: [String]?
        let bookmark: Data?
    }
    private struct DocumentReference: Codable, Equatable {
        var reference: RootReference
        var canonicalURI: String
        let isDirectory: Bool
        var previousURIs: [String]? = nil
    }
    private struct EntryKey: Hashable {
        let identity: DirectoryIdentity
        let workspaceFileName: String?
    }
    private struct Entry: Codable, Equatable {
        let workspaceID: String
        let identity: DirectoryIdentity
        var documentsComponents: [String]?
        var bookmark: Data?
        var canonicalFolderURI: String?
        var previousFolderURIs: [String]?
        var relocationPendingScenes: [String]?
        var relocationPendingLegacy: Bool?
        var workspaceFileName: String?
        var roots: [RootReference]?
        var canonicalWorkspaceURI: String?
        var canonicalFolderURIs: [String]?

        var reference: RootReference {
            get { RootReference(identity: identity, documentsComponents: documentsComponents, bookmark: bookmark) }
            set {
                documentsComponents = newValue.documentsComponents
                bookmark = newValue.bookmark
            }
        }
    }
    private struct Record: Codable {
        let schemaVersion: Int
        var selectedID: String?
        var selectedByScene: [String: String]? = nil
        var documentsByScene: [String: [String: [DocumentReference]]]? = nil
        var legacyOwnerScene: String? = nil
        var entries: [Entry]
    }
    private struct GrantedDirectory {
        let url: URL
        let identity: DirectoryIdentity
        let access: WorkspaceNativeToolAccess
    }
    private struct GrantedWorkspace {
        let snapshot: WorkspaceNativeFileSnapshot
        let identity: DirectoryIdentity
        let roots: [GrantedDirectory]
    }
    private struct PreparedWorkspace {
        let token: String
        let workspace: GrantedWorkspace
    }
    private enum Failure: LocalizedError {
        case invalidRecord, invalidDirectory, identityMismatch, restoreUnavailable, storageUnavailable
        var errorDescription: String? {
            switch self {
            case .invalidRecord: return "Saved workspace metadata is invalid."
            case .invalidDirectory: return "Workspace identity requires an already granted native directory."
            case .identityMismatch: return "The workspace storage identity does not match the granted directory."
            case .restoreUnavailable: return "The saved workspace is unavailable. Select its folder again."
            case .storageUnavailable: return "Workspace selection could not be saved."
            }
        }
    }

    private static let maximumRecordBytes = 1024 * 1024
    private static let stateLock = NSRecursiveLock()
    private struct PendingReservation {
        let id: String
        var owners: Set<UUID>
    }
    private static var pendingByStorage: [String: [EntryKey: PendingReservation]] = [:]
    private let fileSystem: WorkspaceFileSystem
    private let storageURL: URL
    private let documentsURL: URL
    private var record: Record
    private let sceneID: String?
    private let canAdoptLegacy: Bool
    private let reservationOwner = UUID()
    private var ownedPendingKeys: Set<EntryKey> = []
    private var preparedWorkspaces: [String: PreparedWorkspace] = [:]
    private var verifiedDocumentURIs: [String: Set<String>] = [:]
    private var restoredDocumentCache: [String: (DocumentReference, RestoredDocumentGrant)] = [:]
    private var verifiedDocumentRelocations: [String: [String: DocumentReference]] = [:]

    init(fileSystem: WorkspaceFileSystem, storageURL: URL? = nil, documentsURL: URL? = nil, sceneID: String? = nil, canAdoptLegacy: Bool = true) throws {
        self.fileSystem = fileSystem
        self.sceneID = sceneID
        self.canAdoptLegacy = canAdoptLegacy
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodiPad/workspace-state.json")
        self.documentsURL = documentsURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard Self.localFileURL(self.storageURL), Self.localFileURL(self.documentsURL),
              sceneID.map(Self.validSceneID) ?? true else { throw Failure.invalidRecord }
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        record = try Self.readRecord(self.storageURL)
    }

    private static func readRecord(_ storageURL: URL) throws -> Record {
        do {
            let handle = try FileHandle(forReadingFrom: storageURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumRecordBytes + 1) ?? Data()
            guard !data.isEmpty, data.count <= Self.maximumRecordBytes else { throw Failure.invalidRecord }
            let loaded = try JSONDecoder().decode(Record.self, from: data)
            guard loaded.schemaVersion == 1,
                  Set(loaded.entries.map(\.workspaceID)).count == loaded.entries.count,
                  Set(loaded.entries.map { EntryKey(identity: $0.identity, workspaceFileName: $0.workspaceFileName) }).count == loaded.entries.count,
                  loaded.selectedID == nil || loaded.entries.contains(where: { $0.workspaceID == loaded.selectedID }),
                  (loaded.selectedByScene?.count ?? 0) <= 256,
                  (loaded.documentsByScene?.count ?? 0) <= 256,
                  loaded.documentsByScene?.allSatisfy({ scene, layouts in
                      Self.validSceneID(scene) && layouts.count <= 256 && layouts.allSatisfy { layout, documents in
                      Self.validSceneID(layout) && documents.count <= 256 &&
                      Set(documents.map(\.canonicalURI)).count == documents.count && documents.allSatisfy { document in
                          Self.validRootURI(document.canonicalURI) && !document.reference.identity.volume.isEmpty &&
                          (document.previousURIs?.count ?? 0) <= 32 &&
                          (document.previousURIs.map { Set($0).count == $0.count && !$0.contains(document.canonicalURI) && $0.allSatisfy(Self.validRootURI) } ?? true) &&
                          (document.reference.documentsComponents != nil) != (document.reference.bookmark != nil) &&
                          (document.reference.documentsComponents?.allSatisfy(Self.validComponent) ?? true) &&
                          document.reference.bookmark?.isEmpty != true
                      } }
                  }) ?? true,
                  loaded.legacyOwnerScene.map(Self.validSceneID) ?? true,
                  loaded.selectedByScene?.allSatisfy({ scene, id in Self.validSceneID(scene) && loaded.entries.contains(where: { $0.workspaceID == id }) }) ?? true,
                  loaded.entries.allSatisfy({ entry in
                      UUID(uuidString: entry.workspaceID) != nil && !entry.identity.volume.isEmpty
                      && (entry.documentsComponents != nil) != (entry.bookmark != nil)
                      && (entry.canonicalFolderURI.map(Self.validRootURI) ?? true)
                      && (entry.previousFolderURIs?.count ?? 0) <= 32
                      && (entry.previousFolderURIs?.allSatisfy(Self.validRootURI) ?? true)
                      && (entry.relocationPendingScenes?.count ?? 0) <= 256
                      && (entry.relocationPendingScenes.map { Set($0).count == $0.count && $0.allSatisfy(Self.validSceneID) } ?? true)
                      && (entry.previousFolderURIs != nil || ((entry.relocationPendingScenes?.isEmpty ?? true) && entry.relocationPendingLegacy != true))
                      && (entry.documentsComponents?.allSatisfy(Self.validComponent) ?? true)
                      && (entry.bookmark?.isEmpty != true)
                      && (entry.workspaceFileName.map(Self.validComponent) ?? true)
                      && (entry.workspaceFileName == nil) == (entry.roots == nil)
                      && (entry.workspaceFileName == nil) == (entry.canonicalWorkspaceURI == nil)
                      && (entry.workspaceFileName == nil) == (entry.canonicalFolderURIs == nil)
                      && (entry.canonicalWorkspaceURI.map(Self.validRootURI) ?? true)
                      && (entry.canonicalFolderURIs?.allSatisfy(Self.validRootURI) ?? true)
                      && (entry.roots?.count == entry.canonicalFolderURIs?.count)
                      && (entry.roots?.allSatisfy { root in
                          !root.identity.volume.isEmpty && (root.documentsComponents != nil) != (root.bookmark != nil)
                          && (root.documentsComponents?.allSatisfy(Self.validComponent) ?? true) && root.bookmark?.isEmpty != true
                      } ?? true)
                  }) else { throw Failure.invalidRecord }
            return loaded
        } catch let error as NSError where
            (error.domain == NSCocoaErrorDomain && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == ENOENT) {
            return Record(schemaVersion: 1, selectedID: nil, entries: [])
        } catch {
            throw Failure.invalidRecord
        }
    }

    func current(preserveCanonicalFolderURI: Bool = false) throws -> NativeWorkspaceIdentity? {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        record = try Self.readRecord(storageURL)
        // Adopt the legacy single-window selection only once, for the first scene
        // to restore it. Other scenes begin empty and cannot steal that selection.
        if let sceneID, canAdoptLegacy, record.legacyOwnerScene == nil, let legacy = record.selectedID {
            var migrated = record
            migrated.legacyOwnerScene = sceneID
            var selections = migrated.selectedByScene ?? [:]
            guard selections[sceneID] != nil || selections.count < 256 else { throw Failure.storageUnavailable }
            if selections[sceneID] == nil { selections[sceneID] = legacy }
            migrated.selectedByScene = selections
            try save(migrated)
        }
        guard let selected = selectedID(in: record),
              let index = record.entries.firstIndex(where: { $0.workspaceID == selected }) else { return nil }
        do {
            return try fileSystem.withGrantTransaction { _ in
                var entry = record.entries[index]
                let isWorkspace = entry.workspaceFileName != nil
                let uri = try restoreReference(&entry.reference, file: isWorkspace)
                let result: NativeWorkspaceIdentity
                if isWorkspace {
                    guard var references = entry.roots else { throw Failure.invalidRecord }
                    let roots = try references.indices.map { try restoreReference(&references[$0]) }
                    let workspace = try grantedWorkspace(uri: uri, folderURIs: roots)
                    guard workspace.snapshot.url.lastPathComponent == entry.workspaceFileName,
                          workspace.snapshot.url.absoluteString == entry.canonicalWorkspaceURI,
                          workspace.roots.map({ $0.url.absoluteString }) == entry.canonicalFolderURIs else { throw Failure.restoreUnavailable }
                    entry.roots = references
                    result = workspaceIdentity(workspace, id: entry.workspaceID)
                } else {
                    if preserveCanonicalFolderURI && entry.canonicalFolderURI != uri { throw Failure.restoreUnavailable }
                    _ = initializeRelocationTracking(&entry, in: record)
                    if entry.canonicalFolderURI != uri { try updateCanonicalRoot(&entry, to: uri) }
                    let pending = sceneID.map { entry.relocationPendingScenes?.contains($0) == true } ?? (entry.relocationPendingLegacy == true)
                    result = NativeWorkspaceIdentity(folderURI: uri, workspaceID: entry.workspaceID,
                                                     previousFolderURIs: pending ? entry.previousFolderURIs ?? [] : [])
                }
                if record.entries[index] != entry {
                    var updated = record
                    updated.entries[index] = entry
                    try save(updated)
                }
                return result
            }
        } catch {
            throw Failure.restoreUnavailable
        }
    }

    func identify(uri: String) throws -> NativeWorkspaceIdentity {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        record = try Self.readRecord(storageURL)
        let granted = try grantedDirectory(uri)
        let key = EntryKey(identity: granted.identity, workspaceFileName: nil)
        let id: String
        if let existing = record.entries.first(where: { $0.identity == granted.identity && $0.workspaceFileName == nil })?.workspaceID {
            id = existing
        } else {
            id = try reserveIdentity(for: key)
        }
        return NativeWorkspaceIdentity(folderURI: granted.url.absoluteString, workspaceID: id)
    }

    func savedFolderURI() throws -> String {
        Self.stateLock.lock(); defer { Self.stateLock.unlock() }
        record = try Self.readRecord(storageURL)
        guard let selected = selectedID(in: record),
              let entry = record.entries.first(where: { $0.workspaceID == selected && $0.workspaceFileName == nil }),
              let uri = entry.canonicalFolderURI else { throw Failure.restoreUnavailable }
        return uri
    }

    /// Replace the confirmed set of selected document sources for this scene. The caller must
    /// retain failed restorations until it has positively confirmed that they were closed.
    func rememberOpenDocumentGrants(_ selections: [RestoredDocumentGrant], layout: String) throws {
        Self.stateLock.lock(); defer { Self.stateLock.unlock() }
        guard Self.validSceneID(layout), selections.count <= 256 else { throw Failure.invalidRecord }
        record = try Self.readRecord(storageURL)
        let key = sceneID ?? "__single_scene__"
        let previous = record.documentsByScene?[key]?[layout] ?? []
        var documents: [DocumentReference] = []
        for selection in selections {
            guard Self.localFileURL(selection.selectedURL) else { throw Failure.invalidDirectory }
            let (uri, identity) = try documentIdentity(selection.selectedURL, uri: selection.uri, isDirectory: selection.isDirectory)
            guard selection.uri == uri else { throw Failure.identityMismatch }
            if let existing = previous.first(where: { $0.canonicalURI == uri && $0.isDirectory == selection.isDirectory && $0.reference.identity == identity }),
               let old = try? documentSelection(existing.reference, isDirectory: existing.isDirectory),
               old.0.standardizedFileURL == selection.selectedURL.standardizedFileURL {
                documents.append(existing)
            } else {
                guard !previous.contains(where: { $0.canonicalURI == uri && !($0.previousURIs?.isEmpty ?? true) }) else { throw Failure.identityMismatch }
                let reference = try savedDocumentReference(selection.selectedURL, identity: identity)
                documents.append(DocumentReference(reference: reference, canonicalURI: uri, isDirectory: selection.isDirectory))
            }
        }
        guard Set(documents.map(\.canonicalURI)).count == documents.count else { throw Failure.invalidRecord }
        let selected = Set(documents.map(\.canonicalURI))
        let verified = verifiedDocumentURIs[layout] ?? []
        documents.append(contentsOf: previous.filter { (!verified.contains($0.canonicalURI) || !($0.previousURIs?.isEmpty ?? true)) && !selected.contains($0.canonicalURI) })
        guard documents.count <= 256 else { throw Failure.storageUnavailable }
        documents.sort { $0.canonicalURI < $1.canonicalURI }
        if documents == previous.sorted(by: { $0.canonicalURI < $1.canonicalURI }) {
            verifiedDocumentURIs[layout, default: []].formUnion(selected)
            return
        }
        var updated = record
        var scenes = updated.documentsByScene ?? [:]
        guard scenes[key] != nil || scenes.count < 256 || documents.isEmpty else { throw Failure.storageUnavailable }
        var layouts = scenes[key] ?? [:]
        guard layouts[layout] != nil || layouts.count < 256 || documents.isEmpty else { throw Failure.storageUnavailable }
        if documents.isEmpty { layouts.removeValue(forKey: layout) } else { layouts[layout] = documents }
        if layouts.isEmpty { scenes.removeValue(forKey: key) } else { scenes[key] = layouts }
        updated.documentsByScene = scenes.isEmpty ? nil : scenes
        try save(updated)
        verifiedDocumentURIs[layout, default: []].formUnion(selected)
    }

    /// Each saved selection is restored in its own grant transaction. A failed selection is
    /// retained for a later retry and cannot revoke a successfully restored sibling.
    func restoreDocumentGrants(layout: String) throws -> [RestoredDocumentGrant] {
        Self.stateLock.lock(); defer { Self.stateLock.unlock() }
        guard Self.validSceneID(layout) else { throw Failure.invalidRecord }
        record = try Self.readRecord(storageURL)
        let key = sceneID ?? "__single_scene__"
        let documents = record.documentsByScene?[key]?[layout] ?? []
        var verifiedMappings: [String: DocumentReference] = [:]
        let restored: [RestoredDocumentGrant] = documents.compactMap { document in
            do {
                if let cached = restoredDocumentCache[document.canonicalURI],
                   cached.0.isDirectory == document.isDirectory, cached.0.reference.identity == document.reference.identity,
                   let selection = try? documentSelection(document.reference, isDirectory: document.isDirectory),
                   !selection.2, selection.0.standardizedFileURL == cached.1.selectedURL.standardizedFileURL {
                    let (uri, identity) = try documentIdentity(cached.1.selectedURL, uri: document.canonicalURI, isDirectory: document.isDirectory)
                    guard uri == document.canonicalURI, identity == document.reference.identity else { throw Failure.identityMismatch }
                    verifiedMappings[uri] = document
                    let result = RestoredDocumentGrant(selectedURL: cached.1.selectedURL, uri: uri, isDirectory: document.isDirectory, previousURIs: document.previousURIs ?? [])
                    restoredDocumentCache[uri] = (document, result)
                    return result
                }
                let result = try fileSystem.withGrantTransaction { fs in
                    let (selected, scoped, stale) = try documentSelection(document.reference, isDirectory: document.isDirectory)
                    let uri = document.isDirectory ? try fs.grantDirectory(selected, securityScoped: scoped) : try fs.grantFile(selected, securityScoped: scoped)
                    let (canonical, identity) = try documentIdentity(selected, uri: uri, isDirectory: document.isDirectory)
                    guard canonical == uri, identity == document.reference.identity else { throw Failure.identityMismatch }
                    var refreshed = document
                    if uri != document.canonicalURI {
                        guard document.reference.documentsComponents != nil,
                              URL(string: document.canonicalURI)?.lastPathComponent == selected.lastPathComponent else { throw Failure.identityMismatch }
                        var history = document.previousURIs ?? []
                        history.removeAll { $0 == uri || $0 == document.canonicalURI }
                        history.append(document.canonicalURI)
                        guard history.count <= 32 else { throw Failure.storageUnavailable }
                        refreshed.canonicalURI = uri
                        refreshed.previousURIs = history
                    }
                    if stale { refreshed.reference = try savedDocumentReference(selected, identity: identity) }
                    if refreshed != document {
                        var updated = record
                        guard var entries = updated.documentsByScene?[key]?[layout],
                              let index = entries.firstIndex(of: document),
                              !entries.enumerated().contains(where: { $0.offset != index && $0.element.canonicalURI == uri }) else { throw Failure.identityMismatch }
                        entries[index] = refreshed
                        updated.documentsByScene?[key]?[layout] = entries
                        try save(updated)
                    }
                    verifiedMappings[uri] = refreshed
                    return RestoredDocumentGrant(selectedURL: selected, uri: uri, isDirectory: document.isDirectory, previousURIs: refreshed.previousURIs ?? [])
                }
                restoredDocumentCache[result.uri] = (verifiedMappings[result.uri]!, result)
                return result
            } catch {
                restoredDocumentCache.removeValue(forKey: document.canonicalURI)
                return nil
            }
        }
        verifiedDocumentURIs[layout] = Set(restored.map(\.uri))
        verifiedDocumentRelocations[layout] = verifiedMappings
        return restored
    }

    /// Clear only mappings from the latest verified restore after the renderer has durably
    /// migrated every listed editor and backup URI. The complete batch is saved atomically.
    func completeDocumentRelocations(layout: String, acknowledgements: [DocumentRelocationAcknowledgement]) throws {
        Self.stateLock.lock(); defer { Self.stateLock.unlock() }
        guard Self.validSceneID(layout), acknowledgements.count <= 256,
              Set(acknowledgements.map(\.uri)).count == acknowledgements.count else { throw Failure.invalidRecord }
        record = try Self.readRecord(storageURL)
        let key = sceneID ?? "__single_scene__"
        var updated = record
        guard var documents = updated.documentsByScene?[key]?[layout] else {
            if acknowledgements.isEmpty { return }
            throw Failure.identityMismatch
        }
        for acknowledgement in acknowledgements {
            guard !acknowledgement.previousURIs.isEmpty, acknowledgement.previousURIs.count <= 32,
                  let verified = verifiedDocumentRelocations[layout]?[acknowledgement.uri],
                  let index = documents.firstIndex(of: verified),
                  verified.canonicalURI == acknowledgement.uri,
                  verified.previousURIs == acknowledgement.previousURIs,
                  let cached = restoredDocumentCache[acknowledgement.uri],
                  cached.0.isDirectory == verified.isDirectory, cached.0.reference.identity == verified.reference.identity else { throw Failure.identityMismatch }
            let (_, identity) = try documentIdentity(cached.1.selectedURL, uri: verified.canonicalURI, isDirectory: verified.isDirectory)
            guard identity == verified.reference.identity else { throw Failure.identityMismatch }
            documents[index].previousURIs = nil
        }
        guard !acknowledgements.isEmpty else { return }
        updated.documentsByScene?[key]?[layout] = documents
        try save(updated)
        for acknowledgement in acknowledgements {
            verifiedDocumentRelocations[layout]?.removeValue(forKey: acknowledgement.uri)
            restoredDocumentCache.removeValue(forKey: acknowledgement.uri)
        }
    }

    private func documentSelection(_ reference: RootReference, isDirectory: Bool) throws -> (URL, Bool, Bool) {
        if let components = reference.documentsComponents {
            let documents = try Self.canonicalDirectory(documentsURL)
            let selected = components.reduce(documents) { $0.appendingPathComponent($1) }
            return (URL(fileURLWithPath: selected.path, isDirectory: isDirectory), false, false)
        }
        guard let bookmark = reference.bookmark else { throw Failure.invalidRecord }
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting, .withoutImplicitStartAccessing]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing]
        #endif
        let selected = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        // A file bookmark can become stale after an atomic save. The saved canonical path and
        // parent identity are checked after acquiring its scope, before retaining the grant.
        guard Self.localFileURL(selected) else { throw Failure.restoreUnavailable }
        return (selected, true, stale)
    }

    private func documentIdentity(_ selected: URL, uri: String, isDirectory: Bool) throws -> (String, DirectoryIdentity) {
        let anchor = try fileSystem.selectedGrantMetadata(canonicalURI: uri, selectedURL: selected, isDirectory: isDirectory)
        return (uri, Self.identity(anchor.anchorURL, metadata: anchor.metadata))
    }

    private func savedDocumentReference(_ selected: URL, identity: DirectoryIdentity) throws -> RootReference {
        let original = selected.standardizedFileURL
        let originalDocuments = documentsURL.standardizedFileURL
        let canonicalDocuments = try? Self.canonicalDirectory(documentsURL)
        if let components = Self.relativeComponents(original, under: originalDocuments) ??
            canonicalDocuments.flatMap({ Self.relativeComponents(original, under: $0) }) {
            return RootReference(identity: identity, documentsComponents: components, bookmark: nil)
        }
        return try savedReference(selected, identity: identity)
    }

    func reauthorizeFolder(uri: String) throws {
        Self.stateLock.lock(); defer { Self.stateLock.unlock() }
        record = try Self.readRecord(storageURL)
        guard let selected = selectedID(in: record),
              let entry = record.entries.first(where: { $0.workspaceID == selected && $0.workspaceFileName == nil }),
              entry.canonicalFolderURI == uri else { throw Failure.identityMismatch }
        let granted = try grantedDirectory(uri)
        guard granted.identity == entry.identity else { throw Failure.identityMismatch }
        try commit(uri: uri, workspaceID: selected)
    }

    func commit(uri: String, workspaceID: String) throws {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        record = try Self.readRecord(storageURL)
        let granted = try grantedDirectory(uri)
        let identified = try identify(uri: uri)
        guard identified.workspaceID == workspaceID else { throw Failure.identityMismatch }
        let reference = try savedReference(granted.url, identity: granted.identity)
        var entry = Entry(workspaceID: workspaceID, identity: granted.identity,
                          documentsComponents: reference.documentsComponents, bookmark: reference.bookmark)
        if let previous = record.entries.first(where: { $0.workspaceID == workspaceID && $0.identity == granted.identity && $0.workspaceFileName == nil }) {
            entry.canonicalFolderURI = previous.canonicalFolderURI
            entry.previousFolderURIs = previous.previousFolderURIs
            entry.relocationPendingScenes = previous.relocationPendingScenes
            entry.relocationPendingLegacy = previous.relocationPendingLegacy
        }
        try updateCanonicalRoot(&entry, to: granted.url.absoluteString)
        var updated = record
        updated.entries.removeAll { $0.workspaceID == workspaceID }
        updated.entries.append(entry)
        updated.entries.sort { $0.workspaceID < $1.workspaceID }
        try setSelectedID(workspaceID, in: &updated)
        try save(updated)
        releaseIdentity(for: EntryKey(identity: granted.identity, workspaceFileName: nil))
    }

    /// The renderer supplies upstream-resolved roots, never authority. The bridge acquires any
    /// missing grants through the ordinary picker before calling this synchronous preparation.
    func identifyWorkspace(uri: String, folderURIs: [String], contents: Data) throws -> NativeWorkspaceIdentity {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        record = try Self.readRecord(storageURL)
        let workspace = try grantedWorkspace(uri: uri, folderURIs: folderURIs)
        guard workspace.snapshot.data == contents else { throw Failure.identityMismatch }
        let key = EntryKey(identity: workspace.identity, workspaceFileName: workspace.snapshot.url.lastPathComponent)
        let previous = record.entries.first { $0.identity == key.identity && $0.workspaceFileName == key.workspaceFileName }
        // shortcut: file-workspace relocation fails closed until config, layouts and backups can
        // be rebased together; retain the saved record so ordinary reauthorization is retryable.
        if let previous {
            guard previous.canonicalWorkspaceURI == workspace.snapshot.url.absoluteString else { throw Failure.restoreUnavailable }
            for root in workspace.roots {
                if let index = previous.roots!.firstIndex(where: { $0.identity == root.identity }),
                   previous.canonicalFolderURIs![index] != root.url.absoluteString { throw Failure.restoreUnavailable }
            }
        }
        let existingID = previous?.workspaceID ?? Self.pendingByStorage[storageURL.standardizedFileURL.path]?[key]?.id
        if preparedWorkspaces.count >= 32 && (existingID == nil || preparedWorkspaces[existingID!] == nil) {
            throw Failure.storageUnavailable
        }
        let id: String
        if let previous { id = previous.workspaceID } else { id = try reserveIdentity(for: key) }
        let token = UUID().uuidString.lowercased()
        preparedWorkspaces[id] = PreparedWorkspace(token: token, workspace: workspace)
        return workspaceIdentity(workspace, id: id, token: token)
    }

    func commitWorkspace(uri: String, folderURIs: [String], workspaceID: String, preparationToken: String) throws {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        record = try Self.readRecord(storageURL)
        guard let pending = preparedWorkspaces[workspaceID], pending.token == preparationToken else { throw Failure.identityMismatch }
        let workspace = try grantedWorkspace(uri: uri, folderURIs: folderURIs)
        let prepared = pending.workspace
        guard workspace.identity == prepared.identity,
              workspace.snapshot.url == prepared.snapshot.url,
              workspace.snapshot.data == prepared.snapshot.data,
              workspace.roots.map({ $0.identity }) == prepared.roots.map({ $0.identity }),
              workspace.roots.map({ $0.url }) == prepared.roots.map({ $0.url }) else { throw Failure.identityMismatch }
        let reference = try savedReference(workspace.snapshot.url, identity: workspace.identity)
        var entry = Entry(workspaceID: workspaceID, identity: workspace.identity,
                          documentsComponents: reference.documentsComponents, bookmark: reference.bookmark)
        entry.workspaceFileName = workspace.snapshot.url.lastPathComponent
        entry.roots = try workspace.roots.map { try savedReference($0.url, identity: $0.identity) }
        entry.canonicalWorkspaceURI = workspace.snapshot.url.absoluteString
        entry.canonicalFolderURIs = workspace.roots.map { $0.url.absoluteString }
        var updated = record
        updated.entries.removeAll { $0.workspaceID == workspaceID }
        updated.entries.append(entry)
        updated.entries.sort { $0.workspaceID < $1.workspaceID }
        try setSelectedID(workspaceID, in: &updated)
        try save(updated)
        releaseIdentity(for: EntryKey(identity: workspace.identity, workspaceFileName: workspace.snapshot.url.lastPathComponent))
        preparedWorkspaces.removeValue(forKey: workspaceID)
    }

    func cancelWorkspace(workspaceID: String, preparationToken: String) throws {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        guard let pending = preparedWorkspaces[workspaceID], pending.token == preparationToken else { throw Failure.identityMismatch }
        preparedWorkspaces.removeValue(forKey: workspaceID)
        releaseIdentity(for: EntryKey(identity: pending.workspace.identity, workspaceFileName: pending.workspace.snapshot.url.lastPathComponent))
    }

    private func workspaceIdentity(_ workspace: GrantedWorkspace, id: String, token: String? = nil) -> NativeWorkspaceIdentity {
        NativeWorkspaceIdentity(folderURI: nil, workspaceID: id, workspaceURI: workspace.snapshot.url.absoluteString,
                                folderURIs: workspace.roots.map { $0.url.absoluteString }, preparationToken: token)
    }

    private func grantedWorkspace(uri: String, folderURIs: [String]) throws -> GrantedWorkspace {
        guard Self.validRootURI(uri), let url = URL(string: uri),
              url.lastPathComponent.lowercased().hasSuffix(".code-workspace"),
              folderURIs.allSatisfy(Self.validRootURI) else { throw Failure.invalidDirectory }
        let snapshot = try fileSystem.readFileSnapshot(uri, maximumBytes: Self.maximumRecordBytes)
        let parent = snapshot.url.deletingLastPathComponent()
        let roots = try folderURIs.map { try grantedDirectory($0) }
        guard Set(roots.map { $0.url.path }).count == roots.count else { throw Failure.invalidDirectory }
        return GrantedWorkspace(snapshot: snapshot, identity: Self.identity(parent, metadata: snapshot.parentMetadata), roots: roots)
    }

    private func savedReference(_ url: URL, identity: DirectoryIdentity) throws -> RootReference {
        let components = (try? Self.canonicalDirectory(documentsURL)).flatMap { Self.relativeComponents(url, under: $0) }
        let bookmark: Data?
        if components == nil {
            #if os(macOS)
            let options: URL.BookmarkCreationOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkCreationOptions = [.minimalBookmark]
            #endif
            bookmark = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        } else { bookmark = nil }
        return RootReference(identity: identity, documentsComponents: components, bookmark: bookmark)
    }

    private func restoreReference(_ reference: inout RootReference, file: Bool = false) throws -> String {
        let candidate: URL
        var stale = false
        let scoped: Bool
        if let components = reference.documentsComponents {
            let documents = try Self.canonicalDirectory(documentsURL)
            let selected = components.reduce(documents) { $0.appendingPathComponent($1) }
            guard let path = realpath(selected.path, nil) else { throw Failure.restoreUnavailable }
            defer { free(path) }
            candidate = URL(fileURLWithPath: String(cString: path), isDirectory: !file)
            guard Self.relativeComponents(candidate, under: documents) != nil else { throw Failure.restoreUnavailable }
            scoped = false
        } else {
            #if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting, .withoutImplicitStartAccessing]
            #else
            let options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing]
            #endif
            guard let bookmark = reference.bookmark else { throw Failure.invalidRecord }
            candidate = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
            scoped = true
        }
        let uri: String
        if file {
            let snapshot: WorkspaceNativeFileSnapshot
            if let existing = try? fileSystem.readFileSnapshot(candidate.absoluteString, maximumBytes: Self.maximumRecordBytes) {
                snapshot = existing
            } else {
                let granted = try fileSystem.grantFile(candidate, securityScoped: scoped)
                snapshot = try fileSystem.readFileSnapshot(granted, maximumBytes: Self.maximumRecordBytes)
            }
            guard Self.identity(snapshot.url.deletingLastPathComponent(), metadata: snapshot.parentMetadata) == reference.identity else {
                throw Failure.identityMismatch
            }
            uri = snapshot.url.absoluteString
        } else {
            let directory: GrantedDirectory
            if let existing = try? grantedDirectory(candidate.absoluteString) {
                directory = existing
            } else {
                let granted = try fileSystem.grantDirectory(candidate, securityScoped: scoped)
                directory = try grantedDirectory(granted)
            }
            guard directory.identity == reference.identity else { throw Failure.identityMismatch }
            uri = directory.url.absoluteString
        }
        if stale { reference = try savedReference(candidate, identity: reference.identity) }
        return uri
    }

    /// Older records did not record which scene still needs each relocation.
    @discardableResult
    private func initializeRelocationTracking(_ entry: inout Entry, in record: Record) -> Bool {
        guard entry.previousFolderURIs?.isEmpty == false,
              entry.relocationPendingScenes == nil, entry.relocationPendingLegacy == nil else { return false }
        entry.relocationPendingScenes = (record.selectedByScene ?? [:]).compactMap { $0.value == entry.workspaceID ? $0.key : nil }.sorted()
        entry.relocationPendingLegacy = record.legacyOwnerScene == nil && record.selectedID == entry.workspaceID
        return true
    }

    private func clearAcknowledgedRelocation(_ entry: inout Entry) {
        if entry.relocationPendingScenes?.isEmpty != false && entry.relocationPendingLegacy != true {
            entry.previousFolderURIs = nil
            entry.relocationPendingScenes = nil
            entry.relocationPendingLegacy = nil
        }
    }

    private func updateCanonicalRoot(_ entry: inout Entry, to uri: String) throws {
        _ = initializeRelocationTracking(&entry, in: record)
        var previous = entry.previousFolderURIs ?? []
        let changed = entry.canonicalFolderURI != nil && entry.canonicalFolderURI != uri
        if let old = entry.canonicalFolderURI, old != uri, !previous.contains(old) { previous.append(old) }
        previous.removeAll { $0 == uri }
        guard previous.count <= 32 else { throw Failure.storageUnavailable }
        // A legacy record establishes a baseline only; never infer its former root from tabs.
        entry.canonicalFolderURI = uri
        entry.previousFolderURIs = previous.isEmpty ? nil : previous
        if changed && !previous.isEmpty {
            var pending = Set(entry.relocationPendingScenes ?? [])
            for (scene, id) in record.selectedByScene ?? [:] where id == entry.workspaceID { pending.insert(scene) }
            if let sceneID { pending.insert(sceneID) }
            guard pending.count <= 256 else { throw Failure.storageUnavailable }
            entry.relocationPendingScenes = pending.sorted()
            entry.relocationPendingLegacy = entry.relocationPendingLegacy == true || sceneID == nil ||
                (record.legacyOwnerScene == nil && record.selectedID == entry.workspaceID)
        } else if previous.isEmpty {
            entry.relocationPendingScenes = nil
            entry.relocationPendingLegacy = nil
        }
    }

    func completeRelocation(uri: String, workspaceID: String, previousFolderURIs: [String]) throws {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        record = try Self.readRecord(storageURL)
        let granted = try grantedDirectory(uri)
        guard previousFolderURIs.allSatisfy(Self.validRootURI), selectedID(in: record) == workspaceID,
              let index = record.entries.firstIndex(where: { $0.workspaceID == workspaceID }),
              record.entries[index].identity == granted.identity,
              record.entries[index].canonicalFolderURI == granted.url.absoluteString,
              record.entries[index].previousFolderURIs?.map({ URL(string: $0)!.path }) == previousFolderURIs.map({ URL(string: $0)!.path }) else { throw Failure.identityMismatch }
        var updated = record
        _ = initializeRelocationTracking(&updated.entries[index], in: record)
        if let sceneID {
            updated.entries[index].relocationPendingScenes?.removeAll { $0 == sceneID }
        } else {
            updated.entries[index].relocationPendingLegacy = false
        }
        clearAcknowledgedRelocation(&updated.entries[index])
        try save(updated)
    }

    /// Discard only the selection owned by a permanently discarded scene.
    func discardSceneSelection() throws {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        record = try Self.readRecord(storageURL)
        guard let sceneID else { throw Failure.invalidRecord }
        var updated = record
        var changed = false
        if var documents = updated.documentsByScene, documents.removeValue(forKey: sceneID) != nil {
            updated.documentsByScene = documents.isEmpty ? nil : documents
            verifiedDocumentURIs.removeAll()
            verifiedDocumentRelocations.removeAll()
            restoredDocumentCache.removeAll()
            changed = true
        }
        if var selections = updated.selectedByScene, selections.removeValue(forKey: sceneID) != nil {
            updated.selectedByScene = selections.isEmpty ? nil : selections
            changed = true
        }
        for index in updated.entries.indices {
            let tracked = initializeRelocationTracking(&updated.entries[index], in: record)
            if tracked { changed = true }
            if updated.entries[index].relocationPendingScenes?.contains(sceneID) == true {
                updated.entries[index].relocationPendingScenes?.removeAll { $0 == sceneID }
                clearAcknowledgedRelocation(&updated.entries[index])
                changed = true
            }
        }
        guard changed else { return }
        try save(updated)
    }

    private func reserveIdentity(for key: EntryKey) throws -> String {
        let storage = storageURL.standardizedFileURL.path
        var reservations = Self.pendingByStorage[storage] ?? [:]
        if var existing = reservations[key] {
            existing.owners.insert(reservationOwner)
            reservations[key] = existing
            Self.pendingByStorage[storage] = reservations
            ownedPendingKeys.insert(key)
            return existing.id
        }
        guard reservations.count < 4096 else { throw Failure.storageUnavailable }
        let id = UUID().uuidString.lowercased()
        reservations[key] = PendingReservation(id: id, owners: [reservationOwner])
        Self.pendingByStorage[storage] = reservations
        ownedPendingKeys.insert(key)
        return id
    }

    private func releaseIdentity(for key: EntryKey) {
        guard ownedPendingKeys.remove(key) != nil else { return }
        let storage = storageURL.standardizedFileURL.path
        guard var reservations = Self.pendingByStorage[storage], var existing = reservations[key] else { return }
        existing.owners.remove(reservationOwner)
        if existing.owners.isEmpty { reservations.removeValue(forKey: key) } else { reservations[key] = existing }
        Self.pendingByStorage[storage] = reservations.isEmpty ? nil : reservations
    }

    deinit {
        Self.stateLock.lock()
        defer { Self.stateLock.unlock() }
        for key in Array(ownedPendingKeys) { releaseIdentity(for: key) }
    }

    private static func validSceneID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0")
    }

    private func selectedID(in record: Record) -> String? {
        guard let sceneID else { return record.selectedID }
        return record.selectedByScene?[sceneID]
    }

    private func setSelectedID(_ id: String, in record: inout Record) throws {
        let previous = selectedID(in: record)
        if previous != id, let index = record.entries.firstIndex(where: { $0.workspaceID == id }), record.entries[index].previousFolderURIs?.isEmpty == false {
            let snapshot = record
            _ = initializeRelocationTracking(&record.entries[index], in: snapshot)
            if let sceneID {
                var pending = Set(record.entries[index].relocationPendingScenes ?? [])
                pending.insert(sceneID)
                guard pending.count <= 256 else { throw Failure.storageUnavailable }
                record.entries[index].relocationPendingScenes = pending.sorted()
            } else {
                record.entries[index].relocationPendingLegacy = true
            }
        }
        guard let sceneID else { record.selectedID = id; return }
        var selections = record.selectedByScene ?? [:]
        guard selections[sceneID] != nil || selections.count < 256 else { throw Failure.storageUnavailable }
        selections[sceneID] = id
        record.selectedByScene = selections
    }

    private static func validRootURI(_ text: String) -> Bool {
        guard text.utf8.count <= 32768, let url = URL(string: text), localFileURL(url),
              url.query == nil, url.fragment == nil else { return false }
        return true
    }

    private func save(_ updated: Record) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(updated)
        guard data.count <= Self.maximumRecordBytes else { throw Failure.storageUnavailable }
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storageURL, options: .atomic)
        } catch { throw Failure.storageUnavailable }
        record = updated
    }

    private func grantedDirectory(_ uri: String) throws -> GrantedDirectory {
        do {
            let access = try fileSystem.authorizedDirectoryAccess(rootURI: uri)
            var metadata = stat()
            // This callback namespace is local to the held grant; it creates no kernel alias.
            guard access.stat(path: WorkspacePaths.guestRoot, into: &metadata) == 0,
                  (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw Failure.invalidDirectory }
            let url = URL(fileURLWithPath: access.rootPath, isDirectory: true)
            return GrantedDirectory(url: url, identity: Self.identity(url, metadata: metadata), access: access)
        } catch { throw Failure.invalidDirectory }
    }

    private static func identity(_ url: URL, metadata: stat) -> DirectoryIdentity {
        let volume = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) ?? "device:\(metadata.st_dev)"
        return DirectoryIdentity(volume: volume, inode: UInt64(metadata.st_ino),
                                 birthSeconds: Int64(metadata.st_birthtimespec.tv_sec),
                                 birthNanoseconds: Int64(metadata.st_birthtimespec.tv_nsec))
    }
    private static func canonicalDirectory(_ url: URL) throws -> URL {
        guard localFileURL(url), let pointer = realpath(url.path, nil) else { throw Failure.invalidDirectory }
        defer { free(pointer) }
        let result = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        var metadata = stat()
        guard lstat(result.path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw Failure.invalidDirectory }
        return result
    }
    private static func relativeComponents(_ url: URL, under root: URL) -> [String]? {
        if url.path == root.path { return [] }
        guard url.path.hasPrefix(root.path + "/") else { return nil }
        return String(url.path.dropFirst(root.path.count + 1)).split(separator: "/").map(String.init)
    }
    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }
    private static func localFileURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost")
            && !url.path.isEmpty && !url.path.contains("\0")
    }
}
