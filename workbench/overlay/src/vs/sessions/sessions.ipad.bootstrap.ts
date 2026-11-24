/*---------------------------------------------------------------------------------------------
 * Sessions workbench with CodiPad's native filesystem, extension and process services.
 *--------------------------------------------------------------------------------------------*/
import { DisposableStore, isDisposable, toDisposable } from '../base/common/lifecycle.js';
import { domContentLoaded, getWindow } from '../base/browser/dom.js';
import { registerNativeViewportLayout } from '../workbench/ipad-browser/nativeViewportLayout.js';
import { URI } from '../base/common/uri.js';
import { removeTrailingPathSeparator } from '../base/common/resources.js';
import { Schemas } from '../base/common/network.js';
import { IndexedDB } from '../base/browser/indexedDB.js';
import { IndexedDBFileSystemProvider } from '../platform/files/browser/indexedDBFileSystemProvider.js';
import { FileSystemProviderErrorCode, IFileService, toFileSystemProviderErrorCode } from '../platform/files/common/files.js';
import { FileService } from '../platform/files/common/fileService.js';
import { InMemoryFileSystemProvider } from '../platform/files/common/inMemoryFilesystemProvider.js';
import { ILogService, ILoggerService, LogLevel, ConsoleLogger } from '../platform/log/common/log.js';
import { LogService } from '../platform/log/common/logService.js';
import { FileLoggerService } from '../platform/log/common/fileLog.js';
import { IProductService } from '../platform/product/common/productService.js';
import product from '../platform/product/common/product.js';
import { IInstantiationService, ServiceIdentifier } from '../platform/instantiation/common/instantiation.js';
import { ServiceCollection } from '../platform/instantiation/common/serviceCollection.js';
import { InstantiationType, registerSingleton } from '../platform/instantiation/common/extensions.js';
import { IUriIdentityService } from '../platform/uriIdentity/common/uriIdentity.js';
import { UriIdentityService } from '../platform/uriIdentity/common/uriIdentityService.js';
import { AGENTS_WINDOW_PROFILE_ID, IUserDataProfilesService } from '../platform/userDataProfile/common/userDataProfile.js';
import { BrowserUserDataProfilesService } from '../platform/userDataProfile/browser/userDataProfile.js';
import { IUserDataProfileService } from '../workbench/services/userDataProfile/common/userDataProfile.js';
import { UserDataProfileService } from '../workbench/services/userDataProfile/common/userDataProfileService.js';
import { BrowserWorkbenchEnvironmentService, IBrowserWorkbenchEnvironmentService } from '../workbench/services/environment/browser/environmentService.js';
import { IWorkspaceContextService } from '../platform/workspace/common/workspace.js';
import { getWorkspaceIdentifier } from '../platform/workspaces/common/workspaceIdentifier.js';
import { IWorkbenchConfigurationService } from '../workbench/services/configuration/common/configuration.js';
import { IConfigurationService } from '../platform/configuration/common/configuration.js';
import { ConfigurationCache } from '../workbench/services/configuration/common/configurationCache.js';
import { SessionsWorkspaceContextService } from './services/workspace/browser/workspaceContextService.js';
import { ConfigurationService } from './services/configuration/browser/configurationService.js';
import { IWorkspaceEditingService } from '../workbench/services/workspaces/common/workspaceEditing.js';
import { BrowserStorageService } from '../workbench/services/storage/browser/storageService.js';
import { IStorageService } from '../platform/storage/common/storage.js';
import { IWorkspaceTrustEnablementService, IWorkspaceTrustManagementService } from '../platform/workspace/common/workspaceTrust.js';
import { WorkspaceTrustEnablementService, WorkspaceTrustManagementService } from '../workbench/services/workspaces/common/workspaceTrust.js';
import { IDefaultAccountService } from '../platform/defaultAccount/common/defaultAccount.js';
import { DefaultAccountService } from '../workbench/services/accounts/browser/defaultAccount.js';
import { AccountPolicyService, IAccountPolicyGateService } from '../workbench/services/policies/common/accountPolicyService.js';
import { IPolicyService } from '../platform/policy/common/policy.js';
import { IFileManagedSettingsService, IManagedSettingsService, INativeManagedSettingsService, NullFileManagedSettingsService, NullNativeManagedSettingsService } from '../platform/policy/common/copilotManagedSettings.js';
import { IRemoteAuthorityResolverService, RemoteConnectionType } from '../platform/remote/common/remoteAuthorityResolver.js';
import { RemoteAuthorityResolverService } from '../platform/remote/electron-browser/remoteAuthorityResolverService.js';
import { IRemoteSocketFactoryService, RemoteSocketFactoryService } from '../platform/remote/common/remoteSocketFactoryService.js';
import { BrowserSocketFactory } from '../platform/remote/browser/browserSocketFactory.js';
import { IRemoteAgentService } from '../workbench/services/remote/common/remoteAgentService.js';
import { RemoteAgentService } from '../workbench/services/remote/browser/remoteAgentService.js';
import { RemoteFileSystemProviderClient } from '../workbench/services/remote/common/remoteFileSystemProviderClient.js';
import { ISignService } from '../platform/sign/common/sign.js';
import { SignService } from '../platform/sign/browser/signService.js';
import { RequiredMicrosoftSignService } from '../workbench/ipad-browser/nativeSignService.js';
import { IRequestService } from '../platform/request/common/request.js';
import { BrowserRequestService } from '../workbench/services/request/browser/requestService.js';
import { IUserDataInitializationService, UserDataInitializationService } from '../workbench/services/userData/browser/userDataInit.js';
import { IUpdateService } from '../platform/update/common/update.js';
import { IpadUpdateService } from '../workbench/ipad-browser/ipadUpdateService.js';
import { IWebWorkerService } from '../platform/webWorker/browser/webWorkerService.js';
import { IpadWebWorkerService } from '../workbench/ipad-browser/ipadWebWorkerService.js';
import { NativeFileSystemProvider } from '../workbench/ipad-browser/nativeFileSystemProvider.js';
import { NativeSecretStorageProvider } from '../workbench/ipad-browser/nativeSecretStorageProvider.js';
import { NativeURLService } from '../platform/url/common/urlService.js';
import { IURLService } from '../platform/url/common/url.js';
import { NativeExternalOpener } from '../workbench/ipad-browser/nativeExternalOpener.js';
import { IOpenerService } from '../platform/opener/common/opener.js';
import { IExtensionUrlHandler } from '../workbench/services/extensions/browser/extensionUrlHandler.js';
import { INotificationService, Severity } from '../platform/notification/common/notification.js';
import { registerNativeExtensionURLs } from '../workbench/ipad-browser/nativeExtensionURLs.js';
import { registerIncomingDocuments } from '../workbench/ipad-browser/incomingDocuments.js';
import { AbstractPathService, IPathService } from '../workbench/services/path/common/pathService.js';
import { ITitleService } from '../workbench/services/title/browser/titleService.js';
import { TitleService } from './browser/parts/titlebarPart.js';
import { registerIpadOverrides, OwnedService } from '../workbench/ipad-browser/serviceOverrides.js';
import { callNative, isNativeAvailable } from '../workbench/ipad-browser/nativeBridge.js';
import { createSessionsWorkbench } from './browser/workbenchFactory.js';
import { IFileDialogService } from '../platform/dialogs/common/dialogs.js';
import { IpadFileDialogService } from '../workbench/ipad-browser/ipadFileDialogService.js';
import { IEditorService } from '../workbench/services/editor/common/editorService.js';
import { ITerminalService } from '../workbench/contrib/terminal/browser/terminal.js';
import { ITaskService } from '../workbench/contrib/tasks/common/taskService.js';
import { IConfigurationResolverService } from '../workbench/services/configurationResolver/common/configurationResolver.js';
import { registerNativeTerminalBackend } from '../workbench/ipad-browser/nativeTerminalBackend.js';
import { registerNativeTaskSupport } from '../workbench/ipad-browser/nativeTaskSupport.js';
import { registerNativeTerminalKeyboard } from '../workbench/ipad-browser/nativeTerminalKeyboard.js';
import { registerNativeThemeBackground } from '../workbench/ipad-browser/nativeThemeBackground.js';
import { registerNativeWorkbenchActions } from '../workbench/ipad-browser/nativeWorkbenchActions.js';
import { registerNativeWorkbenchMenu } from '../workbench/ipad-browser/nativeWorkbenchMenu.js';
import { IThemeService } from '../platform/theme/common/themeService.js';
import { IMenuService } from '../platform/actions/common/actions.js';
import { IContextKeyService } from '../platform/contextkey/common/contextkey.js';
import { bootStep } from '../workbench/ipad-browser/boot.js';
import { configureNativeSessionsAgentHost } from '../workbench/ipad-browser/nativeSessionsAgentHost.js';

export async function main(): Promise<void> {
 const disposables = new DisposableStore();
 try { await start(disposables); } catch (error) { disposables.dispose(); throw error; }
}

async function start(disposables: DisposableStore): Promise<void> {
 if (!isNativeAvailable()) { throw new Error('Agents Window requires the CodiPad native bridge'); }
 const owned: OwnedService[] = [], collection = new ServiceCollection();
 const own = <T>(id: ServiceIdentifier<T>, instance: T): void => {
  collection.set(id, instance); owned.push([id as ServiceIdentifier<unknown>, instance]);
  if (isDisposable(instance)) { disposables.add(instance); }
 };
 const productService: IProductService = { _serviceBrand: undefined, ...product };
 own(IProductService, productService); own(IURLService, new NativeURLService(productService));
 const workspaceURI = URI.from({scheme: Schemas.vscodeUserData, path: '/User/agent-sessions.code-workspace'});
 const workspace = getWorkspaceIdentifier(workspaceURI);
 const provider = { workspace: undefined, trusted: false, payload: [['isSessionsWindow', 'true']],
  async open() { throw new Error('Opening a workspace from the Agents Window is not supported'); } };
 const env = Object.assign(new BrowserWorkbenchEnvironmentService(workspace.id, URI.from({scheme:'codipad-logs',path:'/logs'}), {
  workspaceProvider: provider, secretStorageProvider: new NativeSecretStorageProvider(), configurationDefaults: {'files.autoSave':'off'}
 }, productService), {supportsLocalNodeExtensionHost:true});
 own(IBrowserWorkbenchEnvironmentService, env);
 const log = new LogService(new ConsoleLogger(LogLevel.Info), []); own(ILogService, log);
 own(IWebWorkerService, new IpadWebWorkerService());
 const files = new FileService(log); own(IFileService, files);
 files.registerProvider(Schemas.file, disposables.add(new NativeFileSystemProvider()));
 const db = await IndexedDB.create('vscode-web-db', 3, ['vscode-userdata-store', 'vscode-logs-store', 'vscode-filehandles-store']);
 disposables.add(toDisposable(() => db.close()));
 files.registerProvider(Schemas.vscodeUserData, disposables.add(new IndexedDBFileSystemProvider(Schemas.vscodeUserData, db, 'vscode-userdata-store', true)));
 files.registerProvider(env.logsHome.scheme, disposables.add(new InMemoryFileSystemProvider()));
 for (const dir of [env.userRoamingDataHome, env.logsHome]) {
  try { await files.createFolder(dir); } catch (error) { if (toFileSystemProviderErrorCode(error instanceof Error ? error : new Error(String(error))) !== FileSystemProviderErrorCode.FileExists) { throw error; } }
 }
 own(ILoggerService, new FileLoggerService(LogLevel.Info, env.logsHome, files));
 const identity = new UriIdentityService(files); own(IUriIdentityService, identity);
 const profiles = new BrowserUserDataProfilesService(env, files, identity, log); own(IUserDataProfilesService, profiles);
 const profile = profiles.profiles.find(p => p.id === AGENTS_WINDOW_PROFILE_ID) ?? await profiles.createProfile(AGENTS_WINDOW_PROFILE_ID, 'Agents');
 if (profile.extensionsResource.toString() !== profiles.defaultProfile.extensionsResource.toString() ||
     profile.settingsResource.toString() !== profiles.defaultProfile.settingsResource.toString()) {
  throw new Error('Agents profile does not inherit the default profile settings and extensions');
 }
 const userProfile = new UserDataProfileService(profile); own(IUserDataProfileService, userProfile);
 const sockets = new RemoteSocketFactoryService(); sockets.register(RemoteConnectionType.WebSocket, new BrowserSocketFactory(undefined)); own(IRemoteSocketFactoryService, sockets);
 const resolver = new RemoteAuthorityResolverService(productService, {getResourceUriProvider: () => uri => uri}); own(IRemoteAuthorityResolverService, resolver);
 const requireMicrosoftSigning = (globalThis as typeof globalThis & {__codipadMicrosoftSigning?: boolean}).__codipadMicrosoftSigning === true;
 const sign = requireMicrosoftSigning ? new RequiredMicrosoftSignService(productService) : new SignService(productService); own(ISignService, sign);
 const remote = new RemoteAgentService(sockets, userProfile, env, productService, resolver, sign, log); own(IRemoteAgentService, remote);
 disposables.add(RemoteFileSystemProviderClient.register(remote, files, log));
 const account = new DefaultAccountService(productService); own(IDefaultAccountService, account);
 const nativeSettings = new NullNativeManagedSettingsService(), fileSettings = new NullFileManagedSettingsService();
 own(INativeManagedSettingsService, nativeSettings); own(IFileManagedSettingsService, fileSettings);
 const policy = new AccountPolicyService(log, account, undefined, nativeSettings, fileSettings);
 own(IPolicyService, policy); own(IAccountPolicyGateService, policy); own(IManagedSettingsService, policy);
 own(IUpdateService, new IpadUpdateService());
 const context = new SessionsWorkspaceContextService(workspace, identity);
 own(IWorkspaceContextService, context); own(IWorkspaceEditingService, context);
 const cache = new ConfigurationCache([Schemas.file, Schemas.vscodeUserData], env, files);
 const config = new ConfigurationService(userProfile, context, identity, files, policy, log, cache, env);
 await config.initialize(); own(IWorkbenchConfigurationService, config);
 const home = removeTrailingPathSeparator(URI.parse(await callNative<string>('process.home')));
 if (home.scheme !== Schemas.file || home.authority || home.query || home.fragment || !home.path.startsWith('/') || home.path.split('/').some(part => part === '.' || part === '..')) { throw new Error('Invalid native process home'); }
 own(IPathService, new class extends AbstractPathService { constructor() { super(home, remote, env, context); } }());
 const storage = new BrowserStorageService(workspace, userProfile, log); await storage.initialize(); own(IStorageService, storage);
 const trustEnabled = new WorkspaceTrustEnablementService(config as IWorkbenchConfigurationService & IConfigurationService, env);
 own(IWorkspaceTrustEnablementService, trustEnabled);
 own(IWorkspaceTrustManagementService, new WorkspaceTrustManagementService(config as IWorkbenchConfigurationService & IConfigurationService, resolver, storage, identity, env, context, trustEnabled, files));
 own(IUserDataInitializationService, new UserDataInitializationService());
 own(IRequestService, new BrowserRequestService(remote, config, collection.get(ILoggerService)! as ILoggerService));
 const agentHostAvailability = await configureNativeSessionsAgentHost();
 registerSingleton(ITitleService, TitleService, InstantiationType.Eager);
 registerIpadOverrides(owned);
 const container = document.getElementById('codipad-workbench-host'); if (!container) { throw new Error('Agents host element missing'); }
 await domContentLoaded(getWindow(container));
 const workbench = disposables.add(createSessionsWorkbench(container, undefined, collection, log));
 workbench.onDidShutdown(() => disposables.dispose());
 const services: IInstantiationService = workbench.startup();
 services.invokeFunction(a => a.get(IOpenerService).setDefaultExternalOpener(new NativeExternalOpener()));
 disposables.add(registerNativeViewportLayout(container, () => workbench.layout()));
 services.invokeFunction(a => {
  registerNativeTerminalBackend(a.get(ILogService), services); a.get(ITerminalService).registerProcessSupport(true);
  registerNativeTaskSupport(a.get(ITaskService), a.get(IConfigurationResolverService));
  const dialogs = a.get(IFileDialogService) as IpadFileDialogService;
  const editorService = a.get(IEditorService);
  const openResource = async (resource: URI) => { const pane = await editorService.openEditor({resource, options:{pinned:true}}); if (!pane) { throw new Error('The editor did not open the requested file'); } };
  dialogs.setHost({openResource, openFolder: async folder => context.addFolders([{uri:folder}])});
  const notifications = a.get(INotificationService);
  if (!agentHostAvailability.available) {
   if (agentHostAvailability.reason === 'sessionWorkspaceAuthorityUnavailable') {
    notifications.prompt(Severity.Warning, 'Local agent sessions need access to their working folders.', [{
     label: 'Select Folder', keepOpen: true, run: async () => {
      try {
       const result = await callNative<{ authorized: boolean }>('agentHost.reauthorizeDirectories');
       if (result.authorized) { window.location.reload(); }
      } catch (error) { notifications.error(error); }
     }
    }]);
   } else {
    notifications.warn(agentHostAvailability.reason === 'runtimeUnavailable' ? 'Local agent sessions require the optional agent host and the shared Linux runtime.' :
     'Local agent sessions are unavailable until CodiPad can securely authorize their working folders.');
   }
  }
  disposables.add(registerIncomingDocuments(openResource, error => notifications.error(error)));
  a.get(IExtensionUrlHandler);
  disposables.add(registerNativeExtensionURLs(a.get(IURLService), a.get(IOpenerService), () => notifications.error('The extension callback could not be opened. Please start the request again.')));
  disposables.add(registerNativeTerminalKeyboard(a.get(ITerminalService)));
  disposables.add(registerNativeThemeBackground(a.get(IThemeService)));
  disposables.add(registerNativeWorkbenchActions(dialogs));
  disposables.add(registerNativeWorkbenchMenu(a.get(IMenuService), a.get(IContextKeyService)));
 });
 bootStep('agents-workbench-started');
 bootStep('workbench-started');
}
