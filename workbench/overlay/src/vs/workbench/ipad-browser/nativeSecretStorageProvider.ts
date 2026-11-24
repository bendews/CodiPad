import { ISecretStorageProvider } from '../../platform/secrets/common/secrets.js';
import { callNative } from './nativeBridge.js';

/** BrowserSecretStorageService supplies sequencing and change events around this native store. */
export class NativeSecretStorageProvider implements ISecretStorageProvider {

	readonly type = 'persisted';

	async get(key: string): Promise<string | undefined> {
		const value = await callNative<string | null>('secrets.get', { key });
		return value === null ? undefined : value;
	}

	async set(key: string, value: string): Promise<void> {
		await callNative('secrets.set', { key, value });
	}

	async delete(key: string): Promise<void> {
		await callNative('secrets.delete', { key });
	}

	keys(): Promise<string[]> {
		return callNative('secrets.keys');
	}
}
