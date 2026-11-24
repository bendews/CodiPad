import Foundation
import Network
import Darwin

struct NativeWorkbenchAssetServerError: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// Immutable workbench and leased extension assets. The caller persists the workbench port.
final class NativeWorkbenchAssetServer {
    static let maximumClients = 64
    static let maximumHeaderBytes = 16 * 1024
    static let chunkBytes = 256 * 1024
    static let maximumExtensionCatalogs = 256
    static let maximumCatalogPackages = 4096
    static func canonicalResourcePath(_ uri: URL) -> String? {
        let path = uri.path
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/", omittingEmptySubsequences: true).contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return path
    }
    static func browserResourceURL(_ resource: URL, preserving source: URL) -> URL? {
        guard let original = URLComponents(url: source, resolvingAgainstBaseURL: false),
              var result = URLComponents(url: resource, resolvingAgainstBaseURL: false) else { return nil }
        result.percentEncodedQuery = original.percentEncodedQuery
        result.percentEncodedFragment = original.percentEncodedFragment
        return result.url
    }
    private static let mimeTypes = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "json": "application/json", "map": "application/json", "wasm": "application/wasm",
        "bin": "application/octet-stream",
        "txt": "text/plain; charset=utf-8", "md": "text/markdown; charset=utf-8",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "ico": "image/x-icon", "ttf": "font/ttf", "otf": "font/otf", "woff": "font/woff", "woff2": "font/woff2",
        "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg"
    ]
    struct CatalogPackage {
        let uri: String
        let key: String
        let isDirectory: Bool
        let leafName: String
        let openResource: (String) -> Int32
        init(uri: String, generation: UInt64, isDirectory: Bool, stableKey: Bool = false, openResource: @escaping (String) -> Int32) throws {
            guard uri.hasPrefix("file:///"), let url = URL(string: uri), url.isFileURL, url.host?.isEmpty != false,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  let path = NativeWorkbenchAssetServer.canonicalResourcePath(url),
                  isDirectory || path != "/" else {
                throw NativeWorkbenchAssetServerError(code: "InvalidRoot", message: "browser resources require a canonical local file URI")
            }
            self.uri = uri; self.key = stableKey ? uri : uri + "#" + String(generation)
            self.isDirectory = isDirectory; self.leafName = url.lastPathComponent; self.openResource = openResource
        }
    }

    final class ExtensionCatalogCapability {
        fileprivate weak var server: NativeWorkbenchAssetServer?
        fileprivate let token: String
        fileprivate init(server: NativeWorkbenchAssetServer, token: String) { self.server = server; self.token = token }
        func add(_ packages: [CatalogPackage]) throws -> [[String: String]] {
            guard let server else { throw NativeWorkbenchAssetServerError(code: "Closed", message: "asset server is closed") }
            return try server.addCatalogPackages(packages, token: token)
        }
        func retainExtensionPackages(_ uris: Set<String>) throws {
            guard let server else { throw NativeWorkbenchAssetServerError(code: "Closed", message: "asset server is closed") }
            try server.retainExtensionPackages(uris, token: token)
        }
        func revoke() { server?.revokeExtensionCatalog(token) }
        deinit { revoke() }
    }

    private final class ExtensionCatalog {
        let scene: String
        let baseURL: URL
        var byURI: [String: String] = [:]
        var packages: [String: CatalogPackage] = [:]
        init(scene: String, baseURL: URL) { self.scene = scene; self.baseURL = baseURL }
    }

    private final class Client {
        let connection: NWConnection
        var timeout: DispatchWorkItem?
        var file: Int32 = -1
        var remaining: Int64 = 0
        var keepAlive = false
        var leftover = Data()
        var extensionCatalog: ExtensionCatalog?
        var scene: String?
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private let queue = DispatchQueue(label: "dev.codipad.workbench-assets", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private let root: Int32
    private let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var listener: NWListener?
    private var url: URL?
    private var requestedPort: UInt16?
    private var closed = false
    private var waiters: [(Result<URL, Error>) -> Void] = []
    private var clients: [ObjectIdentifier: Client] = [:]
    private var extensionCatalogs: [String: ExtensionCatalog] = [:]
    private var sceneNonces: Set<String> = []

    init(resourceRoot: URL) throws {
        guard resourceRoot.isFileURL, resourceRoot.query == nil, resourceRoot.fragment == nil else {
            throw NativeWorkbenchAssetServerError(code: "InvalidRoot", message: "workbench assets require a local directory")
        }
        let directory = Darwin.open(resourceRoot.resolvingSymlinksInPath().standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw NativeWorkbenchAssetServerError(code: "InvalidRoot", message: "workbench asset directory is unavailable") }
        let index = openat(directory, "index.html", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        var info = stat()
        guard index >= 0, fstat(index, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            if index >= 0 { Darwin.close(index) }
            Darwin.close(directory)
            throw NativeWorkbenchAssetServerError(code: "InvalidRoot", message: "workbench entry point is unavailable")
        }
        Darwin.close(index)
        root = directory
        queue.setSpecific(key: queueKey, value: ())
    }

    /// Completion always runs on the private server queue, including errors. A requested port never falls back.
    func start(preferredPort: UInt16? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            guard !closed else { completion(.failure(error("Closed", "workbench asset server is closed"))); return }
            guard preferredPort != 0 else { completion(.failure(error("InvalidPort", "the persisted workbench port is invalid"))); return }
            if listener != nil {
                guard preferredPort == nil || preferredPort == (url?.port.map(UInt16.init) ?? requestedPort) else {
                    completion(.failure(error("PortMismatch", "workbench origin cannot change while running"))); return
                }
                if let url { completion(.success(url)) }
                else if waiters.count < 8 { waiters.append(completion) }
                else { completion(.failure(error("Unavailable", "too many pending workbench starts"))) }
                return
            }
            requestedPort = preferredPort
            waiters.append(completion)
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = false
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: preferredPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
                let server = try NWListener(using: parameters)
                listener = server
                server.stateUpdateHandler = { [weak self, weak server] state in
                    guard let self, let server, self.listener === server else { return }
                    switch state {
                    case .ready:
                        guard let port = server.port, self.requestedPort == nil || port.rawValue == self.requestedPort else {
                            self.stop(self.error("PortUnavailable", "the persisted workbench port is unavailable")); return
                        }
                        self.url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.nonce)/index.html")!
                        let callbacks = self.waiters; self.waiters.removeAll()
                        for callback in callbacks { callback(.success(self.url!)) }
                    case .failed:
                        self.stop(self.error(self.requestedPort == nil ? "Unavailable" : "PortUnavailable", "cannot bind the workbench origin"))
                    default: break
                    }
                }
                server.newConnectionHandler = { [weak self, weak server] connection in
                    guard let self, let server, self.listener === server, self.url != nil else { connection.cancel(); return }
                    self.accept(connection)
                }
                server.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 5) { [weak self, weak server] in
                    guard let self, let server, self.listener === server, self.url == nil else { return }
                    self.stop(self.error("Unavailable", "workbench listener did not become ready"))
                }
            } catch { stop(self.error(preferredPort == nil ? "Unavailable" : "PortUnavailable", "cannot bind the workbench origin")) }
        }
    }

    func close() { sync { stop(error("Closed", "workbench asset server is closed")) } }

    fileprivate func registerExtensionCatalog(scene: String) throws -> ExtensionCatalogCapability {
        try sync {
            guard !closed, sceneNonces.contains(scene), let entry = url else { throw error("Closed", "workbench scene is closed") }
            guard extensionCatalogs.count < Self.maximumExtensionCatalogs else { throw error("RootCapacity", "extension capability capacity is exhausted") }
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let base = entry.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(scene, isDirectory: true)
                .appendingPathComponent(".extension", isDirectory: true).appendingPathComponent(token, isDirectory: true)
            extensionCatalogs[token] = ExtensionCatalog(scene: scene, baseURL: base)
            return ExtensionCatalogCapability(server: self, token: token)
        }
    }

    private func addCatalogPackages(_ incoming: [CatalogPackage], token: String) throws -> [[String: String]] {
        try sync {
            guard let catalog = extensionCatalogs[token], sceneNonces.contains(catalog.scene), !closed else { throw error("Closed", "extension catalog is closed") }
            let newURIs = Set(incoming.map(\.key)).subtracting(catalog.byURI.keys)
            guard catalog.packages.count + newURIs.count <= Self.maximumCatalogPackages else { throw error("RootCapacity", "extension catalog capacity is exhausted") }
            for package in incoming where catalog.byURI[package.key] == nil {
                let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                catalog.byURI[package.key] = id
                catalog.packages[id] = package
            }
            return incoming.map { package in
                let base = catalog.baseURL.appendingPathComponent(catalog.byURI[package.key]!, isDirectory: true)
                let target = package.isDirectory ? base : base.appendingPathComponent(package.leafName)
                return ["extensionLocation": package.uri, "browserRoot": target.absoluteString]
            }
        }
    }

    private func revokeExtensionCatalog(_ token: String) {
        sync {
            guard let catalog = extensionCatalogs.removeValue(forKey: token) else { return }
            for client in Array(clients.values) where client.extensionCatalog === catalog { finish(client) }
        }
    }

    private func retainExtensionPackages(_ uris: Set<String>, token: String) throws {
        try sync {
            guard let catalog = extensionCatalogs[token], sceneNonces.contains(catalog.scene), !closed else {
                throw error("Closed", "extension catalog is closed")
            }
            // Workspace grants have generation-specific keys. In-flight responses own their file descriptors.
            for (id, package) in catalog.packages where package.key == package.uri && !uris.contains(package.uri) {
                catalog.byURI.removeValue(forKey: package.key)
                catalog.packages.removeValue(forKey: id)
            }
        }
    }

    fileprivate func makeScene() throws -> String {
        try sync {
            guard !closed else { throw error("Closed", "workbench asset server is closed") }
            let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            sceneNonces.insert(value)
            return value
        }
    }

    fileprivate func sceneEntry(_ scene: String, agents: Bool = false) -> URL? {
        sync {
            guard sceneNonces.contains(scene), let url else { return nil }
            return url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(scene, isDirectory: true).appendingPathComponent(agents ? "agents.html" : "index.html")
        }
    }

    fileprivate func hasAgentsEntry(scene: String) -> Bool {
        sync {
            guard !closed, sceneNonces.contains(scene) else { return false }
            return ["agents.html", "agents.js", "agents.css"].allSatisfy { name in
                let descriptor = openat(root, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard descriptor >= 0 else { return false }
                defer { Darwin.close(descriptor) }
                var info = stat()
                return fstat(descriptor, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
            }
        }
    }

    fileprivate func sceneMatches(_ candidate: URL, scene: String, asset: String, allowQuery: Bool = false) -> Bool {
        sync {
            guard sceneNonces.contains(scene), var value = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
                  let url, let expected = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
            if allowQuery { value.query = nil }
            return value.scheme == "http" && value.host == "127.0.0.1" && value.port == expected.port && value.user == nil && value.password == nil && value.query == nil && value.fragment == nil && value.percentEncodedPath == "/\(scene)/\(asset)"
        }
    }

    fileprivate func closeScene(_ scene: String) {
        sync {
            guard sceneNonces.remove(scene) != nil else { return }
            for token in extensionCatalogs.filter({ $0.value.scene == scene }).map(\.key) { revokeExtensionCatalog(token) }
            for client in Array(clients.values) where client.scene == scene { finish(client) }
        }
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }

    fileprivate func hasSameRoot(_ candidate: URL) -> Bool {
        guard candidate.isFileURL, candidate.query == nil, candidate.fragment == nil else { return false }
        let fd = Darwin.open(candidate.resolvingSymlinksInPath().standardizedFileURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var lhs = stat(), rhs = stat()
        return fstat(root, &lhs) == 0 && fstat(fd, &rhs) == 0 && lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private func error(_ code: String, _ message: String) -> NativeWorkbenchAssetServerError { .init(code: code, message: message) }

    private func stop(_ error: Error) {
        closed = true
        url = nil
        listener?.cancel(); listener = nil
        for client in Array(clients.values) { finish(client) }
        extensionCatalogs.removeAll()
        sceneNonces.removeAll()
        let callbacks = waiters; waiters.removeAll()
        for callback in callbacks { callback(.failure(error)) }
    }

    deinit {
        listener?.cancel()
        for client in clients.values {
            client.timeout?.cancel(); client.connection.cancel()
            if client.file >= 0 { Darwin.close(client.file) }
        }
        Darwin.close(root)
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < Self.maximumClients else { connection.cancel(); return }
        let client = Client(connection)
        clients[ObjectIdentifier(client)] = client
        armTimeout(client, seconds: 5)
        connection.start(queue: queue)
        receive(client, header: Data())
    }

    private func armTimeout(_ client: Client, seconds: Double) {
        client.timeout?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak client] in if let self, let client { self.finish(client) } }
        client.timeout = timeout
        queue.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }

    private func finish(_ client: Client) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        client.timeout?.cancel(); client.connection.cancel()
        if client.file >= 0 { Darwin.close(client.file); client.file = -1 }
        client.extensionCatalog = nil
    }

    private func receive(_ client: Client, header: Data) {
        if let end = header.range(of: Data("\r\n\r\n".utf8)) {
            client.leftover = Data(header[end.upperBound...])
            handle(client, header: Data(header[..<end.lowerBound]))
            return
        }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumHeaderBytes + 1 - header.count) { [weak self, weak client] data, _, complete, failure in
            guard let self, let client, self.clients[ObjectIdentifier(client)] != nil else { return }
            var received = header
            if let data { received.append(data) }
            if received.count > Self.maximumHeaderBytes { self.respond(client, status: 431) }
            else if let end = received.range(of: Data("\r\n\r\n".utf8)) {
                client.leftover = Data(received[end.upperBound...])
                self.handle(client, header: Data(received[..<end.lowerBound]))
            }
            else if complete || failure != nil { self.finish(client) }
            else { self.receive(client, header: received) }
        }
    }

    private func handle(_ client: Client, header: Data) {
        guard let text = String(data: header, encoding: .utf8), let origin = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              let port = origin.port else { respond(client, status: 400); return }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1" else { respond(client, status: 400); return }
        guard request[0] == "GET" || request[0] == "HEAD" else { respond(client, status: 405); return }
        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line.contains("\n"), !line.contains("\r") else { respond(client, status: 400); return }
            headers[String(line[..<colon]).lowercased(), default: []].append(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let authority = "127.0.0.1:\(port)"
        guard headers["host"] == [authority] else { respond(client, status: 403); return }
        let path = String(request[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard path.hasPrefix("/"), let end = path.dropFirst().firstIndex(of: "/") else { respond(client, status: 404); return }
        let scene = String(path[path.index(after: path.startIndex)..<end])
        guard scene == nonce || sceneNonces.contains(scene) else { respond(client, status: 404); return }
        client.scene = scene
        let prefix = "/\(scene)/"
        guard !path.contains("#"), path.hasPrefix(prefix) else { respond(client, status: 404); return }
        var rawParts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)

        guard path.hasPrefix(prefix + ".extension/") || headers["origin"] == nil || headers["origin"] == ["http://" + authority] else {
            respond(client, status: 403); return
        }
        guard headers["transfer-encoding"] == nil, headers["content-length"] == nil || headers["content-length"] == ["0"] else { respond(client, status: 400); return }
        let connectionTokens = (headers["connection"] ?? []).joined(separator: ",").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        client.keepAlive = !connectionTokens.contains("close")
        var package: CatalogPackage?
        if rawParts.first == ".extension" {
            guard rawParts.count >= 4, (headers["origin"]?.count ?? 0) <= 1 else { respond(client, status: 404); return }
            let token = String(rawParts[1])
            guard let catalog = extensionCatalogs[token], catalog.scene == scene,
                  let admitted = catalog.packages[String(rawParts[2])] else { respond(client, status: 404); return }
            client.extensionCatalog = catalog
            package = admitted
            rawParts.removeFirst(3)
        } else {
            guard headers["origin"] == nil || headers["origin"] == ["http://" + authority] else { respond(client, status: 403); return }
        }
        let parts = rawParts.compactMap { String($0).removingPercentEncoding }
        let assetCapability = client.extensionCatalog != nil
        guard parts.count == rawParts.count, !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && (assetCapability || !$0.hasPrefix(".")) && !$0.contains("/") && !$0.contains("\\") && !$0.utf8.contains(0) }),
              let name = parts.last else { respond(client, status: 404); return }
        let ext = (name as NSString).pathExtension.lowercased()
        guard let mime = Self.mimeTypes[ext] ?? (assetCapability ? "application/octet-stream" : nil) else { respond(client, status: 404); return }
        let descriptor: Int32
        if let package {
            guard package.isDirectory || (parts.count == 1 && name == package.leafName) else { respond(client, status: 404); return }
            descriptor = package.openResource(package.isDirectory ? parts.joined(separator: "/") : "")
        } else { descriptor = openAsset(parts) }
        var info = stat()
        guard descriptor >= 0, fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            if descriptor >= 0 { Darwin.close(descriptor) }
            respond(client, status: 404); return
        }
        client.file = descriptor
        client.remaining = Int64(info.st_size)
        armTimeout(client, seconds: 30)
        // Bundle assets are scoped by a per-launch scene nonce and immutable for the process lifetime.
        let cacheControl: String
        if assetCapability || ext == "html" {
            cacheControl = "no-store"
        } else if parts.first == "assets" {
            cacheControl = "private, max-age=3600, immutable"
        } else {
            cacheControl = "private, max-age=3600"
        }
        respond(client, status: 200, length: client.remaining, mime: mime, cacheControl: cacheControl, head: request[0] == "HEAD")
    }

    private func openAsset(_ parts: [String]) -> Int32 {
        var directory = root
        for (index, part) in parts.enumerated() {
            let last = index == parts.count - 1
            let next = openat(directory, part, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (last ? O_NONBLOCK : O_DIRECTORY))
            if directory != root { Darwin.close(directory) }
            guard next >= 0 else { return -1 }
            if last { return next }
            directory = next
        }
        return -1
    }

    private func respond(_ client: Client, status: Int, length: Int64 = 0, mime: String = "text/plain",
                         cacheControl: String = "no-store", head: Bool = false) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 431: "Request Header Fields Too Large"][status]!
        let capabilityHeaders = client.extensionCatalog == nil ? "" : "Access-Control-Allow-Origin: *\r\nCross-Origin-Resource-Policy: cross-origin\r\n"
        let reuse = client.keepAlive && (status == 200 || status == 404)
        client.keepAlive = reuse
        let connectionHeader = reuse ? "keep-alive" : "close"
        let response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(mime)\r\nContent-Length: \(length)\r\nCache-Control: \(cacheControl)\r\nX-Content-Type-Options: nosniff\r\n\(capabilityHeaders)Connection: \(connectionHeader)\r\n\r\n".utf8)
        client.connection.send(content: response, completion: .contentProcessed { [weak self, weak client] failure in
            guard let self, let client, self.clients[ObjectIdentifier(client)] != nil else { return }
            if failure != nil { self.finish(client); return }
            if head || status != 200 { self.completeResponse(client) }
            else { self.sendChunk(client) }
        })
    }

    private func completeResponse(_ client: Client) {
        if client.file >= 0 { Darwin.close(client.file); client.file = -1 }
        client.remaining = 0
        client.extensionCatalog = nil
        guard client.keepAlive else { finish(client); return }
        armTimeout(client, seconds: 15)
        let pending = client.leftover
        client.leftover = Data()
        receive(client, header: pending)
    }

    private func sendChunk(_ client: Client) {
        guard client.remaining > 0 else { completeResponse(client); return }
        var data = Data(count: min(Self.chunkBytes, Int(client.remaining)))
        var count: Int
        repeat { count = data.withUnsafeMutableBytes { Darwin.read(client.file, $0.baseAddress!, $0.count) } }
        while count < 0 && errno == EINTR
        guard count > 0 else { finish(client); return }
        data.count = count
        client.remaining -= Int64(count)
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] failure in
            guard let self, let client, self.clients[ObjectIdentifier(client)] != nil else { return }
            if failure != nil { self.finish(client) }
            else {
                self.armTimeout(client, seconds: 30)
                self.sendChunk(client)
            }
        })
    }
}

/// One scene's path and extension capabilities on the process-shared listener.
final class NativeWorkbenchAssetLease {
    private let server: NativeWorkbenchAssetServer
    private let scene: String
    private let lock = NSLock()
    private var released = false
    fileprivate init(server: NativeWorkbenchAssetServer, scene: String) { self.server = server; self.scene = scene }

    func start(preferredPort: UInt16? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        server.start(preferredPort: preferredPort) { [weak self] result in
            DispatchQueue.global(qos: .userInitiated).async {
                switch result {
                case .failure(let error): completion(.failure(error))
                case .success:
                    guard let self, let entry = self.entryURL else {
                        completion(.failure(NativeWorkbenchAssetServerError(code: "Closed", message: "workbench scene is closed"))); return
                    }
                    completion(.success(entry))
                }
            }
        }
    }
    var entryURL: URL? { server.sceneEntry(scene) }
    func migrationURL() -> URL? { entryURL?.deletingLastPathComponent().appendingPathComponent("storage-migration.html") }
    func entryURL(agents: Bool) -> URL? { server.sceneEntry(scene, agents: agents) }
    func isEntryPoint(_ candidate: URL, agents: Bool = false) -> Bool { server.sceneMatches(candidate, scene: scene, asset: agents ? "agents.html" : "index.html") }
    func hasAgentsEntry() -> Bool { server.hasAgentsEntry(scene: scene) }
    func isExtensionWorkerFrame(_ candidate: URL) -> Bool { server.sceneMatches(candidate, scene: scene, asset: "out/vs/workbench/services/extensions/worker/webWorkerExtensionHostIframe.html", allowQuery: true) }
    func registerExtensionCatalog() throws -> NativeWorkbenchAssetServer.ExtensionCatalogCapability {
        try server.registerExtensionCatalog(scene: scene)
    }
    func close() {
        lock.lock(); let shouldClose = !released; released = true; lock.unlock()
        guard shouldClose else { return }
        server.closeScene(scene)
        NativeWorkbenchAssetPool.release(server)
    }
    deinit { close() }
}

/// Shares only the bound listener; each lease receives an independent capability namespace.
enum NativeWorkbenchAssetPool {
    private static let lock = NSCondition()
    private static var server: NativeWorkbenchAssetServer?
    private static var owners = 0
    private static var closing = false
    static func acquire(resourceRoot: URL) throws -> NativeWorkbenchAssetLease {
        lock.lock()
        while closing { lock.wait() }
        let instance: NativeWorkbenchAssetServer
        if let existing = server {
            guard existing.hasSameRoot(resourceRoot) else {
                lock.unlock()
                throw NativeWorkbenchAssetServerError(code: "InvalidRoot", message: "workbench asset root changed")
            }
            instance = existing
        } else {
            do { instance = try NativeWorkbenchAssetServer(resourceRoot: resourceRoot) }
            catch { lock.unlock(); throw error }
            server = instance
        }
        owners += 1
        lock.unlock()
        do {
            let scene = try instance.makeScene()
            return NativeWorkbenchAssetLease(server: instance, scene: scene)
        } catch {
            release(instance)
            throw error
        }
    }
    fileprivate static func release(_ instance: NativeWorkbenchAssetServer) {
        lock.lock()
        guard server === instance, owners > 0 else { lock.unlock(); return }
        owners -= 1
        guard owners == 0 else { lock.unlock(); return }
        server = nil
        closing = true
        lock.unlock()
        instance.close()
        lock.lock(); closing = false; lock.broadcast(); lock.unlock()
    }
}
