import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import CodiPadWorkspace

/// Persistent, independently authorized roots used by local agent sessions.
final class NativeAgentWorkspaceRoots {
    private static let lock = NSRecursiveLock()
    private let fileSystem: WorkspaceFileSystem
    private let directory: URL

    init(fileSystem: WorkspaceFileSystem) {
        self.fileSystem = fileSystem
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodiPad/agent-workspace-roots", isDirectory: true)
    }

    func authorize(_ uris: [String]) throws -> [WorkspaceNativeToolAccess] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard uris.count <= 32, Set(uris).count == uris.count else {
            throw NativeAgentHost.Failure("InvalidRequest", "Invalid agent working directories")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var result: [WorkspaceNativeToolAccess] = []
        for uri in uris {
            let access = try fileSystem.authorizedDirectoryAccess(rootURI: uri)
            let name = SHA256.hash(data: Data(uri.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
            let state = try NativeWorkspaceState(fileSystem: fileSystem, storageURL: directory.appendingPathComponent(name), canAdoptLegacy: false)
            let identity = try state.identify(uri: uri)
            try state.commit(uri: uri, workspaceID: identity.workspaceID)
            result.append(access)
        }
        return result
    }

    func restore() throws -> [WorkspaceNativeToolAccess] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        guard files.count <= 1024 else { throw NativeAgentHost.Failure("InvalidState", "Too many saved agent workspace roots") }
        return try files.map { file in
            let state = try NativeWorkspaceState(fileSystem: fileSystem, storageURL: file, canAdoptLegacy: false)
            guard let uri = try state.current(preserveCanonicalFolderURI: true)?.folderURI else {
                throw NativeAgentHost.Failure("WorkspaceUnavailable", "A saved agent working directory is unavailable")
            }
            return try fileSystem.authorizedDirectoryAccess(rootURI: uri)
        }
    }

    func unavailableRoot() throws -> (file: URL, uri: String)? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard files.count <= 1024 else { throw NativeAgentHost.Failure("InvalidState", "Too many saved agent workspace roots") }
        for file in files {
            let state = try NativeWorkspaceState(fileSystem: fileSystem, storageURL: file, canAdoptLegacy: false)
            do { guard try state.current(preserveCanonicalFolderURI: true) != nil else { throw NativeAgentHost.Failure("WorkspaceUnavailable", "A saved agent working directory is unavailable") } }
            catch { return (file, try state.savedFolderURI()) }
        }
        return nil
    }

    func reauthorize(file: URL, uri: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let state = try NativeWorkspaceState(fileSystem: fileSystem, storageURL: file, canAdoptLegacy: false)
        try state.reauthorizeFolder(uri: uri)
    }
}

/// One standalone stock AHP generation in the existing process authority. Renderer disposal
/// disconnects its socket; only this owner stops the process. The kernel and mounts remain shared.
final class NativeAgentHost {
    struct Artifact {
        let url: URL
        let sha256: String
        func verify() throws {
            guard url.isFileURL, url.host == nil || url.host == "", url.query == nil, url.fragment == nil,
                  url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  sha256.count == 64 else { throw Failure("ArtifactUnavailable", "Agent host artifact identity is unavailable") }
            let actual = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            guard actual == sha256 else { throw Failure("ArtifactUnavailable", "Agent host artifact checksum differs") }
        }
    }
    struct LaunchInput {
        let script: Artifact
        let sqliteAddon: Artifact
        let cwd: String
        let logsPath: String
        let userDataPath: String
        let environment: [String: String]
        let launchConfiguration: [String: Any]
        let filesystemOwner: WorkspaceFileSystem
        let runtimeOwner: AnyObject
    }
    struct Session {
        let sessionId: String
        let ownerGeneration: String
        let address: String
        let connectionToken: String
        let otelPolicy: [String: Any]
        var value: [String: Any] { ["sessionId": sessionId, "ownerGeneration": ownerGeneration,
            "address": address, "connectionToken": connectionToken, "otelPolicy": otelPolicy] }
    }
    struct Exit {
        let sessionId: String
        let ownerGeneration: String
        let code: Int32
        let signal: Int32
        var value: [String: Any] { ["sessionId": sessionId, "ownerGeneration": ownerGeneration,
            "code": Int(code), "signal": Int(signal), "allReaped": true] }
    }
    struct Failure: LocalizedError {
        let code: String
        let message: String
        init(_ code: String, _ message: String) { self.code = code; self.message = message }
        var errorDescription: String? { message }
    }
    private enum Phase: String { case idle, starting, running, stopping, incomplete }
    private let queue = DispatchQueue(label: "dev.codipad.agent-host", qos: .userInitiated)
    private var phase = Phase.idle
    private var session: UInt64?
    private var owner: UInt64?
    private var context: UnsafeMutableRawPointer?
    private var retainedInput: LaunchInput?
    private var active: Session?
    private var lastExit: Exit?
    private var startReplies: [(Result<Session, Error>) -> Void] = []
    private var stopReplies: [(Result<Exit, Error>) -> Void] = []
    private var startFailure: Error?
    private var settlement: (code: Int32, signal: Int32)?
    private var closedStatus: codipad_session_info?
    private var readers: [Int32: DispatchSourceRead] = [:]
    private var stdoutFD: Int32 = -1
    private var stderrFD: Int32 = -1
    private var line = Data()
    private var oversizedLine = false
    /// Callbacks run on this class's queue and must not block or synchronously call status().
    var onExit: ((Exit) -> Void)?
    var onOutput: ((Data, Bool) -> Void)?

    init() {}

    func status() -> [String: Any] {
        queue.sync {
            var value: [String: Any] = ["phase": phase.rawValue,
                "otelPolicy": retainedInput?.launchConfiguration["otelPolicy"] as? [String: Any] ?? [:]]
            if let session { value["sessionId"] = String(session) }
            if let owner { value["ownerGeneration"] = String(owner) }
            if let lastExit { value["lastExit"] = lastExit.value }
            return value
        }
    }

    func start(_ input: LaunchInput, completion: @escaping (Result<Session, Error>) -> Void) {
        queue.async { [self] in
            do { try Self.validateLaunchConfiguration(input.launchConfiguration) }
            catch { completion(.failure(error)); return }
            if let active, phase == .running { completion(.success(active)); return }
            if phase == .starting, startReplies.count < 16 { startReplies.append(completion); return }
            guard phase == .idle else { completion(.failure(Failure("CleanupIncomplete", "Agent host generation is still owned"))); return }
            do {
                try input.script.verify(); try input.sqliteAddon.verify()
                let prefix = try Data(contentsOf: input.sqliteAddon.url).prefix(20)
                guard prefix.starts(with: [0x7f, 0x45, 0x4c, 0x46, 2, 1]), prefix.count == 20,
                      prefix[16] == 3, prefix[17] == 0, prefix[18] == 183, prefix[19] == 0 else { throw Failure("UnsupportedABI", "Agent host requires the verified Linux AArch64 addon") }
                guard [input.cwd, input.logsPath, input.userDataPath].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
                      JSONSerialization.isValidJSONObject(input.launchConfiguration) else { throw Failure("InvalidLaunch", "Invalid agent host launch data") }
                let configuration = try JSONSerialization.data(withJSONObject: input.launchConfiguration, options: [.sortedKeys])
                guard let telemetry = input.launchConfiguration["telemetryLevel"] as? String else { throw Failure("InvalidLaunch", "Missing telemetry level") }
                var environment = input.environment
                environment["VSCODE_AGENT_HOST_SOCKET_PATH"] = nil
                environment["VSCODE_AGENT_HOST_HOST"] = "127.0.0.1"
                environment["VSCODE_AGENT_HOST_PORT"] = "0"
                let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
                environment["VSCODE_AGENT_HOST_CONNECTION_TOKEN"] = token
                environment["VSCODE_AGENT_HOST_LAUNCH_KIND"] = "vscode_cli"
                environment["CODIPAD_AGENT_HOST_LAUNCH_CONFIG"] = String(decoding: configuration, as: UTF8.self)
                let env = try environment.map { key, value -> String in
                    guard !key.isEmpty, !key.contains("="), !key.contains("\0"), !value.contains("\0") else { throw Failure("InvalidLaunch", "Invalid agent host environment") }
                    return "\(key)=\(value)"
                }.sorted()
                let argv = ["/usr/local/bin/node", input.script.url.path, "--type=agentHost", "--logsPath", input.logsPath,
                            "--user-data-dir", input.userDataPath, "--telemetry-level", telemetry]
                var backend = CODIPAD_BACKEND_UNKNOWN
                var resolved = [CChar](repeating: 0, count: 4096)
                let preflight = try withStrings(env) { envp in
                    "/usr/local/bin/node".withCString { executable in input.cwd.withCString { cwd in
                        resolved.withUnsafeMutableBufferPointer { codipad_kernel_preflight_executable(executable, cwd, envp, $0.baseAddress, $0.count, &backend) }
                    } }
                }
                guard preflight == 0, backend == CODIPAD_BACKEND_GUEST_ELF else { throw Failure("RuntimeUnavailable", "The shared Linux Node runtime is unavailable (\(preflight))") }
                var generation: UInt64 = 0
                let reservation = codipad_kernel_reserve_owner_generation(&generation)
                guard reservation == 0 else { throw Failure("IdentityExhausted", "Agent host identity reservation failed (\(reservation))") }
                let nullInput = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
                guard nullInput >= 0 else { throw Failure("PipeFailed", "Cannot open agent host input (\(errno))") }
                defer { Darwin.close(nullInput) }
                var output = try makePipe()
                var errors: [Int32]
                do { errors = try makePipe() } catch { output.forEach { Darwin.close($0) }; throw error }
                var adopted = false
                defer { if !adopted { (output + errors).forEach { if $0 >= 0 { Darwin.close($0) } } } }
                let raw = Unmanaged.passRetained(self).toOpaque()
                var callbackAdopted = false
                defer { if !callbackAdopted { Unmanaged<NativeAgentHost>.fromOpaque(raw).release() } }
                var spawned: codipad_session_t = 0
                var options = codipad_spawn_opts()
                options.stdio_mode = CODIPAD_STDIO_HOST_FDS
                options.stdin_fd = nullInput; options.stdout_fd = output[1]; options.stderr_fd = errors[1]
                options.owner = generation; options.ctx = raw
                options.on_exit = nativeAgentHostLeaderExit
                options.on_settled = nativeAgentHostSettled
                let result = try withStrings(argv) { argvp in try withStrings(env) { envp in
                    "/usr/local/bin/node".withCString { executable in input.cwd.withCString { cwd in
                        options.exe = executable; options.cwd = cwd; options.argv = argvp; options.envp = envp
                        return codipad_kernel_spawn(&options, &spawned)
                    } }
                } }
                guard result == 0 else {
                    throw Failure("SpawnFailed", "Agent host spawn failed (\(result))")
                }
                Darwin.close(output[1]); output[1] = -1; Darwin.close(errors[1]); errors[1] = -1
                adopted = true; callbackAdopted = true
                phase = .starting; session = spawned; owner = generation; context = raw; retainedInput = input
                startReplies = [completion]; startFailure = nil; settlement = nil; active = nil
                stdoutFD = output[0]; stderrFD = errors[0]; line.removeAll(); oversizedLine = false
                read(output[0], stderr: false, token: token); read(errors[0], stderr: true, token: token)
                // Matches the pinned Node IPC client's default startup deadline; never a readiness pass.
                let startedSession = spawned
                queue.asyncAfter(deadline: .now() + .seconds(60)) { [self] in
                    guard session == startedSession, phase == .starting else { return }
                    startFailure = Failure("StartupTimeout", "Stock agent host did not report a listening endpoint")
                    requestStop(startedSession)
                }
            } catch { completion(.failure(error)) }
        }
    }

    func stop(sessionId: String, completion: @escaping (Result<Exit, Error>) -> Void) {
        queue.async { [self] in
            if let lastExit, lastExit.sessionId == sessionId { completion(.success(lastExit)); return }
            guard let session, String(session) == sessionId, stopReplies.count < 16 else { completion(.failure(Failure("StaleGeneration", "Agent host session is not current"))); return }
            stopReplies.append(completion)
            if phase == .starting { startFailure = Failure("Cancelled", "Agent host startup was cancelled") }
            requestStop(session)
        }
    }

    func shutdown() {
        queue.async { [self] in
            guard let session else { return }
            startFailure = Failure("Cancelled", "Native agent host owner is shutting down")
            requestStop(session)
        }
    }

    static func validateLaunchConfiguration(_ value: [String: Any]) throws {
        func invalid() -> Failure { Failure("InvalidLaunch", "Unsupported agent host launch configuration") }
        guard Set(value.keys) == ["schemaVersion", "sdk", "otel", "otelPolicy", "telemetryLevel"],
              let version = value["schemaVersion"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let sdk = value["sdk"] as? [String: Any],
              let telemetry = value["telemetryLevel"] as? String, ["off", "crash", "error", "all"].contains(telemetry) else { throw invalid() }
        func string(_ raw: Any) -> Bool { (raw as? String).map { !$0.contains("\0") && $0.utf8.count <= 8192 } == true }
        func boolean(_ raw: Any) -> Bool { (raw as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true }
        for (key, raw) in sdk {
            switch key {
            case "codexSdkRoot", "codexHome": guard string(raw) else { throw invalid() }
            case "claudeAgentEnabled", "codexAgentEnabled": guard boolean(raw) else { throw invalid() }
            case "codexBinaryArgs":
                guard let args = raw as? [String], args.count <= 128, args.allSatisfy({ string($0) }) else { throw invalid() }
            default: throw invalid()
            }
        }
        for field in ["otel", "otelPolicy"] {
            guard let settings = value[field] as? [String: Any] else { throw invalid() }
            for (key, raw) in settings {
                switch key {
                case "enabled", "captureContent", "captureIdentity", "dbSpanExporterEnabled": guard boolean(raw) else { throw invalid() }
                case "exporterType", "otlpProtocol", "otlpEndpoint", "outfile", "serviceName": guard string(raw) else { throw invalid() }
                case "resourceAttributes":
                    guard let attrs = raw as? [String: String], attrs.count <= 128,
                          attrs.allSatisfy({ string($0.key) && string($0.value) }) else { throw invalid() }
                default: throw invalid()
                }
            }
        }
        guard JSONSerialization.isValidJSONObject(value),
              try JSONSerialization.data(withJSONObject: value).count <= 65536 else { throw invalid() }
    }

    private func requestStop(_ target: UInt64) {
        guard session == target else { return }
        active = nil
        phase = .stopping
        if let settlement { finishSettlement(target, code: settlement.code, signal: settlement.signal, attempt: 0); return }
        _ = codipad_kernel_signal(target, SIGTERM)
        queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [self] in
            guard session == target else { return }
            _ = codipad_kernel_signal(target, SIGKILL)
            // Signals reach inherited fs_context tasks even after leader exit. Keep the record
            // until dispatcher settlement: destructive close can erase an undelivered callback.
        }
        queue.asyncAfter(deadline: .now() + .seconds(3)) { [self] in
            guard session == target else { return }
            phase = .incomplete
            failReplies(Failure("CleanupIncomplete", "Agent host cancellation has not been confirmed; ownership is retained"))
        }
    }

    fileprivate func observedLeaderExit(_ target: UInt64, code: Int32, signal: Int32) {
        queue.async { [self] in
            guard session == target else { return }
            active = nil
            if phase == .starting { startFailure = Failure("StartupFailed", "Agent host exited before reporting readiness (\(code), signal \(signal))") }
            guard phase == .starting || phase == .running else { return }
            requestStop(target)
        }
    }

    private func closeOwnedSession(_ target: UInt64) -> Int32 {
        if closedStatus != nil { return 0 }
        var final = codipad_session_info()
        let result = codipad_kernel_close_status(target, 0, &final)
        if result == 0, final.session == target, final.has_status, final.reaped, final.all_descendants_reaped {
            closedStatus = final
        }
        return result
    }

    private func makePipe() throws -> [Int32] {
        var pair: [Int32] = [-1, -1]
        guard Darwin.pipe(&pair) == 0 else { throw Failure("PipeFailed", "Agent host pipe creation failed (\(errno))") }
        guard fcntl(pair[0], F_SETFL, O_NONBLOCK) == 0, fcntl(pair[1], F_SETFL, O_NONBLOCK) == 0,
              fcntl(pair[0], F_SETFD, FD_CLOEXEC) == 0, fcntl(pair[1], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(pair[1], F_SETNOSIGPIPE, 1) == 0 else {
            let error = errno; pair.forEach { Darwin.close($0) }; throw Failure("PipeFailed", "Agent host pipe configuration failed (\(error))")
        }
        return pair
    }

    private func read(_ fd: Int32, stderr: Bool, token: String) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readers[fd] = source
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in self?.drain(fd, stderr: stderr, token: token) }
        source.resume()
    }
    private func drain(_ fd: Int32, stderr: Bool, token: String) {
        guard readers[fd] != nil else { return }
        var buffer = [UInt8](repeating: 0, count: 16384)
        for _ in 0..<64 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer.prefix(count)); onOutput?(data, stderr)
                if !stderr { acceptStdout(data, token: token) }
            } else if count == 0 {
                readers.removeValue(forKey: fd)?.cancel()
                if stderr { stderrFD = -1 } else { stdoutFD = -1 }
                return
            } else if errno != EINTR {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    let failure = Failure("PipeFailed", "Agent host output read failed (\(errno))")
                    startFailure = failure
                    if let session, settlement == nil { requestStop(session) }
                    else { phase = .incomplete; failReplies(failure) }
                }
                return
            }
        }
    }
    private func acceptStdout(_ data: Data, token: String) {
        for byte in data {
            if byte == 10 {
                if !oversizedLine, phase == .starting, let session, let owner {
                    let text = String(decoding: line, as: UTF8.self)
                    let prefix = "Agent host server listening on 127.0.0.1:"
                    if text.hasPrefix(prefix), let port = UInt16(text.dropFirst(prefix.count)), port > 0,
                       String(port) == text.dropFirst(prefix.count) {
                        let result = Session(sessionId: String(session), ownerGeneration: String(owner), address: "ws://127.0.0.1:\(port)", connectionToken: token,
                            otelPolicy: retainedInput?.launchConfiguration["otelPolicy"] as? [String: Any] ?? [:])
                        active = result; phase = .running
                        let replies = startReplies; startReplies.removeAll(); replies.forEach { $0(.success(result)) }
                    }
                }
                line.removeAll(keepingCapacity: true); oversizedLine = false
            } else if line.count < 16384 && !oversizedLine { line.append(byte) }
            else { line.removeAll(keepingCapacity: true); oversizedLine = true }
        }
    }

    fileprivate func observedSettlement(_ target: UInt64, code: Int32, signal: Int32, allReaped: Bool) {
        queue.async { [self] in
            guard session == target, allReaped else { return }
            if phase == .starting { startFailure = Failure("StartupFailed", "Agent host exited before reporting readiness (\(code), signal \(signal))") }
            phase = .stopping; settlement = (code, signal)
            finishSettlement(target, code: code, signal: signal, attempt: 0)
        }
    }
    private func finishSettlement(_ target: UInt64, code: Int32, signal: Int32, attempt: Int) {
        guard session == target, let owner else { return }
        let result = closeOwnedSession(target)
        if result == -EINPROGRESS && attempt < 40 {
            queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in finishSettlement(target, code: code, signal: signal, attempt: attempt + 1) }
            return
        }
        // A missing record proves nothing. Only our own successful matching close snapshot
        // survives record removal while the real pipe EOF is still pending.
        guard let final = closedStatus, final.code == code, final.terminating_signal == signal,
              codipad_kernel_sessions_for_owner(owner, nil, 0) == 0 else {
            phase = .incomplete; failReplies(Failure("CleanupIncomplete", "Agent host settlement is incomplete (\(result)); ownership is retained")); return
        }
        // Settlement closes every writer, but the parent pipes may still hold final log bytes.
        // Drain to real EOF before releasing them or acknowledging the generation's stop.
        if stdoutFD >= 0 { drain(stdoutFD, stderr: false, token: "") }
        if stderrFD >= 0 { drain(stderrFD, stderr: true, token: "") }
        if !readers.isEmpty {
            if attempt < 40 {
                queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [self] in finishSettlement(target, code: code, signal: signal, attempt: attempt + 1) }
            } else {
                phase = .incomplete; failReplies(Failure("CleanupIncomplete", "Agent host output has not reached EOF; ownership is retained"))
            }
            return
        }
        let exit = Exit(sessionId: String(target), ownerGeneration: String(owner), code: code, signal: signal)
        let startReplies = self.startReplies, stops = stopReplies
        self.startReplies.removeAll(); stopReplies.removeAll()
        let failure = startFailure ?? Failure("StartupFailed", "Agent host stopped before readiness")
        readers.values.forEach { $0.cancel() }; readers.removeAll(); stdoutFD = -1; stderrFD = -1
        lastExit = exit; active = nil; session = nil; self.owner = nil; retainedInput = nil; phase = .idle; startFailure = nil; settlement = nil; closedStatus = nil
        onExit?(exit)
        startReplies.forEach { $0(.failure(failure)) }; stops.forEach { $0(.success(exit)) }
        if let context { self.context = nil; Unmanaged<NativeAgentHost>.fromOpaque(context).release() }
    }
    private func failReplies(_ error: Error) {
        let starts = startReplies, stops = stopReplies; startReplies.removeAll(); stopReplies.removeAll()
        starts.forEach { $0(.failure(error)) }; stops.forEach { $0(.failure(error)) }
    }
    private func withStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) throws -> T) throws -> T {
        let storage = strings.map { strdup($0) }
        defer { storage.forEach { free($0) } }
        guard storage.allSatisfy({ $0 != nil }) else { throw Failure("OutOfMemory", "Agent host launch allocation failed") }
        var values = storage.map { $0.map { UnsafePointer($0) } }; values.append(nil)
        return try values.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }
}

private func nativeAgentHostLeaderExit(_ session: codipad_session_t, _ code: Int32, _ signal: Int32, _ allReaped: Bool, _ raw: UnsafeMutableRawPointer?) {
    guard let raw else { return }
    Unmanaged<NativeAgentHost>.fromOpaque(raw).takeUnretainedValue().observedLeaderExit(session, code: code, signal: signal)
}
private func nativeAgentHostSettled(_ session: codipad_session_t, _ code: Int32, _ signal: Int32, _ allReaped: Bool, _ raw: UnsafeMutableRawPointer?) {
    guard let raw else { return }
    Unmanaged<NativeAgentHost>.fromOpaque(raw).takeUnretainedValue().observedSettlement(session, code: code, signal: signal, allReaped: allReaped)
}
