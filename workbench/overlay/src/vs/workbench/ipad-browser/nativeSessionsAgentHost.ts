/*---------------------------------------------------------------------------------------------
 * Local Agents Window capability and lifetime. The stock provider retains its upstream policy,
 * workspace trust and authentication checks; only its process connection is native.
 *--------------------------------------------------------------------------------------------*/
import { Disposable } from '../../base/common/lifecycle.js';
import { autorun } from '../../base/common/observable.js';
import { IAgentHostEnablementService } from '../../platform/agentHost/common/agentHostEnablementService.js';
import { AgentHostEnablementService } from '../../platform/agentHost/browser/agentHostEnablementService.js';
import { IAgentHostService } from '../../platform/agentHost/common/agentService.js';
import { IConfigurationService } from '../../platform/configuration/common/configuration.js';
import { IContextKeyService } from '../../platform/contextkey/common/contextkey.js';
import { SyncDescriptor } from '../../platform/instantiation/common/descriptors.js';
import { InstantiationType, registerSingleton } from '../../platform/instantiation/common/extensions.js';
import { IManagedSettingsService } from '../../platform/policy/common/copilotManagedSettings.js';
import { IWorkbenchContribution, registerWorkbenchContribution2, WorkbenchPhase } from '../common/contributions.js';
import { IWorkbenchEnvironmentService } from '../services/environment/common/environmentService.js';
import { callNative, isNativeAvailable } from './nativeBridge.js';
import { NativeAgentHostService } from './nativeAgentHostService.js';

class NativeSessionsAgentHostEnablement extends AgentHostEnablementService {
	constructor(runtimeAvailable: boolean,
		@IConfigurationService configuration: IConfigurationService,
		@IContextKeyService context: IContextKeyService,
		@IManagedSettingsService managed: IManagedSettingsService,
	) {
		super(runtimeAvailable, configuration, context, managed);
	}
}

// The stock web sessions graph has no local prewarmer. Start only when upstream
// enablement permits it; the owning native scene settles the host on teardown.
class NativeSessionsAgentHostPrewarm extends Disposable implements IWorkbenchContribution {
	static readonly ID = 'sessions.contrib.nativeAgentHostPrewarm';
	private started = false;
	constructor(
		@IAgentHostEnablementService enablement: IAgentHostEnablementService,
		@IAgentHostService private readonly host: IAgentHostService,
		@IWorkbenchEnvironmentService environment: IWorkbenchEnvironmentService,
	) {
		super();
		if (!environment.isSessionsWindow) { return; }
		this._register(autorun(reader => {
			if (!this.started && enablement.enabled.read(reader)) {
				this.started = true;
				this.host.startAgentHost();
			}
		}));
	}
}

type NativeSessionsAgentHostAvailability =
	| { readonly available: true }
	| { readonly available: false; readonly reason: 'nativeBridgeUnavailable' | 'runtimeUnavailable' | 'sessionWorkspaceAuthorityUnavailable' };

let configuration: Promise<NativeSessionsAgentHostAvailability> | undefined;
/** Run once after loading the stock sessions graph and before the workbench starts. */
export function configureNativeSessionsAgentHost(): Promise<NativeSessionsAgentHostAvailability> {
	return configuration ??= (async () => {
		if (!isNativeAvailable()) { return { available: false, reason: 'nativeBridgeUnavailable' }; }
		const status = await callNative<{ runtimeAvailable: boolean; sessionsWorkspaceAuthorityAvailable?: boolean }>('agentHost.status');
		if (typeof status?.runtimeAvailable !== 'boolean') {
			throw new Error('Native agent host capability status is invalid');
		}
		if (!status.runtimeAvailable) { return { available: false, reason: 'runtimeUnavailable' }; }
		// Session restore can access saved working directories before the renderer sees
		// them. Do not expose the provider until the native host owns those grants.
		if (status.sessionsWorkspaceAuthorityAvailable !== true) {
			const recovery = await callNative<{ authorized: boolean }>('agentHost.reauthorizeDirectories').catch(() => undefined);
			if (!recovery?.authorized) { return { available: false, reason: 'sessionWorkspaceAuthorityUnavailable' }; }
		}
		await import('../../sessions/contrib/providers/agentHost/browser/localAgentHost.contribution.js');
		// Sessions Workbench consumes all singleton registrations in order.
		registerSingleton(IAgentHostService, NativeAgentHostService, InstantiationType.Delayed);
		registerSingleton(IAgentHostEnablementService, new SyncDescriptor(NativeSessionsAgentHostEnablement, [status.runtimeAvailable], false));
		registerWorkbenchContribution2(NativeSessionsAgentHostPrewarm.ID, NativeSessionsAgentHostPrewarm, WorkbenchPhase.BlockRestore);
		return { available: true };
	})();
}
