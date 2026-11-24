/* Browser URLs retain native-owned, scene-scoped filesystem grants. */
import { FileAccess } from '../../base/common/network.js';
import { URI } from '../../base/common/uri.js';

export interface NativeBrowserResource {
	readonly uri: string;
	readonly kind: 'file' | 'directory';
	readonly browserUri: string;
}

const roots = new Map<string, { path: string; kind: 'file' | 'directory'; browser: URI }>();

export function isCanonicalNativeFileUri(uri: URI, allowQueryAndFragment = false): boolean {
	return uri.scheme === 'file' && !uri.authority && (allowQueryAndFragment || (!uri.query && !uri.fragment)) && uri.path.startsWith('/') && !uri.path.includes('\\') && !uri.path.includes('\0') && !uri.path.split('/').some(part => part === '.' || part === '..');
}

function localPath(text: string): string {
	if (typeof text !== 'string' || !text.startsWith('file:')) { throw new Error('Invalid browser resource file URI'); }
	const uri = URI.parse(text, true);
	if (!isCanonicalNativeFileUri(uri)) {
		throw new Error('Invalid browser resource file URI');
	}
	return uri.path.length > 1 ? uri.path.replace(/\/$/, '') : uri.path;
}

function validateBrowserUri(text: string, kind: 'file' | 'directory', path: string): URI {
	const workbench = new URL(globalThis._VSCODE_FILE_ROOT);
	const scene = /^\/([a-f0-9]{32})\/out\/$/.exec(workbench.pathname)?.[1];
	if (workbench.protocol !== 'http:' || workbench.hostname !== '127.0.0.1' || workbench.origin !== globalThis.origin || !scene || workbench.username || workbench.password) {
		throw new Error('Invalid workbench origin');
	}
	const url = new URL(text);
	const prefix = `/${scene}/.extension/`;
	const pathname = url.pathname.startsWith(prefix) ? url.pathname.slice(prefix.length) : '';
	const match = /^([a-f0-9]{32})\/([a-f0-9]{32})\/(.*)$/.exec(pathname);
	if (url.origin !== workbench.origin || url.protocol !== 'http:' || url.username || url.password || url.search || url.hash || !match || url.href !== text) { throw new Error('Invalid browser resource URL'); }
	if (kind === 'directory' ? match[3] !== '' : !match[3] || match[3].includes('/') || decodeURIComponent(match[3]) !== path.slice(path.lastIndexOf('/') + 1)) {
		throw new Error('Invalid browser resource URL');
	}
	return URI.parse(url.href, true);
}

/** Validate a complete batch before changing the mapper. */
export function installNativeBrowserResources(entries: readonly NativeBrowserResource[]): void {
	const pending = new Map<string, { path: string; kind: 'file' | 'directory'; browser: URI }>();
	for (const entry of entries) {
		if (entry.kind !== 'directory' && entry.kind !== 'file') { throw new Error('Invalid browser resource kind'); }
		const path = localPath(entry.uri);
		const browser = validateBrowserUri(entry.browserUri, entry.kind, path);
		const key = entry.kind + ':' + path;
		const old = pending.get(key);
		if (old && old.browser.toString() !== browser.toString()) { throw new Error('Browser resource grant changed'); }
		pending.set(key, { path, kind: entry.kind, browser });
	}
	for (const [key, value] of pending) { roots.set(key, value); }
	FileAccess.setScopedFileBrowserUriMapper(uri => {
		if (!isCanonicalNativeFileUri(uri, true)) { return undefined; }
		let best = roots.get('file:' + uri.path);
		let ancestor = uri.path;
		while (!best) {
			best = roots.get('directory:' + ancestor);
			if (best || ancestor === '/') { break; }
			const separator = ancestor.lastIndexOf('/');
			ancestor = separator === 0 ? '/' : ancestor.slice(0, separator);
		}
		if (!best) { return undefined; }
		const suffix = best.kind === 'directory' ? uri.path.slice(best.path.length).replace(/^\//, '') : '';
		return best.browser.with({ path: best.browser.path + suffix, query: uri.query, fragment: uri.fragment });
	});
}

const catalogRoots = new Map<string, string>();

export function installCatalogBrowserResourceRoots(raw: unknown, packages: readonly string[], inventory?: readonly string[]): void {
	if (!Array.isArray(raw)) { throw new Error('[codipad-ext-catalog] missing browser resource roots'); }
	const locations = new Set(packages.map(localPath));
	const seen = new Set<string>();
	const entries: NativeBrowserResource[] = [];
	const pending = new Map<string, string>();
	for (const entry of raw) {
		const path = localPath(entry?.extensionLocation);
		if (!locations.has(path) || typeof entry.browserRoot !== 'string') { throw new Error('[codipad-ext-catalog] browser root is not an immutable package'); }
		const previous = pending.get(path) ?? catalogRoots.get(path);
		if (previous && previous !== entry.browserRoot) { throw new Error('[codipad-ext-catalog] immutable package browser root changed'); }
		pending.set(path, entry.browserRoot);
		seen.add(path);
		entries.push({ uri: entry.extensionLocation, browserUri: entry.browserRoot, kind: 'directory' });
	}
	if ([...locations].some(location => !seen.has(location))) { throw new Error('[codipad-ext-catalog] incomplete browser resource roots'); }
	installNativeBrowserResources(entries);
	for (const [path, browser] of pending) { catalogRoots.set(path, browser); }
	if (inventory) {
		const live = new Set(inventory.map(localPath));
		for (const [path, browser] of catalogRoots) {
			if (live.has(path)) { continue; }
			const key = 'directory:' + path;
			if (roots.get(key)?.browser.toString() === browser) { roots.delete(key); }
			catalogRoots.delete(path);
		}
	}
}
