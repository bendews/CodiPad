import UIKit
import CodiPadWorkspace

/// Observe the receiving scene without changing how UIKit or WebKit delivers its input.
private final class WorkbenchWindow: UIWindow {
    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches,
           event.allTouches?.contains(where: { $0.window === self && $0.phase == .began }) == true {
            (UIApplication.shared.delegate as? AppDelegate)?.noteWindowInteraction(self)
        }
        super.sendEvent(event)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let workspaceAccess = WorkspaceAccess()
    private var activationRequestID: String?
    private var pendingSelection: NativeSceneSelection?
    private var pendingIncomingURLs: [URL] = []
    private(set) var windowKind: NativeWindowKind?
    private static let legacyRemoteOwnerKey = "dev.codipad.legacyRemoteOwnerScene"
    private static weak var embeddedHostOwner: SceneDelegate?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = WorkbenchWindow(windowScene: windowScene)
        guard let requestedKind = NativeSceneActivation.kind(connectionOptions.userActivities, restoring: session.stateRestorationActivity) else {
            showUnavailable("This window type is not supported by this build.", in: window)
            return
        }
        windowKind = requestedKind
        let receiptIdentifiers = BuildReceipt.identifiers()
        if let data = try? JSONSerialization.data(withJSONObject: receiptIdentifiers, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8), !receiptIdentifiers.isEmpty {
            print("codipad-bootstrap receipt-identifiers=" + text)
        } else {
            print("codipad-bootstrap receipt-identifiers=unavailable")
        }
        if !NativeRuntimeConfiguration.current.usesLinuxExtensionHost {
            guard Self.embeddedHostOwner == nil || Self.embeddedHostOwner === self else {
                showUnavailable("This window is unavailable. The embedded extension host supports one window.", in: window)
                return
            }
            Self.embeddedHostOwner = self
        }
        activationRequestID = NativeSceneActivation.requestID(connectionOptions.userActivities)
        pendingSelection = NativeSceneActivation.takeSelection(requestID: activationRequestID)
        pendingIncomingURLs = connectionOptions.urlContexts.map(\.url)
        self.window = window
        NotificationCenter.default.addObserver(self, selector: #selector(runtimeStateChanged),
                                               name: NativeRuntimeStartup.didChange, object: nil)
        if NativeRuntimeStartup.isReady {
            showWorkbench(in: window, session: session, kind: requestedKind)
        } else {
            window.rootViewController = NativeRuntimeStartupViewController()
            window.makeKeyAndVisible()
            runtimeStateChanged()
        }
    }

    @objc private func runtimeStateChanged() {
        if case .failed(let reason) = NativeRuntimeStartup.status {
            pendingSelection?.complete(.failure(NSError(domain: "CodiPadScene", code: 4, userInfo: [NSLocalizedDescriptionKey: reason])))
            pendingSelection = nil
            return
        }
        guard NativeRuntimeStartup.isReady, let window, let scene = window.windowScene,
              window.rootViewController is NativeRuntimeStartupViewController, let windowKind else { return }
        showWorkbench(in: window, session: scene.session, kind: windowKind)
        if scene.activationState == .foregroundActive { sceneDidBecomeActive(scene) }
    }

    private func showWorkbench(in window: UIWindow, session: UISceneSession, kind: NativeWindowKind) {
        let sceneID = UIApplication.shared.supportsMultipleScenes ? session.persistentIdentifier : nil
        if kind == .editor, let sceneID, UserDefaults.standard.string(forKey: Self.legacyRemoteOwnerKey) == nil {
            UserDefaults.standard.set(sceneID, forKey: Self.legacyRemoteOwnerKey)
        }
        let migrateLegacyRemote = kind == .editor && (sceneID == nil || UserDefaults.standard.string(forKey: Self.legacyRemoteOwnerKey) == sceneID)
        let workbench = WorkbenchViewController(access: workspaceAccess, sceneID: sceneID, migrateLegacyRemote: migrateLegacyRemote, windowKind: kind)
        window.rootViewController = workbench
        window.makeKeyAndVisible()
        if let selection = pendingSelection {
            pendingSelection = nil
            workbench.openPickedSelection(selection)
        }
        let incoming = pendingIncomingURLs
        pendingIncomingURLs.removeAll()
        for url in incoming { workbench.openIncomingURL(url) }
    }

    @available(iOS 26.0, *)
    func windowScene(_ windowScene: UIWindowScene, didUpdateEffectiveGeometry previous: UIWindowScene.Geometry) {
        guard previous.isInteractivelyResizing != windowScene.effectiveGeometry.isInteractivelyResizing,
              let workbench = window?.rootViewController as? WorkbenchViewController,
              let view = workbench.viewIfLoaded else { return }
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        NativeSceneActivation.didBecomeActive(requestID: activationRequestID, sessionID: scene.session.persistentIdentifier,
                                              kind: window?.rootViewController is WorkbenchViewController ? windowKind : nil)
        if window?.rootViewController is WorkbenchViewController { activationRequestID = nil }
        (UIApplication.shared.delegate as? AppDelegate)?.sceneWindowDidBecomeActive(window)
    }

    private func showUnavailable(_ message: String, in window: UIWindow) {
        let unavailable = UIViewController()
        let label = UILabel()
        label.text = message
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        unavailable.view.backgroundColor = .systemBackground
        unavailable.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: unavailable.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: unavailable.view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: unavailable.view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: unavailable.view.safeAreaLayoutGuide.trailingAnchor, constant: -24)
        ])
        window.rootViewController = unavailable
        window.makeKeyAndVisible()
        self.window = window
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        windowKind.map { NativeSceneActivation.restorationActivity(kind: $0) }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        pendingSelection?.complete(.failure(CocoaError(.userCancelled)))
        pendingSelection = nil
        NativeSceneActivation.didLoseFocus(sessionID: scene.session.persistentIdentifier)
        (UIApplication.shared.delegate as? AppDelegate)?.sceneWindowDidDisconnect(window)
        (window?.rootViewController as? WorkbenchViewController)?.disconnectScene()
        if Self.embeddedHostOwner === self { Self.embeddedHostOwner = nil }
        window?.rootViewController = nil
        window = nil
    }

    func sceneWillResignActive(_ scene: UIScene) {
        NativeSceneActivation.didLoseFocus(sessionID: scene.session.persistentIdentifier)
        (UIApplication.shared.delegate as? AppDelegate)?.sceneWindowWillResignActive(window)
        (window?.rootViewController as? WorkbenchViewController)?.cancelTerminalKeys()
        (window?.rootViewController as? WorkbenchViewController)?.checkpointTerminals()
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let workbench = window?.rootViewController as? WorkbenchViewController else {
            pendingIncomingURLs.append(contentsOf: URLContexts.map(\.url))
            return
        }
        for context in URLContexts {
            workbench.openIncomingURL(context.url)
        }
    }
}
