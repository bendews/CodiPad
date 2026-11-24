import Foundation
import Network

struct NativeWebviewServiceError: Error {
    let code: String
    let message: String
}

/// Serves only the pinned shell assets. Workspace resources still cross VS Code's grant-checked relay.
final class NativeWebviewService {
    static let maximumWebviews = 64
    private static let maximumClients = 128
    private static let maximumPendingMounts = 16
    private final class Client {
        let id = UUID()
        let connection: NWConnection
        var timeout: DispatchWorkItem?
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private final class Host {
        let id: String
        let originHash: String
        let listener: NWListener
        var endpoint: String?
        var clients: [UUID: Client] = [:]
        var waiters: [(Result<String, NativeWebviewServiceError>) -> Void] = []
        init(id: String, originHash: String, listener: NWListener) {
            self.id = id; self.originHash = originHash; self.listener = listener
        }
    }

    private let queue = DispatchQueue(label: "dev.codipad.webview", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private let assets: [String: Data]
    private var hosts: [String: Host] = [:]

    init(resourceRoot: URL) throws {
        do {
            var loaded: [String: Data] = [:]
            for name in ["index.html", "service-worker.js", "fake.html"] {
                loaded[name] = try Data(contentsOf: resourceRoot.appendingPathComponent(name))
            }
            assets = loaded
        } catch {
            throw NativeWebviewServiceError(code: "Unavailable", message: "pinned webview resources are unavailable")
        }
        queue.setSpecific(key: queueKey, value: ())
    }

    /// A stable id coalesces repeated mounts; each live webview gets a distinct loopback origin.
    func open(id: String, originHash: String, completion: @escaping (Result<String, NativeWebviewServiceError>) -> Void) {
        queue.async { [self] in
            guard UUID(uuidString: id) != nil, originHash.utf8.count == 52,
                  originHash.utf8.allSatisfy({ (48...57).contains($0) || (97...118).contains($0) }) else {
                completion(.failure(.init(code: "InvalidRequest", message: "invalid webview identity")))
                return
            }
            if let existing = self.hosts[id] {
                guard existing.originHash == originHash else {
                    completion(.failure(.init(code: "InvalidRequest", message: "webview identity changed during its lifetime")))
                    return
                }
                if let endpoint = existing.endpoint { completion(.success(endpoint)) }
                else if existing.waiters.count < Self.maximumPendingMounts { existing.waiters.append(completion) }
                else { completion(.failure(.init(code: "Unavailable", message: "too many pending webview mounts"))) }
                return
            }
            guard self.hosts.count < Self.maximumWebviews else {
                completion(.failure(.init(code: "Unavailable", message: "webview listener limit reached")))
                return
            }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                let host = Host(id: id, originHash: originHash, listener: listener)
                host.waiters.append(completion)
                self.hosts[id] = host
                listener.stateUpdateHandler = { [weak self, weak host] state in
                    guard let self, let host, self.hosts[id] === host else { return }
                    switch state {
                    case .ready:
                        guard let port = host.listener.port else {
                            self.remove(host, message: "webview listener has no port"); return
                        }
                        host.endpoint = "http://127.0.0.1:\(port.rawValue)/\(originHash)/pre"
                        let waiters = host.waiters; host.waiters.removeAll()
                        for waiter in waiters { waiter(.success(host.endpoint!)) }
                    case .failed:
                        self.remove(host, message: "webview listener failed")
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self, weak host] connection in
                    guard let self, let host, self.hosts[id] === host else { connection.cancel(); return }
                    self.accept(connection, host: host)
                }
                listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self, weak host] in
                    guard let self, let host, host.endpoint == nil, self.hosts[id] === host else { return }
                    self.remove(host, message: "webview listener did not become ready")
                }
            } catch {
                completion(.failure(.init(code: "Unavailable", message: "cannot create isolated webview listener")))
            }
        }
    }

    func close(id: String) {
        sync { if let host = hosts[id] { remove(host, message: "webview closed before becoming ready") } }
    }

    func closeAll() {
        sync { for host in Array(hosts.values) { remove(host, message: "webview service stopped") } }
    }

    /// Navigation grants expire with the listener. Loopback alone is not a webview capability.
    func allowsNavigation(to url: URL, from sourceURL: URL?, sourceOrigin: URL?, trustedWorkbench: Bool) -> Bool {
        var allowed = false
        sync {
            if trustedWorkbench && url.absoluteString == "about:blank" {
                allowed = true
                return
            }
            for host in hosts.values {
                guard let endpoint = host.endpoint, let base = URLComponents(string: endpoint),
                      let source = sourceURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { continue }
                let prefix = base.percentEncodedPath + "/"
                func issuedDocument(_ candidate: URLComponents) -> Bool {
                    guard candidate.scheme == base.scheme, candidate.host == base.host, candidate.port == base.port,
                          candidate.user == nil, candidate.password == nil,
                          [prefix + "index.html", prefix + "fake.html"].contains(candidate.percentEncodedPath) else { return false }
                    let ids = (candidate.queryItems ?? []).filter { $0.name == "id" }
                    return ids.count == 1 && ids[0].value == host.id
                }
                if !trustedWorkbench {
                    guard let origin = sourceOrigin.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
                          origin.scheme == base.scheme, origin.host == base.host, origin.port == base.port,
                          issuedDocument(source) else { continue }
                }
                if url.absoluteString == "about:blank" {
                    allowed = true
                    return
                }
                guard let target = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      target.fragment == nil, issuedDocument(target),
                      !trustedWorkbench || target.percentEncodedPath == prefix + "index.html" else { continue }
                allowed = true
                return
            }
        }
        return allowed
    }

    private func sync(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { body() }
        else { queue.sync(execute: body) }
    }

    deinit {
        for host in hosts.values {
            host.listener.cancel()
            for client in host.clients.values { client.timeout?.cancel(); client.connection.cancel() }
        }
    }

    private func remove(_ host: Host, message: String) {
        guard hosts.removeValue(forKey: host.id) != nil else { return }
        host.listener.cancel()
        for client in host.clients.values { client.timeout?.cancel(); client.connection.cancel() }
        host.clients.removeAll()
        let waiters = host.waiters; host.waiters.removeAll()
        for waiter in waiters { waiter(.failure(.init(code: "Unavailable", message: message))) }
    }

    private func accept(_ connection: NWConnection, host: Host) {
        guard hosts.values.reduce(0, { $0 + $1.clients.count }) < Self.maximumClients else {
            connection.cancel()
            return
        }
        let client = Client(connection)
        host.clients[client.id] = client
        let timeout = DispatchWorkItem { [weak self, weak host, weak client] in
            guard let self, let host, let client else { return }
            self.finish(client, host: host)
        }
        client.timeout = timeout
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
        connection.start(queue: queue)
        receive(client, host: host, buffered: Data())
    }

    private func finish(_ client: Client, host: Host) {
        host.clients.removeValue(forKey: client.id)
        client.timeout?.cancel()
        client.connection.cancel()
    }

    private func receive(_ client: Client, host: Host, buffered: Data) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak host, weak client] data, _, complete, error in
            guard let self, let host, let client, self.hosts[host.id] === host else { return }
            var received = buffered
            if let data { received.append(data) }
            if received.count > 8192 {
                self.respond(client, host: host, status: 431)
            } else if let end = received.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(client, host: host, header: received[..<end.lowerBound])
            } else if complete || error != nil {
                self.finish(client, host: host)
            } else {
                self.receive(client, host: host, buffered: received)
            }
        }
    }

    private func handle(_ client: Client, host: Host, header: Data) {
        guard let text = String(data: header, encoding: .utf8), let endpoint = host.endpoint,
              let authority = URL(string: endpoint)?.host, let port = host.listener.port else {
            respond(client, host: host, status: 400); return
        }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1" else { respond(client, host: host, status: 400); return }
        guard request[0] == "GET" || request[0] == "HEAD" else { respond(client, host: host, status: 405); return }
        let hostHeaders = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        guard hostHeaders.count == 1,
              hostHeaders[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == "\(authority):\(port.rawValue)" else {
            respond(client, host: host, status: 403); return
        }
        let path = String(request[1].split(separator: "?", maxSplits: 1).first ?? "")
        let prefix = "/\(host.originHash)/pre/"
        guard path.hasPrefix(prefix), let data = assets[String(path.dropFirst(prefix.count))] else {
            respond(client, host: host, status: 404); return
        }
        let mime = path.hasSuffix(".js") ? "text/javascript; charset=utf-8" : "text/html; charset=utf-8"
        respond(client, host: host, status: 200, data: data, mime: mime, head: request[0] == "HEAD")
    }

    private func respond(_ client: Client, host: Host, status: Int, data: Data = Data(), mime: String = "text/plain", head: Bool = false) {
        let reasons = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 431: "Request Header Fields Too Large"]
        var response = Data("HTTP/1.1 \(status) \(reasons[status]!)\r\nContent-Type: \(mime)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8)
        if !head { response.append(data) }
        client.connection.send(content: response, completion: .contentProcessed { [weak self, weak host, weak client] _ in
            guard let self, let host, let client else { return }
            self.finish(client, host: host)
        })
    }
}
