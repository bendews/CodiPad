import Foundation

enum NativeExecutionMode: String {
    case gadget
    case stikDebug = "stikdebug"
    case debugger
    case platform

    var title: String {
        switch self {
        case .gadget: return "Gadget Only"
        case .stikDebug: return "StikDebug"
        case .debugger: return "Mac Debugger"
        case .platform: return "Embedded Node"
        }
    }
}

/// Immutable for this process. A saved choice applies on the next app launch.
struct NativeRuntimeConfiguration {
    static let preferenceKey = "dev.codipad.execution-mode"
    static let current: NativeRuntimeConfiguration = {
        #if CODIPAD_ENABLE_SHARED_EXECUTION
        let sharedExecution = true
        #else
        let sharedExecution = false
        #endif
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        return NativeRuntimeConfiguration(arguments: CommandLine.arguments,
                                          savedMode: UserDefaults.standard.string(forKey: preferenceKey),
                                          sharedExecution: sharedExecution, debugBuild: debugBuild)
    }()

    let mode: NativeExecutionMode
    let usesLinuxExtensionHost: Bool
    let error: String?
    var debuggerPrepared: Bool { mode == .debugger || mode == .stikDebug }

    init(arguments: [String], savedMode: String?, sharedExecution: Bool, debugBuild: Bool) {
        let gadget = arguments.contains("--codipad-gadget-only")
        let stik = arguments.contains("--codipad-stikdebug")
        let debugger = arguments.contains("--codipad-debugger-pages")
        let embedded = debugBuild && arguments.contains("--codipad-embedded-extension-host")
        let linux = debugBuild && arguments.contains("--codipad-linux-extension-host")
        var selected: NativeExecutionMode
        var failure: String?
        if [gadget, stik, debugger].filter({ $0 }).count > 1 || (embedded && (gadget || stik || linux)) {
            failure = "Conflicting execution modes were requested. Close CodiPad and launch with one mode."
        }
        if debugger {
            selected = .debugger
        } else if gadget {
            selected = .gadget
        } else if stik {
            selected = .stikDebug
        } else if embedded || !sharedExecution {
            selected = .platform
        } else {
            selected = savedMode == NativeExecutionMode.stikDebug.rawValue ? .stikDebug : .gadget
        }
        if !sharedExecution && (selected == .gadget || selected == .stikDebug) {
            failure = "This build does not include the shared Linux execution engine."
        }
        mode = selected
        usesLinuxExtensionHost = selected == .gadget || selected == .stikDebug || linux
        error = failure
    }
}
