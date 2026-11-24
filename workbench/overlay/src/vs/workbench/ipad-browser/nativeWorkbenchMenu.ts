/* Native menu snapshots use the same live actions and context as the VS Code menubar. */
import { IAction, Separator } from '../../base/common/actions.js';
import { mnemonicButtonLabel } from '../../base/common/labels.js';
import { IDisposable } from '../../base/common/lifecycle.js';
import { IMenuService, MenuId, MenuItemAction, SubmenuItemAction } from '../../platform/actions/common/actions.js';
import { IContextKeyService } from '../../platform/contextkey/common/contextkey.js';

type WindowState = typeof globalThis & {
	__codipadIncomingDocumentPage?: string;
	__codipadNativeWorkbenchMenu?: { receiverId: string; run(page: string, receiver: string, revision: string, token: string): Promise<void> };
	webkit?: { messageHandlers?: { codipad?: { postMessage(value: unknown): void } } };
};
type Node = { title?: string; id?: string; token?: string; enabled?: boolean; checked?: boolean; children?: Node[]; separator?: true };

export function registerNativeWorkbenchMenu(menus: IMenuService, context: IContextKeyService): IDisposable {
	const page = globalThis as WindowState;
	const menu = menus.createMenu(MenuId.MenubarMainMenu, context, { emitEventsForSubmenuChanges: true });
	const receiverId = crypto.randomUUID();
	let disposed = false;
	let scheduled: ReturnType<typeof setTimeout> | undefined;
	let revision = '';
	let lastPage = '';
	let lastShape = '';
	let lastIdentities: object[] = [];
	let lastActionIDs: string[] = [];
	type Ancestor = { item: SubmenuItemAction['item']; id: string };
	type Selection = { action: MenuItemAction; ancestors: readonly Ancestor[] };
	let current = new Map<string, Selection>();
	const publish = () => {
		if (disposed || page.__codipadNativeWorkbenchMenu !== actions || !page.__codipadIncomingDocumentPage) { return; }
		const next = new Map<string, Selection>();
		const identities: object[] = [];
		const actionIDs: string[] = [];
		let count = 0;
		const convert = (action: IAction, depth: number, ancestors: readonly Ancestor[]): Node => {
			if (++count > 2048 || depth > 12) { throw new Error('Native menu exceeds supported size'); }
			if (action.id === Separator.ID) { return { separator: true }; }
			actionIDs.push(action.id);
			const title = mnemonicButtonLabel(action.label, true);
			if (!title || title.length > 512) { throw new Error('Native menu title is invalid'); }
			if (action instanceof SubmenuItemAction) {
				identities.push(action.item);
				return { title, id: action.item.submenu.id, enabled: action.enabled, children: action.actions.map(child => convert(child, depth + 1, [...ancestors, { item: action.item, id: action.item.submenu.id }])) };
			}
			if (!(action instanceof MenuItemAction)) { return { title, enabled: false }; }
			identities.push(action.item);
			const token = crypto.randomUUID();
			next.set(token, { action, ancestors });
			return { title, token, enabled: action.enabled, checked: action.checked === true };
		};
		try {
			const nodes = menu.getActions({ shouldForwardArgs: true }).flatMap(([, actions]) => actions.map(action => convert(action, 0, [])));
			const shape = JSON.stringify(nodes, (key, value) => key === 'token' ? undefined : value);
			if (page.__codipadIncomingDocumentPage === lastPage && shape === lastShape && identities.length === lastIdentities.length && identities.every((item, index) => item === lastIdentities[index]) && actionIDs.length === lastActionIDs.length && actionIDs.every((id, index) => id === lastActionIDs[index])) { return; }
			lastPage = page.__codipadIncomingDocumentPage;
			lastShape = shape;
			lastIdentities = identities;
			lastActionIDs = actionIDs;
			revision = crypto.randomUUID();
			current = next;
			page.webkit?.messageHandlers?.codipad?.postMessage({ event: 'native.workbenchMenu', pageId: page.__codipadIncomingDocumentPage, receiverId, revision, menus: nodes });
		} catch {
			lastPage = '';
			lastShape = '';
			lastIdentities = [];
			lastActionIDs = [];
			revision = '';
			current.clear();
			page.webkit?.messageHandlers?.codipad?.postMessage({ event: 'native.workbenchMenu', pageId: page.__codipadIncomingDocumentPage, receiverId, revision: '', menus: [] });
		}
	};
	const schedule = () => {
		if (scheduled !== undefined) { clearTimeout(scheduled); }
		scheduled = setTimeout(() => { scheduled = undefined; publish(); }, 200);
	};
	const listener = menu.onDidChange(schedule);
	const actions = {
		receiverId,
		async run(pageId: string, receiver: string, requestedRevision: string, token: string): Promise<void> {
			if (disposed || page.__codipadNativeWorkbenchMenu !== actions || pageId !== page.__codipadIncomingDocumentPage || receiver !== receiverId || requestedRevision !== revision) { throw new Error('Native menu is no longer current'); }
			const selected = current.get(token);
			if (!selected?.action.enabled) { throw new Error('Native menu action is unavailable'); }
			const findCurrent = (actions: readonly IAction[], depth: number): MenuItemAction | undefined => {
				for (const action of actions) {
					if (depth < selected.ancestors.length) {
						if (!(action instanceof SubmenuItemAction) || !action.enabled || action.item !== selected.ancestors[depth].item || action.item.submenu.id !== selected.ancestors[depth].id) { continue; }
						const child = findCurrent(action.actions, depth + 1);
						if (child) { return child; }
					} else if (action instanceof MenuItemAction && action.item === selected.action.item && action.id === selected.action.id && action.enabled) { return action; }
				}
				return undefined;
			};
			const action = findCurrent(menu.getActions({ shouldForwardArgs: true }).flatMap(([, actions]) => actions), 0);
			if (!action) { throw new Error('Native menu action is no longer available'); }
			await action.run();
		}
	};
	const dispose = () => {
		if (disposed) { return; }
		disposed = true;
		if (scheduled !== undefined) { clearTimeout(scheduled); }
		listener.dispose(); menu.dispose(); current.clear();
		if (page.__codipadNativeWorkbenchMenu === actions) {
			if (page.__codipadIncomingDocumentPage) { page.webkit?.messageHandlers?.codipad?.postMessage({ event: 'native.workbenchMenu', pageId: page.__codipadIncomingDocumentPage, receiverId, revision: '', menus: [] }); }
			delete page.__codipadNativeWorkbenchMenu;
		}
		page.removeEventListener('codipad-incoming-document-page', publish);
		page.removeEventListener('pagehide', dispose);
	};
	page.__codipadNativeWorkbenchMenu = actions;
	page.addEventListener('codipad-incoming-document-page', publish);
	page.addEventListener('pagehide', dispose);
	publish();
	return { dispose };
}
