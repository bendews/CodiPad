import CryptoKit
import Foundation
import WebKit

/// Copies the existing VS Code databases between this app's own browsing origins before boot.
/// The original databases and a private resumable snapshot remain untouched after verification.
@MainActor
final class NativeStorageMigration {
    enum Failure: Error { case invalidState, unexpectedResult, oversizedChunk, targetNotEmpty, verification, navigation, timeout }
    private struct PortState: Codable { let version: Int; let port: UInt16 }
    private struct Complete: Codable { let version: Int; let origin: String; let digest: String }
    private struct Snapshot: Codable {
        let version: Int; let origin: String; let chunks: Int; let digest: String; let targetConfirmedEmpty: Bool
    }
    private let webView: WKWebView
    private let legacyPage: URL
    private let targetPage: URL
    private let fileRoot: URL
    private let origin: String
    private let stateDirectory: URL
    private let directory: URL
    private var expectedPage: URL?
    private var pendingNavigation: WKNavigation?
    private var navigationReply: CheckedContinuation<Void, Error>?
    private var navigationGeneration: UUID?
    private(set) var isActive = false
    private(set) var stage = "idle"

    init(webView: WKWebView, fileRoot: URL, targetPage: URL, stateDirectory: URL? = nil) throws {
        self.webView = webView
        self.fileRoot = fileRoot
        self.legacyPage = fileRoot.appendingPathComponent("storage-migration.html")
        self.targetPage = targetPage
        self.origin = try Self.origin(of: targetPage)
        self.stateDirectory = try Self.privateDirectory(stateDirectory)
        self.directory = self.stateDirectory.appendingPathComponent("snapshot", isDirectory: true)
    }

    private static func privateDirectory(_ specified: URL? = nil) throws -> URL {
        if let specified {
            guard specified.isFileURL else { throw Failure.invalidState }
            try FileManager.default.createDirectory(at: specified, withIntermediateDirectories: true)
            return specified
        }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("CodiPad/WorkbenchOrigin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func origin(of url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "http", components.host == "127.0.0.1",
              let port = components.port, port > 0, port <= Int(UInt16.max),
              components.user == nil, components.password == nil else { throw Failure.invalidState }
        return "http://127.0.0.1:\(port)"
    }

    static func preferredPort(stateDirectory: URL? = nil) throws -> UInt16? {
        let file = try privateDirectory(stateDirectory).appendingPathComponent("port.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let state = try JSONDecoder().decode(PortState.self, from: read(file))
        guard state.version == 1, state.port > 0 else { throw Failure.invalidState }
        return state.port
    }

    static func rememberPort(for entry: URL, stateDirectory: URL? = nil) throws {
        _ = try origin(of: entry)
        guard let value = URLComponents(url: entry, resolvingAgainstBaseURL: false)?.port,
              let port = UInt16(exactly: value) else { throw Failure.invalidState }
        if let previous = try preferredPort(stateDirectory: stateDirectory) {
            guard previous == port else { throw Failure.invalidState }
            return
        }
        let file = try privateDirectory(stateDirectory).appendingPathComponent("port.json")
        try JSONEncoder().encode(PortState(version: 1, port: port)).write(to: file, options: .atomic)
    }

    static func isComplete(for entry: URL, stateDirectory: URL? = nil) throws -> Bool {
        let file = try privateDirectory(stateDirectory).appendingPathComponent("complete.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let value = try JSONDecoder().decode(Complete.self, from: read(file))
        guard value.version == 1, value.origin == (try origin(of: entry)),
              value.digest.utf8.count == 64,
              value.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalidState }
        return true
    }

    func allowsNavigation(to url: URL) -> Bool { isActive && url == expectedPage }

    func didFinish(_ navigation: WKNavigation?, url: URL?) -> Bool {
        guard let reply = navigationReply, navigation === pendingNavigation, url == expectedPage else { return false }
        navigationReply = nil
        navigationGeneration = nil
        pendingNavigation = nil
        reply.resume()
        return true
    }

    func didFail(_ navigation: WKNavigation?, error: Error) -> Bool {
        guard let reply = navigationReply, navigation === pendingNavigation else { return false }
        navigationReply = nil
        navigationGeneration = nil
        pendingNavigation = nil
        reply.resume(throwing: error)
        return true
    }

    func run(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isActive else { completion(.failure(Failure.invalidState)); return }
        isActive = true
        Task {
            do {
                let manifest = directory.appendingPathComponent("manifest.json")
                let resumed = FileManager.default.fileExists(atPath: manifest.path)
                var snapshot: Snapshot
                if resumed {
                    stage = "resume-validation"
                    snapshot = try JSONDecoder().decode(Snapshot.self, from: Self.read(manifest))
                    guard snapshot.version == 1, snapshot.origin == origin,
                          snapshot.chunks >= 0, snapshot.chunks <= 1_000_000,
                          snapshot.digest == (try snapshotDigest(chunks: snapshot.chunks)) else { throw Failure.invalidState }
                } else {
                    stage = "legacy-load"
                    try await load(legacyPage)
                    stage = "source-export"
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let metadata = try await stringCall("exportBegin")
                    try metadata.data(using: .utf8)!.write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
                    var count = 0
                    while let chunk = try await optionalStringCall("exportNextChunk") {
                        guard count < 1_000_000 else { throw Failure.oversizedChunk }
                        try chunk.data(using: .utf8)!.write(to: chunkURL(count), options: .atomic)
                        count += 1
                    }
                    snapshot = Snapshot(version: 1, origin: origin, chunks: count,
                                        digest: try snapshotDigest(chunks: count), targetConfirmedEmpty: false)
                    try JSONEncoder().encode(snapshot).write(to: manifest, options: .atomic)
                }
                stage = "target-load"
                try await load(targetPage)
                if !snapshot.targetConfirmedEmpty {
                    stage = "target-validation"
                    let targetMetadata = try await stringCall("exportBegin")
                    guard let metadata = try JSONSerialization.jsonObject(with: Data(targetMetadata.utf8)) as? [String: Any],
                          let databases = metadata["databases"] as? [Any], databases.isEmpty,
                          metadata["windowSelection"] is NSNull else { throw Failure.targetNotEmpty }
                    snapshot = Snapshot(version: snapshot.version, origin: snapshot.origin, chunks: snapshot.chunks,
                                        digest: snapshot.digest, targetConfirmedEmpty: true)
                    try JSONEncoder().encode(snapshot).write(to: manifest, options: .atomic)
                }
                let metadata = String(decoding: try Self.read(directory.appendingPathComponent("metadata.json")), as: UTF8.self)
                stage = "import"
                _ = try await call("importBegin", input: metadata)
                for index in 0..<snapshot.chunks {
                    _ = try await call("importChunk", input: String(decoding: try Self.read(chunkURL(index)), as: UTF8.self))
                }
                _ = try await call("importFinish")
                stage = "verification"
                var verified = SHA256()
                Self.hash(try await stringCall("exportBegin"), into: &verified)
                var chunks = 0
                while let value = try await optionalStringCall("exportNextChunk") {
                    guard chunks < snapshot.chunks else { throw Failure.verification }
                    Self.hash(value, into: &verified)
                    chunks += 1
                }
                guard chunks == snapshot.chunks,
                      Self.hex(verified.finalize()) == snapshot.digest else { throw Failure.verification }
                let completed = Complete(version: 1, origin: origin, digest: snapshot.digest)
                stage = "publication"
                try JSONEncoder().encode(completed).write(to: stateDirectory.appendingPathComponent("complete.json"), options: .atomic)
                isActive = false
                stage = "completed"
                completion(.success(()))
            } catch {
                isActive = false
                completion(.failure(error))
            }
        }
    }

    private func chunkURL(_ index: Int) -> URL { directory.appendingPathComponent(String(format: "%06d.chunk", index)) }
    private static func read(_ url: URL) throws -> Data {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, size <= 4 * 1024 * 1024 else { throw Failure.invalidState }
        return try Data(contentsOf: url)
    }
    private static func hash(_ value: String, into hasher: inout SHA256) {
        let data = Data(value.utf8)
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }
    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    private func snapshotDigest(chunks: Int) throws -> String {
        var digest = SHA256()
        Self.hash(String(decoding: try Self.read(directory.appendingPathComponent("metadata.json")), as: UTF8.self), into: &digest)
        for index in 0..<chunks { Self.hash(String(decoding: try Self.read(chunkURL(index)), as: UTF8.self), into: &digest) }
        return Self.hex(digest.finalize())
    }

    private func load(_ url: URL) async throws {
        expectedPage = url
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            navigationReply = reply
            let generation = UUID()
            navigationGeneration = generation
            pendingNavigation = url.isFileURL ? webView.loadFileURL(url, allowingReadAccessTo: fileRoot) : webView.load(URLRequest(url: url))
            if pendingNavigation == nil { navigationReply = nil; reply.resume(throwing: Failure.navigation); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, self.navigationGeneration == generation, let pending = self.navigationReply else { return }
                self.navigationReply = nil
                self.navigationGeneration = nil
                self.pendingNavigation = nil
                pending.resume(throwing: Failure.timeout)
            }
        }
    }

    private func call(_ method: String, input: String? = nil) async throws -> Any? {
        guard ["exportBegin", "exportNextChunk", "importBegin", "importChunk", "importFinish"].contains(method) else { throw Failure.invalidState }
        return try await withCheckedThrowingContinuation { reply in
            var finished = false
            let timeout = DispatchWorkItem {
                guard !finished else { return }
                finished = true
                reply.resume(throwing: Failure.timeout)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
            webView.callAsyncJavaScript("return await globalThis.codipadStorageMigration.\(method)(input)",
                arguments: ["input": input as Any? ?? NSNull()], in: nil, in: .page) { result in
                guard !finished else { return }
                finished = true
                timeout.cancel()
                reply.resume(with: result.map { Optional($0) })
            }
        }
    }
    private func stringCall(_ method: String) async throws -> String {
        guard let value = try await optionalStringCall(method) else { throw Failure.unexpectedResult }
        return value
    }
    private func optionalStringCall(_ method: String) async throws -> String? {
        let result = try await call(method)
        if result == nil || result is NSNull { return nil }
        guard let value = result as? String else { throw Failure.unexpectedResult }
        guard value.utf8.count <= 4 * 1024 * 1024 else { throw Failure.oversizedChunk }
        return value
    }
}
