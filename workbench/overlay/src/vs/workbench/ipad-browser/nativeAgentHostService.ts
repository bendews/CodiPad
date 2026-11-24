/*---------------------------------------------------------------------------------------------
 * Local stock AHP over the app-owned process authority. Protocol, subscriptions, file permissions,
 * workspace trust, authentication and provider methods remain in AgentHostProtocolClient.
 *---------------------------------------------------------------------------------------------*/
import { Emitter, Event } from '../../base/common/event.js';
import { Disposable } from '../../base/common/lifecycle.js';
import { equals } from '../../base/common/objects.js';
import { observableValue, ObservablePromise } from '../../base/common/observable.js';
import { IConfigurationService } from '../../platform/configuration/common/configuration.js';
import { IDefaultAccountService } from '../../platform/defaultAccount/common/defaultAccount.js';
import { IInstantiationService } from '../../platform/instantiation/common/instantiation.js';
import { ILogService } from '../../platform/log/common/log.js';
import { ManagedSettingsFreshnessState } from '../../platform/policy/common/managedSettingsFreshness.js';
import { ITelemetryService } from '../../platform/telemetry/common/telemetry.js';
import { IWorkspaceTrustEnablementService, IWorkspaceTrustManagementService, IWorkspaceTrustRequestService } from '../../platform/workspace/common/workspaceTrust.js';
import { AgentHostClientState, AgentHostProtocolClient } from '../../platform/agentHost/browser/agentHostProtocolClient.js';
import { IAgentCreateSessionConfig } from '../../platform/agentHost/common/agent.js';
import { fromAgentHostUri } from '../../platform/agentHost/common/agentHostUri.js';
import { URI } from '../../base/common/uri.js';
import { WebSocketClientTransport } from '../../platform/agentHost/browser/webSocketClientTransport.js';
import { agentsWindowAgentHostClientInfo, editorWindowAgentHostClientInfo } from '../../platform/agentHost/common/agentHostClientInfo.js';
import { IWorkbenchEnvironmentService } from '../services/environment/common/environmentService.js';
import { IAgentHostResourceService, LOCAL_AGENT_HOST_RESOURCE_IDENTITY } from '../../platform/agentHost/common/agentHostResourceService.js';
import { AgentHostClientConnectionKind, telemetryLevelToAgentHostValue } from '../../platform/agentHost/common/agentHostTelemetry.js';
import { AgentHostOTelPolicyState, IAgentHostService, IAgentSdkStarterSettings, IAgentHostOTelSettings, readAgentHostOTelPolicySettings, AgentHostClaudeAgentEnabledSettingId, AgentHostCodexAgentEnabledSettingId, AgentHostCodexAgentSdkRootSettingId, AgentHostCodexAgentCodexHomeSettingId, AgentHostCodexAgentBinaryArgsSettingId, AgentHostOTelEnabledSettingId, AgentHostOTelExporterTypeSettingId, AgentHostOTelOtlpEndpointSettingId, AgentHostOTelCaptureContentSettingId, AgentHostOTelCaptureIdentitySettingId, AgentHostOTelOutfileSettingId, AgentHostOTelDbSpanExporterEnabledSettingId } from '../../platform/agentHost/common/agentService.js';
import { ProtocolMessage } from '../../platform/agentHost/common/state/sessionProtocol.js';
import { IClientTransport, IProtocolTransport, ITransportCloseDetails } from '../../platform/agentHost/common/state/sessionTransport.js';
import { AccountPolicyGateUnsatisfiedReason, IAccountPolicyGateService } from '../services/policies/common/accountPolicyService.js';
import { callNative } from './nativeBridge.js';
import { onReverseEvent } from './reverseEvents.js';

export interface NativeAgentHostLaunchConfiguration {
	readonly schemaVersion: 1;
	readonly sdk: IAgentSdkStarterSettings;
	readonly otel: IAgentHostOTelSettings;
	readonly otelPolicy: IAgentHostOTelSettings;
	readonly telemetryLevel: ReturnType<typeof telemetryLevelToAgentHostValue>;
}
interface NativeHostInfo {
	readonly sessionId: string;
	readonly ownerGeneration: string;
	readonly address: string;
	readonly connectionToken: string;
	readonly otelPolicy: IAgentHostOTelSettings;
}
interface NativeHostStatus {
	readonly sessionId?: string;
	readonly otelPolicy?: IAgentHostOTelSettings;
}

/** Only connection acquisition is native. The WebSocket transport and AHP stay upstream. */
class NativeAgentTransport extends Disposable implements IClientTransport {
	readonly clientConnectionKind = AgentHostClientConnectionKind.DirectWebSocket;
	private readonly message = this._register(new Emitter<ProtocolMessage>());
	readonly onMessage = this.message.event;
	private readonly close = this._register(new Emitter<void>());
	readonly onClose = this.close.event;
	private readonly details = this._register(new Emitter<ITransportCloseDetails>());
	readonly onDidCloseDetails = this.details.event;
	private socket: IClientTransport | undefined;
	constructor(private readonly acquire: () => Promise<NativeHostInfo>, private readonly instantiation: IInstantiationService) { super(); }
	async connect(): Promise<void> {
		const host = await this.acquire();
		if (this._store.isDisposed) { throw new Error('Agent transport was disposed during startup'); }
		const port = /^ws:\/\/127\.0\.0\.1:([1-9]\d{0,4})$/.exec(host.address);
		if (!port || Number(port[1]) > 65535 || !/^[1-9]\d{0,19}$/.test(host.sessionId) || !/^[1-9]\d{0,19}$/.test(host.ownerGeneration) || typeof host.connectionToken !== 'string' || host.connectionToken.length < 32 || host.connectionToken.length > 512) {
			throw new Error('Native agent host returned an invalid local endpoint');
		}
		const socket = this._register(this.instantiation.createInstance(WebSocketClientTransport, host.address, host.connectionToken, undefined));
		this.socket = socket;
		this._register(socket.onMessage(message => this.message.fire(message)));
		this._register(socket.onClose(() => this.close.fire()));
		this._register(socket.onDidCloseDetails(details => this.details.fire(details)));
		await socket.connect();
	}
	send(message: Parameters<IProtocolTransport['send']>[0]): void {
		if (!this.socket) { throw new Error('Agent host socket is not connected'); }
		this.socket.send(message);
	}
}

export class NativeAgentHostService extends AgentHostProtocolClient implements IAgentHostService {
	private readonly started = this._register(new Emitter<void>());
	readonly onAgentHostStart = this.started.event;
	private readonly exited = this._register(new Emitter<number>());
	readonly onAgentHostExit = this.exited.event;
	readonly authenticationPending = observableValue('nativeAgentHostAuthenticationPending', true);
	readonly supportsConversationImport = false;
	private authenticationSettled = false;
	private initialConnectRequested = false;
	private restart: Promise<void> | undefined;
	private currentHost: NativeHostInfo | undefined;
	private readonly policyState = new AgentHostOTelPolicyState();

	override async createSession(config?: IAgentCreateSessionConfig): Promise<URI> {
		const uris = config?.workingDirectories?.map(uri => fromAgentHostUri(uri).toString()) ?? [];
		if (uris.length) { await callNative('agentHost.authorizeDirectories', { uris }); }
		return super.createSession(config);
	}

	constructor(
		@ILogService log: ILogService,
		@IAgentHostResourceService resources: IAgentHostResourceService,
		@IConfigurationService configuration: IConfigurationService,
		@ITelemetryService telemetry: ITelemetryService,
		@IWorkspaceTrustEnablementService trustEnabled: IWorkspaceTrustEnablementService,
		@IWorkspaceTrustManagementService trust: IWorkspaceTrustManagementService,
		@IWorkspaceTrustRequestService trustRequests: IWorkspaceTrustRequestService,
		@IDefaultAccountService account: IDefaultAccountService,
		@IInstantiationService instantiation: IInstantiationService,
		@IAccountPolicyGateService accountPolicy: IAccountPolicyGateService,
		@IWorkbenchEnvironmentService environment: IWorkbenchEnvironmentService,
	) {
		// The same readiness conditions as pinned workbench/services/agentHost's Electron
		// composition, without importing its Electron IPC service or changing platform flags.
		const initialized = ObservablePromise.fromFn(async () => {
			try { await account.getDefaultAccount(); return true; }
			catch (error) { log.error('Failed to resolve account policy for Agent Host OTel', error); return false; }
		});
		const policyReady = () => initialized.promiseResult.get()?.data === true
			&& accountPolicy.gateInfo.reason !== AccountPolicyGateUnsatisfiedReason.PolicyNotResolved
			&& accountPolicy.gateInfo.managedSettingsFreshness?.state !== ManagedSettingsFreshnessState.Pending;
		const policyChanged = Event.any(Event.fromObservableLight(initialized.promiseResult), accountPolicy.onDidChangeGateInfo, configuration.onDidChangeConfiguration);
		let acquire!: () => Promise<NativeHostInfo>;
		super(LOCAL_AGENT_HOST_RESOURCE_IDENTITY, () => new NativeAgentTransport(() => acquire(), instantiation), { clientInfo: environment.isSessionsWindow ? agentsWindowAgentHostClientInfo : editorWindowAgentHostClientInfo }, log, resources, configuration, telemetry, trustEnabled, trust, trustRequests, account);
		const launchConfiguration = (): NativeAgentHostLaunchConfiguration => ({
			schemaVersion: 1,
			sdk: { codexSdkRoot: configuration.getValue(AgentHostCodexAgentSdkRootSettingId), codexHome: configuration.getValue(AgentHostCodexAgentCodexHomeSettingId), codexBinaryArgs: configuration.getValue(AgentHostCodexAgentBinaryArgsSettingId), claudeAgentEnabled: configuration.getValue(AgentHostClaudeAgentEnabledSettingId), codexAgentEnabled: configuration.getValue(AgentHostCodexAgentEnabledSettingId) },
			otel: { enabled: configuration.getValue(AgentHostOTelEnabledSettingId), exporterType: configuration.getValue(AgentHostOTelExporterTypeSettingId), otlpEndpoint: configuration.getValue(AgentHostOTelOtlpEndpointSettingId), captureContent: configuration.getValue(AgentHostOTelCaptureContentSettingId), captureIdentity: configuration.getValue(AgentHostOTelCaptureIdentitySettingId), outfile: configuration.getValue(AgentHostOTelOutfileSettingId), dbSpanExporterEnabled: configuration.getValue(AgentHostOTelDbSpanExporterEnabledSettingId) },
			otelPolicy: this.policyState.policy ?? readAgentHostOTelPolicySettings(configuration), telemetryLevel: telemetryLevelToAgentHostValue(telemetry.telemetryLevel),
		});
		acquire = async () => {
			const status = await callNative<NativeHostStatus>('agentHost.status');
			if (status.sessionId && !this.currentHost) {
				// A renderer reload must retain the app-owned host's applied policy while the
				// replacement renderer is still resolving account policy.
				this.policyState.update(status.otelPolicy ?? {}, false, true);
			}
			this.policyState.update(readAgentHostOTelPolicySettings(configuration), !!status.sessionId, policyReady());
			const desired = launchConfiguration();
			if (status.sessionId && policyReady() && !equals(status.otelPolicy ?? {}, JSON.parse(JSON.stringify(desired.otelPolicy)))) {
				await callNative('agentHost.stop', { sessionId: status.sessionId });
			}
			const host = await callNative<NativeHostInfo>('agentHost.start', { launchConfiguration: desired });
			this.currentHost = host;
			return host;
		};
		this.policyState.update(readAgentHostOTelPolicySettings(configuration), false, policyReady());
		this._register(policyChanged(() => {
			if (this.policyState.update(readAgentHostOTelPolicySettings(configuration), this.initialConnectRequested, policyReady())) {
				void this.restartAgentHost().catch(error => log.error('Agent host policy restart failed', error));
			}
		}));
		this._register(this.onDidChangeConnectionState(state => {
			if (state === AgentHostClientState.Connected) { this.policyState.didStart(); this.started.fire(); }
		}));
		this._register(onReverseEvent('agentHost.exit', 0, event => {
			try {
				const status = JSON.parse(event.data ?? '');
				if (status.sessionId === this.currentHost?.sessionId && status.ownerGeneration === this.currentHost.ownerGeneration && status.allReaped === true && Number.isInteger(status.code)) {
					this.exited.fire(status.code); this.notifyTransportClosed();
				}
			} catch { log.warn('Invalid native agent-host exit event'); }
		}));
	}

	setAuthenticationPending(pending: boolean): void {
		if (this.authenticationSettled) { return; }
		if (!pending) { this.authenticationSettled = true; }
		this.authenticationPending.set(pending, undefined);
	}
	startAgentHost(): void {
		if (this.initialConnectRequested) { this.reconnectFromClosed(); return; }
		this.initialConnectRequested = true;
		void this.connect().catch(() => { /* Stock protocol client owns failure/reconnect state. */ });
	}
	restartAgentHost(): Promise<void> {
		return this.restart ??= (async () => {
			const status = await callNative<NativeHostStatus>('agentHost.status');
			if (status.sessionId) { await callNative('agentHost.stop', { sessionId: status.sessionId }); }
			this.notifyTransportClosed();
			this.startAgentHost();
			this.reconnectNow();
		})().finally(() => this.restart = undefined);
	}
	async startWebSocketServer(): Promise<never> { throw new Error('Local agent management socket publication is unsupported'); }
	async getInspectInfo(_tryEnable: boolean): Promise<never> { throw new Error('Local agent inspector management is unsupported'); }
}
