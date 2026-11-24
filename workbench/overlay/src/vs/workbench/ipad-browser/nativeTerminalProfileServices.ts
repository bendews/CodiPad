/*---------------------------------------------------------------------------------------------
 * CodiPad terminal profile services use the guest OS only for local native terminals. Remote
 * authorities retain their own platform and profile configuration.
 *--------------------------------------------------------------------------------------------*/

import { Codicon } from '../../base/common/codicons.js';
import { NativeTerminalBackend } from './nativeTerminalBackend.js';
import { OperatingSystem } from '../../base/common/platform.js';
import { IConfigurationService } from '../../platform/configuration/common/configuration.js';
import { IContextKeyService } from '../../platform/contextkey/common/contextkey.js';
import { InstantiationType, registerSingleton } from '../../platform/instantiation/common/extensions.js';
import { ITerminalLogService, TerminalSettingPrefix } from '../../platform/terminal/common/terminal.js';
import { IWorkspaceContextService } from '../../platform/workspace/common/workspace.js';
import { IExtensionService } from '../services/extensions/common/extensions.js';
import { IWorkbenchEnvironmentService } from '../services/environment/common/environmentService.js';
import { IHistoryService } from '../services/history/common/history.js';
import { IRemoteAgentService } from '../services/remote/common/remoteAgentService.js';
import { IConfigurationResolverService } from '../services/configurationResolver/common/configurationResolver.js';
import { ITerminalProfileResolverService, ITerminalProfileService } from '../contrib/terminal/common/terminal.js';
import { ITerminalInstanceService } from '../contrib/terminal/browser/terminal.js';
import { ITerminalContributionService } from '../contrib/terminal/common/terminalExtensionPoints.js';
import { BrowserTerminalProfileResolverService } from '../contrib/terminal/browser/terminalProfileResolverService.js';
import { TerminalProfileService } from '../contrib/terminal/browser/terminalProfileService.js';
import { nativeTerminalPlatformKey, resolveConfiguredTerminalDefault, withGuestTerminalOS } from './terminalProfileOS.js';

const GUEST_OS = OperatingSystem.Linux;

export class NativeTerminalProfileService extends TerminalProfileService {
	private readonly _nativeConfigurationService: IConfigurationService;
	private readonly _nativeEnvironmentService: IWorkbenchEnvironmentService;

	constructor(
		@IContextKeyService contextKeyService: IContextKeyService,
		@IConfigurationService configurationService: IConfigurationService,
		@ITerminalContributionService terminalContributionService: ITerminalContributionService,
		@IExtensionService extensionService: IExtensionService,
		@IRemoteAgentService remoteAgentService: IRemoteAgentService,
		@IWorkbenchEnvironmentService environmentService: IWorkbenchEnvironmentService,
		@ITerminalInstanceService terminalInstanceService: ITerminalInstanceService
	) {
		super(contextKeyService, configurationService, terminalContributionService, extensionService,
			remoteAgentService, environmentService, terminalInstanceService);
		this._nativeConfigurationService = configurationService;
		this._nativeEnvironmentService = environmentService;
	}

	override async getPlatformKey(): Promise<string> {
		// The base constructor starts profile refresh before subclass fields are assigned.
		await Promise.resolve();
		const authority = this._nativeEnvironmentService?.remoteAuthority;
		return nativeTerminalPlatformKey(authority, await super.getPlatformKey());
	}

	override getDefaultProfile(os?: OperatingSystem) {
		if (this._nativeEnvironmentService?.remoteAuthority) {
			return super.getDefaultProfile(os);
		}
		const defaultProfile = this._nativeConfigurationService.getValue(`${TerminalSettingPrefix.DefaultProfile}linux`);
		const profiles = this._nativeConfigurationService.getValue(`${TerminalSettingPrefix.Profiles}linux`);
		return resolveConfiguredTerminalDefault(defaultProfile, profiles, () => super.getDefaultProfile(GUEST_OS));
	}
}

export class NativeTerminalProfileResolverService extends BrowserTerminalProfileResolverService {
	private readonly _nativeConfigurationService: IConfigurationService;
	private readonly _nativeEnvironmentService: IWorkbenchEnvironmentService;
	private readonly _nativeProfileService: ITerminalProfileService;

	constructor(
		@IConfigurationResolverService configurationResolverService: IConfigurationResolverService,
		@IConfigurationService configurationService: IConfigurationService,
		@IHistoryService historyService: IHistoryService,
		@ITerminalLogService logService: ITerminalLogService,
		@ITerminalInstanceService private readonly terminalInstanceService: ITerminalInstanceService,
		@ITerminalProfileService terminalProfileService: ITerminalProfileService,
		@IWorkspaceContextService workspaceContextService: IWorkspaceContextService,
		@IRemoteAgentService remoteAgentService: IRemoteAgentService,
		@IWorkbenchEnvironmentService environmentService: IWorkbenchEnvironmentService
	) {
		super(configurationResolverService, configurationService, historyService, logService, terminalInstanceService,
			terminalProfileService, workspaceContextService, remoteAgentService);
		this._nativeConfigurationService = configurationService;
		this._nativeEnvironmentService = environmentService;
		this._nativeProfileService = terminalProfileService;
	}

	override resolveIcon(shellLaunchConfig: Parameters<BrowserTerminalProfileResolverService['resolveIcon']>[0], os: OperatingSystem): void {
		super.resolveIcon(shellLaunchConfig, this._isNativeLocal() ? GUEST_OS : os);
	}

	override resolveShellLaunchConfig(
		shellLaunchConfig: Parameters<BrowserTerminalProfileResolverService['resolveShellLaunchConfig']>[0],
		options: Parameters<BrowserTerminalProfileResolverService['resolveShellLaunchConfig']>[1]
	): Promise<void> {
		if (!this._isNativeLocal(options.remoteAuthority)) {
			return super.resolveShellLaunchConfig(shellLaunchConfig, options);
		}
		const resolvedOptions = this._resolveOptions(options);
		return super.resolveShellLaunchConfig(shellLaunchConfig, resolvedOptions);
	}

	override async getDefaultProfile(options: Parameters<BrowserTerminalProfileResolverService['getDefaultProfile']>[0]) {
		if (!this._isNativeLocal(options.remoteAuthority)) {
			return super.getDefaultProfile(options);
		}
		const resolvedOptions = this._resolveOptions(options);
		if (this._hasHigherPriorityProfile(resolvedOptions, 'linux')) {
			return super.getDefaultProfile(resolvedOptions);
		}
		await this._nativeProfileService.profilesReady;
		// Read settings after the await: cached discovery may describe a different path array.
		if (!this._hasHigherPriorityProfile(resolvedOptions, 'linux')) {
			const name = this._nativeConfigurationService.getValue<string>(`${TerminalSettingPrefix.DefaultProfile}linux`);
			const profiles = this._nativeConfigurationService.getValue<Record<string, { path?: unknown }>>(`${TerminalSettingPrefix.Profiles}linux`);
			if (typeof name === 'string' && Array.isArray(profiles?.[name]?.path)) {
				const backend = await this.terminalInstanceService.getBackend(undefined);
				if (!(backend instanceof NativeTerminalBackend)) {
					throw new Error('[codipad-terminal] guest profile lookup is unavailable');
				}
				const [profile] = await backend.getProfiles({ [name]: profiles[name] }, name, false);
				if (profile) {
					// Keep upstream argument/variable resolution and metadata handling after selection.
					const launch = { executable: profile.path, args: profile.args };
					await super.resolveShellLaunchConfig(launch, resolvedOptions);
					return { ...profile, path: launch.executable, args: launch.args, icon: resolvedOptions.allowAutomationShell ? Codicon.tools : profile.icon };
				}
			}
		}
		return super.getDefaultProfile(resolvedOptions);
	}

	private _resolveOptions<T extends Parameters<BrowserTerminalProfileResolverService['getDefaultProfile']>[0]>(options: T): T {
		return withGuestTerminalOS(options, this._isNativeLocal(options.remoteAuthority), GUEST_OS) as T;
	}

	private _isNativeLocal(remoteAuthority?: string): boolean {
		return !remoteAuthority && !this._nativeEnvironmentService?.remoteAuthority;
	}

	private _hasHigherPriorityProfile(options: Parameters<BrowserTerminalProfileResolverService['getDefaultProfile']>[0], osKey: string): boolean {
		if (options.allowAgentHostShell) {
			const profile = this._nativeConfigurationService.getValue(`terminal.integrated.agentHostProfile.${osKey}`);
			if (typeof profile === 'string' && this._nativeProfileService.availableProfiles.some(candidate => candidate.profileName === profile && !candidate.isAutoDetected)) {
				return true;
			}
			if (profile && typeof profile === 'object' && typeof (profile as { path?: unknown }).path === 'string') {
				return true;
			}
		}
		if (options.allowAutomationShell) {
			const profile = this._nativeConfigurationService.getValue(`terminal.integrated.automationProfile.${osKey}`);
			if (profile && typeof profile === 'object' && typeof (profile as { path?: unknown }).path === 'string') {
				return true;
			}
		}
		return false;
	}
}

// Imported after terminal.web.contribution in ipadMain so these guest-scoped registrations replace
// only terminal profile resolution; renderer platform detection remains unchanged.
registerSingleton(ITerminalProfileService, NativeTerminalProfileService, InstantiationType.Delayed);
registerSingleton(ITerminalProfileResolverService, NativeTerminalProfileResolverService, InstantiationType.Delayed);
