/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench — upstream Marketplace install engine with a native package task.
 *
 *  AbstractExtensionManagementService owns gallery compatibility selection, policy, dependency
 *  orchestration, control-manifest caching, install deduplication and normal result events. The
 *  native store owns the package download, verification, extraction and install location.
 *--------------------------------------------------------------------------------------------*/

import { Emitter, Event } from '../../base/common/event.js';
import { URI } from '../../base/common/uri.js';
import { IExtensionGalleryService, IExtensionIdentifier, IExtensionsControlManifest, ILocalExtension, IGalleryExtension, InstallOptions, InstallOperation, IProductVersion, Metadata, IAllowedExtensionsService, ExtensionManagementError, ExtensionManagementErrorCode, shouldRequireRepositorySignatureFor } from '../../platform/extensionManagement/common/extensionManagement.js';
import { IExtensionGalleryManifestService } from '../../platform/extensionManagement/common/extensionGalleryManifest.js';
import { AbstractExtensionManagementService, IInstallExtensionTask, InstallExtensionTaskOptions, IUninstallExtensionTask, UninstallExtensionTaskOptions } from '../../platform/extensionManagement/common/abstractExtensionManagementService.js';
import { ExtensionType, IExtensionManifest, TargetPlatform } from '../../platform/extensions/common/extensions.js';
import { IProductService } from '../../platform/product/common/productService.js';
import { ITelemetryService } from '../../platform/telemetry/common/telemetry.js';
import { IUriIdentityService } from '../../platform/uriIdentity/common/uriIdentity.js';
import { ILogService } from '../../platform/log/common/log.js';
import { IExtensionResourceLoaderService } from '../../platform/extensionResourceLoader/common/extensionResourceLoader.js';
import { IUserDataProfilesService } from '../../platform/userDataProfile/common/userDataProfile.js';
import { ILifecycleService, LifecyclePhase } from '../services/lifecycle/common/lifecycle.js';
import { DidChangeProfileEvent, IProfileAwareExtensionManagementService } from '../services/extensionManagement/common/extensionManagement.js';
import { IUserDataProfileService } from '../services/userDataProfile/common/userDataProfile.js';
import { getGalleryExtensionId, areSameExtensions } from '../../platform/extensionManagement/common/extensionManagementUtil.js';
import { isEngineValid } from '../../platform/extensions/common/extensionValidator.js';
import { NativeExtensionCatalogEntry, nativeExtensionToLocal } from './nativeExtensionCatalog.js';
import { CancellationError } from '../../base/common/errors.js';
import { generateUuid } from '../../base/common/uuid.js';
import { NativeCallError, callNative } from './nativeBridge.js';

import { IExtensionsScannerService } from '../../platform/extensionManagement/common/extensionsScannerService.js';
import { NativeExtensionsScannerService } from './nativeExtensionsScannerService.js';
import { delta } from '../../base/common/arrays.js';
import { compare } from '../../base/common/strings.js';

const NOT_SUPPORTED = 'native extension management does not support this operation';

function refuse<T = never>(operation: string): Promise<T> {
	return Promise.reject(new Error(`[codipad-ext-mgmt] ${operation}: ${NOT_SUPPORTED}`));
}

/** A single upstream install task whose physical package operation is owned by the native store. */
class NativePackageInstallTask implements IInstallExtensionTask {
	readonly identifier: IExtensionIdentifier;
	private _operation = InstallOperation.Install;
	get operation(): InstallOperation { return this.options.operation ?? this._operation; }
	private promise: Promise<ILocalExtension> | undefined;
	private readonly requestId = generateUuid();
	private cancelled = false;
	private nativeStarted = false;

	constructor(
		readonly manifest: IExtensionManifest,
		readonly source: URI | IGalleryExtension,
		readonly options: InstallExtensionTaskOptions,
		private readonly logService: ILogService,
		private readonly getInstalled: () => Promise<ILocalExtension[]>,
		private readonly commitMembership: (entry: NativeExtensionCatalogEntry) => Promise<ILocalExtension>,
	) {
		this.identifier = URI.isUri(source) ? { id: getGalleryExtensionId(manifest.publisher, manifest.name) } : source.identifier;
	}

	run(): Promise<ILocalExtension> {
		return this.promise ??= this.install().catch(error => {
			if (error instanceof NativeCallError && error.code === 'Cancelled') {
				throw new CancellationError();
			}
			throw error;
		});
	}

	waitUntilTaskIsFinished(): Promise<ILocalExtension> {
		return this.run();
	}

	cancel(): void {
		this.cancelled = true;
		if (this.nativeStarted) {
			// The original install reply decides whether cancellation beat publication.
			void callNative('extension.cancelInstall', { requestId: this.requestId }).catch(error => this.logService.error(error));
		}
	}

	private async install(): Promise<ILocalExtension> {
		if (this.cancelled) { throw new CancellationError(); }
		const previous = (await this.getInstalled()).find(extension => areSameExtensions(extension.identifier, this.identifier));
		if (previous) {
			this._operation = InstallOperation.Update;
		}
		if (this.cancelled) { throw new CancellationError(); }
		const metadataOptions = {
			isApplicationScoped: !!this.options.isApplicationScoped,
			pinned: this.options.installGivenVersion || (this.options.pinned ?? previous?.pinned ?? false),
			isMachineScoped: this.options.isMachineScoped ?? previous?.isMachineScoped ?? false,
			preRelease: this.options.preRelease ?? (!!this.options.installPreReleaseVersion || !!previous?.preRelease),
			hasPreReleaseVersion: previous?.hasPreReleaseVersion ?? false,
		};
		this.nativeStarted = true;
		if (URI.isUri(this.source)) {
			const entry = await callNative<import('./nativeExtensionCatalog.js').NativeExtensionCatalogEntry>('extension.installVSIX', {
				requestId: this.requestId,
				uri: this.source.toString(),
				id: this.identifier.id,
				version: this.manifest.version,
				options: {
					...metadataOptions,
					...(this.options.installGivenVersion ? { pinned: true } : typeof this.options.pinned === 'boolean' ? { pinned: this.options.pinned } : {}),
					...(typeof this.options.isMachineScoped === 'boolean' ? { isMachineScoped: this.options.isMachineScoped } : {}),
				},
			});
			return this.commitMembership(entry);
		}
		const targetPlatform = this.source.properties.targetPlatform;
		if (!targetPlatform || !this.source.assets.download.uri) {
			throw new Error(`[codipad-ext-mgmt] installGalleryExtensions: Marketplace result ${this.identifier.id} is missing its target platform or download URI`);
		}
		const entry = await callNative<{
			manifest: Record<string, unknown>;
			extensionLocation: string;
			isBuiltin?: boolean;
			metadata?: Partial<Metadata>;
		}>('extension.install', {
			requestId: this.requestId,
			id: this.identifier.id,
			version: this.source.version,
			targetPlatform,
			downloadUri: this.source.assets.download.uri,
			options: {
				...metadataOptions,
				...(this.options.installGivenVersion ? { pinned: true } : typeof this.options.pinned === 'boolean' ? { pinned: this.options.pinned } : {}),
				...(typeof this.options.preRelease === 'boolean' ? { preRelease: this.options.preRelease } : {}),
				...(typeof this.options.isMachineScoped === 'boolean' ? { isMachineScoped: this.options.isMachineScoped } : {}),
				installPreReleaseVersion: !!this.options.installPreReleaseVersion,
				isPreReleaseVersion: !!this.source.properties.isPreReleaseVersion,
				hasPreReleaseVersion: !!this.source.hasPreReleaseVersion,
			},
		});
		return this.commitMembership(entry);
	}
}

export class BundledExtensionManagementService extends AbstractExtensionManagementService implements IProfileAwareExtensionManagementService {
	declare readonly _serviceBrand: undefined;

	private readonly profileChange = this._register(new Emitter<DidChangeProfileEvent>());
	readonly onDidChangeProfile = this.profileChange.event;
	get onProfileAwareDidInstallExtensions() { return super.onDidInstallExtensions; }
	get onProfileAwareDidUninstallExtension() { return super.onDidUninstallExtension; }
	get onProfileAwareDidUpdateExtensionMetadata() { return super.onDidUpdateExtensionMetadata; }
	override get onInstallExtension() { return Event.filter(super.onInstallExtension, e => this.filterEvent(e), this._store); }
	override get onDidInstallExtensions() { return Event.filter(Event.map(this.onProfileAwareDidInstallExtensions, results => results.filter(e => this.filterEvent(e)), this._store), results => results.length > 0, this._store); }
	override get onUninstallExtension() { return Event.filter(super.onUninstallExtension, e => this.filterEvent(e), this._store); }
	override get onDidUninstallExtension() { return Event.filter(this.onProfileAwareDidUninstallExtension, e => this.filterEvent(e), this._store); }
	override get onDidUpdateExtensionMetadata() { return Event.filter(this.onProfileAwareDidUpdateExtensionMetadata, e => this.filterEvent({ ...e, applicationScoped: e.local.isApplicationScoped }), this._store); }

	private filterEvent({ profileLocation, applicationScoped }: { profileLocation?: URI; applicationScoped?: boolean }): boolean {
		return !!applicationScoped || !profileLocation || this.uriIdentityService.extUri.isEqual(profileLocation, this.getCurrentExtensionsManifestLocation());
	}

	constructor(
		@IExtensionGalleryService galleryService: IExtensionGalleryService,
		@ITelemetryService telemetryService: ITelemetryService,
		@IUriIdentityService uriIdentityService: IUriIdentityService,
		@ILogService logService: ILogService,
		@IProductService productService: IProductService,
		@IAllowedExtensionsService allowedExtensionsService: IAllowedExtensionsService,
		@IUserDataProfilesService userDataProfilesService: IUserDataProfilesService,
		@IExtensionResourceLoaderService private readonly resourceLoader: IExtensionResourceLoaderService,
		@IUserDataProfileService private readonly userDataProfileService: IUserDataProfileService,
		@IExtensionsScannerService private readonly scanner: NativeExtensionsScannerService,
		@IExtensionGalleryManifestService private readonly galleryManifest: IExtensionGalleryManifestService,
		@ILifecycleService lifecycle: ILifecycleService,
	) {
		super(galleryService, telemetryService, uriIdentityService, logService, productService, allowedExtensionsService, userDataProfilesService);
		void lifecycle.when(LifecyclePhase.Eventually).then(() => this.cleanUp()).catch(error => logService.error('Error cleaning up extensions', error));
		this._register(userDataProfileService.onDidChangeCurrentProfile(e => {
			if (!this.uriIdentityService.extUri.isEqual(e.previous.extensionsResource, e.profile.extensionsResource)) {
				e.join((async () => {
					const previous = await this.getInstalled(ExtensionType.User, e.previous.extensionsResource);
					const current = await this.getInstalled(ExtensionType.User, e.profile.extensionsResource);
					const order = (a: ILocalExtension, b: ILocalExtension) => compare(`${a.identifier.id.toLowerCase()}@${a.manifest.version}:${a.location.toString()}`, `${b.identifier.id.toLowerCase()}@${b.manifest.version}:${b.location.toString()}`);
					// Native package directory names are immutable UUIDs, not ID/version sort keys.
					this.profileChange.fire(delta(previous.sort(order), current.sort(order), order));
				})());
			}
		}));
	}
	async getInstalled(type?: ExtensionType, profileLocation = this.getCurrentExtensionsManifestLocation(), productVersion?: IProductVersion): Promise<ILocalExtension[]> {
		this.scanner.assertProfile(profileLocation);
		return this.scanner.installed(profileLocation, type, productVersion);
	}
	getTargetPlatform(): Promise<TargetPlatform> {
		// Marketplace helpers run through the Linux ARM64 process authority. This does not change
		// the native Node extension host platform or imply native addon compatibility.
		return Promise.resolve(TargetPlatform.LINUX_ARM64);
	}
	async installExtensionsFromProfile(identifiers: IExtensionIdentifier[], from: URI, to: URI): Promise<ILocalExtension[]> {
		await this.scanner.profileScanner(to);
		const installed = await this.getInstalled(ExtensionType.User, from);
		const results: ILocalExtension[] = [];
		for (const extension of installed.filter(extension => identifiers.some(id => areSameExtensions(id, extension.identifier)))) {
			if (extension.isApplicationScoped) { results.push(extension); continue; }
			const local = await this.copyExtension(extension, from, to);
			this._onDidInstallExtensions.fire([{ identifier: local.identifier, local, operation: InstallOperation.None, profileLocation: to }]);
			results.push(local);
		}
		return results;
	}

	async updateMetadata(local: ILocalExtension, metadata: Partial<Metadata>, profileLocation = this.getCurrentExtensionsManifestLocation()): Promise<ILocalExtension> {
		this.scanner.assertProfile(profileLocation);
		const target = local.isApplicationScoped ? this.userDataProfilesService.defaultProfile.extensionsResource : profileLocation;
		const profiles = await this.scanner.profileScanner(target);
		const normalized = { ...metadata };
		if (metadata.isPreReleaseVersion) { normalized.preRelease = true; normalized.hasPreReleaseVersion = true; }
		for (const key of ['isMachineScoped', 'isBuiltin', 'pinned'] as const) {
			if (metadata[key] === false) { normalized[key] = undefined; }
		}
		await profiles.updateMetadata([[local, normalized]], target);
		const updated = (await this.getInstalled(ExtensionType.User, target)).find(extension => this.uriIdentityService.extUri.isEqual(extension.location, local.location));
		if (!updated) { throw new Error('[codipad-ext-mgmt] Updated membership was not readable'); }
		this._onDidUpdateExtensionMetadata.fire({ local: updated, profileLocation: target });
		return updated;
	}
	async zip(extension: ILocalExtension): Promise<URI> {
		const member = (await this.getInstalled()).find(local => this.uriIdentityService.extUri.isEqual(local.location, extension.location)
			&& areSameExtensions(local.identifier, extension.identifier));
		if (!member || member.type !== ExtensionType.User) { throw new Error('Extension is not installed in the current profile'); }
		const value = await callNative<string>('extension.exportVSIX', { uri: member.location.toString() });
		const uri = URI.parse(value, true);
		if (uri.scheme !== 'file') { throw new Error('Native export returned an invalid temporary file'); }
		return uri;
	}
	async installFromLocation(location: URI, profileLocation: URI): Promise<ILocalExtension> {
		const profiles = await this.scanner.profileScanner(profileLocation);
		// Only an already published, native-validated immutable package can gain membership.
		const catalog = await this.scanner.catalog();
		const entry = catalog.packages.find(entry => entry.extensionLocation === location.toString() && !entry.isBuiltin);
		if (!entry) { throw new Error('[codipad-ext-mgmt] Location is not an immutable native package'); }
		const local = await nativeExtensionToLocal({ ...entry, metadata: { ...entry.metadata, isApplicationScoped: false, source: 'resource' } }, this.resourceLoader, this.logService);
		await profiles.addExtensionsToProfile([[local, { ...entry.metadata, isApplicationScoped: false, source: 'resource' }]], profileLocation);
		this._onDidInstallExtensions.fire([{ identifier: local.identifier, local, operation: InstallOperation.Install, profileLocation }]);
		return local;
	}
	getManifest(vsix: URI): Promise<IExtensionManifest> { return callNative('extension.getVSIXManifest', { uri: vsix.toString() }); }
	async install(vsix: URI, options: InstallOptions = {}): Promise<ILocalExtension> {
		await this.scanner.profileScanner(options.profileLocation ?? this.getCurrentExtensionsManifestLocation());
		const manifest = await this.getManifest(vsix);
		const id = getGalleryExtensionId(manifest.publisher, manifest.name);
		if (manifest.engines?.vscode && !isEngineValid(manifest.engines.vscode, this.productService.version, this.productService.date)) {
			throw new Error(`Extension ${id} requires an incompatible VS Code version`);
		}
		const allowed = this.allowedExtensionsService.isAllowed({ id, version: manifest.version, publisherDisplayName: undefined });
		if (allowed !== true) {
			throw new Error(`Extension ${id} cannot be installed: ${allowed.value}`);
		}
		const results = await this.installExtensions([{ manifest, extension: vsix, options }]);
		const result = results.find(result => areSameExtensions(result.identifier, { id }));
		if (result?.local) {
			return result.local;
		}
		throw result?.error ?? new Error(`Installation did not return ${id}`);
	}
	async copyExtensions(from: URI, to: URI): Promise<void> {
		await this.installExtensionsFromProfile((await this.getInstalled(ExtensionType.User, from)).map(extension => extension.identifier), from, to);
	}
	async download(extension: IGalleryExtension, _operation: InstallOperation, donotVerifySignature: boolean): Promise<URI> {
		if (!donotVerifySignature && !extension.isSigned && shouldRequireRepositorySignatureFor(extension.private, await this.galleryManifest.getExtensionGalleryManifest())) {
			throw new ExtensionManagementError('The Marketplace requires this extension to be signed', ExtensionManagementErrorCode.PackageNotSigned);
		}
		const targetPlatform = extension.properties.targetPlatform;
		if (!targetPlatform || !extension.assets.download.uri) { throw new Error('Marketplace package information is incomplete'); }
		if (!donotVerifySignature && extension.isSigned) {
			throw new ExtensionManagementError('Verifying this signed Marketplace extension on iPad is unavailable. Install it from the Marketplace on the remote server.', ExtensionManagementErrorCode.Unsupported);
		}
		const uri = await callNative<string>('extension.download', {
			id: extension.identifier.id, version: extension.version, targetPlatform, downloadUri: extension.assets.download.uri,
		});
		const location = URI.parse(uri, true);
		if (location.scheme !== 'file') { throw new Error('Native download returned an invalid temporary file'); }
		return location;
	}

	getExtensionsControlManifestOrEmpty(): Promise<IExtensionsControlManifest> { return this.getExtensionsControlManifest(); }

	cleanUp(): Promise<void> { return this.scanner.cleanUp(); }

	protected getCurrentExtensionsManifestLocation(): URI {
		return this.userDataProfileService.currentProfile.extensionsResource;
	}

	protected override async installExtensions(extensions: { manifest: IExtensionManifest; extension: URI | IGalleryExtension; options: InstallOptions }[]) {
		// Validate every requested profile before the stock orchestrator can publish packages.
		for (const extension of extensions) { await this.scanner.profileScanner(extension.options.profileLocation ?? this.getCurrentExtensionsManifestLocation()); }
		return super.installExtensions(extensions);
	}

	protected createInstallExtensionTask(manifest: IExtensionManifest, extension: URI | IGalleryExtension, options: InstallExtensionTaskOptions): IInstallExtensionTask {
		return new NativePackageInstallTask(manifest, extension, options, this.logService,
			() => this.getInstalled(ExtensionType.User, options.profileLocation, options.productVersion), async entry => {
				try {
					const profiles = await this.scanner.profileScanner(options.profileLocation);
					const metadata = { ...entry.metadata, isApplicationScoped: !!options.isApplicationScoped, isBuiltin: !!options.isBuiltin };
					const local = { ...await nativeExtensionToLocal({ ...entry, metadata }, this.resourceLoader, this.logService), isBuiltin: !!options.isBuiltin };
					await profiles.addExtensionsToProfile([[local, metadata]], options.profileLocation);
					return local;
				} finally {
					// The profile write has settled. Releasing this temporary hold cannot change its outcome.
					await callNative('extension.releasePublication', { uri: entry.extensionLocation }).catch(error => this.logService.error(error));
				}
			});
	}

	protected createUninstallExtensionTask(extension: ILocalExtension, options: UninstallExtensionTaskOptions): IUninstallExtensionTask {
		let task: Promise<void> | undefined;
		const run = () => task ??= (async () => {
			const profiles = await this.scanner.profileScanner(options.profileLocation);
			await profiles.removeExtensionsFromProfile([extension.identifier], options.profileLocation, options.versionOnly
				? member => member.version === extension.manifest.version && member.location.toString() === extension.location.toString() && areSameExtensions(member.identifier, extension.identifier)
				: undefined);
		})();
		return { extension, options, run, waitUntilTaskIsFinished: run, cancel: () => { /* The upstream queued manifest write is the membership commit. */ } };
	}

	protected async copyExtension(extension: ILocalExtension, from: URI, to: URI, metadata?: Partial<Metadata>): Promise<ILocalExtension> {
		const source = await this.scanner.profileScanner(from);
		const target = await this.scanner.profileScanner(to);
		const member = (await source.scanProfileExtensions(from)).find(member => member.location.toString() === extension.location.toString() && member.version === extension.manifest.version && areSameExtensions(member.identifier, extension.identifier));
		if (!member) { throw new Error('[codipad-ext-mgmt] Copy source is not a member of the requested profile'); }
		const existing = (await target.scanProfileExtensions(to)).find(member => areSameExtensions(member.identifier, extension.identifier));
		const merged = { ...existing?.metadata, ...member.metadata, ...metadata };
		await target.addExtensionsToProfile([[extension, merged]], to);
		const copied = (await this.getInstalled(ExtensionType.User, to)).find(local => this.uriIdentityService.extUri.isEqual(local.location, extension.location));
		if (!copied) { throw new Error('[codipad-ext-mgmt] Copied membership was not readable'); }
		return copied;
	}
	protected async moveExtension(extension: ILocalExtension, from: URI, to: URI, metadata?: Partial<Metadata>): Promise<ILocalExtension> {
		const copied = await this.copyExtension(extension, from, to, metadata);
		if (!this.uriIdentityService.extUri.isEqual(from, to)) { await this.removeExtension(extension, from); }
		return copied;
	}
	protected async removeExtension(extension: ILocalExtension, from: URI): Promise<void> {
		await (await this.scanner.profileScanner(from)).removeExtensionsFromProfile([extension.identifier], from);
	}
	protected deleteExtension(_extension: ILocalExtension): Promise<void> { return refuse('deleteExtension'); }
}
