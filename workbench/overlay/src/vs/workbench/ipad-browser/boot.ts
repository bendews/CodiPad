/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench — boot diary.
 *
 *  Every step, warning and failure is reported three ways: the DOM status panel, `console`, and
 *  the native shell via `webkit.messageHandlers.codipad`. No failure is swallowed; a boot that
 *  cannot continue leaves a readable panel on screen instead of a blank page.
 *--------------------------------------------------------------------------------------------*/

export type BootLevel = 'step' | 'warn' | 'error';

interface NativeBootMessage {
	readonly kind: 'codipad-boot';
	readonly level: BootLevel;
	readonly step: string;
	readonly detail?: string;
	readonly stack?: string;
	readonly at: number;
}

interface CodiPadWebkitBridge {
	readonly messageHandlers?: { readonly codipad?: { postMessage(message: NativeBootMessage): void } };
}

const entries: NativeBootMessage[] = [];
let panel: HTMLElement | undefined;
let shellStarted = false;

function post(message: NativeBootMessage): void {
	entries.push(message);
	try {
		// WKWebView only; absent in a preview browser tab, which is fine.
		const bridge = (globalThis as { webkit?: CodiPadWebkitBridge }).webkit;
		bridge?.messageHandlers?.codipad?.postMessage(message);
	} catch (error) {
		console.error('[codipad-boot] native post failed', error);
	}
}

function panelElement(): HTMLElement {
	if (panel?.isConnected) {
		return panel;
	}

	panel = document.createElement('div');
	panel.id = 'codipad-boot-panel';
	panel.setAttribute('role', 'status');
	panel.style.cssText = [
		'position:fixed', 'inset:auto 0 0 0', 'z-index:2147483647',
		'font:12px/1.4 ui-monospace,Menlo,monospace', 'white-space:pre-wrap',
		'background:#1f1f1f', 'color:#ddd', 'padding:8px 12px',
		'border-top:1px solid #444', 'max-height:40vh', 'overflow:auto'
	].join(';');
	document.body.appendChild(panel);

	return panel;
}

function render(): void {
    // Once VS Code owns the window, diagnostics remain in the native/console log. The
    // bootstrap panel is only for a startup that never reaches the shell.
    if (shellStarted) { return; }
	const lines = entries.map(entry => {
		const mark = entry.level === 'error' ? 'ERROR' : entry.level === 'warn' ? 'WARN ' : '  ok ';
		return `${mark} ${entry.step}${entry.detail ? `: ${entry.detail}` : ''}`;
	});
	const failed = entries.some(entry => entry.level === 'error');
	const element = panelElement();
	element.textContent = lines.join('\n');
	element.style.color = failed ? '#ffb4ab' : '#ddd';
}

export function bootStep(step: string, detail?: string): void {
	post({ kind: 'codipad-boot', level: 'step', step, detail, at: Date.now() });
	console.log(`[codipad-boot] ${step}${detail ? `: ${detail}` : ''}`);
	if (step === 'workbench-started') {
		shellStarted = true;
		panel?.remove();
		document.getElementById('startup')?.remove();
		return;
	}
	render();
}

export function bootWarn(step: string, detail?: string): void {
	post({ kind: 'codipad-boot', level: 'warn', step, detail, at: Date.now() });
	console.warn(`[codipad-boot] ${step}${detail ? `: ${detail}` : ''}`);
	render();
}

export function bootError(step: string, error: unknown): void {
	const asError = error instanceof Error ? error : new Error(String(error));
	post({ kind: 'codipad-boot', level: 'error', step, detail: asError.message, stack: asError.stack, at: Date.now() });
	console.error(`[codipad-boot] ${step}`, asError);
	render();
}

/**
 * A capability this build does not provide yet. Throwing keeps the failure attributed to the
 * named service in the boot diary instead of surfacing as an unrelated `undefined` later.
 */
export function unsupported(serviceId: string, reason: string): never {
	throw new Error(`[codipad-unsupported] ${serviceId}: ${reason}`);
}

export function installBootErrorHooks(): void {
	globalThis.addEventListener?.('error', event => bootError('window-error', event.error ?? event.message));
	globalThis.addEventListener?.('unhandledrejection', event => bootError('unhandled-rejection', event.reason));
}

