// Use the shared workbench contributions in WKWebView. ipadMain supplies the iPad services.
import './workbench.common.main.js';

// Complete the common profile import/export path with the pinned browser storage service.
// Keep browser registrations before ipadMain's native and disabled-service overrides.
import './services/userDataProfile/browser/userDataProfileStorageService.js';
import './ipad-browser/nativeAgentsWindowAction.js';

// Performance observers expect the load mark normally set by the upstream page bootstrap.
import { mark } from '../base/common/performance.js';
mark('code/didLoadWorkbenchMain');

// iPad composition. `ipadMain.ts` owns every service instance; nothing below this line touches
// Electron or shared-process IPC.
import { installBootErrorHooks, bootError, bootStep } from './ipad-browser/boot.js';
import { main as ipadMain, IpadMain } from './ipad-browser/ipadMain.js';
import { overrideServiceInstance } from './ipad-browser/serviceOverrides.js';
import { IRemoteAgentHostService, NullRemoteAgentHostService } from '../platform/agentHost/common/remoteAgentHostService.js';

export { IpadMain };

// Common chat and tool contributions depend on this service even when the product has no remote
// agent connections. The upstream null implementation exposes no connections and rejects
// unsupported connection operations. Register after the common graph so it is available when the
// workbench builds those contributions.
overrideServiceInstance(IRemoteAgentHostService, new NullRemoteAgentHostService());

/**
 * Boots a real workbench in the native-sized host. Returns once the workbench has started, so a shell
 * can log the outcome; it does not resolve to a disposed workbench.
 */
export async function main(): Promise<void> {
	installBootErrorHooks();
	bootStep('entrypoint', 'workbench.ipad.main');

	await ipadMain();
}

interface CodiPadGlobals {
	CODIPAD_AUTOSTART?: boolean;
}

// Auto-start for the page bundle, where no shell code imports this module. The shell may also set
// `CODIPAD_AUTOSTART = false` and call `main()` itself after its own readiness checks.
if ((globalThis as CodiPadGlobals).CODIPAD_AUTOSTART !== false) {
	main().catch(error => bootError('autostart', error));
}
