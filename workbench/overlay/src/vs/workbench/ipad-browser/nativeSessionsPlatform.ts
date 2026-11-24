import { registerNativeWindowServices, registerNativeCatalogServices } from './nativeSharedServices.js';
/*---------------------------------------------------------------------------------------------
 * Native replacements for the upstream Agents Window web service graph.
 * This module does not import the editor workbench entrypoint or its contribution graph.
 *--------------------------------------------------------------------------------------------*/
import '../../platform/meteredConnection/browser/meteredConnectionService.js';
import './nativeSearchService.js';
import './nativeTerminalProfileServices.js';
import { InstantiationType, registerSingleton } from '../../platform/instantiation/common/extensions.js';
import { ITelemetryService } from '../../platform/telemetry/common/telemetry.js';
import { NullTelemetryServiceShape } from '../../platform/telemetry/common/telemetryUtils.js';
import { IExtensionService } from '../services/extensions/common/extensions.js';
import { NativeIpadExtensionService } from './nativeExtensionService.js';
import { IExtensionGalleryService } from '../../platform/extensionManagement/common/extensionManagement.js';
import { NativeMarketplaceGalleryService } from './marketplaceRequestService.js';
import { ITaskService } from '../contrib/tasks/common/taskService.js';
import { NativeTaskService } from './nativeTaskSupport.js';
import { IUserDataSyncAccountService } from '../../platform/userDataSync/common/userDataSyncAccount.js';
import { IUserDataAutoSyncService, IUserDataSyncEnablementService } from '../../platform/userDataSync/common/userDataSync.js';
import { DisabledUserDataAutoSyncService, DisabledUserDataSyncAccountService, DisabledUserDataSyncEnablementService } from './disabledPlatformServices.js';
import { ISandboxHelperService } from '../../platform/sandbox/common/sandboxHelperService.js';
import { overrideServiceInstance } from './serviceOverrides.js';

registerSingleton(ITelemetryService, NullTelemetryServiceShape, InstantiationType.Delayed);
registerNativeWindowServices();
registerSingleton(IExtensionService, NativeIpadExtensionService, InstantiationType.Delayed);
registerSingleton(IExtensionGalleryService, NativeMarketplaceGalleryService, InstantiationType.Delayed);
registerSingleton(ITaskService, NativeTaskService, InstantiationType.Delayed);
registerNativeCatalogServices();
overrideServiceInstance(IUserDataSyncAccountService, new DisabledUserDataSyncAccountService());
overrideServiceInstance(IUserDataSyncEnablementService, new DisabledUserDataSyncEnablementService());
overrideServiceInstance(IUserDataAutoSyncService, new DisabledUserDataAutoSyncService());
overrideServiceInstance(ISandboxHelperService, {
 _serviceBrand: undefined,
 async checkSandboxDependencies() { throw new Error('Local terminal sandbox capability cannot be verified on iPad'); }
});
