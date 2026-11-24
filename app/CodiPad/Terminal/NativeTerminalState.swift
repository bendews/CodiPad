import Foundation
import JavaScriptCore

/// App-owned parser/screen state. Never shares the WK renderer's JavaScript lifetime.
/// All JS values and timers stay on this queue; callers are the terminal IO queue, not main.
final class NativeTerminalState {
    private let queue = DispatchQueue(label: "dev.codipad.terminal-state")
    private var context: JSContext!
    private var handle: JSValue!
    private var timers: [Int: DispatchWorkItem] = [:]
    private var nextTimer = 0
    private var completion: ((Result<Any, Error>) -> Void)?
    private var failed = false
    private let scrollback: Int

    /// Keep these preflight limits aligned with the pinned terminal-state runtime.
    static func validateConfiguration(cols: Int, rows: Int, scrollback: Int) throws {
        guard (2...1000).contains(cols), (1...500).contains(rows), (0...10000).contains(scrollback),
              cols * (rows + scrollback) <= 2_000_000 else {
            throw NativeTerminalHostError.invalidRequest("terminal replay requires 0–10000 scrollback lines and at most 2000000 cells within supported dimensions")
        }
    }

    init(cols: Int, rows: Int, scrollback: Int, unicodeVersion: String, shellIntegrationNonce: String) throws {
        try Self.validateConfiguration(cols: cols, rows: rows, scrollback: scrollback)
        self.scrollback = scrollback
        guard let url = Bundle.main.url(forResource: "terminal-state", withExtension: "js", subdirectory: "Workbench") else {
            throw NativeTerminalHostError.invalidRequest("terminal state bundle is missing")
        }
        let script = try String(contentsOf: url, encoding: .utf8)
        _ = try perform { [self] done in
            self.context = JSContext()
            self.context.exceptionHandler = { [weak self] _, _ in
                self?.failed = true
                self?.finish(.failure(NativeTerminalHostError.invalidRequest("terminal state runtime failed")))
            }
            let schedule: @convention(block) (JSValue, Double) -> Int = { [weak self] callback, delay in
                guard let self else { return 0 }
                self.nextTimer += 1
                let id = self.nextTimer
                let item = DispatchWorkItem { [weak self] in
                    guard let self, self.timers.removeValue(forKey: id) != nil else { return }
                    callback.call(withArguments: [])
                }
                self.timers[id] = item
                self.queue.asyncAfter(deadline: .now() + max(0, min(delay, 60_000)) / 1000, execute: item)
                return id
            }
            let cancel: @convention(block) (Int) -> Void = { [weak self] id in
                self?.timers.removeValue(forKey: id)?.cancel()
            }
            self.context.setObject(schedule, forKeyedSubscript: "setTimeout" as NSString)
            self.context.setObject(cancel, forKeyedSubscript: "clearTimeout" as NSString)
            let now: @convention(block) () -> Double = { ProcessInfo.processInfo.systemUptime * 1000 }
            let uuid: @convention(block) () -> String = { UUID().uuidString.lowercased() }
            self.context.setObject(["now": now], forKeyedSubscript: "performance" as NSString)
            self.context.setObject(["randomUUID": uuid], forKeyedSubscript: "crypto" as NSString)
            self.context.evaluateScript("globalThis.queueMicrotask = callback => Promise.resolve().then(callback);")
            self.context.evaluateScript(script)
            guard !self.failed else { return }
            self.handle = self.context.objectForKeyedSubscript("CodiPadTerminalState")?.invokeMethod("create", withArguments: [
                ["cols": cols, "rows": rows, "scrollback": scrollback, "unicodeVersion": unicodeVersion, "shellIntegrationNonce": shellIntegrationNonce]
            ])
            guard self.handle != nil, !self.handle.isUndefined, !self.handle.isNull else {
                self.finish(.failure(NativeTerminalHostError.invalidRequest("terminal state creation failed")))
                return
            }
            done(.success(NSNull()))
        }
    }

    /// Only one write is admitted per session. The shared IO queue never waits for parser work.
    final class Write {
        private let finished = DispatchGroup()
        private var result: Result<[String], Error>?
        init() { finished.enter() }
        fileprivate func complete(_ result: Result<[String], Error>) {
            self.result = result
            finished.leave()
        }
        func wait() throws -> [String] {
            finished.wait()
            return try result!.get()
        }
    }

    func writeAsync(_ data: Data, completion: @escaping (Write) -> Void) -> Write {
        let write = Write()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            write.complete(Result {
                guard let replies = try self.call("writeLive", arguments: [Array(data)]) as? [String] else {
                    throw NativeTerminalHostError.invalidRequest("terminal auto reply result is malformed")
                }
                return replies
            })
            completion(write)
        }
        return write
    }

    func write(_ data: Data) throws {
        _ = try call("write", arguments: [Array(data)])
    }

    func installAutoReply(_ match: String, reply: String) throws {
        try synchronousCall("installAutoReply", arguments: [match, reply])
    }

    func uninstallAllAutoReplies() throws {
        try synchronousCall("uninstallAllAutoReplies", arguments: [])
    }

    func snapshot() throws -> [String: Any] {
        guard let value = try call("snapshot", arguments: []) as? [String: Any],
              value["data"] is String, value["pendingBytes"] is [NSNumber],
              value["cols"] is NSNumber, value["rows"] is NSNumber else {
            throw NativeTerminalHostError.invalidRequest("terminal snapshot is malformed")
        }
        return value
    }

    func restoreCommands(_ commands: [String: Any]) throws {
        try synchronousCall("restoreCommands", arguments: [commands])
    }

    func snapshotNormal() throws -> [String: Any] {
        guard let value = try call("snapshotNormal", arguments: []) as? [String: Any], value["data"] is String else {
            throw NativeTerminalHostError.invalidRequest("normal terminal snapshot is malformed")
        }
        return value
    }

    /// Invalid input must not reach the JS exception handler, which marks real runtime faults fatal.
    func validateResize(cols: Int, rows: Int) throws {
        try Self.validateConfiguration(cols: cols, rows: rows, scrollback: scrollback)
    }

    func resize(cols: Int, rows: Int) throws {
        try validateResize(cols: cols, rows: rows)
        _ = try perform { done in
            self.handle.invokeMethod("resize", withArguments: [cols, rows])
            if !self.failed { done(.success(NSNull())) }
        }
    }

    func clearBuffer() throws { try synchronousCall("clearBuffer", arguments: []) }
    func setNextCommandId(_ commandLine: String, _ commandId: String) throws {
        try synchronousCall("setNextCommandId", arguments: [commandLine, commandId])
    }
    func setUnicodeVersion(_ version: String) throws { _ = try call("setUnicodeVersion", arguments: [version]) }

    private func synchronousCall(_ method: String, arguments: [Any]) throws {
        _ = try perform { done in
            self.handle.invokeMethod(method, withArguments: arguments)
            if !self.failed { done(.success(NSNull())) }
        }
    }

    private func call(_ method: String, arguments: [Any]) throws -> Any {
        try perform { done in
            let callback: @convention(block) (JSValue, JSValue) -> Void = { error, value in
                if !error.isUndefined && !error.isNull {
                    done(.failure(NativeTerminalHostError.invalidRequest("terminal state \(method) failed")))
                } else {
                    done(.success(value.toObject() ?? NSNull()))
                }
            }
            self.handle.invokeMethod(method, withArguments: arguments + [callback])
        }
    }

    private func finish(_ result: Result<Any, Error>) {
        let done = completion
        completion = nil
        done?(result)
    }

    private func perform(_ body: @escaping (@escaping (Result<Any, Error>) -> Void) -> Void) throws -> Any {
        precondition(!Thread.isMainThread)
        let signal = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<Any, Error>?
        queue.async {
            guard !self.failed else {
                lock.lock(); result = .failure(NativeTerminalHostError.invalidRequest("terminal state is unavailable")); lock.unlock()
                signal.signal(); return
            }
            self.completion = { value in
                lock.lock(); result = value; lock.unlock(); signal.signal()
            }
            body { self.finish($0) }
        }
        guard signal.wait(timeout: .now() + 10) == .success else {
            queue.async { self.failed = true; self.completion = nil }
            throw NativeTerminalHostError.invalidRequest("terminal state operation timed out")
        }
        lock.lock(); defer { lock.unlock() }
        return try result!.get()
    }

    func dispose() {
        queue.async {
            self.timers.values.forEach { $0.cancel() }
            self.timers.removeAll()
            self.handle?.invokeMethod("dispose", withArguments: [])
            self.handle = nil
            self.context = nil
        }
    }
}
