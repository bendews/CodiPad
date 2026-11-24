/*---------------------------------------------------------------------------------------------
 * System callbacks enter the desktop URL service without BrowserURLService's trusted shortcut.
 *--------------------------------------------------------------------------------------------*/
import { DisposableStore, IDisposable, toDisposable } from '../../base/common/lifecycle.js';
import { matchesScheme } from '../../base/common/network.js';
import { IOpenerService, OpenExternalOptions } from '../../platform/opener/common/opener.js';
import { URI } from '../../base/common/uri.js';
import { IURLService } from '../../platform/url/common/url.js';
import { callNative } from './nativeBridge.js';
import { onReverseEvent } from './reverseEvents.js';

export function parseExtensionURL(text: string): URI {
	const uri = URI.parse(text, true);
	if (text.length > 16_384 || /[\x00-\x20\x7f]/.test(text) || uri.scheme !== 'codipad' || !/^[a-z0-9][a-z0-9-]*\.[a-z0-9][a-z0-9-]*$/i.test(uri.authority)) {
		throw new Error('Invalid extension callback');
	}
	return uri;
}

/** Start after workbench contributions, including the upstream extension URL consent handler. */
export function registerNativeExtensionURLs(urls: IURLService, opener: IOpenerService, onError: () => void): IDisposable {
	const store = new DisposableStore();
	store.add(opener.registerOpener({
		async open(resource, options) {
			if ((options as OpenExternalOptions | undefined)?.openExternal || !matchesScheme(resource, 'codipad')) { return false; }
			// Renderer links use the same untrusted consent path as OS callbacks.
			return urls.open(typeof resource === 'string' ? URI.parse(resource) : resource);
		}
	}));
	const receiverId = crypto.randomUUID();
	const page = globalThis as typeof globalThis & { __codipadIncomingDocumentPage?: string };
	let pageId: string | undefined;
	let disposed = false;
	let opening = Promise.resolve();
	store.add(onReverseEvent('urls.open', 0, event => {
		opening = opening.then(async () => {
			const request = JSON.parse(event.data ?? '{}');
			if (disposed || !pageId || request.pageId !== pageId || request.pageId !== page.__codipadIncomingDocumentPage || request.receiverId !== receiverId || typeof request.id !== 'string') { return; }
			const requestPage = pageId;
			// Native consumption precedes dispatch. An uncertain extension effect is never retried.
			const text = await callNative<string>('urls.claim', { pageId: requestPage, receiverId, id: request.id });
			const uri = parseExtensionURL(text);
			if (disposed || requestPage !== pageId || requestPage !== page.__codipadIncomingDocumentPage) { onError(); return; }
			// No trusted flag: stock extension consent, installation and activation apply.
			if (!await urls.open(uri)) { onError(); }
		}).catch(() => onError()); // Parser/upstream errors can contain credentials; never surface them.
	}));
	const ready = () => {
		const current = page.__codipadIncomingDocumentPage;
		if (!disposed && current && current !== pageId) {
			pageId = current;
			void callNative('urls.ready', { pageId, receiverId }).catch(() => onError());
		}
	};
	const dispose = () => {
		if (disposed) { return; }
		disposed = true;
		if (pageId) { void callNative('urls.suspend', { pageId, receiverId }).catch(() => {}); }
		store.dispose();
	};
	globalThis.addEventListener('codipad-incoming-document-page', ready);
	globalThis.addEventListener('pagehide', dispose);
	store.add(toDisposable(() => {
		globalThis.removeEventListener('codipad-incoming-document-page', ready);
		globalThis.removeEventListener('pagehide', dispose);
	}));
	ready();
	return { dispose };
}
