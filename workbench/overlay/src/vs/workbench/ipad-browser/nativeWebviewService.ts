import { parentOriginHash } from '../../base/browser/iframe.js';
import { CodeWindow } from '../../base/browser/window.js';
import { Emitter } from '../../base/common/event.js';
import { INotificationService } from '../../platform/notification/common/notification.js';
import { IWebviewElement, WebviewInitInfo } from '../contrib/webview/browser/webview.js';
import { WebviewElement } from '../contrib/webview/browser/webviewElement.js';
import { WebviewService } from '../contrib/webview/browser/webviewService.js';
import { callNative } from './nativeBridge.js';

function closeNativeWebview(id: string): void {
	void callNative('webview.close', { id }).catch(error => console.error('[codipad-native] webview close failed', error));
}

/** Each pinned upstream shell and service worker runs on its own native loopback origin. */
export class NativeWebviewElement extends WebviewElement {
	private nativeEndpoint: string | undefined;
	private nativeDisposed = false;
	private mountGeneration = 0;
	private readonly nativeFailure = this._register(new Emitter<string>());
	readonly onNativeError = this.nativeFailure.event;

	override mountTo(element: HTMLElement, targetWindow: CodeWindow): void {
		const generation = ++this.mountGeneration;
		void parentOriginHash(targetWindow.origin, this.origin).then(async originHash => {
			if (this.nativeDisposed || generation !== this.mountGeneration) {
				return;
			}
			const { endpoint } = await callNative<{ endpoint: string }>('webview.open', { id: this.id, originHash });
			if (this.nativeDisposed) {
				closeNativeWebview(this.id);
				return;
			}
			if (generation !== this.mountGeneration) {
				return;
			}
			const url = new URL(endpoint);
			if (url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || !url.port
				|| url.pathname !== `/${originHash}/pre` || url.username || url.password || url.search || url.hash) {
				throw new Error('native webview returned an invalid isolated endpoint');
			}
			this.nativeEndpoint = endpoint;
			super.mountTo(element, targetWindow);
		}).catch(error => {
			if (!this.nativeDisposed && generation === this.mountGeneration) {
				this.nativeFailure.fire(error instanceof Error ? error.message : String(error));
				this.dispose();
			}
		});
	}

	protected override webviewContentEndpoint(_encodedWebviewOrigin: string): string {
		if (!this.nativeEndpoint) {
			throw new Error('native webview endpoint is not ready');
		}
		return this.nativeEndpoint;
	}

	override dispose(): void {
		if (this.nativeDisposed) {
			return;
		}
		this.nativeDisposed = true;
		super.dispose();
		closeNativeWebview(this.id);
	}
}

export class NativeWebviewService extends WebviewService {
	override createWebviewElement(initInfo: WebviewInitInfo): IWebviewElement {
		const webview = this._instantiationService.createInstance(NativeWebviewElement, initInfo, this._webviewThemeDataProvider);
		webview.onNativeError(message => this._instantiationService.invokeFunction(accessor => accessor.get(INotificationService).error(message)));
		this.registerNewWebview(webview);
		return webview;
	}
}
