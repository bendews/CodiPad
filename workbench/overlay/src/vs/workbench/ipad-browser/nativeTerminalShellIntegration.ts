/*---------------------------------------------------------------------------------------------
 * Copyright (c) CodiPad contributors. All rights reserved.
 * Licensed under GPL-3.0-only. See LICENSE in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { IProcessEnvironment } from '../../base/common/platform.js';
import { ILogService } from '../../platform/log/common/log.js';
import product from '../../platform/product/common/product.js';
import { getShellIntegrationInjection } from '../../platform/terminal/common/shellIntegrationInjection.js';
import { IShellLaunchConfig, ITerminalProcessOptions } from '../../platform/terminal/common/terminal.js';
import { callTerminal } from './nativeTerminalConnection.js';

interface NativeShellIntegrationContext {
	platform: 'linux'; scriptsRoot: string; tmpDir: string; stagingDirectory: string;
	homedir: string; username: null; applicationName: string; quality: string | null;
}

/** Stock decisions with native-owned paths and real, bounded filesystem operations. */
export async function getNativeShellIntegration(slc: IShellLaunchConfig, options: ITerminalProcessOptions,
	env: IProcessEnvironment, logService: ILogService) {
	let pending: Promise<NativeShellIntegrationContext> | undefined;
	const context = () => pending ??= callTerminal<NativeShellIntegrationContext>('terminal.shellIntegrationContext', {}).then(value => {
		if (value.platform !== 'linux' || value.username !== null || value.applicationName !== product.applicationName ||
			(value.quality ?? undefined) !== product.quality ||
			![value.scriptsRoot, value.tmpDir, value.stagingDirectory, value.homedir].every(path => typeof path === 'string' && path.startsWith('/') && !path.includes('\0')) ||
			value.stagingDirectory !== `${value.tmpDir}/unknown-${value.applicationName}-zsh`) {
			throw new Error('Invalid native shell integration context');
		}
		return value;
	});
	const perform = async (operation: string) => {
		const reply = await callTerminal<{ completed: boolean }>('terminal.prepareShellIntegration', { operation });
		if (reply.completed !== true) { throw new Error('Native shell integration operation did not complete'); }
	};
	const injection = await getShellIntegrationInjection(slc, options, env, logService, product, {
		environment: async () => {
			const value = await context();
			return { platform: value.platform, scriptRoot: value.scriptsRoot,
				userInfo: () => { throw new Error('Guest username is unavailable'); },
				tmpdir: () => value.tmpDir, homedir: () => value.homedir };
		},
		windowsBuildNumber: async () => { throw new Error('Windows build lookup is unavailable for the Linux terminal'); },
		realpath: async path => {
			const value = await context();
			if (path !== value.tmpDir) { throw new Error('Unexpected shell integration staging root'); }
			return value.tmpDir; // Native validated this canonical mounted directory through its retained capability.
		},
		chmod: async (path, mode) => {
			if (path !== (await context()).stagingDirectory || mode !== 0o1700) { throw new Error('Unexpected shell integration chmod'); }
			await perform('chmod');
		},
		mkdir: async (path, options) => {
			if (path !== (await context()).stagingDirectory || options.recursive !== true) { throw new Error('Unexpected shell integration mkdir'); }
			await perform('mkdir');
		}
	});
	if (injection.type === 'injection' && injection.filesToCopy) {
		const value = await context();
		const copies = [
			['shellIntegration-rc.zsh', '.zshrc', 'copyRc'], ['shellIntegration-profile.zsh', '.zprofile', 'copyProfile'],
			['shellIntegration-env.zsh', '.zshenv', 'copyEnv'], ['shellIntegration-login.zsh', '.zlogin', 'copyLogin']
		];
		for (const file of injection.filesToCopy) {
			const copy = copies.find(([source, dest]) => file.source === `${value.scriptsRoot}/${source}` && file.dest === `${value.stagingDirectory}/${dest}`);
			if (!copy) { throw new Error('Unexpected shell integration copy'); }
			await perform(copy[2]);
		}
	}
	return injection;
}
