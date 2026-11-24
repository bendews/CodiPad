/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench — Marketplace-only native request adapter.
 *
 *  Keep the native URLSession path scoped to the upstream gallery service. The general workbench
 *  IRequestService remains unchanged; the native bridge enforces Marketplace HTTPS origins and
 *  redirects before returning a response body.
 *--------------------------------------------------------------------------------------------*/

import { CancellationToken } from '../../base/common/cancellation.js';
import { CancellationError } from '../../base/common/errors.js';
import { generateUuid } from '../../base/common/uuid.js';
import { VSBuffer, bufferToStream } from '../../base/common/buffer.js';
import { AbstractRequestService, AuthInfo, Credentials } from '../../platform/request/common/request.js';
import { IRequestContext, IRequestOptions } from '../../base/parts/request/common/request.js';
import { ILogService } from '../../platform/log/common/log.js';
import { IStorageService } from '../../platform/storage/common/storage.js';
import { IEnvironmentService } from '../../platform/environment/common/environment.js';
import { ITelemetryService } from '../../platform/telemetry/common/telemetry.js';
import { IFileService } from '../../platform/files/common/files.js';
import { IProductService } from '../../platform/product/common/productService.js';
import { IConfigurationService } from '../../platform/configuration/common/configuration.js';
import { IAllowedExtensionsService, IExtensionGalleryService } from '../../platform/extensionManagement/common/extensionManagement.js';
import { TargetPlatform } from '../../platform/extensions/common/extensions.js';
import { IExtensionGalleryManifestService } from '../../platform/extensionManagement/common/extensionGalleryManifest.js';
import { ExtensionGalleryService } from '../../platform/extensionManagement/common/extensionGalleryService.js';
import { callNative, decodeBase64, encodeBase64 } from './nativeBridge.js';

interface MarketplaceResponse {
	readonly status: number;
	readonly headers: Record<string, string>;
	readonly bodyBase64: string;
}

export class MarketplaceRequestService extends AbstractRequestService {

	constructor(@ILogService logService: ILogService) {
		super(logService);
	}

	request(options: IRequestOptions, token: CancellationToken): Promise<IRequestContext> {
		return this.logAndRequest(options, async () => {
			if (token.isCancellationRequested) {
				throw new CancellationError();
			}
			if (!options.url) {
				throw new Error('[codipad-marketplace] request URL is required');
			}

			const data = options.data === undefined ? undefined : VSBuffer.fromString(options.data).buffer;
			const headers = Object.fromEntries(Object.entries(options.headers ?? {}).flatMap(([name, value]) => {
				if (typeof value === 'string') {
					return [[name, value]];
				}
				return Array.isArray(value) ? [[name, value.join(', ')]] : [];
			}));
			const requestId = generateUuid();
			const request = callNative<MarketplaceResponse>('marketplace.request', {
				requestId,
				url: options.url,
				method: options.type ?? (data === undefined ? 'GET' : 'POST'),
				headers,
				...(data === undefined ? {} : { bodyBase64: encodeBase64(data) }),
			});
			let cancel!: () => void;
			let cancellationSent = false;
			const cancelled = new Promise<never>((_, reject) => { cancel = () => {
				if (cancellationSent) { return; }
				cancellationSent = true;
				void callNative('marketplace.cancel', { requestId }).catch(() => {});
				reject(new CancellationError());
			}; });
			const listener = token.onCancellationRequested(cancel);
			if (token.isCancellationRequested) { cancel(); }
			let response: MarketplaceResponse;
			try { response = await Promise.race([request, cancelled]); }
			finally { listener.dispose(); }
			if (token.isCancellationRequested) {
				throw new CancellationError();
			}

			if (!Number.isInteger(response?.status) || typeof response.bodyBase64 !== 'string') {
				throw new Error('[codipad-marketplace] native request returned a malformed response');
			}

			return {
				res: {
					statusCode: response.status,
					headers: response.headers ?? {},
				},
				stream: bufferToStream(VSBuffer.wrap(decodeBase64(response.bodyBase64))),
			};
		});
	}

	resolveProxy(_url: string): Promise<string | undefined> { return Promise.resolve(undefined); }
	lookupAuthorization(_authInfo: AuthInfo): Promise<Credentials | undefined> { return Promise.resolve(undefined); }
	lookupKerberosAuthorization(_url: string): Promise<string | undefined> { return Promise.resolve(undefined); }
	loadCertificates(): Promise<string[]> { return Promise.resolve([]); }
}

/** Upstream Marketplace implementation with a request path scoped to the native Marketplace API. */
export class NativeMarketplaceGalleryService extends ExtensionGalleryService implements IExtensionGalleryService {
	protected override get defaultTargetPlatform(): TargetPlatform { return TargetPlatform.LINUX_ARM64; }

	constructor(
		@IStorageService storageService: IStorageService,
		@ILogService logService: ILogService,
		@IEnvironmentService environmentService: IEnvironmentService,
		@ITelemetryService telemetryService: ITelemetryService,
		@IFileService fileService: IFileService,
		@IProductService productService: IProductService,
		@IConfigurationService configurationService: IConfigurationService,
		@IAllowedExtensionsService allowedExtensionsService: IAllowedExtensionsService,
		@IExtensionGalleryManifestService extensionGalleryManifestService: IExtensionGalleryManifestService,
	) {
		super(
			storageService,
			new MarketplaceRequestService(logService),
			logService,
			environmentService,
			telemetryService,
			fileService,
			productService,
			configurationService,
			allowedExtensionsService,
			extensionGalleryManifestService,
		);
	}
}
