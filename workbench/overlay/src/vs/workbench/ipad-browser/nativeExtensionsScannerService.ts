/*---------------------------------------------------------------------------------------------
 *  Native catalog visibility and upstream manifest/resource scanning.
 *--------------------------------------------------------------------------------------------*/

import { Emitter } from '../../base/common/event.js';
import { Mutable } from '../../base/common/types.js';
import { Disposable } from '../../base/common/lifecycle.js';
import { dirname, joinPath } from '../../base/common/resources.js';
import { URI } from '../../base/common/uri.js';
import { IEnvironmentService } from '../../platform/environment/common/environment.js';
import { IExtensionResourceLoaderService } from '../../platform/extensionResourceLoader/common/extensionResourceLoader.js';
import { AbstractExtensionsProfileScannerService, IExtensionsProfileScannerService, IProfileExtensionsScanOptions, IScannedProfileExtension } from '../../platform/extensionManagement/common/extensionsProfileScannerService.js';
import { IExtensionsScannerService, IScannedExtension, ManifestMetadata, NativeExtensionsScannerService as UpstreamNativeExtensionsScannerService, ScanOptions, SystemExtensionsScanOptions, UserExtensionsScanOptions } from '../../platform/extensionManagement/common/extensionsScannerService.js';
import { IExtension, IExtensionIdentifier, ExtensionType, TargetPlatform } from '../../platform/extensions/common/extensions.js';
import { FileOperationResult, IFileService, toFileOperationResult } from '../../platform/files/common/files.js';
import { IInstantiationService } from '../../platform/instantiation/common/instantiation.js';
import { ServiceCollection } from '../../platform/instantiation/common/serviceCollection.js';
import { ILogService } from '../../platform/log/common/log.js';
import { IProductService } from '../../platform/product/common/productService.js';
import { IUserDataProfilesService } from '../../platform/userDataProfile/common/userDataProfile.js';
import { IUriIdentityService } from '../../platform/uriIdentity/common/uriIdentity.js';
import { IUserDataProfileService } from '../services/userDataProfile/common/userDataProfile.js';
import { NativeExtensionCatalog, scanNativeCatalogIndex, scanNativeCatalogMetadata, scanNativePackageInventory, scannedExtensionToLocal, publishNativeExtensionResources } from './nativeExtensionCatalog.js';
import { ILocalExtension, IProductVersion, Metadata } from '../../platform/extensionManagement/common/extensionManagement.js';
import { areSameExtensions } from '../../platform/extensionManagement/common/extensionManagementUtil.js';
import { toExtensionDescription } from '../services/extensions/common/extensions.js';
import { callNative } from './nativeBridge.js';

class NativeExtensionsProfileScanner extends AbstractExtensionsProfileScannerService {
	constructor(home: URI, files: IFileService, profiles: IUserDataProfilesService, identity: IUriIdentityService, log: ILogService,
		private readonly validateProfile: (location: URI) => void,
		private readonly inventory: () => Promise<NativeExtensionCatalog['packages']>,
	) { super(home, files, profiles, identity, log); }

	protected override async withProfileExtensions(location: URI, update?: (extensions: Mutable<IScannedProfileExtension>[]) => IScannedProfileExtension[], options?: IProfileExtensionsScanOptions): Promise<IScannedProfileExtension[]> {
		const token = await callNative<string>('extension.profileFenceAcquire');
		try { return await super.withProfileExtensions(location, update, options); }
		finally { await callNative('extension.profileFenceRelease', { token, mutated: !!update }); }
	}

	async scanUnderFence(location: URI): Promise<IScannedProfileExtension[]> {
		const entries = await super.withProfileExtensions(location);
		await this.validatePackages(entries);
		return entries;
	}

	private async validatePackages(extensions: { location: URI; identifier: IExtensionIdentifier; version: string }[]): Promise<void> {
		if (!extensions.length) { return; }
		const packages = await this.inventory();
		for (const extension of extensions) {
			const entry = packages.find(entry => entry.extensionLocation === extension.location.toString());
			if (!entry || entry.isBuiltin || !areSameExtensions(extension.identifier, { id: `${entry.manifest.publisher}.${entry.manifest.name}` }) || entry.manifest.version !== extension.version) {
				throw new Error('[codipad-ext-scanner] Profile references an unknown or unsafe immutable package');
			}
		}
	}

	override async scanProfileExtensions(location: URI, options?: IProfileExtensionsScanOptions) {
		this.validateProfile(location);
		const entries = await super.scanProfileExtensions(location, options);
		await this.validatePackages(entries);
		return entries;
	}

	override async addExtensionsToProfile(extensions: [IExtension, Metadata | undefined][], location: URI, keepExistingVersions?: boolean) {
		await this.scanProfileExtensions(location);
		await this.validatePackages(extensions.map(([extension]) => ({ ...extension, version: extension.manifest.version })));
		return super.addExtensionsToProfile(extensions, location, keepExistingVersions);
	}

	override async updateMetadata(extensions: [IExtension, Metadata][], location: URI) {
		await this.scanProfileExtensions(location);
		const updated: IScannedProfileExtension[] = [];
		await this.withProfileExtensions(location, members => {
			const targets = extensions.map(([extension, metadata]) => {
				const member = members.find(member => member.location.toString() === extension.location.toString() && member.version === extension.manifest.version && areSameExtensions(member.identifier, extension.identifier));
				if (!member) { throw new Error('[codipad-ext-scanner] Metadata target is not a member of this profile'); }
				return { member, metadata };
			});
			for (const { member, metadata } of targets) {
				member.metadata = { ...member.metadata, ...metadata };
				updated.push(member);
			}
			return members;
		});
		return updated;
	}

	override async removeExtensionsFromProfile(extensions: IExtensionIdentifier[], location: URI, matches?: (extension: IScannedProfileExtension) => boolean) {
		await this.scanProfileExtensions(location);
		return super.removeExtensionsFromProfile(extensions, location, matches);
	}
}

/** Defer native resource preparation until scanning, so failed runtime startup cannot block editing. */
export class NativeExtensionsScannerService extends Disposable implements IExtensionsScannerService {
	declare readonly _serviceBrand: undefined;
	private readonly cacheChange = this._register(new Emitter<ExtensionType>());
	readonly onDidChangeCache = this.cacheChange.event;
	private preparation: Promise<UpstreamNativeExtensionsScannerService> | undefined;
	private locations: NativeExtensionCatalog['homes'] | undefined;
	private profiles: NativeExtensionsProfileScanner | undefined;

	constructor(
		@IExtensionResourceLoaderService private readonly resourceLoader: IExtensionResourceLoaderService,
		@IFileService private readonly fileService: IFileService,
		@ILogService private readonly logService: ILogService,
		@IEnvironmentService private readonly environmentService: IEnvironmentService,
		@IProductService private readonly productService: IProductService,
		@IUriIdentityService private readonly uriIdentityService: IUriIdentityService,
		@IUserDataProfilesService private readonly userDataProfilesService: IUserDataProfilesService,
		@IUserDataProfileService private readonly userDataProfileService: IUserDataProfileService,
		@IInstantiationService private readonly instantiationService: IInstantiationService,
	) {
		super();
	}

	get systemExtensionsLocation(): URI {
		if (!this.locations) { throw new Error('[codipad-ext-scanner] Native locations are unavailable before the first scan'); }
		return joinPath(this.locations.appRoot, 'extensions');
	}
	get userExtensionsLocation(): URI {
		if (!this.locations) { throw new Error('[codipad-ext-scanner] Native locations are unavailable before the first scan'); }
		return this.locations.extensionsHome;
	}

	private scanner(): Promise<UpstreamNativeExtensionsScannerService> {
		return this.preparation ??= this.prepare().catch(error => {
			this.preparation = undefined;
			throw error;
		});
	}

	private async prepare(): Promise<UpstreamNativeExtensionsScannerService> {
		const catalog = await scanNativeCatalogMetadata();
		this.locations = catalog.homes;
		// The upstream scanner immediately reads and localizes each selected manifest.
		const loadCatalog = () => scanNativeCatalogIndex();
		const skipBuiltins = new Set(this.environmentService.skipBuiltinExtensions?.map(id => id.toLowerCase()));
		class CatalogScanner extends UpstreamNativeExtensionsScannerService {
			protected override getTargetPlatform(): Promise<TargetPlatform> {
				return Promise.resolve(TargetPlatform.LINUX_ARM64);
			}

			private async scanCatalog(type: ExtensionType, options: ScanOptions, legacyOnly = false): Promise<IScannedExtension[]> {
				// Native selects immutable package identities and hides tombstoned versions. Enumerating
				// the package directory here would restore extensions the user already uninstalled.
				const catalog = await loadCatalog();
				const visible = catalog.installed.filter(extension => extension.type === type && (!legacyOnly || extension.isApplicationScoped) && !(type === ExtensionType.System && skipBuiltins.has(extension.identifier.id.toLowerCase())));
				const packagesByLocation = new Map<string, (typeof catalog.packages)[number]>();
				for (const entry of catalog.packages) {
					if (!packagesByLocation.has(entry.extensionLocation)) { packagesByLocation.set(entry.extensionLocation, entry); }
				}
				const results = await Promise.all(visible.map(async extension => {
					const scanned = await super.scanExistingExtension(extension.location, type, options);
					return scanned && {
						...scanned,
						targetPlatform: extension.targetPlatform,
						metadata: {
							...(packagesByLocation.get(extension.location.toString())?.metadata),
							isApplicationScoped: extension.isApplicationScoped,
							isMachineScoped: extension.isMachineScoped,
							pinned: extension.pinned,
							targetPlatform: extension.targetPlatform,
						},
					};
				}));
				return results.filter((extension): extension is NonNullable<typeof extension> => extension !== null);
			}

			override scanSystemExtensions(options: SystemExtensionsScanOptions): Promise<IScannedExtension[]> { return this.scanCatalog(ExtensionType.System, options); }
			override scanAllUserExtensions(): Promise<IScannedExtension[]> { return this.scanCatalog(ExtensionType.User, { includeInvalid: true }, true); }
		}

		// The upstream default initializer calls scanAllUserExtensions once; seed legacy app-wide
		// membership only. Never revive an orphaned profile-local publication on initialization.
		const profiles = this.profiles = this._register(new NativeExtensionsProfileScanner(catalog.homes.extensionsHome, this.fileService, this.userDataProfilesService, this.uriIdentityService, this.logService,
			location => this.assertProfile(location), scanNativePackageInventory));
		const instantiation = this._register(this.instantiationService.createChild(new ServiceCollection([IExtensionsProfileScannerService, profiles])));
		const scanner = this._register(new CatalogScanner(
			this.systemExtensionsLocation, this.userExtensionsLocation, catalog.homes.globalStorageHome,
			this.userDataProfileService.currentProfile, this.userDataProfilesService, profiles,
			this.fileService, this.logService, this.environmentService, this.productService,
			this.uriIdentityService, instantiation,
		));
		this._register(scanner.onDidChangeCache(type => this.cacheChange.fire(type)));
		return scanner;
	}

	async scanAllExtensions(system: SystemExtensionsScanOptions, user: UserExtensionsScanOptions): Promise<IScannedExtension[]> {
		await this.profileScanner(user.profileLocation);
		return (await this.scanner()).scanAllExtensions(system, { ...user, useCache: false });
	}
	async scanSystemExtensions(options: SystemExtensionsScanOptions): Promise<IScannedExtension[]> { return (await this.scanner()).scanSystemExtensions(options); }
	async scanUserExtensions(options: UserExtensionsScanOptions): Promise<IScannedExtension[]> {
		await this.profileScanner(options.profileLocation);
		return (await this.scanner()).scanUserExtensions({ ...options, useCache: false });
	}
	async scanAllUserExtensions(): Promise<IScannedExtension[]> {
		const catalog = await scanNativeCatalogMetadata();
		const scanner = await this.scanner();
		const result: IScannedExtension[] = [];
		for (const entry of catalog.packages.filter(entry => !entry.isBuiltin)) {
			const scanned = await scanner.scanExistingExtension(URI.parse(entry.extensionLocation), ExtensionType.User, { includeInvalid: true });
			if (scanned) { result.push({ ...scanned, metadata: entry.metadata, targetPlatform: entry.metadata?.targetPlatform ?? scanned.targetPlatform }); }
		}
		return result;
	}
	async scanExtensionsUnderDevelopment(existing: IScannedExtension[], options: ScanOptions): Promise<IScannedExtension[]> { return (await this.scanner()).scanExtensionsUnderDevelopment(existing, options); }
	async scanExistingExtension(location: URI, type: ExtensionType, options: ScanOptions): Promise<IScannedExtension | null> { return (await this.scanner()).scanExistingExtension(location, type, options); }
	async scanMultipleExtensions(locations: URI[], type: ExtensionType, options: ScanOptions): Promise<IScannedExtension[]> { return (await this.scanner()).scanMultipleExtensions(locations, type, options); }
	async scanOneOrMultipleExtensions(location: URI, type: ExtensionType, options: ScanOptions): Promise<IScannedExtension[]> { return (await this.scanner()).scanOneOrMultipleExtensions(location, type, options); }
	async initializeDefaultProfileExtensions(): Promise<void> { return (await this.scanner()).initializeDefaultProfileExtensions(); }

	assertProfile(location: URI): void {
		if (location.query || location.fragment || location.path.includes('\0') || !this.userDataProfilesService.profiles.some(profile => this.uriIdentityService.extUri.isEqual(profile.extensionsResource, location))) {
			throw new Error('[codipad-ext-scanner] Unknown extension profile');
		}
	}

	async profileScanner(location: URI): Promise<NativeExtensionsProfileScanner> {
		this.assertProfile(location);
		const scanner = await this.scanner();
		await scanner.initializeDefaultProfileExtensions();
		// Upstream logs initialization failures; confirm the manifest exists before any install.
		const defaultLocation = this.userDataProfilesService.defaultProfile.extensionsResource;
		const [, parent] = await Promise.all([
			this.profiles!.scanProfileExtensions(defaultLocation, { bailOutWhenFileNotFound: true }),
			this.fileService.stat(dirname(location)),
		]);
		if (!parent.isDirectory) {
			throw new Error('[codipad-ext-scanner] Profile manifest parent is not an authorized directory');
		} // Native filesystem revalidates the live grant.
		if (!this.uriIdentityService.extUri.isEqual(defaultLocation, location)) {
			await this.profiles!.scanProfileExtensions(location);
		}
		return this.profiles!;
	}

	async installed(profileLocation = this.userDataProfileService.currentProfile.extensionsResource, type?: ExtensionType, productVersion?: IProductVersion): Promise<ILocalExtension[]> {
		const options = { profileLocation, productVersion, includeInvalid: true };
		const extensions = type === ExtensionType.User ? await this.scanUserExtensions(options)
			: type === ExtensionType.System ? await this.scanSystemExtensions({}) : await this.scanAllExtensions({}, options);
		await publishNativeExtensionResources(extensions.map(extension => extension.location));
		return Promise.all(extensions.map(extension => scannedExtensionToLocal(extension, this.resourceLoader, this.logService)));
	}

	/** Host homes are fixed when the scanner is prepared, independent of profile membership. */
	async nativeHomes(): Promise<NativeExtensionCatalog['homes']> {
		await this.scanner();
		return this.locations!;
	}

	async cleanUp(): Promise<void> {
		await this.profileScanner(this.userDataProfilesService.defaultProfile.extensionsResource);
		const token = await callNative<string>('extension.profileFenceAcquire');
		try {
			const profiles = new Map(this.userDataProfilesService.profiles.map(profile => [profile.extensionsResource.toString(), profile.extensionsResource]));
			// A profile created in another window may already have a manifest while its broadcast is still queued.
			const home = this.userDataProfilesService.profilesHome;
			for (const directory of [home, joinPath(home, 'builtin')]) {
				try {
					const children = (await this.fileService.resolve(directory)).children;
					if (!children) { throw new Error('Cannot enumerate extension profiles'); }
					for (const child of children) {
						if (child.isSymbolicLink) { throw new Error('Cannot establish the location of a linked extension profile'); }
						if (child.isDirectory) {
							const manifest = joinPath(child.resource, 'extensions.json');
							profiles.set(manifest.toString(), manifest);
						}
					}
				} catch (error) {
					if (toFileOperationResult(error) !== FileOperationResult.FILE_NOT_FOUND) { throw error; }
				}
			}
			const references = new Set<string>();
			for (const location of profiles.values()) {
				for (const extension of await this.profiles!.scanUnderFence(location)) { references.add(extension.location.toString()); }
			}
			await callNative('extension.collect', { token, references: [...references] });
		} finally { await callNative('extension.profileFenceRelease', { token }); }
	}

	async descriptions(): Promise<ReturnType<typeof toExtensionDescription>[]> {
		return (await this.installed()).filter(extension => extension.isValid).map(extension => toExtensionDescription(extension));
	}

	async descriptionKey(): Promise<string | undefined> {
		const location = this.userDataProfileService.currentProfile.extensionsResource;
		const profiles = await this.profileScanner(location);
		const members = await profiles.scanProfileExtensions(location);
		const generation = await callNative<string | null>('exthost.catalogGeneration');
		if (generation === null) { return undefined; }
		return JSON.stringify([location.toString(), generation, TargetPlatform.LINUX_ARM64, members]);
	}

	async catalog(): Promise<NativeExtensionCatalog> {
		const [native, installed] = await Promise.all([scanNativeCatalogMetadata(), this.installed()]);
		return { ...native, installed, descriptions: installed.filter(extension => extension.isValid).map(extension => toExtensionDescription(extension)) };
	}

	async updateManifestMetadata(_location: URI, _metadata: ManifestMetadata): Promise<void> {
		throw new Error('[codipad-ext-scanner] Immutable package metadata cannot be rewritten; update profile membership metadata');
	}
}
