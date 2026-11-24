import { addDisposableListener, EventType, getWindow } from '../../base/browser/dom.js';
import { DisposableStore, IDisposable, toDisposable } from '../../base/common/lifecycle.js';
import { isIOS } from '../../base/common/platform.js';

/** Apply native size events immediately and coalesce browser resize signals for both windows. */
export function registerNativeViewportLayout(container: HTMLElement, layout: () => void): IDisposable {
	const disposables = new DisposableStore();
	const nativeWindow = getWindow(container);
	let frame: number | undefined;
	const flush = () => {
		if (frame !== undefined) { nativeWindow.cancelAnimationFrame(frame); frame = undefined; }
		layout();
		// Match BrowserWindow's iOS keyboard workaround (upstream #121206).
		if (isIOS) { nativeWindow.scrollTo(0, 0); }
	};
	const schedule = () => {
		if (frame !== undefined) { return; }
		frame = nativeWindow.requestAnimationFrame(flush);
	};
	const observer = new ResizeObserver(schedule);
	// The native setter dispatches inside RAF; do not defer this layout to another frame.
	disposables.add(addDisposableListener(nativeWindow, 'codipad-native-viewport', flush));
	disposables.add(addDisposableListener(nativeWindow, EventType.RESIZE, schedule));
	if (isIOS && nativeWindow.visualViewport) {
		disposables.add(addDisposableListener(nativeWindow.visualViewport, EventType.RESIZE, schedule));
	}
	observer.observe(container);
	disposables.add(toDisposable(() => {
		observer.disconnect();
		if (frame !== undefined) { nativeWindow.cancelAnimationFrame(frame); }
	}));
	return disposables;
}
