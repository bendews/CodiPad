/*---------------------------------------------------------------------------------------------
 * System-selected files already authorized by the native exact-file authority. This consumer
 * opens ordinary editors without switching the selected workspace or authorizing other paths.
 *---------------------------------------------------------------------------------------------*/
import { DisposableStore, IDisposable, toDisposable } from '../../base/common/lifecycle.js';
import { URI } from '../../base/common/uri.js';
import { callNative } from './nativeBridge.js';
import { onReverseEvent } from './reverseEvents.js';

/** Call only after the actual editor services and native filesystem provider are ready. */
export function registerIncomingDocuments(openResource: (resource: URI, kind: 'file' | 'folder' | 'workspace') => Promise<void>, onError: (error: Error) => void): IDisposable {
	const store = new DisposableStore();
	const receiverId = crypto.randomUUID();
	let disposed = false;
	let pageId: string | undefined;
	const page = globalThis as typeof globalThis & { __codipadIncomingDocumentPage?: string };
	let opening = Promise.resolve();
	const report = (error: unknown) => onError(error instanceof Error ? error : new Error(String(error)));
	store.add(onReverseEvent('documents.open', 0, event => {
		opening = opening.then(async () => {
			if (disposed) { return; } // Unfinished native requests remain pending for the next ready receiver.
			let id: string | undefined;
			let failure: string | undefined;
			let requestPage: string | undefined;
			try {
				const request = JSON.parse(event.data ?? '');
				if (request.receiverId !== receiverId || request.pageId !== pageId) { return; }
				requestPage = request.pageId;
				if (typeof request.id !== 'string') { throw new Error('Invalid incoming document request'); }
				id = request.id;
				const uri = await callNative<string>('documents.resolve', { id, receiverId, pageId: requestPage });
				const resource = URI.parse(uri, true);
				if (resource.scheme !== 'file' || resource.authority || !resource.path.startsWith('/') || resource.query || resource.fragment || !['file', 'folder', 'workspace'].includes(request.resourceKind)) {
					throw new Error('The incoming document is not a supported local file');
				}
				if (!disposed) { await openResource(resource, request.resourceKind); }
			} catch (error) {
				// Keep the native error bounded in UTF-8, including arbitrary upstream editor messages.
				failure = String(error instanceof Error ? error.message : error).slice(0, 480) || 'Unable to open document';
				if (!id) { report(error); }
			}
			if (id && !disposed) {
				await callNative('documents.complete', { id, receiverId, pageId: requestPage, ...(failure ? { error: failure } : {}) });
			}
		}).catch(report);
	}));
	store.add(toDisposable(() => {
		disposed = true;
		if (pageId) { void callNative('documents.suspend', { receiverId, pageId }).catch(report); }
	}));
	const ready = () => {
		const current = page.__codipadIncomingDocumentPage;
		if (!disposed && current && current !== pageId) {
			pageId = current;
			void callNative('documents.ready', { receiverId, pageId }).catch(report);
		}
	};
	globalThis.addEventListener('codipad-incoming-document-page', ready);
	store.add(toDisposable(() => globalThis.removeEventListener('codipad-incoming-document-page', ready)));
	ready();
	return store;
}
