import UIKit
import Security

/// Prepares one execution policy before any scene creates process consumers.
@MainActor
enum NativeRuntimeStartup {
    enum Status {
        case starting, needsStikDebug, waiting, preparing, ready
        case failed(String)
    }

    static let didChange = Notification.Name("CodiPadRuntimeStartupChanged")
    private(set) static var status: Status = .starting {
        didSet { NotificationCenter.default.post(name: didChange, object: nil) }
    }
    private static var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private static var protocolStarted = false

    static var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    static func prepareAtLaunch() {
        if let failure = NativeRuntimeConfiguration.current.error {
            status = .failed(failure)
            return
        }
        if NativeRuntimeConfiguration.current.mode == .stikDebug {
            status = .needsStikDebug
            return
        }
        do {
            #if CODIPAD_ENABLE_SHARED_EXECUTION
            try NativeExecutionPages.prepare()
            #endif
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    static func enableWithStikDebug() {
        guard case .needsStikDebug = status else { return }
        #if CODIPAD_ENABLE_SHARED_EXECUTION
        do {
            guard #available(iOS 17.4, *) else {
                throw failure("StikDebug requires iPadOS 17.4 or later.")
            }
            guard CodiPadExecutionHasDebugEntitlement() else {
                throw failure("This installation does not allow debugging. Install a build signed with get-task-allow, or choose Gadget Only for the next launch.")
            }
            guard !CodiPadExecutionDebuggerAttached() else {
                throw failure("Another debugger is already attached. Restart CodiPad before enabling StikDebug.")
            }
            let txm = CodiPadExecutionTXMState()
            guard txm == 0 || txm == 1 else {
                throw failure("The JIT preparation method could not be determined for this device. Use Gadget Only for the next launch.")
            }
            if txm == 0 && CodiPadExecutionJITEnabled() {
                prepare(usesBreakpointProtocol: false, nonce: (0, 0))
                DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                    failAttempt("Runtime preparation did not finish in time. Restart CodiPad before trying again.")
                }
                return
            }
            guard let bundleID = Bundle.main.bundleIdentifier,
                  let probe = URL(string: "stikdebug://enable-jit"), UIApplication.shared.canOpenURL(probe) else {
                throw failure("Install StikDebug, import this device's pairing file and connect its required loopback VPN before enabling JIT.")
            }
            var bytes = [UInt8](repeating: 0, count: 16)
            let randomStatus = bytes.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
            }
            guard randomStatus == errSecSuccess, bytes.contains(where: { $0 != 0 }) else {
                throw failure("Could not create a fresh debugger preparation request.")
            }
            func word(_ slice: ArraySlice<UInt8>) -> UInt64 {
                slice.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
            }
            let nonce = (word(bytes[0..<8]), word(bytes[8..<16]))
            var components = URLComponents()
            components.scheme = "stikdebug"
            components.host = "enable-jit"
            components.queryItems = [URLQueryItem(name: "bundle-id", value: bundleID),
                                     URLQueryItem(name: "pid", value: String(getpid()))]
            CodiPadExecutionDebuggerHandshakeBegin(nonce.0, nonce.1)
            if txm == 1 {
                guard let resource = Bundle.main.url(forResource: "stikdebug", withExtension: "js") else {
                    throw failure("The bundled StikDebug preparation script is missing.")
                }
                var script = try String(contentsOf: resource, encoding: .utf8)
                let addressKey = "__CODIPAD_HANDSHAKE_ADDRESS__", tokenKey = "__CODIPAD_HANDSHAKE_TOKEN__"
                guard script.components(separatedBy: addressKey).count == 2,
                      script.components(separatedBy: tokenKey).count == 2 else {
                    throw failure("The bundled StikDebug preparation script is invalid.")
                }
                script = script.replacingOccurrences(of: addressKey, with: String(CodiPadExecutionDebuggerHandshakeAddress(), radix: 16))
                    .replacingOccurrences(of: tokenKey, with: bytes.map { String(format: "%02x", $0) }.joined())
                components.queryItems?.append(URLQueryItem(name: "script-data", value: Data(script.utf8).base64EncodedString()))
            }
            guard let url = components.url else { throw failure("Could not create the StikDebug request.") }
            status = .waiting
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Prepare CodiPad Runtime") {
                failAttempt("iPadOS ended background preparation. Return to CodiPad, then restart it before trying again.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                failAttempt("StikDebug preparation did not finish in time. Restart CodiPad before trying again.")
            }
            UIApplication.shared.open(url, options: [:]) { accepted in
                if accepted {
                    poll(deadline: deadline, usesBreakpointProtocol: txm == 1, nonce: nonce)
                } else {
                    failAttempt("iPadOS could not open StikDebug. Restart CodiPad before trying again.")
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
        #else
        status = .failed("This build does not include the shared execution engine.")
        #endif
    }

    #if CODIPAD_ENABLE_SHARED_EXECUTION
    private static func poll(deadline: TimeInterval, usesBreakpointProtocol: Bool, nonce: (UInt64, UInt64)) {
        if case .failed = status {
            // The external request can outlive its timeout. Service only its
            // matching handshake to detach; never allocate pages or start tools.
            guard usesBreakpointProtocol, !protocolStarted else { return }
            if CodiPadExecutionDebuggerHandshakeMatches(nonce.0, nonce.1), CodiPadExecutionDebuggerAttached() {
                protocolStarted = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let detached = CodiPadExecutionDebuggerCancelPreparation()
                    if !detached {
                        DispatchQueue.main.async {
                            status = .failed("StikDebug cleanup could not be confirmed. Restart CodiPad before trying again.")
                        }
                    }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
                    poll(deadline: deadline, usesBreakpointProtocol: usesBreakpointProtocol, nonce: nonce)
                }
            }
            return
        }
        guard case .waiting = status else { return }
        let ready = usesBreakpointProtocol
            ? CodiPadExecutionDebuggerHandshakeMatches(nonce.0, nonce.1) && CodiPadExecutionDebuggerAttached()
            : CodiPadExecutionJITEnabled() && !CodiPadExecutionDebuggerAttached()
        if ready {
            prepare(usesBreakpointProtocol: usesBreakpointProtocol, nonce: nonce)
        } else if ProcessInfo.processInfo.systemUptime >= deadline {
            failAttempt("StikDebug did not prepare this app process in time. Check pairing and the VPN, then restart CodiPad before trying again.")
            poll(deadline: deadline, usesBreakpointProtocol: usesBreakpointProtocol, nonce: nonce)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                poll(deadline: deadline, usesBreakpointProtocol: usesBreakpointProtocol, nonce: nonce)
            }
        }
    }

    private static func prepare(usesBreakpointProtocol: Bool, nonce: (UInt64, UInt64)) {
        protocolStarted = true
        status = .preparing
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, Error> = Result {
                try NativeExecutionPages.prepareWithStikDebug(usesBreakpointProtocol: usesBreakpointProtocol, nonce: nonce)
                guard !CodiPadExecutionDebuggerAttached() else {
                    throw failure("The debugger has not detached. Restart CodiPad before trying again.")
                }
            }
            DispatchQueue.main.async {
                endBackgroundTask()
                guard case .preparing = status else { return }
                switch result {
                case .success: status = .ready
                case .failure(let error): status = .failed(error.localizedDescription)
                }
            }
        }
    }
    #endif

    private static func failAttempt(_ message: String) {
        switch status {
        case .waiting, .preparing:
            status = .failed(message)
            endBackgroundTask()
        default: break
        }
    }

    private static func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    nonisolated private static func failure(_ message: String) -> Error {
        NSError(domain: "CodiPadRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func presentModePicker(from presenter: UIViewController) {
        #if CODIPAD_ENABLE_SHARED_EXECUTION
        let saved = UserDefaults.standard.string(forKey: NativeRuntimeConfiguration.preferenceKey)
        let next = saved == NativeExecutionMode.stikDebug.rawValue ? NativeExecutionMode.stikDebug : .gadget
        let alert = UIAlertController(title: "Execution Mode", message:
            "Current: \(NativeRuntimeConfiguration.current.mode.title)\nNext launch: \(next.title)\n\nChanges apply after you close and reopen CodiPad. Gadget Only works without a debugger. StikDebug requires pairing, a loopback VPN and JIT preparation for each new app process.", preferredStyle: .alert)
        for mode in [NativeExecutionMode.gadget, .stikDebug] {
            alert.addAction(UIAlertAction(title: "Use \(mode.title) Next Launch", style: .default) { _ in
                UserDefaults.standard.set(mode.rawValue, forKey: NativeRuntimeConfiguration.preferenceKey)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presenter.present(alert, animated: true)
        #endif
    }
}

/// Only shown while the selected runtime is unavailable. Workbench creation waits for readiness.
final class NativeRuntimeStartupViewController: UIViewController {
    private let statusLabel = UILabel()
    private let startButton = UIButton(type: .system)
    private let modeButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "CodiPad"
        title.font = .preferredFont(forTextStyle: .largeTitle)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        startButton.setTitle("Enable JIT with StikDebug", for: .normal)
        startButton.addTarget(self, action: #selector(start), for: .touchUpInside)
        modeButton.setTitle("Choose Execution Mode…", for: .normal)
        modeButton.addTarget(self, action: #selector(chooseMode), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, statusLabel, startButton, modeButton])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            startButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            modeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NativeRuntimeStartup.didChange, object: nil)
        refresh()
    }

    @objc private func start() { NativeRuntimeStartup.enableWithStikDebug() }
    @objc private func chooseMode() { NativeRuntimeStartup.presentModePicker(from: self) }

    @objc private func refresh() {
        startButton.isHidden = true
        switch NativeRuntimeStartup.status {
        case .starting: statusLabel.text = "Starting the runtime…"
        case .needsStikDebug:
            statusLabel.text = "Connect the loopback VPN, then open StikDebug to prepare this launch. You will return here when preparation finishes."
            startButton.isHidden = false
        case .waiting: statusLabel.text = "Waiting for StikDebug…"
        case .preparing: statusLabel.text = "Preparing the runtime…"
        case .ready: statusLabel.text = "Ready"
        case .failed(let message): statusLabel.text = message
        }
    }
}
