/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See workbench/notices/VSCODE-LICENSE.txt for license information.
 *
 *  CodiPad iPad workbench — extension service backed by the native Node extension host.
 *
 *  `AbstractExtensionService` owns activation, delta handling, status and lifecycle; this file
 *  supplies the three abstract methods, a factory for native, worker and remote hosts, and the
 *  pinned desktop host-selection policy.
 *  The upstream remote host owns its connection and protocol; only the local process boundary
 *  uses the native adapter. Browser platform flags remain unchanged.
 *---------------------------------------------------------------------------------------------*/

import { Action2, registerAction2 } from '../../platform/actions/common/actions.js';
import { Categories } from '../../platform/action/common/actionCommonCategories.js';
import { ServicesAccessor } from '../../platform/instantiation/common/instantiation.js';
import { localize, localize2 } from '../../nls.js';
import { IInstantiationService } from '../../platform/instantiation/common/instantiation.js';
import { INotificationService, Severity } from '../../platform/notification/common/notification.js';
import { ITelemetryService } from '../../platform/telemetry/common/telemetry.js';
import { IFileService } from '../../platform/files/common/files.js';
import { IProductService } from '../../platform/product/common/productService.js';
import { Schemas } from '../../base/common/network.js';
import { URI } from '../../base/common/uri.js';
import { IWorkspaceTrustManagementService } from '../../platform/workspace/common/workspaceTrust.js';
import { IWorkspaceContextService, WorkbenchState } from '../../platform/workspace/common/workspace.js';
import { IConfigurationService } from '../../platform/configuration/common/configuration.js';
import { ILogService, LogLevel } from '../../platform/log/common/log.js';
import { ILifecycleService, LifecyclePhase } from '../services/lifecycle/common/lifecycle.js';
import { IRemoteAgentService } from '../services/remote/common/remoteAgentService.js';
import { IRemoteExtensionsScannerService } from '../../platform/remote/common/remoteExtensionsScanner.js';
import { IRemoteAuthorityResolverService, RemoteAuthorityResolverError, RemoteAuthorityResolverErrorCode, RemoteConnectionType, ResolverResult, getRemoteAuthorityPrefix } from '../../platform/remote/common/remoteAuthorityResolver.js';
import { PersistentConnectionEventType } from '../../platform/remote/common/remoteAgentConnection.js';
import { isLoopbackHost, parseAuthorityWithPort } from '../../platform/remote/common/remoteHosts.js';
import { updateProxyConfigurationsScope } from '../../platform/request/common/request.js';
import { IRemoteExplorerService } from '../services/remote/common/remoteExplorerService.js';
import { RemoteExtensionHost } from '../services/extensions/common/remoteExtensionHost.js';
import { WebWorkerExtensionHost } from '../services/extensions/browser/webWorkerExtensionHost.js';
import { IDialogService } from '../../platform/dialogs/common/dialogs.js';
import { IWorkbenchExtensionEnablementService, IWorkbenchExtensionManagementService } from '../services/extensionManagement/common/extensionManagement.js';
import { IExtensionManifestPropertiesService } from '../services/extensions/common/extensionManifestPropertiesService.js';
import { ExtensionsProposedApi } from '../services/extensions/common/extensionsProposedApi.js';
import { AbstractExtensionService, checkEnabledAndProposedAPI, IExtensionHostFactory, LocalExtensions, RemoteExtensions, ResolverExtensions, ResolvedExtensions, isResolverExtension } from '../services/extensions/common/abstractExtensionService.js';
import { ExtensionHostKind } from '../services/extensions/common/extensionHostKind.js';
import { ExtensionRunningLocation } from '../services/extensions/common/extensionRunningLocation.js';
import { ExtensionRunningLocationTracker, filterExtensionDescriptions } from '../services/extensions/common/extensionRunningLocationTracker.js';
import { ExtensionDescriptionRegistrySnapshot } from '../services/extensions/common/extensionDescriptionRegistry.js';
import { ExtensionHostExtensions, ExtensionHostStartup, IExtensionHost, IExtensionService, WebWorkerExtHostConfigValue, webWorkerExtHostConfig } from '../services/extensions/common/extensions.js';
import { IExtensionDescription } from '../../platform/extensions/common/extensions.js';
import { IExtensionResourceLoaderService } from '../../platform/extensionResourceLoader/common/extensionResourceLoader.js';
import { IExtensionHostInitData, IStaticWorkspaceData, UIKind } from '../services/extensions/common/extensionHostProtocol.js';
import { IWorkbenchEnvironmentService } from '../services/environment/common/environmentService.js';
import { IpadExtensionHostKindPicker } from './nativeRemoteExtensionHostKindPicker.js';
import { NativeExtensionHost, createNativeTransport } from './nativeExtensionHost.js';
import { callNative } from './nativeBridge.js';
import { IExtensionsScannerService } from '../../platform/extensionManagement/common/extensionsScannerService.js';
import { NativeExtensionsScannerService } from './nativeExtensionsScannerService.js';
import { bootStep, bootWarn } from './boot.js';

interface ExtensionSelection {
	readonly all: IExtensionDescription[];
	readonly runnable: IExtensionDescription[];
}

/** Init-data inputs. The extension set and versionId come from the base service's authoritative
 *  registry snapshot (or the initial scanned/enabled allocation), never from a local counter. */
interface NativeHostSeed {
	readonly extensions: ReturnType<ExtensionHostExtensions['toSnapshot']>;
	readonly workspace: IStaticWorkspaceData | undefined;
	readonly homes: import('./nativeExtensionCatalog.js').NativeExtensionHomes;
}

export class NativeExtensionHostFactory implements IExtensionHostFactory {

	constructor(
		private readonly _deps: {
			readonly getSnapshot: () => Promise<ExtensionDescriptionRegistrySnapshot>;
			readonly selectEnabled: () => Promise<IExtensionDescription[]>;
			readonly workspace: () => IStaticWorkspaceData | undefined;
			readonly homes: () => Promise<import('./nativeExtensionCatalog.js').NativeExtensionHomes>;
		},
		private readonly _productService: IProductService,
		private readonly _instantiationService: IInstantiationService,
		private readonly _remoteAgentService: IRemoteAgentService,
		private readonly _remoteAuthorityResolverService: IRemoteAuthorityResolverService,
		private readonly _environmentService: IWorkbenchEnvironmentService,
		private readonly _webWorkerStartup: ExtensionHostStartup | null = null
	) { }

	createExtensionHost(runningLocations: ExtensionRunningLocationTracker, runningLocation: ExtensionRunningLocation, isInitialStart: boolean): IExtensionHost | null {
		if (runningLocation.kind === ExtensionHostKind.LocalWebWorker) {
			return this._webWorkerStartup === null ? null : this._instantiationService.createInstance(WebWorkerExtensionHost, runningLocation, this._webWorkerStartup, {
				getInitData: async () => {

					const snapshot = await this._deps.getSnapshot();

					const mine = runningLocations.filterByRunningLocation(snapshot.extensions, runningLocation);
					return { extensions: new ExtensionHostExtensions(snapshot.versionId, snapshot.extensions, mine.map(extension => extension.identifier)) };
				}
			});
		}
		if (runningLocation.kind === ExtensionHostKind.Remote) {
			const connection = this._remoteAgentService.getConnection();
			return connection ? this._instantiationService.createInstance(RemoteExtensionHost, runningLocation, {
				remoteAuthority: connection.remoteAuthority,
				getInitData: async () => {

					const snapshot = await this._deps.getSnapshot();


					const environment = await this._remoteAgentService.getEnvironment();

					if (!environment) {
						throw new Error('Cannot provide init data for remote extension host');
					}
					const mine = runningLocations.filterByExtensionHostKind(snapshot.extensions, ExtensionHostKind.Remote);
					return {
						connectionData: this._remoteAuthorityResolverService.getConnectionData(connection.remoteAuthority),
						pid: environment.pid,
						appRoot: environment.appRoot,
						extensionHostLogsPath: environment.extensionHostLogsPath,
						globalStorageHome: environment.globalStorageHome,
						workspaceStorageHome: environment.workspaceStorageHome,
						extensions: new ExtensionHostExtensions(snapshot.versionId, snapshot.extensions, mine.map(extension => extension.identifier)),
					};
				}
			}) : null;
		}
		if (runningLocation.kind !== ExtensionHostKind.LocalProcess) {
			return null;
		}

		const startup = isInitialStart ? ExtensionHostStartup.EagerManualStart : ExtensionHostStartup.EagerAutoStart;

		return new NativeExtensionHost(runningLocation, startup, async () => this.buildInitData(
			await this.buildSeed(runningLocations, runningLocation, isInitialStart), startup
		), createNativeTransport(this._environmentService.remoteAuthority ? 'remote' : this._deps.workspace() ? 'native' : 'empty'));
	}

	/**
	 * Mirrors upstream `NativeExtensionHostFactory` (`nativeExtensionService.ts:596-627`):
	 *   initial -> scanned/enabled set, `computeRunningLocation`, `ExtensionHostExtensions(0, …)`
	 *   restart -> `_getExtensionRegistrySnapshotWhenReady()` versionId + `filterByRunningLocation`
	 * so a restart never carries a version id we invented and never disagrees with the registry.
	 */
	private async buildSeed(runningLocations: ExtensionRunningLocationTracker, runningLocation: ExtensionRunningLocation, isInitialStart: boolean): Promise<NativeHostSeed> {

		const homesPromise = this._deps.homes();
		if (isInitialStart) {

			const [homes, localExtensions] = await Promise.all([homesPromise, this._deps.selectEnabled()]);

			const computed = runningLocations.computeRunningLocation(localExtensions, [], false);
			const myExtensions = filterExtensionDescriptions(localExtensions, computed, extRunningLocation => runningLocation.equals(extRunningLocation));
			const extensions = new ExtensionHostExtensions(0, localExtensions, myExtensions.map(extension => extension.identifier));

			return { extensions: extensions.toSnapshot(), workspace: this._deps.workspace(), homes };
		}

		const [homes, snapshot] = await Promise.all([homesPromise, this._deps.getSnapshot()]);

		const myExtensions = runningLocations.filterByRunningLocation(snapshot.extensions, runningLocation);
		const extensions = new ExtensionHostExtensions(snapshot.versionId, snapshot.extensions, myExtensions.map(extension => extension.identifier));

		return { extensions: extensions.toSnapshot(), workspace: this._deps.workspace(), homes };
	}

	/**
	 * `IExtensionHostInitData` assembled with upstream types: `ExtensionHostExtensions.toSnapshot()`
	 * produces `versionId`, `allExtensions`, `myExtensions` (ExtensionIdentifier[]) and the implicit
	 * activation-event map, so no hand-written activationEvents array is needed.
	 */
	buildInitData(seed: NativeHostSeed, startup: ExtensionHostStartup): IExtensionHostInitData {
		const snapshot = seed.extensions;

		return {
			version: this._productService.version,
			quality: this._productService.quality,
			commit: this._productService.commit,
			date: this._productService.date,
			parentPid: 0,
			environment: {
				isExtensionDevelopmentDebug: false,
				appName: this._productService.nameLong,
				appHost: 'ipad',
				appRoot: seed.homes.appRoot,
				appLanguage: 'en',
				isExtensionTelemetryLoggingOnly: false,
				appUriScheme: this._productService.urlProtocol,
				globalStorageHome: seed.homes.globalStorageHome,
				workspaceStorageHome: seed.homes.workspaceStorageHome,
			},
			workspace: seed.workspace,
			extensions: snapshot,
			telemetryInfo: { sessionId: '', machineId: '', sqmId: '', devDeviceId: '', firstSessionDate: '' },
			logLevel: LogLevel.Info,
			loggers: [],
			logsLocation: seed.homes.logsLocation,
			autoStart: startup === ExtensionHostStartup.EagerAutoStart,
			remote: { isRemote: false, authority: this._environmentService.remoteAuthority, connectionData: this._environmentService.remoteAuthority ? this._remoteAuthorityResolverService.getConnectionData(this._environmentService.remoteAuthority) : null },
			consoleForward: { includeStack: true, logNative: false },
			uiKind: UIKind.Desktop,
		};
	}

	dispose(): void { /* hosts dispose themselves with the service */ }
}

class RestartExtensionHostAction extends Action2 {

	constructor() {
		super({
			id: 'workbench.action.restartExtensionHost',
			title: localize2('restartExtensionHost', "Restart Extension Host"),
			category: Categories.Developer,
			f1: true
		});
	}

	async run(accessor: ServicesAccessor): Promise<void> {
		const extensionService = accessor.get(IExtensionService);

		const stopped = await extensionService.stopExtensionHosts(localize('restartExtensionHost.reason', "An explicit request"));
		if (stopped) {
			extensionService.startExtensionHosts();
		}
	}
}

registerAction2(RestartExtensionHostAction);

export class NativeIpadExtensionService extends AbstractExtensionService implements IExtensionService {
	private _descriptionsInFlight: Promise<IExtensionDescription[]> | undefined;
	private _descriptionCache: { key: string; descriptions: IExtensionDescription[] } | undefined;
	private _descriptionRevision = 0;

	private readonly _nativeProposedApi: ExtensionsProposedApi;
	private readonly _enablement: IWorkbenchExtensionEnablementService;
	private readonly _hasWebWorkerExtHost: boolean;

	constructor(
		@IInstantiationService instantiationService: IInstantiationService,
		@INotificationService notificationService: INotificationService,
		@IWorkbenchEnvironmentService environmentService: IWorkbenchEnvironmentService,
		@ITelemetryService telemetryService: ITelemetryService,
		@IWorkbenchExtensionEnablementService extensionEnablementService: IWorkbenchExtensionEnablementService,
		@IFileService fileService: IFileService,
		@IProductService productService: IProductService,
		@IWorkbenchExtensionManagementService extensionManagementService: IWorkbenchExtensionManagementService,
		@IWorkspaceContextService contextService: IWorkspaceContextService,
		@IConfigurationService configurationService: IConfigurationService,
		@IExtensionManifestPropertiesService extensionManifestPropertiesService: IExtensionManifestPropertiesService,
		@ILogService logService: ILogService,
		@IRemoteAgentService remoteAgentService: IRemoteAgentService,
		@IRemoteExtensionsScannerService remoteExtensionsScannerService: IRemoteExtensionsScannerService,
		@ILifecycleService lifecycleService: ILifecycleService,
		@IRemoteAuthorityResolverService remoteAuthorityResolverService: IRemoteAuthorityResolverService,
		@IDialogService dialogService: IDialogService,
		@IExtensionResourceLoaderService _extensionResourceLoaderService: IExtensionResourceLoaderService,
		@IWorkspaceTrustManagementService private readonly _workspaceTrustManagementService: IWorkspaceTrustManagementService,
		@IRemoteExplorerService private readonly _remoteExplorerService: IRemoteExplorerService,
		@IExtensionsScannerService private readonly _nativeScanner: NativeExtensionsScannerService
	) {
		const extensionsProposedApi = instantiationService.createInstance(ExtensionsProposedApi);
		const descriptions = () => this.descriptions();
		const webWorkerStartup = localWebWorkerStartup(environmentService, configurationService);

		super(
			{ hasLocalProcess: true, allowRemoteExtensionsInLocalWebWorker: false },
			extensionsProposedApi,
			new NativeExtensionHostFactory(
				{
					getSnapshot: () => this._getExtensionRegistrySnapshotWhenReady(),
					selectEnabled: async () => checkEnabledAndProposedAPI(logService, extensionEnablementService, extensionsProposedApi, await descriptions(), true),
					workspace: () => this.workspaceFor(contextService),
					homes: () => this._nativeScanner.nativeHomes(),
				},
				productService, instantiationService, remoteAgentService, remoteAuthorityResolverService, environmentService, webWorkerStartup
			),
			new IpadExtensionHostKindPicker(!!environmentService.remoteAuthority, webWorkerStartup !== null),
			instantiationService,
			notificationService,
			environmentService,
			telemetryService,
			extensionEnablementService,
			fileService,
			productService,
			extensionManagementService,
			contextService,
			configurationService,
			extensionManifestPropertiesService,
			logService,
			remoteAgentService,
			remoteExtensionsScannerService,
			lifecycleService,
			remoteAuthorityResolverService,
			dialogService
		);

		this._nativeProposedApi = extensionsProposedApi;
		this._enablement = extensionEnablementService;
		this._hasWebWorkerExtHost = webWorkerStartup !== null;
		const invalidateScan = () => { this._descriptionRevision++; this._descriptionsInFlight = undefined; this._descriptionCache = undefined; };
		this._register(extensionManagementService.onInstallExtension(invalidateScan));
		this._register(extensionManagementService.onProfileAwareDidInstallExtensions(invalidateScan));
		this._register(extensionManagementService.onUninstallExtension(invalidateScan));
		this._register(extensionManagementService.onProfileAwareDidUninstallExtension(invalidateScan));
		this._register(extensionManagementService.onProfileAwareDidUpdateExtensionMetadata(invalidateScan));
		this._register(extensionManagementService.onDidChangeProfile(invalidateScan));
		const publishRegistry = () => {
			const uris = new Set(this.extensions.filter(extension => extension.extensionLocation.scheme === 'file')
				.map(extension => extension.extensionLocation.toString()));
			void callNative('extension.registeredPackages', { uris: [...uris] }).catch(error => logService.error(error));
		};
		this._register(this.onDidRegisterExtensions(publishRegistry));
		this._register(this.onDidChangeExtensions(publishRegistry));

		// Same deferral as the desktop service: scan/start once the workbench is Ready.
		lifecycleService.when(LifecyclePhase.Ready).then(() => {
			void this._initializeIfNeeded();
		});
	}

	/** Host init data consumes the authoritative current-profile scan. */
	descriptions(): Promise<IExtensionDescription[]> {
		if (this._descriptionsInFlight) { return this._descriptionsInFlight; }
		const revision = this._descriptionRevision;
		let scan!: Promise<IExtensionDescription[]>;
		scan = (async () => {
			const key = await this._nativeScanner.descriptionKey();
			if (revision !== this._descriptionRevision) { return this.descriptions(); }
			if (key !== undefined && this._descriptionCache?.key === key) { return this._descriptionCache.descriptions; }
			const result = await this._nativeScanner.descriptions();
			const finalKey = await this._nativeScanner.descriptionKey();
			if (revision !== this._descriptionRevision || key !== finalKey) {
				if (this._descriptionsInFlight === scan) { this._descriptionsInFlight = undefined; }
				return this.descriptions();
			}
			if (key !== undefined) { this._descriptionCache = { key, descriptions: result }; }
			return result;
		})().catch(error => {
			this._descriptionCache = undefined;
			bootWarn('extension-catalog', error instanceof Error ? error.message : String(error));
			throw error;
		});
		this._descriptionsInFlight = scan;
		void scan.finally(() => {
			if (this._descriptionsInFlight === scan) { this._descriptionsInFlight = undefined; }
		}).catch(() => {});
		return scan;
	}

	/** No hardcoded workspace: an empty workbench reports no workspace, a folder reports its own. */
	private workspaceFor(contextService: IWorkspaceContextService): IStaticWorkspaceData | undefined {
		if (contextService.getWorkbenchState() === WorkbenchState.EMPTY) {
			return undefined;
		}
		const workspace = contextService.getWorkspace();

		return {
			id: workspace.id,
			name: workspace.folders[0]?.name ?? '',
			transient: false,
		};
	}

	protected async *_resolveExtensions(): AsyncIterable<ResolvedExtensions> {
		const remoteAuthority = this._environmentService.remoteAuthority;
		let remoteExtensions: IExtensionDescription[] = [];
		if (remoteAuthority) {
			this._remoteAuthorityResolverService._setCanonicalURIProvider(uri => uri.scheme === Schemas.vscodeRemote && uri.authority === remoteAuthority ? this.getCanonicalURI(remoteAuthority, uri) : Promise.resolve(uri));
			await this._workspaceTrustManagementService.workspaceResolved;

			const resolvers = (await this.descriptions()).filter(isResolverExtension);

			if (resolvers.length) {
				yield new ResolverExtensions(resolvers);
			}

			try {
				const result = await this._resolveAuthorityInitial(remoteAuthority);
				this._remoteAuthorityResolverService._setResolvedAuthority(result.authority, result.options);
				this._remoteExplorerService.setTunnelInformation(result.tunnelInformation);
				const connection = this._remoteAgentService.getConnection();
				if (connection) {
					this._register(connection.onDidStateChange(event => {
						if (event.type === PersistentConnectionEventType.ConnectionLost) {
							this._remoteAuthorityResolverService._clearResolvedAuthority(remoteAuthority);
						}
					}));
					this._register(connection.onReconnecting(() => this._resolveAuthorityAgain()));
				}

				const [environment, extensions] = await Promise.all([
					this._remoteAgentService.getRawEnvironment(),
					this._remoteExtensionsScannerService.scanExtensions(),
				]);
				if (!environment) {
					throw new Error('Could not fetch remote extension-host environment');
				}
				this._register(this._configurationService.onDidChangeConfiguration(event => {
					if (event.affectsConfiguration('http.useLocalProxyConfiguration')) {
						updateProxyConfigurationsScope(this._configurationService.getValue('http.useLocalProxyConfiguration'), environment.useHostProxy);
					}
				}));
				updateProxyConfigurationsScope(this._configurationService.getValue('http.useLocalProxyConfiguration'), environment.useHostProxy);
				remoteExtensions = extensions;
			} catch (error) {
				this._logService.error('Remote extension host resolution failed', error);
				this._remoteAuthorityResolverService._setResolvedAuthorityError(remoteAuthority, error);
				if (!RemoteAuthorityResolverError.isHandled(error)) {
					this._notificationService.error(error instanceof Error ? error : String(error));
				}
			}
		} else {
			this._remoteAuthorityResolverService._setCanonicalURIProvider(async uri => uri);
		}

		await this._workspaceTrustManagementService.workspaceTrustInitialized;

		if (remoteExtensions.length) {
			yield new RemoteExtensions(remoteExtensions);
		}
		const selection = await this.selectExtensions();
		bootStep('extension-catalog', `${selection.all.length} local, ${selection.runnable.length} locally runnable`);
		yield new LocalExtensions(selection.all);
	}

	private async getCanonicalURI(authority: string, uri: URI): Promise<URI> {
		if (!authority.includes('+')) {
			return uri;
		}
		const results = await Promise.all(this._getExtensionHostManagers(ExtensionHostKind.LocalProcess).map(host => host.getCanonicalURI(authority, uri)));
		const result = results.find(candidate => candidate !== null);
		if (!result) {
			throw new Error(`No extension can canonicalize remote authority ${getRemoteAuthorityPrefix(authority)}`);
		}
		return result;
	}

	/** Single source of truth: enablement + web-only filtering, shared by registry and init data. */

	private async selectExtensions(): Promise<ExtensionSelection> {
		const descriptions = await this.descriptions();
		const enabled = checkEnabledAndProposedAPI(this._logService, this._enablement, this._nativeProposedApi, descriptions, false);
		const runnable = enabled.filter(extension => {
			const declared = extension.extensionKind;
			const kinds = Array.isArray(declared) ? declared : declared ? [declared] : [];

			return this._hasWebWorkerExtHost || !(kinds.length > 0 && kinds.every(kind => kind === 'web'));
		});
		if (runnable.length !== enabled.length) {
			bootWarn('extension-selection', `${enabled.length - runnable.length} web-only extension(s) have no host in this composition`);
		}
		return { all: enabled, runnable };
	}

	async resolveExtensionResourceUri(uri: URI): Promise<URI | undefined> {
		if (uri.scheme !== Schemas.file) {
			return undefined;
		}
		if ((globalThis as typeof globalThis & { __codipadExtensionWorkerHostReady?: boolean }).__codipadExtensionWorkerHostReady !== true) {
			throw new Error('[codipad-unsupported] native extension browser resources are not ready');
		}
		const workbench = new URL(globalThis._VSCODE_FILE_ROOT);
		if (workbench.protocol !== 'http:' || !['127.0.0.1', '[::1]'].includes(workbench.hostname)
			|| workbench.origin !== globalThis.origin || workbench.username || workbench.password) {
			throw new Error('[codipad-unsupported] extension resources require the loopback workbench origin');
		}
		const response = await callNative<{ uri?: unknown }>('extension.resolveBrowserResource', { uri: uri.toString() });
		if (!response || typeof response.uri !== 'string') {
			throw new Error('Invalid native extension resource URI');
		}
		const resolved = new URL(response.uri);
		if (resolved.protocol !== 'http:' || resolved.origin !== workbench.origin || resolved.username || resolved.password) {
			throw new Error('Native extension resource URI is outside the loopback workbench origin');
		}
		return URI.parse(resolved.href, true);
	}

	protected async _onExtensionHostExit(code: number): Promise<void> {
		bootWarn('extension-host-exit', `native extension host exited with code ${code}`);
	}

	protected async _resolveAuthority(remoteAuthority: string): Promise<ResolverResult> {
		if (remoteAuthority.includes('+')) {
			return this._resolveAuthorityOnExtensionHosts(ExtensionHostKind.LocalProcess, remoteAuthority);
		}
		const { host, port } = parseAuthorityWithPort(remoteAuthority);
		if (!isLoopbackHost(host)) {
			const { confirmed } = await this._dialogService.confirm({
				type: Severity.Warning,
				message: localize('remoteConnectionConfirm', "Allow connecting to the remote server '{0}:{1}'?", host, port),
				detail: localize('remoteConnectionConfirmDetail', "Only continue if you trust this server. It will be able to run code and access files on your behalf."),
				primaryButton: localize('remoteConnectionConfirmButton', "Connect"),
			});
			if (!confirmed) {
				throw new RemoteAuthorityResolverError('Remote server connection was not allowed', RemoteAuthorityResolverErrorCode.NotAvailable);
			}
		}
		return { authority: { authority: remoteAuthority, connectTo: { type: RemoteConnectionType.WebSocket, host, port }, connectionToken: undefined } };
	}
}

/** Same eager/lazy/disabled policy as the pinned desktop extension host factory. */
function localWebWorkerStartup(environmentService: IWorkbenchEnvironmentService, configurationService: IConfigurationService): ExtensionHostStartup | null {
	// The shell enables admission only after the worker assets and native resource boundary exist.
	if ((globalThis as typeof globalThis & { __codipadExtensionWorkerHostReady?: boolean }).__codipadExtensionWorkerHostReady !== true) {
		return null;
	}
	if (environmentService.isExtensionDevelopment && environmentService.extensionDevelopmentKind?.some(kind => kind === 'web')) {
		return ExtensionHostStartup.EagerManualStart;
	}
	const config = configurationService.getValue<WebWorkerExtHostConfigValue>(webWorkerExtHostConfig);
	return config === true ? ExtensionHostStartup.EagerManualStart : config === 'auto' ? ExtensionHostStartup.LazyAutoStart : null;
}
