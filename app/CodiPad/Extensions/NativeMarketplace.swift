import Foundation

/// HTTPS access to the extension gallery configured in the app bundle.
final class NativeMarketplaceClient {
    static let maximumRequestBodyBytes = 2 * 1024 * 1024
    // Full Marketplace version histories can exceed 64 MiB.
    static let maximumResponseBodyBytes = 128 * 1024 * 1024

    private let configuration: URLSessionConfiguration

    private static let gallery: (service: URL, allowMicrosoftCDN: Bool)? = {
        guard let file = Bundle.main.url(forResource: "product", withExtension: "json", subdirectory: "Exthost"),
              let data = try? Data(contentsOf: file),
              let product = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gallery = product["extensionsGallery"] as? [String: Any],
              let service = gallery["serviceUrl"] as? String,
              let url = URL(string: service),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }

        let allowMicrosoftCDN = product["codipadMicrosoftMarketplace"] as? Bool == true &&
            service == "https://marketplace.visualstudio.com/_apis/public/gallery"
        return (url, allowMicrosoftCDN)
    }()

    static func galleryServiceURL() throws -> URL {
        guard let service = gallery?.service else {
            throw NativeMarketplaceError(code: "GalleryUnavailable", message: "No extension gallery is configured. Use Install from VSIX to install a local package.")
        }
        return service
    }

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    func request(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> NativeMarketplaceResponse {
        try Self.validate(url)
        let normalizedMethod = method.uppercased()
        guard ["GET", "POST"].contains(normalizedMethod) else {
            throw NativeMarketplaceError(code: "MethodNotAllowed", message: "Marketplace requests support GET and POST")
        }
        guard (body?.count ?? 0) <= Self.maximumRequestBodyBytes else {
            throw NativeMarketplaceError(code: "RequestTooLarge", message: "Marketplace request body exceeds the size limit")
        }

        var request = URLRequest(url: url)
        request.httpMethod = normalizedMethod
        request.httpBody = body
        request.timeoutInterval = 60
        for (name, value) in headers where Self.isSafeHeader(name: name, value: value) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return try await MarketplaceURLSessionRequest(responseLimit: Self.maximumResponseBodyBytes).run(request, configuration: configuration)
    }

    static func validate(_ url: URL?) throws {
        let service = try galleryServiceURL()
        guard let url,
              url.scheme?.lowercased() == "https",
              (url.port ?? 443) == (service.port ?? 443),
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              host == service.host?.lowercased() || (gallery?.allowMicrosoftCDN == true &&
                (host.hasSuffix(".gallery.vsassets.io") || host.hasSuffix(".gallerycdn.vsassets.io"))) else {
            throw NativeMarketplaceError(code: "HostNotAllowed", message: "The URL is outside the configured extension gallery's allowed HTTPS origins")
        }
    }

    private static func isSafeHeader(name: String, value: String) -> Bool {
        let lower = name.lowercased()
        return !["host", "cookie", "authorization", "content-length", "connection"].contains(lower) &&
            !name.contains("\r") && !name.contains("\n") && !value.contains("\r") && !value.contains("\n")
    }
}

struct NativeMarketplaceResponse {
    let status: Int
    let headers: [String: String]
    let body: Data
}

private final class MarketplaceURLSessionRequest: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let responseLimit: Int
    private var continuation: CheckedContinuation<NativeMarketplaceResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let cancellationLock = NSLock()
    private var cancelled = false
    private var response: HTTPURLResponse?
    private var receivedData = Data()
    private var declaredLength = "unknown"
    private var redirectError: NativeMarketplaceError?

    init(responseLimit: Int) {
        self.responseLimit = responseLimit
    }

    func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> NativeMarketplaceResponse {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                cancellationLock.lock()
                self.task = task
                let cancelled = self.cancelled
                cancellationLock.unlock()
                task.resume()
                if cancelled { task.cancel() }
            }
        }, onCancel: {
            self.cancellationLock.lock()
            self.cancelled = true
            let task = self.task
            self.cancellationLock.unlock()
            task?.cancel()
        })
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(NativeMarketplaceError(code: "InvalidResponse", message: "Marketplace returned a non-HTTP response")))
            return
        }
        do {
            try NativeMarketplaceClient.validate(http.url)
        } catch let error as NativeMarketplaceError {
            completionHandler(.cancel)
            finish(.failure(error))
            return
        } catch {
            completionHandler(.cancel)
            finish(.failure(NativeMarketplaceError(code: "HostNotAllowed", message: "Marketplace response host is not allowed")))
            return
        }

        self.response = http
        if let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
           let parsed = Int64(contentLength.trimmingCharacters(in: .whitespacesAndNewlines)), parsed >= 0 {
            declaredLength = String(parsed)
        } else if http.expectedContentLength >= 0 {
            declaredLength = String(http.expectedContentLength)
        }
        // Content-Length can describe compressed bytes while URLSession delivers decoded bytes.
        // Keep it for diagnostics only; never use it to allocate or reject the response.
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard continuation != nil else { return }
        let remaining = responseLimit - receivedData.count
        guard data.count <= remaining else {
            let received = receivedData.count + data.count
            task?.cancel()
            finish(.failure(NativeMarketplaceError(
                code: "ResponseTooLarge",
                message: "declaredLength=\(declaredLength) receivedBytes=\(received) limitBytes=\(responseLimit)"
            )))
            return
        }
        receivedData.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        do {
            try NativeMarketplaceClient.validate(request.url)
            completionHandler(request)
        } catch let error as NativeMarketplaceError {
            redirectError = error
            completionHandler(nil)
            task.cancel()
        } catch {
            redirectError = NativeMarketplaceError(code: "HostNotAllowed", message: "Marketplace redirect host is not allowed")
            completionHandler(nil)
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard continuation != nil else { return }
        if let redirectError {
            finish(.failure(redirectError))
            return
        }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                finish(.failure(CancellationError()))
                return
            }
            finish(.failure(NativeMarketplaceError(code: "RequestFailed", message: error.localizedDescription)))
            return
        }
        guard let response else {
            finish(.failure(NativeMarketplaceError(code: "InvalidResponse", message: "Marketplace returned no HTTP response")))
            return
        }
        let responseHeaders = Dictionary(
            response.allHeaderFields.compactMap { key, value -> (String, String)? in
                guard let key = key as? String else { return nil }
                return (key.lowercased(), String(describing: value))
            }, uniquingKeysWith: { first, _ in first }
        )
        finish(.success(NativeMarketplaceResponse(status: response.statusCode, headers: responseHeaders, body: receivedData)))
    }

    private func finish(_ result: Result<NativeMarketplaceResponse, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        let session = self.session
        self.session = nil
        cancellationLock.lock()
        task = nil
        cancellationLock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }
}

struct NativeMarketplaceError: Error, CustomStringConvertible {
    let code: String
    let message: String
    var description: String { "\(code): \(message)" }
}
