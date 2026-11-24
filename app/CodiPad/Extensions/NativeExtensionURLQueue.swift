import Foundation

/// Main-thread confined. Only unclaimed callbacks survive page replacement; a claim is never retried.
/// A renderer loss after claim has an uncertain outcome, since arbitrary extension effects cannot be rolled back.
final class NativeExtensionURLQueue {
    enum Failure: Error { case invalidURL, full, staleReceiver }
    private struct Request {
        let id: String
        let uri: String
        var delivered = false
    }
    private var requests: [Request] = []
    private var page: String?
    private var receiver: String?

    static func accepts(_ url: URL) -> Bool {
        let text = url.absoluteString
        guard text.utf8.count <= 16_384,
              !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "codipad", parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host,
              host.range(of: "^[a-z0-9][a-z0-9-]*\\.[a-z0-9][a-z0-9-]*$", options: [.regularExpression, .caseInsensitive]) != nil
        else { return false }
        return true
    }

    func receive(_ url: URL) throws {
        guard Self.accepts(url) else { throw Failure.invalidURL }
        guard requests.count < 32 else { throw Failure.full }
        requests.append(Request(id: UUID().uuidString, uri: url.absoluteString))
    }

    func dispose() {
        setPage(nil)
        requests.removeAll()
    }

    func setPage(_ page: String?) {
        self.page = page
        receiver = nil
        for index in requests.indices { requests[index].delivered = false }
    }

    func operation(_ method: String, _ params: [String: Any]) throws -> Any {
        guard let page = params["pageId"] as? String, page == self.page,
              let receiver = params["receiverId"] as? String, UUID(uuidString: receiver) != nil else { throw Failure.staleReceiver }
        if method == "urls.ready" || method == "urls.suspend" {
            guard Set(params.keys) == ["pageId", "receiverId"], self.receiver == nil || self.receiver == receiver else { throw Failure.staleReceiver }
            self.receiver = method == "urls.ready" ? receiver : nil
            for index in requests.indices { requests[index].delivered = false }
            return NSNull()
        }
        guard method == "urls.claim", Set(params.keys) == ["pageId", "receiverId", "id"], self.receiver == receiver,
              let id = params["id"] as? String,
              let index = requests.firstIndex(where: { $0.id == id && $0.delivered }) else { throw Failure.staleReceiver }
        return requests.remove(at: index).uri
    }

    func deliveries() -> [[String: Any]] {
        guard let page, let receiver else { return [] }
        return requests.indices.compactMap { index in
            guard !requests[index].delivered else { return nil }
            guard let data = try? JSONSerialization.data(withJSONObject: ["pageId": page, "receiverId": receiver, "id": requests[index].id]) else { return nil }
            requests[index].delivered = true
            return ["kind": "urls.open", "sessionId": 0, "pageId": page, "receiverId": receiver,
                    "requestId": requests[index].id,
                    "data": String(decoding: data, as: UTF8.self)]
        }
    }

    @discardableResult
    func failedDelivery(_ event: [String: Any]) -> Bool {
        guard event["pageId"] as? String == page, event["receiverId"] as? String == receiver,
              let index = requests.firstIndex(where: { $0.id == event["requestId"] as? String && $0.delivered }) else { return false }
        requests[index].delivered = false // Retry only after the next ready/page transition, never spin on a failed WK call.
        return true
    }
}
