/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench — platform services that are genuinely absent on this build.
 *
 *  Two services are needed by the extension graph but have no real implementation here:
 *    - `IUserDataSyncAccountService`: settings sync is not offered; there is no account and no
 *      network client. A token-bearing call rejects, because accepting one would imply sync works.
 *    - `IExtensionManagementServerService`: there is exactly one extension source, the bundled
 *      catalog. The "local" server points at the same management instance; remote and web servers
 *      are `null`, and asking where a non-catalog extension is installed rejects.
 *
 *  These are statements about capability, not shims: nothing returns a fabricated success.
 *---------------------------------------------------------------------------------------------*/

import { Event } from '../../base/common/event.js';
import { IUserDataSyncAccount, IUserDataSyncAccountService } from '../../platform/userDataSync/common/userDataSyncAccount.js';
import { IUserDataAutoSyncService, IUserDataSyncEnablementService, SyncOptions, SyncResource, UserDataSyncError } from '../../platform/userDataSync/common/userDataSync.js';
import { ExtensionInstallLocation, IExtensionManagementServer, IExtensionManagementServerService } from '../services/extensionManagement/common/extensionManagement.js';
import { IWorkbenchExtensionManagementService } from '../services/extensionManagement/common/extensionManagement.js';
import { IExtension } from '../../platform/extensions/common/extensions.js';

const SYNC_REASON = 'settings sync is not available on iPad: no account service, no sync client';

export class DisabledUserDataSyncAccountService implements IUserDataSyncAccountService {

	declare readonly _serviceBrand: undefined;

	readonly onTokenFailed = Event.None as Event<boolean>;
	readonly onDidChangeAccount = Event.None as Event<IUserDataSyncAccount | undefined>;
	readonly account = undefined;

	/** `undefined` means "no account"; that is truthful and changes nothing. */
	async updateAccount(account: IUserDataSyncAccount | undefined): Promise<void> {
		if (account === undefined) {
			return;
		}

		throw new Error(`[codipad-sync] updateAccount: ${SYNC_REASON}`);
	}
}

/**
 * Settings sync is off and stays off: every resource is disabled, the state cannot be toggled, and
 * an attempt to enable is rejected instead of silently flipping a flag nothing implements.
 */
export class DisabledUserDataSyncEnablementService implements IUserDataSyncEnablementService {

	declare readonly _serviceBrand: undefined;

	readonly onDidChangeEnablement = Event.None as Event<boolean>;
	readonly onDidChangeResourceEnablement = Event.None as Event<[SyncResource, boolean]>;

	isEnabled(): boolean {
		return false;
	}

	canToggleEnablement(): boolean {
		return false; // no sync client to turn on
	}

	setEnablement(enabled: boolean): void {
		if (enabled) {
			throw new Error(`[codipad-sync] setEnablement: ${SYNC_REASON}`);
		}
		// already disabled: truthful no-op
	}

	isResourceEnabled(_resource: SyncResource, _defaultValue?: boolean): boolean {
		return false;
	}

	setResourceEnablement(resource: SyncResource, enabled: boolean): void {
		if (enabled) {
			throw new Error(`[codipad-sync] setResourceEnablement(${resource}): ${SYNC_REASON}`);
		}
	}

	getResourceSyncStateVersion(_resource: SyncResource): string | undefined {
		return undefined; // never synced, so no version exists
	}

	isResourceEnablementConfigured(_resource: SyncResource): boolean {
		return false;
	}
}

/**
 * Auto sync is disabled: there is no sync client. Activity hints schedule nothing, matching
 * upstream when auto sync is absent. Explicit attempts to turn sync on still reject.
 */
export class DisabledUserDataAutoSyncService implements IUserDataAutoSyncService {

	declare readonly _serviceBrand: undefined;

	readonly onError = Event.None as Event<UserDataSyncError>;

	async turnOn(): Promise<void> {
		throw new Error(`[codipad-sync] turnOn: ${SYNC_REASON}`);
	}

	async turnOff(_everywhere: boolean): Promise<void> {
		// already off: truthful no-op
	}

	async triggerSync(_sources: string[], _options?: SyncOptions): Promise<void> {
		// Upstream resolves activity hints without syncing when autoSync.value is undefined.
	}
}

export class BundledExtensionManagementServerService implements IExtensionManagementServerService {

	declare readonly _serviceBrand: undefined;

	readonly localExtensionManagementServer: IExtensionManagementServer;
	readonly remoteExtensionManagementServer = null;
	readonly webExtensionManagementServer = null;

	constructor(@IWorkbenchExtensionManagementService private readonly _management: IWorkbenchExtensionManagementService) {
		this.localExtensionManagementServer = {
			id: 'local',
			label: 'CodiPad (native extensions)',
			extensionManagementService: _management,
		};
	}

	/** Bundled and installed catalog extensions belong to the local server. */
	getExtensionManagementServer(extension: IExtension): IExtensionManagementServer | null {
		if (extension.isBuiltin || extension.location.scheme === 'file') {
			return this.localExtensionManagementServer;
		}

		throw new Error(`[codipad-ext-servers] getExtensionManagementServer: no server for ${extension.identifier.id} (bundled extensions only)`);
	}

	getExtensionInstallLocation(extension: IExtension): ExtensionInstallLocation | null {
		if (extension.isBuiltin || extension.location.scheme === 'file') {
			return ExtensionInstallLocation.Local;
		}

		throw new Error(`[codipad-ext-servers] getExtensionInstallLocation: no install location for ${extension.identifier.id}`);
	}
}
