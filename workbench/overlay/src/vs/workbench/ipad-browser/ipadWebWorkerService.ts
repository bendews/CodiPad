/*---------------------------------------------------------------------------------------------
 *  CodiPad worker boundary. Bootstrap, NLS, readiness and RPC remain upstream.
 *--------------------------------------------------------------------------------------------*/

import { WebWorkerDescriptor } from '../../platform/webWorker/browser/webWorkerDescriptor.js';
import { WebWorkerService } from '../../platform/webWorker/browser/webWorkerServiceImpl.js';

export class IpadWebWorkerService extends WebWorkerService {

	protected override async _createWorker(descriptor: WebWorkerDescriptor): Promise<Worker> {
		// Check and launch the same module even when a descriptor supplies a URL factory.
		const location = descriptor.esmModuleLocation;
		const resolved = new WebWorkerDescriptor({
			esmModuleLocation: typeof location === 'function' ? location() : location,
			esmModuleLocationBundler: descriptor.esmModuleLocationBundler,
			label: descriptor.label,
		});
		const moduleUrl = new URL(this.getWorkerUrl(resolved));
		const root = new URL(globalThis._VSCODE_FILE_ROOT);
		if (!['http:', 'https:'].includes(root.protocol) || root.origin !== globalThis.origin
			|| moduleUrl.origin !== root.origin || !root.pathname.endsWith('/')
			|| !moduleUrl.pathname.startsWith(root.pathname)) {
			throw new Error('[codipad-unsupported] web worker module must be in the workbench HTTP asset root');
		}

		// Fail before launching a worker if the declared upstream entry was not packaged.
		const response = await fetch(moduleUrl, { method: 'HEAD', credentials: 'same-origin' });
		if (!response.ok || !/(?:javascript|ecmascript)/i.test(response.headers.get('Content-Type') ?? '')) {
			throw new Error(`[codipad-unsupported] missing JavaScript worker artifact: ${descriptor.label}`);
		}
		return super._createWorker(resolved);
	}
}
