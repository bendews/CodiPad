import { IWebviewService } from '../contrib/webview/browser/webview.js';
import { NativeWebviewService } from './nativeWebviewService.js';
import { IFileDialogService } from '../../platform/dialogs/common/dialogs.js';
import { IpadFileDialogService } from './ipadFileDialogService.js';
import { IClipboardService } from '../../platform/clipboard/common/clipboardService.js';
import { NativeClipboardService } from './nativeClipboardService.js';
import { ExtensionTipsService } from '../../platform/extensionManagement/common/extensionTipsService.js';
import { IWorkbenchExtensionManagementService } from '../services/extensionManagement/common/extensionManagement.js';
import { ExtensionManagementService } from '../services/extensionManagement/common/extensionManagementService.js';
import { IExtensionManagementServerService } from '../services/extensionManagement/common/extensionManagement.js';
import { NativeExtensionManagementServerService } from './nativeExtensionManagementServerService.js';
import { IExtensionsScannerService } from '../../platform/extensionManagement/common/extensionsScannerService.js';
import { NativeExtensionsScannerService } from './nativeExtensionsScannerService.js';
import { UserDataSyncStoreManagementService } from '../../platform/userDataSync/common/userDataSyncStoreService.js';
import { IExtensionTipsService } from '../../platform/extensionManagement/common/extensionManagement.js';
import { IUserDataSyncStoreManagementService } from '../../platform/userDataSync/common/userDataSync.js';
import { InstantiationType, registerSingleton } from '../../platform/instantiation/common/extensions.js';

export function registerNativeWindowServices(): void {
	registerSingleton(IWebviewService, NativeWebviewService, InstantiationType.Delayed);
	registerSingleton(IFileDialogService, IpadFileDialogService, InstantiationType.Delayed);
	registerSingleton(IClipboardService, NativeClipboardService, InstantiationType.Delayed);
}

export function registerNativeCatalogServices(): void {
	registerSingleton(IExtensionTipsService, ExtensionTipsService, InstantiationType.Delayed);
	registerSingleton(IWorkbenchExtensionManagementService, ExtensionManagementService, InstantiationType.Delayed);
	registerSingleton(IExtensionManagementServerService, NativeExtensionManagementServerService, InstantiationType.Delayed);
	registerSingleton(IExtensionsScannerService, NativeExtensionsScannerService, InstantiationType.Delayed);
	registerSingleton(IUserDataSyncStoreManagementService, UserDataSyncStoreManagementService, InstantiationType.Delayed);
}
