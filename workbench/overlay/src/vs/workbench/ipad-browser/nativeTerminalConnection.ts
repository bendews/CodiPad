/* Copyright (c) CodiPad contributors. Licensed under GPL-3.0-only. */
import { callNative } from './nativeBridge.js';

/** Native navigation publishes this identity; an outgoing page cannot adopt its replacement. */
export async function callTerminal<T>(method: string, params: object = {}): Promise<T> {
	const target = globalThis as { __codipadIncomingDocumentPage?: string };
	if (!target.__codipadIncomingDocumentPage) {
		await new Promise<void>((resolve, reject) => {
			const ready = () => {
				if (target.__codipadIncomingDocumentPage) {
					clearTimeout(timer);
					globalThis.removeEventListener('codipad-incoming-document-page', ready);
					resolve();
				}
			};
			const timer = setTimeout(() => {
				globalThis.removeEventListener('codipad-incoming-document-page', ready);
				reject(new Error('[codipad-terminal] native page binding is unavailable'));
			}, 10000);
			globalThis.addEventListener('codipad-incoming-document-page', ready);
			ready();
		});
	}
	return callNative<T>(method, { pageId: target.__codipadIncomingDocumentPage, ...params });
}
