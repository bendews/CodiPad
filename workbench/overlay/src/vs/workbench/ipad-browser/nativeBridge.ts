/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench — native channel.
 *
 *  Contract (WKScriptMessageHandlerWithReply, owned by the native shell):
 *
 *    const reply = await window.webkit.messageHandlers.codipadNative.postMessage({ method, params });
 *    // reply is { ok: true, value, pathCapabilities? } or { ok: false, error: { code, message } }
 *
 *  The promise is the transport: nothing here registers a global reply function, allocates call ids,
 *  or falls back to a second channel. Grant metadata is validated and delivered to listeners
 *  before the unchanged value resolves. A missing handler rejects with a named error, so a
 *  workbench without the shell fails visibly instead of pretending a file operation happened.
 *---------------------------------------------------------------------------------------------*/

import { URI } from '../../base/common/uri.js';
import { installNativeBrowserResources, isCanonicalNativeFileUri, NativeBrowserResource } from './nativeBrowserResources.js';

/** atob then a manual copy: spreading a multi-megabyte string into a constructor would blow the stack. */
export function decodeBase64(data: string): Uint8Array {
	const binary = atob(data);
	const bytes = new Uint8Array(binary.length);
	for (let index = 0; index < binary.length; index++) {
		bytes[index] = binary.charCodeAt(index);
	}

	return bytes;
}

export function encodeBase64(bytes: Uint8Array): string {
	const chunk = 0x8000;
	let binary = '';
	for (let offset = 0; offset < bytes.length; offset += chunk) {
		binary += String.fromCharCode(...bytes.subarray(offset, offset + chunk));
	}

	return btoa(binary);
}

export interface NativeErrorPayload {
	readonly code: string;
	readonly message: string;
}

export interface NativePathCapability {
	readonly uri: string;
	readonly pathCaseSensitive: boolean;
}

interface NativeEnvelope {
	readonly ok: boolean;
	readonly value?: unknown;
	readonly error?: NativeErrorPayload;
	readonly pathCapabilities?: unknown;
}

interface CodiPadNativeHandler {
	postMessage(message: unknown): Promise<NativeEnvelope>;
}

interface CodiPadNativeBridge {
	readonly messageHandlers?: { readonly codipadNative?: CodiPadNativeHandler };
}

export class NativeBridgeUnavailableError extends Error { }
export class NativeCallError extends Error {
	constructor(readonly method: string, readonly code: string, message: string) {
		super(`[codipad-native] ${method}: ${code}: ${message}`);
	}
}

const pathCapabilityListeners = new Set<(capabilities: readonly NativePathCapability[]) => void>();

/** Subscribe to grant metadata attached to native replies. The returned function removes the listener. */
export function onNativePathCapabilities(listener: (capabilities: readonly NativePathCapability[]) => void): () => void {
	pathCapabilityListeners.add(listener);
	return () => pathCapabilityListeners.delete(listener);
}

function validatePathCapabilities(method: string, value: unknown): readonly NativePathCapability[] {
	if (value === undefined) {
		return [];
	}
	if (!Array.isArray(value)) {
		throw new NativeCallError(method, 'MalformedPathCapabilities', 'pathCapabilities must be an array');
	}

	const seen = new Map<string, boolean>();
	const capabilities: NativePathCapability[] = [];
	const browserResources: NativeBrowserResource[] = [];
	for (const entry of value) {
		if (!entry || typeof entry !== 'object' || !('uri' in entry) || !('pathCaseSensitive' in entry)) {
			throw new NativeCallError(method, 'MalformedPathCapabilities', 'each path capability needs a file URI and boolean pathCaseSensitive');
		}
		const candidate = entry as Record<string, unknown>;
		if (typeof candidate.uri !== 'string' || typeof candidate.pathCaseSensitive !== 'boolean') {
			throw new NativeCallError(method, 'MalformedPathCapabilities', 'each path capability needs a file URI and boolean pathCaseSensitive');
		}
		let uri: URI;
		try {
			uri = URI.parse(candidate.uri);
		} catch {
			throw new NativeCallError(method, 'MalformedPathCapabilities', 'path capability URI is invalid');
		}
		if (!isCanonicalNativeFileUri(uri)) {
			throw new NativeCallError(method, 'MalformedPathCapabilities', 'path capability URI must be a local absolute file URI');
		}
		const previous = seen.get(candidate.uri);
		if (previous !== undefined && previous !== candidate.pathCaseSensitive) {
			throw new NativeCallError(method, 'MalformedPathCapabilities', 'duplicate URI has conflicting case semantics');
		}
		if (candidate.browserResource !== undefined) {
			const resource = candidate.browserResource;
			if (!resource || typeof resource !== 'object' || !('kind' in resource) || !('uri' in resource) || (resource.kind !== 'directory' && resource.kind !== 'file') || typeof resource.uri !== 'string') {
				throw new NativeCallError(method, 'MalformedPathCapabilities', 'invalid browser resource grant');
			}
			browserResources.push({ uri: candidate.uri, kind: resource.kind, browserUri: resource.uri });
		}
		seen.set(candidate.uri, candidate.pathCaseSensitive);
		capabilities.push({ uri: candidate.uri, pathCaseSensitive: candidate.pathCaseSensitive });
	}
	try { if (browserResources.length) { installNativeBrowserResources(browserResources); } }
	catch { throw new NativeCallError(method, 'MalformedPathCapabilities', 'invalid browser resource grant'); }
	return capabilities;
}

export function isNativeAvailable(): boolean {
	return !!(globalThis as { webkit?: CodiPadNativeBridge }).webkit?.messageHandlers?.codipadNative;
}

export async function callNative<T>(method: string, params: unknown = {}): Promise<T> {
	const handler = (globalThis as { webkit?: CodiPadNativeBridge }).webkit?.messageHandlers?.codipadNative;
	if (!handler) {
		throw new NativeBridgeUnavailableError('[codipad-native] window.webkit.messageHandlers.codipadNative is not installed by the shell');
	}

	const envelope = await handler.postMessage({ method, params });
	if (envelope?.ok) {
		const pathCapabilities = validatePathCapabilities(method, envelope.pathCapabilities);
		if (pathCapabilities.length) {
			for (const listener of pathCapabilityListeners) {
				listener(pathCapabilities);
			}
		}
		return envelope.value as T;
	}

	const error = envelope?.error ?? { code: 'Unknown', message: 'malformed reply from the shell' };
	throw new NativeCallError(method, error.code, error.message);
}
