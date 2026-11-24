/*---------------------------------------------------------------------------------------------
 *  Native external-browser boundary for VS Code's normal opener and URL validation services.
 *--------------------------------------------------------------------------------------------*/

import { CancellationToken } from '../../base/common/cancellation.js';
import { URI } from '../../base/common/uri.js';
import { IExternalOpener } from '../../platform/opener/common/opener.js';
import { callNative } from './nativeBridge.js';

export class NativeExternalOpener implements IExternalOpener {
	async openExternal(href: string, _context: { sourceUri: URI }, token: CancellationToken): Promise<boolean> {
		if (token.isCancellationRequested) {
			return false;
		}
		const uri = URI.parse(href, true);
		const scheme = uri.scheme.toLowerCase();
		if (!['http', 'https', 'mailto'].includes(scheme) || ((scheme === 'http' || scheme === 'https') && (!uri.authority || uri.authority.includes('@')))) {
			throw new Error('[codipad-opener] Native browser opening requires an absolute HTTP, HTTPS or mailto URI without embedded credentials');
		}
		const opened = await callNative<unknown>('window.openExternal', { uri: href });
		if (opened !== true) {
			// The upstream default-opener path discards a false result and reports the URI handled.
			throw new Error('[codipad-opener] The native system did not open the external URI');
		}
		return true;
	}
}
