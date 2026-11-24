import Foundation

#if CODIPAD_ENABLE_SHARED_EXECUTION
/// Owns the code cache for the app-lifetime kernel and every Node generation.
enum NativeExecutionPages {
    private static let nodeReserveBytes = 256 * 1024 * 1024
    private static let lock = NSLock()
    private static var region: OpaquePointer?
    private static var kernelLease: OpaquePointer?
    private static var debuggerPolicy: Bool?
    private static var startupFailure: Error?

    static func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure = NativeRuntimeConfiguration.current.error {
            throw NativeExtensionHostError.runtimeUnavailable(failure)
        }
        if let startupFailure { throw startupFailure }
        if NativeRuntimeConfiguration.current.mode == .gadget {
            guard region == nil, codipad_kernel_configure_execution_mode(true) == 0 else {
                throw NativeExtensionHostError.runtimeUnavailable("The execution engine has already started in another mode. Restart CodiPad.")
            }
            return
        }
        if NativeRuntimeConfiguration.current.mode == .stikDebug {
            guard region != nil else {
                throw NativeExtensionHostError.runtimeUnavailable("StikDebug has not finished preparing this app process.")
            }
            return
        }
        try prepareLocked(debuggerPrepared: NativeRuntimeConfiguration.current.debuggerPrepared)
    }

    static func prepareWithStikDebug(usesBreakpointProtocol: Bool, nonce: (UInt64, UInt64)) throws {
        lock.lock()
        defer { lock.unlock() }
        guard NativeRuntimeConfiguration.current.mode == .stikDebug else {
            throw NativeExtensionHostError.runtimeUnavailable("StikDebug was not selected for this app process.")
        }
        if let startupFailure { throw startupFailure }
        guard region == nil else { return }
        if usesBreakpointProtocol {
            guard CodiPadExecutionDebuggerHandshakeMatches(nonce.0, nonce.1), CodiPadExecutionDebuggerAttached() else {
                throw NativeExtensionHostError.runtimeUnavailable("The StikDebug preparation script is not attached. Restart CodiPad before trying again.")
            }
        } else {
            guard CodiPadExecutionJITEnabled(), !CodiPadExecutionDebuggerAttached() else {
                throw NativeExtensionHostError.runtimeUnavailable("StikDebug has not enabled JIT and detached from this process.")
            }
        }
        try prepareLocked(debuggerPrepared: usesBreakpointProtocol)
    }

    private static func prepareLocked(debuggerPrepared: Bool) throws {
        if region != nil {
            guard debuggerPolicy == debuggerPrepared else {
                throw NativeExtensionHostError.runtimeUnavailable("Shared code pages already use a different page policy")
            }
            return
        }

        do {
            guard codipad_kernel_configure_execution_mode(false) == 0 else {
                throw NativeExtensionHostError.runtimeUnavailable("The Linux engine has already started in gadget mode. Restart CodiPad.")
            }
            try prepareOnce(debuggerPrepared: debuggerPrepared)
        } catch {
            // A debugger-prepared pool gets one startup attempt. Preserve its
            // actual failure instead of retrying after the debugger detached.
            startupFailure = error
            throw error
        }
    }

    private static func prepareOnce(debuggerPrepared: Bool) throws {

        var cacheBytes = ish_jit_region_capacity()
        guard cacheBytes > 0 else {
            throw NativeExtensionHostError.runtimeUnavailable("ARM64 code cache must be prepared before kernel startup")
        }
        // Keep the existing Node reserve when the translated-code cache grows.
        let poolBytes = max(512 * 1024 * 1024, cacheBytes + nodeReserveBytes)
        var error = [CChar](repeating: 0, count: 256)
        let created = error.withUnsafeMutableBufferPointer {
            CodiPadExecutionRegionCreate(poolBytes, debuggerPrepared, $0.baseAddress, $0.count)
        }
        guard let created else {
            throw NativeExtensionHostError.runtimeUnavailable(String(cString: error))
        }
        let actualPoolBytes = CodiPadExecutionRegionCapacity(created)
        if actualPoolBytes < poolBytes {
            // The debugger could not prepare the larger pool; retain the original
            // 256 MiB split for each engine rather than starving Node.
            guard actualPoolBytes == 512 * 1024 * 1024,
                  ish_jit_limit_region_capacity(256 * 1024 * 1024) else {
                CodiPadExecutionRegionDestroy(created)
                throw NativeExtensionHostError.runtimeUnavailable("Could not apply the smaller ARM64 code cache")
            }
            cacheBytes = ish_jit_region_capacity()
        }
        let lease = error.withUnsafeMutableBufferPointer {
            CodiPadExecutionRegionAcquire(created, cacheBytes, $0.baseAddress, $0.count)
        }
        guard let lease else {
            CodiPadExecutionRegionDestroy(created)
            throw NativeExtensionHostError.runtimeUnavailable(String(cString: error))
        }
        guard ish_jit_install_region(CodiPadExecutionLeaseExecutable(lease),
                                     CodiPadExecutionLeaseWritable(lease),
                                     CodiPadExecutionLeaseCapacity(lease)) else {
            CodiPadExecutionLeaseDestroy(lease)
            CodiPadExecutionRegionDestroy(created)
            throw NativeExtensionHostError.runtimeUnavailable("ARM64 engine refused the shared code cache")
        }
        // The engine now borrows these addresses. Keep the allocation through
        // kernel shutdown; the current kernel is intentionally app-lifetime.
        region = created
        kernelLease = lease
        debuggerPolicy = debuggerPrepared
    }

}
#endif
