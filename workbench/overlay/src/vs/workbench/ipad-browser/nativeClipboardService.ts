/*---------------------------------------------------------------------------------------------
 *  Copyright (c) CodiPad contributors. All rights reserved.
 *  Licensed under GPL-3.0-only. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { BrowserClipboardService } from '../services/clipboard/browser/clipboardService.js';
import { callNative } from './nativeBridge.js';

/** Extension RPC calls do not retain the browser gesture required by WebKit's clipboard. */
export class NativeClipboardService extends BrowserClipboardService {

	override async writeText(text: string, type?: string): Promise<void> {
		if (type) {
			return super.writeText(text, type);
		}
		await callNative('clipboard.writeText', { text });
		this.clearInternalState();
	}

	override async readText(type?: string): Promise<string> {
		if (type) {
			return super.readText(type);
		}
		const text = await callNative<unknown>('clipboard.readText');
		if (typeof text !== 'string') {
			throw new Error('[codipad-clipboard] Native clipboard returned invalid text');
		}
		return text;
	}
}
