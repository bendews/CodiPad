/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench — native extension catalog for bundled and user-installed extensions.
 *
 *  Contract (`exthost.scan`, implemented by the shell):
 *
 *    exthost.scan {} -> {
 *      extensions: [{ manifest: object, extensionLocation: 'file://…', isBuiltin?: true, metadata?: object }],
 *      appRoot: 'file://…', globalStorageHome: 'file://…',
 *      workspaceStorageHome: 'file://…', logsLocation: 'file://…'
 *    }
 *
 *  Native owns install paths and returns the same scan shape after install. Reading extension
 *  resources from the renderer still needs a native grant for those paths (handled by the shell).
 *---------------------------------------------------------------------------------------------*/

import * as platform from '../../base/common/platform.js';
import { joinPath, removeTrailingPathSeparator } from '../../base/common/resources.js';
import { URI } from '../../base/common/uri.js';
import { ExtensionType, IExtensionDescription, IExtensionManifest, TargetPlatform } from '../../platform/extensions/common/extensions.js';
import { IScannedExtension } from '../../platform/extensionManagement/common/extensionsScannerService.js';
import { ILocalExtension, Metadata } from '../../platform/extensionManagement/common/extensionManagement.js';
import { getGalleryExtensionId } from '../../platform/extensionManagement/common/extensionManagementUtil.js';
import { IExtensionResourceLoaderService } from '../../platform/extensionResourceLoader/common/extensionResourceLoader.js';
import { FileOperationResult, toFileOperationResult } from '../../platform/files/common/files.js';
import { ILogService } from '../../platform/log/common/log.js';
import { ITranslations, localizeManifest } from '../../platform/extensionManagement/common/extensionNls.js';
import { toExtensionDescription } from '../services/extensions/common/extensions.js';
import { callNative } from './nativeBridge.js';
import { installCatalogBrowserResourceRoots, isCanonicalNativeFileUri } from './nativeBrowserResources.js';

export interface NativeExtensionCatalogEntry {
	readonly manifest: Record<string, unknown>;
	readonly extensionLocation: string;
	readonly isBuiltin?: boolean;
	readonly metadata?: Partial<Metadata>;
}

export interface NativeExtensionHomes {
	readonly appRoot: URI;
	readonly extensionsHome: URI;
	readonly globalStorageHome: URI;
	readonly workspaceStorageHome: URI;
	readonly logsLocation: URI;
}

export interface NativeExtensionCatalog {
	readonly descriptions: IExtensionDescription[];
	readonly installed: ILocalExtension[];
	readonly packages: NativeExtensionCatalogEntry[];
	readonly homes: NativeExtensionHomes;
}

function requireFileUri(value: unknown, field: string): URI {
	if (typeof value !== 'string' || !value.startsWith('file:')) {
		console.error('[codipad-ext-catalog] rejected native URI', JSON.stringify({
			field,
			valueType: typeof value,
			filePrefix: typeof value === 'string' && value.startsWith('file:'),
		}));
		throw new Error(`[codipad-ext-catalog] ${field} must be a file: URI`);
	}

	const uri = URI.parse(value);
	if (!isCanonicalNativeFileUri(uri)) {
		throw new Error(`[codipad-ext-catalog] ${field} is not a canonical local file URI`);
	}
	return removeTrailingPathSeparator(uri);
}

function containsNlsPlaceholder(value: unknown): boolean {
	if (typeof value === 'string') {
		return value.length > 1 && value.startsWith('%') && value.endsWith('%');
	}
	if (Array.isArray(value)) {
		return value.some(containsNlsPlaceholder);
	}
	if (value && typeof value === 'object') {
		return Object.values(value).some(containsNlsPlaceholder);
	}
	return false;
}

async function readTranslations(
	uri: URI,
	resourceLoader: IExtensionResourceLoaderService,
	logService: ILogService
): Promise<ITranslations | undefined> {
	try {
		const translations: unknown = JSON.parse(await resourceLoader.readExtensionResource(uri));
		if (!translations || typeof translations !== 'object' || Array.isArray(translations)) {
			throw new Error('Expected an extension NLS JSON object');
		}
		return translations as ITranslations;
	} catch (error) {
		if (toFileOperationResult(error as Error) !== FileOperationResult.FILE_NOT_FOUND) {
			logService.error(`[codipad-ext-catalog] failed to read extension translations at ${uri.toString()}`, error);
		}
		return undefined;
	}
}

/** Apply package.nls translations using the pinned upstream manifest localization rules. */
async function localizeNativeManifest(
	manifest: IExtensionManifest,
	location: URI,
	resourceLoader: IExtensionResourceLoaderService,
	logService: ILogService
): Promise<IExtensionManifest> {
	if (!containsNlsPlaceholder(manifest)) {
		return manifest;
	}

	const fallback = await readTranslations(joinPath(location, 'package.nls.json'), resourceLoader, logService);
	let translations: ITranslations | undefined;
	if (platform.language) {
		let language = platform.language;
		while (language) {
			translations = await readTranslations(joinPath(location, `package.nls.${language}.json`), resourceLoader, logService);
			if (translations) {
				break;
			}
			const separator = language.lastIndexOf('-');
			if (separator <= 0) {
				break;
			}
			language = language.slice(0, separator);
		}
	}

	translations ??= fallback;
	if (!translations) {
		return manifest;
	}
	return localizeManifest(logService, manifest, translations, translations === fallback ? undefined : fallback);
}

function validateNativeEntry(entry: NativeExtensionCatalogEntry, index: number): { manifest: Record<string, unknown> & { publisher: string; name: string; version: string }; location: URI } {
	const manifest = entry?.manifest;
	if (!manifest || typeof manifest !== 'object' || typeof manifest.publisher !== 'string' || typeof manifest.name !== 'string' || typeof manifest.version !== 'string') {
		throw new Error(`[codipad-ext-catalog] extension[${index}] manifest needs publisher, name and version`);
	}
	const location = requireFileUri(entry.extensionLocation, `extensions[${index}].extensionLocation`);
	return { manifest: manifest as Record<string, unknown> & { publisher: string; name: string; version: string }, location };
}

/** Convert a native scan/install entry using the same upstream extension description conversion. */
export async function nativeExtensionToLocal(
	entry: NativeExtensionCatalogEntry,
	resourceLoader: IExtensionResourceLoaderService,
	logService: ILogService,
	index = 0,
	localize = true
): Promise<ILocalExtension> {
	const { manifest, location } = validateNativeEntry(entry, index);
	const manifestCopy = JSON.parse(JSON.stringify(manifest)) as IExtensionManifest;
	const localizedManifest = localize ? await localizeNativeManifest(manifestCopy, location, resourceLoader, logService) : manifestCopy;
	const metadata = entry.metadata;
	return {
		type: entry.isBuiltin ? ExtensionType.System : ExtensionType.User,
		isBuiltin: !!entry.isBuiltin,
		identifier: { id: getGalleryExtensionId(manifest.publisher, manifest.name), uuid: metadata?.id },
		manifest: { ...localizedManifest, version: String(manifest.version) },
		location,
		targetPlatform: metadata?.targetPlatform ?? TargetPlatform.UNIVERSAL,
		validations: [],
		isValid: true,
		preRelease: !!metadata?.preRelease,
		publisherDisplayName: metadata?.publisherDisplayName,
		isWorkspaceScoped: false,
		isMachineScoped: !!metadata?.isMachineScoped,
		isApplicationScoped: metadata?.isApplicationScoped ?? !entry.isBuiltin,
		publisherId: metadata?.publisherId ?? null,
		installedTimestamp: metadata?.installedTimestamp,
		isPreReleaseVersion: !!metadata?.isPreReleaseVersion,
		hasPreReleaseVersion: !!metadata?.hasPreReleaseVersion,
		private: !!metadata?.private,
		updated: !!metadata?.updated,
		pinned: !!metadata?.pinned,
		forceAutoUpdate: false,
		source: metadata?.source ?? (entry.isBuiltin ? 'resource' : 'gallery'),
		size: metadata?.size ?? 0,
	};
}

interface RawNativeCatalog {
	browserResourceRoots?: { extensionLocation: string; browserRoot: string }[];
	extensions?: NativeExtensionCatalogEntry[];
	packages?: NativeExtensionCatalogEntry[];
	appRoot?: string;
	extensionsHome?: string;
	globalStorageHome?: string;
	workspaceStorageHome?: string;
	logsLocation?: string;
}

/** Fetch and validate every response anew; profile changes are never cached. */
async function readNativeCatalog(): Promise<{ raw: RawNativeCatalog; homes: NativeExtensionHomes; packages: NativeExtensionCatalogEntry[] }> {
	const raw = await callNative<RawNativeCatalog>('exthost.scan', {});
	if (!Array.isArray(raw?.extensions) || !Array.isArray(raw?.packages)) {
		throw new Error('[codipad-ext-catalog] exthost.scan did not return extensions and immutable packages');
	}
	for (let index = 0; index < raw.extensions.length; index++) { validateNativeEntry(raw.extensions[index], index); }
	const homes: NativeExtensionHomes = {
		appRoot: requireFileUri(raw.appRoot, 'appRoot'),
		extensionsHome: requireFileUri(raw.extensionsHome, 'extensionsHome'),
		globalStorageHome: requireFileUri(raw.globalStorageHome, 'globalStorageHome'),
		workspaceStorageHome: requireFileUri(raw.workspaceStorageHome, 'workspaceStorageHome'),
		logsLocation: requireFileUri(raw.logsLocation, 'logsLocation'),
	};
	const packages = raw.packages.map((entry, index) => ({ ...entry, extensionLocation: requireFileUri(entry.extensionLocation, `packages[${index}].extensionLocation`).toString() }));
	installCatalogBrowserResourceRoots(raw.browserResourceRoots, raw.extensions.filter(entry => entry.isBuiltin).map(entry => entry.extensionLocation), packages.map(entry => entry.extensionLocation));
	return { raw, homes, packages };
}

/** Publish only packages selected by the profile scanner. */
export async function publishNativeExtensionResources(locations: readonly URI[]): Promise<void> {
	const uris = [...new Set(locations.map(uri => uri.toString()))];
	const roots = await callNative<unknown>('extension.publishBrowserResources', { uris });
	installCatalogBrowserResourceRoots(roots, uris);
}

/** Read only stable homes and immutable package identities from a fresh response. */
export async function scanNativeCatalogMetadata(): Promise<Pick<NativeExtensionCatalog, 'homes' | 'packages'>> {
	const { homes, packages } = await readNativeCatalog();
	return { homes, packages };
}

/** Validate immutable membership without localizing unrelated installed manifests. */
export async function scanNativePackageInventory(): Promise<NativeExtensionCatalogEntry[]> {
	return (await readNativeCatalog()).packages;
}

/** Select package identities without constructing manifests that the upstream scanner rereads. */
export async function scanNativeCatalogIndex() {
	const { raw, packages } = await readNativeCatalog();
	const installed = raw.extensions!.map((entry, index) => {
		const { manifest, location } = validateNativeEntry(entry, index);
		const metadata = entry.metadata;
		return {
			location,
			identifier: { id: getGalleryExtensionId(manifest.publisher, manifest.name), uuid: metadata?.id },
			type: entry.isBuiltin ? ExtensionType.System : ExtensionType.User,
			isApplicationScoped: metadata?.isApplicationScoped ?? !entry.isBuiltin,
			isMachineScoped: !!metadata?.isMachineScoped,
			pinned: !!metadata?.pinned,
			targetPlatform: metadata?.targetPlatform ?? TargetPlatform.UNIVERSAL,
		};
	});
	return { installed, packages };
}

/** Reads the native catalog once. Never invents an extension that native did not report. */
export async function scanNativeExtensions(
	resourceLoader: IExtensionResourceLoaderService,
	logService: ILogService,
	localize = true
): Promise<NativeExtensionCatalog> {
	const { raw, homes, packages } = await readNativeCatalog();
	const installed = await Promise.all(raw.extensions!.map((entry, index) => nativeExtensionToLocal(entry, resourceLoader, logService, index, localize)));
	return { descriptions: installed.map(extension => toExtensionDescription(extension)), installed, homes, packages };
}

/** Keep profile metadata authoritative when adapting the stock scanner for management/activation. */
export async function scannedExtensionToLocal(extension: IScannedExtension, resourceLoader: IExtensionResourceLoaderService, logService: ILogService): Promise<ILocalExtension> {
	const local = await nativeExtensionToLocal({ manifest: extension.manifest as unknown as Record<string, unknown>, extensionLocation: extension.location.toString(),
		isBuiltin: extension.type === ExtensionType.System, metadata: { ...extension.metadata, isApplicationScoped: !!extension.metadata?.isApplicationScoped } }, resourceLoader, logService);
	return { ...local, isBuiltin: extension.isBuiltin, isValid: extension.isValid, validations: extension.validations, targetPlatform: extension.targetPlatform };
}
