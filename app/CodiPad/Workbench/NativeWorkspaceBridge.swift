import Foundation
import Darwin
import CodiPadWorkspace
import UIKit
import UniformTypeIdentifiers
import WebKit

/// Native reply bridge for the workbench page: native folder/file picking plus backend
/// filesystem calls. Registered as `codipadNative` in the page content world.
///
/// Trust rules: only the top-level document at the artifact entry point may call it. Requests
/// are validated before any picker or filesystem side effect. The page never authorizes an
/// arbitrary path: only native picker selections and system-delivered file URLs are granted,
/// through `WorkspaceFileSystem` on a serial I/O queue. This type contains no filesystem code.
final class NativeWorkspaceBridge: NSObject {
    static let name = "codipadNative"
    static let contentWorld: WKContentWorld = .page

    // The UI supplies only a workspace/instance URI. Keep the actual PTY and its lease owner
    // alive in the source host until a target has acknowledged the snapshot.
    private final class WeakTerminalBridge {
        weak var value: NativeWorkspaceBridge?
        init(_ value: NativeWorkspaceBridge) { self.value = value }
    }
    private struct TerminalTransferOffer {
        let source: NativeWorkspaceBridge
        let owner: NativeTerminalHost
        let page: String
        let generation: String
        let sessionId: Int
        let details: [String: Any]
    }
    private final class TerminalTransfer {
        let id = UUID().uuidString
        weak var target: NativeWorkspaceBridge?
        let targetPage: String
        let targetWorkspace: String
        let reply: ReplyToken
        var source: NativeWorkspaceBridge?
        var owner: NativeTerminalHost?
        var sourcePage = ""
        var sourceGeneration = ""
        var sourceWorkspace = ""
        var sessionId = 0
        var snapshotStarted = false
        var replied = false
        var offers: [TerminalTransferOffer] = []
        init(target: NativeWorkspaceBridge, page: String, workspace: String, reply: ReplyToken) {
            self.target = target; self.targetPage = page; self.targetWorkspace = workspace; self.reply = reply
        }
    }
    // Main queue only, including timeout and bridge/page lifecycle callbacks.
    private static var terminalBridges: [WeakTerminalBridge] = []
    private static var terminalTransfers: [String: TerminalTransfer] = [:]

    private func registerTerminalBridge() {
        Self.terminalBridges.removeAll { $0.value == nil || $0.value === self }
        Self.terminalBridges.append(WeakTerminalBridge(self))
    }

    private func cancelTerminalTransfers() {
        let pending = Self.terminalTransfers.values.filter { $0.target === self || $0.source === self }
        for transfer in pending { Self.cancelTerminalTransfer(transfer) }
        Self.terminalBridges.removeAll { $0.value == nil || $0.value === self }
    }

    private static func cancelTerminalTransfer(_ transfer: TerminalTransfer) {
        guard terminalTransfers.removeValue(forKey: transfer.id) != nil else { return }
        if transfer.snapshotStarted, let owner = transfer.owner {
            let session = transfer.sessionId, id = transfer.id
            DispatchQueue.global(qos: .userInitiated).async {
                try? owner.cancelHandoff(sessionId: session, handoffId: id)
            }
        }
        if !transfer.replied { transfer.reply.send(ok(NSNull())) }
    }

    private func requestTerminalTransfer(workspace: String, targetWorkspace: String, instance: Int, page: String, token: ReplyToken) {
        let transfer = TerminalTransfer(target: self, page: page, workspace: targetWorkspace, reply: token)
        Self.terminalTransfers[transfer.id] = transfer
        let data = try? JSONSerialization.data(withJSONObject: ["requestId": transfer.id, "workspaceId": workspace, "instanceId": instance])
        let message = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        for entry in Self.terminalBridges {
            guard let bridge = entry.value, bridge !== self, !bridge.isTornDown,
                  bridge.incomingDocumentPage != nil, bridge.extensionHost.processRuntime == .linux else { continue }
            bridge.onRuntimeEvent?(["kind": "terminal.handoffRequest", "sessionId": 0,
                                    "pageId": bridge.incomingDocumentPage!, "data": message])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(1)) {
            guard Self.terminalTransfers[transfer.id] === transfer else { return }
            guard transfer.offers.count == 1, let offer = transfer.offers.first,
                  !offer.source.isTornDown, offer.source.incomingDocumentPage == offer.page else {
                Self.cancelTerminalTransfer(transfer); return
            }
            transfer.source = offer.source; transfer.owner = offer.owner; transfer.sourcePage = offer.page
            transfer.sourceGeneration = offer.generation; transfer.sourceWorkspace = offer.details["workspaceId"] as? String ?? ""
            transfer.sessionId = offer.sessionId; transfer.replied = true
            transfer.reply.send(Self.ok(offer.details))
            transfer.offers.removeAll()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(15)) { Self.cancelTerminalTransfer(transfer) }
    }

    private func offerTerminalTransfer(id: String, session: Int, page: String, generation: String, token: ReplyToken) {
        guard let transfer = Self.terminalTransfers[id], transfer.source == nil,
              transfer.target !== self, transfer.target?.incomingDocumentPage == transfer.targetPage else {
            token.send(Self.ok(NSNull())); return
        }
        let owner = NativeTerminalHost.transferredHost(sessionId: session, target: terminalHost) ?? terminalHost
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let details = try owner.handoffDetails(sessionId: session, pageId: page, generation: generation)
                DispatchQueue.main.async {
                    guard let self, Self.terminalTransfers[id] === transfer, transfer.source == nil,
                          !self.isTornDown, self.incomingDocumentPage == page,
                          transfer.target?.incomingDocumentPage == transfer.targetPage else {
                        token.send(Self.ok(NSNull())); return
                    }
                    if !transfer.offers.contains(where: { $0.source === self }) {
                        transfer.offers.append(TerminalTransferOffer(source: self, owner: owner, page: page,
                            generation: generation, sessionId: session, details: details))
                    }
                    token.send(Self.ok(NSNull()))
                }
            } catch { token.send(Self.error("TerminalHandoffFailed", error.localizedDescription)) }
        }
    }

    private func pendingTerminalTransfer(session: Int, page: String) -> TerminalTransfer? {
        Self.terminalTransfers.values.first { $0.target === self && $0.targetPage == page && $0.sessionId == session && $0.owner != nil }
    }

    /// Methods this bridge answers. `fs.*` entries are forwarded to the backend unchanged.
    static let methods: Set<String> = [
        "urls.ready", "urls.suspend", "urls.claim",
        "documents.ready", "documents.suspend", "documents.resolve", "documents.complete",
        "documents.restoreOpen", "documents.syncOpen", "documents.acceptSaveTarget",
        "process.home", "dialog.open", "workspace.current", "workspace.identify", "workspace.commit", "workspace.cancel", "workspace.completeRelocation", "window.openExternal", "window.openScene", "window.showEditor",
        "exthost.scan", "exthost.catalogGeneration", "exthost.start", "exthost.send", "exthost.stop", "exthost.assertStopped", "exthost.prepareWindowReload", "exthost.cancelWindowReload",
        "agentHost.start", "agentHost.stop", "agentHost.status", "agentHost.authorizeDirectories", "agentHost.reauthorizeDirectories",
        "marketplace.request", "marketplace.cancel", "extension.install", "extension.download", "extension.exportVSIX", "extension.updateMetadata", "extension.releasePublication",
        "extension.getVSIXManifest", "extension.installVSIX", "extension.cancelInstall", "extension.uninstall", "extension.profileFenceAcquire", "extension.profileFenceRelease", "extension.publishBrowserResources", "extension.registeredPackages", "extension.collect", "extension.hostLease",
        "extension.resolveBrowserResource",
        "secrets.get", "secrets.set", "secrets.delete", "secrets.keys",
        "clipboard.readText", "clipboard.writeText",
        "webview.open", "webview.close",
        "terminal.create", "terminal.input", "terminal.ack", "terminal.ackBatch", "terminal.resize", "terminal.signal",
        "terminal.metadata", "terminal.clearBuffer", "terminal.setUnicodeVersion", "terminal.setNextCommandId", "terminal.attachIdentity", "terminal.attach", "terminal.resume", "terminal.detach", "terminal.ackExit", "terminal.serialize", "terminal.incarnation", "terminal.setLayout", "terminal.getLayout",
        "terminal.stop", "terminal.cwd", "terminal.list", "terminal.environment", "terminal.pathExists", "terminal.profileEnvironment", "terminal.shells",
        "terminal.shellIntegrationContext", "terminal.prepareShellIntegration", "terminal.requestHandoff", "terminal.offerHandoff", "terminal.installAutoReply", "terminal.uninstallAllAutoReplies",
        "fs.stat", "fs.pathCapabilities", "fs.readdir", "fs.open", "fs.close", "fs.read", "fs.write", "fs.writeFile", "fs.stageBegin", "fs.stageWrite", "fs.stageCommit", "fs.stageAbort", "fs.mkdir", "fs.rename", "fs.delete", "fs.watch", "fs.unwatch",
    ]

    /// Presenter for the document picker, set by the hosting controller.
    weak var presenter: UIViewController?
    /// Bundle artifact root; requests from outside its entry point are rejected.
    var artifactRoot: URL?
    /// Current committed top-level URL, used when the frame request URL is unavailable.
    var topLevelURL: (() -> URL?)?
    /// Only the native asset service's currently issued main document may use this bridge.
    var isTrustedWorkbenchURL: ((URL) -> Bool)?
    weak var extensionAssetServer: NativeWorkbenchAssetLease?
    /// Structured metadata log sink. Callers must not pass file contents or file paths.
    var logEvent: (([String: Any]) -> Void)?
    /// Raw extension-host socket events, delivered only to the current trusted workbench.
    var onRuntimeEvent: (([String: Any]) -> Void)?

    var onIncomingDocumentError: ((String) -> Void)?

    private let fileSystem: WorkspaceFileSystem
    private let sceneID: String?
    private let canAdoptLegacy: Bool
    private let extensionHost: NativeExtensionHost
    private let terminalHost: NativeTerminalHost
    private let agentHost = NativeAgentHost()
    private static let includesLocalAgentHost = Bundle.main.url(
        forResource: "receipt", withExtension: "json", subdirectory: "Exthost/agent-host"
    ) != nil
    private var localAgentHostAvailable: Bool {
        Self.includesLocalAgentHost && extensionHost.processRuntime == .linux
    }
    private lazy var agentWorkspaceRoots = NativeAgentWorkspaceRoots(fileSystem: fileSystem)
    private var agentWorkspaceRootsRestored = false
    private let marketplace = NativeMarketplaceClient()
    private let marketplaceTaskLock = NSLock()
    private var marketplaceTasks: [String: Task<Void, Never>] = [:]
    private var marketplacePendingCancellations: [String: Date] = [:]
    private let extensionStore = NativeExtensionStore()
    private let extensionDownloadDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codipad-vsix-" + UUID().uuidString, isDirectory: true)
    private let extensionProfileFenceOwner = UUID()
    private let secretStore = WorkspaceSecretStore(service: "\(Bundle.main.bundleIdentifier ?? "com.bendews.codipad").extension-secrets")
    /// Accessed on ioQueue; resource loading must not delay ordinary folder editing at startup.
    private var webviewService: NativeWebviewService?
    /// Accessed only on ioQueue; restored native grants precede workbench storage selection.
    private var workspaceState: NativeWorkspaceState?
    // On ioQueue. Only a native picker, an incoming file, or a verified bookmark supplies
    // a source. Editor URIs identify which of those selections the scene still needs.
    private var pickedDocumentSources: [String: RestoredDocumentGrant] = [:]
    private var restoredDocumentFolders: [String: RestoredDocumentGrant] = [:]
    private var acceptedSaveTargets: [String: RestoredDocumentGrant] = [:]
    private var persistedDocumentSources: Set<String>?
    private var documentLayout: String?
    /// Accessed only on ioQueue. Bundle and private homes share the same filesystem authority.
    private var extensionCatalog: [String: Any]?
    private var extensionCatalogGeneration: UInt64?
    private var extensionPrivateRoots: [String: String] = [:]
    private var extensionDownloadURI: String?
    private var processHomeURI: String?
    private var browserResourceCatalog: NativeWorkbenchAssetServer.ExtensionCatalogCapability?
    /// Cold materialization is shared by every catalog-dependent request already on ioQueue.
    private var extensionCatalogPreparationInFlight = false
    private var extensionCatalogPreparationWaiters: [(Result<[String: Any], Error>) -> Void] = []
    private let extensionInstallTaskLock = NSLock()
    private var extensionInstallTasks: [String: Task<Void, Never>] = [:]
    private var waitingExtensionInstalls: [String: () -> Void] = [:]
    private var extensionInstallInFlight = false
    private var extensionInstallQueue: [(requestId: String?, run: () -> Void)] = []
    private let ioQueue = DispatchQueue(label: "dev.codipad.workspace.bridge", qos: .userInitiated)
    private let pendingLock = NSLock()
    private let extensionHostStartLock = NSLock()
    private var extensionHostStartsSuspended = false
    private var extensionHostStartGeneration: UInt64 = 0
    private var pending: [UUID: ReplyToken] = [:]
    private var activePickerReply: ReplyToken?
    private var pickerOpensNewWindow = false
    private var activeWorkspacePicker: (([URL]) -> Void)?
    // ioQueue only. Runtime installation follows a completed grant transaction.
    private var preparedNativeWorkspaces: [String: PreparedNativeWorkspace] = [:]
    private var committedNativeWorkspaceAccess: [String: WorkspaceNativeToolAccess] = [:]
    private var pickerInFlight = false
    private var lastFolderURI: String?
    private var tornDown = false
    #if DEBUG
    private var watchDiagnosticCount = 0
    #endif

    init(fileSystem: WorkspaceFileSystem, sceneID: String? = nil, canAdoptLegacy: Bool = true) {
        self.fileSystem = fileSystem
        self.sceneID = sceneID
        self.canAdoptLegacy = canAdoptLegacy
        let extensionHost = NativeExtensionHost(leaseOwner: fileSystem)
        self.extensionHost = extensionHost
        self.terminalHost = NativeTerminalHost(leaseOwner: fileSystem, processRuntime: extensionHost.processRuntime)
        super.init()
        #if DEBUG
        fileSystem.onWatchDiagnostic = { [weak self] subscription, step, count in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown, self.watchDiagnosticCount < 64 else { return }
                self.watchDiagnosticCount += 1
                self.logEvent?(["event": "native.watchDiagnostic", "sessionId": subscription,
                                "step": step, "count": count])
            }
        }
        fileSystem.onWatchFailure = { [weak self] subscription, failure in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.logEvent?([
                    "event": "native.watchFailure",
                    "sessionId": subscription,
                    "phase": failure.phase.rawValue,
                    "operation": failure.operation,
                    "posixErrno": failure.posixErrno.map { NSNumber(value: $0) as Any } ?? NSNull(),
                    "relativeDepth": failure.relativeDepth.map { NSNumber(value: $0) as Any } ?? NSNull()
                ])
            }
        }
        #endif
        fileSystem.onFileChanges = { [weak self] subscription, changes in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.onRuntimeEvent?(["kind": "fs.changes", "sessionId": subscription, "changes": changes])
            }
        }
        fileSystem.onWatchError = { [weak self] subscription, message in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.logEvent?(["event": "native.watchError", "sessionId": subscription])
                self.onRuntimeEvent?(["kind": "fs.watchError", "sessionId": subscription,
                                      "message": message])
            }
        }
        extensionHost.onEvent = { [weak self] event in
            guard let self else { return }
            #if DEBUG
            if event["kind"] as? String == "exthost.lifecycleTrace" {
                var trace = event
                trace.removeValue(forKey: "kind")
                trace["event"] = "native.extensionHostLifecycle"
                self.logEvent?(trace)
                return
            }
            #endif
            // Preserve lifecycle evidence without logging socket bytes, paths or extension data.
            if let kind = event["kind"] as? String, let session = event["sessionId"] as? Int {
                if kind == "exthost.exit", let code = event["code"] as? Int {
                    self.ioQueue.async {
                        if self.extensionHost.currentSessionId == nil && !self.extensionHost.cleanupIncomplete {
                            NativeExtensionStore.releaseHostPackages(owner: self.extensionProfileFenceOwner)
                        }
                    }
                    self.logEvent?(["event": "native.extensionHostExited", "sessionId": session, "code": code])
                } else if kind == "exthost.transportError" {
                    self.logEvent?(["event": "native.extensionHostTransportError", "sessionId": session])
                }
            }
            self.onRuntimeEvent?(event)
        }
        terminalHost.onEvent = { [weak self] event in
            guard let self else { return }
            if let kind = event["kind"] as? String, let session = event["sessionId"] as? Int {
                if kind == "terminal.exit", let code = event["code"] as? Int {
                    self.logEvent?(["event": "native.terminalExited", "sessionId": session, "code": code, "signal": event["signal"] ?? NSNull()])
                } else if kind == "terminal.error" {
                    self.logEvent?(["event": "native.terminalError", "sessionId": session, "code": event["code"] ?? "unknown"])
                }
            }
            self.onRuntimeEvent?(event)
        }
        agentHost.onExit = { [weak self] exit in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown,
                      let data = try? JSONSerialization.data(withJSONObject: exit.value),
                      let text = String(data: data, encoding: .utf8) else { return }
                self.logEvent?(["event": "native.agentHostExited", "code": Int(exit.code), "signal": Int(exit.signal)])
                self.onRuntimeEvent?(["kind": "agentHost.exit", "sessionId": 0, "data": text])
            }
        }
        agentHost.onOutput = { [weak self] data, stderr in
            let bytes = data.count
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.logEvent?(["event": "native.agentHostOutput", "bytes": bytes, "stderr": stderr])
            }
        }
    }

    /// Settles every outstanding reply so no page promise hangs when the host goes away.
    func teardown() {
        cancelTerminalTransfers()
        pendingLock.lock()
        guard !tornDown else { pendingLock.unlock(); return }
        let handlers = pending
        pending.removeAll()
        tornDown = true
        pendingLock.unlock()
        extensionURLs.dispose()
        NativeExtensionProfileFence.shared.abandon(owner: extensionProfileFenceOwner)
        extensionInstallTaskLock.lock()
        for task in extensionInstallTasks.values { task.cancel() }
        extensionInstallTaskLock.unlock()
        marketplaceTaskLock.lock()
        for task in marketplaceTasks.values { task.cancel() }
        marketplaceTasks.removeAll()
        marketplacePendingCancellations.removeAll()
        marketplaceTaskLock.unlock()
        failPickedSelections(CocoaError(.userCancelled))
        incomingDocuments.removeAll()
        activePickerReply = nil
        activeWorkspacePicker = nil
        for (_, token) in handlers {
            token.send(Self.error("hostTornDown", "the native host went away before this request completed"))
        }
        ioQueue.async { [authority = fileSystem] in
            authority.stopAllWatches()
            authority.stopAllFileTransfers()
            authority.onFileChanges = nil
            authority.onWatchError = nil
            authority.onWatchFailure = nil
            authority.onWatchDiagnostic = nil
        }
        ioQueue.async { [host = extensionHost, owner = extensionProfileFenceOwner] in
            host.shutdown()
            if host.currentSessionId == nil && !host.cleanupIncomplete { NativeExtensionStore.releaseHostPackages(owner: owner) }
        }
        ioQueue.async { [host = agentHost] in host.shutdown() }
        ioQueue.async { [host = terminalHost] in host.shutdown() }
        ioQueue.async { [self] in
            for prepared in self.preparedNativeWorkspaces.values {
                if let token = prepared.identity.preparationToken {
                    try? self.workspaceState?.cancelWorkspace(workspaceID: prepared.identity.workspaceID, preparationToken: token)
                }
            }
            self.preparedNativeWorkspaces.removeAll()
            try? FileManager.default.removeItem(at: self.extensionDownloadDirectory)
            self.browserResourceCatalog = nil
            NativeExtensionStore.releaseAssetPackages(owner: self.extensionProfileFenceOwner)
            // Resume cancelled waiters so no suspended task retains the disposed owner.
            let waiting = self.waitingExtensionInstalls.values.map { $0 }
            self.waitingExtensionInstalls.removeAll()
            self.extensionInstallQueue.removeAll()
            for resume in waiting { resume() }
            self.webviewService?.closeAll()
            self.webviewService = nil
        }
    }

    // MARK: - Request handling

    func allowsWebviewNavigation(to url: URL, from sourceURL: URL?, sourceOrigin: URL?,
                                 trustedWorkbench: Bool, completion: @escaping (Bool) -> Void) {
        ioQueue.async { [weak self] in
            let allowed: Bool
            if let self, !self.isTornDown {
                allowed = self.webviewService?.allowsNavigation(to: url, from: sourceURL,
                    sourceOrigin: sourceOrigin, trustedWorkbench: trustedWorkbench) ?? false
            } else {
                allowed = false
            }
            DispatchQueue.main.async { completion(allowed) }
        }
    }

    private func handle(message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let token = ReplyToken(replyHandler)
        pendingLock.lock()
        let isTornDown = tornDown
        if !isTornDown { pending[token.id] = token }
        pendingLock.unlock()
        guard !isTornDown else {
            token.send(Self.error("hostTornDown", "the native host is shutting down"))
            return
        }
        token.bridge = self
        guard !rendererUnavailable else {
            reject(token, "RendererTerminated", "the workbench page is unavailable")
            return
        }

        guard message.frameInfo.isMainFrame else {
            reject(token, "mainFrameOnly", "codipadNative is available to the main frame only")
            return
        }
        guard let root = artifactRoot,
              let source = message.frameInfo.request.url ?? topLevelURL?(),
              isTrustedWorkbenchURL?(source) == true
        else {
            reject(token, "untrustedFrame", "codipadNative is available to the artifact entry point only")
            return
        }
        guard let body = message.body as? [String: Any],
              let method = body["method"] as? String, !method.isEmpty
        else {
            reject(token, "malformedRequest", "expected an object with a non-empty string 'method'")
            return
        }
        let params: [String: Any]
        if let raw = body["params"] {
            guard let dictionary = raw as? [String: Any] else {
                reject(token, "malformedRequest", "'params' must be an object when present")
                return
            }
            params = dictionary
        } else {
            params = [:]
        }

        switch method {
        case "urls.ready", "urls.suspend", "urls.claim":
            do {
                let value = try extensionURLs.operation(method, params)
                token.send(Self.ok(value))
                deliverExtensionURLs()
            } catch {
                reject(token, "InvalidRequest", "The extension URL receiver is unavailable or stale.")
            }
        case "clipboard.readText":
            guard params.isEmpty else {
                reject(token, "InvalidRequest", "clipboard read takes no parameters")
                return
            }
            token.send(Self.ok(UIPasteboard.general.string ?? ""))
        case "clipboard.writeText":
            guard Set(params.keys) == ["text"], let text = params["text"] as? String,
                  text.utf8.count <= 1024 * 1024 else {
                reject(token, "InvalidRequest", "clipboard text exceeds the supported size")
                return
            }
            UIPasteboard.general.string = text
            token.send(Self.ok(NSNull()))
        case "documents.ready", "documents.suspend", "documents.resolve", "documents.complete":
            do {
                let reply = try performIncomingDocumentOperation(method: method, params: params)
                token.send(Self.ok(reply.value, pathCapabilities: reply.pathCapabilities))
            } catch {
                reject(token, "InvalidRequest", incomingDocumentError(error))
            }
        case "documents.restoreOpen", "documents.syncOpen", "documents.acceptSaveTarget":
            handleOpenDocumentState(method: method, params: params, token: token)
        case "process.home":
            guard params.isEmpty else { reject(token, "InvalidRequest", "process home takes no parameters"); return }
            ioQueue.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                do {
                    let root = try self.authorizedProcessHome()
                    guard let rootURL = URL(string: root), rootURL.isFileURL else {
                        throw NativeTerminalHostError.processHomeUnavailable("invalid authorized process home")
                    }
                    let home = rootURL.appendingPathComponent("home", isDirectory: true).absoluteString
                    token.send(Self.ok(home, pathCapabilities: try self.pathCapabilityMetadata(forURIs: [root], publishBrowserResources: true)))
                } catch let error as NativeTerminalHostError {
                    token.send(Self.error(error.code, error.message))
                } catch {
                    token.send(Self.error("ProcessHomeUnavailable", "the private process home could not be authorized"))
                }
            }
        case "workspace.current", "workspace.identify", "workspace.commit", "workspace.cancel", "workspace.completeRelocation":
            handleWorkspace(method: method, params: params, token: token)
        case "dialog.open":
            handleDialogOpen(params: params, token: token)
        case "window.showEditor":
            guard params.isEmpty else { reject(token, "InvalidRequest", "Unexpected editor window parameters."); return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                NativeSceneActivation.showEditor { [weak self] result in
                    guard let self, !self.isTornDown else { return }
                    switch result {
                    case .success: token.send(Self.ok(true))
                    case .failure(let error): self.reject(token, "windowOpenFailed", error.localizedDescription)
                    }
                }
            }
        case "window.openScene":
            guard let kind = NativeWindowKind.sceneRequest(params) else {
                reject(token, "InvalidRequest", "Opening a specific workspace in a new window is not supported yet.")
                return
            }
            if kind == .agents && extensionAssetServer?.hasAgentsEntry() != true {
                reject(token, "Unsupported", "The Agents Window is unavailable in this build.")
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                NativeSceneActivation.open(kind: kind) { [weak self] result in
                    guard let self, !self.isTornDown else { return }
                    switch result {
                    case .success: token.send(Self.ok(true))
                    case .failure(let error): self.reject(token, "windowOpenFailed", error.localizedDescription)
                    }
                }
            }
        case "window.openExternal":
            guard Set(params.keys) == ["uri"], let text = params["uri"] as? String,
                  text.utf8.count <= 16_384,
                  !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  ["https", "http", "mailto"].contains(scheme),
                  scheme == "mailto" || (url.host?.isEmpty == false && url.user == nil && url.password == nil) else {
                reject(token, "InvalidRequest", "invalid external URI")
                return
            }
            UIApplication.shared.open(url, options: [:]) { [weak self] opened in
                guard let self, !self.isTornDown else { return }
                self.logEvent?(["event": "native.externalURLOpened", "scheme": scheme, "opened": opened])
                token.send(Self.ok(opened))
            }
        case "marketplace.request":
            handleMarketplaceRequest(params: params, token: token)
        case "marketplace.cancel":
            guard Set(params.keys) == ["requestId"], let id = Self.installRequestID(params) else {
                reject(token, "malformedRequest", "invalid Marketplace request identity"); return
            }
            marketplaceTaskLock.lock()
            let task = marketplaceTasks[id]
            if task == nil {
                let now = Date()
                marketplacePendingCancellations = marketplacePendingCancellations.filter { now.timeIntervalSince($0.value) < 300 }
                guard marketplacePendingCancellations.count < 4096 || marketplacePendingCancellations[id] != nil else {
                    marketplaceTaskLock.unlock()
                    reject(token, "TooManyRequests", "too many pending Marketplace cancellations"); return
                }
                marketplacePendingCancellations[id] = now
            }
            marketplaceTaskLock.unlock()
            task?.cancel()
            token.send(Self.ok(NSNull()))
        case "webview.open", "webview.close":
            guard let id = params["id"] as? String,
                  (method == "webview.open" && Set(params.keys) == ["id", "originHash"] && params["originHash"] is String)
                    || (method == "webview.close" && Set(params.keys) == ["id"]) else {
                reject(token, "InvalidRequest", "invalid webview request")
                return
            }
            ioQueue.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                if method == "webview.close" {
                    self.webviewService?.close(id: id)
                    token.send(Self.ok(NSNull()))
                    return
                }
                do {
                    if self.webviewService == nil {
                        self.webviewService = try NativeWebviewService(resourceRoot: root.appendingPathComponent("webview-pre"))
                    }
                    self.webviewService!.open(id: id, originHash: params["originHash"] as! String) { [weak self] result in
                        DispatchQueue.main.async {
                            guard let self, !self.isTornDown else { return }
                            switch result {
                            case .success(let endpoint): token.send(Self.ok(["endpoint": endpoint]))
                            case .failure(let error): token.send(Self.error(error.code, error.message))
                            }
                        }
                    }
                } catch let error as NativeWebviewServiceError {
                    token.send(Self.error(error.code, error.message))
                } catch {
                    token.send(Self.error("Unavailable", "webview service could not start"))
                }
            }
        case "secrets.get", "secrets.set", "secrets.delete", "secrets.keys":
            ioQueue.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                let reply: [String: Any]
                do {
                    reply = Self.ok(try self.secretStore.perform(method, params: params))
                } catch let error as WorkspaceSecretStoreError {
                    reply = Self.error(error.code, error.message)
                } catch {
                    reply = Self.error("KeychainUnavailable", "secret operation failed")
                }
                DispatchQueue.main.async {
                    guard !self.isTornDown else { return }
                    token.send(reply)
                }
            }
        case "extension.cancelInstall":
            guard Set(params.keys) == ["requestId"], let requestId = Self.installRequestID(params) else {
                reject(token, "malformedRequest", "invalid extension cancellation identity")
                return
            }
            ioQueue.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.extensionInstallTaskLock.lock()
                let task = self.extensionInstallTasks[requestId]
                task?.cancel()
                self.extensionInstallTaskLock.unlock()
                self.extensionInstallQueue.removeAll { $0.requestId == requestId }
                self.waitingExtensionInstalls.removeValue(forKey: requestId)?()
                token.send(Self.ok(["accepted": task != nil]))
            }
        case "extension.install":
            handleExtensionInstall(params: params, token: token)
        case "extension.download":
            handleExtensionDownload(params: params, token: token)
        case "extension.exportVSIX":
            handleExtensionExport(params: params, token: token)
        case "extension.releasePublication":
            guard Set(params.keys) == ["uri"], let uri = params["uri"] as? String, Self.validWorkspaceURI(uri) else {
                reject(token, "malformedRequest", "invalid extension publication"); return
            }
            extensionStore.releasePublication(uri)
            token.send(Self.ok(NSNull()))
        case "extension.publishBrowserResources":
            handleExtensionBrowserResourceSnapshot(params: params, token: token)
        case "extension.registeredPackages":
            guard Set(params.keys) == ["uris"], let uris = params["uris"] as? [String],
                  uris.count <= NativeWorkbenchAssetServer.maximumCatalogPackages, uris.allSatisfy(Self.validWorkspaceURI) else {
                reject(token, "malformedRequest", "invalid registered extension locations"); return
            }
            ioQueue.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                NativeExtensionStore.setRegisteredPackages(owner: self.extensionProfileFenceOwner, packages: Set(uris))
                token.send(Self.ok(NSNull()))
            }
        case "extension.profileFenceAcquire":
            guard params.isEmpty else { reject(token, "malformedRequest", "invalid extension profile fence"); return }
            let owner = extensionProfileFenceOwner
            NativeExtensionProfileFence.shared.acquire(owner: owner) { [weak self] fence in
                guard let self, !self.isTornDown else {
                    _ = NativeExtensionProfileFence.shared.release(owner: owner, token: fence); return
                }
                token.send(Self.ok(fence))
            }
        case "extension.profileFenceRelease":
            guard Set(params.keys).isSubset(of: ["token", "mutated"]), let fence = params["token"] as? String,
                  params["mutated"] == nil || params["mutated"] is Bool,
                  UUID(uuidString: fence) != nil,
                  NativeExtensionProfileFence.shared.release(owner: extensionProfileFenceOwner, token: fence, mutated: params["mutated"] as? Bool ?? false) else {
                reject(token, "InvalidFence", "extension profile fence is not owned by this scene"); return
            }
            token.send(Self.ok(NSNull()))
        case "extension.collect":
            guard Set(params.keys) == ["token", "references"], let fence = params["token"] as? String,
                  let references = params["references"] as? [String], references.count <= 100_000,
                  references.allSatisfy(Self.validWorkspaceURI) else {
                reject(token, "malformedRequest", "invalid extension cleanup snapshot"); return
            }
            ioQueue.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                do {
                    let removed = try NativeExtensionProfileFence.shared.perform(owner: self.extensionProfileFenceOwner, token: fence) {
                        try self.extensionStore.collectUnreferenced(references: Set(references))
                    }
                    if !removed.isEmpty { self.extensionCatalog = nil; self.extensionCatalogGeneration = nil }
                    token.send(Self.ok(removed.count))
                } catch { self.replyLocalExtensionError(error, token: token) }
            }
        case "extension.hostLease":
            guard Set(params.keys) == ["sessionId", "uris"], let id = params["sessionId"] as? Int,
                  let uris = params["uris"] as? [String], uris.count <= NativeWorkbenchAssetServer.maximumCatalogPackages,
                  uris.allSatisfy(Self.validWorkspaceURI) else {
                reject(token, "malformedRequest", "invalid extension host lease"); return
            }
            ioQueue.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                guard self.extensionHost.currentSessionId == id else { self.reject(token, "StaleSession", "extension host is no longer active"); return }
                NativeExtensionStore.retainHostPackages(owner: self.extensionProfileFenceOwner, packages: Set(uris))
                token.send(Self.ok(NSNull()))
            }
        case "extension.resolveBrowserResource":
            handleExtensionBrowserResource(params: params, token: token)
        case "extension.updateMetadata":
            handleExtensionMetadataUpdate(params: params, token: token)
        case "extension.getVSIXManifest", "extension.installVSIX", "extension.uninstall":
            handleLocalExtensionOperation(method: method, params: params, token: token)
        case "exthost.catalogGeneration":
            guard params.isEmpty else { reject(token, "malformedRequest", "extension generation takes no parameters"); return }
            token.send(Self.ok(NativeExtensionStore.catalogGeneration().map { String($0) as Any } ?? NSNull()))
        case "exthost.scan":
            guard params.isEmpty else {
                reject(token, "malformedRequest", "extension scan takes no parameters")
                return
            }
            ioQueue.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                self.withAuthorizedExtensionCatalog { result in
                    do {
                        var catalog = try result.get()
                        let metadata = try self.pathCapabilityMetadata(inCatalog: catalog)
                        guard let server = self.extensionAssetServer, let packages = catalog["packages"] as? [[String: Any]] else {
                            throw BridgeError(code: "Unavailable", message: "extension resources are unavailable")
                        }
                        let entries = try packages.filter { $0["isBuiltin"] as? Bool == true }.map { entry -> NativeWorkbenchAssetServer.CatalogPackage in
                            guard let uri = entry["extensionLocation"] as? String else { throw BridgeError(code: "InvalidCatalog", message: "invalid extension location") }
                            let access = try self.fileSystem.authorizedDirectoryAccess(rootURI: uri)
                            return try NativeWorkbenchAssetServer.CatalogPackage(uri: uri, generation: access.accessGeneration, isDirectory: true, stableKey: true, openResource: { access.open(path: $0, flags: O_RDONLY | O_NONBLOCK, mode: 0) })
                        }
                        catalog["browserResourceRoots"] = try self.addBrowserResources(entries, server: server)
                        token.send(Self.ok(catalog, pathCapabilities: metadata))
                    } catch let error as NativeWorkbenchAssetServerError {
                        token.send(Self.error(error.code, error.message))
                    } catch let error as NativeExtensionCatalogError {
                        token.send(Self.error(error.code, error.message))
                    } catch let error as BridgeError {
                        token.send(Self.error(error.code, error.message))
                    } catch let error as NativeTerminalHostError {
                        token.send(Self.error(error.code, error.message))
                    } catch {
                        token.send(Self.error("CatalogFailure", error.localizedDescription))
                    }
                }
            }
        case "exthost.start", "exthost.send", "exthost.stop", "exthost.assertStopped", "exthost.prepareWindowReload", "exthost.cancelWindowReload":
            handleExtensionHost(method: method, params: params, token: token)
        case "agentHost.start", "agentHost.stop", "agentHost.status", "agentHost.authorizeDirectories", "agentHost.reauthorizeDirectories":
            handleAgentHost(method: method, params: params, token: token)
        case "terminal.installAutoReply", "terminal.uninstallAllAutoReplies", "terminal.requestHandoff", "terminal.offerHandoff", "terminal.metadata", "terminal.clearBuffer", "terminal.setUnicodeVersion", "terminal.setNextCommandId", "terminal.attachIdentity", "terminal.attach", "terminal.resume", "terminal.detach", "terminal.ackExit", "terminal.serialize", "terminal.incarnation", "terminal.setLayout", "terminal.getLayout", "terminal.create", "terminal.input", "terminal.ack", "terminal.ackBatch", "terminal.resize", "terminal.signal", "terminal.stop", "terminal.cwd", "terminal.list", "terminal.environment", "terminal.pathExists", "terminal.profileEnvironment", "terminal.shells", "terminal.shellIntegrationContext", "terminal.prepareShellIntegration":
            handleTerminal(method: method, params: params, token: token)
        default:
            guard Self.methods.contains(method), method.hasPrefix("fs.") else {
                reject(token, "unknownMethod", "unknown method: \(method)")
                return
            }
            handleFileSystem(method: method, params: params, token: token)
        }
    }

    private func handleExtensionBrowserResourceSnapshot(params: [String: Any], token: ReplyToken) {
        guard Set(params.keys) == ["uris"], let uris = params["uris"] as? [String],
              uris.count <= NativeWorkbenchAssetServer.maximumCatalogPackages,
              Set(uris).count == uris.count, uris.allSatisfy(Self.validWorkspaceURI) else {
            reject(token, "malformedRequest", "invalid extension resource snapshot"); return
        }
        ioQueue.async { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.withAuthorizedExtensionCatalog { result in
                do {
                    let catalog = try result.get()
                    guard let server = self.extensionAssetServer,
                          let entries = catalog["packages"] as? [[String: Any]] else {
                        throw BridgeError(code: "Unavailable", message: "extension resources are unavailable")
                    }
                    let known = Dictionary(entries.compactMap { entry -> (String, String)? in
                        guard let uri = entry["extensionLocation"] as? String, let url = URL(string: uri) else { return nil }
                        return (url.standardizedFileURL.path, uri)
                    }, uniquingKeysWith: { first, _ in first })
                    guard uris.allSatisfy({ URL(string: $0).flatMap { known[$0.standardizedFileURL.path] } != nil }) else { throw BridgeError(code: "NoPermissions", message: "unknown extension package") }
                    let packages = try uris.map { uri -> NativeWorkbenchAssetServer.CatalogPackage in
                        let canonical = known[URL(string: uri)!.standardizedFileURL.path]!
                        let access = try self.fileSystem.authorizedDirectoryAccess(rootURI: canonical)
                        return try NativeWorkbenchAssetServer.CatalogPackage(uri: canonical, generation: access.accessGeneration, isDirectory: true, stableKey: true, openResource: { access.open(path: $0, flags: O_RDONLY | O_NONBLOCK, mode: 0) })
                    }
                    token.send(Self.ok(try self.addBrowserResources(packages, server: server)))
                } catch { self.replyLocalExtensionError(error, token: token) }
            }
        }
    }

    private func handleExtensionBrowserResource(params: [String: Any], token: ReplyToken) {
        guard Set(params.keys) == ["uri"], let text = params["uri"] as? String,
              text.utf8.count <= 16_384, let requested = URL(string: text), requested.isFileURL,
              requested.host == nil || requested.host == "", requested.user == nil, requested.password == nil else {
            reject(token, "InvalidRequest", "invalid extension resource URI")
            return
        }
        ioQueue.async { [weak self] in
            guard let self, !self.isTornDown else { return }
            self.withAuthorizedExtensionCatalog { result in
                do {
                    let catalog = try result.get()
                    guard let server = self.extensionAssetServer,
                          let entries = catalog["packages"] as? [[String: Any]] else {
                        throw BridgeError(code: "Unavailable", message: "extension resources are unavailable")
                    }
                    guard let path = NativeWorkbenchAssetServer.canonicalResourcePath(requested) else {
                        throw BridgeError(code: "InvalidRequest", message: "invalid extension resource path")
                    }
                    let roots = entries.compactMap { $0["extensionLocation"] as? String }
                        .compactMap { text -> (String, URL)? in URL(string: text).map { (text, $0) } }
                        .sorted { $0.1.path.count > $1.1.path.count }
                    guard let (uri, root) = roots.first(where: { path == $0.1.path || path.hasPrefix($0.1.path + "/") }) else {
                        throw BridgeError(code: "NoPermissions", message: "resource is outside the installed extension catalog")
                    }
                    let access = try self.fileSystem.authorizedDirectoryAccess(rootURI: uri)
                    let item = try NativeWorkbenchAssetServer.CatalogPackage(uri: uri, generation: access.accessGeneration, isDirectory: true, stableKey: true, openResource: { access.open(path: $0, flags: O_RDONLY | O_NONBLOCK, mode: 0) })
                    let browserRoots = try self.addBrowserResources([item], server: server)
                    guard let base = browserRoots.first?["browserRoot"].flatMap(URL.init(string:)) else { throw BridgeError(code: "Unavailable", message: "extension resources are unavailable") }
                    let relative = String(path.dropFirst(root.path.count))
                    let resource = relative.split(separator: "/").reduce(base) {
                        $0.appendingPathComponent(String($1), isDirectory: false)
                    }
                    guard let browserURI = NativeWorkbenchAssetServer.browserResourceURL(resource, preserving: requested) else {
                        throw BridgeError(code: "InvalidRequest", message: "invalid extension resource URI")
                    }
                    token.send(Self.ok(["uri": browserURI.absoluteString]))
                } catch let error as BridgeError {
                    token.send(Self.error(error.code, error.message))
                } catch {
                    token.send(Self.error("NoPermissions", "extension resource could not be authorized"))
                }
            }
        }
    }

    /// Authorize the same app-private root used for guest HOME, independently of extension scanning.
    private func authorizedProcessHome() throws -> String {
        if let processHomeURI {
            _ = try fileSystem.authorizedDirectoryAccess(rootURI: processHomeURI)
            return processHomeURI
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodiPad/Process", isDirectory: true)
        for directory in ["home", "data", "cache", "config", "tmp"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
        let uri = try fileSystem.grantDirectory(root, securityScoped: false)
        processHomeURI = uri
        return uri
    }

    /// Called on ioQueue. Publish the filesystem authority's canonical file URLs to every client.
    private func authorizedExtensionCatalog(preparedRoot: URL) throws -> [String: Any] {
        if let catalog = extensionCatalog, let generation = NativeExtensionStore.catalogGeneration(), extensionCatalogGeneration == generation { return catalog }
        var snapshotGeneration: UInt64?
        var catalog = try NativeExtensionCatalog.scan(linuxHost: extensionHost.processRuntime == .linux, preparedRoot: preparedRoot) { root in
                let (inventory, generation) = try NativeExtensionStore.withCatalogSnapshot {
                    try NativeExtensionCatalog.userInventory(in: root)
                }
                snapshotGeneration = generation
                return inventory
            }
        let processHomeURI = try authorizedProcessHome()
        var newRoots: [String: String] = [:]
        try fileSystem.withGrantTransaction { authority in
            for key in ["appRoot", "extensionsHome", "globalStorageHome", "workspaceStorageHome", "logsLocation"] {
                guard let text = catalog[key] as? String, let url = URL(string: text), url.isFileURL else {
                    throw NativeExtensionCatalogError.failure(code: "InvalidHome", message: "invalid native extension home")
                }
                // These locations come from our bundle/private store, never from the page.
                let path = url.standardizedFileURL.path
                if let uri = extensionPrivateRoots[path] ?? newRoots[path] {
                    _ = try authority.authorizedDirectoryAccess(rootURI: uri)
                    catalog[key] = uri
                } else {
                    let uri = try authority.grantDirectory(url, securityScoped: false)
                    newRoots[path] = uri
                    catalog[key] = uri
                }
            }
            let bundledRoot = URL(string: catalog["appRoot"] as! String)!.appendingPathComponent("extensions", isDirectory: true).standardizedFileURL.path
            let userRoot = URL(string: catalog["extensionsHome"] as! String)!.standardizedFileURL.path
            var packageGrants: [String: String] = [:]
            for key in ["extensions", "packages"] {
                guard var entries = catalog[key] as? [[String: Any]] else {
                    throw NativeExtensionCatalogError.failure(code: "InvalidCatalog", message: "missing immutable package inventory")
                }
                for index in entries.indices {
                    guard let text = entries[index]["extensionLocation"] as? String,
                          let url = URL(string: text), url.isFileURL else {
                        throw NativeExtensionCatalogError.failure(code: "InvalidHome", message: "invalid native extension location")
                    }
                    if packageGrants[text] == nil {
                        let access = try authority.authorizedDirectoryAccess(rootURI: text)
                        let parent = URL(fileURLWithPath: access.rootPath, isDirectory: true).deletingLastPathComponent().standardizedFileURL.path
                        guard parent == bundledRoot || parent == userRoot else {
                            throw NativeExtensionCatalogError.failure(code: "InvalidHome", message: "extension package is outside the catalog homes")
                        }
                        packageGrants[text] = URL(fileURLWithPath: access.rootPath, isDirectory: true).absoluteString
                    }
                    entries[index]["extensionLocation"] = packageGrants[text]
                }
                catalog[key] = entries
            }
        }
        extensionPrivateRoots.merge(newRoots) { old, _ in old }
        let processRoots = ["appRoot", "extensionsHome", "globalStorageHome", "workspaceStorageHome", "logsLocation"]
            .compactMap { catalog[$0] as? String }
        try terminalHost.prepareProcessDirectories(processRoots + [processHomeURI], homeURI: processHomeURI)
        if let packages = catalog["packages"] as? [[String: Any]] {
            try browserResourceCatalog?.retainExtensionPackages(Set(packages.compactMap { $0["extensionLocation"] as? String }))
        }
        extensionCatalog = catalog
        extensionCatalogGeneration = snapshotGeneration
        #if DEBUG
        if let entries = catalog["extensions"] as? [[String: Any]] {
            logEvent?(["event": "native.extensionCatalog", "entries": entries.enumerated().map { index, entry in
                ["index": index, "uriIsFile": (entry["extensionLocation"] as? String)?.hasPrefix("file:") == true] as [String: Any]
            }])
        }
        #endif
        return catalog
    }

    /// Start cold bundled-resource verification away from ioQueue, then return to ioQueue before
    /// publishing any grants or catalog state. Callers must invoke this from ioQueue.
    private func withAuthorizedExtensionCatalog(
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        if let extensionCatalog, let generation = NativeExtensionStore.catalogGeneration(), extensionCatalogGeneration == generation {
            completion(.success(extensionCatalog))
            return
        }
        extensionCatalog = nil
        extensionCatalogGeneration = nil
        extensionCatalogPreparationWaiters.append(completion)
        guard !extensionCatalogPreparationInFlight else { return }
        extensionCatalogPreparationInFlight = true
        NativeExtensionCatalog.prepareBundledHostRoot() { [weak self] result in
            guard let self else { return }
            self.ioQueue.async {
                let waiters = self.extensionCatalogPreparationWaiters
                self.extensionCatalogPreparationWaiters.removeAll()
                self.extensionCatalogPreparationInFlight = false
                let catalogResult: Result<[String: Any], Error>
                if self.isTornDown {
                    catalogResult = .failure(BridgeError(code: "hostTornDown", message: "the native host went away before extension resources were prepared"))
                } else {
                    do {
                        let root = try result.get()
                        catalogResult = .success(try self.authorizedExtensionCatalog(preparedRoot: root))
                    } catch {
                        catalogResult = .failure(error)
                    }
                }
                for waiter in waiters {
                    waiter(catalogResult)
                }
            }
        }
    }

    private func addBrowserResources(_ packages: [NativeWorkbenchAssetServer.CatalogPackage], server: NativeWorkbenchAssetLease) throws -> [[String: String]] {
        let capability = try browserResourceCatalog ?? server.registerExtensionCatalog()
        let roots = try capability.add(packages)
        browserResourceCatalog = capability
        return roots
    }

    /// Returns path identity only for URIs whose live grants are owned by `WorkspaceFileSystem`.
    /// This bridge keeps no parallel grant registry; every answer is re-authorized by the authority.
    private func pathCapabilityMetadata(forURIs uris: [String], publishBrowserResources: Bool = false) throws -> [[String: Any]] {
        var seen = Set<String>()
        let unique = uris.filter { seen.insert($0).inserted }
        var metadata: [[String: Any]] = try unique.map { uri in
            do {
                guard let reply = try fileSystem.perform("fs.pathCapabilities", params: ["uri": uri]) as? [String: Any],
                      let sensitive = reply["pathCaseSensitive"] as? Bool else {
                    throw BridgeError(code: "PathCapabilitiesUnavailable", message: "native authority returned incomplete path capabilities")
                }
                return ["uri": uri, "pathCaseSensitive": sensitive]
            } catch let error as BridgeError { throw error }
            catch { throw BridgeError(code: "PathCapabilitiesUnavailable", message: "native authority could not confirm path identity metadata") }
        }
        guard publishBrowserResources, !unique.isEmpty else { return metadata }
        guard let server = extensionAssetServer else { throw BridgeError(code: "Unavailable", message: "browser resources are unavailable") }
        let packages = try unique.map { uri -> NativeWorkbenchAssetServer.CatalogPackage in
            let access = try fileSystem.browserResourceAccess(rootURI: uri)
            return try NativeWorkbenchAssetServer.CatalogPackage(uri: uri, generation: access.generation, isDirectory: access.isDirectory, openResource: access.open)
        }
        let roots = try addBrowserResources(packages, server: server)
        for index in metadata.indices {
            metadata[index]["browserResource"] = ["kind": packages[index].isDirectory ? "directory" : "file", "uri": roots[index]["browserRoot"]!]
        }
        return metadata
    }

    private func pathCapabilityMetadata(inCatalog catalog: [String: Any]) throws -> [[String: Any]] {
        var uris = [String]()
        for key in ["appRoot", "extensionsHome", "globalStorageHome", "workspaceStorageHome", "logsLocation"] {
            if let uri = catalog[key] as? String { uris.append(uri) }
        }
        if let entries = catalog["packages"] as? [[String: Any]] {
            uris.append(contentsOf: entries.compactMap { $0["extensionLocation"] as? String })
        }
        return try pathCapabilityMetadata(forURIs: uris)
    }

    private func handleMarketplaceRequest(params: [String: Any], token: ReplyToken) {
        guard Set(params.keys).isSubset(of: ["requestId", "url", "method", "headers", "bodyBase64"]),
              let requestId = Self.installRequestID(params),
              let text = params["url"] as? String, text.count <= 16_384, let url = URL(string: text),
              params["method"] == nil || params["method"] is String,
              params["headers"] == nil || params["headers"] is [String: String],
              params["bodyBase64"] == nil || params["bodyBase64"] is String else {
            reject(token, "malformedRequest", "invalid Marketplace request")
            return
        }
        let encodedBody = params["bodyBase64"] as? String ?? ""
        guard encodedBody.utf8.count <= ((NativeMarketplaceClient.maximumRequestBodyBytes + 2) / 3) * 4,
              let body = Data(base64Encoded: encodedBody), body.count <= NativeMarketplaceClient.maximumRequestBodyBytes else {
            reject(token, "RequestTooLarge", "invalid or oversized Marketplace body")
            return
        }
        let method = params["method"] as? String ?? "GET"
        let headers = params["headers"] as? [String: String] ?? [:]
        marketplaceTaskLock.lock()
        if marketplacePendingCancellations.removeValue(forKey: requestId) != nil {
            marketplaceTaskLock.unlock()
            reject(token, "Cancelled", "Marketplace request cancelled")
            return
        }
        guard marketplaceTasks[requestId] == nil, !isTornDown else {
            marketplaceTaskLock.unlock()
            reject(token, "DuplicateRequest", "Marketplace request identity is already active")
            return
        }
        let task = Task { [weak self] in
            guard let self, !self.isTornDown else { return }
            defer {
                self.marketplaceTaskLock.lock()
                self.marketplaceTasks.removeValue(forKey: requestId)
                self.marketplaceTaskLock.unlock()
            }
            do {
                let response = try await self.marketplace.request(url: url, method: method, headers: headers, body: body.isEmpty ? nil : body)
                guard !self.isTornDown else { return }
                token.send(Self.ok(["status": response.status, "headers": response.headers, "bodyBase64": response.body.base64EncodedString()]))
            } catch is CancellationError {
                token.send(Self.error("Cancelled", "Marketplace request cancelled"))
            } catch let error as NativeMarketplaceError {
                token.send(Self.error(error.code, error.message))
            } catch {
                token.send(Self.error("MarketplaceRequestFailed", error.localizedDescription))
            }
        }
        marketplaceTasks[requestId] = task
        marketplaceTaskLock.unlock()
    }

    private func publishTemporaryVSIX(_ archive: Data, token: ReplyToken) {
        guard !isTornDown, token.isPending else { return }
        let file = extensionDownloadDirectory.appendingPathComponent(UUID().uuidString + ".vsix")
        do {
            let root = try authorizedExtensionDownloadRoot()
            try archive.write(to: file, options: .atomic)
            guard let uri = URL(string: root)?.appendingPathComponent(file.lastPathComponent).absoluteString else {
                throw BridgeError(code: "InvalidHome", message: "The temporary extension directory is unavailable")
            }
            token.send(Self.ok(uri, pathCapabilities: try pathCapabilityMetadata(forURIs: [uri])))
        } catch {
            try? FileManager.default.removeItem(at: file)
            replyLocalExtensionError(error, token: token)
        }
    }

    private func authorizedExtensionDownloadRoot() throws -> String {
        if let existing = extensionDownloadURI {
            _ = try fileSystem.authorizedDirectoryAccess(rootURI: existing)
            return existing
        }
        try FileManager.default.createDirectory(at: extensionDownloadDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let root = try fileSystem.grantDirectory(extensionDownloadDirectory, securityScoped: false)
        extensionDownloadURI = root
        return root
    }

    private func handleExtensionExport(params: [String: Any], token: ReplyToken) {
        guard Set(params.keys) == ["uri"], let uri = params["uri"] as? String,
              Self.validWorkspaceURI(uri), let location = URL(string: uri) else {
            reject(token, "malformedRequest", "invalid extension export location"); return
        }
        ioQueue.async { [weak self] in
            guard let self, !self.isTornDown else { return }
            do { self.publishTemporaryVSIX(try self.extensionStore.retainedVSIX(extensionLocation: location), token: token) }
            catch { self.replyLocalExtensionError(error, token: token) }
        }
    }

    private func handleExtensionDownload(params: [String: Any], token: ReplyToken) {
        guard Set(params.keys) == ["id", "version", "targetPlatform", "downloadUri"],
              let id = params["id"] as? String, let version = params["version"] as? String,
              let platform = params["targetPlatform"] as? String,
              let text = params["downloadUri"] as? String, text.utf8.count <= 16_384,
              let url = URL(string: text) else {
            reject(token, "malformedRequest", "invalid Marketplace extension download"); return
        }
        let requestId = "download:" + UUID().uuidString
        marketplaceTaskLock.lock()
        guard !isTornDown else { marketplaceTaskLock.unlock(); return }
        let task = Task { [weak self] in
            guard let self, !self.isTornDown else { return }
            defer {
                self.marketplaceTaskLock.lock()
                self.marketplaceTasks.removeValue(forKey: requestId)
                self.marketplaceTaskLock.unlock()
            }
            do {
                let archive = try await self.extensionStore.downloadGalleryVSIX(id: id, version: version, targetPlatform: platform, downloadURI: url)
                self.ioQueue.async { self.publishTemporaryVSIX(archive, token: token) }
            } catch { self.replyLocalExtensionError(error, token: token) }
        }
        marketplaceTasks[requestId] = task
        marketplaceTaskLock.unlock()
    }

    private func handleExtensionInstall(params: [String: Any], token: ReplyToken) {
        guard Set(params.keys) == ["requestId", "id", "version", "targetPlatform", "downloadUri", "options"],
              let requestId = Self.installRequestID(params),
              let id = params["id"] as? String, let version = params["version"] as? String,
              let platform = params["targetPlatform"] as? String,
              let text = params["downloadUri"] as? String, text.count <= 16_384,
              let download = URL(string: text),
              let options = params["options"] as? [String: Bool],
              Set(options.keys).isSubset(of: ["pinned", "preRelease", "isMachineScoped", "installPreReleaseVersion", "isPreReleaseVersion", "hasPreReleaseVersion", "isApplicationScoped"]) else {
            reject(token, "malformedRequest", "invalid Marketplace extension install")
            return
        }
        ioQueue.async { [weak self] in
            guard let self, !self.isTornDown else { return }
            // Upstream schedules dependencies and extension-pack members concurrently. Queue
            // package commits and catalog refreshes without rejecting otherwise valid requests.
            self.enqueueExtensionInstall(requestId: requestId, token: token) {
                do {
                    let published = try await self.extensionStore.install(id: id, version: version, targetPlatform: platform, downloadURI: download, options: options)
                    self.ioQueue.async {
                        self.extensionCatalog = nil
                        guard !self.isTornDown else {
                            self.finishExtensionInstall(requestId: requestId)
                            return
                        }
                        self.withAuthorizedExtensionCatalog { result in
                            defer { self.finishExtensionInstall(requestId: requestId) }
                            guard !self.isTornDown else { return }
                            do {
                                let catalog = try result.get()
                                guard let entries = catalog["packages"] as? [[String: Any]],
                                      let installed = entries.first(where: {
                                          ($0["extensionLocation"] as? String) == (published["extensionLocation"] as? String)
                                      }) else {
                                    throw NativeExtensionCatalogError.failure(code: "InstalledExtensionMissing", message: "installed extension is absent from the native catalog")
                                }
                                self.logEvent?(["event": "native.extensionInstalled", "extensionId": id, "version": version])
                                token.send(Self.ok(installed, pathCapabilities: try self.pathCapabilityMetadata(inCatalog: catalog)))
                            } catch let error as NativeExtensionCatalogError {
                                token.send(Self.error(error.code, error.message))
                            } catch let error as BridgeError {
                                token.send(Self.error(error.code, error.message))
                            } catch {
                                token.send(Self.error("CatalogFailure", error.localizedDescription))
                            }
                        }
                    }
                } catch {
                    self.ioQueue.async {
                        defer { self.finishExtensionInstall(requestId: requestId) }
                        guard !self.isTornDown else { return }
                        if error is CancellationError {
                            token.send(Self.error("Cancelled", "extension installation cancelled"))
                        } else if let failure = error as? NativeExtensionStoreError {
                            token.send(Self.error(failure.code, failure.message))
                        } else if let failure = error as? NativeMarketplaceError {
                            token.send(Self.error(failure.code, failure.message))
                        } else {
                            token.send(Self.error("InstallFailed", error.localizedDescription))
                        }
                    }
                }
            }
        }
    }

    private func handleLocalExtensionOperation(method: String, params: [String: Any], token: ReplyToken) {
        // Profile manifests own membership. A package may still be referenced by another profile
        // or a live host; physical collection has no implemented lifetime contract yet.
        if method == "extension.uninstall" {
            reject(token, "UnsupportedOperation", "remove profile membership through extension management; physical package deletion is unsupported")
            return
        }
        let installing = method == "extension.installVSIX"
        let expected: Set<String> = installing ? ["requestId", "uri", "id", "version", "options"] : ["uri"]
        let optionNames: Set<String> = ["pinned", "preRelease", "isMachineScoped", "installPreReleaseVersion", "isPreReleaseVersion", "hasPreReleaseVersion", "isApplicationScoped"]
        guard Set(params.keys) == expected,
              let text = params["uri"] as? String, text.utf8.count <= 16_384,
              let location = URL(string: text), location.isFileURL, location.host == nil || location.host == "",
              location.query == nil, location.fragment == nil, !location.path.contains("\0") else {
            reject(token, "malformedRequest", "invalid local extension operation")
            return
        }
        let rawOptions = params["options"] as? [String: Any] ?? [:]
        guard !installing || (Self.installRequestID(params) != nil && params["id"] is String && params["version"] is String && params["options"] is [String: Any] &&
                Set(rawOptions.keys).isSubset(of: optionNames) && rawOptions.values.allSatisfy {
                    guard let value = $0 as? NSNumber else { return false }
                    return CFGetTypeID(value) == CFBooleanGetTypeID()
                }) else {
            reject(token, "malformedRequest", "invalid local extension install options")
            return
        }
        ioQueue.async { [weak self] in
            guard let self, !self.isTornDown else { return }
            if installing {
                let requestId = Self.installRequestID(params)!
                self.enqueueExtensionInstall(requestId: requestId, token: token) {
                    do {
                        let archive = try self.ioQueue.sync {
                            try self.fileSystem.readFileData(text, maximumBytes: NativeMarketplaceClient.maximumResponseBodyBytes)
                        }
                        try Task.checkCancellation()
                        let value = try self.extensionStore.installVSIX(archive, id: params["id"] as! String,
                            version: params["version"] as! String, targetPlatform: "linux-arm64",
                            options: rawOptions.mapValues { ($0 as! NSNumber).boolValue })
                        self.ioQueue.async {
                            self.extensionCatalog = nil
                            guard !self.isTornDown else { self.finishExtensionInstall(requestId: requestId); return }
                            self.withAuthorizedExtensionCatalog { result in
                                defer { self.finishExtensionInstall(requestId: requestId) }
                                guard !self.isTornDown else { return }
                                do {
                                    let catalog = try result.get()
                                    self.logEvent?(["event": "native.extensionInstalled", "extensionId": params["id"] as! String,
                                                    "version": params["version"] as! String, "source": "vsix"])
                                    token.send(Self.ok(value, pathCapabilities: try self.pathCapabilityMetadata(inCatalog: catalog)))
                                } catch { self.replyLocalExtensionError(error, token: token) }
                            }
                        }
                    } catch {
                        self.ioQueue.async {
                            self.replyLocalExtensionError(error, token: token)
                            self.finishExtensionInstall(requestId: requestId)
                        }
                    }
                }
                return
            }
            self.extensionInstallQueue.append((requestId: nil, run: { [weak self] in
                guard let self, !self.isTornDown else { return }
                do {
                    let archive = try self.fileSystem.readFileData(text,
                        maximumBytes: NativeMarketplaceClient.maximumResponseBodyBytes)
                    let value = try self.extensionStore.getVSIXManifest(archive)
                    token.send(Self.ok(value))
                    self.finishExtensionInstall()
                } catch {
                    self.replyLocalExtensionError(error, token: token)
                    self.finishExtensionInstall()
                }
            }))
            self.startNextExtensionInstall()
        }
    }

    private func replyLocalExtensionError(_ error: Error, token: ReplyToken) {
        switch error {
        case is CancellationError: token.send(Self.error("Cancelled", "extension installation cancelled"))
        case let failure as WorkspaceFileSystemError: token.send(Self.error(failure.code, failure.message))
        case let failure as NativeExtensionStoreError: token.send(Self.error(failure.code, failure.message))
        case let failure as NativeExtensionCatalogError: token.send(Self.error(failure.code, failure.message))
        case let failure as NativeAgentHost.Failure: token.send(Self.error(failure.code, failure.message))
        case let failure as NativeTerminalHostError: token.send(Self.error(failure.code, failure.message))
        case let failure as BridgeError: token.send(Self.error(failure.code, failure.message))
        default: token.send(Self.error("ExtensionOperationFailed", error.localizedDescription))
        }
    }

    private func handleExtensionMetadataUpdate(params: [String: Any], token: ReplyToken) {
        guard Set(params.keys) == ["extensionLocation", "metadata"],
              let text = params["extensionLocation"] as? String, text.utf8.count <= 16_384,
              let location = URL(string: text), location.isFileURL,
              location.query == nil, location.fragment == nil, !location.path.contains("\0"),
              let metadata = params["metadata"] as? [String: Any],
              Self.validExtensionMetadata(metadata) else {
            reject(token, "malformedRequest", "invalid installed extension metadata update")
            return
        }
        ioQueue.async { [weak self] in
            guard let self, !self.isTornDown else { return }
            // Serialize with package commits so metadata updates cannot race their catalog
            // snapshot. The store validates this exact package under the app-owned home.
            self.extensionInstallQueue.append((requestId: nil, run: { [weak self] in
                guard let self else { return }
                guard !self.isTornDown else { self.finishExtensionInstall(); return }
                self.withAuthorizedExtensionCatalog { initialResult in
                    do {
                        _ = try initialResult.get()
                        let entry = try self.extensionStore.updateMetadata(extensionLocation: location, metadata: metadata)
                        self.extensionCatalog = nil
                        self.withAuthorizedExtensionCatalog { catalogResult in
                            defer { self.finishExtensionInstall() }
                            guard !self.isTornDown else { return }
                            do {
                                let catalog = try catalogResult.get()
                                token.send(Self.ok(entry, pathCapabilities: try self.pathCapabilityMetadata(inCatalog: catalog)))
                            } catch let error as NativeExtensionStoreError {
                                token.send(Self.error(error.code, error.message))
                            } catch let error as NativeExtensionCatalogError {
                                token.send(Self.error(error.code, error.message))
                            } catch let error as BridgeError {
                                token.send(Self.error(error.code, error.message))
                            } catch {
                                token.send(Self.error("MetadataUpdateFailed", error.localizedDescription))
                            }
                        }
                    } catch let error as NativeExtensionStoreError {
                        self.finishExtensionInstall()
                        token.send(Self.error(error.code, error.message))
                    } catch let error as NativeExtensionCatalogError {
                        self.finishExtensionInstall()
                        token.send(Self.error(error.code, error.message))
                    } catch let error as BridgeError {
                        self.finishExtensionInstall()
                        token.send(Self.error(error.code, error.message))
                    } catch {
                        self.finishExtensionInstall()
                        token.send(Self.error("MetadataUpdateFailed", error.localizedDescription))
                    }
                }
            }))
            self.startNextExtensionInstall()
        }
    }

    /// The pinned upstream Metadata shape. Null removes a field; package provenance is not
    /// writable through this operation. Boolean and numeric JSON values stay distinct.
    private static func validExtensionMetadata(_ metadata: [String: Any]) -> Bool {
        let booleans: Set<String> = ["private", "isPreReleaseVersion", "isApplicationScoped",
            "isMachineScoped", "isBuiltin", "isSystem", "updated", "preRelease", "hasPreReleaseVersion", "pinned"]
        let strings: Set<String> = ["id", "publisherId", "publisherDisplayName", "targetPlatform", "source"]
        let numbers: Set<String> = ["installedTimestamp", "size"]
        for (key, value) in metadata {
            guard booleans.contains(key) || strings.contains(key) || numbers.contains(key) else { return false }
            if value is NSNull { continue }
            if booleans.contains(key) {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            } else if strings.contains(key) {
                guard let text = value as? String, text.utf8.count <= 4_096, !text.contains("\0") else { return false }
                if key == "source" && !["gallery", "vsix", "resource"].contains(text) { return false }
            } else {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
                let amount = number.doubleValue
                guard amount.isFinite, amount.rounded(.towardZero) == amount,
                      amount >= 0, amount <= 9_007_199_254_740_991 else { return false }
            }
        }
        return true
    }

    private static func installRequestID(_ params: [String: Any]) -> String? {
        guard let id = params["requestId"] as? String, id.utf8.count == 36,
              UUID(uuidString: id) != nil else { return nil }
        return id.lowercased()
    }

    /// Track before queuing so cancellation and teardown also reach waiting installs.
    private func enqueueExtensionInstall(requestId: String, token: ReplyToken,
                                         operation: @escaping () async -> Void) {
        extensionInstallTaskLock.lock()
        defer { extensionInstallTaskLock.unlock() }
        guard !isTornDown else { return }
        guard extensionInstallTasks[requestId] == nil else {
            reject(token, "DuplicateRequest", "extension install identity is already active")
            return
        }
        extensionInstallTasks[requestId] = Task {
            let started = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                self.ioQueue.async {
                    self.extensionInstallTaskLock.lock()
                    let cancelled = self.extensionInstallTasks[requestId]?.isCancelled != false
                    self.extensionInstallTaskLock.unlock()
                    guard !self.isTornDown, !cancelled else { continuation.resume(returning: false); return }
                    self.waitingExtensionInstalls[requestId] = { continuation.resume(returning: false) }
                    self.extensionInstallQueue.append((requestId: requestId, run: {
                        self.waitingExtensionInstalls.removeValue(forKey: requestId)
                        continuation.resume(returning: true)
                    }))
                    self.startNextExtensionInstall()
                }
            }
            guard started, !Task.isCancelled else {
                token.send(Self.error("Cancelled", "extension installation cancelled"))
                self.ioQueue.async {
                    if started { self.finishExtensionInstall(requestId: requestId) }
                    else {
                        self.extensionInstallTaskLock.lock()
                        self.extensionInstallTasks.removeValue(forKey: requestId)
                        self.extensionInstallTaskLock.unlock()
                    }
                }
                return
            }
            await operation()
        }
    }

    /// All queue operations run on ioQueue. Teardown settles queued reply tokens separately.
    private func startNextExtensionInstall() {
        guard !extensionInstallInFlight else { return }
        guard !isTornDown else {
            extensionInstallQueue.removeAll()
            return
        }
        guard !extensionInstallQueue.isEmpty else { return }
        extensionInstallInFlight = true
        extensionInstallQueue.removeFirst().run()
    }

    private func finishExtensionInstall(requestId: String? = nil) {
        if let requestId {
            extensionInstallTaskLock.lock()
            extensionInstallTasks.removeValue(forKey: requestId)
            extensionInstallTaskLock.unlock()
        }
        extensionInstallInFlight = false
        startNextExtensionInstall()
    }

    private func openWorkspaceState() throws -> NativeWorkspaceState {
        if let workspaceState { return workspaceState }
        let state = try NativeWorkspaceState(fileSystem: fileSystem, sceneID: sceneID, canAdoptLegacy: canAdoptLegacy)
        workspaceState = state
        return state
    }

    private func handleWorkspace(method: String, params: [String: Any], token: ReplyToken) {
        let file = (params["workspaceFile"] as? NSNumber).map {
            CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue
        } ?? false
        let allowed: Set<String>
        switch method {
        case "workspace.current": allowed = []
        case "workspace.cancel": allowed = ["workspaceId", "preparationToken"]
        case "workspace.identify": allowed = file ? ["uri", "workspaceFile", "folderUris", "contents"] : ["uri"]
        case "workspace.completeRelocation": allowed = ["uri", "workspaceId", "previousFolderUris"]
        default: allowed = file ? ["uri", "workspaceFile", "folderUris", "workspaceId", "preparationToken"] : ["uri", "workspaceId"]
        }
        func bounded(_ key: String, limit: Int) -> Bool {
            (params[key] as? String).map { !$0.isEmpty && $0.utf8.count <= limit } == true
        }
        guard Set(params.keys) == allowed,
              ["workspace.current", "workspace.cancel"].contains(method) || bounded("uri", limit: 32768),
              !["workspace.commit", "workspace.cancel", "workspace.completeRelocation"].contains(method) || bounded("workspaceId", limit: 256),
              !(file && method == "workspace.commit" || method == "workspace.cancel") || bounded("preparationToken", limit: 256) else {
            reject(token, "malformedRequest", "invalid native workspace state request")
            return
        }
        if file {
            guard let roots = params["folderUris"] as? [String], roots.allSatisfy(Self.validWorkspaceURI),
                  Self.validWorkspaceURI(params["uri"] as! String),
                  method != "workspace.identify" || ((params["contents"] as? String).map { $0.utf8.count <= 1_398_104 && Data(base64Encoded: $0) != nil } == true) else {
                reject(token, "malformedRequest", "invalid workspace file resources or contents")
                return
            }
        }
        if method == "workspace.completeRelocation" {
            guard let roots = params["previousFolderUris"] as? [String], !roots.isEmpty, roots.count <= 32,
                  roots.allSatisfy(Self.validWorkspaceURI) else {
                reject(token, "malformedRequest", "invalid native workspace relocation acknowledgement")
                return
            }
        }
        ioQueue.async { [weak self] in
            guard let self, !self.isTornDown else { return }
            do {
                _ = try self.openWorkspaceState()
                if file && method == "workspace.identify" {
                    let snapshot = try self.fileSystem.readFileSnapshot(params["uri"] as! String, maximumBytes: 1024 * 1024)
                    guard snapshot.data == Data(base64Encoded: params["contents"] as! String)! else {
                        throw BridgeError(code: "WorkspaceIdentityMismatch", message: "workspace config changed before authorization")
                    }
                    let roots = params["folderUris"] as! [String]
                    let missing = roots.filter { (try? self.fileSystem.authorizedDirectoryAccess(rootURI: $0)) == nil }
                    if missing.isEmpty {
                        let reply = try self.prepareWorkspaceFile(params: params, pickedURLs: [])
                        try self.installPreparedWorkspace(reply)
                        self.replyWorkspace(reply, method: method, token: token)
                    } else {
                        self.pickWorkspaceRoots(token: token, initialURI: missing[0]) { [weak self] urls in
                            guard let self else { return }
                            self.ioQueue.async {
                                guard !self.isTornDown else { return }
                                guard !urls.isEmpty else { token.send(Self.ok(NSNull())); return }
                                do {
                                    let reply = try self.prepareWorkspaceFile(params: params, pickedURLs: urls)
                                    try self.installPreparedWorkspace(reply)
                                    self.replyWorkspace(reply, method: method, token: token)
                                } catch { self.rejectWorkspace(error, method: method, token: token) }
                            }
                        }
                    }
                } else {
                    let reply = try self.performWorkspaceOperation(method: method, params: params)
                    self.replyWorkspace(reply, method: method, token: token)
                }
            } catch { self.rejectWorkspace(error, method: method, token: token) }
        }
    }

    // Synchronous workspace boundary; exercised by the existing host bridge projection.
    private struct PreparedNativeWorkspace {
        let identity: NativeWorkspaceIdentity
        let access: [WorkspaceNativeToolAccess]
    }
    private typealias WorkspaceReply = (value: Any, metadata: [[String: Any]], identity: NativeWorkspaceIdentity?)

    private static func validWorkspaceURI(_ uri: String) -> Bool {
        guard uri.utf8.count <= 32768, let url = URL(string: uri), url.isFileURL,
              url.host == nil || url.host == "", url.path.hasPrefix("/"), !url.path.contains("\0"),
              url.query == nil, url.fragment == nil,
              !url.pathComponents.contains(".."), !url.pathComponents.contains(".") else { return false }
        return true
    }

    private func workspaceResources(_ identity: NativeWorkspaceIdentity) -> [String] {
        if let workspace = identity.workspaceURI { return [workspace] + identity.folderURIs }
        return identity.folderURI.map { [$0] } ?? []
    }

    private func workspaceValue(_ identity: NativeWorkspaceIdentity?) -> [String: Any] {
        guard let identity else { return ["folderUri": NSNull()] }
        var value: [String: Any] = ["workspaceId": identity.workspaceID]
        if let workspace = identity.workspaceURI {
            value["workspaceUri"] = workspace
            value["folderUris"] = identity.folderURIs
            if let token = identity.preparationToken { value["preparationToken"] = token }
        } else {
            value["folderUri"] = identity.folderURI
            if !identity.previousFolderURIs.isEmpty { value["previousFolderUris"] = identity.previousFolderURIs }
        }
        return value
    }

    private func workspaceAccess(_ identity: NativeWorkspaceIdentity) throws -> [WorkspaceNativeToolAccess] {
        try (identity.workspaceURI == nil ? identity.folderURI.map { [$0] } ?? [] : identity.folderURIs)
            .map { try fileSystem.authorizedDirectoryAccess(rootURI: $0) }
    }

    private func prepareWorkspaceFile(params: [String: Any], pickedURLs: [URL]) throws -> WorkspaceReply {
        let state = workspaceState!
        return try fileSystem.withGrantTransaction { fs in
            var identity: NativeWorkspaceIdentity?
            var access: [WorkspaceNativeToolAccess] = []
            do {
                for url in pickedURLs {
                    guard url.isFileURL, url.hasDirectoryPath else {
                        throw BridgeError(code: "invalidSelection", message: "workspace roots require directory selections")
                    }
                    _ = try fs.grantDirectory(url, securityScoped: !Self.isInsideAppDocuments(url))
                }
                identity = try state.identifyWorkspace(uri: params["uri"] as! String,
                    folderURIs: params["folderUris"] as! [String], contents: Data(base64Encoded: params["contents"] as! String)!)
                preparedNativeWorkspaces = preparedNativeWorkspaces.filter { $0.value.identity.workspaceID != identity!.workspaceID }
                access = try workspaceAccess(identity!)
                let metadata = try pathCapabilityMetadata(forURIs: workspaceResources(identity!), publishBrowserResources: true)
                preparedNativeWorkspaces[identity!.preparationToken!] = PreparedNativeWorkspace(identity: identity!, access: access)
                return (workspaceValue(identity), metadata, identity)
            } catch {
                // Drop every descriptor owner before the enclosing grant transaction rolls back.
                defer {
                    if let token = identity?.preparationToken { preparedNativeWorkspaces.removeValue(forKey: token) }
                    access.removeAll()
                }
                if let identity, let token = identity.preparationToken {
                    try state.cancelWorkspace(workspaceID: identity.workspaceID, preparationToken: token)
                }
                throw error
            }
        }
    }

    private func installPreparedWorkspace(_ reply: WorkspaceReply) throws {
        guard let identity = reply.identity, let token = identity.preparationToken,
              let prepared = preparedNativeWorkspaces[token] else {
            throw BridgeError(code: "WorkspaceIdentityMismatch", message: "workspace preparation does not match")
        }
        do {
            // Upstream initialization can activate extensions before selection is saved. Publish
            // already-authorized mappings now, strictly outside the completed grant transaction.
            try terminalHost.installAuthorizedWorkspaceRoots(prepared.access)
        } catch {
            defer { preparedNativeWorkspaces.removeValue(forKey: token) }
            try workspaceState!.cancelWorkspace(workspaceID: identity.workspaceID, preparationToken: token)
            throw error
        }
    }

    private func performWorkspaceOperation(method: String, params: [String: Any]) throws -> WorkspaceReply {
        let state = workspaceState!
        if method == "workspace.cancel" {
            let token = params["preparationToken"] as! String
            if let prepared = preparedNativeWorkspaces[token] {
                guard prepared.identity.workspaceID == params["workspaceId"] as? String else {
                    throw BridgeError(code: "WorkspaceIdentityMismatch", message: "workspace preparation does not match")
                }
                try state.cancelWorkspace(workspaceID: prepared.identity.workspaceID, preparationToken: token)
                preparedNativeWorkspaces.removeValue(forKey: token)
            }
            return (NSNull(), [], nil)
        }
        if params["workspaceFile"] as? Bool == true && method == "workspace.commit" {
            let token = params["preparationToken"] as! String
            guard let prepared = preparedNativeWorkspaces[token], prepared.identity.workspaceID == params["workspaceId"] as? String else {
                throw BridgeError(code: "WorkspaceIdentityMismatch", message: "workspace preparation does not match")
            }
            do {
                let metadata = try pathCapabilityMetadata(forURIs: workspaceResources(prepared.identity), publishBrowserResources: true)
                // All grant transactions finished before publishing process mounts. Successful
                // mounts retain their owners for the app-global kernel, even if persistence fails.
                try terminalHost.installAuthorizedWorkspaceRoots(prepared.access)
                try state.commitWorkspace(uri: params["uri"] as! String, folderURIs: params["folderUris"] as! [String],
                    workspaceID: prepared.identity.workspaceID, preparationToken: token)
                for item in prepared.access { committedNativeWorkspaceAccess[item.rootPath] = item }
                preparedNativeWorkspaces.removeValue(forKey: token)
                return (NSNull(), metadata, prepared.identity)
            } catch {
                defer { preparedNativeWorkspaces.removeValue(forKey: token) }
                try state.cancelWorkspace(workspaceID: prepared.identity.workspaceID, preparationToken: token)
                throw error
            }
        }
        let identity: NativeWorkspaceIdentity?
        let metadata: [[String: Any]]
        var restoredAccess: [WorkspaceNativeToolAccess] = []
        if method == "workspace.current" {
            // Capability failure must roll back newly restored grants too.
            (identity, metadata) = try fileSystem.withGrantTransaction { _ in
                let identity = try state.current()
                do {
                    restoredAccess = try identity.map(workspaceAccess) ?? []
                    let metadata = try identity.map { try pathCapabilityMetadata(forURIs: workspaceResources($0), publishBrowserResources: true) } ?? []
                    return (identity, metadata)
                } catch {
                    restoredAccess.removeAll()
                    throw error
                }
            }
        } else {
            identity = try state.identify(uri: params["uri"] as! String)
            if method == "workspace.commit", identity?.workspaceID != params["workspaceId"] as? String {
                throw BridgeError(code: "WorkspaceIdentityMismatch", message: "workspace identity does not match")
            }
            metadata = try pathCapabilityMetadata(forURIs: workspaceResources(identity!), publishBrowserResources: true)
        }
        if method == "workspace.completeRelocation" {
            try state.completeRelocation(uri: params["uri"] as! String, workspaceID: params["workspaceId"] as! String,
                                         previousFolderURIs: params["previousFolderUris"] as! [String])
        }
        if method == "workspace.current" || method == "workspace.commit", let identity {
            let access = method == "workspace.current" ? restoredAccess : try workspaceAccess(identity)
            try terminalHost.installAuthorizedWorkspaceRoots(access)
            if method == "workspace.commit" { try state.commit(uri: params["uri"] as! String, workspaceID: params["workspaceId"] as! String) }
            for item in access { committedNativeWorkspaceAccess[item.rootPath] = item }
        }
        return (["workspace.commit", "workspace.completeRelocation"].contains(method) ? NSNull() : workspaceValue(identity), metadata, identity)
    }
    // End synchronous workspace boundary.

    private func replyWorkspace(_ reply: WorkspaceReply, method: String, token: ReplyToken) {
        DispatchQueue.main.async {
            guard !self.isTornDown else { return }
            if ["workspace.current", "workspace.commit"].contains(method) {
                self.lastFolderURI = reply.identity?.folderURI ?? reply.identity?.folderURIs.first
            }
            token.send(Self.ok(reply.value, pathCapabilities: reply.metadata))
        }
    }

    private func rejectWorkspace(_ error: Error, method: String, token: ReplyToken) {
        let code = (error as? WorkspaceFileSystemError)?.code ?? (error as? BridgeError)?.code
            ?? (error as? NativeTerminalHostError)?.code ?? "WorkspaceStateUnavailable"
        let message = (error as? NativeTerminalHostError)?.message ?? "The native workspace state operation failed"
        DispatchQueue.main.async {
            guard !self.isTornDown else { return }
            self.logEvent?(["event": "native.workspaceStateFailed", "operation": method, "code": code])
            if method == "workspace.current" {
                self.lastFolderURI = nil
                token.send(Self.ok(["folderUri": NSNull(), "restoreUnavailable": true]))
            } else { token.send(Self.error(code, message)) }
        }
    }

    /// Collect raw selections first; no file grant or native identity is published by this picker.
    private func pickWorkspaceRoots(token: ReplyToken, initialURI: String, completion: @escaping ([URL]) -> Void) {
        DispatchQueue.main.async {
            guard !self.isTornDown else { return }
            guard !self.pickerInFlight else { self.reject(token, "pickerBusy", "a document picker is already open"); return }
            guard let presenter = self.presenter, presenter.viewIfLoaded?.window != nil else {
                self.reject(token, "noPresenter", "no native view is available to present a picker"); return
            }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.allowsMultipleSelection = true
            picker.directoryURL = URL(string: initialURI)
            picker.delegate = self
            self.pickerInFlight = true
            self.activePickerReply = token
            self.activeWorkspacePicker = completion
            presenter.present(picker, animated: true)
        }
    }

    private func handleTerminal(method: String, params: [String: Any], token: ReplyToken) {
        let fields: [String: Set<String>] = [
            "terminal.requestHandoff": ["workspaceId", "targetWorkspaceId", "instanceId"],
            "terminal.offerHandoff": ["requestId", "sessionId"],
            "terminal.create": ["cols", "rows", "cwdUri", "executable", "args", "env", "unsetEnv", "workspaceId", "shouldPersist", "unicodeVersion", "shellIntegrationNonce", "scrollback", "launchMetadata", "launchConfig", "revival"],
            "terminal.serialize": ["workspaceId"], "terminal.incarnation": [],
            "terminal.metadata": ["sessionId", "metadata"],
            "terminal.clearBuffer": ["sessionId"], "terminal.setUnicodeVersion": ["sessionId", "version"],
            "terminal.setNextCommandId": ["sessionId", "commandLine", "commandId"],
            "terminal.attachIdentity": ["processIdentity", "workspaceId"],
            "terminal.attach": ["sessionId", "workspaceId"], "terminal.resume": ["sessionId", "throughDataId"],
            "terminal.detach": ["sessionId"], "terminal.ackExit": ["sessionId"],
            "terminal.setLayout": ["workspaceId", "layout"], "terminal.getLayout": ["workspaceId"],
            "terminal.input": ["sessionId", "data"],
            "terminal.ack": ["sessionId", "dataId"],
            "terminal.ackBatch": ["sessionId", "dataIds"],
            "terminal.resize": ["sessionId", "cols", "rows"],
            "terminal.signal": ["sessionId", "signal"],
            "terminal.stop": ["sessionId"], "terminal.cwd": ["sessionId"], "terminal.list": ["workspaceId"], "terminal.environment": [],
            "terminal.pathExists": ["path"], "terminal.profileEnvironment": [], "terminal.shells": [],
            "terminal.installAutoReply": ["match", "reply"], "terminal.uninstallAllAutoReplies": [],
            "terminal.shellIntegrationContext": [], "terminal.prepareShellIntegration": ["operation"],
        ]
        guard let allowed = fields[method], Set(params.keys).isSubset(of: allowed.union(["pageId", "generation"])) else {
            reject(token, "malformedRequest", "unknown terminal parameter")
            return
        }
        func integer(_ name: String, maximum: Double = 9_007_199_254_740_991, minimum: Double = 1) -> Int? {
            guard let number = params[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value.rounded(.towardZero) == value, value >= minimum, value <= maximum else { return nil }
            return Int(value)
        }
        guard let pageId = params["pageId"] as? String, pageId == incomingDocumentPage else {
            reject(token, "StaleTerminalPage", "terminal page is no longer active")
            return
        }
        let workspaceId = params["workspaceId"] as? String ?? ""
        if method == "terminal.requestHandoff" {
            guard extensionHost.processRuntime == .linux, !workspaceId.isEmpty, workspaceId.utf8.count <= 1024,
                  let targetWorkspace = params["targetWorkspaceId"] as? String, !targetWorkspace.isEmpty,
                  targetWorkspace.utf8.count <= 1024, let instance = integer("instanceId") else {
                reject(token, "malformedRequest", "invalid terminal handoff request"); return
            }
            requestTerminalTransfer(workspace: workspaceId, targetWorkspace: targetWorkspace, instance: instance, page: pageId, token: token)
            return
        }
        if method == "terminal.offerHandoff" {
            guard let id = params["requestId"] as? String, UUID(uuidString: id) != nil,
                  let session = integer("sessionId"), let generation = params["generation"] as? String else {
                reject(token, "malformedRequest", "invalid terminal handoff offer"); return
            }
            offerTerminalTransfer(id: id, session: session, page: pageId, generation: generation, token: token)
            return
        }
        if ["terminal.serialize", "terminal.create", "terminal.attachIdentity", "terminal.attach", "terminal.list", "terminal.getLayout", "terminal.setLayout"].contains(method)
            && (workspaceId.isEmpty || workspaceId.utf8.count > 1024) {
            reject(token, "malformedRequest", "terminal workspace identity is required")
            return
        }
        let session = integer("sessionId")
        let cols = integer("cols", maximum: 1000), rows = integer("rows", maximum: 1000)
        let scrollback = integer("scrollback", maximum: 10000, minimum: 0)
        let signal = integer("signal", maximum: 64)
        let dataId = integer("dataId")
        var dataIds: [Int] = []
        if method == "terminal.ackBatch" {
            guard let values = params["dataIds"] as? [NSNumber], !values.isEmpty, values.count <= 512 else {
                reject(token, "malformedRequest", "invalid output acknowledgement batch"); return
            }
            for value in values {
                let number = value.doubleValue
                guard CFGetTypeID(value) != CFBooleanGetTypeID(), number.isFinite,
                      number.rounded(.towardZero) == number, number >= 1, number <= 9_007_199_254_740_991 else {
                    reject(token, "malformedRequest", "invalid output acknowledgement identity"); return
                }
                dataIds.append(Int(number))
            }
            guard Set(dataIds).count == dataIds.count else {
                reject(token, "malformedRequest", "duplicate output acknowledgement identity"); return
            }
        }
        let unsetEnv = params["unsetEnv"] as? [String] ?? []
        let shellOperation = (params["operation"] as? String).flatMap(NativeTerminalHost.ShellIntegrationOperation.init(rawValue:))
        let selectedWorkspaceURI = lastFolderURI
        let workspaceURL = selectedWorkspaceURI.flatMap(URL.init(string:))
        if !["terminal.installAutoReply", "terminal.uninstallAllAutoReplies", "terminal.attachIdentity", "terminal.serialize", "terminal.incarnation", "terminal.setLayout", "terminal.getLayout", "terminal.create", "terminal.list", "terminal.environment", "terminal.pathExists", "terminal.profileEnvironment", "terminal.shells", "terminal.shellIntegrationContext", "terminal.prepareShellIntegration"].contains(method) && session == nil {
            reject(token, "malformedRequest", "terminal session must be a positive integer")
            return
        }
        if method == "terminal.prepareShellIntegration" && shellOperation == nil {
            reject(token, "malformedRequest", "unknown shell integration operation")
            return
        }
        if ["terminal.shellIntegrationContext", "terminal.prepareShellIntegration"].contains(method)
            && extensionHost.processRuntime != .linux {
            reject(token, "UnsupportedRuntime", "shell integration requires the shared Linux runtime")
            return
        }
        if method == "terminal.pathExists" {
            guard let path = params["path"] as? String, path.hasPrefix("/"),
                  !path.contains("\0"), path.utf8.count < 4096 else {
                reject(token, "malformedRequest", "profile lookup requires a bounded absolute guest path")
                return
            }
        }
        if method == "terminal.installAutoReply" {
            guard let match = params["match"] as? String, let reply = params["reply"] as? String,
                  match.utf8.count <= 64 * 1024, reply.utf8.count <= 64 * 1024 else {
                reject(token, "malformedRequest", "invalid terminal auto reply"); return
            }
        }
        if method == "terminal.create" {
            guard params["launchConfig"] == nil || params["launchConfig"] is [String: Any],
                  params["revival"] == nil || params["revival"] is [String: Any] else {
                reject(token, "malformedRequest", "invalid terminal revival envelope"); return
            }
            guard let cols, let rows, let scrollback,
                  params["executable"] is String,
                  params["args"] == nil || params["args"] is [String],
                  params["env"] == nil || params["env"] is [String: String],
                  params["unsetEnv"] == nil || params["unsetEnv"] is [String],
                  unsetEnv.allSatisfy({ !$0.isEmpty && !$0.contains("=") && !$0.contains("\0") }),
                  params["cwdUri"] == nil || params["cwdUri"] is String else {
                reject(token, "malformedRequest", "invalid terminal launch parameters")
                return
            }
            do {
                guard let metadata = params["launchMetadata"] as? [String: Any] else {
                    throw NativeTerminalHostError.invalidRequest("terminal launch metadata is required")
                }
                _ = try NativeTerminalMetadata.validate(metadata, launch: true)
                try NativeTerminalState.validateConfiguration(cols: cols, rows: rows, scrollback: scrollback)
            }
            catch {
                reject(token, "malformedRequest", "invalid terminal replay configuration or restoration metadata")
                return
            }
            // An empty Linux window uses the already-authorized private process home. The
            // embedded runtime still requires a selected workspace for its singleton mount.
            guard workspaceURL?.isFileURL == true || (selectedWorkspaceURI == nil && extensionHost.processRuntime == .linux) else {
                reject(token, "NoWorkspace", "open a native workspace before creating a terminal")
                return
            }
        } else if (method == "terminal.resize" && (cols == nil || rows == nil))
            || (method == "terminal.signal" && signal == nil)
            || (method == "terminal.input" && !(params["data"] is String)) {
            reject(token, "malformedRequest", "invalid terminal operation parameters")
            return
        }
        if (method == "terminal.create" && (!["6", "11"].contains(params["unicodeVersion"] as? String ?? "") || !(params["shellIntegrationNonce"] is String)))
            || (method == "terminal.setUnicodeVersion" && !["6", "11"].contains(params["version"] as? String ?? ""))
            || (method == "terminal.setNextCommandId" && (!(params["commandLine"] is String) || !(params["commandId"] is String))) {
            reject(token, "malformedRequest", "invalid terminal state parameters"); return
        }
        if method == "terminal.ack" && dataId == nil {
            reject(token, "malformedRequest", "output acknowledgement must identify a positive safe integer")
            return
        }
        if method == "terminal.metadata" {
            guard let metadata = params["metadata"] as? [String: Any],
                  (try? NativeTerminalMetadata.validate(metadata, launch: false)) != nil else {
                reject(token, "malformedRequest", "invalid terminal metadata"); return
            }
        }
        let generation = params["generation"] as? String ?? ""
        let throughDataId = integer("throughDataId", minimum: 0)
        if method == "terminal.resume" && throughDataId == nil {
            reject(token, "malformedRequest", "invalid terminal snapshot revision")
            return
        }
        if method == "terminal.setLayout" && params["layout"] != nil && !(params["layout"] is [String: Any]) {
            reject(token, "malformedRequest", "invalid terminal layout")
            return
        }
        let handoff = session.flatMap { pendingTerminalTransfer(session: $0, page: pageId) }
        if method == "terminal.attach", let handoff { handoff.snapshotStarted = true }
        ioQueue.async { [weak self] in
            guard let self, !self.isTornDown else { return }
            let identityHost = (params["processIdentity"] as? String).flatMap {
                NativeTerminalHost.transferredHost(identity: $0, target: self.terminalHost, workspace: workspaceId)
            }
            let selectedHost = session.flatMap { NativeTerminalHost.transferredHost(sessionId: $0, target: self.terminalHost) } ?? identityHost ?? self.terminalHost
            let operationHost = (handoff != nil && (method == "terminal.attach" || method == "terminal.resume")) ? handoff!.owner! : selectedHost
            let perform = {
                guard token.isPending else { return }
                do {
                    try self.terminalHost.requirePage(pageId)
                    if let session, method != "terminal.attach", !(method == "terminal.resume" && handoff != nil) {
                        try operationHost.requireAttachment(sessionId: session, pageId: pageId, generation: generation)
                    }
                    let value: Any
                    switch method {
                    case "terminal.serialize":
                        value = try operationHost.serialize(workspaceId: workspaceId)
                    case "terminal.incarnation":
                        value = operationHost.incarnationInfo()
                    case "terminal.metadata":
                        try operationHost.updateMetadata(sessionId: session!, metadata: params["metadata"] as! [String: Any]); value = NSNull()
                    case "terminal.clearBuffer":
                        try operationHost.updateState(sessionId: session!) { try $0.clearBuffer() }; value = NSNull()
                    case "terminal.setUnicodeVersion":
                        try operationHost.updateState(sessionId: session!) { try $0.setUnicodeVersion(params["version"] as! String) }; value = NSNull()
                    case "terminal.setNextCommandId":
                        try operationHost.updateState(sessionId: session!) { try $0.setNextCommandId(params["commandLine"] as! String, params["commandId"] as! String) }; value = NSNull()
                    case "terminal.attachIdentity":
                        guard let identity = params["processIdentity"] as? String, identity.utf8.count <= 1024 else { throw NativeTerminalHostError.invalidRequest("invalid process identity") }
                        value = try operationHost.attachIdentity(identity, workspaceId: workspaceId, pageId: pageId, foreignPage: operationHost !== self.terminalHost)
                    case "terminal.attach":
                        if let handoff {
                            value = try operationHost.beginHandoff(sessionId: session!, pageId: handoff.sourcePage,
                                generation: handoff.sourceGeneration, targetPage: pageId, targetWorkspace: handoff.targetWorkspace, handoffId: handoff.id)
                            let stillPending = DispatchQueue.main.sync { Self.terminalTransfers[handoff.id] === handoff }
                            if !stillPending {
                                try? operationHost.cancelHandoff(sessionId: session!, handoffId: handoff.id)
                                throw NativeTerminalHostError.invalidRequest("terminal handoff expired")
                            }
                        } else {
                            value = try operationHost.attach(sessionId: session!, workspaceId: workspaceId, pageId: pageId, foreignPage: operationHost !== self.terminalHost)
                        }
                    case "terminal.resume":
                        if let handoff, let source = handoff.source {
                            let stillPending = DispatchQueue.main.sync {
                                Self.terminalTransfers[handoff.id] === handoff && !self.isTornDown && self.incomingDocumentPage == pageId
                            }
                            guard stillPending else { throw NativeTerminalHostError.invalidRequest("terminal handoff expired") }
                            try NativeTerminalHost.routeHandoff(sessionId: session!, source: operationHost,
                                previous: source.terminalHost, target: self.terminalHost, workspace: handoff.targetWorkspace)
                            do {
                                try self.terminalHost.copyAutoReplies(to: operationHost, sessionId: session!)
                                try operationHost.commitHandoff(sessionId: session!, handoffId: handoff.id,
                                    pageId: pageId, generation: generation, throughDataId: UInt64(throughDataId!))
                                if operationHost === self.terminalHost {
                                    NativeTerminalHost.releaseHandoff(sessionId: session!, source: operationHost)
                                }
                            } catch {
                                NativeTerminalHost.restoreHandoffRoute(sessionId: session!, source: operationHost,
                                    previous: source.terminalHost, target: self.terminalHost, workspace: handoff.sourceWorkspace)
                                try? source.terminalHost.copyAutoReplies(to: operationHost, sessionId: session!)
                                throw error
                            }
                            DispatchQueue.main.async {
                                Self.terminalTransfers[handoff.id] = nil
                                let data = try? JSONSerialization.data(withJSONObject: ["requestId": handoff.id, "sessionId": session!])
                                if let data, let text = String(data: data, encoding: .utf8) {
                                    source.onRuntimeEvent?(["kind": "terminal.handoffComplete", "sessionId": 0,
                                                            "pageId": handoff.sourcePage, "data": text])
                                }
                            }
                        } else {
                            try operationHost.resumeOutput(sessionId: session!, throughDataId: UInt64(throughDataId!))
                        }
                        value = NSNull()
                    case "terminal.detach":
                        try operationHost.detach(sessionId: session!); value = NSNull()
                    case "terminal.ackExit":
                        try operationHost.acknowledgeExit(sessionId: session!); value = NSNull()
                    case "terminal.setLayout":
                        try operationHost.setLayout(workspaceId: workspaceId, layout: params["layout"] as? [String: Any]); value = NSNull()
                    case "terminal.getLayout":
                        value = operationHost.getLayout(workspaceId: workspaceId) as Any? ?? NSNull()
                    case "terminal.create":
                        // Catalog preparation above retains the private directory grant for this host.
                        let home = self.processHomeURI.flatMap(URL.init(string:))
                        guard let sessionRoot = workspaceURL ?? home, sessionRoot.isFileURL else {
                            throw NativeTerminalHostError.processHomeUnavailable("the authorized process home is unavailable")
                        }
                        let cwdURI = params["cwdUri"] as? String ?? (workspaceURL == nil
                            ? sessionRoot.appendingPathComponent("home", isDirectory: true).absoluteString : nil)
                        let result = try operationHost.create(workspaceURL: sessionRoot, cols: cols!, rows: rows!,
                            cwdURI: cwdURI, executable: params["executable"] as! String,
                            args: params["args"] as? [String] ?? [], env: params["env"] as? [String: String] ?? [:],
                            unsetEnv: unsetEnv, pageId: pageId, workspaceId: workspaceId, shouldPersist: params["shouldPersist"] as? Bool == true, unicodeVersion: params["unicodeVersion"] as! String, shellIntegrationNonce: params["shellIntegrationNonce"] as! String, scrollback: scrollback!, launchMetadata: params["launchMetadata"] as! [String: Any], launchConfig: params["launchConfig"] as? [String: Any], revival: params["revival"] as? [String: Any])
                        self.logEvent?(["event": "native.terminalStarted", "sessionId": result["sessionId"] ?? 0, "pid": result["pid"] ?? 0])
                        value = result
                    case "terminal.input":
                        value = try operationHost.input(sessionId: session!, data: params["data"] as! String)
                        self.logEvent?(["event": "native.terminalInput", "sessionId": session!])
                    case "terminal.ack":
                        value = try operationHost.acknowledgeOutput(sessionId: session!, dataId: dataId!)
                    case "terminal.ackBatch":
                        value = try operationHost.acknowledgeOutputBatch(sessionId: session!, dataIds: dataIds)
                    case "terminal.resize":
                        try operationHost.resize(sessionId: session!, cols: cols!, rows: rows!)
                        self.logEvent?(["event": "native.terminalResized", "sessionId": session!, "cols": cols!, "rows": rows!])
                        value = NSNull()
                    case "terminal.signal": try operationHost.signal(sessionId: session!, signal: Int32(signal!)); value = NSNull()
                    case "terminal.stop": try operationHost.stop(sessionId: session!); value = NSNull()
                    case "terminal.cwd": value = try operationHost.cwd(sessionId: session!)
                    case "terminal.pathExists":
                        if let workspaceURL { try operationHost.prepareProcessWorkspace(workspaceURL: workspaceURL) }
                        else { try operationHost.prepareProcessRuntime() }
                        value = try operationHost.lookupProfile(path: params["path"] as! String)
                    case "terminal.profileEnvironment":
                        if let workspaceURL { try operationHost.prepareProcessWorkspace(workspaceURL: workspaceURL) }
                        else { try operationHost.prepareProcessRuntime() }
                        value = try operationHost.lookupProfile()
                    case "terminal.shells":
                        if let workspaceURL { try operationHost.prepareProcessWorkspace(workspaceURL: workspaceURL) }
                        else { try operationHost.prepareProcessRuntime() }
                        value = try operationHost.lookupProfile(shells: true)
                    case "terminal.installAutoReply":
                        try operationHost.installAutoReply(match: params["match"] as! String, reply: params["reply"] as! String)
                        try operationHost.updateBorrowedAutoReplies(match: params["match"] as? String, reply: params["reply"] as? String)
                        value = NSNull()
                    case "terminal.uninstallAllAutoReplies":
                        try operationHost.uninstallAllAutoReplies()
                        try operationHost.updateBorrowedAutoReplies()
                        value = NSNull()
                    case "terminal.environment":
                        value = try operationHost.environment()
                    case "terminal.shellIntegrationContext":
                        let inputs = try self.shellIntegrationInputs()
                        // This is launch preparation; profile lookup remains read-only.
                        try operationHost.prepareProcessRuntime()
                        value = try operationHost.shellIntegrationContext(appRootAccess: inputs.app,
                            processHomeAccess: inputs.home, applicationName: inputs.applicationName, quality: inputs.quality)
                    case "terminal.prepareShellIntegration":
                        let inputs = try self.shellIntegrationInputs()
                        value = try operationHost.prepareShellIntegration(operation: shellOperation!, appRootAccess: inputs.app,
                            processHomeAccess: inputs.home, applicationName: inputs.applicationName, quality: inputs.quality)
                    default: value = operationHost.list(workspaceId: workspaceId)
                    }
                    token.send(Self.ok(value))
                } catch let error as NativeTerminalHostError {
                    self.logEvent?(["event": "native.terminalRequestFailed", "method": method, "code": error.code])
                    token.send(Self.error(error.code, error.message))
                } catch {
                    token.send(Self.error("TerminalFailure", error.localizedDescription))
                }
            }
            if ["terminal.create", "terminal.environment", "terminal.shellIntegrationContext", "terminal.pathExists", "terminal.profileEnvironment", "terminal.shells"].contains(method) {
                self.withAuthorizedExtensionCatalog { result in
                    do { _ = try result.get(); perform() }
                    catch let error as NativeTerminalHostError { token.send(Self.error(error.code, error.message)) }
                    catch let error as NativeExtensionCatalogError { token.send(Self.error(error.code, error.message)) }
                    catch let error as BridgeError { token.send(Self.error(error.code, error.message)) }
                    catch { token.send(Self.error("TerminalFailure", error.localizedDescription)) }
                }
            } else if session != nil || ["terminal.serialize", "terminal.attachIdentity", "terminal.list"].contains(method) {
                operationHost.performRequest(sessionId: session, processIdentity: params["processIdentity"] as? String, perform)
            } else {
                perform()
            }
        }
    }

    private func shellIntegrationInputs() throws -> (app: WorkspaceNativeToolAccess, home: WorkspaceNativeToolAccess,
                                                      applicationName: String, quality: String?) {
        guard let text = extensionCatalog?["appRoot"] as? String, let root = URL(string: text), root.isFileURL,
              root.host == nil || root.host == "", root.query == nil, root.fragment == nil,
              let processHomeURI else {
            throw NativeTerminalHostError.processHomeUnavailable("shell integration requires the prepared catalog and process home")
        }
        let app = try fileSystem.nativeToolAccess(rootURI: text)
        let home = try fileSystem.nativeToolAccess(rootURI: processHomeURI)
        let data = try fileSystem.readFileData(root.appendingPathComponent("product.json").absoluteString, maximumBytes: 1024 * 1024)
        guard let product = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let applicationName = product["applicationName"] as? String,
              product["quality"] == nil || product["quality"] is String else {
            throw BridgeError(code: "ArtifactUnavailable", message: "verified shell integration product metadata is unavailable")
        }
        return (app, home, applicationName, product["quality"] as? String)
    }

    /// Terminal credits stay charged until matching consumption; failed delivery detaches the reader.
    func completeRuntimeEventDelivery(_ event: [String: Any], accepted: Bool, reason: String) {
        if event["kind"] as? String == "urls.open" {
            if !accepted && extensionURLs.failedDelivery(event) {
                onIncomingDocumentError?("The extension callback was not delivered. Pending callbacks are preserved; reload the workbench to retry.")
            }
            return
        }
        if event["kind"] as? String == "documents.open" {
            if !accepted { failIncomingDocumentDelivery(event, reason: "The workbench did not accept the requested document. Try opening it again.") }
            return
        }
        if event["kind"] as? String == "terminal.data" {
            guard !accepted, let session = event["sessionId"] as? Int, session > 0,
                  let dataId = event["dataId"] as? Int, dataId > 0,
                  let pageId = event["pageId"] as? String, let generation = event["generation"] as? String else { return }
            let host = NativeTerminalHost.transferredHost(sessionId: session, target: terminalHost) ?? terminalHost
            ioQueue.async {
                host.failOutputDelivery(sessionId: session, dataId: dataId, pageId: pageId, generation: generation, reason: reason)
            }
            return
        }
        // Termination already schedules explicit protocol teardown. A late WK completion
        // must not close the socket before that teardown can drain it to EOF.
        if rendererUnavailable { return }
        guard event["kind"] as? String == "exthost.data",
              let session = event["sessionId"] as? Int,
              let dataId = event["dataId"] as? Int else { return }
        ioQueue.async { [weak self, host = extensionHost] in
            if accepted {
                do {
                    try host.acknowledgeOutput(sessionId: session, dataId: dataId)
                } catch {
                    self?.logEvent?(["event": "native.extensionHostOutputAckFailed", "sessionId": session])
                    host.failOutputDelivery(sessionId: session, dataId: dataId, reason: "output acknowledgement failed")
                }
            } else {
                host.failOutputDelivery(sessionId: session, dataId: dataId, reason: reason)
            }
        }
    }

    private func handleAgentHost(method: String, params: [String: Any], token: ReplyToken) {
        guard method == "agentHost.status" || method == "agentHost.stop" || localAgentHostAvailable else {
            reject(token, "UnsupportedRuntime", "Local agent sessions require the optional agent host and the shared Linux runtime.")
            return
        }
        let configuration: [String: Any]?
        do {
            switch method {
            case "agentHost.start":
                guard Set(params.keys) == ["launchConfiguration"],
                      let value = params["launchConfiguration"] as? [String: Any] else {
                    throw BridgeError(code: "malformedRequest", message: "invalid agent host launch configuration")
                }
                // Reject data before catalog grants, mounts or runtime preparation.
                try NativeAgentHost.validateLaunchConfiguration(value)
                configuration = value
            case "agentHost.stop":
                guard Set(params.keys) == ["sessionId"], let text = params["sessionId"] as? String,
                      text.count <= 20, let value = UInt64(text), value > 0, value < UInt64.max,
                      String(value) == text else {
                    throw BridgeError(code: "malformedRequest", message: "agent host session must be a canonical positive decimal string")
                }
                configuration = nil
            case "agentHost.authorizeDirectories":
                guard Set(params.keys) == ["uris"], let uris = params["uris"] as? [String],
                      uris.count <= 32, uris.allSatisfy(Self.validWorkspaceURI) else {
                    throw BridgeError(code: "malformedRequest", message: "invalid agent working directories")
                }
                configuration = nil
            default:
                guard params.isEmpty else {
                    throw BridgeError(code: "malformedRequest", message: "agent host status takes no parameters")
                }
                configuration = nil
            }
        } catch let error as NativeAgentHost.Failure {
            reject(token, error.code, error.message); return
        } catch let error as BridgeError {
            reject(token, error.code, error.message); return
        } catch {
            reject(token, "malformedRequest", "invalid agent host request"); return
        }
        let respond: (Result<[String: Any], Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                switch result {
                case .success(let value): token.send(Self.ok(value))
                case .failure(let error as NativeAgentHost.Failure): token.send(Self.error(error.code, error.message))
                case .failure(let error as NativeTerminalHostError): token.send(Self.error(error.code, error.message))
                case .failure(let error as NativeExtensionCatalogError): token.send(Self.error(error.code, error.message))
                case .failure(let error as BridgeError): token.send(Self.error(error.code, error.message))
                case .failure(let error): token.send(Self.error("AgentHostUnavailable", error.localizedDescription))
                }
            }
        }
        ioQueue.async { [weak self] in
            guard let self, !self.isTornDown else { return }
            switch method {
            case "agentHost.reauthorizeDirectories":
                self.reauthorizeAgentWorkspaceRoots(token: token, respond: respond)
            case "agentHost.start":
                do { try self.restoreAgentWorkspaceRoots() }
                catch { respond(.failure(error)); return }
                self.withAuthorizedExtensionCatalog { result in
                    guard token.isPending else { return }
                    do {
                        let catalog = try result.get()
                        // The catalog has verified the complete immutable Exthost inventory.
                        // Resolve the receipt's entry before starting the shared kernel.
                        let input = try self.agentHostLaunchInput(catalog: catalog, configuration: configuration!)
                        self.agentHost.start(input) { respond($0.map { $0.value }) }
                    } catch { respond(.failure(error)) }
                }
            case "agentHost.stop":
                self.agentHost.stop(sessionId: params["sessionId"] as! String) { respond($0.map { $0.value }) }
            case "agentHost.authorizeDirectories":
                do {
                    let access = try self.agentWorkspaceRoots.authorize(params["uris"] as! [String])
                    try self.terminalHost.installAuthorizedWorkspaceRoots(access)
                    respond(.success([:]))
                } catch { respond(.failure(error)) }
            default:
                var status = self.agentHost.status()
                status["runtimeAvailable"] = self.localAgentHostAvailable
                if self.localAgentHostAvailable {
                    do {
                        try self.restoreAgentWorkspaceRoots()
                        status["sessionsWorkspaceAuthorityAvailable"] = true
                    } catch {
                        status["sessionsWorkspaceAuthorityAvailable"] = false
                        self.logEvent?(["event": "native.agentWorkspaceRestoreFailed"])
                    }
                }
                respond(.success(status))
            }
        }
    }

    private func reauthorizeAgentWorkspaceRoots(token: ReplyToken, respond: @escaping (Result<[String: Any], Error>) -> Void) {
        do {
            guard let missing = try agentWorkspaceRoots.unavailableRoot() else {
                try restoreAgentWorkspaceRoots()
                respond(.success(["authorized": true])); return
            }
            pickWorkspaceRoots(token: token, initialURI: missing.uri) { [weak self] urls in
                guard let self else { return }
                self.ioQueue.async {
                    guard !self.isTornDown else { return }
                    guard urls.count == 1, let selected = urls.first else {
                        respond(.success(["authorized": false])); return
                    }
                    do {
                        try self.fileSystem.withGrantTransaction { fs in
                            let uri = try fs.grantDirectory(selected, securityScoped: !Self.isInsideAppDocuments(selected))
                            try self.agentWorkspaceRoots.reauthorize(file: missing.file, uri: uri)
                        }
                        self.reauthorizeAgentWorkspaceRoots(token: token, respond: respond)
                    } catch { respond(.failure(error)) }
                }
            }
        } catch { respond(.failure(error)) }
    }

    private func restoreAgentWorkspaceRoots() throws {
        var access: [WorkspaceNativeToolAccess] = []
        try fileSystem.withGrantTransaction { _ in
            do { access = try agentWorkspaceRoots.restore() }
            catch { access.removeAll(); throw error }
        }
        // A previous restore installed the mounts, but their directory identities can change
        // before a later status or start request. Revalidate before trusting the cached mounts.
        guard !agentWorkspaceRootsRestored else { return }
        try terminalHost.installAuthorizedWorkspaceRoots(access)
        agentWorkspaceRootsRestored = true
    }

    private func agentHostLaunchInput(catalog: [String: Any], configuration: [String: Any]) throws -> NativeAgentHost.LaunchInput {
        func directory(_ key: String) throws -> URL {
            guard let text = catalog[key] as? String, let url = URL(string: text), url.isFileURL,
                  url.host == nil || url.host == "", url.query == nil, url.fragment == nil else {
                throw BridgeError(code: "ArtifactUnavailable", message: "agent host catalog directory is unavailable")
            }
            return url
        }
        let root = try directory("appRoot")
        let artifacts = try NativeExtensionCatalog.agentHostArtifacts(in: root)
        let script = NativeAgentHost.Artifact(url: artifacts.script, sha256: artifacts.scriptHash)
        let addon = NativeAgentHost.Artifact(url: artifacts.sqlite, sha256: artifacts.sqliteHash)
        try script.verify(); try addon.verify()
        // Validate the current kernel owner and retained mounted adapters before handing out a launch lease.
        try terminalHost.prepareProcessRuntime()
        let environment = try terminalHost.environment()
        guard let home = environment["HOME"], home.hasPrefix("/"), !home.contains("\0") else {
            throw BridgeError(code: "RuntimeUnavailable", message: "the authorized process HOME is unavailable")
        }
        return NativeAgentHost.LaunchInput(script: script, sqliteAddon: addon, cwd: home,
            logsPath: try directory("logsLocation").appendingPathComponent("agent-host").path,
            userDataPath: try directory("globalStorageHome").appendingPathComponent("agent-host").path,
            environment: environment, launchConfiguration: configuration,
            filesystemOwner: fileSystem, runtimeOwner: terminalHost)
    }

    private func handleExtensionHost(method: String, params: [String: Any], token: ReplyToken) {
        if method == "exthost.prepareWindowReload" {
            guard params.isEmpty else { reject(token, "malformedRequest", "reload preparation takes no parameters"); return }
            let generation = setExtensionHostStartsSuspended(true)
            prepareForRendererReload { [weak self] result in
                switch result {
                case .success: token.send(Self.ok(["generation": generation]))
                case .failure:
                    _ = self?.resumeExtensionHostStarts(ifGeneration: generation)
                    token.send(Self.error("CleanupIncomplete", "The previous extension host has not settled"))
                }
            }
            return
        }
        if method == "exthost.cancelWindowReload" {
            guard Set(params.keys) == ["generation"], let n = params["generation"] as? NSNumber,
                  CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                  n.doubleValue.rounded(.towardZero) == n.doubleValue,
                  n.doubleValue >= 0, n.doubleValue <= 9_007_199_254_740_991 else {
                reject(token, "malformedRequest", "invalid reload generation"); return
            }
            let resumed = resumeExtensionHostStarts(ifGeneration: n.uint64Value)
            token.send(Self.ok(["resumed": resumed]))
            return
        }
        if method == "exthost.assertStopped" {
            guard params.isEmpty else {
                reject(token, "malformedRequest", "shutdown confirmation takes no parameters")
                return
            }
            ioQueue.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                var cleanup = codipad_node_process_cleanup_snapshot()
                codipad_node_process_get_cleanup_snapshot(&cleanup)
                guard self.extensionHost.currentSessionId == nil, !self.extensionHost.cleanupIncomplete,
                      cleanup.host_active == 0, cleanup.remaining_sessions == 0 else {
                    token.send(Self.error("CleanupIncomplete", "The previous extension host still owns runtime state"))
                    return
                }
                token.send(Self.ok(NSNull()))
            }
            return
        }
        let allowed: Set<String> = method == "exthost.start" ? ["generation", "workspaceKind"] :
            (method == "exthost.send" ? ["sessionId", "data"] : ["sessionId"])
        guard Set(params.keys).isSubset(of: allowed) else {
            reject(token, "malformedRequest", "unknown extension-host parameter")
            return
        }
        func integer(_ value: Any?, allowZero: Bool = false) -> Int? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value.rounded(.towardZero) == value,
                  value >= (allowZero ? 0 : 1), value <= 9_007_199_254_740_991 else { return nil }
            return Int(value)
        }
        let session = integer(params["sessionId"])
        let generation = params["generation"] == nil ? 0 : integer(params["generation"], allowZero: true)
        let workspaceKind = params["workspaceKind"] as? String ?? "native"
        guard (method == "exthost.start" && generation != nil) ||
                (method != "exthost.start" && session != nil),
              params["workspaceKind"] == nil || ["native", "remote", "empty"].contains(workspaceKind),
              params["workspaceKind"] == nil || params["workspaceKind"] is String,
              method != "exthost.send" || params["data"] is String else {
            reject(token, "malformedRequest", "extension-host session and payload types are invalid")
            return
        }
        let workspaceURL = workspaceKind == "native" ? lastFolderURI.flatMap(URL.init(string:)) : nil
        extensionHostStartLock.lock()
        let startGeneration = extensionHostStartGeneration
        extensionHostStartLock.unlock()
        ioQueue.async { [weak self] in
            guard let self, !self.isTornDown else { return }
            let perform: ([String: Any]?) -> Void = { catalog in
                guard token.isPending else { return }
                do {
                    let value: Any
                    switch method {
                    case "exthost.start":
                        // The catalog root is receipt-verified and granted by this bridge.
                        guard let text = catalog?["appRoot"] as? String, let root = URL(string: text),
                              root.isFileURL, root.host == nil || root.host == "",
                              root.query == nil, root.fragment == nil else {
                            throw NativeExtensionHostError.artifactMissing("authorized extension-host root is unavailable")
                        }
                        self.extensionHostStartLock.lock()
                        let startsSuspended = self.extensionHostStartsSuspended || self.extensionHostStartGeneration != startGeneration
                        self.extensionHostStartLock.unlock()
                        guard !startsSuspended else {
                            token.send(Self.error("RendererReloading", "The previous workbench page is closing"))
                            return
                        }
                        if self.extensionHost.currentSessionId == nil && !self.extensionHost.cleanupIncomplete {
                            let pendingPackages = Set((catalog?["packages"] as? [[String: Any]] ?? []).compactMap { $0["extensionLocation"] as? String })
                            NativeExtensionStore.retainHostPackages(owner: self.extensionProfileFenceOwner, packages: pendingPackages)
                        }
                        defer {
                            if self.extensionHost.currentSessionId == nil && !self.extensionHost.cleanupIncomplete {
                                NativeExtensionStore.releaseHostPackages(owner: self.extensionProfileFenceOwner)
                            }
                        }
                        let environment = try self.terminalHost.environment()
                        var processCwd: String?
                        if NativeRuntimeConfiguration.current.usesLinuxExtensionHost {
                            if let workspaceURL, workspaceURL.isFileURL {
                                try self.terminalHost.prepareProcessWorkspace(workspaceURL: workspaceURL)
                                processCwd = workspaceURL.path
                            } else {
                                guard let home = environment["HOME"], home.hasPrefix("/") else {
                                    throw NativeExtensionHostError.startFailed("The authorized process HOME is unavailable")
                                }
                                try self.terminalHost.prepareProcessRuntime()
                                processCwd = home
                            }
                        }
                        let session = try { () throws -> Int? in
                            // Starts and reload cleanup both execute on ioQueue. Once admitted,
                            // an in-flight start must finish before queued cleanup can settle it.
                            // Never hold this lock across start: suspension runs on the UI thread.
                            dispatchPrecondition(condition: .onQueue(self.ioQueue))
                            self.extensionHostStartLock.lock()
                            let admitted = !self.extensionHostStartsSuspended && self.extensionHostStartGeneration == startGeneration
                            self.extensionHostStartLock.unlock()
                            guard admitted else { return nil }
                            return try self.extensionHost.start(
                                generation: generation!, environment: environment, bundleRoot: root,
                                processCwd: processCwd, runtimeOwner: self.terminalHost
                            )
                        }()
                        guard let session else {
                            token.send(Self.error("RendererReloading", "The previous workbench page is closing"))
                            return
                        }
                        self.logEvent?(["event": "native.extensionHostStarted", "sessionId": session])
                        value = ["sessionId": session]
                    case "exthost.send":
                        self.extensionHost.send(sessionId: session!, data: params["data"] as! String) { result in
                            switch result {
                            case .success:
                                token.send(Self.ok(NSNull()))
                            case .failure(let error as NativeExtensionHostError):
                                self.logEvent?(["event": "native.extensionHostRequestFailed", "method": method, "code": error.code])
                                token.send(Self.error(error.code, error.message))
                            case .failure(let error):
                                token.send(Self.error("RuntimeFailure", error.localizedDescription))
                            }
                        }
                        return
                    default:
                        try self.extensionHost.stop(sessionId: session!)
                        self.logEvent?(["event": "native.extensionHostStopRequested", "sessionId": session!])
                        value = NSNull()
                    }
                    token.send(Self.ok(value))
                } catch let error as NativeTerminalHostError {
                    token.send(Self.error(error.code, error.message))
                } catch let error as NativeExtensionHostError {
                    self.logEvent?(["event": "native.extensionHostRequestFailed", "method": method, "code": error.code])
                    token.send(Self.error(error.code, error.message))
                } catch {
                    token.send(Self.error("RuntimeFailure", error.localizedDescription))
                }
            }
            if method == "exthost.start" {
                self.withAuthorizedExtensionCatalog { result in
                    do { perform(try result.get()) }
                    catch let error as NativeTerminalHostError { token.send(Self.error(error.code, error.message)) }
                    catch let error as NativeExtensionCatalogError { token.send(Self.error(error.code, error.message)) }
                    catch let error as BridgeError { token.send(Self.error(error.code, error.message)) }
                    catch { token.send(Self.error("RuntimeFailure", error.localizedDescription)) }
                }
            } else {
                perform(nil)
            }
        }
    }

    /// Rejects a request without touching the picker, backend, or previous grant state.
    private func reject(_ token: ReplyToken, _ code: String, _ message: String) {
        logEvent?(["event": "native.requestRejected", "code": code])
        token.send(Self.error(code, message))
    }

    // MARK: - dialog.open

    private struct PickerOptions {
        var files: Bool
        var folders: Bool
        var multiple: Bool
        var newWindow: Bool
        var extensions: [String]
        var initialURL: URL?
    }

    private func handleDialogOpen(params: [String: Any], token: ReplyToken) {
        let options: PickerOptions
        do {
            options = try Self.pickerOptions(params)
        } catch let error as BridgeError {
            reject(token, error.code, error.message)
            return
        } catch {
            reject(token, "malformedRequest", error.localizedDescription)
            return
        }

        ioQueue.async { [weak self] in
            guard let self, !self.isTornDown else { return }
            let initialDirectory = options.initialURL.flatMap { url -> URL? in
                for directory in [url, url.deletingLastPathComponent()] {
                    if let access = try? self.fileSystem.authorizedDirectoryAccess(rootURI: directory.absoluteString) {
                        return URL(fileURLWithPath: access.rootPath, isDirectory: true)
                    }
                }
                return nil
            }
            DispatchQueue.main.async { self.presentOpenPicker(options, initialDirectory: initialDirectory, token: token) }
        }
    }

    private func presentOpenPicker(_ options: PickerOptions, initialDirectory: URL?, token: ReplyToken) {
        // Teardown already flushed this request; never present a picker after the host left.
        guard !self.isTornDown else { return }
        guard !self.pickerInFlight else {
            self.reject(token, "pickerBusy", "a document picker is already open")
            return
        }
        guard let presenter = self.presenter, presenter.viewIfLoaded?.window != nil else {
            self.reject(token, "noPresenter", "no native view is available to present a picker")
            return
        }
        var types: [UTType] = []
        if options.files {
            let filtered = options.extensions.compactMap { UTType(filenameExtension: $0) }
            types = filtered.isEmpty || options.extensions.contains("*") ? [.item] : filtered
        }
        if options.folders { types.append(.folder) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.directoryURL = initialDirectory
        pickerOpensNewWindow = options.newWindow
        picker.allowsMultipleSelection = options.multiple
        picker.delegate = self
        self.pickerInFlight = true
        self.activePickerReply = token
        self.logEvent?([
            "event": "native.dialogPresented",
            "files": options.files, "folders": options.folders, "multiple": options.multiple,
        ])
        presenter.present(picker, animated: true)
    }

    private static func pickerOptions(_ params: [String: Any]) throws -> PickerOptions {
        let allowed: Set<String> = ["files", "folders", "multiple", "newWindow", "extensions", "initialUri"]
        if let unknown = Set(params.keys).subtracting(allowed).first {
            throw BridgeError(code: "malformedRequest", message: "unknown dialog.open parameter: \(unknown)")
        }
        func flag(_ key: String) throws -> Bool {
            guard let value = params[key] else { return false }
            // `as? Bool` also accepts NSNumber 1/0 through bridging; require a real CFBoolean,
            // matching the filesystem agent's strict boolean handling.
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw BridgeError(code: "malformedRequest", message: "'\(key)' must be a boolean")
            }
            return number.boolValue
        }
        let files = try flag("files")
        let folders = try flag("folders")
        let multiple = try flag("multiple")
        guard files || folders else {
            throw BridgeError(code: "malformedRequest", message: "dialog.open needs files or folders to be true")
        }
        let newWindow = try flag("newWindow")
        guard !newWindow || !multiple, params["extensions"] == nil || params["extensions"] is [String] else {
            throw BridgeError(code: "malformedRequest", message: "invalid picker selection options")
        }
        let initial = (params["initialUri"] as? String).flatMap(URL.init(string:))
        guard params["initialUri"] == nil || (initial?.isFileURL == true && (initial?.host ?? "").isEmpty) else {
            throw BridgeError(code: "malformedRequest", message: "the initial picker location must be a local file URL")
        }
        return PickerOptions(files: files, folders: folders, multiple: multiple, newWindow: newWindow,
                             extensions: params["extensions"] as? [String] ?? [], initialURL: initial)
    }

    /// Grants every picked URL through the backend, on the serial I/O queue, then replies on main.
    private func authorize(urls: [URL], token: ReplyToken) {
        guard !urls.isEmpty else {
            logEvent?(["event": "native.selectionCancelled"])
            token.send(Self.ok([String]()))
            finishPicker()
            return
        }
        ioQueue.async { [weak self] in
            guard let self else {
                token.send(Self.error("hostTornDown", "the native host went away before authorization"))
                return
            }
            guard !self.isTornDown else { return }
            var uris: [String] = []
            var pathCapabilityMetadata: [[String: Any]] = []
            var folderURI: String?
            var fileCount = 0
            var folderCount = 0
            var appContainerCount = 0
            do {
                // Only grants appended by this batch are rolled back on failure; earlier grants
                // and their authorization survive. The backend owns that rollback.
                try self.fileSystem.withGrantTransaction { fs in
                    for url in urls {
                        guard url.isFileURL else {
                            throw BridgeError(code: "invalidSelection", message: "selection is not a local file URL")
                        }
                        // The app's own Documents container needs no security scope; every other
                        // selection does. A failed external scope is never retried as unscoped.
                        let inAppContainer = Self.isInsideAppDocuments(url)
                        if inAppContainer { appContainerCount += 1 }
                        if url.hasDirectoryPath {
                            let uri = try fs.grantDirectory(url, securityScoped: !inAppContainer)
                            folderURI = uri
                            folderCount += 1
                            uris.append(uri)
                        } else {
                            uris.append(try fs.grantFile(url, securityScoped: !inAppContainer))
                            fileCount += 1
                        }
                    }
                    // Publish file grants independently of the optional execution runtime.
                    pathCapabilityMetadata = try self.pathCapabilityMetadata(forURIs: uris, publishBrowserResources: true)
                }
                for (url, uri) in zip(urls, uris) {
                    self.recordDocumentSource(RestoredDocumentGrant(selectedURL: url, uri: uri, isDirectory: url.hasDirectoryPath))
                }
            } catch let error as WorkspaceFileSystemError {
                let reason = error.message.hasPrefix("scope:") ? "scopeDenied"
                    : error.message.hasPrefix("anchor-open:") ? "anchorOpenDenied"
                    : "filesystemGrantRejected"
                self.logEvent?(["event": "native.selectionFailed", "code": error.code, "reason": reason])
                DispatchQueue.main.async {
                    guard !self.isTornDown else { return }
                    token.send(Self.error(error.code, error.message))
                    self.finishPicker()
                }
                return
            } catch let error as NativeTerminalHostError {
                self.logEvent?(["event": "native.selectionFailed", "code": error.code, "reason": error.message])
                DispatchQueue.main.async {
                    guard !self.isTornDown else { return }
                    token.send(Self.error(error.code, error.message))
                    self.finishPicker()
                }
                return
            } catch let error as NativeExtensionHostError {
                self.logEvent?(["event": "native.selectionFailed", "code": error.code, "reason": error.message])
                DispatchQueue.main.async {
                    guard !self.isTornDown else { return }
                    token.send(Self.error(error.code, error.message))
                    self.finishPicker()
                }
                return
            } catch let error as BridgeError {
                self.logEvent?(["event": "native.selectionFailed", "code": error.code])
                DispatchQueue.main.async {
                    guard !self.isTornDown else { return }
                    token.send(Self.error(error.code, error.message))
                    self.finishPicker()
                }
                return
            } catch {
                self.logEvent?(["event": "native.selectionFailed", "code": "grantFailed"])
                DispatchQueue.main.async {
                    guard !self.isTornDown else { return }
                    token.send(Self.error("grantFailed", error.localizedDescription))
                    self.finishPicker()
                }
                return
            }
            if let folderURI, let folder = URL(string: folderURI) {
                do {
                    try self.terminalHost.prepareProcessWorkspace(workspaceURL: folder)
                } catch let error as NativeTerminalHostError {
                    self.logEvent?(["event": "native.workspaceRuntimePreparationFailed", "code": error.code])
                } catch {
                    self.logEvent?(["event": "native.workspaceRuntimePreparationFailed", "code": "RuntimeFailure"])
                }
            }
            DispatchQueue.main.async {
                // Teardown may have run while the grants were in flight: reply is already
                // flushed as hostTornDown and the one-shot token ignores this send. Do not
                // update the remembered folder or picker state after teardown.
                guard !self.isTornDown else { return }
                // A picker authorizes access; only workspace.current/commit selects the cwd.
                self.logEvent?([
                    "event": "native.selectionGranted",
                    "count": uris.count, "files": fileCount, "folders": folderCount,
                    "appContainer": appContainerCount,
                ])
                token.send(Self.ok(uris, pathCapabilities: pathCapabilityMetadata))
                self.finishPicker()
            }
        }
    }

    /// Classifies a picker URL as inside or outside the app's own Documents container.
    ///
    /// Ordering rule: an external selection must be authorized before ANY filesystem access, so
    /// this compares raw paths lexically first and touches no filesystem for external candidates.
    /// Only a candidate lexically inside the trusted container may be symlink-resolved (the app
    /// already has authorization there), and canonical containment must then also hold.
    private static func isInsideAppDocuments(_ url: URL) -> Bool {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return false
        }
        // Lexical comparison first: no filesystem access on an external candidate.
        let trusted = lexicalContainerPath(documents)
        let candidate = lexicalContainerPath(url)
        guard candidate == trusted || candidate.hasPrefix(trusted + "/") else {
            return false
        }
        // Lexically contained: canonicalize now and require canonical containment too.
        let canonicalTrusted = documents.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalCandidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        return canonicalCandidate == canonicalTrusted
            || canonicalCandidate.hasPrefix(canonicalTrusted + "/")
    }

    /// Lexical spelling that treats `/var` and `/private/var` as the same app container.
    private static func lexicalContainerPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/var/") { return "/private" + path }
        return path
    }

    private func recordDocumentSource(_ source: RestoredDocumentGrant) {
        if let path = URL(string: source.uri)?.path {
            pickedDocumentSources[path] = source
            persistedDocumentSources = nil
        }
    }

    private func selectedParent(of path: String, in sources: [String: RestoredDocumentGrant]) -> RestoredDocumentGrant? {
        var parent = path[...]
        while let slash = parent.lastIndex(of: "/") {
            parent = parent[..<slash]
            if let source = sources[parent.isEmpty ? "/" : String(parent)], source.isDirectory { return source }
        }
        return nil
    }

    private func handleOpenDocumentState(method: String, params: [String: Any], token: ReplyToken) {
        ioQueue.async { [weak self] in
            guard let self, !self.isTornDown else { return }
            do {
                if method == "documents.acceptSaveTarget" {
                    guard Set(params.keys) == ["uri"], let uri = params["uri"] as? String, Self.validWorkspaceURI(uri),
                          let path = URL(string: uri)?.path else {
                        throw BridgeError(code: "InvalidRequest", message: "Invalid Save As destination.")
                    }
                    // Same authority check as a file operation, including for a new directory entry.
                    let value = try self.fileSystem.perform("fs.pathCapabilities", params: params)
                    self.acceptedSaveTargets[path] = self.selectedParent(of: path, in: self.pickedDocumentSources)
                    token.send(Self.ok(value))
                    return
                }
                guard let layout = params["layout"] as? String, !layout.isEmpty, layout.utf8.count <= 256 else {
                    throw BridgeError(code: "InvalidRequest", message: "Invalid editor layout.")
                }
                let state = try self.openWorkspaceState()
                if method == "documents.restoreOpen" {
                    guard Set(params.keys) == ["layout"] else {
                        throw BridgeError(code: "InvalidRequest", message: "Invalid document restoration request.")
                    }
                    self.documentLayout = nil
                    let restored = try state.restoreDocumentGrants(layout: layout)
                    let metadata = try self.pathCapabilityMetadata(forURIs: restored.map(\.uri), publishBrowserResources: true)
                    self.acceptedSaveTargets.removeAll()
                    self.restoredDocumentFolders.removeAll()
                    for source in restored {
                        self.recordDocumentSource(source)
                        if source.isDirectory, let path = URL(string: source.uri)?.path {
                            self.restoredDocumentFolders[path] = source
                        }
                    }
                    self.persistedDocumentSources = Set(restored.map(\.uri))
                    self.documentLayout = layout
                    token.send(Self.ok(NSNull(), pathCapabilities: metadata))
                    return
                }
                guard layout == self.documentLayout, Set(params.keys) == ["layout", "uris"],
                      let uris = params["uris"] as? [String], uris.count <= 16_384, uris.allSatisfy(Self.validWorkspaceURI) else {
                    throw BridgeError(code: "InvalidRequest", message: "Invalid open documents for the active editor layout.")
                }
                var sources = [String: RestoredDocumentGrant]()
                for uri in uris {
                    guard let path = URL(string: uri)?.path else { continue }
                    if let source = self.pickedDocumentSources[path], !source.isDirectory {
                        sources[source.uri] = source
                    } else if let source = self.acceptedSaveTargets[path] ?? self.selectedParent(of: path, in: self.restoredDocumentFolders) {
                        sources[source.uri] = source
                    }
                }
                let selected = Set(sources.keys)
                if selected != self.persistedDocumentSources {
                    try state.rememberOpenDocumentGrants(Array(sources.values), layout: layout)
                    self.persistedDocumentSources = selected
                    for source in sources.values where source.isDirectory {
                        if let path = URL(string: source.uri)?.path { self.restoredDocumentFolders[path] = source }
                    }
                }
                token.send(Self.ok(NSNull()))
            } catch let error as WorkspaceFileSystemError {
                token.send(Self.error(error.code, error.message))
            } catch let error as BridgeError {
                token.send(Self.error(error.code, error.message))
            } catch {
                token.send(Self.error("WorkspaceStateUnavailable", "The saved document selections are unavailable."))
            }
        }
    }

    // Incoming document boundary. Queue state is main-thread confined; only authorization uses ioQueue.
    private struct IncomingDocument {
        let id: String
        let resourceKind: String
        let selection: NativeSceneSelection?
        var authorized: (uri: String, pathCapabilities: [[String: Any]])?
        var delivered = false
    }
    private let extensionURLs = NativeExtensionURLQueue()

    func receiveExtensionURL(_ url: URL) {
        guard !isTornDown else { return }
        do {
            try extensionURLs.receive(url)
            deliverExtensionURLs()
        } catch {
            // Never include the callback or an underlying parser error: it may contain credentials.
            logEvent?(["event": "native.extensionURLRejected"])
            onIncomingDocumentError?("The extension callback is invalid or too many callbacks are waiting. Please start the request again.")
        }
    }

    private func deliverExtensionURLs() {
        for event in extensionURLs.deliveries() { onRuntimeEvent?(event) }
    }

    private var incomingDocuments: [IncomingDocument] = []
    private var incomingDocumentReceiver: String?
    private var incomingDocumentPage: String?
    private var rendererUnavailable = false
    private var terminatedTerminalPage: String?

    /// End page endpoints, never the filesystem or terminal lifetime owner.
    func rendererDidTerminate() {
        if let page = incomingDocumentPage { terminatedTerminalPage = page }
        let terminatedPage = terminatedTerminalPage
        suspendIncomingDocumentPage()
        rendererUnavailable = true
        pendingLock.lock()
        let replies = Array(pending.values)
        pendingLock.unlock()
        for reply in replies {
            reply.send(Self.error("RendererTerminated", "the workbench page terminated"))
        }
        ioQueue.async { [self] in
            extensionHost.prepareForRendererReload { _ in }
            if let terminatedPage { try? terminalHost.retireRendererPage(terminatedPage) }
            fileSystem.stopAllWatches()
            fileSystem.stopAllFileTransfers()
            webviewService?.closeAll()
            webviewService = nil
        }
    }

    func prepareForRendererReload(completion: @escaping (Result<Void, Error>) -> Void) {
        let terminatedPage = terminatedTerminalPage
        ioQueue.async { [self] in
            // The independent AHP server survives. NativeAgentHost.start returns its live
            // authenticated endpoint to the replacement stock client.
            extensionHost.prepareForRendererReload { [self] result in
                ioQueue.async { [self] in
                    let terminalResult = Result { if let terminatedPage { try terminalHost.retireRendererPage(terminatedPage) } }
                    DispatchQueue.main.async {
                        completion(result.flatMap { terminalResult })
                    }
                }
            }
        }
    }

    /// Fence old-page start RPCs before preparing a committed navigation. Pending
    /// starts check the same fence when they reach the serialized host queue.
    @discardableResult
    func setExtensionHostStartsSuspended(_ suspended: Bool) -> UInt64 {
        extensionHostStartLock.lock()
        extensionHostStartsSuspended = suspended
        if suspended { extensionHostStartGeneration &+= 1 }
        let generation = extensionHostStartGeneration
        extensionHostStartLock.unlock()
        return generation
    }

    private func resumeExtensionHostStarts(ifGeneration generation: UInt64) -> Bool {
        extensionHostStartLock.lock()
        defer { extensionHostStartLock.unlock() }
        guard extensionHostStartsSuspended, extensionHostStartGeneration == generation else { return false }
        extensionHostStartsSuspended = false
        return true
    }

    /// Native navigation callbacks own this epoch; no RPC reveals or replaces it.
    func activateIncomingDocumentPage() -> String {
        rendererUnavailable = false
        let page = UUID().uuidString
        incomingDocumentPage = page
        registerTerminalBridge()
        extensionURLs.setPage(page)
        ioQueue.async { [host = terminalHost] in host.setRendererPage(page) }
        incomingDocumentReceiver = nil
        return page
    }

    func suspendIncomingDocumentPage() {
        NativeExtensionProfileFence.shared.abandon(owner: extensionProfileFenceOwner)
        cancelTerminalTransfers()
        ioQueue.async { [host = terminalHost] in host.setRendererPage(nil) }
        incomingDocumentPage = nil
        extensionURLs.setPage(nil)
        incomingDocumentReceiver = nil
    }

    func failPickedSelections(_ error: Error) {
        let selections = incomingDocuments.compactMap(\.selection)
        incomingDocuments.removeAll { $0.selection != nil }
        for selection in selections { selection.complete(.failure(error)) }
    }

    /// Swift-only entry point for the URLs delivered by UIWindowScene, never a pathname RPC.
    func receiveIncomingDocument(_ url: URL, selection: NativeSceneSelection? = nil) {
        do {
            let id = try reserveIncomingDocument(url, selection: selection)
            ioQueue.async { [weak self] in
                guard let self, !self.isTornDown else { return }
                let result = Result { try self.authorizeIncomingDocument(url, folder: selection != nil && url.hasDirectoryPath) }
                DispatchQueue.main.async {
                    guard !self.isTornDown else { return }
                    self.finishIncomingDocumentAuthorization(id: id, result: result)
                }
            }
        } catch {
            if let selection { selection.complete(.failure(error)) }
            else { onIncomingDocumentError?(incomingDocumentError(error)) }
        }
    }

    private func reserveIncomingDocument(_ url: URL, selection: NativeSceneSelection?) throws -> String {
        guard url.isFileURL, url.host == nil || url.host == "",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, url.path.hasPrefix("/"),
              url.absoluteString.utf8.count <= 16_384,
              !url.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw BridgeError(code: "InvalidDocument", message: "Only local file URLs can be opened as documents.")
        }
        guard selection != nil || url.pathExtension.lowercased() != "code-workspace" else {
            throw BridgeError(code: "UnsupportedDocument", message: "Use Open Workspace to open this workspace file and authorize its folders.")
        }
        guard incomingDocuments.count < 32 else {
            throw BridgeError(code: "TooManyDocuments", message: "Too many documents are waiting to open. Try this document again after the pending requests finish.")
        }
        let id = UUID().uuidString
        let kind = selection != nil && url.hasDirectoryPath ? "folder" : (url.pathExtension.lowercased() == "code-workspace" ? "workspace" : "file")
        incomingDocuments.append(IncomingDocument(id: id, resourceKind: kind, selection: selection))
        return id
    }

    private func authorizeIncomingDocument(_ url: URL, folder: Bool) throws -> (uri: String, pathCapabilities: [[String: Any]]) {
        let result = try fileSystem.withGrantTransaction { fs in
            let scoped = !Self.isInsideAppDocuments(url)
            let uri = try folder ? fs.grantDirectory(url, securityScoped: scoped) : fs.grantFile(url, securityScoped: scoped)
            // Reject unavailable path semantics before publishing a grant or editor request.
            return (uri, try pathCapabilityMetadata(forURIs: [uri], publishBrowserResources: true))
        }
        recordDocumentSource(RestoredDocumentGrant(selectedURL: url, uri: result.0, isDirectory: folder))
        return result
    }

    private func finishIncomingDocumentAuthorization(id: String, result: Result<(uri: String, pathCapabilities: [[String: Any]]), Error>) {
        guard let index = incomingDocuments.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let authorized):
            incomingDocuments[index].authorized = authorized
            deliverIncomingDocuments()
        case .failure(let error):
            if let selection = incomingDocuments.remove(at: index).selection { selection.complete(.failure(error)) }
            else { onIncomingDocumentError?(incomingDocumentError(error)) }
        }
    }

    private func performIncomingDocumentOperation(method: String, params: [String: Any]) throws -> (value: Any, pathCapabilities: [[String: Any]]) {
        guard let page = params["pageId"] as? String, page == incomingDocumentPage,
              let receiver = params["receiverId"] as? String, UUID(uuidString: receiver) != nil else {
            throw BridgeError(code: "InvalidRequest", message: "incoming document receiver identity is required")
        }
        if method == "documents.ready" || method == "documents.suspend" {
            guard Set(params.keys) == ["pageId", "receiverId"] else {
                throw BridgeError(code: "InvalidRequest", message: "unexpected incoming document receiver parameters")
            }
            if method == "documents.ready" {
                incomingDocumentReceiver = receiver
                for index in incomingDocuments.indices { incomingDocuments[index].delivered = false }
                deliverIncomingDocuments()
            } else if incomingDocumentReceiver == receiver {
                incomingDocumentReceiver = nil
            }
            return (NSNull(), [])
        }
        guard method == "documents.complete" || method == "documents.resolve", Set(params.keys).isSubset(of: ["pageId", "receiverId", "id", "error"]),
              let id = params["id"] as? String,
              params["error"] == nil || (params["error"] as? String).map({ !$0.isEmpty && $0.utf8.count <= 2048 }) == true else {
            throw BridgeError(code: "InvalidRequest", message: "invalid incoming document completion")
        }
        // An outgoing page cannot complete or suspend the replacement page's request.
        guard incomingDocumentReceiver == receiver,
              let index = incomingDocuments.firstIndex(where: { $0.id == id && $0.delivered }) else {
            throw BridgeError(code: "InvalidRequest", message: "incoming document request is not active for this receiver")
        }
        if method == "documents.resolve" {
            guard Set(params.keys) == ["pageId", "receiverId", "id"], let authorized = incomingDocuments[index].authorized else {
                throw BridgeError(code: "InvalidRequest", message: "incoming document is not authorized")
            }
            return (authorized.uri, authorized.pathCapabilities)
        }
        let selection = incomingDocuments.remove(at: index).selection
        if let message = params["error"] as? String {
            if let selection { selection.complete(.failure(BridgeError(code: "windowOpenFailed", message: message))) }
            else { onIncomingDocumentError?(message) }
        } else { selection?.complete(.success(())) }
        return (NSNull(), [])
    }

    private func incomingDocumentError(_ error: Error) -> String {
        if let error = error as? BridgeError { return error.message }
        if let error = error as? WorkspaceFileSystemError { return error.message }
        return error.localizedDescription
    }

    private func deliverIncomingDocuments() {
        guard let receiver = incomingDocumentReceiver, let page = incomingDocumentPage else { return }
        for index in incomingDocuments.indices {
            guard !incomingDocuments[index].delivered, incomingDocuments[index].authorized != nil else { continue }
            let request = incomingDocuments[index]
            guard let data = try? JSONSerialization.data(withJSONObject: ["id": request.id, "receiverId": receiver, "pageId": page, "resourceKind": request.resourceKind]) else {
                onIncomingDocumentError?("The requested document could not be delivered. Reload the workbench to retry.")
                return
            }
            incomingDocuments[index].delivered = true
            onRuntimeEvent?(["kind": "documents.open", "sessionId": 0, "requestId": request.id, "receiverId": receiver, "pageId": page,
                             "data": String(decoding: data, as: UTF8.self)])
        }
    }

    private func failIncomingDocumentDelivery(_ event: [String: Any], reason: String) {
        guard let id = event["requestId"] as? String, let receiver = event["receiverId"] as? String,
              let page = event["pageId"] as? String else { return }
        _ = try? performIncomingDocumentOperation(method: "documents.complete", params: ["id": id, "receiverId": receiver, "pageId": page, "error": reason])
    }
    // End incoming document boundary.

    // MARK: - fs.*

    private func handleFileSystem(method: String, params: [String: Any], token: ReplyToken) {
        ioQueue.async { [weak self] in
            guard let self else {
                token.send(Self.error("hostTornDown", "the native host went away before this request completed"))
                return
            }
            guard !self.isTornDown else { return }
            do {
                let value = try self.fileSystem.perform(method, params: params)
                DispatchQueue.main.async {
                    guard !self.isTornDown else { return }
                    #if DEBUG
                    self.logEvent?(["event": "native.fsSuccess", "method": method])
                    #endif
                    token.send(Self.ok(value))
                }
            } catch let error as WorkspaceFileSystemError {
                DispatchQueue.main.async {
                    guard !self.isTornDown else { return }
                    self.logEvent?(["event": "native.fsError", "method": method, "code": error.code])
                    token.send(Self.error(error.code, error.message))
                }
            } catch {
                DispatchQueue.main.async {
                    guard !self.isTornDown else { return }
                    self.logEvent?(["event": "native.fsError", "method": method, "code": "filesystemFailed"])
                    token.send(Self.error("filesystemFailed", error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Reply helpers

    /// Thread-safe: async completions must not mutate bridge state after teardown.
    private var isTornDown: Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return tornDown
    }

    private func forget(_ id: UUID) {
        pendingLock.lock()
        pending[id] = nil
        pendingLock.unlock()
    }

    private func finishPicker() {
        pickerOpensNewWindow = false
        pickerInFlight = false
        activePickerReply = nil
    }

    private static func ok(_ value: Any, pathCapabilities: [[String: Any]] = []) -> [String: Any] {
        var envelope: [String: Any] = ["ok": true, "value": value]
        if !pathCapabilities.isEmpty {
            envelope["pathCapabilities"] = pathCapabilities
        }
        return envelope
    }

    private static func error(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": ["code": code, "message": message]]
    }

    private struct BridgeError: LocalizedError {
        var errorDescription: String? { message }
        let code: String
        let message: String
    }

    /// One-shot reply: later sends are ignored, so teardown and a late completion cannot both reply.
    private final class ReplyToken {
        let id = UUID()
        private let lock = NSLock()
        private var handler: ((Any?, String?) -> Void)?
        weak var bridge: NativeWorkspaceBridge?

        init(_ handler: @escaping (Any?, String?) -> Void) {
            self.handler = handler
        }

        var isPending: Bool {
            lock.lock()
            defer { lock.unlock() }
            return handler != nil
        }

        func send(_ value: Any?, error: String? = nil) {
            lock.lock()
            let handler = self.handler
            self.handler = nil
            lock.unlock()
            handler?(value, error)
            bridge?.forget(id)
        }
    }
}

// MARK: - Script message handler

extension NativeWorkspaceBridge: WKScriptMessageHandlerWithReply {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        handle(message: message, replyHandler: replyHandler)
    }
}

// MARK: - Document picker

extension NativeWorkspaceBridge: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !isTornDown else { return }
        if let completion = activeWorkspacePicker {
            activeWorkspacePicker = nil
            finishPicker()
            completion(urls)
            return
        }
        guard let token = activePickerReply else { return }
        activePickerReply = nil
        if pickerOpensNewWindow {
            finishPicker()
            guard urls.count == 1, let url = urls.first else {
                reject(token, "invalidSelection", "select one resource for the new window")
                return
            }
            NativeSceneActivation.open(pickedURL: url) { result in
                switch result {
                case .success: token.send(Self.ok([String]()))
                case .failure(let error): token.send(Self.error("windowOpenFailed", error.localizedDescription))
                }
            }
        } else {
            authorize(urls: urls, token: token)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard !isTornDown else { return }
        // Cancellation leaves the previous selection and grant untouched.
        if let completion = activeWorkspacePicker {
            activeWorkspacePicker = nil
            finishPicker()
            completion([])
            return
        }
        pickerInFlight = false
        guard let token = activePickerReply else { return }
        activePickerReply = nil
        logEvent?(["event": "native.selectionCancelled"])
        token.send(Self.ok([String]()))
    }
}
