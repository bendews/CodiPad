import CodiPadWorkspace
import CoreFoundation
import AVFoundation
import GameController
import UIKit
import WebKit

/// Native host for the bundled VS Code workbench.
///
/// Renders `Workbench/index.html` and its relative assets from the app bundle. It is not a
/// remote-server client. Native errors identify unavailable workbench artifacts and failed
/// system document opens; document content stays in the ordinary workbench editors.
final class WorkbenchViewController: UIViewController {
    private static var storageMigrationRunning = false
    private static var storageMigrationWaiters: [() -> Void] = []
    /// Directory inside the app bundle, produced by the parent build from app/generated/Workbench.
    static let artifactDirectory = "Workbench"
    static let entryPoint = "index.html"
    /// Command that builds the app and bundles the workbench artifact.
    static let buildCommand = "python3 scripts/build.py --sdk iphoneos"

    /// Shared lifetime owner for the native picker's security-scoped workspace grants.
    private let workspaceAccess: WorkspaceAccess
    private let sceneID: String?
    private let migrateLegacyRemote: Bool
    private let windowKind: NativeWindowKind
    private var sceneDisconnected = false
    private let bridge = WorkbenchBridge()
    /// UIKit can suspend the process without a web shutdown event. Keep live PTYs running.
    func checkpointTerminals() {
        guard let webView, workbenchLoaded else { return }
        var task = UIBackgroundTaskIdentifier.invalid
        var deadline: DispatchWorkItem?
        let finish = {
            deadline?.cancel()
            if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
        }
        task = UIApplication.shared.beginBackgroundTask(withName: "Terminal checkpoint", expirationHandler: finish)
        let timeout = DispatchWorkItem(block: finish)
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        webView.callAsyncJavaScript("if (typeof globalThis.__codipadCheckpointTerminals !== 'function') { throw new Error('terminal checkpoint unavailable'); } await globalThis.__codipadCheckpointTerminals();", arguments: [:], in: nil, in: .page) { result in
            if case .failure(let error) = result { print("codipad-terminal checkpoint failed: \(error)") }
            finish()
        }
    }

    private var nativeBridge: NativeWorkspaceBridge?
    private var webView: WKWebView?
    private var artifactRoot: URL?
    private var artifactServer: NativeWorkbenchAssetLease?
    private let topSafeAreaFill = UIView()
    private let bottomSafeAreaFill = UIView()
    private var themeStatusBarStyle: UIStatusBarStyle = .default
    override var preferredStatusBarStyle: UIStatusBarStyle { themeStatusBarStyle }
    private var storageMigration: NativeStorageMigration?
    private var sceneFocused = false
    private var sceneFocusRevision = 0
    private var incomingDocumentHasCommittedPage = false
    private var incomingDocumentPage: String?
    private var incomingDocumentErrors: [String] = []
    private weak var incomingDocumentAlert: UIAlertController?
    private struct NativeMenuNode: Decodable {
        let title: String?
        let id: String?
        let token: String?
        let enabled: Bool?
        let checked: Bool?
        let children: [NativeMenuNode]?
        let separator: Bool?
    }
    private struct NativeMenuSnapshot {
        let page: String
        let receiver: String
        let revision: String
        let nodes: [NativeMenuNode]
    }
    private var nativeMenu: NativeMenuSnapshot?
    private var nativeOpenReceiver: String?
    private var nativeOpenInvocation: UUID?
    private var nativeOpenBusy = false
    private var nativeOpenSuspended = true
    private lazy var openButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Open…", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityIdentifier = "codipad.native.open"
        button.accessibilityLabel = "Open File"
        button.accessibilityHint = "Choose a file to open in the workbench"
        button.isEnabled = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(openFile), for: .touchUpInside)
        return button
    }()
    private var rendererRecoveryGeneration = UUID()
    private var rendererRecoveryNeeded = false
    private var rendererRecoveryInFlight = false
    private var committedReloadInFlight = false
    private lazy var reloadButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Reload Workbench", for: .normal)
        button.accessibilityIdentifier = "codipad.native.reloadWorkbench"
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        button.addTarget(self, action: #selector(reloadWorkbench), for: .touchUpInside)
        return button
    }()
    private let terminalKeyboard = TerminalKeyboardBar()
    private var terminalKeyboardHeight: NSLayoutConstraint?
    private var terminalKeyboardTarget: (page: String, receiver: String, focus: String)?
    private var hardwareKeyboardObservers: [NSObjectProtocol] = []
    private var keyboardGuideBottom: NSLayoutConstraint?
    private var hardwareAssistantBottom: NSLayoutConstraint?
    private var terminalKeyboardSafeBottom: NSLayoutConstraint?
    private var keyboardScreenFrame: CGRect?
    private weak var keyboardScreen: UIScreen?
    // iPadOS does not identify the hardware assistant in public keyboard notifications.
    // A short full-screen frame is treated as the assistant only while hardware is present.
    private static func isHardwareAssistantFrame(_ frame: CGRect?, screenBounds: CGRect,
                                                  hardware: Bool, local: Bool, accessible: Bool) -> Bool {
        guard hardware, local, !accessible, let frame,
              [frame.minX, frame.minY, frame.width, frame.height, screenBounds.minX, screenBounds.minY,
               screenBounds.width, screenBounds.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0, frame.height <= 96,
              screenBounds.width > 0, screenBounds.height > 0 else { return false }
        return frame.intersects(screenBounds)
    }

    // An empty frame from another scene can precede the keyboard guide settling.
    private static func retainAssistantForEmptyFrame(_ frame: CGRect, overlayActive: Bool) -> Bool {
        overlayActive && frame.width == 0 && frame.height == 0
    }

    private func updateHardwareAssistantOverlay() {
        guard let guide = keyboardGuideBottom, let overlay = hardwareAssistantBottom else { return }
        let window = viewIfLoaded?.window
        let ownsKeyboard = window?.isKeyWindow == true && window?.windowScene?.activationState == .foregroundActive &&
            keyboardScreen != nil && keyboardScreen === window?.screen
        let overlayAssistant = Self.isHardwareAssistantFrame(keyboardScreenFrame,
            screenBounds: window?.screen.coordinateSpace.bounds ?? .null,
            hardware: GCKeyboard.coalesced != nil, local: ownsKeyboard,
            accessible: UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning)
        guard overlayAssistant != overlay.isActive else { return }
        if overlayAssistant { guide.isActive = false; overlay.isActive = true }
        else { overlay.isActive = false; guide.isActive = true }
    }

    private func keyboardFrameDidChange(_ notification: Notification) {
        guard let window = viewIfLoaded?.window else { keyboardScreenFrame = nil; keyboardScreen = nil; updateHardwareAssistantOverlay(); return }
        if let screen = notification.object as? UIScreen, screen !== window.screen { return }
        guard let screen = notification.object as? UIScreen,
              notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool == true,
              let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            keyboardScreenFrame = nil; keyboardScreen = nil; updateHardwareAssistantOverlay()
            return
        }
        if Self.retainAssistantForEmptyFrame(frame, overlayActive: hardwareAssistantBottom?.isActive == true),
           GCKeyboard.coalesced != nil, !UIAccessibility.isVoiceOverRunning, !UIAccessibility.isSwitchControlRunning {
            return
        }
        keyboardScreenFrame = frame
        keyboardScreen = screen
        updateHardwareAssistantOverlay()
    }

    private func updateTerminalKeyboardVisibility() {
        let show = terminalKeyboardTarget != nil && GCKeyboard.coalesced == nil
        if !show && !terminalKeyboard.isHidden {
            sendTerminalKey("Cancel")
            terminalKeyboard.cancel()
        }
        terminalKeyboard.isHidden = !show
        terminalKeyboardHeight?.constant = show ? 44 : 0
        terminalKeyboardSafeBottom?.isActive = show
    }

    private func sendTerminalKey(_ key: String) {
        guard let target = terminalKeyboardTarget, incomingDocumentHasCommittedPage,
              target.page == incomingDocumentPage, let webView else { return }
        webView.callAsyncJavaScript("return globalThis.__codipadTerminalKeyboard?.invoke(page, receiver, focus, key) === true;",
            arguments: ["page": target.page, "receiver": target.receiver, "focus": target.focus, "key": key],
            in: nil, in: .page) { [weak self] result in
                guard let self, self.terminalKeyboardTarget?.focus == target.focus else { return }
                if case .success(let accepted) = result, accepted as? Bool == true { return }
                self.terminalKeyboard.cancel()
            }
    }

    func cancelTerminalKeys() {
        sendTerminalKey("Cancel")
        terminalKeyboard.cancel()
    }

    private var workbenchLoaded = false
    private var reportedViewportSize: CGSize?
    private var viewportUpdate: UUID?
    private var viewportRetryUsed = false
    private var viewportDisplayLink: CADisplayLink?
    private let workbenchViewport = UIView()
    private var viewportHandoffSnapshot: UIView?

    @MainActor private final class ViewportFrameTarget: NSObject {
        weak var owner: WorkbenchViewController?
        init(_ owner: WorkbenchViewController) { self.owner = owner }
        @objc func update(_ link: CADisplayLink) { owner?.publishWorkbenchViewport() }
    }

    private lazy var errorView: UITextView = {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.alwaysBounceVertical = true
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20)
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    init(access: WorkspaceAccess, sceneID: String? = nil, migrateLegacyRemote: Bool = true, windowKind: NativeWindowKind = .editor) {
        self.workspaceAccess = access
        self.sceneID = sceneID
        self.migrateLegacyRemote = migrateLegacyRemote
        self.windowKind = windowKind
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(access:)")
    }

    deinit {
        viewportDisplayLink?.invalidate()
        hardwareKeyboardObservers.forEach(NotificationCenter.default.removeObserver)
        bridge.onEvent = nil
        nativeBridge?.teardown()
        artifactServer?.close()
        let controller = webView?.configuration.userContentController
        controller?.removeScriptMessageHandler(forName: WorkbenchBridge.name)
        controller?.removeScriptMessageHandler(forName: NativeWorkspaceBridge.name)
    }

    /// A disconnected scene is no longer visible; retain process owners until their own cleanup settles.
    func disconnectScene() {
        guard !sceneDisconnected else { return }
        sceneDisconnected = true
        clearViewportHandoff()
        viewportDisplayLink?.invalidate()
        viewportDisplayLink = nil
        cancelTerminalKeys()
        suspendOpenButton()
        nativeBridge?.teardown()
        if storageMigration == nil { artifactServer?.close() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "CodiPad"
        view.backgroundColor = .systemBackground

        bridge.onEvent = { [weak self] event, frame in
            self?.accept(bridgeEvent: event, from: frame)
        }

        view.addSubview(reloadButton)
        view.addSubview(errorView)
        NSLayoutConstraint.activate([
            reloadButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            reloadButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            reloadButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            errorView.topAnchor.constraint(equalTo: reloadButton.bottomAnchor),
            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        guard let root = Self.artifactRoot(bundle: .main) else {
            showMissingArtifact()
            return
        }
        artifactRoot = root
        loadWorkbench(root: root)
    }

    func openIncomingURL(_ url: URL) {
        if url.isFileURL { openIncomingDocument(url); return }
        guard NativeExtensionURLQueue.accepts(url) else {
            reportIncomingDocumentError("The extension callback is invalid. Please start the request again.")
            return
        }
        loadViewIfNeeded()
        guard let nativeBridge else {
            reportIncomingDocumentError("The workbench is unavailable. Please start the request again.")
            return
        }
        nativeBridge.receiveExtensionURL(url)
    }

    func openPickedSelection(_ selection: NativeSceneSelection) {
        loadViewIfNeeded()
        if !errorView.isHidden, let message = errorView.text, !message.isEmpty {
            selection.complete(.failure(NSError(domain: "CodiPadScene", code: 4, userInfo: [NSLocalizedDescriptionKey: message])))
            return
        }
        guard let nativeBridge else {
            selection.complete(.failure(CocoaError(.fileReadUnknown)))
            return
        }
        nativeBridge.receiveIncomingDocument(selection.url, selection: selection)
    }

    /// Only SceneDelegate calls this with a system-delivered URL; the renderer cannot grant paths.
    func openIncomingDocument(_ url: URL) {
        loadViewIfNeeded()
        guard let nativeBridge else {
            reportIncomingDocumentError("The workbench is unavailable. The requested document was not opened.")
            return
        }
        nativeBridge.receiveIncomingDocument(url)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentIncomingDocumentError()
    }

    private func canDeliverRuntimeEvent(_ event: [String: Any], in webView: WKWebView) -> Bool {
        if (event["kind"] as? String)?.hasPrefix("terminal.") == true {
            // A provisional URL is not a replacement document. The JS receiver also checks this epoch.
            guard incomingDocumentHasCommittedPage, let page = incomingDocumentPage else { return false }
            return page == event["pageId"] as? String
        }
        return incomingDocumentHasCommittedPage && webView.url.map(isWorkbenchEntryPoint) == true
    }

    /// Install a native-chosen epoch only into the currently committed main document.
    private func publishIncomingDocumentPage(finalAttempt: Bool = false) {
        guard incomingDocumentHasCommittedPage, let page = incomingDocumentPage, let webView,
              let url = webView.url, isWorkbenchEntryPoint(url) else { return }
        webView.callAsyncJavaScript("""
            if (globalThis.__codipadIncomingDocumentPage !== pageId) {
                globalThis.__codipadIncomingDocumentPage = pageId;
                globalThis.dispatchEvent(new Event('codipad-incoming-document-page'));
            }
            return true;
            """, arguments: ["pageId": page], in: nil, in: .page) { [weak self] result in
                if case .failure = result {
                    self?.log(event: ["event": "native.incomingDocumentBindingFailed"])
                    if finalAttempt, self?.incomingDocumentPage == page {
                        self?.reportIncomingDocumentError("The workbench could not receive incoming documents. The pending requests are preserved; reload the workbench to retry.")
                    }
                }
            }
    }

    private func reportIncomingDocumentError(_ message: String) {
        guard incomingDocumentErrors.count < 32 else { return }
        incomingDocumentErrors.append(message)
        presentIncomingDocumentError()
    }

    private func presentIncomingDocumentError() {
        guard viewIfLoaded?.window != nil, incomingDocumentAlert == nil,
              !incomingDocumentErrors.isEmpty else { return }
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController { presenter = presented }
        if let transition = presenter.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { [weak self] _ in self?.presentIncomingDocumentError() }
            return
        }
        let alert = UIAlertController(title: "Unable to Open Request", message: incomingDocumentErrors.removeFirst(), preferredStyle: .alert)
        incomingDocumentAlert = alert
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self, weak alert] _ in
            alert?.dismiss(animated: true) {
                self?.incomingDocumentAlert = nil
                self?.presentIncomingDocumentError()
            }
        })
        presenter.present(alert, animated: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutWorkbenchSurface()
        updateWorkbenchViewport()
    }

    private func layoutWorkbenchSurface() {
        guard let webView else { return }
        let visible = workbenchViewport.bounds.size
        guard visible.width.isFinite, visible.height.isFinite, visible.width > 0, visible.height > 0 else { return }
        let dragging: Bool
        if #available(iOS 26.0, *) { dragging = view.window?.windowScene?.effectiveGeometry.isInteractivelyResizing == true }
        else { dragging = false }
        if dragging || (viewportHandoffSnapshot != nil && viewportHandoffSnapshot?.bounds.size != visible) { clearViewportHandoff() }
        // A stable surface avoids magnifying the workbench during a drag. At rest,
        // the web view's own size determines the page's CSS viewport units.
        var surface = visible
        if #available(iOS 26.0, *), let scene = view.window?.windowScene,
           dragging,
           scene.screen.bounds.width.isFinite, scene.screen.bounds.height.isFinite,
           scene.screen.bounds.width > 0, scene.screen.bounds.height > 0 {
            let display = scene.screen.bounds.size
            surface = CGSize(width: max(display.width, visible.width), height: max(display.height, visible.height))
        }
        if webView.frame.size != surface {
            if #available(iOS 26.0, *), !dragging, webView.maximumViewportInset != .zero {
                beginViewportHandoff(size: visible, webView: webView)
            } else { clearViewportHandoff() }
            if #available(iOS 26.0, *), webView.maximumViewportInset != .zero {
                // An old inset can exceed the new frame when a window moves to a smaller display.
                webView.setMinimumViewportInset(.zero, maximumViewportInset: .zero)
                webView.obscuredContentInsets = .zero
            }
            webView.frame = CGRect(origin: .zero, size: surface)
        }
        if #available(iOS 26.0, *) {
            let insets = UIEdgeInsets(top: 0, left: 0, bottom: surface.height - visible.height, right: surface.width - visible.width)
            if webView.obscuredContentInsets != insets { webView.obscuredContentInsets = insets }
            // Both large and small CSS viewport units exclude the area beyond the clip.
            if webView.maximumViewportInset != insets || webView.minimumViewportInset != insets {
                webView.setMinimumViewportInset(insets, maximumViewportInset: insets)
            }
        }
    }

    private func clearViewportHandoff() {
        viewportHandoffSnapshot?.removeFromSuperview()
        viewportHandoffSnapshot = nil
    }

    private func beginViewportHandoff(size: CGSize, webView: WKWebView) {
        clearViewportHandoff()
        guard workbenchLoaded, !sceneDisconnected,
              let snapshot = workbenchViewport.snapshotView(afterScreenUpdates: false) else { return }
        viewportHandoffSnapshot = snapshot
        snapshot.frame = workbenchViewport.bounds
        snapshot.isUserInteractionEnabled = false
        snapshot.isAccessibilityElement = false
        snapshot.accessibilityElementsHidden = true
        workbenchViewport.addSubview(snapshot)
        // Wait until WebKit reports the new ordinary viewport units and paints a frame.
        webView.callAsyncJavaScript("""
            const probe = document.createElement('div');
            probe.style.cssText = 'position:fixed!important;visibility:hidden!important;pointer-events:none!important;width:100vw!important;height:100vh!important';
            document.documentElement.appendChild(probe);
            try { return await new Promise(resolve => {
                let done = false, scheduled = false;
                const matches = () => {
                    const rect = probe.getBoundingClientRect();
                    return Math.abs(rect.width - width) < 1 && Math.abs(rect.height - height) < 1;
                };
                const finish = ready => {
                    if (done) return;
                    done = true; clearTimeout(timer); observer.disconnect(); probe.remove(); resolve(ready);
                };
                const observer = new ResizeObserver(() => {
                    if (done || scheduled || !matches()) return;
                    scheduled = true;
                    requestAnimationFrame(() => requestAnimationFrame(() => {
                        scheduled = false;
                        if (!done && matches()) finish(true);
                    }));
                });
                const timer = setTimeout(() => finish(false), 1000);
                observer.observe(probe);
            }); } finally { probe.remove(); }
            """, arguments: ["width": size.width, "height": size.height], in: nil, in: .defaultClient) { [weak self, weak snapshot] _ in
            guard let self, let snapshot, self.viewportHandoffSnapshot === snapshot else { return }
            self.clearViewportHandoff()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak snapshot] in
            guard let self, let snapshot, self.viewportHandoffSnapshot === snapshot else { return }
            self.clearViewportHandoff()
        }
    }

    /// WebKit can deliver its document resize after the window or keyboard has moved.
    /// Report the usable size to the workbench as soon as UIKit lays out the clipping view.
    private func updateWorkbenchViewport() {
        guard workbenchLoaded, !sceneDisconnected, webView != nil else { return }
        let size = workbenchViewport.bounds.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              reportedViewportSize != size else { return }
        if viewportDisplayLink == nil {
            let link = CADisplayLink(target: ViewportFrameTarget(self), selector: #selector(ViewportFrameTarget.update(_:)))
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            viewportDisplayLink = link
        }
        viewportDisplayLink?.isPaused = false
    }

    private func publishWorkbenchViewport() {
        viewportDisplayLink?.isPaused = true
        guard workbenchLoaded, !sceneDisconnected, let webView else { return }
        let size = workbenchViewport.bounds.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              reportedViewportSize != size else { return }
        // A slow JavaScript acknowledgement must not hold up subsequent live-resize frames.
        let update = UUID()
        viewportUpdate = update
        reportedViewportSize = size
        webView.callAsyncJavaScript(
            "if (typeof window.__codipadSetNativeViewport !== 'function') return false; window.__codipadSetNativeViewport(height, width); return true;",
            arguments: ["height": size.height, "width": size.width],
            in: nil,
            in: .page
        ) { [weak self, weak webView] result in
            guard let self, let webView, self.webView === webView, self.viewportUpdate == update else { return }
            self.viewportUpdate = nil
            if case .success(let accepted) = result, accepted as? Bool == true {
                self.viewportRetryUsed = false
            } else {
                self.reportedViewportSize = nil
                if !self.viewportRetryUsed {
                    self.viewportRetryUsed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak webView] in
                        guard let self, let webView, self.webView === webView else { return }
                        self.updateWorkbenchViewport()
                    }
                }
            }
            if self.workbenchViewport.bounds.size != size {
                self.updateWorkbenchViewport()
            }
        }
    }

    private func updateOpenButton() {
        openButton.isEnabled = !nativeOpenSuspended && nativeOpenReceiver != nil &&
            nativeOpenInvocation == nil && !nativeOpenBusy && incomingDocumentHasCommittedPage && errorView.isHidden
    }

    private func suspendOpenButton() {
        nativeMenu = nil
        UIMenuSystem.main.setNeedsRebuild()
        terminalKeyboard.cancel()
        terminalKeyboardTarget = nil
        terminalKeyboard.isHidden = true
        terminalKeyboardHeight?.constant = 0
        nativeOpenSuspended = true
        nativeOpenReceiver = nil
        nativeOpenInvocation = nil
        nativeOpenBusy = false
        updateOpenButton()
    }

    @objc private func openFile() {
        guard openButton.isEnabled, let webView, let page = incomingDocumentPage,
              let receiver = nativeOpenReceiver, let url = webView.url, isWorkbenchEntryPoint(url) else { return }
        let invocation = UUID()
        nativeOpenInvocation = invocation
        updateOpenButton()
        webView.callAsyncJavaScript("""
            const actions = globalThis.__codipadNativeWorkbenchActions;
            if (globalThis.__codipadIncomingDocumentPage !== pageId || actions?.receiverId !== receiverId) {
                throw new Error('The workbench Open action is unavailable');
            }
            await actions.openFile(pageId, receiverId);
            return true;
            """, arguments: ["pageId": page, "receiverId": receiver], in: nil, in: .page) { [weak self, weak webView] result in
                guard let self, self.webView === webView, self.incomingDocumentPage == page,
                      self.nativeOpenReceiver == receiver, self.nativeOpenInvocation == invocation else { return }
                self.nativeOpenInvocation = nil
                self.updateOpenButton()
                if case .failure = result {
                    self.reportIncomingDocumentError("The file could not be opened. Try Open again when the workbench is available.")
                }
            }
    }

    func setSceneFocused(_ focused: Bool) {
        guard sceneFocused != focused else { return }
        sceneFocused = focused
        sceneFocusRevision += 1
        publishSceneFocus()
    }

    private func publishSceneFocus() {
        guard incomingDocumentHasCommittedPage, let webView,
              let url = webView.url, isWorkbenchEntryPoint(url) else { return }
        webView.callAsyncJavaScript(
            "return globalThis.__codipadSetSceneFocus?.(focused, revision);",
            arguments: ["focused": sceneFocused, "revision": sceneFocusRevision], in: nil, in: .page
        ) { _ in }
    }

    // MARK: - Loading

    private func loadWorkbench(root: URL) {
        #if DEBUG
        _ = DebugWorkbenchLog.spawnDiagnostics
        #endif
        let configuration = WKWebViewConfiguration()
        let sceneData = try! JSONEncoder().encode(sceneID ?? "single")
        let sceneLiteral = String(decoding: sceneData, as: UTF8.self)
        configuration.userContentController.addUserScript(WKUserScript(
            source: "globalThis.__codipadSceneId = \(sceneLiteral); globalThis.__codipadMigrateLegacyRemote = \(migrateLegacyRemote); globalThis.__codipadWindowKind = '\(windowKind.rawValue)';",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            (() => {
                let revision = -1;
                globalThis.__codipadSceneFocused = false;
                globalThis.__codipadSetSceneFocus = (focused, nextRevision) => {
                    if (typeof focused !== 'boolean' || !Number.isSafeInteger(nextRevision) || nextRevision < revision) return;
                    revision = nextRevision;
                    if (globalThis.__codipadSceneFocused !== focused) {
                        globalThis.__codipadSceneFocused = focused;
                        globalThis.dispatchEvent(new Event('codipad-scene-focus'));
                    }
                };
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // iOS permits the pinned webview shell's Service Worker on declared app-bound domains.
        configuration.limitsNavigationsToAppBoundDomains = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(bridge, name: WorkbenchBridge.name)

        // Native picker + filesystem replies. Registered in the page content world so the
        // artifact's own script can call window.webkit.messageHandlers.codipadNative.
        let nativeBridge = NativeWorkspaceBridge(fileSystem: WorkspaceFileSystem(access: workspaceAccess), sceneID: sceneID, canAdoptLegacy: migrateLegacyRemote)
        nativeBridge.presenter = self
        nativeBridge.artifactRoot = root
        nativeBridge.topLevelURL = { [weak self] in self?.webView?.url }
        nativeBridge.isTrustedWorkbenchURL = { [weak self] in self?.isWorkbenchEntryPoint($0) == true }
        nativeBridge.logEvent = { [weak self] event in self?.log(event: event) }
        nativeBridge.onIncomingDocumentError = { [weak self] message in
            self?.reportIncomingDocumentError(message)
        }
        nativeBridge.onRuntimeEvent = { [weak self, weak nativeBridge] event in
            guard let self, let webView = self.webView, self.canDeliverRuntimeEvent(event, in: webView) else {
                nativeBridge?.completeRuntimeEventDelivery(event, accepted: false, reason: "workbench page is unavailable")
                return
            }
            webView.callAsyncJavaScript(
                "if (event.kind?.startsWith('terminal.') && event.pageId !== globalThis.__codipadIncomingDocumentPage) { return false; } return window.__codipadRuntimeEvent?.(event) === true;",
                arguments: ["event": event], in: nil, in: .page
            ) { [weak self, weak nativeBridge] result in
                let accepted = (try? result.get()) as? Bool == true
                nativeBridge?.completeRuntimeEventDelivery(event, accepted: accepted, reason: "renderer did not accept output")
                if case .failure = result {
                    self?.log(event: ["event": "native.runtimeEventDeliveryFailed"])
                }
            }
        }
        configuration.userContentController.addScriptMessageHandler(
            nativeBridge, contentWorld: NativeWorkspaceBridge.contentWorld, name: NativeWorkspaceBridge.name
        )
        self.nativeBridge = nativeBridge

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        // Workbench chrome (title/menu bar) sits at the top edge; keep it inside the safe area
        // instead of under the iPad status bar. The keyboard guide resolves to the safe-area
        // bottom when the keyboard is hidden and to the docked keyboard top while it is visible,
        // so WKWebView and the workbench resize to the area where the editor can actually be used.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.autoresizingMask = []
        #if DEBUG
        webView.isInspectable = true
        #endif
        let viewport = workbenchViewport
        viewport.clipsToBounds = true
        viewport.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(viewport)
        viewport.addSubview(webView)
        for fill in [topSafeAreaFill, bottomSafeAreaFill] {
            fill.isUserInteractionEnabled = false
            fill.translatesAutoresizingMaskIntoConstraints = false
            view.insertSubview(fill, at: 0)
        }
        terminalKeyboard.translatesAutoresizingMaskIntoConstraints = false
        terminalKeyboard.isHidden = true
        terminalKeyboard.send = { [weak self] key in self?.sendTerminalKey(key) }
        view.addSubview(terminalKeyboard)
        terminalKeyboardHeight = terminalKeyboard.heightAnchor.constraint(equalToConstant: 0)
        terminalKeyboardHeight?.isActive = true
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        keyboardGuideBottom = terminalKeyboard.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        keyboardGuideBottom?.priority = .init(999)
        hardwareAssistantBottom = terminalKeyboard.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        hardwareAssistantBottom?.priority = .init(999)
        terminalKeyboardSafeBottom = terminalKeyboard.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor)
        keyboardGuideBottom?.isActive = true
        NSLayoutConstraint.activate([
            topSafeAreaFill.topAnchor.constraint(equalTo: view.topAnchor),
            topSafeAreaFill.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topSafeAreaFill.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topSafeAreaFill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bottomSafeAreaFill.topAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            bottomSafeAreaFill.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomSafeAreaFill.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomSafeAreaFill.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            viewport.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            viewport.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            viewport.bottomAnchor.constraint(equalTo: terminalKeyboard.topAnchor),
            terminalKeyboard.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            terminalKeyboard.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        self.webView = webView
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            hardwareKeyboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateTerminalKeyboardVisibility()
                self?.updateHardwareAssistantOverlay()
            })
        }
        hardwareKeyboardObservers.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] notification in
            self?.keyboardFrameDidChange(notification)
        })
        for name in [UIAccessibility.voiceOverStatusDidChangeNotification, UIAccessibility.switchControlStatusDidChangeNotification] {
            hardwareKeyboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateHardwareAssistantOverlay()
            })
        }
        hardwareKeyboardObservers.append(NotificationCenter.default.addObserver(forName: UIWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, notification.object as? UIWindow === self.viewIfLoaded?.window else { return }
            self.keyboardScreenFrame = nil; self.keyboardScreen = nil; self.updateHardwareAssistantOverlay()
        })

        startWorkbenchOrigin(root: root, webView: webView)
    }

    private func isWorkbenchEntryPoint(_ url: URL) -> Bool { artifactServer?.isEntryPoint(url, agents: windowKind == .agents) == true }

    private func startWorkbenchOrigin(root: URL, webView: WKWebView) {
        do {
            let server = try NativeWorkbenchAssetPool.acquire(resourceRoot: root)
            artifactServer = server
            nativeBridge?.extensionAssetServer = server
            let preferred = try NativeStorageMigration.preferredPort()
            server.start(preferredPort: preferred) { [weak self, weak webView, weak server] result in
                DispatchQueue.main.async {
                    guard let self, let webView, let server, self.artifactServer === server else { return }
                    do {
                        _ = try result.get()
                        guard let entry = server.entryURL(agents: self.windowKind == .agents),
                              self.windowKind != .agents || server.hasAgentsEntry() else {
                            self.showError("The Agents Window is unavailable in this build.")
                            return
                        }
                        self.prepareWorkbenchStorage(entry: entry, root: root, webView: webView, server: server)
                    } catch {
                        self.log(event: ["event": "native.workbenchOriginFailed"])
                        self.showError("CodiPad could not start its local workbench. Your files and saved data are preserved. Reopen the app to retry.")
                    }
                }
            }
        } catch {
            log(event: ["event": "native.workbenchOriginFailed"])
            showError("CodiPad could not start its local workbench. Your files and saved data are preserved. Reopen the app to retry.")
        }
    }

    private static func finishStorageMigration() {
        storageMigrationRunning = false
        let waiters = storageMigrationWaiters
        storageMigrationWaiters.removeAll()
        waiters.forEach { $0() }
    }

    private func prepareWorkbenchStorage(entry: URL, root: URL, webView: WKWebView, server: NativeWorkbenchAssetLease) {
        guard !sceneDisconnected, self.webView === webView, artifactServer === server else { return }
        if Self.storageMigrationRunning {
            Self.storageMigrationWaiters.append { [weak self, weak webView, weak server] in
                guard let self, let webView, let server else { return }
                self.prepareWorkbenchStorage(entry: entry, root: root, webView: webView, server: server)
            }
            return
        }
        do {
            try NativeStorageMigration.rememberPort(for: entry)
            if try NativeStorageMigration.isComplete(for: entry) {
                loadWorkbenchEntry(entry, into: webView)
                return
            }
            guard let page = server.migrationURL() else { throw NativeStorageMigration.Failure.invalidState }
            let migration = try NativeStorageMigration(webView: webView, fileRoot: root, targetPage: page)
            Self.storageMigrationRunning = true
            storageMigration = migration
            migration.run { [self, weak webView] result in
                defer { Self.finishStorageMigration() }
                storageMigration = nil
                if sceneDisconnected { artifactServer?.close(); return }
                guard !sceneDisconnected, let webView, self.webView === webView, artifactServer === server else { return }
                switch result {
                case .success:
                    log(event: ["event": "native.workbenchStorageMigration", "success": true])
                    loadWorkbenchEntry(entry, into: webView)
                case .failure(let error):
                    let failure = error as NSError
                    log(event: ["event": "native.workbenchStorageMigration", "success": false,
                                "stage": migration.stage, "domain": failure.domain, "code": failure.code])
                    showError("CodiPad could not prepare your saved workbench data. Your existing data is preserved. Reopen the app to retry.")
                }
            }
        } catch {
            log(event: ["event": "native.workbenchOriginFailed"])
            showError("CodiPad could not start its local workbench. Your files and saved data are preserved. Reopen the app to retry.")
        }
    }

    private func loadWorkbenchEntry(_ entry: URL, into webView: WKWebView) {
        log(event: ["event": "workbench.load", "url": windowKind == .agents ? "agents.html" : Self.entryPoint])
        webView.load(URLRequest(url: entry))
    }

    /// Resolves the bundled artifact, or nil when the parent build did not produce it.
    static func artifactRoot(bundle: Bundle) -> URL? {
        guard let root = bundle.url(forResource: artifactDirectory, withExtension: nil) else { return nil }
        let index = root.appendingPathComponent(entryPoint, isDirectory: false)
        guard FileManager.default.fileExists(atPath: index.path) else { return nil }
        return root
    }

    private func showMissingArtifact() {
        let message = """
        Workbench unavailable.

        This build contains no \(Self.artifactDirectory)/\(Self.entryPoint) resource, so there is nothing to render. The workbench is built from pinned VS Code source and copied to app/generated/\(Self.artifactDirectory) during the app build.

        Rebuild (this also builds and bundles the workbench artifact):
          \(Self.buildCommand)

        No editor, terminal, extension host, or process model is implemented in this build.
        """
        log(event: [
            "event": "workbench.artifactMissing",
            "path": "\(Self.artifactDirectory)/\(Self.entryPoint)",
            "buildCommand": Self.buildCommand,
        ])
        showError(message)
    }

    private func showError(_ message: String) {
        nativeBridge?.failPickedSelections(NSError(domain: "CodiPadScene", code: 4,
                                                   userInfo: [NSLocalizedDescriptionKey: message]))
        suspendOpenButton()
        errorView.text = message
        errorView.isHidden = false
        view.bringSubviewToFront(errorView)
        reloadButton.isHidden = !rendererRecoveryNeeded
        view.bringSubviewToFront(reloadButton)
    }

    // MARK: - Logging

    /// Accepts a bridge event only when the sending frame's document is inside the artifact root.
    private func accept(bridgeEvent event: [String: Any], from frame: WKFrameInfo) {
        guard frame.isMainFrame else {
            log(event: ["event": "workbench.bridgeRejected", "reason": "nonMainFrame"])
            return
        }
        // Main-frame document URL: the frame's own request, else the committed top-level URL.
        let source = frame.request.url ?? webView?.url
        guard let source, isWorkbenchEntryPoint(source) else {
            log(event: [
                "event": "workbench.bridgeRejected",
                "reason": "sourceNotInArtifact",
                "url": source?.absoluteString ?? "unavailable",
            ])
            return
        }

        if event["event"] as? String == "native.workbenchBackground",
           incomingDocumentHasCommittedPage, let page = incomingDocumentPage,
           event["pageId"] as? String == page,
           let color = Self.workbenchBackground(event["background"] as? String) {
            view.backgroundColor = color
            webView?.backgroundColor = color
            webView?.scrollView.backgroundColor = color
            let titleBackground = Self.workbenchBackground(event["titleBackground"] as? String) ?? color
            topSafeAreaFill.backgroundColor = titleBackground
            bottomSafeAreaFill.backgroundColor = Self.workbenchBackground(event["statusBackground"] as? String) ?? color
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            var baseRed: CGFloat = 0, baseGreen: CGFloat = 0, baseBlue: CGFloat = 0, baseAlpha: CGFloat = 0
            if titleBackground.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
               color.getRed(&baseRed, green: &baseGreen, blue: &baseBlue, alpha: &baseAlpha) {
                let brightness = (red * 0.299 + green * 0.587 + blue * 0.114) * alpha +
                    (baseRed * 0.299 + baseGreen * 0.587 + baseBlue * 0.114) * (1 - alpha)
                themeStatusBarStyle = brightness > 0.5 ? .darkContent : .lightContent
                setNeedsStatusBarAppearanceUpdate()
            }
            terminalKeyboard.backgroundColor = Self.workbenchBackground(event["terminalBackground"] as? String) ?? color
            if let foreground = Self.workbenchBackground(event["terminalForeground"] as? String) {
                terminalKeyboard.tintColor = foreground
            }
        }
        if event["event"] as? String == "native.terminalKeyboard",
           !nativeOpenSuspended, incomingDocumentHasCommittedPage,
           let page = incomingDocumentPage, event["pageId"] as? String == page,
           let receiver = event["receiverId"] as? String, UUID(uuidString: receiver) != nil,
           let focus = event["focusId"] as? String, UUID(uuidString: focus) != nil,
           let ready = event["ready"] as? Bool, let ctrl = event["ctrl"] as? Bool,
           let alt = event["alt"] as? Bool {
            if terminalKeyboardTarget?.focus != focus || !ready { terminalKeyboard.cancel() }
            terminalKeyboardTarget = ready ? (page, receiver, focus) : nil
            updateTerminalKeyboardVisibility()
            terminalKeyboard.update(ctrl: ctrl, alt: alt)
        }
        if event["event"] as? String == "native.workbenchMenu" {
            receiveNativeMenu(event)
            return // Menu labels can contain user data; never write them to diagnostics.
        }
        if event["event"] as? String == "native.workbenchActions",
           !nativeOpenSuspended, incomingDocumentHasCommittedPage,
           let page = incomingDocumentPage, event["pageId"] as? String == page,
           let receiver = event["receiverId"] as? String, !receiver.isEmpty,
           let ready = event["ready"] as? Bool, let busy = event["busy"] as? Bool {
            if nativeOpenReceiver == nil || nativeOpenReceiver == receiver {
                nativeOpenReceiver = ready ? receiver : nil
                nativeOpenBusy = busy
                updateOpenButton()
            }
        }
        log(event: event, frameInfo: frame)
    }

    private func receiveNativeMenu(_ event: [String: Any]) {
        guard !nativeOpenSuspended, incomingDocumentHasCommittedPage,
              let page = incomingDocumentPage, event["pageId"] as? String == page,
              let receiver = event["receiverId"] as? String, UUID(uuidString: receiver) != nil,
              let revision = event["revision"] as? String else { return }
        if let current = nativeMenu, current.receiver != receiver { return }
        if revision.isEmpty { nativeMenu = nil; UIMenuSystem.main.setNeedsRebuild(); return }
        guard UUID(uuidString: revision) != nil, let value = event["menus"],
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value), data.count <= 1_048_576,
              let nodes = try? JSONDecoder().decode([NativeMenuNode].self, from: data) else { return }
        var count = 0
        func valid(_ node: NativeMenuNode, depth: Int) -> Bool {
            count += 1
            guard count <= 2048, depth <= 12 else { return false }
            if node.separator == true { return node.title == nil && node.token == nil && node.children == nil }
            guard let title = node.title, !title.isEmpty, title.utf8.count <= 2048 else { return false }
            if let children = node.children {
                return node.token == nil && children.allSatisfy { valid($0, depth: depth + 1) }
            }
            if let token = node.token { return UUID(uuidString: token) != nil }
            return node.enabled == false
        }
        guard nodes.allSatisfy({ valid($0, depth: 0) }) else { return }
        nativeMenu = NativeMenuSnapshot(page: page, receiver: receiver, revision: revision, nodes: nodes)
        UIMenuSystem.main.setNeedsRebuild()
    }

    func populateMainMenu(_ builder: any UIMenuBuilder) {
        guard builder.system == UIMenuSystem.main, viewIfLoaded?.window?.isKeyWindow == true,
              (UIApplication.shared.delegate as? AppDelegate)?.ownsMainMenu(viewIfLoaded?.window) == true,
              let snapshot = nativeMenu, incomingDocumentHasCommittedPage, incomingDocumentPage == snapshot.page else { return }
        func elements(_ nodes: [NativeMenuNode], enabled: Bool = true) -> [UIMenuElement] {
            var result: [UIMenuElement] = [], group: [UIMenuElement] = []
            func flush() {
                guard !group.isEmpty else { return }
                result.append(UIMenu(title: "", options: .displayInline, children: group))
                group.removeAll()
            }
            for node in nodes {
                if node.separator == true { flush(); continue }
                guard let title = node.title else { continue }
                if let children = node.children {
                    group.append(UIMenu(title: title, options: [], children: elements(children, enabled: enabled && node.enabled != false)))
                } else {
                    let token = node.token
                    let action = UIAction(title: title, attributes: enabled && node.enabled == true && token != nil ? [] : .disabled,
                                          state: node.checked == true ? .on : .off) { [weak self] _ in
                        guard let self, let token else { return }
                        self.runNativeMenuAction(snapshot, token: token)
                    }
                    group.append(action)
                }
            }
            flush()
            return result
        }
        for node in snapshot.nodes {
            guard let id = node.id, let title = node.title, let children = node.children else { continue }
            let mapped = elements(children, enabled: node.enabled != false)
            switch id {
            case "MenubarFileMenu": builder.replaceChildren(ofMenu: .file) { _ in mapped }
            case "MenubarViewMenu": builder.replaceChildren(ofMenu: .view) { _ in mapped }
            case "MenubarHelpMenu": builder.replaceChildren(ofMenu: .help) { _ in mapped }
            case "MenubarEditMenu":
                builder.replaceChildren(ofMenu: .edit) { current in current + [UIMenu(title: title + " (VS Code)", children: mapped)] }
            default:
                builder.insertSibling(UIMenu(title: title, identifier: UIMenu.Identifier("dev.codipad." + id), children: mapped), beforeMenu: .help)
            }
        }
    }

    private func runNativeMenuAction(_ snapshot: NativeMenuSnapshot, token: String) {
        guard viewIfLoaded?.window?.isKeyWindow == true, let webView,
              (UIApplication.shared.delegate as? AppDelegate)?.ownsMainMenu(viewIfLoaded?.window) == true,
              incomingDocumentHasCommittedPage, incomingDocumentPage == snapshot.page,
              nativeMenu?.receiver == snapshot.receiver, nativeMenu?.revision == snapshot.revision,
              let url = webView.url, isWorkbenchEntryPoint(url) else { return }
        webView.callAsyncJavaScript("""
            const menu = globalThis.__codipadNativeWorkbenchMenu;
            if (globalThis.__codipadIncomingDocumentPage !== page || menu?.receiverId !== receiver) return false;
            await menu.run(page, receiver, revision, token);
            return true;
            """, arguments: ["page": snapshot.page, "receiver": snapshot.receiver,
                              "revision": snapshot.revision, "token": token], in: nil, in: .page) { [weak self] result in
            if case .failure = result { self?.reportIncomingDocumentError("This menu action is no longer available. Try opening the menu again.") }
        }
    }

    private static func workbenchBackground(_ value: String?) -> UIColor? {
        guard let value, value.utf8.count == 9, value.first == "#",
              value.dropFirst().utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let rgba = UInt32(value.dropFirst(), radix: 16) else { return nil }
        return UIColor(red: CGFloat((rgba >> 24) & 0xff) / 255,
                       green: CGFloat((rgba >> 16) & 0xff) / 255,
                       blue: CGFloat((rgba >> 8) & 0xff) / 255,
                       alpha: CGFloat(rgba & 0xff) / 255)
    }

    private func log(event: [String: Any], frameInfo: WKFrameInfo? = nil) {
        var fields = event
        if let frameInfo {
            fields["mainFrame"] = frameInfo.isMainFrame
        }
        let now = ProcessInfo.processInfo.systemUptime
        fields["uptimeSeconds"] = Int(now)
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return }
        print("codipad-workbench=" + text)
        #if DEBUG
        if (fields["event"] as? String)?.hasPrefix("native.") == true
            || (fields["startupTimeline"] != nil && ["workbench.load", "workbench.loaded"].contains(fields["event"] as? String ?? ""))
            || fields["event"] as? String == "workbench.consoleError"
            || fields["event"] as? String == "workbench.contentProcessTerminated" {
            DebugWorkbenchLog.append(data, eventName: fields["event"] as? String)
        }
        #endif
    }

}

#if DEBUG
/// Retains bridge metadata and workbench errors when XCTest cannot attach app stdout.
/// Bounded, asynchronous, cache-only, DEBUG-only, and reset each app process.
enum DebugWorkbenchLog {
    private static let queue = DispatchQueue(label: "dev.codipad.debug-events")
    private static var handle: FileHandle?
    private static var bytes = 0
    private static var initialized = false
    private static var spawnFailureCount = 0
    private static var filesystemSuccessCount = 0
    private struct FilesystemErrorKey: Hashable {
        let method: String
        let code: String
    }
    private struct FilesystemErrorSummary {
        var suppressed = 0
        var firstUptime: Int
        var lastUptime: Int
    }
    private static var filesystemErrors: [FilesystemErrorKey: FilesystemErrorSummary] = [:]
    private static var filesystemErrorTimer: DispatchSourceTimer?
    private static var url: URL?
    private static let limit = 2 * 1024 * 1024

    // Install once before any extension host starts. The callback has no object context to
    // outlive, and uses the same bounded journal when app stderr is not attached to Xcode.
    static let spawnDiagnostics: Void = {
        let result = codipad_node_set_spawn_diagnostic_callback({ stage, error, backend, _ in
            queue.async {
                guard spawnFailureCount < 64 else { return }
                spawnFailureCount += 1
                let event: [String: Any] = [
                    "event": "native.nodeSpawnFailed", "stage": Int(stage),
                    "error": Int(error), "backend": Int(backend),
                    "uptimeSeconds": Int(ProcessInfo.processInfo.systemUptime),
                ]
                if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) {
                    append(data)
                }
            }
        }, nil)
        if result != 0,
           let data = try? JSONSerialization.data(withJSONObject: [
               "event": "native.nodeSpawnDiagnosticsUnavailable", "error": Int(result)
           ]) {
            append(data)
        }
    }()

    static func append(_ event: Data, eventName: String? = nil) {
        queue.async {
            if eventName == "native.fsSuccess" {
                filesystemSuccessCount += 1
                if filesystemSuccessCount > 64 && filesystemSuccessCount % 1024 != 0 { return }
            }
            if eventName == "native.fsError" {
                recordFilesystemError(event)
                return
            }
            write(event, eventName: eventName)
        }
    }

    // Bound cardinality and retain only small identifier fields, never paths or messages.
    private static func identifier(_ value: Any?) -> String {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 95 }) else { return "other" }
        return value
    }

    private static func recordFilesystemError(_ event: Data) {
        let fields = (try? JSONSerialization.jsonObject(with: event)) as? [String: Any] ?? [:]
        var key = FilesystemErrorKey(method: identifier(fields["method"]), code: identifier(fields["code"]))
        if filesystemErrors[key] == nil && filesystemErrors.count >= 63 {
            key = FilesystemErrorKey(method: "other", code: "other")
        }
        let now = Int(ProcessInfo.processInfo.systemUptime)
        if var summary = filesystemErrors[key] {
            if summary.suppressed == 0 { summary.firstUptime = now }
            summary.suppressed += 1
            summary.lastUptime = now
            filesystemErrors[key] = summary
            if summary.suppressed >= 256 { flushFilesystemErrors() }
        } else {
            filesystemErrors[key] = FilesystemErrorSummary(firstUptime: now, lastUptime: now)
            if let data = try? JSONSerialization.data(withJSONObject: ["event": "native.fsError", "method": key.method, "code": key.code, "uptimeSeconds": now], options: [.sortedKeys]) {
                write(data, eventName: "native.fsError")
            }
        }
        if filesystemErrorTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { flushFilesystemErrors() }
            filesystemErrorTimer = timer
            timer.resume()
        }
    }

    private static func flushFilesystemErrors() {
        for key in Array(filesystemErrors.keys) {
            guard var summary = filesystemErrors[key], summary.suppressed > 0 else { continue }
            let fields: [String: Any] = ["event": "native.fsErrorSummary", "method": key.method, "code": key.code,
                "suppressedCount": summary.suppressed, "firstUptimeSeconds": summary.firstUptime, "uptimeSeconds": summary.lastUptime]
            if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
                write(data, eventName: "native.fsErrorSummary")
                summary.suppressed = 0
                filesystemErrors[key] = summary
            }
        }
    }

    private static func write(_ event: Data, eventName: String?) {
            if !initialized {
                initialized = true
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                let destination = directory.appendingPathComponent("codipad-workbench-events.jsonl")
                url = destination
                try? Data().write(to: destination, options: .atomic)
                handle = try? FileHandle(forWritingTo: destination)
            }
            var line = event
            line.append(0x0a)
            if line.count > limit / 2 {
                guard var summary = try? JSONSerialization.data(withJSONObject: [
                    "event": "native.journalOversized", "originalEvent": eventName ?? "unknown",
                    "originalBytes": line.count,
                ], options: [.sortedKeys]) else { return }
                summary.append(0x0a)
                line = summary
            }
            if bytes + line.count > limit {
                // Preserve the newest complete records and leave an explicit marker
                // for evidence readers that require a complete process history.
                guard let url, let handle, let old = try? Data(contentsOf: url) else { return }
                let start = max(0, old.count - limit / 2)
                let boundary = old[start...].firstIndex(of: 0x0a).map { $0 + 1 } ?? old.count
                let marker: [String: Any] = [
                    "event": "native.journalTruncated", "limitBytes": limit,
                    "uptimeSeconds": Int(ProcessInfo.processInfo.systemUptime),
                ]
                guard var prefix = try? JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]) else { return }
                prefix.append(0x0a)
                prefix.append(old[boundary...])
                do {
                    try handle.truncate(atOffset: 0)
                    try handle.seek(toOffset: 0)
                    try handle.write(contentsOf: prefix)
                    bytes = prefix.count
                } catch { return }
            }
            try? handle?.write(contentsOf: line)
            bytes += line.count
    }
}
#endif

// MARK: - Navigation

extension WorkbenchViewController: WKUIDelegate {
    private func isTrustedMicrophoneRequest(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo) -> Bool {
        guard self.webView === webView, incomingDocumentHasCommittedPage, !sceneDisconnected,
              frame.isMainFrame, let frameURL = frame.request.url, isWorkbenchEntryPoint(frameURL),
              let currentURL = webView.url, isWorkbenchEntryPoint(currentURL),
              let entryURL = artifactServer?.entryURL, let port = entryURL.port else { return false }
        return origin.protocol == entryURL.scheme && origin.host == entryURL.host && origin.port == port
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard type == .microphone, isTrustedMicrophoneRequest(webView, origin: origin, frame: frame) else {
            decisionHandler(.prompt)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            decisionHandler(.grant)
        case .notDetermined:
            guard let page = incomingDocumentPage else { decisionHandler(.deny); return }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self, weak webView] granted in
                DispatchQueue.main.async {
                    guard let self, let webView, granted,
                          self.incomingDocumentPage == page,
                          self.isTrustedMicrophoneRequest(webView, origin: origin, frame: frame) else {
                        decisionHandler(.deny)
                        return
                    }
                    decisionHandler(.grant)
                }
            }
        default:
            decisionHandler(.deny)
        }
    }
}

extension WorkbenchViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            log(event: ["event": "workbench.navigationBlocked", "reason": "noURL"])
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == false {
            let source = navigationAction.sourceFrame
            let sourceURL = source.request.url ?? (source.isMainFrame ? webView.url : nil)
            let trustedWorkbench = source.isMainFrame && sourceURL.map(isWorkbenchEntryPoint) == true
            // Appending a new iframe first navigates its empty document before the shell URL.
            if trustedWorkbench && url.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            if trustedWorkbench && artifactServer?.isExtensionWorkerFrame(url) == true {
                log(event: ["event": "native.extensionWorkerNavigation", "allowed": true])
                decisionHandler(.allow)
                return
            }
            var origin = URLComponents()
            origin.scheme = source.securityOrigin.protocol
            origin.host = source.securityOrigin.host
            if source.securityOrigin.port > 0 { origin.port = source.securityOrigin.port }
            guard let nativeBridge else {
                decisionHandler(.cancel)
                return
            }
            nativeBridge.allowsWebviewNavigation(to: url, from: sourceURL, sourceOrigin: origin.url, trustedWorkbench: trustedWorkbench) { [weak self] allowed in
                self?.log(event: ["event": "native.webviewNavigation", "allowed": allowed])
                decisionHandler(allowed ? .allow : .cancel)
            }
            return
        }
        // A top-level navigation or new window remains confined to the artifact entry point.
        guard isWorkbenchEntryPoint(url) || storageMigration?.allowsNavigation(to: url) == true else {
            log(event: [
                "event": "workbench.navigationBlocked",
                "reason": "notArtifactEntryPoint",
                "url": url.absoluteString,
            ])
            decisionHandler(.cancel)
            return
        }
        // A page reload creates a new extension-host protocol owner. Stop the old
        // host and wait for settlement before the new document can start another.
        if incomingDocumentHasCommittedPage, isWorkbenchEntryPoint(url),
           storageMigration == nil, !rendererRecoveryInFlight {
            prepareCommittedWorkbenchNavigation(webView, decisionHandler: decisionHandler)
            return
        }
        decisionHandler(.allow)
    }

    private func prepareCommittedWorkbenchNavigation(
        _ webView: WKWebView,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard !committedReloadInFlight, let nativeBridge,
              let page = incomingDocumentPage, self.webView === webView else {
            decisionHandler(.cancel)
            return
        }
        committedReloadInFlight = true
        nativeBridge.setExtensionHostStartsSuspended(true)
        nativeBridge.prepareForRendererReload { [weak self, weak webView, weak nativeBridge] result in
            guard let self else { nativeBridge?.setExtensionHostStartsSuspended(false); decisionHandler(.cancel); return }
            self.committedReloadInFlight = false
            guard let webView, self.webView === webView, let nativeBridge,
                  self.nativeBridge === nativeBridge, self.incomingDocumentHasCommittedPage,
                  self.incomingDocumentPage == page, !self.rendererRecoveryNeeded else {
                nativeBridge?.setExtensionHostStartsSuspended(false)
                decisionHandler(.cancel)
                return
            }
            switch result {
            case .success:
                decisionHandler(.allow)
            case .failure:
                nativeBridge.setExtensionHostStartsSuspended(false)
                self.showError("Background services have not finished closing, so the workbench could not reload. Your remaining terminal sessions are preserved. Try reloading again.")
                decisionHandler(.cancel)
            }
        }
    }

    /// Canonical confinement: any file inside the artifact root, plus exactly `about:blank`.
    static func isAllowed(url: URL, root: URL?) -> Bool {
        guard let root else { return false }
        if url.absoluteString == "about:blank" { return true }
        guard url.isFileURL, url.query == nil, url.fragment == nil else { return false }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        return candidate == rootPath || candidate.hasPrefix(rootPath + "/")
    }

    /// A top-level navigation is limited to `Workbench/index.html` (or the empty document).
    static func isEntryPoint(url: URL, root: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        guard isAllowed(url: url, root: root) else { return false }
        let index = root.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(entryPoint, isDirectory: false)
            .path
        return url.resolvingSymlinksInPath().standardizedFileURL.path == index
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        suspendOpenButton()
        // The committed document can still consume output and send ACKs until replacement commits.
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        clearViewportHandoff()
        suspendOpenButton()
        viewportUpdate = nil
        reportedViewportSize = nil
        viewportRetryUsed = false
        incomingDocumentPage = nil
        nativeBridge?.suspendIncomingDocumentPage()
        nativeBridge?.setExtensionHostStartsSuspended(false)
        incomingDocumentHasCommittedPage = false
        guard let url = webView.url, isWorkbenchEntryPoint(url) else { return }
        incomingDocumentHasCommittedPage = true
        nativeOpenSuspended = false
        incomingDocumentPage = nativeBridge?.activateIncomingDocumentPage()
        publishIncomingDocumentPage()
        publishSceneFocus()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if storageMigration?.didFinish(navigation, url: webView.url) == true { return }
        guard incomingDocumentHasCommittedPage, let url = webView.url, isWorkbenchEntryPoint(url) else { return }
        publishIncomingDocumentPage(finalAttempt: true)
        publishSceneFocus()
        rendererRecoveryNeeded = false
        rendererRecoveryInFlight = false
        reloadButton.isHidden = true
        reloadButton.isEnabled = true
        errorView.isHidden = true
        workbenchLoaded = true
        updateOpenButton()
        reportedViewportSize = nil
        updateWorkbenchViewport()
        log(event: ["event": "workbench.loaded", "url": webView.url?.lastPathComponent ?? ""])
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        if storageMigration?.didFail(navigation, error: error) == true { return }
        nativeBridge?.setExtensionHostStartsSuspended(false)
        if incomingDocumentHasCommittedPage, let url = webView.url, isWorkbenchEntryPoint(url) {
            publishIncomingDocumentPage(finalAttempt: true)
        }
        reportLoadFailure(error, stage: "provisional")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if storageMigration?.didFail(navigation, error: error) == true { return }
        nativeBridge?.setExtensionHostStartsSuspended(false)
        reportLoadFailure(error, stage: "navigation")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        suspendOpenButton()
        workbenchLoaded = false
        incomingDocumentHasCommittedPage = false
        incomingDocumentPage = nil
        rendererRecoveryGeneration = UUID()
        rendererRecoveryNeeded = true
        rendererRecoveryInFlight = false
        reloadButton.isEnabled = true
        nativeBridge?.rendererDidTerminate()
        log(event: ["event": "workbench.contentProcessTerminated"])
        showError("The workbench stopped. Reload Workbench to reopen it and reconnect to saved terminal sessions. Unsaved editor changes may be lost.")
    }

    @objc private func reloadWorkbench() {
        guard rendererRecoveryNeeded, !rendererRecoveryInFlight,
              let webView, let nativeBridge, let entry = artifactServer?.entryURL(agents: windowKind == .agents),
              isWorkbenchEntryPoint(entry), storageMigration == nil else { return }
        let generation = rendererRecoveryGeneration
        rendererRecoveryInFlight = true
        reloadButton.isEnabled = false
        showError("Preparing the workbench to reload…")
        nativeBridge.prepareForRendererReload { [weak self, weak webView] result in
            guard let self, let webView, self.webView === webView,
                  self.rendererRecoveryGeneration == generation else { return }
            switch result {
            case .success:
                self.loadWorkbenchEntry(entry, into: webView)
            case .failure:
                self.rendererRecoveryInFlight = false
                self.reloadButton.isEnabled = true
                self.showError("Background services have not finished closing, so the workbench could not reload. Your remaining terminal sessions are preserved. Try Reload Workbench again.")
            }
        }
    }

    private func reportLoadFailure(_ error: Error, stage: String) {
        if rendererRecoveryNeeded {
            rendererRecoveryInFlight = false
            reloadButton.isEnabled = true
        }
        let nsError = error as NSError
        log(event: [
            "event": "workbench.loadFailed",
            "stage": stage,
            "domain": nsError.domain,
            "code": nsError.code,
            "message": nsError.localizedDescription,
        ])
        showError("""
        The workbench failed to load (\(stage)).

        \(nsError.domain) \(nsError.code): \(nsError.localizedDescription)

        If this build was produced without the workbench artifact, rebuild with:
          \(Self.buildCommand)
        """)
    }
}

// MARK: - Bridge

/// Receives structured `codipad` messages from the workbench page and forwards them to the
/// native log. Only the main frame is accepted; subframes and non-object payloads are rejected.
final class WorkbenchBridge: NSObject, WKScriptMessageHandler {
    static let name = "codipad"
    var onEvent: (([String: Any], WKFrameInfo) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.frameInfo.isMainFrame else {
            onEvent?(["event": "workbench.bridgeRejected", "reason": "nonMainFrame"], message.frameInfo)
            return
        }
        guard let payload = message.body as? [String: Any], !payload.isEmpty else {
            onEvent?(["event": "workbench.bridgeRejected", "reason": "nonObjectPayload"], message.frameInfo)
            return
        }
        var event = payload
        if event["event"] == nil { event["event"] = "workbench.bridgeEvent" }
        onEvent?(event, message.frameInfo)
    }
}
