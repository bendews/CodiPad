/*---------------------------------------------------------------------------------------------
 * Native chrome actions belong to one started workbench and one committed native page epoch.
 *--------------------------------------------------------------------------------------------*/
import type { IDisposable } from '../../base/common/lifecycle.js';
import type { IFileDialogService } from '../../platform/dialogs/common/dialogs.js';

type NativeActionWindow = typeof globalThis & {
	__codipadIncomingDocumentPage?: string;
	__codipadNativeWorkbenchActions?: { receiverId: string; openFile(pageId: string, receiverId: string): Promise<void> };
	webkit?: { messageHandlers?: { codipad?: { postMessage(message: unknown): void } } };
};

export function registerNativeWorkbenchActions(dialogs: IFileDialogService): IDisposable {
	const page = globalThis as NativeActionWindow;
	const receiverId = crypto.randomUUID();
	let disposed = false;
	let busy = false;
	const publish = () => {
		if (page.__codipadIncomingDocumentPage) {
			page.webkit?.messageHandlers?.codipad?.postMessage({ event: 'native.workbenchActions',
				pageId: page.__codipadIncomingDocumentPage, receiverId, ready: !disposed, busy });
		}
	};
	const actions = {
		receiverId,
		async openFile(pageId: string, receiver: string): Promise<void> {
			if (disposed || busy || page.__codipadNativeWorkbenchActions !== actions || receiver !== receiverId || pageId !== page.__codipadIncomingDocumentPage) {
				throw new Error('The native Open action is no longer available');
			}
			busy = true;
			try {
				publish();
				await dialogs.pickFileAndOpen({ forceNewWindow: false });
			} finally {
				busy = false;
				if (!disposed) { publish(); }
			}
		}
	};
	const dispose = () => {
		if (disposed) { return; }
		disposed = true;
		if (page.__codipadNativeWorkbenchActions === actions) {
			delete page.__codipadNativeWorkbenchActions;
			publish();
		}
		page.removeEventListener('codipad-incoming-document-page', publish);
		page.removeEventListener('pagehide', dispose);
	};
	page.__codipadNativeWorkbenchActions = actions;
	page.addEventListener('codipad-incoming-document-page', publish);
	page.addEventListener('pagehide', dispose);
	publish();
	return { dispose };
}
