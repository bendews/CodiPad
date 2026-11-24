import Darwin
import Foundation

/// Per-host output accounting shared by the Darwin and Linux transports. Calls are serialized by
/// each host's queue; delivery uses exact session/dataId acknowledgements. Renderer teardown
/// explicitly discards credits without claiming delivery.
final class ExtensionHostOutputCredits {
    private let byteLimit: Int
    private let eventLimit: Int
    private var nextDataID = 1
    private var credits: [Int: [Int: Int]] = [:]
    private(set) var pendingBytes = 0
    private(set) var pendingEvents = 0

    init(byteLimit: Int = 8 * 1024 * 1024, eventLimit: Int = 128) {
        self.byteLimit = byteLimit
        self.eventLimit = eventLimit
    }

    var hasOutstanding: Bool { pendingEvents > 0 }
    var remainingByteCapacity: Int { byteLimit - pendingBytes }
    var remainingEventCapacity: Int { eventLimit - pendingEvents }

    func reserve(sessionID: Int, byteCount: Int) -> Int? {
        guard sessionID > 0, byteCount > 0, byteCount <= byteLimit - pendingBytes,
              pendingEvents < eventLimit, nextDataID <= 9_007_199_254_740_991 else { return nil }
        let dataID = nextDataID
        nextDataID += 1
        credits[sessionID, default: [:]][dataID] = byteCount
        pendingBytes += byteCount
        pendingEvents += 1
        return dataID
    }

    func acknowledge(sessionID: Int, dataID: Int) -> Int? {
        guard sessionID > 0, dataID > 0,
              let bytes = credits[sessionID]?.removeValue(forKey: dataID) else { return nil }
        pendingBytes -= bytes
        pendingEvents -= 1
        if credits[sessionID]?.isEmpty == true { credits.removeValue(forKey: sessionID) }
        return bytes
    }

    /// Discard a dead renderer's protocol bookkeeping, not an acknowledgement or exit proof.
    func discardForRendererTeardown() {
        credits.removeAll()
        pendingBytes = 0
        pendingEvents = 0
    }

    func contains(sessionID: Int, dataID: Int) -> Bool {
        credits[sessionID]?[dataID] != nil
    }
}

/// Native extension-host transport over embedded Node or the supervised Linux runtime.
///
/// Shape (matches the TS `IExtensionHostTransport` and the workbench overlay):
///   * `start(generation:) -> Int` starts one host generation and returns a numeric session id.
///   * `send(sessionId:base64:)` writes raw socket bytes; no framing is interpreted here.
///   * `stop(sessionId:)` asks the generation to stop.
///   * `onEvent` emits `exthost.data` / `exthost.exit` for the bridge to forward to the page.
///
/// The Node side is the real bundled `Exthost/extensionHostProcess.js`, launched with a
/// `createRequire` bootstrap and a per-environment native environment store. It connects out to a
/// UNIX socket this type listens on. This type owns one host generation, not a process table.
///
/// Limits (deliberately not claimed as working):
///   * one active generation; a second start is rejected until the previous one exits;
///   * no restart policy, no extension activation, no subprocess registry;
///   * a native abort inside the runtime still takes the app down (as recorded in the plan);
///   * debugger-prepared pages are opt-in via `--codipad-debugger-pages` and are not a JIT bypass.
final class NativeExtensionHost {
    typealias EventHandler = ([String: Any]) -> Void

    private struct PendingHostWrite {
        let data: Data
        let completion: (Result<Void, Error>) -> Void
    }

    /// Called on the main queue with `exthost.data` / `exthost.exit` payloads.
    var onEvent: EventHandler?

    private enum Phase {
        case idle
        case starting
        case running
        case stopping
    }

    private let ioQueue = DispatchQueue(label: "dev.codipad.exthost", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()

    private var runtime: OpaquePointer?
    /// Strong hold on the shared filesystem/scope owner for as long as this host may run.
    /// Released only after the runtime generation has actually been stopped and destroyed.
    private var leaseOwner: AnyObject?
    private var listener: UNIXSocketListener?
    private var connection: UNIXSocketConnection?
    private var pendingWrites: [PendingHostWrite] = []
    private var pendingWriteBytes = 0
    private var pendingWriteEvents = 0
    private var pendingEvents: [[String: Any]] = []
    private var pendingEventBytes = 0
    private let outputCredits = ExtensionHostOutputCredits()

    private var phase: Phase = .idle
    private var activeSessionId: Int?
    private var reloadReplies: [(Result<Void, Error>) -> Void] = []
    private var discardingRendererOutput = false
    private var protocolEOF = true
    private var startReturned = false
    private var exitEmitted = false
    private var retiringExitEvent: [String: Any]?
    /// Strong self-reference kept while the C runtime may still invoke its callback.
    private var retainedContext: UnsafeMutableRawPointer?
    private var incompleteCleanup = false
    private var failingTransport = false
    private var transportFailureReason: String?
    private let linuxHost = LinuxExtensionHost()
    private let usesLinuxHost = NativeRuntimeConfiguration.current.usesLinuxExtensionHost

    var processRuntime: NativeProcessRuntime { usesLinuxHost ? .linux : .embedded }

    private let useDebuggerPreparedPages = NativeRuntimeConfiguration.current.debuggerPrepared

    private static let sessionCounterLock = NSLock()
    private static var sessionCounter = 0
    private static let quarantineLock = NSLock()
    private static var quarantined: [NativeExtensionHost] = []
    private static let maxPendingWriteBytes = 4 * 1024 * 1024
    private static let maxPendingWriteEvents = 1024
    private static let maxDecodedPayloadBytes = 16 * 1024 * 1024
    private static let maxBufferedEventBytes = 8 * 1024 * 1024
    private static let errorBufferSize = 256

    /// - Parameter leaseOwner: the shared `WorkspaceFileSystem` (or any scope-owning object).
    ///   It is retained until the Node environment is stopped and `CodiPadNodeRuntimeDestroy`
    ///   succeeds, so a controller teardown cannot drop security scopes under a running host.
    init(leaseOwner: AnyObject? = nil) {
        self.leaseOwner = leaseOwner
        ioQueue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        // Destroy must not run from a runtime callback; the owner calls shutdown() first.
        listener?.close()
        connection?.close()
        if let runtime {
            var error = [CChar](repeating: 0, count: Self.errorBufferSize)
            _ = CodiPadNodeRuntimeDestroy(runtime, &error, error.count)
        }
    }

    // MARK: - Public lifecycle

    /// Starts one generation. `generation` is informational only (the TS adapter sends 0).
    func start(generation: Int = 0, environment guestEnvironment: [String: String], bundleRoot: URL,
               processCwd: String? = nil, runtimeOwner: AnyObject? = nil) throws -> Int {
        if usesLinuxHost {
            guard let processCwd else {
                throw NativeExtensionHostError.startFailed(
                    "Linux extension host requires a prepared, authorized process directory"
                )
            }
            guard let runtimeOwner else {
                throw NativeExtensionHostError.startFailed("Linux extension host requires a retained process authority")
            }
            linuxHost.onEvent = { [weak self] event in self?.onEvent?(event) }
            let bundlePath = URL(fileURLWithPath: try artifactPath(in: bundleRoot)).deletingLastPathComponent().path
            return try linuxHost.start(bundlePath: bundlePath, environment: guestEnvironment,
                                       processCwd: processCwd, leaseOwner: leaseOwner, runtimeOwner: runtimeOwner)
        }
        return try onQueue {
            guard phase == .idle else { throw NativeExtensionHostError.alreadyRunning }
            guard !outputCredits.hasOutstanding else {
                throw NativeExtensionHostError.cleanupIncomplete("previous generation still has unacknowledged output")
            }
            guard !incompleteCleanup else {
                throw NativeExtensionHostError.cleanupIncomplete("previous generation could not be destroyed")
            }
            guard reloadReplies.isEmpty else { throw NativeExtensionHostError.alreadyRunning }
            discardingRendererOutput = false
            protocolEOF = true
            let bundlePath = try artifactPath(in: bundleRoot)
            let socketPath = try makeSocketPath()

            let sessionId = Self.nextSessionId()
            activeSessionId = sessionId
            exitEmitted = false
            failingTransport = false
            transportFailureReason = nil
            startReturned = false
            pendingWrites.removeAll()
            pendingWriteBytes = 0
            pendingWriteEvents = 0
            pendingEvents.removeAll()
            phase = .starting

            do {
                let listener = try UNIXSocketListener(path: socketPath, queue: ioQueue)
                listener.onAccept = { [weak self] fd in self?.accept(fd: fd) }
                listener.onFailure = { [weak self] message in self?.transportFailed(message) }
                self.listener = listener

                try ensureRuntime()
                guard let runtime else { throw NativeExtensionHostError.runtimeUnavailable("runtime handle is null") }

                let script = bootstrapScript(bundlePath: bundlePath)
                let environmentJSON = try environmentSnapshotJSON(guestEnvironment, socketPath: socketPath, bundlePath: bundlePath)
                var error = [CChar](repeating: 0, count: Self.errorBufferSize)
                let started = script.withCString { scriptPointer in
                    environmentJSON.withCString { environmentPointer in
                        CodiPadNodeRuntimeStartWithEnvironment(
                            runtime, scriptPointer, script.utf8.count,
                            environmentPointer, environmentJSON.utf8.count,
                            &error, error.count
                        )
                    }
                }
                guard started else {
                    let detail = String(cString: error)
                    let snapshot = copySnapshot(runtime)
                    let state = snapshot.state
                    if state == Self.stateStarting || state == Self.stateRunning || state == Self.stateStopping {
                        // The C API reported failure but the handle may still host a live
                        // environment. Fail closed: keep the session, the scope owner and the
                        // callback context, stop accepting peers, and refuse further starts.
                        phase = state == Self.stateRunning ? .running
                            : (state == Self.stateStopping ? .stopping : .starting)
                        listener.close()
                        self.listener = nil
                        startReturned = false
                        pendingEvents.removeAll()
                        pendingEventBytes = 0
                        quarantine("start reported failure while runtime state is \(Self.stateName(state))")
                        let reason = detail.isEmpty ? snapshotMessage(snapshot) : detail
                        throw NativeExtensionHostError.cleanupIncomplete(
                            "runtime reported \(Self.stateName(state)) after a failed start: \(reason)"
                        )
                    }
                    cleanupTransport()
                    activeSessionId = nil
                    phase = .idle
                    if snapshot.state == Self.stateExited || snapshot.state == Self.stateFailed,
                       snapshot.exit_code != 0 || !detail.isEmpty {
                        throw NativeExtensionHostError.startExited(
                            code: Int(snapshot.exit_code),
                            message: detail.isEmpty ? snapshotMessage(snapshot) : detail
                        )
                    }
                    throw NativeExtensionHostError.startFailed(detail.isEmpty ? "Node runtime refused to start" : detail)
                }

                phase = .running
                startReturned = true
                flushPendingEvents()
                return sessionId
            } catch {
                activeSessionId = nil
                phase = .idle
                cleanupTransport()
                throw error
            }
        }
    }

    /// Completes only after all decoded wire bytes have been written to the host socket.

    func send(sessionId: Int, data base64: String,
              completion: @escaping (Result<Void, Error>) -> Void) {
        if usesLinuxHost {
            linuxHost.send(sessionId: sessionId, data: base64, completion: completion)
            return
        }
        do {
            try onQueue { try enqueueNativeWrite(sessionId: sessionId, base64: base64, completion: completion) }
        } catch {
            completion(.failure(error))
        }
    }

    func acknowledgeOutput(sessionId: Int, dataId: Int) throws {
        if usesLinuxHost {
            try linuxHost.acknowledgeOutput(sessionId: sessionId, dataId: dataId)
            return
        }
        try onQueue {
            guard outputCredits.acknowledge(sessionID: sessionId, dataID: dataId) != nil else {
                throw NativeExtensionHostError.transport("unknown or stale extension-host output acknowledgement")
            }
            connection?.resumeReadForOutputCredits()
        }
    }

    func failOutputDelivery(sessionId: Int, dataId: Int, reason: String) {
        if usesLinuxHost {
            linuxHost.failOutputDelivery(sessionId: sessionId, dataId: dataId, reason: reason)
            return
        }
        onQueue {
            guard outputCredits.contains(sessionID: sessionId, dataID: dataId) else { return }
            if phase == .idle {
                deliver(["kind": "exthost.transportError", "sessionId": sessionId,
                         "reason": "renderer did not receive extension-host output \(dataId): \(reason)"])
                return
            }
            failTransport("renderer did not receive extension-host output \(dataId): \(reason)")
        }
    }

    private func enqueueNativeWrite(sessionId: Int, base64: String,
                                    completion: @escaping (Result<Void, Error>) -> Void) throws {
        guard let activeSessionId, phase == .running || phase == .stopping else {
            throw NativeExtensionHostError.notRunning
        }
        guard sessionId == activeSessionId else { throw NativeExtensionHostError.staleSession(sessionId) }
        let encodedCount = base64.utf8.count
        guard (encodedCount / 4) * 3 <= Self.maxDecodedPayloadBytes,
              let data = Data(base64Encoded: base64), data.count <= Self.maxDecodedPayloadBytes else {
            throw NativeExtensionHostError.transport("invalid or oversized extension-host payload")
        }
        guard !data.isEmpty else { completion(.success(())); return }
        guard data.count <= Self.maxPendingWriteBytes - pendingWriteBytes,
              pendingWriteEvents < Self.maxPendingWriteEvents else {
            throw NativeExtensionHostError.transport("extension-host write queue is full")
        }
        pendingWriteBytes += data.count
        pendingWriteEvents += 1
        let completed: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self else { completion(result); return }
            self.pendingWriteBytes = max(0, self.pendingWriteBytes - data.count)
            self.pendingWriteEvents = max(0, self.pendingWriteEvents - 1)
            completion(result)
        }
        if let connection {
            connection.write(data, completion: completed)
        } else {
            pendingWrites.append(PendingHostWrite(data: data, completion: completed))
        }
    }

    /// Requests stop for the active generation. The exit event arrives via `onEvent`.
    func stop(sessionId: Int) throws {
        if linuxHost.currentSessionId == sessionId {
            try linuxHost.stop(sessionId: sessionId)
            return
        }
        try onQueue {
            guard let activeSessionId else { throw NativeExtensionHostError.notRunning }
            guard sessionId == activeSessionId else { throw NativeExtensionHostError.staleSession(sessionId) }
            guard let runtime else { throw NativeExtensionHostError.notRunning }
            phase = .stopping
            var error = [CChar](repeating: 0, count: Self.errorBufferSize)
            guard CodiPadNodeRuntimeRequestStop(runtime, &error, error.count) else {
                phase = .running
                let detail = String(cString: error)
                throw NativeExtensionHostError.stopFailed(detail.isEmpty ? "request stop failed" : detail)
            }
        }
    }

    /// Reuse this owner only after the old generation and its descendants have settled.
    func prepareForRendererReload(completion: @escaping (Result<Void, Error>) -> Void) {
        if usesLinuxHost {
            linuxHost.prepareForRendererReload(completion: completion)
            return
        }
        ioQueue.async { [self] in
            reloadReplies.append(completion)
            guard reloadReplies.count == 1 else { return }
            discardingRendererOutput = true
            outputCredits.discardForRendererTeardown()
            pendingEvents.removeAll()
            pendingEventBytes = 0
            connection?.resumeReadForOutputCredits()
            do {
                if let session = activeSessionId { try stop(sessionId: session) }
                finishRendererReload(attempt: 0)
            } catch { completeRendererReload(.failure(error)) }
        }
    }

    private func finishRendererReload(attempt: Int) {
        if activeSessionId != nil {
            guard attempt < 200 else {
                completeRendererReload(.failure(NativeExtensionHostError.cleanupIncomplete("renderer teardown did not reach host exit and protocol EOF")))
                return
            }
            ioQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
                finishRendererReload(attempt: attempt + 1)
            }
            return
        }
        if let runtime {
            var error = [CChar](repeating: 0, count: Self.errorBufferSize)
            guard CodiPadNodeRuntimeDestroy(runtime, &error, error.count) else {
                quarantine("renderer teardown could not join the runtime thread")
                completeRendererReload(.failure(NativeExtensionHostError.cleanupIncomplete(String(cString: error))))
                return
            }
            self.runtime = nil
            if let context = retainedContext {
                retainedContext = nil
                Unmanaged<NativeExtensionHost>.fromOpaque(context).release()
            }
        }
        var cleanup = codipad_node_process_cleanup_snapshot()
        codipad_node_process_get_cleanup_snapshot(&cleanup)
        guard cleanup.host_active == 0, cleanup.remaining_sessions == 0 else {
            quarantine("renderer teardown retains owned child processes")
            completeRendererReload(.failure(NativeExtensionHostError.cleanupIncomplete("owned child processes have not settled")))
            return
        }
        guard protocolEOF else {
            guard attempt < 200 else {
                completeRendererReload(.failure(NativeExtensionHostError.cleanupIncomplete("extension protocol has not reached EOF")))
                return
            }
            ioQueue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
                finishRendererReload(attempt: attempt + 1)
            }
            return
        }
        cleanupTransport()
        phase = .idle
        incompleteCleanup = false
        Self.leaveQuarantine(self)
        completeRendererReload(.success(()))
    }

    private func completeRendererReload(_ result: Result<Void, Error>) {
        if case .success = result, let event = retiringExitEvent {
            retiringExitEvent = nil
            // Retirement runs after start's queue turn; cleanup has already reset its gate.
            deliver(event)
        }
        let replies = reloadReplies
        reloadReplies.removeAll()
        for reply in replies { reply(result) }
    }

    /// Stops and destroys the runtime. Safe to call once, before releasing the owner.
    func shutdown() {
        linuxHost.shutdown()
        onQueue {
            guard let runtime else {
                leaseOwner = nil
                return
            }
            if phase != .idle {
                var stopError = [CChar](repeating: 0, count: Self.errorBufferSize)
                _ = CodiPadNodeRuntimeRequestStop(runtime, &stopError, stopError.count)
            }
            activeSessionId = nil
            phase = .idle
            cleanupTransport()
            var error = [CChar](repeating: 0, count: Self.errorBufferSize)
            guard CodiPadNodeRuntimeDestroy(runtime, &error, error.count) else {
                // Destroy did not join the host thread. Keep the runtime, the scope owner and the
                // retained callback context, and quarantine this host so nothing is released
                // under a live environment. ARC cannot drop it while the static list holds it.
                quarantine("Destroy did not join the host thread: \(String(cString: error))")
                onEvent = nil
                return
            }
            self.runtime = nil
            incompleteCleanup = false
            Self.leaveQuarantine(self)
            // Environment gone and host thread joined: scopes may drop now.
            leaseOwner = nil
            onEvent = nil
            // Last: the closure capture keeps `self` alive across this release.
            if let context = retainedContext {
                retainedContext = nil
                Unmanaged<NativeExtensionHost>.fromOpaque(context).release()
            }
        }
    }

    var currentSessionId: Int? {
        linuxHost.currentSessionId ?? onQueue { activeSessionId }
    }

    /// True when a previous generation could not be stopped and destroyed. No new start is
    /// accepted in that state; the host stays alive (quarantined) so callback contexts and
    /// security-scope owners are not released under a possibly running environment.
    var cleanupIncomplete: Bool {
        linuxHost.cleanupIncomplete || onQueue { incompleteCleanup }
    }

    // MARK: - Runtime callbacks

    fileprivate func receiveSnapshot(_ snapshot: CodiPadNodeSnapshot) {
        var copy = snapshot
        let message = withUnsafePointer(to: &copy.message) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 192) { String(cString: $0) }
        }
        let state = snapshot.state
        let exitCode = snapshot.exit_code
        ioQueue.async { [weak self] in
            self?.apply(state: state, exitCode: exitCode, message: message)
        }
    }

    private func apply(state: Int32, exitCode: Int32, message: String) {
        if state == Self.stateRunning, phase == .starting {
            phase = .running
            return
        }
        guard state == Self.stateExited || state == Self.stateFailed else { return }
        if !exitEmitted {
            exitEmitted = true
            if let sessionId = activeSessionId {
                let reason: String
                if let failure = transportFailureReason, !failure.isEmpty {
                    reason = message.isEmpty ? "transport: \(failure)" : "\(message); transport: \(failure)"
                } else {
                    reason = message
                }
                retiringExitEvent = [
                    "kind": "exthost.exit",
                    "sessionId": sessionId,
                    "code": Int(exitCode),
                    "reason": reason,
                ]
            }
        }
        failingTransport = false
        transportFailureReason = nil
        activeSessionId = nil
        phase = .stopping
        // Normal exit and renderer death share retirement. Joining the producer may release
        // its last writer, so keep the reader alive while destroying the exited runtime.
        prepareForRendererReload { _ in }
    }

    // MARK: - Socket transport

    private func accept(fd: Int32) {
        guard phase == .running || phase == .starting else {
            Darwin.close(fd)
            return
        }
        guard connection == nil else {
            // One generation, one transport. Refuse a second peer instead of mixing streams.
            Darwin.close(fd)
            return
        }
        let connection = UNIXSocketConnection(fd: fd, queue: ioQueue)
        connection.onData = { [weak self] data in self?.receive(data) }
        protocolEOF = false
        connection.onEOF = { [weak self] in self?.protocolEOF = true }
        connection.onClose = { [weak self] in self?.transportClosed() }
        self.connection = connection
        let buffered = pendingWrites
        pendingWrites.removeAll()
        connection.readAllowance = { [weak self] in self?.nextOutputReadCapacity ?? 0 }
        for pending in buffered {
            connection.write(pending.data, completion: pending.completion)
        }
    }

    private func receive(_ data: Data) {
        guard !discardingRendererOutput else { return }
        guard let sessionId = activeSessionId else { return }
        guard let dataId = reserveOutput(sessionId: sessionId, bytes: data.count) else {
            failTransport("extension-host output exceeded its byte or event credit bound")
            return
        }
        emit([
            "kind": "exthost.data",
            "sessionId": sessionId,
            "dataId": dataId,
            "byteCount": data.count,
            "data": data.base64EncodedString(),
        ])
        if nextOutputReadCapacity == 0 { connection?.pauseReadForOutputCredits() }
    }

    private var nextOutputReadCapacity: Int {
        if discardingRendererOutput { return 64 * 1024 }
        guard outputCredits.remainingEventCapacity > 0 else { return 0 }
        return min(64 * 1024, outputCredits.remainingByteCapacity)
    }

    private func reserveOutput(sessionId: Int, bytes: Int) -> Int? {
        outputCredits.reserve(sessionID: sessionId, byteCount: bytes)
    }

    private func transportClosed() {
        connection = nil
        guard !discardingRendererOutput, !failingTransport else { return }
        guard phase != .idle else { return }
        // No fabricated exit here: ask the host to stop and let the C snapshot report the
        // real exit code and reason once the environment is disposed.
        failTransport("transport closed by the peer")
    }

    private func transportFailed(_ message: String) {
        failTransport(message)
    }

    /// Fails the transport without pretending the Node environment exited.
    ///
    /// Buffered bytes are dropped because partial framing cannot be delivered; the renderer
    /// gets an immediate `exthost.transportError` so it can fail the handshake, and the real
    /// `exthost.exit` follows from the C Exited/Failed snapshot.
    private func failTransport(_ reason: String) {
        guard phase != .idle, !failingTransport else { return }
        failingTransport = true
        transportFailureReason = reason
        pendingEvents.removeAll()
        pendingEventBytes = 0
        listener?.close()
        listener = nil
        connection?.close(reason: reason)
        connection = nil
        let failedPendingWrites = pendingWrites
        pendingWrites.removeAll()
        let writeError = NativeExtensionHostError.transport(reason)
        for pending in failedPendingWrites { pending.completion(.failure(writeError)) }
        if let sessionId = activeSessionId {
            deliver([
                "kind": "exthost.transportError",
                "sessionId": sessionId,
                "reason": reason,
            ])
        } else {
            print("codipad-exthost transportError: \(reason)")
        }
        if let runtime {
            var error = [CChar](repeating: 0, count: Self.errorBufferSize)
            _ = CodiPadNodeRuntimeRequestStop(runtime, &error, error.count)
        }
    }

    private func cleanupTransport() {
        connection?.close(reason: "extension-host generation ended before pending writes completed")
        connection = nil
        listener?.close()
        listener = nil
        let failedPendingWrites = pendingWrites
        pendingWrites.removeAll()
        let failure = NativeExtensionHostError.transport("extension-host generation ended before pending writes completed")
        for pending in failedPendingWrites { pending.completion(.failure(failure)) }
        pendingEvents.removeAll()
        pendingEventBytes = 0
        failingTransport = false
        transportFailureReason = nil
        startReturned = false
    }

    // MARK: - Bootstrap

    private func quarantine(_ reason: String) {
        incompleteCleanup = true
        Self.quarantineLock.lock()
        if !Self.quarantined.contains(where: { $0 === self }) {
            Self.quarantined.append(self)
        }
        Self.quarantineLock.unlock()
        // Visible diagnostic: the bridge can also read `cleanupIncomplete`.
        print("codipad-exthost cleanupIncomplete: \(reason)")
    }

    private static func leaveQuarantine(_ host: NativeExtensionHost) {
        quarantineLock.lock()
        quarantined.removeAll { $0 === host }
        quarantineLock.unlock()
    }

    private static func nextSessionId() -> Int {
        sessionCounterLock.lock()
        defer { sessionCounterLock.unlock() }
        sessionCounter += 1
        return sessionCounter
    }

    private func ensureRuntime() throws {
        guard runtime == nil else { return }
        // Node derives process.execPath with uv_exepath(), which uses POSIX realpath on Darwin.
        // Register that same identity before the host starts so ordinary fork() can select the
        // Linux Node backend without changing the native host's reported platform or executable.
        guard let executable = Bundle.main.executableURL,
              let canonicalExecutable = realpath(executable.path, nil) else {
            throw NativeExtensionHostError.runtimeUnavailable("the app executable identity is unavailable")
        }
        defer { free(canonicalExecutable) }
        let identityResult = codipad_node_set_self_exec_identity(canonicalExecutable)
        guard identityResult == 0 else {
            throw NativeExtensionHostError.runtimeUnavailable("cannot configure Node child execution (\(identityResult))")
        }
        #if CODIPAD_ENABLE_SHARED_EXECUTION
        try NativeExecutionPages.prepare()
        #endif
        var options = CodiPadNodeRuntimeOptions()
        options.use_debugger_prepared_pages = useDebuggerPreparedPages ? 1 : 0
        // The C API keeps a raw context pointer; retain self for as long as callbacks can fire.
        let context = Unmanaged.passRetained(self).toOpaque()
        guard let created = CodiPadNodeRuntimeCreateWithOptions(&options, codipadNodeEventCallback, context) else {
            Unmanaged<NativeExtensionHost>.fromOpaque(context).release()
            throw NativeExtensionHostError.runtimeUnavailable("CodiPadNodeRuntimeCreateWithOptions returned null")
        }
        runtime = created
        retainedContext = context
    }

    private func artifactPath(in directory: URL) throws -> String {
        let file = directory.appendingPathComponent("extensionHostProcess.js")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw NativeExtensionHostError.artifactMissing(file.path)
        }
        return file.path
    }

    /// Short UNIX socket path. `sun_path` is 104 bytes including the terminator.
    private func makeSocketPath() throws -> String {
        // `sun_path` is 104 bytes; the app-container temp directory alone is ~90 on iOS.
        let short = String(UUID().uuidString.prefix(6))
        #if targetEnvironment(simulator)
        let base = "/tmp"
        #else
        let base = NSTemporaryDirectory()
        #endif
        let directory = base.hasSuffix("/") ? base : base + "/"
        let candidate = directory + "e" + short + ".s"
        guard candidate.utf8.count <= 103 else {
            throw NativeExtensionHostError.socketPathTooLong(candidate.utf8.count)
        }
        return candidate
    }

    private func environmentSnapshotJSON(_ guestEnvironment: [String: String],
                                        socketPath: String, bundlePath: String) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(guestEnvironment) { _, guestValue in guestValue }
        environment["VSCODE_EXTHOST_IPC_HOOK"] = socketPath
        environment["CODIPAD_MANAGED_EXTENSION_HOST"] = "1"
        let searchHelper = URL(fileURLWithPath: bundlePath).deletingLastPathComponent().appendingPathComponent("bin/rg")
        guard let searchPath = realpath(searchHelper.path, nil) else {
            throw NativeExtensionHostError.startFailed("the packaged search executable is missing")
        }
        environment["VSCODE_RIPGREP_PATH"] = String(cString: searchPath)
        free(searchPath)
        guard JSONSerialization.isValidJSONObject(environment),
              let data = try? JSONSerialization.data(withJSONObject: environment, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            throw NativeExtensionHostError.startFailed("could not encode the extension environment")
        }
        return json
    }

    /// The launch source is built here, never taken from page content.
    private func bootstrapScript(bundlePath: String) -> String {
        return """
        const { createRequire } = require('module');
        const bundle = \(jsonLiteral(bundlePath));
        createRequire(bundle)(bundle);
        """
    }

    private func jsonLiteral(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "null"
        }
        return text
    }

    private func copySnapshot(_ runtime: OpaquePointer) -> CodiPadNodeSnapshot {
        CodiPadNodeRuntimeGetSnapshot(runtime)
    }

    private func snapshotMessage(_ snapshot: CodiPadNodeSnapshot) -> String {
        var copy = snapshot
        return withUnsafePointer(to: &copy.message) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 192) { String(cString: $0) }
        }
    }

    // MARK: - Events

    private func emit(_ event: [String: Any]) {
        if startReturned {
            deliver(event)
            return
        }
        let size = Self.approximateEventBytes(event)
        if size > Self.maxBufferedEventBytes || pendingEventBytes + size > Self.maxBufferedEventBytes {
            // Dropping an oldest chunk would cut PersistentProtocol framing and corrupt the
            // stream. Fail the whole transport visibly instead; the C snapshot still decides
            // the real exit status afterwards.
            failTransport("reverse event buffer exceeded \(Self.maxBufferedEventBytes) bytes")
            return
        }
        pendingEvents.append(event)
        pendingEventBytes += size
    }

    private static func approximateEventBytes(_ event: [String: Any]) -> Int {
        if let data = event["data"] as? String { return data.utf8.count }
        return 128
    }

    private func flushPendingEvents() {
        let events = pendingEvents
        pendingEvents.removeAll()
        pendingEventBytes = 0
        for event in events {
            deliver(event)
        }
    }

    private func deliver(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    // MARK: - Queue helper

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try ioQueue.sync(execute: body)
    }

    // MARK: - State constants

    private static let stateIdle = Int32(CodiPadNodeStateIdle.rawValue)
    private static let stateStarting = Int32(CodiPadNodeStateStarting.rawValue)
    private static let stateRunning = Int32(CodiPadNodeStateRunning.rawValue)
    private static let stateStopping = Int32(CodiPadNodeStateStopping.rawValue)
    private static let stateExited = Int32(CodiPadNodeStateExited.rawValue)
    private static let stateFailed = Int32(CodiPadNodeStateFailed.rawValue)

    private static func stateName(_ state: Int32) -> String {
        switch state {
        case stateIdle: return "Idle"
        case stateStarting: return "Starting"
        case stateRunning: return "Running"
        case stateStopping: return "Stopping"
        case stateExited: return "Exited"
        case stateFailed: return "Failed"
        default: return "Unknown(\(state))"
        }
    }
}

// MARK: - C callback

private func codipadNodeEventCallback(
    _ context: UnsafeMutableRawPointer?,
    _ snapshot: UnsafePointer<CodiPadNodeSnapshot>?
) {
    guard let context, let snapshot else { return }
    let host = Unmanaged<NativeExtensionHost>.fromOpaque(context).takeUnretainedValue()
    host.receiveSnapshot(snapshot.pointee)
}

// MARK: - Errors

enum NativeExtensionHostError: LocalizedError, CustomStringConvertible {
    case alreadyRunning
    case notRunning
    case staleSession(Int)
    case artifactMissing(String)
    case socketPathTooLong(Int)
    case socketSetup(String)
    case runtimeUnavailable(String)
    case startFailed(String)
    case startExited(code: Int, message: String)
    case cleanupIncomplete(String)
    case stopFailed(String)
    case transport(String)

    var code: String {
        switch self {
        case .alreadyRunning: return "AlreadyRunning"
        case .notRunning: return "NotRunning"
        case .staleSession: return "StaleSession"
        case .artifactMissing: return "ArtifactMissing"
        case .socketPathTooLong: return "SocketPathTooLong"
        case .socketSetup: return "SocketSetup"
        case .runtimeUnavailable: return "RuntimeUnavailable"
        case .startFailed: return "StartFailed"
        case .startExited: return "StartExited"
        case .cleanupIncomplete: return "CleanupIncomplete"
        case .stopFailed: return "StopFailed"
        case .transport: return "Transport"
        }
    }

    var message: String {
        switch self {
        case .alreadyRunning: return "a host generation is already active"
        case .notRunning: return "no host generation is active"
        case .staleSession(let id): return "session \(id) is not the active generation"
        case .artifactMissing(let detail): return "extension host bundle missing: \(detail)"
        case .socketPathTooLong(let length): return "UNIX socket path is \(length) bytes (limit 103)"
        case .socketSetup(let detail): return "could not set up the host transport: \(detail)"
        case .runtimeUnavailable(let detail): return detail
        case .startFailed(let detail): return detail
        case .startExited(let code, let message): return "host exited during start (code \(code)): \(message)"
        case .cleanupIncomplete(let detail): return "host cleanup is incomplete; no new start is accepted: \(detail)"
        case .stopFailed(let detail): return detail
        case .transport(let detail): return detail
        }
    }

    var errorDescription: String? { message }
    var description: String { "\(code): \(message)" }
}

// MARK: - UNIX listener

private final class UNIXSocketListener {
    let path: String
    private let queue: DispatchQueue
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    var onAccept: ((Int32) -> Void)?
    var onFailure: ((String) -> Void)?

    init(path: String, queue: DispatchQueue) throws {
        self.path = path
        self.queue = queue
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NativeExtensionHostError.socketSetup("socket: \(String(cString: strerror(errno)))")
        }
        unlink(path)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw NativeExtensionHostError.socketSetup("bind: \(detail)")
        }
        guard listen(descriptor, 1) == 0 else {
            let detail = String(cString: strerror(errno))
            Darwin.close(descriptor)
            unlink(path)
            throw NativeExtensionHostError.socketSetup("listen: \(detail)")
        }
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
        source.resume()
        self.source = source
    }

    private func acceptPending() {
        var address = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let client = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(descriptor, $0, &length) }
        }
        guard client >= 0 else {
            if errno != EAGAIN && errno != EWOULDBLOCK {
                onFailure?("accept: \(String(cString: strerror(errno)))")
            }
            return
        }
        let flags = fcntl(client, F_GETFL, 0)
        _ = fcntl(client, F_SETFL, flags | O_NONBLOCK)
        var noSigPipe: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        onAccept?(client)
    }

    func close() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    deinit {
        close()
    }
}

// MARK: - UNIX connection

private final class UNIXSocketConnection {
    private struct WriteItem {
        let data: Data
        var offset = 0
        let completion: (Result<Void, Error>) -> Void
    }

    private let descriptor: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeQueue: [WriteItem] = []
    private var writeBytes = 0
    private var closed = false
    private var readPaused = false
    private let maxWriteBytes = 4 * 1024 * 1024
    private let maxWriteChunks = 1024

    var onData: ((Data) -> Void)?
    var onEOF: (() -> Void)?
    var onClose: (() -> Void)?
    var readAllowance: (() -> Int)?

    init(fd: Int32, queue: DispatchQueue) {
        descriptor = fd
        self.queue = queue

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.read() }
        readSource.setCancelHandler { [fd] in Darwin.close(fd) }
        readSource.resume()
        self.readSource = readSource
    }

    func write(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !closed else {
            completion(.failure(NativeExtensionHostError.transport("extension-host socket is closed")))
            return
        }
        guard data.count <= maxWriteBytes - writeBytes, writeQueue.count < maxWriteChunks else {
            completion(.failure(NativeExtensionHostError.transport("extension-host socket write queue is full")))
            return
        }
        writeQueue.append(WriteItem(data: data, completion: completion))
        writeBytes += data.count
        flush()
    }

    private func flush() {
        guard !closed else { return }
        while !writeQueue.isEmpty {
            let index = writeQueue.startIndex
            let remaining = writeQueue[index].data.count - writeQueue[index].offset
            let written = writeQueue[index].data.withUnsafeBytes { pointer in
                Darwin.send(descriptor, pointer.baseAddress!.advanced(by: writeQueue[index].offset), remaining, 0)
            }
            if written > 0 {
                writeBytes -= written
                writeQueue[index].offset += written
                if writeQueue[index].offset == writeQueue[index].data.count {
                    let completed = writeQueue.removeFirst()
                    completed.completion(.success(()))
                }
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                installWriteSource()
                return
            } else {
                let code = written == 0 ? EIO : errno
                close(reason: "extension-host socket write failed: \(String(cString: strerror(code)))")
                return
            }
        }
        cancelWriteSource()
    }

    private func installWriteSource() {
        guard writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.flush() }
        source.resume()
        writeSource = source
    }

    private func cancelWriteSource() {
        writeSource?.cancel()
        writeSource = nil
    }

    private func read() {
        guard !closed else { return }
        while true {
            let allowance = readAllowance?() ?? 64 * 1024
            guard allowance > 0 else { pauseReadForOutputCredits(); return }
            var buffer = [UInt8](repeating: 0, count: min(64 * 1024, allowance))
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                onData?(Data(buffer[0..<count]))
            } else if count == 0 {
                onEOF?()
                close()
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                close()
                return
            }
        }
    }

    func pauseReadForOutputCredits() {
        guard !closed, !readPaused, let readSource else { return }
        readPaused = true
        readSource.suspend()
    }

    func resumeReadForOutputCredits() {
        guard !closed, readPaused, (readAllowance?() ?? 0) > 0, let readSource else { return }
        readPaused = false
        readSource.resume()
    }

    func close(reason: String = "extension-host socket closed") {
        guard !closed else { return }
        closed = true
        if readPaused { readSource?.resume(); readPaused = false }
        readSource?.cancel()
        readSource = nil
        cancelWriteSource()
        let error = NativeExtensionHostError.transport(reason)
        let failed = writeQueue
        writeQueue.removeAll()
        writeBytes = 0
        for item in failed { item.completion(.failure(error)) }
        onClose?()
    }

    deinit {
        close()
    }
}
