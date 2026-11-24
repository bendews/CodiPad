/*---------------------------------------------------------------------------------------------
 *  The Files picker grants local files and directories. The workbench save dialog
 *  handles filenames and overwrite confirmation within the selected directory.
 *--------------------------------------------------------------------------------------------*/

import { URI } from '../../base/common/uri.js';
import { basename, dirname, joinPath } from '../../base/common/resources.js';
import { Schemas } from '../../base/common/network.js';
import { localize } from '../../nls.js';
import { IPickAndOpenOptions, IOpenDialogOptions, ISaveDialogOptions } from '../../platform/dialogs/common/dialogs.js';
import { WORKSPACE_EXTENSION, hasWorkspaceFileExtension } from '../../platform/workspace/common/workspace.js';
import { AbstractFileDialogService } from '../services/dialogs/browser/abstractFileDialogService.js';
import { callNative } from './nativeBridge.js';

/** Local opening retains the shell's live workspace transition after the workbench starts. */
export interface IpadDialogHost {
	openResource(resource: URI): Promise<void>;
	openFolder(folder: URI): Promise<void>;
}

export class IpadFileDialogService extends AbstractFileDialogService {
	private host: IpadDialogHost | undefined;

	setHost(host: IpadDialogHost): void {
		this.host = host;
	}

	private requireHost(): IpadDialogHost {
		if (!this.host) {
			throw new Error('[codipad-unsupported] file opening requires a started workbench');
		}
		return this.host;
	}

	async showOpenDialog(options: IOpenDialogOptions): Promise<URI[] | undefined> {
		const schema = this.getFileSystemSchema(options);
		if (schema !== Schemas.file) {
			return this.showOpenDialogSimplified(schema, { ...options });
		}
		return this.pickLocal(options);
	}

	private async pickLocal(options: IOpenDialogOptions, newWindow = false): Promise<URI[] | undefined> {
		const selection = await callNative<string[]>('dialog.open', {
			files: options.canSelectFiles !== false,
			folders: !!options.canSelectFolders,
			multiple: !!options.canSelectMany,
			newWindow,
			...(options.defaultUri?.scheme === Schemas.file ? { initialUri: options.defaultUri.toString() } : {}),
			...(options.filters?.length ? { extensions: options.filters.flatMap(filter => filter.extensions) } : {})
		});
		return selection.length ? selection.map(text => {
			const uri = URI.parse(text, true);
			if (uri.scheme !== Schemas.file) {
				throw new Error('[codipad-native] native picker returned a non-file URI');
			}
			return uri;
		}) : undefined;
	}

	async pickFileAndOpen(options: IPickAndOpenOptions): Promise<void> {
		const schema = this.getFileSystemSchema(options);
		if (schema !== Schemas.file) {
			return this.pickFileAndOpenSimplified(schema, { ...options, defaultUri: options.defaultUri ?? await this.defaultFilePath(schema) }, false);
		}
		const host = this.requireHost();
		const [uri] = await this.pickLocal({ ...options, defaultUri: options.defaultUri ?? await this.defaultFilePath(schema), canSelectFiles: true, canSelectFolders: false, canSelectMany: false }, options.forceNewWindow) ?? [];
		if (uri) {
			if (hasWorkspaceFileExtension(uri)) {
				await this.hostService.openWindow([{ workspaceUri: uri }], { forceNewWindow: options.forceNewWindow, remoteAuthority: options.remoteAuthority });
			} else {
				this.addFileToRecentlyOpened(uri);
				await host.openResource(uri);
			}
		}
	}

	async pickFolderAndOpen(options: IPickAndOpenOptions): Promise<void> {
		const schema = this.getFileSystemSchema(options);
		if (schema !== Schemas.file) {
			return this.pickFolderAndOpenSimplified(schema, { ...options, defaultUri: options.defaultUri ?? await this.defaultFolderPath(schema) });
		}
		const host = this.requireHost();
		const [uri] = await this.pickLocal({ ...options, defaultUri: options.defaultUri ?? await this.defaultFolderPath(schema), canSelectFiles: false, canSelectFolders: true, canSelectMany: false }, options.forceNewWindow) ?? [];
		if (uri) {
			await host.openFolder(uri);
		}
	}

	async pickFileFolderAndOpen(options: IPickAndOpenOptions): Promise<void> {
		const schema = this.getFileSystemSchema(options);
		if (schema !== Schemas.file) {
			return this.pickFileFolderAndOpenSimplified(schema, { ...options, defaultUri: options.defaultUri ?? await this.defaultFilePath(schema) }, false);
		}
		const host = this.requireHost();
		const [uri] = await this.pickLocal({ ...options, defaultUri: options.defaultUri ?? await this.defaultFilePath(schema), canSelectFiles: true, canSelectFolders: true, canSelectMany: false }, options.forceNewWindow) ?? [];
		if (uri) {
			if ((await this.fileService.stat(uri)).isDirectory) {
				await host.openFolder(uri);
			} else if (hasWorkspaceFileExtension(uri)) {
				await this.hostService.openWindow([{ workspaceUri: uri }], { forceNewWindow: options.forceNewWindow, remoteAuthority: options.remoteAuthority });
			} else {
				this.addFileToRecentlyOpened(uri);
				await host.openResource(uri);
			}
		}
	}

	async pickWorkspaceAndOpen(options: IPickAndOpenOptions): Promise<void> {
		const availableFileSystems = this.getWorkspaceAvailableFileSystems(options);
		const schema = this.getFileSystemSchema({ ...options, availableFileSystems });
		const defaultUri = options.defaultUri ?? await this.defaultWorkspacePath(schema);
		if (schema !== Schemas.file) {
			return this.pickWorkspaceAndOpenSimplified(schema, { ...options, defaultUri, availableFileSystems });
		}
		const [uri] = await this.pickLocal({ defaultUri, availableFileSystems, canSelectFiles: true, canSelectFolders: false,
			canSelectMany: false, filters: [{ name: localize('filterName.workspace', 'Workspace'), extensions: [WORKSPACE_EXTENSION] }] }, options.forceNewWindow) ?? [];
		if (uri) {
			await this.hostService.openWindow([{ workspaceUri: uri }], { forceNewWindow: options.forceNewWindow, remoteAuthority: options.remoteAuthority });
		}
	}

	// The Files picker supplies authority for a parent, then the standard save
	// dialog handles the filename, extension filters and overwrite confirmation.
	private async saveOptions(options: ISaveDialogOptions, schema: string): Promise<ISaveDialogOptions | undefined> {
		if (schema !== Schemas.file) { return { ...options }; }
		const suggested = options.defaultUri;
		const [folder] = await this.pickLocal({ canSelectFiles: false, canSelectFolders: true,
			defaultUri: suggested ? dirname(suggested) : await this.defaultFolderPath(schema) }) ?? [];
		return folder && { ...options, defaultUri: suggested ? joinPath(folder, basename(suggested)) : folder };
	}

	async showSaveDialog(options: ISaveDialogOptions): Promise<URI | undefined> {
		const schema = this.getFileSystemSchema(options);
		const selection = await this.saveOptions(options, schema);
		return selection && this.confirmSaveDestination(await this.showSaveDialogSimplified(schema, selection));
	}

	async pickFileToSave(defaultUri: URI, availableFileSystems?: string[]): Promise<URI | undefined> {
		const schema = this.getFileSystemSchema({ defaultUri, availableFileSystems });
		const selection = await this.saveOptions(this.getPickFileToSaveDialogOptions(defaultUri, availableFileSystems), schema);
		return selection && this.confirmSaveDestination(await this.pickFileToSaveSimplified(schema, selection));
	}

	private async confirmSaveDestination(uri: URI | undefined): Promise<URI | undefined> {
		if (uri?.scheme === Schemas.file) {
			// A typed destination must already belong to a live native grant, including new files.
			await callNative('documents.acceptSaveTarget', { uri: uri.toString() });
		}
		return uri;
	}
}
