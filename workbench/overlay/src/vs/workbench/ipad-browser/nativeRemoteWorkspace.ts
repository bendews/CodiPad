/*---------------------------------------------------------------------------------------------
 *  Copyright (c) CodiPad contributors. All rights reserved.
 *  Licensed under GPL-3.0-only. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { Schemas } from '../../base/common/network.js';
import { URI, isUriComponents } from '../../base/common/uri.js';
import { IWorkspace, IWorkspaceProvider } from '../browser/web.api.js';
import { IAnyWorkspaceIdentifier, UNKNOWN_EMPTY_WINDOW_WORKSPACE } from '../../platform/workspace/common/workspace.js';
import { getSingleFolderWorkspaceIdentifier, getWorkspaceIdentifier } from '../../platform/workspaces/common/workspaceIdentifier.js';
import { IExtUri, removeTrailingPathSeparator, isEqualOrParent, relativePath, joinPath } from '../../base/common/resources.js';
import { CancellationToken } from '../../base/common/cancellation.js';
import { CancellationError } from '../../base/common/errors.js';
import { bufferToReadable, streamToBuffer, encodeBase64 } from '../../base/common/buffer.js';
import { IStorageService, StorageScope, StorageTarget } from '../../platform/storage/common/storage.js';
import { Memento } from '../common/memento.js';
import { IWorkingCopyBackupService } from '../services/workingCopy/common/workingCopyBackup.js';
import { WorkingCopyBackupService } from '../services/workingCopy/common/workingCopyBackupService.js';
import { IndexedDBStorageDatabase } from '../services/storage/browser/storageService.js';
import { ILogService } from '../../platform/log/common/log.js';
import { parse } from '../../base/common/json.js';
import { isStoredWorkspaceFolder, toWorkspaceFolders } from '../../platform/workspaces/common/workspaces.js';
import { IFileService } from '../../platform/files/common/files.js';
import { callNative } from './nativeBridge.js';

const STORAGE_KEY = 'codipad.remoteWorkspace.v1';

/** localStorage is shared by all workbench paths at the same origin, so scope remote state by scene. */
export function remoteWorkspaceSceneStorage(storage: Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>,
	sceneId: string, migrateLegacy: boolean): Pick<Storage, 'getItem' | 'setItem' | 'removeItem'> {
	if (!sceneId || sceneId.length > 512 || sceneId.includes('\0')) {
		throw new Error('Invalid native scene identity');
	}
	const key = `${STORAGE_KEY}.scene.${encodeURIComponent(sceneId)}`;
	if (migrateLegacy) {
		const old = storage.getItem(STORAGE_KEY);
		if (old !== null) {
			if (storage.getItem(key) === null) { storage.setItem(key, old); }
			storage.removeItem(STORAGE_KEY);
		}
	}
	return {
		getItem: name => storage.getItem(name === STORAGE_KEY ? key : name),
		setItem: (name, value) => storage.setItem(name === STORAGE_KEY ? key : name, value),
		removeItem: name => storage.removeItem(name === STORAGE_KEY ? key : name)
	};
}

/** Keep the legacy scene's storage and backup IDs, while isolating other windows. */
export function sceneWorkspaceIdentifier(workspace: IAnyWorkspaceIdentifier, sceneId: string, migrateLegacy: boolean): IAnyWorkspaceIdentifier {
	if (!sceneId || sceneId.length > 512 || sceneId.includes('\0')) {
		throw new Error('Invalid native scene identity');
	}
	if (migrateLegacy) { return workspace; }
	const encodedScene = encodeURIComponent(sceneId);
	const id = `codipad-scene-${encodedScene.length}-${encodedScene}-${encodeURIComponent(workspace.id)}`;
	if (id.length > 1024) { throw new Error('Scene workspace identity is too long'); }
	return { ...workspace, id };
}

interface RemoteWorkspaceState {
	readonly version: 1;
	readonly remoteAuthority: string;
	readonly folderUri?: string;
	readonly workspaceUri?: string;
	readonly payload?: object;
}

export interface RemoteWorkspaceOpenOptions {
	readonly reuse?: boolean;
	readonly payload?: object;
	readonly remoteAuthority?: string | null;
}

export interface NativeWorkspaceSelection {
	readonly folderUri: URI;
	readonly workspaceId: string;
	readonly previousFolderUris?: readonly URI[];
}

/** Selection comes from an established native grant, never a persisted renderer file URI. */
export function parseNativeWorkspaceSelection(value: unknown): NativeWorkspaceSelection | undefined {
	if (!value || typeof value !== 'object' || Array.isArray(value)) {
		throw new Error('Invalid native workspace selection');
	}
	const state = value as { folderUri?: unknown; workspaceId?: unknown; restoreUnavailable?: unknown; previousFolderUris?: unknown };
	if (state.restoreUnavailable !== undefined && typeof state.restoreUnavailable !== 'boolean') {
		throw new Error('Invalid native workspace restoration state');
	}
	if (state.folderUri === null && state.workspaceId === undefined) {
		return undefined;
	}
	if (typeof state.folderUri !== 'string' || typeof state.workspaceId !== 'string' || !state.workspaceId
		|| state.workspaceId.length > 8192 || /[\x00-\x1f\x7f]/.test(state.workspaceId) || state.restoreUnavailable) {
		throw new Error('Invalid native workspace identity');
	}
	const folderUri = URI.parse(state.folderUri, true);
	if (folderUri.scheme !== Schemas.file || folderUri.authority || !folderUri.path.startsWith('/') || folderUri.query || folderUri.fragment) {
		throw new Error('Native workspace must have a canonical local file URI');
	}
	let previousFolderUris: URI[] | undefined;
	if (state.previousFolderUris !== undefined) {
		if (!Array.isArray(state.previousFolderUris) || !state.previousFolderUris.length || state.previousFolderUris.length > 32) {
			throw new Error('Invalid native workspace relocation');
		}
		previousFolderUris = state.previousFolderUris.map(value => {
			const previous = parseNativeWorkspaceSelection({ folderUri: value, workspaceId: state.workspaceId })!.folderUri;
			if (previous.toString() === removeTrailingPathSeparator(folderUri).toString()) { throw new Error('Invalid native workspace relocation'); }
			return URI.parse(value, true);
		});
		if (new Set(previousFolderUris.map(uri => uri.toString())).size !== previousFolderUris.length) {
			throw new Error('Duplicate native workspace relocation root');
		}
	}
	return { folderUri: removeTrailingPathSeparator(folderUri), workspaceId: state.workspaceId, previousFolderUris };
}

export interface NativeWorkspaceFileSelection {
	readonly workspaceUri: URI;
	readonly workspaceId: string;
	readonly folderUris: readonly URI[];
	readonly preparationToken?: string;
}

export type NativeLocalWorkspaceSelection = NativeWorkspaceSelection | NativeWorkspaceFileSelection;

function localWorkspaceURI(value: unknown, directory = false): URI {
	if (typeof value !== 'string') { throw new Error('Invalid native workspace resource'); }
	const uri = URI.parse(value, true);
	if (uri.scheme !== Schemas.file || uri.authority || !uri.path.startsWith('/') || uri.query || uri.fragment
		|| /[\x00-\x1f\x7f]/.test(uri.path) || uri.path.split('/').some(part => part === '.' || part === '..')) {
		throw new Error('Native workspace resources require canonical local file URIs');
	}
	return directory ? removeTrailingPathSeparator(uri) : uri;
}

/** File workspaces have their own identity; a first folder is never substituted for the file. */
export function parseNativeWorkspaceFileSelection(value: unknown): NativeWorkspaceFileSelection {
	if (!value || typeof value !== 'object' || Array.isArray(value)) { throw new Error('Invalid native workspace selection'); }
	const state = value as { workspaceUri?: unknown; folderUri?: unknown; workspaceId?: unknown; folderUris?: unknown; preparationToken?: unknown; restoreUnavailable?: unknown };
	if (state.folderUri != null || typeof state.workspaceId !== 'string' || !state.workspaceId || state.workspaceId.length > 8192
		|| /[\x00-\x1f\x7f]/.test(state.workspaceId) || state.restoreUnavailable || !Array.isArray(state.folderUris)
		|| (state.restoreUnavailable !== undefined && typeof state.restoreUnavailable !== 'boolean')
		|| (state.preparationToken !== undefined && (typeof state.preparationToken !== 'string' || !state.preparationToken))) {
		throw new Error('Invalid native workspace-file identity');
	}
	const folderUris = state.folderUris.map(value => localWorkspaceURI(value, true));
	if (new Set(folderUris.map(uri => uri.toString())).size !== folderUris.length) { throw new Error('Duplicate native workspace root'); }
	return { workspaceUri: localWorkspaceURI(state.workspaceUri), workspaceId: state.workspaceId, folderUris,
		preparationToken: state.preparationToken as string | undefined };
}

export function parseNativeLocalWorkspaceSelection(value: unknown): NativeLocalWorkspaceSelection | undefined {
	return value && typeof value === 'object' && 'workspaceUri' in value && value.workspaceUri != null
		? parseNativeWorkspaceFileSelection(value) : parseNativeWorkspaceSelection(value);
}

type NativeWorkspaceRequest = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/** Shared with startup validation: persisted paths describe roots but cannot grant them. */
export function resolveNativeWorkspaceFolders(resource: URI, contents: string, extUri: IExtUri): readonly URI[] {
	const stored = parse(contents);
	if (!stored || !Array.isArray(stored.folders)) { throw new Error('Invalid workspace file: expected folders array'); }
	if (stored.remoteAuthority) { throw new Error('A local workspace cannot select a remote authority'); }
	return toWorkspaceFolders(stored.folders.filter(isStoredWorkspaceFolder), resource, extUri)
		.map(folder => localWorkspaceURI(folder.uri.toString(), true));
}

/** Upstream JSONC/path semantics describe roots; only the native authority can authorize them. */
export async function identifyNativeWorkspaceFile(resource: URI, files: IFileService, extUri: IExtUri,
	request: NativeWorkspaceRequest = callNative, token = CancellationToken.None): Promise<NativeWorkspaceFileSelection | undefined> {
	resource = localWorkspaceURI(resource.toString());
	if (token.isCancellationRequested) { throw new CancellationError(); }
	const content = (await files.readFile(resource)).value;
	const roots = resolveNativeWorkspaceFolders(resource, content.toString(), extUri);
	if (token.isCancellationRequested) { throw new CancellationError(); }
	const response = await request('workspace.identify', { uri: resource.toString(), workspaceFile: true,
		folderUris: roots.map(uri => uri.toString()), contents: encodeBase64(content) });
	if (response === null) { return undefined; } // Ordinary native picker cancellation publishes no candidate.
	const selection = parseNativeWorkspaceFileSelection(response);
	if (!selection.preparationToken || !extUri.isEqual(selection.workspaceUri, resource)
		|| selection.folderUris.length !== roots.length || roots.some((uri, index) => !extUri.isEqual(uri, selection.folderUris[index]))) {
		if (selection.preparationToken) { await cancelNativeWorkspaceFile(selection, request); }
		throw new Error('Native workspace authorization differs from the parsed workspace');
	}
	if (token.isCancellationRequested) {
		await cancelNativeWorkspaceFile(selection, request);
		throw new CancellationError();
	}
	return selection;
}

export async function commitNativeWorkspaceFile(selection: NativeWorkspaceFileSelection, request: NativeWorkspaceRequest = callNative): Promise<void> {
	if (!selection.preparationToken) { throw new Error('Workspace selection has no pending native preparation'); }
	await request('workspace.commit', { uri: selection.workspaceUri.toString(), workspaceFile: true, folderUris: selection.folderUris.map(uri => uri.toString()),
		workspaceId: selection.workspaceId, preparationToken: selection.preparationToken });
}

export async function cancelNativeWorkspaceFile(selection: NativeWorkspaceFileSelection, request: NativeWorkspaceRequest = callNative): Promise<void> {
	if (!selection.preparationToken) { throw new Error('Workspace selection has no pending native preparation'); }
	await request('workspace.cancel', { workspaceId: selection.workspaceId, preparationToken: selection.preparationToken });
}

function validateAuthority(authority: unknown): asserts authority is string {
	if (typeof authority !== 'string' || !authority || authority.length > 1024 || /[\x00-\x20\x7f/\\?#]/.test(authority)) {
		throw new Error('Invalid remote authority');
	}
}

function workspaceUri(workspace: IWorkspace): URI | undefined {
	return workspace && ('folderUri' in workspace ? workspace.folderUri : workspace.workspaceUri);
}

/** The workbench graph is authority-scoped. Opening a remote window must rebuild that graph. */
export class NativeRemoteWorkspaceProvider implements IWorkspaceProvider {
	readonly remoteAuthority: string | undefined;
	private remoteWorkspace: IWorkspace;
	private nativeWorkspace: NativeLocalWorkspaceSelection | undefined;
	readonly payload: object | undefined;
	readonly trusted = undefined;

	constructor(
		private readonly storage: Pick<Storage, 'getItem' | 'setItem' | 'removeItem'>,
		private readonly reload: () => Promise<void>,
		private readonly openLocal: (workspace: IWorkspace, options?: RemoteWorkspaceOpenOptions) => Promise<boolean>,
		private readonly openNewWindow?: (workspace: IWorkspace, options?: RemoteWorkspaceOpenOptions) => Promise<boolean>,
		private readonly qualifyWorkspace: (workspace: IAnyWorkspaceIdentifier) => IAnyWorkspaceIdentifier = workspace => workspace,
	) {
		const serialized = storage.getItem(STORAGE_KEY);
		if (serialized === null) {
			return;
		}
		const state: RemoteWorkspaceState = JSON.parse(serialized);
		if (!state || typeof state !== 'object' || state.version !== 1) {
			throw new Error('Unsupported remote workspace state');
		}
		validateAuthority(state.remoteAuthority);
		if ((state.folderUri !== undefined && typeof state.folderUri !== 'string') || (state.workspaceUri !== undefined && typeof state.workspaceUri !== 'string') || (state.payload !== undefined && (!state.payload || typeof state.payload !== 'object'))) {
			throw new Error('Invalid remote workspace state');
		}
		if (state.folderUri && state.workspaceUri) {
			throw new Error('Remote workspace state contains both a folder and workspace file');
		}
		const uri = state.folderUri ? URI.parse(state.folderUri, true) : state.workspaceUri ? URI.parse(state.workspaceUri, true) : undefined;
		if (uri && (uri.scheme !== Schemas.vscodeRemote || uri.authority !== state.remoteAuthority)) {
			throw new Error('Remote workspace URI and authority disagree');
		}
		this.remoteAuthority = state.remoteAuthority;
		this.remoteWorkspace = state.folderUri ? { folderUri: uri! } : state.workspaceUri ? { workspaceUri: uri! } : undefined;
		this.payload = state.payload;
	}

	get workspace(): IWorkspace {
		if (this.remoteAuthority) { return this.remoteWorkspace; }
		if (!this.nativeWorkspace) { return undefined; }
		return 'workspaceUri' in this.nativeWorkspace
			? { workspaceUri: this.nativeWorkspace.workspaceUri } : { folderUri: this.nativeWorkspace.folderUri };
	}

	setNativeWorkspace(selection: NativeLocalWorkspaceSelection | undefined): void {
		if (this.remoteAuthority) {
			throw new Error('A remote window cannot adopt a native workspace');
		}
		this.nativeWorkspace = selection;
	}

	get workspaceIdentifier(): IAnyWorkspaceIdentifier {
		if (!this.remoteAuthority && this.nativeWorkspace) {
			return this.qualifyWorkspace('workspaceUri' in this.nativeWorkspace
				? { id: this.nativeWorkspace.workspaceId, configPath: this.nativeWorkspace.workspaceUri }
				: { id: this.nativeWorkspace.workspaceId, uri: this.nativeWorkspace.folderUri });
		}
		if (!this.workspace) {
			return this.qualifyWorkspace(this.remoteAuthority ? { id: `codipad-remote-${this.remoteAuthority}` } : UNKNOWN_EMPTY_WINDOW_WORKSPACE);
		}
		if ('folderUri' in this.workspace) {
			return this.qualifyWorkspace(getSingleFolderWorkspaceIdentifier(this.workspace.folderUri));
		}
		return this.qualifyWorkspace(getWorkspaceIdentifier(this.workspace.workspaceUri));
	}

	async open(workspace: IWorkspace, options?: RemoteWorkspaceOpenOptions): Promise<boolean> {
		// Upstream passes undefined reuse for an empty New Window, and false for explicit
		// new-window workspace requests. Never silently reuse the current scene.
		if (options?.reuse === false || (options?.reuse === undefined && !workspace)) {
			if (!this.openNewWindow) { throw new Error('Opening a new window is unavailable'); }
			return this.openNewWindow(workspace, options);
		}
		const uri = workspaceUri(workspace);
		const authority = options?.remoteAuthority === null ? undefined : options?.remoteAuthority ?? (uri?.scheme === Schemas.vscodeRemote ? uri.authority : undefined);
		if (!authority && !this.remoteAuthority) {
			return this.openLocal(workspace, options);
		}
		if (!authority && workspace) {
			throw new Error('Close the remote connection before opening a native folder');
		}
		if (authority) {
			validateAuthority(authority);
			if (uri && (uri.scheme !== Schemas.vscodeRemote || uri.authority !== authority)) {
				throw new Error('Remote workspace URI and authority disagree');
			}
		}

		const previous = this.storage.getItem(STORAGE_KEY);
		try {
			if (authority) {
				const state: RemoteWorkspaceState = {
					version: 1,
					remoteAuthority: authority,
					...(workspace && 'folderUri' in workspace ? { folderUri: workspace.folderUri.toString() } : {}),
					...(workspace && 'workspaceUri' in workspace ? { workspaceUri: workspace.workspaceUri.toString() } : {}),
					...(options?.payload ? { payload: options.payload } : {}),
				};
				this.storage.setItem(STORAGE_KEY, JSON.stringify(state));
			} else {
				this.storage.removeItem(STORAGE_KEY);
			}
			await this.reload();
			return true;
		} catch (error) {
			if (previous === null) {
				this.storage.removeItem(STORAGE_KEY);
			} else {
				this.storage.setItem(STORAGE_KEY, previous);
			}
			throw error;
		}
	}
}

export interface NativeEditorRelocation {
	readonly kind: 'directory' | 'file';
	readonly from: URI;
	readonly to: URI;
}

function validatedRelocations(mappings: readonly NativeEditorRelocation[]): readonly NativeEditorRelocation[] {
	const seen = new Set<string>();
	return mappings.map(mapping => {
		if (mapping.kind !== 'directory' && mapping.kind !== 'file') { throw new Error('Invalid native document relocation kind'); }
		const from = localWorkspaceURI(mapping.from.toString(), mapping.kind === 'directory');
		const to = localWorkspaceURI(mapping.to.toString(), mapping.kind === 'directory');
		const key = `${mapping.kind}:${from.toString()}`;
		if (seen.has(key) || from.toString() === to.toString()) { throw new Error('Invalid or duplicate native document relocation'); }
		seen.add(key);
		return { kind: mapping.kind, from, to };
	}).sort((a, b) => b.from.path.length - a.from.path.length || (a.kind === 'file' ? -1 : 1));
}

/** Map only canonical local resource identities, preserving view query and fragment. */
export function relocateNativeEditorResource(resource: URI, selection: NativeWorkspaceSelection | readonly NativeEditorRelocation[]): URI {
	if (resource.scheme !== Schemas.file || resource.authority || resource.path.split('/').some(part => part === '.' || part === '..')) { return resource; }
	const mappings = Array.isArray(selection) ? validatedRelocations(selection) : validatedRelocations((selection as NativeWorkspaceSelection).previousFolderUris?.map(from => ({ kind: 'directory' as const, from, to: (selection as NativeWorkspaceSelection).folderUri })) ?? []);
	const clean = resource.with({ query: '', fragment: '' });
	for (const mapping of mappings) {
		if (mapping.kind === 'file') {
			if (clean.toString() === mapping.from.toString()) { return mapping.to.with({ query: resource.query, fragment: resource.fragment }); }
		} else if (isEqualOrParent(clean, mapping.from)) {
			const relative = relativePath(mapping.from, clean);
			if (relative !== undefined) { return joinPath(mapping.to, relative).with({ query: resource.query, fragment: resource.fragment }); }
		}
	}
	return resource;
}

/** Migrate the pinned file-editor serializer fields, never extension state or arbitrary strings. */
function relocateSerializedEditor(editor: { id: string; value: string }, selection: NativeWorkspaceSelection | readonly NativeEditorRelocation[]): void {
	if (editor.id === 'workbench.editors.files.fileEditorInput') {
		const value = JSON.parse(editor.value);
		let changed = false;
		for (const key of ['resourceJSON', 'preferredResourceJSON']) {
			if (value[key] && typeof value[key].scheme === 'string' && typeof value[key].path === 'string') {
				const resource = URI.revive(value[key]);
				const relocated = relocateNativeEditorResource(resource, selection);
				if (relocated.toString() !== resource.toString()) { value[key] = relocated.toJSON(); changed = true; }
			}
		}
		if (changed) { editor.value = JSON.stringify(value); }
	} else if (editor.id === 'workbench.editors.diffEditorInput' || editor.id === 'workbench.editorinputs.sidebysideEditorInput') {
		const value = JSON.parse(editor.value);
		let changed = false;
		for (const side of ['primary', 'secondary']) {
			const child = { id: value[side + 'TypeId'], value: value[side + 'Serialized'] };
			if (typeof child.id === 'string' && typeof child.value === 'string') {
				relocateSerializedEditor(child, selection);
				if (child.value !== value[side + 'Serialized']) { value[side + 'Serialized'] = child.value; changed = true; }
			}
		}
		if (changed) { editor.value = JSON.stringify(value); }
	} else {
		const affected = (value: unknown): boolean => {
			if (typeof value === 'string' && value.startsWith('file:')) {
				try { const uri = URI.parse(value, true); return relocateNativeEditorResource(uri, selection).toString() !== uri.toString(); } catch { return false; }
			}
			if (isUriComponents(value)) { const uri = URI.revive(value); return relocateNativeEditorResource(uri, selection).toString() !== uri.toString(); }
			return !!value && typeof value === 'object' && Object.values(value).some(affected);
		};
		let value: unknown;
		try { value = JSON.parse(editor.value); } catch { value = editor.value; }
		if (affected(value)) { throw new Error('Relocation of this serialized editor type is not supported'); }
	}
}

function relocateEditorPart(state: any, selection: NativeWorkspaceSelection | readonly NativeEditorRelocation[]): void {
	const visit = (node: any) => {
		if (node?.type === 'branch' && Array.isArray(node.data)) { node.data.forEach(visit); }
		else if (node?.type === 'leaf' && Array.isArray(node.data?.editors)) {
			for (const editor of node.data.editors) {
				if (typeof editor.id === 'string' && typeof editor.value === 'string') { relocateSerializedEditor(editor, selection); }
			}
		}
	};
	visit(state?.serializedGrid?.root);
}

/** Runs before the workbench/editor graph starts. Native retains evidence until the caller acks. */
export async function restoreRelocatedNativeEditors(selection: NativeWorkspaceSelection, storage: IStorageService,
	backups: IWorkingCopyBackupService, logService: ILogService, token = CancellationToken.None,
	rendererWorkspaceId = selection.workspaceId): Promise<void> {
	if (!selection.previousFolderUris?.length) { return; }
	if (!storage.hasScope({ id: rendererWorkspaceId, uri: selection.folderUri })) { throw new Error('Relocation workspace storage identity mismatch'); }
	const checkCancelled = () => { if (token.isCancellationRequested) { throw new CancellationError(); } };
	checkCancelled();
	const staged = ['workbench.parts.editor', 'workbench.editorParts'].map(id => {
		const memento = new Memento<Record<string, any>>(id, storage);
		const original = memento.getMemento(StorageScope.WORKSPACE, StorageTarget.MACHINE);
		const updated = JSON.parse(JSON.stringify(original));
		if (id === 'workbench.parts.editor') { relocateEditorPart(updated['editorpart.state'], selection); }
		else { for (const part of updated['editorparts.state']?.auxiliary ?? []) { relocateEditorPart(part.state, selection); } }
		return { memento, original, updated };
	});
	// Saved working sets use the same pinned serialized editor layout, not arbitrary profile data.
	const workingSets = storage.getObject<any[]>('editor.workingSets', StorageScope.WORKSPACE);
	const updatedWorkingSets = workingSets && JSON.parse(JSON.stringify(workingSets));
	for (const set of updatedWorkingSets ?? []) {
		relocateEditorPart(set.main, selection);
		for (const part of set.auxiliary?.auxiliary ?? []) { relocateEditorPart(part.state, selection); }
	}
	const retire = await stageRelocatedBackups(selection, backups, token);
	checkCancelled();
	for (const { memento, original, updated } of staged) { Object.assign(original, updated); memento.saveMemento(); }
	if (updatedWorkingSets) { storage.store('editor.workingSets', updatedWorkingSets, StorageScope.WORKSPACE, StorageTarget.MACHINE); }
	const keys = ['memento/workbench.parts.editor', 'memento/workbench.editorParts', 'editor.workingSets'];
	const expected = new Map(keys.map(key => [key, storage.get(key, StorageScope.WORKSPACE)]));
	await storage.flush();
	// Upstream flush waiters can settle after a failed/in-flight write. Verify committed
	// values through a separate IndexedDB connection, never through the storage cache.
	const database = await IndexedDBStorageDatabase.createWorkspaceStorage(rendererWorkspaceId, logService);
	try {
		if (!(database instanceof IndexedDBStorageDatabase)) { throw new Error('Relocation requires persistent workspace storage'); }
		const committed = await database.getItems();
		if (keys.some(key => committed.get(key) !== expected.get(key))) {
			throw new Error('Relocated editor layout has not committed; original backups and native history are retained');
		}
	} finally { await database.close(); database.dispose(); }
	// Keep original backups until the new identifiers and serialized resources are durable.
	for (const identifier of retire) { checkCancelled(); await backups.discardBackup(identifier, token); }
}

async function stageRelocatedBackups(selection: NativeWorkspaceSelection | readonly NativeEditorRelocation[], backups: IWorkingCopyBackupService, token: CancellationToken) {
	const checkCancelled = () => { if (token.isCancellationRequested) { throw new CancellationError(); } };
	const identifiers = await backups.getBackups();
	const retire: Awaited<ReturnType<IWorkingCopyBackupService['getBackups']>> = [];
	for (const identifier of identifiers) {
		checkCancelled();
		// Custom editors use an empty typeId too: their original URI is in the query/meta,
		// not in the vscodeCustomEditor working-copy path. Never acknowledge those as migrated.
		if (identifier.resource.scheme === Schemas.vscodeCustomEditor) {
			const backup = await backups.resolve(identifier);
			if (!backup) { throw new Error('A custom editor backup could not be inspected'); }
			const query = JSON.parse(identifier.resource.query);
			const meta = backup.meta?.editorResource;
			if (!isUriComponents(query) || (meta !== undefined && !isUriComponents(meta))) {
				throw new Error('A custom editor backup resource could not be inspected');
			}
			const queryResource = URI.revive(query);
			const metaResource = isUriComponents(meta) ? URI.revive(meta) : undefined;
			if ([queryResource, metaResource].some(resource => resource && relocateNativeEditorResource(resource, selection).toString() !== resource.toString())) {
				throw new Error('Relocation of dirty custom editor backups is not supported');
			}
		}
		const resource = relocateNativeEditorResource(identifier.resource, selection);
		if (resource.toString() === identifier.resource.toString()) { continue; }
		if (identifier.typeId !== '') { throw new Error('Relocation of this dirty editor backup type is not supported'); }
		const old = await backups.resolve(identifier);
		if (!old) { throw new Error('A relocated dirty editor backup could not be read'); }
		const content = await streamToBuffer(old.value);
		const target = { resource, typeId: identifier.typeId };
		const existing = await backups.resolve(target);
		if (existing) {
			const existingContent = await streamToBuffer(existing.value);
			if (!content.equals(existingContent) || JSON.stringify(old.meta) !== JSON.stringify(existing.meta)) {
				throw new Error('Conflicting dirty editor backups prevent workspace relocation');
			}
		} else {
			checkCancelled();
			await backups.backup(target, bufferToReadable(content), undefined, old.meta, token);
		}
		retire.push(identifier);
	}
	return retire;
}

class RelocationBackupService extends WorkingCopyBackupService {}

/** Migrate the actual target workspace before its editor layout is opened. */
export async function migrateNativeEditorResources(mappings: readonly NativeEditorRelocation[], target: IAnyWorkspaceIdentifier,
	storage: IStorageService, files: IFileService, roamingDataHome: URI, logService: ILogService,
	token: CancellationToken = CancellationToken.None): Promise<void> {
	const selection = validatedRelocations(mappings);
	if (!selection.length) { return; }
	if (!target.id || target.id.length > 8192 || /[\x00-\x1f\x7f/\\]/.test(target.id)) { throw new Error('Invalid relocation workspace identity'); }
	const checkCancelled = () => { if (token.isCancellationRequested) { throw new CancellationError(); } };
	checkCancelled();
	const database = await IndexedDBStorageDatabase.createWorkspaceStorage(target.id, logService);
	const backups = new RelocationBackupService(joinPath(roamingDataHome, 'Backups', target.id), files, logService);
	try {
		if (!(database instanceof IndexedDBStorageDatabase)) { throw new Error('Relocation requires persistent workspace storage'); }
		const active = storage.hasScope(target);
		const keys = ['memento/workbench.parts.editor', 'memento/workbench.editorParts', 'editor.workingSets'];
		const disk = await database.getItems();
		const originals = new Map(keys.map(key => [key, active ? storage.get(key, StorageScope.WORKSPACE) : disk.get(key)]));
		const updates = new Map<string, string>();
		for (const key of keys) {
			const raw = originals.get(key);
			if (raw === undefined) { continue; }
			const state = JSON.parse(raw);
			if (key === 'memento/workbench.parts.editor') { relocateEditorPart(state['editorpart.state'], selection); }
			else if (key === 'memento/workbench.editorParts') { for (const part of state['editorparts.state']?.auxiliary ?? []) { relocateEditorPart(part.state, selection); } }
			else { for (const set of state) { relocateEditorPart(set.main, selection); for (const part of set.auxiliary?.auxiliary ?? []) { relocateEditorPart(part.state, selection); } } }
			const updated = JSON.stringify(state);
			if (updated !== raw) { updates.set(key, updated); }
		}
		const retire = await stageRelocatedBackups(selection, backups, token);
		checkCancelled();
		if (active) {
			for (const [key, value] of updates) { storage.store(key, value, StorageScope.WORKSPACE, StorageTarget.MACHINE); }
			await storage.flush();
		} else {
			const current = await database.getItems();
			if (keys.some(key => current.get(key) !== originals.get(key))) { throw new Error('Workspace layout changed during relocation'); }
			await database.updateItems({ insert: updates });
		}
		const committed = await database.getItems();
		if (keys.some(key => committed.get(key) !== (updates.get(key) ?? originals.get(key)))) { throw new Error('Relocated editor layout has not committed; original backups are retained'); }
		for (const identifier of retire) { checkCancelled(); await backups.discardBackup(identifier, token); }
	} finally { backups.dispose(); await database.close(); database.dispose(); }
}
