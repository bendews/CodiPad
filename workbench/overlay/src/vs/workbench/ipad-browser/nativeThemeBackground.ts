/* Mirror the visible workbench colors into native areas surrounding WKWebView. */
import type { IDisposable } from '../../base/common/lifecycle.js';
import type { IThemeService } from '../../platform/theme/common/themeService.js';

export function registerNativeThemeBackground(theme: IThemeService): IDisposable {
	const page = globalThis as typeof globalThis & {
		__codipadIncomingDocumentPage?: string;
		webkit?: { messageHandlers?: { codipad?: { postMessage(message: unknown): void } } };
	};
	let observed: Element[] = [], lastPayload = '', scheduled = false, disposed = false;
	const schedule = () => {
		if (scheduled || disposed) { return; }
		scheduled = true;
		queueMicrotask(() => { scheduled = false; if (!disposed) { publish(); } });
	};
	const observer = new MutationObserver(schedule);
	// The status bar animates background-color; the first mutation can expose its old color.
	const transition = (event: Event) => {
		if ((event as TransitionEvent).propertyName === 'background-color' && observed.includes(event.target as Element)) { schedule(); }
	};
	const format = (components: number[]) => components.every(value => Number.isInteger(value) && value >= 0 && value <= 255)
		? '#' + components.map(value => value.toString(16).padStart(2, '0')).join('') : undefined;
	const cssColor = (value: string): string | undefined => {
		const match = /^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)(?:\s*,\s*([\d.]+))?\s*\)$/.exec(value);
		if (!match) { return undefined; }
		return format([Number(match[1]), Number(match[2]), Number(match[3]), Math.round(Number(match[4] ?? 1) * 255)]);
	};
	const publish = () => {
		const root = document.querySelector('.monaco-workbench');
		const parts = ['.monaco-workbench .part.titlebar', '.monaco-workbench .part.statusbar'].map(selector => document.querySelector(selector));
		const targets: Element[] = [];
		for (const part of parts) {
			for (let node = part; node; node = node.parentElement) {
				if (!targets.includes(node)) { targets.push(node); }
				if (node === root) { break; }
			}
		}
		if (targets.length !== observed.length || targets.some((part, index) => observed[index] !== part)) {
			observer.disconnect(); observed = targets;
			for (const part of observed) { observer.observe(part, { attributes: true, attributeFilter: ['style', 'class'] }); }
		}
		const pageId = page.__codipadIncomingDocumentPage;
		const current = theme.getColorTheme();
		const themeColor = (id: string) => {
			const color = current.getColor(id)?.rgba;
			if (!color) { return undefined; }
			return format([color.r, color.g, color.b, Math.round(color.a * 255)]);
		};
		const background = themeColor('editor.background');
		if (!pageId || !background) { return; }
		const partColor = (part: Element | null, property: 'backgroundColor' | 'color') => {
			const color = part && part.getClientRects().length ? cssColor(getComputedStyle(part)[property]) : undefined;
			return color && !color.endsWith('00') ? color : undefined;
		};
		const visibleToken = (id: string) => { const color = themeColor(id); return color && !color.endsWith('00') ? color : undefined; };
		const terminalBackground = themeColor('terminal.background') ?? background;
		const terminalForeground = themeColor('terminal.foreground') ?? themeColor('editor.foreground');
		const titleBackground = partColor(parts[0], 'backgroundColor') ?? visibleToken('titleBar.activeBackground') ?? background;
		const statusBackground = partColor(parts[1], 'backgroundColor') ?? (parts[1]?.getClientRects().length ? visibleToken('statusBar.background') : undefined) ?? background;
		const payload = { event: 'native.workbenchBackground', pageId, background, terminalBackground, terminalForeground, titleBackground, statusBackground };
		const serialized = JSON.stringify(payload);
		if (serialized !== lastPayload) { lastPayload = serialized; page.webkit?.messageHandlers?.codipad?.postMessage(payload); }
	};
	const subscription = theme.onDidColorThemeChange(publish);
	document.addEventListener('transitionend', transition, true);
	document.addEventListener('transitioncancel', transition, true);
	page.addEventListener('codipad-incoming-document-page', publish);
	page.addEventListener('resize', schedule);
	publish();
	return { dispose: () => { disposed = true; observer.disconnect(); subscription.dispose(); document.removeEventListener('transitionend', transition, true); document.removeEventListener('transitioncancel', transition, true); page.removeEventListener('codipad-incoming-document-page', publish); page.removeEventListener('resize', schedule); } };
}
