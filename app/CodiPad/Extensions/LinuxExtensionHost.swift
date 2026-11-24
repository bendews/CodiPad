import Darwin
import Foundation

/// Serial-queue-owned write pump. Closing it invalidates the descriptor before delivering pending
/// failures, so completion callbacks cannot enqueue work against a closed socket.
private final class LinuxExtensionHostWritePump {
    private struct PendingWrite {
        let data: Data
        var offset = 0
        let completion: (Result<Void, Error>) -> Void
    }

    private let queue: DispatchQueue
    private let maxBytes: Int
    private let maxEvents: Int
    private let onFailure: (String) -> Void
    private var descriptor: Int32
    private var source: DispatchSourceWrite?
    private var writes: [PendingWrite] = []
    private var pendingBytes = 0
    private var closed = false

    init(fd: Int32, queue: DispatchQueue, maxBytes: Int = 4 * 1024 * 1024,
         maxEvents: Int = 1024, onFailure: @escaping (String) -> Void) {
        self.descriptor = fd
        self.queue = queue
        self.maxBytes = maxBytes
        self.maxEvents = maxEvents
        self.onFailure = onFailure
    }

    func enqueue(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) throws {
        guard !closed, descriptor >= 0 else {
            throw NativeExtensionHostError.transport("Linux extension-host socket is closed")
        }
        guard data.count <= maxBytes - pendingBytes, writes.count < maxEvents else {
            throw NativeExtensionHostError.transport("Linux extension-host write queue is full")
        }
        guard !data.isEmpty else { completion(.success(())); return }
        writes.append(PendingWrite(data: data, completion: completion))
        pendingBytes += data.count
        if source == nil {
            guard !closed, descriptor >= 0 else {
                close(error: NativeExtensionHostError.transport("Linux extension-host socket is closed"))
                throw NativeExtensionHostError.transport("Linux extension-host socket is closed")
            }
            let writeSource = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
            writeSource.setEventHandler { [weak self] in self?.writeAvailable() }
            writeSource.setCancelHandler {}
            writeSource.resume()
            source = writeSource
        }
        writeAvailable()
    }

    func close(error: Error) {
        guard !closed else { return }
        closed = true
        descriptor = -1
        source?.cancel()
        source = nil
        let failed = writes
        writes.removeAll()
        pendingBytes = 0
        for write in failed { write.completion(.failure(error)) }
    }

    private func writeAvailable() {
        guard !closed, descriptor >= 0 else { return }
        while !writes.isEmpty {
            guard !closed, descriptor >= 0 else { return }
            let index = writes.startIndex
            let remaining = writes[index].data.count - writes[index].offset
            let written = writes[index].data.withUnsafeBytes { raw in
                Darwin.send(descriptor, raw.baseAddress!.advanced(by: writes[index].offset), remaining, 0)
            }
            if written > 0 {
                writes[index].offset += written
                if writes[index].offset == writes[index].data.count {
                    let completed = writes.removeFirst()
                    pendingBytes -= completed.data.count
                    completed.completion(.success(()))
                }
            } else if written < 0 && errno == EINTR { continue }
            else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return }
            else {
                let code = written == 0 ? EIO : errno
                let reason = "Linux extension-host socket write failed: \(String(cString: strerror(code)))"
                let error = NativeExtensionHostError.transport(reason)
                close(error: error)
                onFailure(reason)
                return
            }
        }
        source?.cancel()
        source = nil
    }
}

/// Linux Node extension host used by Gadget Only, StikDebug and debugger-prepared Linux launches.
///
/// The child is a root session in the shared iSH authority. Its fd 3 is one end of a connected
/// socketpair, and the other end carries the upstream PersistentProtocol bytes to the workbench.
/// Session exit is reported only after the authority's settled callback and close confirmation.
final class LinuxExtensionHost {
    typealias EventHandler = ([String: Any]) -> Void

    private struct OutputFrame {
        let sessionID: Int
        let dataID: Int
        let data: Data
    }

    private enum Phase { case idle, running, stopping, incomplete }
    private let queue = DispatchQueue(label: "dev.codipad.linux-exthost", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private var phase: Phase = .idle
    private var session: UInt64?
    private var authorityOwner: UInt64?
    private var hostFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writePump: LinuxExtensionHostWritePump?
    private var output: [OutputFrame] = []
    private let outputCredits = ExtensionHostOutputCredits()
    private var reloadReplies: [(Result<Void, Error>) -> Void] = []
    private var discardingRendererOutput = false
    private var protocolEOF = true
    private var readPaused = false
    private var outputDrainScheduled = false
    private var leaderStatus: (Int32, Int32)?
    private var settledStatus: (Int32, Int32)?
    private var callbackContext: UnsafeMutableRawPointer?
    private var leaseOwner: AnyObject?
    /// Retain the original per-window mount adapters until this generation settles and EOF arrives.
    private var runtimeOwner: AnyObject?
    private var incompleteReason: String?
    private var transportFailureEmitted = false

    var onEvent: EventHandler?

    init() { queue.setSpecific(key: queueKey, value: ()) }

    var currentSessionId: Int? {
        onQueue { session.flatMap(Self.safeInt) }
    }

    var cleanupIncomplete: Bool { onQueue { phase == .incomplete } }

    func start(bundlePath: String, environment: [String: String], processCwd: String,
               leaseOwner: AnyObject?, runtimeOwner: AnyObject) throws -> Int {
        try onQueue {
            guard phase == .idle, session == nil else {
                throw NativeExtensionHostError.alreadyRunning
            }
            guard !outputCredits.hasOutstanding else {
                throw NativeExtensionHostError.cleanupIncomplete("previous generation still has unacknowledged output")
            }
            guard reloadReplies.isEmpty else { throw NativeExtensionHostError.alreadyRunning }
            guard processCwd.hasPrefix("/"), !processCwd.contains("\0") else {
                throw NativeExtensionHostError.startFailed("Linux extension host requires an absolute authorized process directory")
            }
            guard bundlePath.hasPrefix("/"), !bundlePath.contains("\0") else {
                throw NativeExtensionHostError.artifactMissing("verified extension-host root is not guest-addressable")
            }
            let entrypoint = URL(fileURLWithPath: bundlePath).appendingPathComponent("extensionHostProcess.js").path
            guard FileManager.default.fileExists(atPath: entrypoint) else {
                throw NativeExtensionHostError.artifactMissing(entrypoint)
            }

            var launchEnvironment = environment
            launchEnvironment["VSCODE_IPAD_EXTHOST_FD"] = "3"
            launchEnvironment["CODIPAD_MANAGED_EXTENSION_HOST"] = "1"
            launchEnvironment["VSCODE_RIPGREP_PATH"] = URL(fileURLWithPath: bundlePath)
                .appendingPathComponent("bin/rg").path
            let envStrings = try launchEnvironment.map { key, value -> String in
                guard !key.isEmpty, !key.contains("="), !key.contains("\0"), !value.contains("\0") else {
                    throw NativeExtensionHostError.startFailed("invalid Linux extension-host environment entry")
                }
                return "\(key)=\(value)"
            }.sorted()
            var idOwner: UInt64 = 0
            let reservation = codipad_kernel_reserve_owner_generation(&idOwner)
            guard reservation == 0 else {
                throw NativeExtensionHostError.startFailed("Cannot reserve Linux host generation: \(Self.posixMessage(-reservation))")
            }
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
                throw NativeExtensionHostError.socketSetup("socketpair: \(Self.posixMessage(errno))")
            }
            let parent = pair[0]
            let child = pair[1]
            guard Self.configureSocket(parent), Self.configureSocket(child) else {
                let code = errno
                Darwin.close(parent); Darwin.close(child)
                throw NativeExtensionHostError.socketSetup("cannot configure inherited socket: \(Self.posixMessage(code))")
            }
            let argvStrings = ["/usr/local/bin/node", entrypoint]
            let context = Unmanaged.passRetained(self).toOpaque()
            callbackContext = context
            self.leaseOwner = leaseOwner
            self.runtimeOwner = runtimeOwner
            let borrowedFDs: [Int32] = [-1, STDOUT_FILENO, STDERR_FILENO, child]
            let modes: [UInt8] = [UInt8(CODIPAD_HOST_FD_READ), UInt8(CODIPAD_HOST_FD_WRITE),
                                  UInt8(CODIPAD_HOST_FD_WRITE), UInt8(CODIPAD_HOST_FD_READ_WRITE)]
            var options = codipad_spawn_opts()
            options.cols = 80
            options.rows = 24
            options.on_output = nil
            options.on_exit = linuxExtensionHostExit
            options.on_settled = linuxExtensionHostSettled
            options.ctx = context
            options.stdio_mode = CODIPAD_STDIO_HOST_FDS
            options.stdio_host_fd_count = borrowedFDs.count
            options.owner = idOwner
            var spawned: codipad_session_t = 0
            let result = "/usr/local/bin/node".withCString { executable in
                processCwd.withCString { cwd in
                    withCStringArray(argvStrings) { argv in
                        withCStringArray(envStrings) { envp in
                            borrowedFDs.withUnsafeBufferPointer { fds in
                                modes.withUnsafeBufferPointer { accessModes in
                                    options.exe = executable
                                    options.cwd = cwd
                                    options.argv = UnsafeRawPointer(argv.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                                    options.envp = UnsafeRawPointer(envp.baseAddress!).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                                    options.stdio_host_fds = fds.baseAddress
                                    options.stdio_host_modes = accessModes.baseAddress
                                    return withUnsafePointer(to: &options) { codipad_kernel_spawn($0, &spawned) }
                                }
                            }
                        }
                    }
                }
            }
            Darwin.close(child)
            guard result == 0 else {
                Darwin.close(parent)
                callbackContext = nil
                self.leaseOwner = nil
                self.runtimeOwner = nil
                Unmanaged<LinuxExtensionHost>.fromOpaque(context).release()
                throw NativeExtensionHostError.startFailed("Linux extension-host spawn failed: \(Self.posixMessage(-result))")
            }
            guard let safeID = Self.safeInt(spawned) else {
                // The authority already created a process. Retain its callback and both owners
                // until settlement; the closed reader makes EOF unprovable, so quarantine it.
                session = spawned
                authorityOwner = idOwner
                phase = .incomplete
                incompleteReason = "process authority returned an unrepresentable host session id"
                protocolEOF = false
                leaderStatus = nil
                settledStatus = nil
                hostFD = -1
                Darwin.close(parent)
                _ = codipad_kernel_signal(spawned, SIGKILL)
                throw NativeExtensionHostError.startFailed("process authority returned an unrepresentable host session id")
            }

            hostFD = parent
            session = spawned
            authorityOwner = idOwner
            phase = .running
            writePump = LinuxExtensionHostWritePump(fd: parent, queue: queue) { [weak self] reason in
                self?.failTransport(reason)
            }
            discardingRendererOutput = false
            protocolEOF = false
            leaderStatus = nil
            settledStatus = nil
            transportFailureEmitted = false
            readPaused = false
            let read = DispatchSource.makeReadSource(fileDescriptor: parent, queue: queue)
            read.setEventHandler { [weak self] in self?.readAvailable() }
            read.setCancelHandler { [parent] in Darwin.close(parent) }
            read.resume()
            readSource = read
            return safeID
        }
    }

    func send(sessionId: Int, data base64: String,
              completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try onQueue { try enqueueWrite(sessionId: sessionId, base64: base64, completion: completion) }
        } catch {
            completion(.failure(error))
        }
    }

    func acknowledgeOutput(sessionId: Int, dataId: Int) throws {
        try onQueue {
            guard outputCredits.acknowledge(sessionID: sessionId, dataID: dataId) != nil else {
                throw NativeExtensionHostError.transport("unknown or stale extension-host output acknowledgement")
            }
            resumeReadAfterAcknowledgement(sessionID: sessionId)
        }
    }

    func failOutputDelivery(sessionId: Int, dataId: Int, reason: String) {
        onQueue {
            guard outputCredits.contains(sessionID: sessionId, dataID: dataId) else { return }
            let message = "renderer did not receive extension-host output \(dataId): \(reason)"
            guard phase != .idle, self.session.flatMap(Self.safeInt) == sessionId else {
                emitTransportError(message, sessionID: sessionId)
                return
            }
            failTransport(message)
        }
    }

    private func enqueueWrite(sessionId: Int, base64: String,
                              completion: @escaping (Result<Void, Error>) -> Void) throws {
        guard phase == .running, hostFD >= 0, writePump != nil, let session,
              Self.safeInt(session) == sessionId else {
            throw NativeExtensionHostError.staleSession(sessionId)
        }
        guard base64.utf8.count <= 5_592_408,
              let data = Data(base64Encoded: base64), data.count <= 4 * 1024 * 1024 else {
            throw NativeExtensionHostError.transport("invalid or oversized extension-host payload")
        }
        guard !data.isEmpty else { completion(.success(())); return }
        guard hostFD >= 0, phase == .running, let writePump else {
            throw NativeExtensionHostError.staleSession(sessionId)
        }
        try writePump.enqueue(data, completion: completion)
    }

    func stop(sessionId: Int) throws {
        try onQueue {
            guard let session else { throw NativeExtensionHostError.notRunning }
            guard Self.safeInt(session) == sessionId else { throw NativeExtensionHostError.staleSession(sessionId) }
            guard phase == .running else { return }
            phase = .stopping
            let signalResult = codipad_kernel_signal(session, SIGTERM)
            guard signalResult == 0 || signalResult == -ESRCH || signalResult == -ENOENT ||
                    signalResult == -Int32(CODIPAD_EINCOMPLETE) else {
                phase = .incomplete
                incompleteReason = "cannot confirm graceful stop signal: \(Self.posixMessage(-signalResult))"
                throw NativeExtensionHostError.stopFailed(incompleteReason!)
            }
            if signalResult == -Int32(CODIPAD_EINCOMPLETE) {
                emitTransportError("graceful stop reached only part of the owned process tree; force-stop will follow")
            }
            scheduleForceStop(session)
        }
    }

    func prepareForRendererReload(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            reloadReplies.append(completion)
            guard reloadReplies.count == 1 else { return }
            discardingRendererOutput = true
            outputCredits.discardForRendererTeardown()
            output.removeAll()
            resumeReadAfterAcknowledgement(sessionID: 0)
            do {
                if settledStatus == nil, let session, let id = Self.safeInt(session) { try stop(sessionId: id) }
                finishRendererReload(attempt: 0)
            } catch { completeRendererReload(.failure(error)) }
        }
    }

    private func finishRendererReload(attempt: Int) {
        if session == nil, phase == .idle, protocolEOF {
            completeRendererReload(.success(()))
        } else if attempt < 200 {
            queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
                finishRendererReload(attempt: attempt + 1)
            }
        } else {
            completeRendererReload(.failure(NativeExtensionHostError.cleanupIncomplete(
                incompleteReason ?? "renderer teardown did not reach settlement and protocol EOF")))
        }
    }

    private func completeRendererReload(_ result: Result<Void, Error>) {
        let replies = reloadReplies
        reloadReplies.removeAll()
        for reply in replies { reply(result) }
    }

    func shutdown() {
        onQueue {
            guard let session else { return }
            if phase != .idle { _ = codipad_kernel_signal(session, SIGKILL) }
            phase = .incomplete
            incompleteReason = "shutdown requested; waiting for authority settlement"
        }
    }

    fileprivate func recordLeaderExit(session callbackSession: UInt64, code: Int32, signal: Int32,
                                       allReaped: Bool) {
        queue.async { [self] in
            guard self.session == callbackSession else { return }
            leaderStatus = (code, signal)
        }
    }

    fileprivate func recordSettled(session callbackSession: UInt64, code: Int32, signal: Int32,
                                   allReaped: Bool) {
        // Never close from inside the authority callback: its callback borrow is still counted
        // until this function returns, and close correctly waits for that borrow to leave.
        queue.async { [self] in
            guard self.session == callbackSession else { return }
            guard allReaped, let status = leaderStatus, status.0 == code, status.1 == signal else {
                phase = .incomplete
                incompleteReason = "settlement does not match the reaped leader status"
                return
            }
            finishSettled(code: code, signal: signal, attempt: 0)
        }
    }

    private func finishSettled(code: Int32, signal: Int32, attempt: Int) {
        guard let finishedSession = self.session else { return }
        if settledStatus == nil {
            // The callback borrow has now unwound. Transient in-flight authority users can still make
            // close_status return EINPROGRESS, so retry without releasing the generation or faking exit.
            var finalInfo = codipad_session_info()
            let result = codipad_kernel_close_status(finishedSession, 0, &finalInfo)
            if result == -EINPROGRESS, attempt < 40 {
                queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in
                    guard self.session == finishedSession else { return }
                    finishSettled(code: code, signal: signal, attempt: attempt + 1)
                }
                return
            }
            guard result == 0 || result == -ENOENT else {
                phase = .incomplete
                incompleteReason = "authority did not close settled host session: \(Self.posixMessage(-result))"
                emitTransportError(incompleteReason!)
                return
            }
            let remainingOwnedSessions = authorityOwner.map { codipad_kernel_sessions_for_owner($0, nil, 0) } ?? 0
            guard remainingOwnedSessions == 0 else {
                phase = .incomplete
                incompleteReason = "authority retains \(remainingOwnedSessions) owned session(s) after host close"
                emitTransportError(incompleteReason!)
                return
            }
            settledStatus = (code, signal)
        }
        // A failed reader cannot establish EOF. Keep ownership and report incomplete cleanup.
        if !protocolEOF && hostFD < 0 {
            phase = .incomplete
            incompleteReason = "extension-host output EOF unavailable after transport failure"
            return
        }
        // Close the settled producer first: the authority may hold the last writer fd.
        // Keep this reader and lease alive until a real zero-byte read arrives.
        phase = .stopping
        discardingRendererOutput = true
        outputCredits.discardForRendererTeardown()
        output.removeAll()
        resumeReadAfterAcknowledgement(sessionID: 0)
        guard protocolEOF else { return }
        let status = leaderStatus ?? (code, signal)
        self.session = nil
        authorityOwner = nil
        closeTransport(reason: "Linux extension-host generation settled before pending writes completed")
        phase = .idle
        leaseOwner = nil
        runtimeOwner = nil
        let event: [String: Any] = ["kind": "exthost.exit", "sessionId": Self.safeInt(finishedSession) as Any,
                                    "code": Int(status.0), "reason": status.1 == 0 ? "" : "terminated by signal \(status.1)"]
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
        if let callbackContext {
            self.callbackContext = nil
            Unmanaged<LinuxExtensionHost>.fromOpaque(callbackContext).release()
        }
    }

    private func readAvailable() {
        guard hostFD >= 0 else { return }
        while true {
            let remainingBytes = discardingRendererOutput ? 64 * 1024 : outputCredits.remainingByteCapacity
            guard remainingBytes > 0,
                  (discardingRendererOutput || outputCredits.remainingEventCapacity > 0) else {
                pauseReadForOutputCredits()
                return
            }
            var buffer = [UInt8](repeating: 0, count: min(64 * 1024, remainingBytes))
            let count = recv(hostFD, &buffer, buffer.count, 0)
            if count > 0 {
                if discardingRendererOutput { continue }
                let chunk = Data(buffer[0..<count])
                guard let session, let sessionID = Self.safeInt(session),
                      let dataID = reserveOutput(sessionID: sessionID, bytes: count) else {
                    failTransport("Linux extension-host output queue exceeded its bound")
                    return
                }
                output.append(OutputFrame(sessionID: sessionID, dataID: dataID, data: chunk))
                scheduleOutputDrain()
                if remainingOutputCapacityIsFull {
                    pauseReadForOutputCredits()
                    return
                }
            } else if count == 0 {
                protocolEOF = true
                if phase == .stopping {
                    closeTransport()
                    if let status = settledStatus {
                        finishSettled(code: status.0, signal: status.1, attempt: 0)
                    }
                    return
                }
                failTransport("Linux extension-host protocol socket closed", readUsable: false)
                return
            } else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else {
                failTransport("Linux extension-host socket read failed: \(Self.posixMessage(errno))", readUsable: false)
                return
            }
        }
    }

    private func scheduleOutputDrain() {
        guard !outputDrainScheduled else { return }
        outputDrainScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let item = self.onQueue { () -> OutputFrame? in
                guard !self.output.isEmpty else {
                    self.outputDrainScheduled = false
                    return nil
                }
                let first = self.output.removeFirst()
                return first
            }
            if let item {
                let event: [String: Any] = ["kind": "exthost.data", "sessionId": item.sessionID,
                                            "dataId": item.dataID, "byteCount": item.data.count,
                                            "data": item.data.base64EncodedString()]
                self.onEvent?(event)
                self.onQueue { self.outputDrainScheduled = false; self.scheduleOutputDrain() }
            }
        }
    }

    private var remainingOutputCapacityIsFull: Bool {
        outputCredits.remainingByteCapacity == 0 || outputCredits.remainingEventCapacity == 0
    }

    private func reserveOutput(sessionID: Int, bytes: Int) -> Int? {
        outputCredits.reserve(sessionID: sessionID, byteCount: bytes)
    }

    private func pauseReadForOutputCredits() {
        guard !readPaused, let readSource else { return }
        readPaused = true
        readSource.suspend()
    }

    private func resumeReadAfterAcknowledgement(sessionID _: Int) {
        guard readPaused, outputCredits.remainingByteCapacity > 0,
              outputCredits.remainingEventCapacity > 0,
              let readSource else { return }
        readPaused = false
        readSource.resume()
    }

    private func failTransport(_ reason: String, readUsable: Bool = true) {
        guard !transportFailureEmitted else {
            if !readUsable && !protocolEOF {
                closeTransport(reason: reason)
                phase = .incomplete
                incompleteReason = reason
            }
            return
        }
        transportFailureEmitted = true
        if phase != .idle { phase = .stopping }
        emitTransportError(reason)
        // A write or delivery failure does not invalidate the read half. Preserve it until real
        // EOF so settlement can be verified, while failing outstanding writes immediately.
        if readUsable {
            discardingRendererOutput = true
            outputCredits.discardForRendererTeardown()
            output.removeAll()
            resumeReadAfterAcknowledgement(sessionID: 0)
            let pump = writePump
            writePump = nil
            pump?.close(error: NativeExtensionHostError.transport(reason))
        } else {
            closeTransport(reason: reason)
        }
        if let session {
            let result = codipad_kernel_signal(session, SIGTERM)
            if result == 0 || result == -ESRCH || result == -ENOENT || result == -Int32(CODIPAD_EINCOMPLETE) {
                scheduleForceStop(session)
            } else {
                phase = .incomplete
                incompleteReason = "cannot signal host after transport failure: \(Self.posixMessage(-result))"
                emitTransportError(incompleteReason!)
            }
        }
    }

    private func scheduleForceStop(_ target: UInt64) {
        queue.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            guard let self, self.session == target, self.phase != .idle else { return }
            let result = codipad_kernel_signal(target, SIGKILL)
            if result != 0 && result != -ESRCH && result != -ENOENT {
                self.phase = .incomplete
                self.incompleteReason = "cannot confirm force-stop signal: \(Self.posixMessage(-result))"
                self.emitTransportError(self.incompleteReason!)
            }
        }
    }


    private func emitTransportError(_ reason: String, sessionID: Int? = nil) {
        guard let sessionID = sessionID ?? session.flatMap(Self.safeInt) else { return }
        let event: [String: Any] = ["kind": "exthost.transportError", "sessionId": sessionID,
                                    "reason": reason]
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    private func closeTransport(reason: String = "Linux extension-host transport closed") {
        hostFD = -1
        if readPaused { readSource?.resume(); readPaused = false }
        readSource?.cancel(); readSource = nil
        let pump = writePump
        writePump = nil
        pump?.close(error: NativeExtensionHostError.transport(reason))
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }

    private static func configureSocket(_ fd: Int32) -> Bool {
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return false }
        let flags = fcntl(fd, F_GETFL, 0)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func safeInt(_ value: UInt64) -> Int? {
        value <= UInt64(Int.max) ? Int(value) : nil
    }

    private static func posixMessage(_ code: Int32) -> String {
        String(cString: strerror(code > 0 ? code : -code))
    }
}

private func linuxExtensionHostExit(_ session: codipad_session_t, _ code: Int32, _ signal: Int32,
                                   _ allReaped: Bool, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<LinuxExtensionHost>.fromOpaque(context).takeUnretainedValue()
        .recordLeaderExit(session: session, code: code, signal: signal, allReaped: allReaped)
}

private func linuxExtensionHostSettled(_ session: codipad_session_t, _ code: Int32, _ signal: Int32,
                                      _ allReaped: Bool, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<LinuxExtensionHost>.fromOpaque(context).takeUnretainedValue()
        .recordSettled(session: session, code: code, signal: signal, allReaped: allReaped)
}


private func withCStringArray<T>(_ values: [String],
                                 _ body: (inout UnsafeMutableBufferPointer<UnsafeMutablePointer<CChar>?>) throws -> T) rethrows -> T {
    var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    pointers.append(nil)
    defer { for pointer in pointers { if let pointer { free(pointer) } } }
    return try pointers.withUnsafeMutableBufferPointer(body)
}
