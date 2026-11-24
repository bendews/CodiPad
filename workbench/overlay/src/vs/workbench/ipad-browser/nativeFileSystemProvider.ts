/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench — `file:` over the native filesystem.
 *
 *  Every operation is a `codipadNative` call; nothing is cached, fabricated, or served from memory.
 *  The native side enforces bounded transfers and the security-scoped grants it issued
 *  through the picker, so a path outside a granted root fails there rather than here.
 *
 *  `watch()` uses native directory subscriptions for external changes. Symlinks are reported
 *  (`FileType.SymbolicLink`, native type 64) but not resolved.
 *---------------------------------------------------------------------------------------------*/

import { Emitter, Event } from '../../base/common/event.js';
import { Disposable, IDisposable, toDisposable } from '../../base/common/lifecycle.js';
import { URI } from '../../base/common/uri.js';
import {
	createFileSystemProviderError, FileChangeType,
	FileSystemProviderCapabilities, FileSystemProviderErrorCode, FileType, IFileChange, IFileDeleteOptions,
	IFileOpenOptions, IFileOverwriteOptions, IFileSystemProvider, IFileWriteOptions, IStat, IWatchOptions, isFileOpenForWriteOptions
} from '../../platform/files/common/files.js';
import { isFiltered, parseWatcherPatterns } from '../../platform/files/common/watcher.js';
import { callNative, decodeBase64, encodeBase64, NativeCallError, onNativePathCapabilities } from './nativeBridge.js';
import { onReverseEvent } from './reverseEvents.js';

interface NativeStat { readonly type: number; readonly size: number; readonly ctime: number; readonly mtime: number }

/** Native error codes map onto VS Code's provider error codes; unknown codes stay `Unknown`. */
const ERROR_CODES: Record<string, FileSystemProviderErrorCode> = {
	FileNotFound: FileSystemProviderErrorCode.FileNotFound,
	FileExists: FileSystemProviderErrorCode.FileExists,
	FileNotADirectory: FileSystemProviderErrorCode.FileNotADirectory,
	FileIsADirectory: FileSystemProviderErrorCode.FileIsADirectory,
	NoPermissions: FileSystemProviderErrorCode.NoPermissions,
	Unavailable: FileSystemProviderErrorCode.Unavailable,
	FileTooLarge: FileSystemProviderErrorCode.FileTooLarge,
	Unknown: FileSystemProviderErrorCode.Unknown
};

function toProviderError(error: unknown): Error {
	if (error instanceof NativeCallError) {
		const code = ERROR_CODES[error.code] ?? FileSystemProviderErrorCode.Unknown;

		return createFileSystemProviderError(new Error(`[codipad-native] ${error.message}`), code);
	}

	return error instanceof Error ? error : new Error(String(error));
}

function stopNativeWatch(subscriptionId: number): void {
	void callNative('fs.unwatch', { subscriptionId }).catch(error => {
		console.error('[codipad-native] fs.unwatch failed', error);
	});
}

/** Preserve supported target/link combinations; unknown native flags stay `Unknown`. */
function toFileType(type: number): FileType {
	switch (type) {
		case 1: return FileType.File;
		case 2: return FileType.Directory;
		case 64: return FileType.SymbolicLink;
		case 65: return FileType.File | FileType.SymbolicLink;
		case 66: return FileType.Directory | FileType.SymbolicLink;
		default: return FileType.Unknown;
	}
}

/** Maximum raw bytes in one native transfer. */
const MAX_TRANSFER_BYTES = 256 * 1024;

export class NativeFileSystemProvider extends Disposable implements IFileSystemProvider {

	readonly capabilities = FileSystemProviderCapabilities.FileReadWrite
		| FileSystemProviderCapabilities.FileOpenReadWriteClose
		| FileSystemProviderCapabilities.FileAtomicWrite
		| FileSystemProviderCapabilities.PathCaseSensitive;

	private readonly openHandles = new Map<number, { resource: URI; writing: boolean; created: boolean }>();

	private readonly _onDidChangeCapabilities = this._register(new Emitter<void>());
	readonly onDidChangeCapabilities: Event<void> = this._onDidChangeCapabilities.event;

	private readonly pathCapabilities = new Map<string, { readonly resource: URI; readonly pathCaseSensitive: boolean }>();

	constructor() {
		super();
		this._register(toDisposable(onNativePathCapabilities(capabilities => {
			const parsed = capabilities.map(capability => ({ resource: URI.parse(capability.uri), pathCaseSensitive: capability.pathCaseSensitive }));
			this.registerPathCapabilitiesBatch(parsed);
		})));
	}

	/** Register case semantics returned by the native authority for this live grant. */
	registerPathCapabilities(resource: URI, capabilities: { readonly pathCaseSensitive: boolean }): void {
		this.registerPathCapabilitiesBatch([{ resource, pathCaseSensitive: capabilities.pathCaseSensitive }]);
	}

	private registerPathCapabilitiesBatch(capabilities: readonly { readonly resource: URI; readonly pathCaseSensitive: boolean }[]): void {
		let changed = false;
		for (const capability of capabilities) {
			const key = capability.resource.toString();
			const current = this.pathCapabilities.get(key);
			if (current?.pathCaseSensitive === capability.pathCaseSensitive) {
				continue;
			}
			this.pathCapabilities.set(key, capability);
			changed = true;
		}
		if (changed) {
			this._onDidChangeCapabilities.fire();
		}
	}

	capabilitiesForResource(resource: URI): FileSystemProviderCapabilities {
		let pathCaseSensitive: boolean | undefined;
		let matchingRootLength = -1;
		for (const grant of this.pathCapabilities.values()) {
			if (grant.resource.scheme !== resource.scheme || grant.resource.authority !== resource.authority) {
				continue;
			}

			// Grant lookup must use the authority's canonical root spelling. Two volumes can
			// have roots that differ only by case; applying either volume's content rule to
			// the root itself could select the other grant. Case semantics apply below the root.
			const rootPath = grant.resource.path.replace(/\/+$/, '') || '/';
			const candidatePath = resource.path;
			const matches = rootPath === '/'
				? candidatePath.startsWith('/')
				: candidatePath === rootPath || candidatePath.startsWith(rootPath + '/');
			if (matches && rootPath.length > matchingRootLength) {
				matchingRootLength = rootPath.length;
				pathCaseSensitive = grant.pathCaseSensitive;
			}
		}

		const capabilities = this.capabilities & ~FileSystemProviderCapabilities.PathCaseSensitive;
		return pathCaseSensitive === false
			? capabilities
			: capabilities | FileSystemProviderCapabilities.PathCaseSensitive;
	}

	private readonly _onDidChangeFile = this._register(new Emitter<readonly IFileChange[]>());
	readonly onDidChangeFile: Event<readonly IFileChange[]> = this._onDidChangeFile.event;
	private readonly _onDidWatchError = this._register(new Emitter<string>());
	readonly onDidWatchError: Event<string> = this._onDidWatchError.event;

	watch(resource: URI, opts: IWatchOptions): IDisposable {
		let disposed = false;
		let watchFailed = false;
		let subscriptionId: number | undefined;
		let eventSubscription: IDisposable | undefined;
		let errorSubscription: IDisposable | undefined;
		const stop = () => {
			if (subscriptionId !== undefined) {
				stopNativeWatch(subscriptionId);
				subscriptionId = undefined;
			}
		};
		const fail = (message: string) => {
			if (disposed || watchFailed) { return; }
			watchFailed = true;
			eventSubscription?.dispose();
			errorSubscription?.dispose();
			this._onDidWatchError.fire(message);
			stop();
		};
		const ignoreCase = !(this.capabilitiesForResource(resource) & FileSystemProviderCapabilities.PathCaseSensitive);
		let excludes: ReturnType<typeof parseWatcherPatterns>;
		let includes: ReturnType<typeof parseWatcherPatterns> | undefined;
		try {
			excludes = parseWatcherPatterns(resource.fsPath, opts.excludes ?? [], ignoreCase);
			includes = opts.includes?.length ? parseWatcherPatterns(resource.fsPath, opts.includes, ignoreCase) : undefined;
		} catch (error) {
			this._onDidWatchError.fire(error instanceof Error ? error.message : String(error));
			return { dispose: () => { disposed = true; } };
		}
		void callNative<{ subscriptionId: number }>('fs.watch', {
			uri: resource.toString(),
			recursive: opts.recursive,
			// Only this literal glob form proves that every descendant is excluded.
			pruneNames: (ignoreCase ? [] : opts.excludes ?? []).flatMap(pattern => {
				const match = /^\*\*\/([a-zA-Z0-9._-]+)\/\*\*$/.exec(pattern);
				return match && match[1].length <= 255 ? [match[1]] : [];
			}).slice(0, 1024)
		}).then(({ subscriptionId: id }) => {
			if (disposed) {
				stopNativeWatch(id);
				return;
			}
			subscriptionId = id;
			eventSubscription = onReverseEvent('fs.changes', id, event => {
				if (disposed || watchFailed) {
					return;
				}
				if (event.overflow) {
					fail(event.reason ?? 'native file watch lost changes before subscription');
					return;
				}
				const { changes } = event as typeof event & {
					changes?: readonly { uri: string; type: FileChangeType }[];
				};
				if (!changes) {
					return;
				}
				const parsed = changes.map(change => ({ resource: URI.parse(change.uri), type: change.type, cId: opts.correlationId }));
				const matching = parsed.filter(change => !isFiltered(change, opts.filter)
					&& !excludes.some(pattern => pattern(change.resource.fsPath))
					&& (!includes || includes.some(pattern => pattern(change.resource.fsPath))));
				if (matching.length) {
					this.fire(matching);
				}
			});
			if (!watchFailed && !disposed) {
				errorSubscription = onReverseEvent('fs.watchError', id, event => {
					fail(event.message ?? event.reason ?? 'native file watch stopped after a coverage error');
				});
			}
			// Buffered events can dispose or fail the watch before subscription assignment.
			if (watchFailed || disposed) {
				eventSubscription.dispose();
				errorSubscription?.dispose();
			}
		}).catch(error => {
			if (!disposed) {
				this._onDidWatchError.fire(error instanceof Error ? error.message : String(error));
			}
		});

		return {
			dispose: () => {
				if (disposed) {
					return;
				}
				disposed = true;
				eventSubscription?.dispose();
				errorSubscription?.dispose();
				stop();
			}
		};
	}

	private fire(changes: IFileChange[]): void {
		this._onDidChangeFile.fire(changes);
	}

	async stat(resource: URI): Promise<IStat> {
		try {
			const stat = await callNative<NativeStat>('fs.stat', { uri: resource.toString() });

			return { type: toFileType(stat.type), size: stat.size, ctime: stat.ctime, mtime: stat.mtime };
		} catch (error) {
			throw toProviderError(error);
		}
	}

	async readdir(resource: URI): Promise<[string, FileType][]> {
		try {
			const entries = await callNative<[string, number][]>('fs.readdir', { uri: resource.toString() });

			return entries.map(([name, type]) => [name, toFileType(type)]);
		} catch (error) {
			throw toProviderError(error);
		}
	}

	async readFile(resource: URI): Promise<Uint8Array> {
		let opened: { data: string } | { handle: number };
		try {
			opened = await callNative('fs.open', { uri: resource.toString(), inlineIfSmall: true });
		} catch (error) { throw toProviderError(error); }
		if ('data' in opened) { return decodeBase64(opened.data); }
		const { handle } = opened;
		try {
			const chunks: Uint8Array[] = [];
			let length = 0;
			while (true) {
				const chunk = await this.readChunk(handle, length, MAX_TRANSFER_BYTES);
				if (!chunk.length) { break; }
				chunks.push(chunk);
				length += chunk.length;
			}
			const result = new Uint8Array(length);
			let offset = 0;
			for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
			return result;
		} finally {
			await this.close(handle);
		}
	}

	async writeFile(resource: URI, content: Uint8Array, opts: IFileWriteOptions): Promise<void> {
		if (content.length <= MAX_TRANSFER_BYTES) {
			try {
				const result = await callNative<{ created: boolean }>('fs.writeFile', { uri: resource.toString(), data: encodeBase64(content), create: opts.create, overwrite: opts.overwrite, atomic: !!opts.atomic });
				this.fire([{ resource, type: result.created ? FileChangeType.ADDED : FileChangeType.UPDATED }]);
			} catch (error) { throw toProviderError(error); }
			return;
		}
		if (opts.atomic) {
			let handle: number | undefined;
			try {
				({ handle } = await callNative<{ handle: number }>('fs.stageBegin', { uri: resource.toString(), create: opts.create, overwrite: opts.overwrite }));
				for (let offset = 0; offset < content.length; offset += MAX_TRANSFER_BYTES) {
					await callNative('fs.stageWrite', { handle, position: offset, data: encodeBase64(content.subarray(offset, offset + MAX_TRANSFER_BYTES)) });
				}
				const result = await callNative<{ created: boolean }>('fs.stageCommit', { handle });
				handle = undefined;
				this.fire([{ resource, type: result.created ? FileChangeType.ADDED : FileChangeType.UPDATED }]);
			} catch (error) { throw toProviderError(error); }
			finally { if (handle !== undefined) { await callNative('fs.stageAbort', { handle }).catch(() => undefined); } }
			return;
		}
		let handle: number | undefined;
		let succeeded = false;
		try {
			handle = await this.openFile(resource, true, opts.create, opts.overwrite);
			let offset = 0;
			while (offset < content.length) {
				offset += await this.write(handle, offset, content, offset, content.length - offset);
			}
			succeeded = true;
		} catch (error) {
			throw toProviderError(error);
		} finally {
			if (handle !== undefined) { if (!succeeded) { this.openHandles.delete(handle); } await this.close(handle); }
		}
	}

	async open(resource: URI, opts: IFileOpenOptions): Promise<number> {
		return this.openFile(resource, isFileOpenForWriteOptions(opts), true, true);
	}

	private async openFile(resource: URI, writing: boolean, create: boolean, overwrite: boolean): Promise<number> {
		try {
			const result = await callNative<{ handle: number; created: boolean }>('fs.open', { uri: resource.toString(), writing, create, overwrite });
			this.openHandles.set(result.handle, { resource, writing, created: result.created });
			return result.handle;
		} catch (error) { throw toProviderError(error); }
	}

	async close(handle: number): Promise<void> {
		const file = this.openHandles.get(handle);
		this.openHandles.delete(handle);
		try {
			await callNative('fs.close', { handle });
			if (file?.writing) { this.fire([{ resource: file.resource, type: file.created ? FileChangeType.ADDED : FileChangeType.UPDATED }]); }
		} catch (error) { throw toProviderError(error); }
	}

	private async readChunk(handle: number, position: number, length: number): Promise<Uint8Array> {
		try {
			return decodeBase64(await callNative<string>('fs.read', { handle, position, length: Math.min(length, MAX_TRANSFER_BYTES) }));
		} catch (error) { throw toProviderError(error); }
	}

	async read(handle: number, position: number, data: Uint8Array, offset: number, length: number): Promise<number> {
		const chunk = await this.readChunk(handle, position, length);
		data.set(chunk, offset);
		return chunk.length;
	}

	async write(handle: number, position: number, data: Uint8Array, offset: number, length: number): Promise<number> {
		try {
			return await callNative<number>('fs.write', { handle, position, data: encodeBase64(data.subarray(offset, offset + Math.min(length, MAX_TRANSFER_BYTES))) });
		} catch (error) { this.openHandles.delete(handle); throw toProviderError(error); }
	}

	async mkdir(resource: URI): Promise<void> {
		try {
			await callNative('fs.mkdir', { uri: resource.toString() });
			this.fire([{ resource, type: FileChangeType.ADDED }]);
		} catch (error) {
			throw toProviderError(error);
		}
	}

	async delete(resource: URI, opts: IFileDeleteOptions): Promise<void> {
		try {
			await callNative('fs.delete', { uri: resource.toString(), recursive: opts.recursive });
			this.fire([{ resource, type: FileChangeType.DELETED }]);
		} catch (error) {
			throw toProviderError(error);
		}
	}

	async rename(from: URI, to: URI, opts: IFileOverwriteOptions): Promise<void> {
		try {
			await callNative('fs.rename', { from: from.toString(), to: to.toString(), overwrite: opts.overwrite });
		} catch (error) {
			throw toProviderError(error);
		}
		this.fire([{ resource: from, type: FileChangeType.DELETED }, { resource: to, type: FileChangeType.ADDED }]);
	}
}
