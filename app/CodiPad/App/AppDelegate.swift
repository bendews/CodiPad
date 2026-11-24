import UIKit
import CodiPadWorkspace

enum NativeWindowKind: String {
    case editor
    case agents

    static func sceneRequest(_ params: [String: Any]) -> NativeWindowKind? {
        if params.isEmpty { return .editor }
        if Set(params.keys) == ["kind"], params["kind"] as? String == agents.rawValue { return .agents }
        return nil
    }
}

struct NativeSceneSelection {
    let url: URL
    let complete: (Result<Void, Error>) -> Void
}

/// Correlates UIKit's error-only activation API with the scene that actually becomes active.
@MainActor
enum NativeSceneActivation {
    private static let activityType = "dev.codipad.new-window"
    private static var pending: [String: (Result<Void, Error>) -> Void] = [:]
    private static var pickedURLs: [String: URL] = [:]
    private static var openingSelections: Set<String> = []
    private static var editorTargets: [String: String] = [:]
    private static var editorCreationRequests: Set<String> = []
    private static var editorCreationWaiters: [(Result<Void, Error>) -> Void] = []
    private static var focusedEditorID: String?
    private static let lastEditorKey = "dev.codipad.lastEditorScene"

    static func open(kind: NativeWindowKind = .editor, pickedURL: URL? = nil, awaitEditorFocus: Bool = false, completion: @escaping (Result<Void, Error>) -> Void) {
        guard NativeRuntimeConfiguration.current.usesLinuxExtensionHost else {
            completion(.failure(NSError(domain: "CodiPadScene", code: 3, userInfo: [NSLocalizedDescriptionKey: "Multiple windows require the Linux extension host; the embedded host supports one window."])))
            return
        }
        guard UIApplication.shared.supportsMultipleScenes else {
            completion(.failure(NSError(domain: "CodiPadScene", code: 1, userInfo: [NSLocalizedDescriptionKey: "Multiple windows are not available on this device."])))
            return
        }
        let id = UUID().uuidString
        pending[id] = completion
        pickedURLs[id] = pickedURL
        if awaitEditorFocus { editorCreationRequests.insert(id) }
        let activity = NSUserActivity(activityType: activityType)
        activity.userInfo = ["requestId": id, "kind": kind.rawValue]
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: activity, options: nil) { error in
            DispatchQueue.main.async { finish(id, result: .failure(error)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            guard !openingSelections.contains(id) else { return }
            finish(id, result: .failure(NSError(domain: "CodiPadScene", code: 2, userInfo: [NSLocalizedDescriptionKey: "The new window did not become active in time. It may still open; check before retrying."])))
        }
    }

    /// Bring the last editor forward without replacing its workspace or scene.
    static func showEditor(completion: @escaping (Result<Void, Error>) -> Void) {
        let app = UIApplication.shared
        let connected = app.connectedScenes.compactMap { $0 as? UIWindowScene }
        let editors = connected.filter {
            guard let delegate = $0.delegate as? SceneDelegate else { return false }
            return delegate.windowKind == .editor && delegate.window?.rootViewController is WorkbenchViewController
        }
        let lastID = UserDefaults.standard.string(forKey: lastEditorKey)
        let lastConnected = editors.first(where: { $0.session.persistentIdentifier == lastID })
        let saved: UISceneSession? = lastID.flatMap { id in
            guard !connected.contains(where: { $0.session.persistentIdentifier == id }),
                  let session = app.openSessions.first(where: { $0.persistentIdentifier == id }) else { return nil }
            if let activity = session.stateRestorationActivity {
                guard activity.activityType == activityType,
                      activity.userInfo?["kind"] as? String == NativeWindowKind.editor.rawValue else { return nil }
            }
            return session
        }
        let restored: UISceneSession? = app.openSessions.first { session in
            guard !connected.contains(where: { $0.session.persistentIdentifier == session.persistentIdentifier }),
                  let activity = session.stateRestorationActivity,
                  activity.activityType == activityType,
                  activity.userInfo?["kind"] as? String == NativeWindowKind.editor.rawValue else { return false }
            return true
        }
        let preferred: UISceneSession? = lastConnected?.session ?? saved ?? editors.first?.session ?? restored
        guard let session = preferred else {
            editorCreationWaiters.append(completion)
            guard editorCreationWaiters.count == 1 else { return }
            open(kind: .editor, awaitEditorFocus: true) { result in
                let waiters = editorCreationWaiters
                editorCreationWaiters.removeAll()
                waiters.forEach { $0(result) }
            }
            return
        }
        if focusedEditorID == session.persistentIdentifier && editors.contains(where: {
            $0.session == session && $0.activationState == .foregroundActive && $0.windows.contains(where: { $0.isKeyWindow })
        }) {
            completion(.success(()))
            return
        }
        let id = UUID().uuidString
        pending[id] = completion
        editorTargets[id] = session.persistentIdentifier
        app.requestSceneSessionActivation(session, userActivity: nil, options: nil) { error in
            DispatchQueue.main.async { finish(id, result: .failure(error)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            finish(id, result: .failure(NSError(domain: "CodiPadScene", code: 2, userInfo: [NSLocalizedDescriptionKey: "The editor window did not become active in time. Check the window overview before retrying."])))
        }
    }

    // Only the public Files picker's delegate supplies these URLs. Activities carry a nonce.
    static func takeSelection(requestID: String?) -> NativeSceneSelection? {
        guard let id = requestID, let url = pickedURLs.removeValue(forKey: id) else { return nil }
        openingSelections.insert(id)
        return NativeSceneSelection(url: url) { result in finish(id, result: result) }
    }

    static func requestID(_ activities: Set<NSUserActivity>) -> String? {
        activities.first(where: { $0.activityType == activityType })?.userInfo?["requestId"] as? String
    }

    static func kind(_ activities: Set<NSUserActivity>, restoring activity: NSUserActivity?) -> NativeWindowKind? {
        let candidate = activities.first(where: { $0.activityType == activityType }) ?? activity
        guard candidate?.activityType == activityType, let value = candidate?.userInfo?["kind"] else { return .editor }
        guard let name = value as? String else { return nil }
        return NativeWindowKind(rawValue: name)
    }

    static func restorationActivity(kind: NativeWindowKind) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        activity.userInfo = ["kind": kind.rawValue]
        return activity
    }

    static func didBecomeActive(requestID: String?, sessionID: String? = nil, kind: NativeWindowKind? = nil) {
        guard let requestID, pickedURLs[requestID] == nil, !openingSelections.contains(requestID) else { return }
        if editorCreationRequests.contains(requestID) {
            guard let sessionID, kind == .editor else { return }
            editorTargets[requestID] = sessionID
            if focusedEditorID == sessionID { finish(requestID, result: .success(())) }
        } else {
            finish(requestID, result: .success(()))
        }
    }

    static func didFocus(sessionID: String, kind: NativeWindowKind?, isActive: Bool) {
        guard isActive else { return }
        focusedEditorID = kind == .editor ? sessionID : nil
        guard kind == .editor else { return }
        UserDefaults.standard.set(sessionID, forKey: lastEditorKey)
        finishEditorTargets(sessionID: sessionID)
    }

    static func didLoseFocus(sessionID: String? = nil) {
        if sessionID == nil || focusedEditorID == sessionID { focusedEditorID = nil }
    }

    private static func finishEditorTargets(sessionID: String) {
        for id in editorTargets.filter({ $0.value == sessionID }).map(\.key) {
            finish(id, result: .success(()))
        }
    }

    private static func finish(_ id: String, result: Result<Void, Error>) {
        pickedURLs.removeValue(forKey: id)
        openingSelections.remove(id)
        editorTargets.removeValue(forKey: id)
        editorCreationRequests.remove(id)
        pending.removeValue(forKey: id)?(result)
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private weak var menuWindow: UIWindow?

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? UIWindow,
              window.rootViewController is WorkbenchViewController else { return }
        noteWindowInteraction(window)
    }

    func noteWindowInteraction(_ window: UIWindow) {
        guard window.rootViewController is WorkbenchViewController else { return }
        if window.isKeyWindow, let scene = window.windowScene,
           let delegate = scene.delegate as? SceneDelegate {
            NativeSceneActivation.didFocus(sessionID: scene.session.persistentIdentifier, kind: delegate.windowKind,
                                           isActive: scene.activationState == .foregroundActive)
        }
        guard menuWindow !== window else { return }
        (menuWindow?.rootViewController as? WorkbenchViewController)?.setSceneFocused(false)
        menuWindow = window
        (window.rootViewController as? WorkbenchViewController)?.setSceneFocused(true)
        UIMenuSystem.main.setNeedsRebuild()
    }

    func sceneWindowDidDisconnect(_ window: UIWindow?) {
        guard menuWindow === window else { return }
        let candidates = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .filter { $0 !== window && $0.isKeyWindow && $0.rootViewController is WorkbenchViewController }
        (menuWindow?.rootViewController as? WorkbenchViewController)?.setSceneFocused(false)
        menuWindow = nil
        if candidates.count == 1 {
            noteWindowInteraction(candidates[0])
        } else {
            UIMenuSystem.main.setNeedsRebuild()
        }
    }

    func sceneWindowDidBecomeActive(_ window: UIWindow?) {
        if let window, window.isKeyWindow { noteWindowInteraction(window) }
    }

    func sceneWindowWillResignActive(_ window: UIWindow?) {
        guard menuWindow === window else { return }
        sceneWindowDidDisconnect(window)
    }

    func applicationWillResignActive(_ application: UIApplication) {
        NativeSceneActivation.didLoseFocus()
        (menuWindow?.rootViewController as? WorkbenchViewController)?.setSceneFocused(false)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        (menuWindow?.rootViewController as? WorkbenchViewController)?.setSceneFocused(true)
    }

    func ownsMainMenu(_ window: UIWindow?) -> Bool {
        guard let window else { return false }
        return menuWindow === window && window.isKeyWindow
    }

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == UIMenuSystem.main else { return }
        let workbench = menuWindow?.rootViewController as? WorkbenchViewController
        workbench?.populateMainMenu(builder)
        #if CODIPAD_ENABLE_SHARED_EXECUTION
        let mode = UIAction(title: "Execution Mode…") { [weak workbench] _ in
            guard let workbench else { return }
            NativeRuntimeStartup.presentModePicker(from: workbench)
        }
        builder.insertSibling(UIMenu(title: "Runtime", identifier: UIMenu.Identifier("dev.codipad.runtime"),
                                     children: [mode]), beforeMenu: .help)
        #endif
    }

    static func main() {
        #if DEBUG
        // Runtime-wide development selection, fixed before Node or the guest
        // kernel starts. Tool environments cannot change the engine mode.
        if CommandLine.arguments.contains("--codipad-flat-memory") {
            setenv("ISH_FLAT_MEMORY", "1", 1)
        }
        #endif
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                                               name: UIWindow.didBecomeKeyNotification, object: nil)
        NativeRuntimeStartup.prepareAtLaunch()
        NativeExtensionCatalog.prewarmBundledHostRoot { _ in }
        return true
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        let ids = sceneSessions.map(\.persistentIdentifier)
        DispatchQueue.global(qos: .utility).async {
            for id in ids {
                do {
                    let fileSystem = WorkspaceFileSystem(access: WorkspaceAccess())
                    let state = try NativeWorkspaceState(fileSystem: fileSystem, sceneID: id)
                    try state.discardSceneSelection()
                } catch {
                    print("codipad-scene: could not discard saved workspace selection")
                }
            }
        }
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
