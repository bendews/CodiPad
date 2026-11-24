import { registerNativeWindowServices, registerNativeCatalogServices } from './nativeSharedServices.js';
/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench bootstrap.
 *
 *  Reuses pinned desktop/common VS Code contributions in WKWebView. Native services provide
 *  filesystem grants, the local process boundary, Keychain, and isolated webview origins.
 *  iSH supplies the local Linux execution environment; an optional remote authority retains
 *  upstream remote filesystem, terminal, extension-host, and connection routing.
 *  Platform flags are unchanged. Failed initialization propagates to the shell.
 *--------------------------------------------------------------------------------------------*/

import './ipadInput.css';
import { Disposable, DisposableStore, isDisposable, toDisposable } from '../../base/common/lifecycle.js';
import { CancellationTokenSource } from '../../base/common/cancellation.js';
import { URI } from '../../base/common/uri.js';
import { removeTrailingPathSeparator } from '../../base/common/resources.js';
import { Schemas } from '../../base/common/network.js';
import { domContentLoaded, getWindow } from '../../base/browser/dom.js';
import { registerNativeViewportLayout } from './nativeViewportLayout.js';
import { ServiceCollection } from '../../platform/instantiation/common/serviceCollection.js';
import { SyncDescriptor } from '../../platform/instantiation/common/descriptors.js';
import { IEditorService } from '../services/editor/common/editorService.js';
import { IEditorGroupsService } from '../services/editor/common/editorGroupsService.js';
import { ILifecycleService } from '../services/lifecycle/common/lifecycle.js';
import { IWorkingCopyService } from '../services/workingCopy/common/workingCopyService.js';
import { NativeOpenDocuments, restoreOpenDocumentAuthorities } from './nativeOpenDocuments.js';
import { EditorsOrder } from '../common/editor.js';
import { IContextKeyService } from '../../platform/contextkey/common/contextkey.js';
import { ISandboxHelperService } from '../../platform/sandbox/common/sandboxHelperService.js';
import { OpenFolderWorkspaceSupportContext } from '../common/contextkeys.js';
import { callNative, isNativeAvailable } from './nativeBridge.js';
import { AbstractPathService, IPathService } from '../services/path/common/pathService.js';
import { NativeRemoteWorkspaceProvider, NativeLocalWorkspaceSelection, NativeWorkspaceFileSelection, parseNativeWorkspaceSelection, parseNativeLocalWorkspaceSelection, identifyNativeWorkspaceFile, commitNativeWorkspaceFile, cancelNativeWorkspaceFile, resolveNativeWorkspaceFolders, restoreRelocatedNativeEditors, remoteWorkspaceSceneStorage, sceneWorkspaceIdentifier } from './nativeRemoteWorkspace.js';
import './nativeRemoteActions.js';
import { IOpenerService } from '../../platform/opener/common/opener.js';
import { NativeExternalOpener } from './nativeExternalOpener.js';
import { ServiceIdentifier } from '../../platform/instantiation/common/instantiation.js';
import { IInstantiationService } from '../../platform/instantiation/common/instantiation.js';
import { IAccessibilityService } from '../../platform/accessibility/common/accessibility.js';
import { AccessibilityService } from '../../platform/accessibility/browser/accessibilityService.js';
import { IContextMenuService } from '../../platform/contextview/browser/contextView.js';
import { ContextMenuService } from '../../platform/contextview/browser/contextMenuService.js';
import { ITitleService } from '../services/title/browser/titleService.js';
import { BrowserTitleService } from '../browser/parts/titlebar/titlebarPart.js';
import { ITimerService, TimerService } from '../services/timer/browser/timerService.js';
import { ILanguagePackService } from '../../platform/languagePacks/common/languagePacks.js';
import { WebLanguagePacksService } from '../../platform/languagePacks/browser/languagePacks.js';
import { ICustomEndpointTelemetryService } from '../../platform/telemetry/common/telemetry.js';
import { NullEndpointTelemetryService, NullTelemetryServiceShape } from '../../platform/telemetry/common/telemetryUtils.js';
import { IDiagnosticsService, NullDiagnosticsService } from '../../platform/diagnostics/common/diagnostics.js';
import { IWebContentExtractorService, NullWebContentExtractorService, ISharedWebContentExtractorService, NullSharedWebContentExtractorService } from '../../platform/webContentExtractor/common/webContentExtractor.js';
import { ITelemetryService } from '../../platform/telemetry/common/telemetry.js';
import { InstantiationType, registerSingleton } from '../../platform/instantiation/common/extensions.js';
import { IProductService } from '../../platform/product/common/productService.js';
import product from '../../platform/product/common/product.js';
import { IFileService } from '../../platform/files/common/files.js';
import { FileService } from '../../platform/files/common/fileService.js';
import { InMemoryFileSystemProvider } from '../../platform/files/common/inMemoryFilesystemProvider.js';
import { IndexedDB } from '../../base/browser/indexedDB.js';
import { IndexedDBFileSystemProvider } from '../../platform/files/browser/indexedDBFileSystemProvider.js';
import { IUserDataInitializationService, UserDataInitializationService } from '../services/userData/browser/userDataInit.js';
// Metered-connection service, browser variant (self-registering via registerSingleton): the
// extensions workbench service reads it to decide on automatic downloads. iPad ships no downloads,
// but the service itself is genuine upstream browser code, so it is imported rather than stubbed.
import '../../platform/meteredConnection/browser/meteredConnectionService.js';

// Self-registering browser implementation (registerSingleton at file end), used by the markdown
// renderer and webview layer to load extension-provided resources. No remote server involved.
import '../../platform/extensionResourceLoader/browser/extensionResourceLoaderService.js';
// Gallery manifest service, browser variant: reads product.json's gallery config and does nothing
// when no remote connection exists. It does not install anything; the native-side extension
// pipeline is a separate, later concern.
import '../services/extensionManagement/browser/extensionGalleryManifestService.js';
import { IMcpGalleryManifestService } from '../../platform/mcp/common/mcpGalleryManifest.js';
import { WorkbenchMcpGalleryManifestService } from '../services/mcp/browser/mcpGalleryManifestService.js';
// Upstream browser secret/encryption services use the injected native Keychain provider.
import '../services/encryption/browser/encryptionService.js';
import '../services/secrets/browser/secretStorageService.js';
// The native service owns only local process startup; the AHP client and remote routing are stock.
import { IAgentHostService } from '../../platform/agentHost/common/agentService.js';
import { NativeAgentHostService } from './nativeAgentHostService.js';
import { AgentHostEnablementService } from '../../platform/agentHost/browser/agentHostEnablementService.js';
import { IAgentHostEnablementService } from '../../platform/agentHost/common/agentHostEnablementService.js';
import { EditorRemoteAgentHostServiceClient } from '../services/agentHost/browser/editorRemoteAgentHostServiceClient.js';
import { IUpdateService } from '../../platform/update/common/update.js';
import { IFileManagedSettingsService, IManagedSettingsService, INativeManagedSettingsService, NullFileManagedSettingsService, NullNativeManagedSettingsService } from '../../platform/policy/common/copilotManagedSettings.js';
import { IpadUpdateService } from './ipadUpdateService.js';
import { ConfirmResult, IFileDialogService } from '../../platform/dialogs/common/dialogs.js';
import { INotificationService } from '../../platform/notification/common/notification.js';
import { registerIncomingDocuments } from './incomingDocuments.js';
import { registerNativeTerminalKeyboard } from './nativeTerminalKeyboard.js';
import { registerNativeThemeBackground } from './nativeThemeBackground.js';
import { IThemeService } from '../../platform/theme/common/themeService.js';
import { registerNativeWorkbenchActions } from './nativeWorkbenchActions.js';
import { registerNativeWorkbenchMenu } from './nativeWorkbenchMenu.js';
import { IMenuService } from '../../platform/actions/common/actions.js';
import { NativeFileSystemProvider } from './nativeFileSystemProvider.js';
import { NativeSecretStorageProvider } from './nativeSecretStorageProvider.js';
import { IWebWorkerService } from '../../platform/webWorker/browser/webWorkerService.js';
import { IpadWebWorkerService } from './ipadWebWorkerService.js';
import { IpadFileDialogService } from './ipadFileDialogService.js';
import { FileSystemProviderErrorCode, toFileSystemProviderErrorCode } from '../../platform/files/common/files.js';
import { ILoggerService } from '../../platform/log/common/log.js';
import { FileLoggerService } from '../../platform/log/common/fileLog.js';
import { ILogService, LogLevel, NullLogService } from '../../platform/log/common/log.js';
import { LogService } from '../../platform/log/common/logService.js';
import { ConsoleLogger } from '../../platform/log/common/log.js';
import { IUriIdentityService } from '../../platform/uriIdentity/common/uriIdentity.js';
import { UriIdentityService } from '../../platform/uriIdentity/common/uriIdentityService.js';
import { IRequestService } from '../../platform/request/common/request.js';
import { ISignService } from '../../platform/sign/common/sign.js';
import { SignService } from '../../platform/sign/browser/signService.js';
import { RequiredMicrosoftSignService } from './nativeSignService.js';
import { IRemoteAuthorityResolverService, RemoteConnectionType } from '../../platform/remote/common/remoteAuthorityResolver.js';
import { RemoteAuthorityResolverService } from '../../platform/remote/electron-browser/remoteAuthorityResolverService.js';
import { IRemoteSocketFactoryService, RemoteSocketFactoryService } from '../../platform/remote/common/remoteSocketFactoryService.js';
import { BrowserSocketFactory } from '../../platform/remote/browser/browserSocketFactory.js';
import { IAnyWorkspaceIdentifier, IWorkspaceContextService } from '../../platform/workspace/common/workspace.js';
import { IWorkbenchConfigurationService } from '../services/configuration/common/configuration.js';
import { IConfigurationService } from '../../platform/configuration/common/configuration.js';
import { WorkspaceService } from '../services/configuration/browser/configurationService.js';
import { ConfigurationCache } from '../services/configuration/common/configurationCache.js';
import { BrowserWorkbenchEnvironmentService, IBrowserWorkbenchEnvironmentService } from '../services/environment/browser/environmentService.js';
import { BrowserStorageService } from '../services/storage/browser/storageService.js';
import { BrowserWorkingCopyBackupService } from '../services/workingCopy/browser/workingCopyBackupService.js';
import { IStorageService } from '../../platform/storage/common/storage.js';
import { IUserDataProfileService } from '../services/userDataProfile/common/userDataProfile.js';
import { UserDataProfileService } from '../services/userDataProfile/common/userDataProfileService.js';
import { BrowserUserDataProfilesService } from '../../platform/userDataProfile/browser/userDataProfile.js';
import { IUserDataProfilesService } from '../../platform/userDataProfile/common/userDataProfile.js';
import { IRemoteAgentService } from '../services/remote/common/remoteAgentService.js';
import { RemoteAgentService } from '../services/remote/browser/remoteAgentService.js';
import { RemoteFileSystemProviderClient } from '../services/remote/common/remoteFileSystemProviderClient.js';
import { IWorkspaceTrustEnablementService, IWorkspaceTrustManagementService } from '../../platform/workspace/common/workspaceTrust.js';
import { WorkspaceTrustEnablementService, WorkspaceTrustManagementService } from '../services/workspaces/common/workspaceTrust.js';
import { IDefaultAccountService } from '../../platform/defaultAccount/common/defaultAccount.js';
import { DefaultAccountService } from '../services/accounts/browser/defaultAccount.js';
import { AccountPolicyService, IAccountPolicyGateService } from '../services/policies/common/accountPolicyService.js';
import { IPolicyService } from '../../platform/policy/common/policy.js';
import { BrowserRequestService } from '../services/request/browser/requestService.js';
import { IExtensionService } from '../services/extensions/common/extensions.js';
import { Workbench } from '../browser/workbench.js';
import { bootError, bootStep, bootWarn } from './boot.js';
import { OwnedService, overrideServiceInstance, registerIpadOverrides } from './serviceOverrides.js';
import { UnsupportedExtensionService } from './unsupportedExtensionService.js';
import { NativeIpadExtensionService } from './nativeExtensionService.js';
import { registerNativeTerminalBackend } from './nativeTerminalBackend.js';
import { NativeTaskService, registerNativeTaskSupport } from './nativeTaskSupport.js';
import { ITerminalService } from '../contrib/terminal/browser/terminal.js';
import { ITaskService } from '../contrib/tasks/common/taskService.js';
import { IConfigurationResolverService } from '../services/configurationResolver/common/configurationResolver.js';
import { DisabledUserDataAutoSyncService, DisabledUserDataSyncAccountService, DisabledUserDataSyncEnablementService } from './disabledPlatformServices.js';
import { IUserDataSyncAccountService } from '../../platform/userDataSync/common/userDataSyncAccount.js';
import { IUserDataAutoSyncService, IUserDataSyncEnablementService, IUserDataSyncService, IUserDataSyncStoreService, IUserDataSyncLocalStoreService, IUserDataSyncResourceProviderService } from '../../platform/userDataSync/common/userDataSync.js';
import { UserDataSyncService } from '../../platform/userDataSync/common/userDataSyncService.js';
import { UserDataSyncStoreService } from '../../platform/userDataSync/common/userDataSyncStoreService.js';
import { UserDataSyncLocalStoreService } from '../../platform/userDataSync/common/userDataSyncLocalStoreService.js';
import { UserDataSyncResourceProviderService } from '../../platform/userDataSync/common/userDataSyncResourceProvider.js';
import { IUserDataSyncMachinesService, UserDataSyncMachinesService } from '../../platform/userDataSync/common/userDataSyncMachines.js';
import { IExtensionGalleryService } from '../../platform/extensionManagement/common/extensionManagement.js';
import { NativeMarketplaceGalleryService } from './marketplaceRequestService.js';

// Platform-neutral browser service registrations, selected individually from `workbench.web.main.ts`
// at the pin and filtered: no web product bootstrap, no web-worker extension host, no remote,
// tunnel, update, userDataSync, gallery scanners, or secrets/encryption clients. These modules
// register themselves via `registerSingleton`, so they are imported for their side effects.
import '../browser/parts/dialogs/dialog.web.contribution.js';
import './nativeSearchService.js';
import '../services/textfile/browser/browserTextFileService.js';
import '../services/keybinding/browser/keyboardLayoutService.js';
import '../services/extensions/browser/extensionsScannerService.js';
import { NativeURLService } from '../../platform/url/common/urlService.js';
import { IURLService } from '../../platform/url/common/url.js';
import { IExtensionUrlHandler } from '../services/extensions/browser/extensionUrlHandler.js';
import { registerNativeExtensionURLs } from './nativeExtensionURLs.js';
import '../services/workspaces/browser/workspacesService.js';
import '../services/workspaces/browser/workspaceEditingService.js';
import '../services/mcp/browser/mcpWorkbenchManagementService.js';
import '../services/dialogs/browser/fileDialogService.js';
import '../services/host/browser/browserHostService.js';
import '../services/lifecycle/browser/lifecycleService.js';
import '../services/clipboard/browser/clipboardService.js';
import '../contrib/browserView/browser/browserView.contribution.js';
import '../services/localization/browser/localeService.js';
import '../services/integrity/browser/integrityService.js';
import '../services/path/browser/pathService.js';
// Terminal and output-link detection require ITunnelService even for local files. The browser
// implementation reports no remote tunnel capability when there is no remote authority.
import '../services/tunnel/browser/tunnelService.js';
import '../services/themes/browser/browserHostColorSchemeService.js';
import '../services/imageResize/browser/imageResizeService.js';
import '../services/workingCopy/browser/workingCopyBackupService.js';
import '../services/files/browser/elevatedFileService.js';
import '../services/workingCopy/browser/workingCopyHistoryService.js';
import '../services/configurationResolver/browser/configurationResolverService.js';
import '../services/auxiliaryWindow/browser/auxiliaryWindowService.js';
import '../services/power/browser/powerService.js';
import '../services/localTranscription/browser/localTranscriptionService.js';
import '../contrib/logs/browser/logs.contribution.js';
import '../contrib/localization/browser/localization.contribution.js';
// Extension install-error actions depend on the issue service even when the user never opens
// a reporter. Reuse the upstream browser implementation and its service registrations.
import '../contrib/issue/browser/issue.contribution.js';
import '../contrib/performance/browser/performance.web.contribution.js';
import '../contrib/preferences/browser/keyboardLayoutPicker.js';
import '../contrib/debug/browser/extensionHostDebugService.js';
import '../contrib/webview/browser/webview.web.contribution.js';
import '../contrib/terminal/browser/terminal.web.contribution.js';
import './nativeTerminalProfileServices.js';
import '../contrib/terminal/browser/terminalInstanceService.js';
import '../contrib/tasks/browser/taskService.js';
import '../contrib/tags/browser/workspaceTagsService.js';

// Platform-neutral browser service registrations, selected individually from `workbench.web.main.ts`
// at the pin and filtered: no web product bootstrap, no web-worker extension host, no remote,
// tunnel, update, userDataSync, gallery scanners, or secrets/encryption clients. These register
// themselves via `registerSingleton`, so they must be imported for their side effects.

// Explicit singleton registrations copied individually from `workbench.web.main.ts` L112-135 at the
// pin (e646868). Each was checked in source; account and automatic sync remain explicitly
// disabled below. Local/remote AHP selection is configured in initServices; native catalog scanning is retained.
// Module load order matters: these must run before `Workbench.initServices()`.
// No telemetry leaves the device. NOTE: `telemetryUtils.NullTelemetryService` is a module-level
// *instance* (L46); `registerSingleton` takes a constructor, so use `NullTelemetryServiceShape` (L29).
registerSingleton(ITelemetryService, NullTelemetryServiceShape, InstantiationType.Delayed);
registerNativeWindowServices();
registerSingleton(IAgentHostService, NativeAgentHostService, InstantiationType.Delayed);
registerSingleton(IMcpGalleryManifestService, WorkbenchMcpGalleryManifestService, InstantiationType.Delayed);
registerSingleton(IAccessibilityService, AccessibilityService, InstantiationType.Delayed);
registerSingleton(IContextMenuService, ContextMenuService, InstantiationType.Delayed);
registerSingleton(ITitleService, BrowserTitleService, InstantiationType.Eager);
registerSingleton(ITimerService, TimerService, InstantiationType.Delayed);
registerSingleton(ILanguagePackService, WebLanguagePacksService, InstantiationType.Delayed);
registerSingleton(ICustomEndpointTelemetryService, NullEndpointTelemetryService, InstantiationType.Delayed);
registerSingleton(IDiagnosticsService, NullDiagnosticsService, InstantiationType.Delayed);
registerSingleton(IWebContentExtractorService, NullWebContentExtractorService, InstantiationType.Delayed);
registerSingleton(ISharedWebContentExtractorService, NullSharedWebContentExtractorService, InstantiationType.Delayed);

// Extension host selection, decided once at module load — before `Workbench.initServices()` reads
// the singleton registry. Presence of the native bridge is a capability fact, not a fallback:
//   codipadNative present -> AbstractExtensionService + native Node host (LocalProcess selection)
//   codipadNative absent  -> the explicitly refusing service, because there is genuinely no host
if (isNativeAvailable()) {
	registerSingleton(IExtensionService, NativeIpadExtensionService, InstantiationType.Delayed);
	registerSingleton(IExtensionGalleryService, NativeMarketplaceGalleryService, InstantiationType.Delayed);
	registerSingleton(ITaskService, NativeTaskService, InstantiationType.Delayed);
} else {
	registerSingleton(IExtensionService, UnsupportedExtensionService as unknown as new (...args: never[]) => IExtensionService, InstantiationType.Eager);
}

// Native extension management. Both ids share the installed catalog and Marketplace events.
registerNativeCatalogServices();
// The workbench decorator refines the platform decorator; one registration serves both ids.
// Keep the common sync state/configuration services available without enabling an account or sync.
registerSingleton(IUserDataSyncStoreService, UserDataSyncStoreService, InstantiationType.Delayed);
registerSingleton(IUserDataSyncLocalStoreService, UserDataSyncLocalStoreService, InstantiationType.Delayed);
registerSingleton(IUserDataSyncResourceProviderService, UserDataSyncResourceProviderService, InstantiationType.Delayed);
registerSingleton(IUserDataSyncMachinesService, UserDataSyncMachinesService, InstantiationType.Delayed);
registerSingleton(IUserDataSyncService, UserDataSyncService, InstantiationType.Delayed);
overrideServiceInstance(IUserDataSyncAccountService, new DisabledUserDataSyncAccountService());
overrideServiceInstance(IUserDataSyncEnablementService, new DisabledUserDataSyncEnablementService());
overrideServiceInstance(IUserDataAutoSyncService, new DisabledUserDataAutoSyncService());
// Reject unavailable local sandbox inspection. Remote workspaces use the remote helper channel.
overrideServiceInstance(ISandboxHelperService, {
	_serviceBrand: undefined,
	async checkSandboxDependencies() {
		throw new Error('Local terminal sandbox capability cannot be verified on iPad');
	}
});

class RestoredWorkspaceFileUnavailable extends Error {}

class IpadAgentHostEnablementService extends AgentHostEnablementService {
	constructor(runtimeAvailable: boolean,
		@IConfigurationService configuration: IConfigurationService,
		@IContextKeyService context: IContextKeyService,
		@IManagedSettingsService managed: IManagedSettingsService,
	) {
		super(runtimeAvailable, configuration, context, managed);
	}
}


export class IpadMain extends Disposable {
	private instantiationService: IInstantiationService | undefined;
	private workspaceTransitionInFlight = false;
	private openNativeFolder: ((folder: URI, workspaceFile?: boolean) => Promise<boolean>) | undefined;
	private readonly sceneId = (globalThis as { __codipadSceneId?: string }).__codipadSceneId ?? 'single';
	private readonly migrateLegacyRemote = (globalThis as { __codipadMigrateLegacyRemote?: boolean }).__codipadMigrateLegacyRemote === true;
	private readonly workspaceProvider = new NativeRemoteWorkspaceProvider(remoteWorkspaceSceneStorage(localStorage,
		this.sceneId, this.migrateLegacyRemote), async () => {
		if (!this.instantiationService) {
			throw new Error('The workbench has not started');
		}
		const stopped = await this.instantiationService.invokeFunction(accessor => accessor.get(IExtensionService).stopExtensionHostsForWindowReload('Change remote authority'));
		if (!stopped) {
			throw new Error('Extension host shutdown was vetoed');
		}
		// Fence stale page starts before asking the native owner to confirm real settlement.
		let fence: { generation: number };
		try { fence = await callNative<{ generation: number }>('exthost.prepareWindowReload'); }
		catch {
			throw new Error('The previous extension host has not finished closing. Your remote workspace is saved; retry Close Remote Connection when cleanup finishes.');
		}
		try { window.location.reload(); }
		catch {
			await callNative('exthost.cancelWindowReload', { generation: fence.generation });
			throw new Error('The workbench could not reload. Your remote workspace is saved; retry Close Remote Connection.');
		}
	}, async workspace => {
		const resource = workspace && ('folderUri' in workspace ? workspace.folderUri : workspace.workspaceUri);
		if (!resource || resource.scheme !== Schemas.file || !this.openNativeFolder) {
			throw new Error('Opening this workspace requires a native folder, workspace file or remote authority');
		}
		return this.openNativeFolder(resource, !!workspace && 'workspaceUri' in workspace);
	}, async (workspace, options) => {
		if (workspace || options?.remoteAuthority || options?.payload) {
			throw new Error('Opening a workspace or remote connection in a new window is not yet supported');
		}
		await callNative('window.openScene', {});
		return true;
	}, workspace => sceneWorkspaceIdentifier(workspace, this.sceneId, this.migrateLegacyRemote));

	/**
	 * `IFileService` exposes `createFolder` (files.ts:225), not `mkdir`; the in-memory provider's
	 * own `mkdir` is non-recursive and needs an existing parent, so only the single root of each
	 * private home is created. FileExists is expected on a second boot in the same page lifetime.
	 */
	private static async mkdirIfMissing(fileService: IFileService, directory: URI): Promise<void> {
		try {
			await fileService.createFolder(directory);
		} catch (error) {
			if (toFileSystemProviderErrorCode(error as Error) !== FileSystemProviderErrorCode.FileExists) {
				throw error;
			}
		}
	}

	async open(): Promise<void> {
		let restoredNativeWorkspace: NativeLocalWorkspaceSelection | undefined;
		let nativeFileProvider: NativeFileSystemProvider | undefined;
		if (isNativeAvailable() && !this.workspaceProvider.remoteAuthority) {
			const log = new NullLogService();
			const files = new FileService(log);
			const provider = this._register(new NativeFileSystemProvider());
			nativeFileProvider = provider;
			files.registerProvider(Schemas.file, provider);
			const identity = new UriIdentityService(files);
			try {
				const current = await callNative<{ restoreUnavailable?: boolean }>('workspace.current');
				restoredNativeWorkspace = parseNativeLocalWorkspaceSelection(current);
				if (restoredNativeWorkspace && 'workspaceUri' in restoredNativeWorkspace) {
					const selection = restoredNativeWorkspace;
					const config = await files.readFile(selection.workspaceUri);
					const roots = resolveNativeWorkspaceFolders(selection.workspaceUri, config.value.toString(), identity.extUri);
					if (roots.length !== selection.folderUris.length || roots.some((root, index) => !identity.extUri.isEqual(root, selection.folderUris[index]))) {
						throw new Error('The saved workspace file no longer matches its authorized folders');
					}
				}
				this.workspaceProvider.setNativeWorkspace(restoredNativeWorkspace);
				if (current.restoreUnavailable) {
					bootWarn('workspace-restore', 'The previous native workspace is unavailable; select it again to restore access.');
				}
			} catch {
				restoredNativeWorkspace = undefined;
				this.workspaceProvider.setNativeWorkspace(undefined);
				bootWarn('workspace-restore', 'Native workspace restoration failed; the empty workbench remains available for selection.');
			} finally { identity.dispose(); files.dispose(); log.dispose(); }
		}
		const workspace = this.workspaceProvider.workspaceIdentifier;
		let documentLayout = workspace.id;
		let documentAccessRestored = isNativeAvailable() ? await restoreOpenDocumentAuthorities(documentLayout) : false;
		bootStep('ipad-main', `workspace=${workspace.id}`);
		const [, services] = await Promise.all([
			domContentLoaded(getWindow(document.body)),
			this.initStartupServices(workspace, restoredNativeWorkspace && 'workspaceUri' in restoredNativeWorkspace ? restoredNativeWorkspace : undefined, nativeFileProvider)
		]);
		if (isNativeAvailable() && documentLayout !== services.workspaceIdentifier.id) {
			documentLayout = services.workspaceIdentifier.id;
			documentAccessRestored = await restoreOpenDocumentAuthorities(documentLayout);
		}

		if (restoredNativeWorkspace && 'folderUri' in restoredNativeWorkspace && restoredNativeWorkspace.previousFolderUris?.length) {
			const storage = services.serviceCollection.get(IStorageService);
			const files = services.serviceCollection.get(IFileService);
			const environment = services.serviceCollection.get(IBrowserWorkbenchEnvironmentService);
			if (!storage || storage instanceof SyncDescriptor || !files || files instanceof SyncDescriptor || !environment || environment instanceof SyncDescriptor) {
				throw new Error('Native workspace relocation requires initialized workspace services');
			}
			const backups = new BrowserWorkingCopyBackupService(services.workspaceService, environment, files, services.logService);
			const cancellation = new CancellationTokenSource();
			const cancelOnDispose = this._register(toDisposable(() => cancellation.cancel()));
			try {
				await restoreRelocatedNativeEditors(restoredNativeWorkspace, storage, backups, services.logService, cancellation.token, services.workspaceIdentifier.id);
				if (cancellation.token.isCancellationRequested) { throw new Error('Native workspace relocation cancelled'); }
				await callNative('workspace.completeRelocation', { uri: restoredNativeWorkspace.folderUri.toString(),
					workspaceId: restoredNativeWorkspace.workspaceId, previousFolderUris: restoredNativeWorkspace.previousFolderUris.map(uri => uri.toString()) });
			} finally { cancelOnDispose.dispose(); cancellation.dispose(); backups.dispose(); }
		}

		// Must happen after the contribution graph has evaluated and after our instances exist:
		// `Workbench.initServices()` overwrites the collection from the singleton registry, and the
		// last registered descriptor wins. See `serviceOverrides.ts` for the verified mechanism.
		registerIpadOverrides(services.owned);

		bootStep('workbench-construct');

		// A non-body parent makes upstream layout measure this native-sized element instead
		// of WebKit's potentially stale visualViewport dimensions during keyboard transitions.
		const container = document.getElementById('codipad-workbench-host');
		if (!container) { throw new Error('Native workbench host element is missing'); }
		const workbench = new Workbench(container, {
			extraClasses: ['ipad']
		}, services.serviceCollection, services.logService);

		this._register(workbench.onDidShutdown(() => this.dispose()));

		const instantiationService = workbench.startup();
		this.instantiationService = instantiationService;
		const documentAuthorities = isNativeAvailable() ? this._register(instantiationService.invokeFunction(accessor => new NativeOpenDocuments(
			documentLayout, documentAccessRestored, accessor.get(IEditorService), accessor.get(IEditorGroupsService),
			accessor.get(IWorkingCopyService), accessor.get(ILifecycleService), accessor.get(IUriIdentityService)
		))) : undefined;
		instantiationService.invokeFunction(accessor => accessor.get(IOpenerService).setDefaultExternalOpener(new NativeExternalOpener()));
		this._register(registerNativeViewportLayout(container, () => workbench.layout()));
		bootStep('workbench-started');

		// Wire the dialog host: opening a file goes through the standard editor path; opening a folder
		// re-initializes the existing WorkspaceService after resolving dirty editors. Storage retains
		// each workspace's editor state; a fresh workspace starts with an empty working set.
		// Native terminals: one backend for the local authority, registered into VS Code's own
		// backend registry so the ordinary New Terminal UI and xterm rendering are untouched.
		if (isNativeAvailable()) {
			instantiationService.invokeFunction(accessor => {
				const logService = accessor.get(ILogService);
				registerNativeTerminalBackend(logService, instantiationService);
				// Tell the terminal service the platform supports local processes. This is the service
				// seam upstream uses (not an OS/platform flag), and it is only set once a backend exists.
				accessor.get(ITerminalService).registerProcessSupport(true);
				bootStep('terminal-backend', 'native PTY backend registered for the local authority');
				registerNativeTaskSupport(accessor.get(ITaskService), accessor.get(IConfigurationResolverService));
				bootStep('task-backend', 'configured shell tasks use the native terminal backend');
			});
		} else {
			bootWarn('terminal-backend', 'codipadNative absent: no PTY backend in this build (explicitly unsupported)');
		}

		instantiationService.invokeFunction(accessor => {
			// The renderer-only build reported "open folder unsupported" (openFolderWorkspaceSupport
			// = false). The native capability exists now, so state that explicitly through the context
			// key. This is a service-capability fact, not an isWeb/isNative flag flip.
			OpenFolderWorkspaceSupportContext.bindTo(accessor.get(IContextKeyService)).set(isNativeAvailable());
			if (!isNativeAvailable()) {
				bootWarn('open-folder', 'codipadNative bridge absent: open-folder actions stay disabled');
			}
		});

		let pendingDocumentBarrier: { layout: string; ready: boolean; listener: { dispose(): void } } | undefined;
		const finishDocumentBarrier = () => {
			if (!pendingDocumentBarrier?.ready || this.workspaceTransitionInFlight) { return; }
			const barrier = pendingDocumentBarrier;
			pendingDocumentBarrier = undefined;
			barrier.listener.dispose();
			if (barrier.layout === documentLayout) { documentAuthorities?.resume(documentLayout, documentAccessRestored); }
		};
		this._register(toDisposable(() => pendingDocumentBarrier?.listener.dispose()));
		const dialogHost = {
			openResource: async (resource: URI) => {
				await instantiationService.invokeFunction(async accessor => {
					const editorService = accessor.get(IEditorService);
					const pane = await editorService.openEditor({ resource, options: { pinned: true } });
					if (!pane) { throw new Error('The editor did not open the requested file.'); }
				});
			},
			openFolder: async (folder: URI, workspaceFile = false) => {
				if (this.workspaceTransitionInFlight) { throw new Error('A native workspace transition is already in progress'); }
				this.workspaceTransitionInFlight = true;
				let nextDocumentAccess = documentAccessRestored;
				let documentsPaused = false;
				let previousBarrierPending = false;
				let newGroupReady = false;
				let needsGroupBarrier = false;
				let newGroupListener: { dispose(): void } | undefined;
				let transitionCommitted = false;
				try {
					if (this.workspaceProvider.remoteAuthority) {
						throw new Error('Close the remote connection before opening a native folder');
					}
					const editorService = instantiationService.invokeFunction(accessor => accessor.get(IEditorService));
					const dirtyEditors = editorService.getEditors(EditorsOrder.SEQUENTIAL).filter(({ editor }) => editor.isDirty());
					if (dirtyEditors.length) {
						const choice = await instantiationService.invokeFunction(accessor => accessor.get(IFileDialogService)
							.showSaveConfirm(dirtyEditors.map(({ editor }) => editor.getName())));
						if (choice === ConfirmResult.CANCEL) { return false; }
						if (choice === ConfirmResult.SAVE) {
							if (!(await editorService.save(dirtyEditors)).success) { return false; }
						} else if (!(await editorService.revert(dirtyEditors))) { return false; }
					}
					// A save dialog or custom editor may leave edits pending. Do not change workspace
					// identity while any buffer still needs a decision from its owner.
					if (editorService.editors.some(editor => editor.isDirty())) { return false; }
					const editorGroups = instantiationService.invokeFunction(accessor => accessor.get(IEditorGroupsService));
					if (!workspaceFile) { folder = removeTrailingPathSeparator(folder); }
					// Live transition, no reload: storage follows the new workspace, and a failed switch
					// restores the previous storage + workspace identity before the error surfaces.
					const previous = services.workspaceIdentifier;
					const storageService = instantiationService.invokeFunction(accessor => accessor.get(IStorageService));
					let storageSwitched = false;
					let selection: NativeLocalWorkspaceSelection | undefined;
					const extUri = instantiationService.invokeFunction(accessor => accessor.get(IUriIdentityService)).extUri;
					try {
						selection = workspaceFile
							? await identifyNativeWorkspaceFile(folder, instantiationService.invokeFunction(accessor => accessor.get(IFileService)), extUri)
							: parseNativeWorkspaceSelection(await callNative('workspace.identify', { uri: folder.toString() }));
						if (!selection) { return false; } // Native picker cancellation leaves the old window intact.
						const nativeTarget = 'workspaceUri' in selection
							? { id: selection.workspaceId, configPath: selection.workspaceUri }
							: { id: selection.workspaceId, uri: selection.folderUri };
						const target = sceneWorkspaceIdentifier(nativeTarget, this.sceneId, this.migrateLegacyRemote);
						if (editorService.editors.some(editor => editor.isDirty())) {
							throw new Error('Editors changed while opening the new workspace; try again');
						}
						// Strict: workspace-scoped storage must follow the folder. The patch
						// `patches/vscode/0002-switch-workspace-storage.patch` stages the new IndexedDB scope
						// before swapping it in, so a rejected switch leaves the old storage untouched and
						// this handler simply surfaces the error.
						previousBarrierPending = !!pendingDocumentBarrier && !pendingDocumentBarrier.ready;
						pendingDocumentBarrier?.listener.dispose();
						pendingDocumentBarrier = undefined;
						await documentAuthorities?.pause();
						documentsPaused = !!documentAuthorities;
						nextDocumentAccess = isNativeAvailable() ? await restoreOpenDocumentAuthorities(target.id) : false;
						const previousGroups = new Set(editorGroups.groups);
						newGroupListener = editorGroups.onDidAddGroup(() => {
							if (editorGroups.groups.some(group => previousGroups.has(group))) { return; }
							newGroupReady = true;
							if (pendingDocumentBarrier && pendingDocumentBarrier.listener === newGroupListener) {
								pendingDocumentBarrier.ready = true;
								finishDocumentBarrier();
							}
						});
						await storageService.switch(target, false);
						storageSwitched = true;
						needsGroupBarrier = target.id !== previous.id && editorGroups.hasRestorableState;
						// Upstream restores saved target layouts on the storage event, but leaves the
						// old editors alone when that target has no memento. Clear only that empty case,
						// after switch() has persisted the previous workspace's tabs.
						if (!editorGroups.hasRestorableState) {
							if (!(await editorGroups.applyWorkingSet('empty')) || editorService.editors.length) {
								throw new Error('Closing editors for the new workspace was vetoed');
							}
						}
						await services.workspaceService.initialize(target);
						const expected = 'workspaceUri' in selection ? selection.folderUris : [selection.folderUri];
						const initialized = services.workspaceService.getWorkspace().folders;
						if (initialized.length !== expected.length || initialized.some((folder, index) => !extUri.isEqual(folder.uri, expected[index]))) {
							throw new Error('The initialized workspace folders differ from native authorization');
						}
						if ('workspaceUri' in selection) { await commitNativeWorkspaceFile(selection); }
						else { await callNative('workspace.commit', { uri: selection.folderUri.toString(), workspaceId: selection.workspaceId }); }
						this.workspaceProvider.setNativeWorkspace(selection);
						services.workspaceIdentifier = target;
						documentLayout = target.id;
						documentAccessRestored = nextDocumentAccess;
						transitionCommitted = true;
					} catch (error) {
						if (selection && 'workspaceUri' in selection) {
							try { await cancelNativeWorkspaceFile(selection); }
							catch (cancelError) { bootError('open-workspace-cancel', cancelError); }
						}
						// A rejected switch restores the storage service itself (patch 0002 rebuilds the
						// previous scope and re-signals it), so the workspace is untouched and nothing must
						// be rolled back here. Only a failure *after* a committed switch needs the pair undone.
						if (storageSwitched) {
							try {
								await storageService.switch(previous, false);
								await services.workspaceService.initialize(previous);
							} catch (rollbackError) {
								bootError('open-folder-rollback', rollbackError);
							}
						}
						try {
							await callNative('workspace.current');
						} catch (nativeRollbackError) {
							bootError('open-folder-native-rollback', nativeRollbackError);
						}
						throw error;
					}
					return true;
				} finally {
					this.workspaceTransitionInFlight = false;
					if (documentsPaused && transitionCommitted && needsGroupBarrier && newGroupListener) {
						pendingDocumentBarrier = { layout: documentLayout, ready: newGroupReady, listener: newGroupListener };
						finishDocumentBarrier();
					} else {
						newGroupListener?.dispose();
						if (documentsPaused && previousBarrierPending && !transitionCommitted) { documentAccessRestored = false; }
						if (documentsPaused) { documentAuthorities?.resume(documentLayout, documentAccessRestored); }
						finishDocumentBarrier();
					}
				}
			}
		};
		this.openNativeFolder = dialogHost.openFolder;
		(instantiationService.invokeFunction(accessor => accessor.get(IFileDialogService)) as IpadFileDialogService).setHost({ openResource: dialogHost.openResource, openFolder: async folder => { await dialogHost.openFolder(folder); } });
		const notifications = instantiationService.invokeFunction(accessor => accessor.get(INotificationService));
		this._register(registerIncomingDocuments(async (resource, kind) => {
			if (kind === 'file') { await dialogHost.openResource(resource); }
			else if (!await dialogHost.openFolder(resource, kind === 'workspace')) { throw new Error('Opening the workspace was cancelled.'); }
		}, error => notifications.error(error)));
		// Instantiate the upstream consent/activation handler before admitting external callbacks.
		instantiationService.invokeFunction(accessor => accessor.get(IExtensionUrlHandler));
		const extensionURLs = this._register(registerNativeExtensionURLs(instantiationService.invokeFunction(accessor => accessor.get(IURLService)), instantiationService.invokeFunction(accessor => accessor.get(IOpenerService)), () => notifications.error('The extension callback could not be opened. Please start the request again.')));
		this._register(workbench.onWillShutdown(() => extensionURLs.dispose()));
		const terminalKeyboard = this._register(registerNativeTerminalKeyboard(instantiationService.invokeFunction(accessor => accessor.get(ITerminalService))));
		this._register(workbench.onWillShutdown(() => terminalKeyboard.dispose()));
		const nativeBackground = this._register(registerNativeThemeBackground(instantiationService.invokeFunction(accessor => accessor.get(IThemeService))));
		this._register(workbench.onWillShutdown(() => nativeBackground.dispose()));
		const nativeActions = this._register(registerNativeWorkbenchActions(instantiationService.invokeFunction(accessor => accessor.get(IFileDialogService))));
		this._register(workbench.onWillShutdown(() => nativeActions.dispose()));
		const nativeMenu = this._register(instantiationService.invokeFunction(accessor => registerNativeWorkbenchMenu(accessor.get(IMenuService), accessor.get(IContextKeyService))));
		this._register(workbench.onWillShutdown(() => nativeMenu.dispose()));
	}

	private async initStartupServices(workspace: IAnyWorkspaceIdentifier, restoredWorkspaceFile?: NativeWorkspaceFileSelection, nativeFileProvider?: NativeFileSystemProvider): ReturnType<IpadMain['initServices']> {
		const attempt = this._register(new DisposableStore());
		try {
			return await this.initServices(workspace, restoredWorkspaceFile, nativeFileProvider, attempt);
		} catch (error) {
			attempt.dispose();
			if (!(error instanceof RestoredWorkspaceFileUnavailable)) { throw error; }
			// Rebuild every workspace-scoped identity together. Native records, layouts and
			// backups remain untouched; no storage for the rejected file has been opened.
			this.workspaceProvider.setNativeWorkspace(undefined);
			bootWarn('workspace-restore', 'The saved workspace file changed during startup; the empty workbench remains available for selection.');
			return this.initStartupServices(this.workspaceProvider.workspaceIdentifier, undefined, nativeFileProvider);
		}
	}

	private async validateRestoredWorkspaceFile(selection: NativeWorkspaceFileSelection, files: IFileService, identity: IUriIdentityService): Promise<void> {
		try {
			const config = await files.readFile(selection.workspaceUri);
			const roots = resolveNativeWorkspaceFolders(selection.workspaceUri, config.value.toString(), identity.extUri);
			if (roots.length !== selection.folderUris.length || roots.some((root, index) => !identity.extUri.isEqual(root, selection.folderUris[index]))) {
				throw new Error('The restored workspace file refers to folders without matching native authorization');
			}
		} catch {
			throw new RestoredWorkspaceFileUnavailable('The restored workspace file is unavailable or changed');
		}
	}

	private async initServices(workspace: IAnyWorkspaceIdentifier, restoredWorkspaceFile: NativeWorkspaceFileSelection | undefined, nativeFileProvider: NativeFileSystemProvider | undefined, attempt: DisposableStore): Promise<{ serviceCollection: ServiceCollection; logService: ILogService; owned: OwnedService[]; workspaceService: WorkspaceService; workspaceIdentifier: IAnyWorkspaceIdentifier }> {		const serviceCollection = new ServiceCollection();
		const owned: OwnedService[] = [];
		let agentRuntimeAvailable = !!this.workspaceProvider.remoteAuthority;
		if (this.workspaceProvider.remoteAuthority) {
			serviceCollection.set(IAgentHostService, new SyncDescriptor(EditorRemoteAgentHostServiceClient));
		} else if (isNativeAvailable()) {
			const status = await callNative<{ runtimeAvailable: boolean }>('agentHost.status');
			agentRuntimeAvailable = status.runtimeAvailable === true;
		}
		serviceCollection.set(IAgentHostEnablementService, new SyncDescriptor(IpadAgentHostEnablementService, [agentRuntimeAvailable]));

		// Set on the collection *and* remember for the post-graph override registration.
		const own = <T>(id: ServiceIdentifier<T>, instance: T): void => {
			serviceCollection.set(id, instance);
			owned.push([id as ServiceIdentifier<unknown>, instance]);
			if (isDisposable(instance)) { attempt.add(instance); }
		};

		// Product -------------------------------------------------------------------------------
		const productService: IProductService = { _serviceBrand: undefined, ...product };
		own(IProductService, productService);
		own(IURLService, new NativeURLService(productService));

		// Environment ---------------------------------------------------------------------------
		// Profile and authority identity are fixed for this workbench service graph.
		const logsHome = URI.from({ scheme: 'codipad-logs', path: '/logs' });
		const environmentService = Object.assign(new BrowserWorkbenchEnvironmentService(workspace.id, logsHome, {
			remoteAuthority: this.workspaceProvider.remoteAuthority,
			secretStorageProvider: new NativeSecretStorageProvider(),
			// Desktop product default; WebKit rendering does not imply browser-product autosave.
			// The standard configuration layer still permits user/workspace overrides.
			configurationDefaults: { 'files.autoSave': 'off' },
			workspaceProvider: this.workspaceProvider
		}, productService), { supportsLocalNodeExtensionHost: isNativeAvailable() });
		own(IBrowserWorkbenchEnvironmentService, environmentService);

		// Logging -------------------------------------------------------------------------------
		const logService = new LogService(new ConsoleLogger(LogLevel.Info), []);
		own(ILogService, logService);

		// Workers ---------------------------------------------------------------------------------
		// Pinned worker entries use the upstream loader on the native asset origin.
		own(IWebWorkerService, new IpadWebWorkerService());

		// Files ---------------------------------------------------------------------------------
		// Profile files use VS Code's durable IndexedDB filesystem. This is private app profile data,
		// not workspace content; the native-backed `file:` provider remains the workspace authority.
		const fileService = attempt.add(new FileService(logService));
		own(IFileService, fileService);

		// `file:` is the native filesystem, through the shell's `codipadNative` channel. No fallback, no
		// memory mirror: if the bridge is missing every operation fails with a named error.
		// Keep the startup grant metadata on the same provider used by the workbench.
		fileService.registerProvider(Schemas.file, nativeFileProvider ?? attempt.add(new NativeFileSystemProvider()));

		// Keep the complete upstream database schema: opening the same name/version with a partial
		// store list would make IndexedDB's schema validation attempt a destructive recreation.
		const profileDatabase = await IndexedDB.create('vscode-web-db', 3, ['vscode-userdata-store', 'vscode-logs-store', 'vscode-filehandles-store']);
		attempt.add(toDisposable(() => profileDatabase.close()));
		const userDataProvider = attempt.add(new IndexedDBFileSystemProvider(Schemas.vscodeUserData, profileDatabase, 'vscode-userdata-store', true));
		fileService.registerProvider(Schemas.vscodeUserData, userDataProvider);
		await IpadMain.mkdirIfMissing(fileService, environmentService.userRoamingDataHome);

		const logProvider = attempt.add(new InMemoryFileSystemProvider());
		fileService.registerProvider(environmentService.logsHome.scheme, logProvider);
		await IpadMain.mkdirIfMissing(fileService, environmentService.logsHome);
		const loggerService = attempt.add(new FileLoggerService(LogLevel.Info, logsHome, fileService));
		own(ILoggerService, loggerService);

		const uriIdentityService = new UriIdentityService(fileService);
		own(IUriIdentityService, uriIdentityService);

		// User data profiles (IndexedDB/file-service backed, private to the app) ----------------
		const userDataProfilesService = new BrowserUserDataProfilesService(environmentService, fileService, uriIdentityService, logService);
		own(IUserDataProfilesService, userDataProfilesService);

		const userDataProfileService = new UserDataProfileService(userDataProfilesService.defaultProfile);
		own(IUserDataProfileService, userDataProfileService);

		// Remote plumbing -----------------------------------------------------------------------
		// The optional remote authority is independent of the local Linux/embedded host.
		// Resolver extensions can supply an upstream managed socket or WebSocket connection.
		const remoteSocketFactoryService = new RemoteSocketFactoryService();
		remoteSocketFactoryService.register(RemoteConnectionType.WebSocket, new BrowserSocketFactory(undefined));
		own(IRemoteSocketFactoryService, remoteSocketFactoryService);

		const remoteAuthorityResolverService = new RemoteAuthorityResolverService(productService, {
			getResourceUriProvider: () => uri => uri
		});
		own(IRemoteAuthorityResolverService, remoteAuthorityResolverService);

		const requireMicrosoftSigning = (globalThis as typeof globalThis & { __codipadMicrosoftSigning?: boolean }).__codipadMicrosoftSigning === true;
		const signService = requireMicrosoftSigning ? new RequiredMicrosoftSignService(productService) : new SignService(productService);
		own(ISignService, signService);

		const remoteAgentService = attempt.add(new RemoteAgentService(
			remoteSocketFactoryService, userDataProfileService, environmentService, productService,
			remoteAuthorityResolverService, signService, logService
		));
		own(IRemoteAgentService, remoteAgentService);
		attempt.add(RemoteFileSystemProviderClient.register(remoteAgentService, fileService, logService));

		// Accounts and policy -------------------------------------------------------------------
		const defaultAccountService = attempt.add(new DefaultAccountService(productService));
		own(IDefaultAccountService, defaultAccountService);

		// No MDM/OS-managed policy feed on iPad: upstream's own null implementations, read from
		// `platform/policy/common/copilotManagedSettings.ts` (L395, L915) exactly as web.main L371-374.
		const nativeManagedSettings = new NullNativeManagedSettingsService();
		const fileManagedSettings = new NullFileManagedSettingsService();
		own(INativeManagedSettingsService, nativeManagedSettings);
		own(IFileManagedSettingsService, fileManagedSettings);

		const policyService = attempt.add(new AccountPolicyService(
			logService, defaultAccountService, undefined, nativeManagedSettings, fileManagedSettings
		));
		own(IPolicyService, policyService);
		own(IAccountPolicyGateService, policyService);
		own(IManagedSettingsService, policyService);

		// Updater: disabled by the platform, not by a fake "up to date" answer.
		own(IUpdateService, new IpadUpdateService());

		// Native pickers. `openResource`/`openFolder` are wired after `workbench.startup()` because
		// the editor service and the workspace transition need the started workbench.
		serviceCollection.set(IFileDialogService, new SyncDescriptor(IpadFileDialogService));

		// Workspace, configuration, storage -----------------------------------------------------
		const configurationCache = new ConfigurationCache([], environmentService, fileService);
		const workspaceService = new WorkspaceService(
			{ remoteAuthority: this.workspaceProvider.remoteAuthority, configurationCache },
			environmentService, userDataProfileService, userDataProfilesService, fileService,
			remoteAgentService, uriIdentityService, logService, policyService
		);
		attempt.add(workspaceService);
		// Throws on failure: a workbench with an uninitialized configuration/storage is not a
		// workbench, and hiding this would make later symptoms unattributable.
		if (restoredWorkspaceFile) { await this.validateRestoredWorkspaceFile(restoredWorkspaceFile, fileService, uriIdentityService); }
		await workspaceService.initialize(workspace);
		if (restoredWorkspaceFile) {
			const initialized = workspaceService.getWorkspace().folders;
			if (initialized.length !== restoredWorkspaceFile.folderUris.length || initialized.some((folder, index) => !uriIdentityService.extUri.isEqual(folder.uri, restoredWorkspaceFile.folderUris[index]))) {
				throw new RestoredWorkspaceFileUnavailable('The initialized restored workspace folders differ from native authorization');
			}
		}
		// Upstream tolerates an unreadable config and can return empty folders. Re-read so
		// removal or invalid JSON also rejects a saved workspace whose authorized roots are empty.
		if (restoredWorkspaceFile) { await this.validateRestoredWorkspaceFile(restoredWorkspaceFile, fileService, uriIdentityService); }
		own(IWorkspaceContextService, workspaceService);
		own(IWorkbenchConfigurationService, workspaceService);

		if (isNativeAvailable()) {
			const home = removeTrailingPathSeparator(URI.parse(await callNative<string>('process.home')));
			if (home.scheme !== Schemas.file || home.authority || home.query || home.fragment || !home.path.startsWith('/') || home.path.split('/').some(part => part === '.' || part === '..')) {
				throw new Error('Native process home is not a canonical local file URI');
			}
			own(IPathService, new class extends AbstractPathService {
				constructor() { super(home, remoteAgentService, environmentService, workspaceService); }
			}());
		}

		const storageService = attempt.add(new BrowserStorageService(workspace, userDataProfileService, logService));
		await storageService.initialize();
		own(IStorageService, storageService);

		// Workspace trust -----------------------------------------------------------------------
		const trustEnablementService = new WorkspaceTrustEnablementService(workspaceService as IWorkbenchConfigurationService & IConfigurationService, environmentService);
		own(IWorkspaceTrustEnablementService, trustEnablementService);

		const trustManagementService = attempt.add(new WorkspaceTrustManagementService(
			workspaceService as IWorkbenchConfigurationService & IConfigurationService, remoteAuthorityResolverService,
			storageService, uriIdentityService, environmentService, workspaceService,
			trustEnablementService, fileService
		));
		own(IWorkspaceTrustManagementService, trustManagementService);
		workspaceService.updateWorkspaceTrust(trustManagementService.isWorkspaceTrusted());
		attempt.add(trustManagementService.onDidChangeTrust(() => workspaceService.updateWorkspaceTrust(trustManagementService.isWorkspaceTrusted())));

		// User data initialization ---------------------------------------------------------------
		// Instance ownership, not a singleton descriptor: the browser class takes an optional
		// initializer list (`userDataInit.ts:31`), and an empty list is correct for a fresh profile
		// with no filesystem — there is nothing to copy or migrate.
		own(IUserDataInitializationService, new UserDataInitializationService());

		// Requests ------------------------------------------------------------------------------
		const requestService = attempt.add(new BrowserRequestService(remoteAgentService, workspaceService as IWorkbenchConfigurationService & IConfigurationService, loggerService));
		own(IRequestService, requestService);

		return { serviceCollection, logService, owned, workspaceService, workspaceIdentifier: workspace };
	}
}

/**
 * Boots the workbench. Safe to call once; the shell owns retries by reloading the page, which is
 * the only clean restart available to a workbench that has already disposed.
 */
export async function main(): Promise<void> {
	const ipadMain = new IpadMain();
	try {
		await ipadMain.open();
	} catch (error) {
		bootError('ipad-main', error);
		throw error;
	}
}
