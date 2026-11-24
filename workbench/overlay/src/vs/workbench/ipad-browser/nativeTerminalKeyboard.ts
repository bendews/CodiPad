import type { IDisposable } from '../../base/common/lifecycle.js';
import type { ITerminalService } from '../contrib/terminal/browser/terminal.js';

// Describe virtual keys; xterm and VS Code decide their meaning and encoding.
function keyInit(key: string): KeyboardEventInit | undefined {
	const special: Record<string, number> = { Escape: 27, Tab: 9, Enter: 13, ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40 };
	if (special[key]) { return { key, code: key, keyCode: special[key] }; }
	if (key.length !== 1) { return undefined; }
	if (/[a-z]/i.test(key)) { return { key, code: `Key${key.toUpperCase()}`, keyCode: key.toUpperCase().charCodeAt(0), shiftKey: key !== key.toLowerCase() }; }
	if (/[0-9]/.test(key)) { return { key, code: `Digit${key}`, keyCode: key.charCodeAt(0) }; }
	const punctuation: [string, string, number][] = [
		[' ', 'Space', 32], ['`~', 'Backquote', 192], ['-_', 'Minus', 189], ['=+', 'Equal', 187],
		['[{', 'BracketLeft', 219], [']}', 'BracketRight', 221], ['\\|', 'Backslash', 220],
		[';:', 'Semicolon', 186], ['\'"', 'Quote', 222], [',<', 'Comma', 188], ['.>', 'Period', 190], ['/?', 'Slash', 191]
	];
	const shiftedDigit = ')!@#$%^&*('.indexOf(key);
	if (shiftedDigit >= 0) { return { key, code: `Digit${shiftedDigit}`, keyCode: 48 + shiftedDigit, shiftKey: true }; }
	for (const [characters, code, keyCode] of punctuation) {
		const index = characters.indexOf(key);
		if (index >= 0) { return { key, code, keyCode, shiftKey: index === 1 }; }
	}
	return { key, code: '', keyCode: 0 };
}

export function registerNativeTerminalKeyboard(terminals: ITerminalService): IDisposable {
	const page = globalThis as typeof globalThis & {
		__codipadIncomingDocumentPage?: string;
		__codipadTerminalKeyboard?: { invoke(pageId: string, receiver: string, focus: string, key: string): boolean };
		webkit?: { messageHandlers?: { codipad?: { postMessage(value: unknown): void } } };
	};
	const receiverId = crypto.randomUUID();
	let focusId = crypto.randomUUID(), ctrl = false, alt = false, disposed = false;
	let target: typeof terminals.activeInstance, currentPage = page.__codipadIncomingDocumentPage;
	type Press = { owner: NonNullable<typeof target>; textarea: HTMLTextAreaElement; pageId: string | undefined; focus: string; init: KeyboardEventInit };
	const pressed = new Map<string, Press>(), injected = new WeakSet<Event>();
	const focused = () => {
		const instance = terminals.activeInstance;
		return instance?.xterm?.raw.textarea === document.activeElement ? instance : undefined;
	};
	const publish = () => page.webkit?.messageHandlers?.codipad?.postMessage({ event: 'native.terminalKeyboard',
		pageId: page.__codipadIncomingDocumentPage, receiverId, focusId, ready: !!target && !disposed, ctrl, alt });
	const valid = (press: Press, releasing = false) => !disposed && page.__codipadTerminalKeyboard === actions &&
		press.pageId === page.__codipadIncomingDocumentPage && press.focus === focusId && press.textarea.isConnected &&
		press.owner.xterm?.raw.textarea === press.textarea && (releasing || focused() === press.owner);
	const dispatch = (press: Press, type: string, repeat = false) => {
		if (!valid(press, type === 'keyup')) { return; }
		const event = new KeyboardEvent(type, { ...press.init, repeat, bubbles: true, cancelable: true,
			...(type === 'keypress' ? { charCode: press.init.key!.charCodeAt(0), keyCode: press.init.key!.charCodeAt(0) } : {}) });
		injected.add(event);
		// xterm's keyup calls textarea.focus(); releasing a blurred key must not reclaim focus.
		const suppressFocus = type === 'keyup' && focused() !== press.owner;
		const ownFocus = Object.getOwnPropertyDescriptor(press.textarea, 'focus');
		if (suppressFocus) { Object.defineProperty(press.textarea, 'focus', { configurable: true, value: () => {} }); }
		try { press.textarea.dispatchEvent(event); }
		finally {
			if (suppressFocus) {
				if (ownFocus) { Object.defineProperty(press.textarea, 'focus', ownFocus); }
				else { Reflect.deleteProperty(press.textarea, 'focus'); }
			}
		}
		return event;
	};
	const down = (press: Press, repeat: boolean) => {
		const event = dispatch(press, 'keydown', repeat);
		// xterm deliberately leaves some printable keys for keypress (eg macOS Option).
		if (event && !event.defaultPrevented && press.init.key?.length === 1) { dispatch(press, 'keypress', repeat); }
	};
	const release = (id: string) => {
		const press = pressed.get(id);
		pressed.delete(id);
		if (press) { dispatch(press, 'keyup'); ctrl = alt = false; publish(); }
	};
	const reset = () => {
		for (const id of Array.from(pressed.keys())) { release(id); }
		ctrl = alt = false; focusId = crypto.randomUUID(); publish();
	};
	const refresh = () => {
		const next = focused();
		if (next !== target || currentPage !== page.__codipadIncomingDocumentPage) {
			reset(); target = next; currentPage = page.__codipadIncomingDocumentPage;
		}
		publish();
	};
	const begin = (id: string, init: KeyboardEventInit) => {
		const textarea = target?.xterm?.raw.textarea;
		if (!target || !textarea) { return; }
		const press: Press = { owner: target, textarea, pageId: currentPage, focus: focusId, init: { ...init, ctrlKey: ctrl || init.ctrlKey, altKey: alt || init.altKey } };
		pressed.set(id, press); down(press, false);
	};
	const actions = {
		invoke(pageId: string, receiver: string, focus: string, action: string) {
			if (disposed || page.__codipadTerminalKeyboard !== actions || pageId !== page.__codipadIncomingDocumentPage ||
				receiver !== receiverId || focus !== focusId || !target || focused() !== target) { return false; }
			if (action === 'Cancel') { reset(); return true; }
			if (action === 'Control') { ctrl = !ctrl; publish(); return true; }
			if (action === 'Alt') { alt = !alt; publish(); return true; }
			const match = /^(.*):(down|repeat|up)$/.exec(action);
			const key = match?.[1] ?? action, phase = match?.[2] ?? 'tap', id = `native:${key}`, init = keyInit(key);
			if (!init) { return false; }
			if (phase === 'up') { release(id); return true; }
			if (phase === 'repeat') {
				const press = pressed.get(id);
				if (!press || !valid(press)) { return false; }
				down(press, true); return true;
			}
			if (pressed.has(id)) { return false; }
			begin(id, init);
			if (phase === 'tap') { release(id); }
			return true;
		}
	};
	const hardwareId = (event: KeyboardEvent) => `hardware:${event.code || event.key}:${event.location}`;
	const keydown = (event: KeyboardEvent) => {
		if (injected.has(event) || event.isComposing || event.keyCode === 229 || ['Dead', 'Process', 'AltGraph', 'Control', 'Alt', 'Shift', 'Meta'].includes(event.key) ||
			focused() !== target || !target) { return; }
		const id = hardwareId(event), press = pressed.get(id);
		if (!press && !ctrl && !alt) { return; }
		event.preventDefault(); event.stopImmediatePropagation();
		if (press) { down(press, event.repeat); }
		else { begin(id, { key: event.key, code: event.code, keyCode: event.keyCode, location: event.location,
			ctrlKey: event.ctrlKey, altKey: event.altKey, shiftKey: event.shiftKey, metaKey: event.metaKey }); }
	};
	const keyup = (event: KeyboardEvent) => {
		if (injected.has(event) || !pressed.has(hardwareId(event))) { return; }
		event.preventDefault(); event.stopImmediatePropagation(); release(hardwareId(event));
	};
	const beforeinput = (event: InputEvent) => {
		if ((!ctrl && !alt) || event.isComposing || event.inputType !== 'insertText' || !event.data || !event.cancelable || focused() !== target || !target) { return; }
		const init = keyInit(event.data);
		if (!init) { return; } // Composition, predictions and emoji stay on xterm's text-input path.
		event.preventDefault(); event.stopImmediatePropagation();
		begin('text', init); release('text');
	};
	const focusout = () => { queueMicrotask(refresh); };
	const dispose = () => {
		if (disposed) { return; }
		reset(); disposed = true; target = undefined; publish();
		if (page.__codipadTerminalKeyboard === actions) { delete page.__codipadTerminalKeyboard; }
		document.removeEventListener('focusin', refresh); document.removeEventListener('focusout', focusout);
		document.removeEventListener('keydown', keydown, true); document.removeEventListener('keyup', keyup, true);
		document.removeEventListener('beforeinput', beforeinput, true);
		page.removeEventListener('blur', reset); page.removeEventListener('pagehide', dispose);
		page.removeEventListener('codipad-incoming-document-page', refresh);
	};
	page.__codipadTerminalKeyboard = actions;
	document.addEventListener('focusin', refresh); document.addEventListener('focusout', focusout);
	document.addEventListener('keydown', keydown, true); document.addEventListener('keyup', keyup, true);
	document.addEventListener('beforeinput', beforeinput, true);
	page.addEventListener('blur', reset); page.addEventListener('pagehide', dispose);
	page.addEventListener('codipad-incoming-document-page', refresh);
	refresh();
	return { dispose };
}
