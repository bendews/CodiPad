/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad boundary for the upstream local/remote extension-management graph.
 *--------------------------------------------------------------------------------------------*/

import { localize } from '../../nls.js';
import { Schemas } from '../../base/common/network.js';
import { Disposable } from '../../base/common/lifecycle.js';
import { IChannel } from '../../base/parts/ipc/common/ipc.js';
import { IExtension } from '../../platform/extensions/common/extensions.js';
import { IInstantiationService } from '../../platform/instantiation/common/instantiation.js';
import { ILabelService } from '../../platform/label/common/label.js';
import { ExtensionInstallLocation, IExtensionManagementServer, IExtensionManagementServerService } from '../services/extensionManagement/common/extensionManagement.js';
import { NativeRemoteExtensionManagementService } from '../services/extensionManagement/electron-browser/remoteExtensionManagementService.js';
import { IRemoteAgentService } from '../services/remote/common/remoteAgentService.js';
import { BundledExtensionManagementService } from './bundledExtensionManagement.js';

/** Upstream desktop server selection, with the native package store replacing shared-process IPC. */
export class NativeExtensionManagementServerService extends Disposable implements IExtensionManagementServerService {
	declare readonly _serviceBrand: undefined;

	readonly localExtensionManagementServer: IExtensionManagementServer;
	readonly remoteExtensionManagementServer: IExtensionManagementServer | null = null;
	readonly webExtensionManagementServer = null;

	constructor(
		@IInstantiationService instantiationService: IInstantiationService,
		@IRemoteAgentService remoteAgentService: IRemoteAgentService,
		@ILabelService labelService: ILabelService,
	) {
		super();
		const local = this._register(instantiationService.createInstance(BundledExtensionManagementService));
		this.localExtensionManagementServer = { id: 'local', label: localize('local', "Local"), extensionManagementService: local };
		const connection = remoteAgentService.getConnection();
		if (connection) {
			const remote = this._register(instantiationService.createInstance(NativeRemoteExtensionManagementService, connection.getChannel<IChannel>('extensions'), this.localExtensionManagementServer));
			this.remoteExtensionManagementServer = {
				id: 'remote',
				extensionManagementService: remote,
				get label() { return labelService.getHostLabel(Schemas.vscodeRemote, connection.remoteAuthority) || localize('remote', "Remote"); },
			};
		}
	}

	getExtensionManagementServer(extension: IExtension): IExtensionManagementServer {
		if (extension.location.scheme === Schemas.file) {
			return this.localExtensionManagementServer;
		}
		if (extension.location.scheme === Schemas.vscodeRemote && this.remoteExtensionManagementServer) {
			return this.remoteExtensionManagementServer;
		}
		throw new Error(`[codipad-ext-servers] No extension management server for ${extension.location}`);
	}

	getExtensionInstallLocation(extension: IExtension): ExtensionInstallLocation {
		return this.getExtensionManagementServer(extension) === this.remoteExtensionManagementServer ? ExtensionInstallLocation.Remote : ExtensionInstallLocation.Local;
	}
}
