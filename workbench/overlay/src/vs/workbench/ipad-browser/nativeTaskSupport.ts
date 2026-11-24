/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench — workspace and extension tasks.
 *
 *  This adapter registers the browser workbench's normal task service against the existing local
 *  terminal backend. It does not create a task runner or process registry. Shell and process
 *  tasks both enter the process authority through the task terminal's executable/argv contract.
 *--------------------------------------------------------------------------------------------*/

import * as Platform from '../../base/common/platform.js';
import { URI } from '../../base/common/uri.js';
import { ConfigurationTarget } from '../../platform/configuration/common/configuration.js';
import { Schemas } from '../../base/common/network.js';
import { IWorkspaceFolder } from '../../platform/workspace/common/workspace.js';
import { IConfigurationResolverService } from '../services/configurationResolver/common/configurationResolver.js';
import { ITaskService } from '../contrib/tasks/common/taskService.js';
import { TaskService } from '../contrib/tasks/browser/taskService.js';
import { IResolveSet, IResolvedVariables, ITaskSystemInfo } from '../contrib/tasks/common/taskSystem.js';

const LOCAL_TASK_CONTEXT = Object.freeze({ authority: 'codipad-local-terminal' });

/** Keep the execution platform's capabilities authoritative when a native Node host registers. */
export class NativeTaskService extends TaskService {
	override registerSupportedExecutions(_custom?: boolean, shell?: boolean, _process?: boolean): void {
		// Native Node's task actor advertises all Node execution kinds. Keep capabilities bounded
		// to the task terminal paths the workbench implements. CustomExecution uses VS Code's
		// extension-owned pseudoterminal actors; shell and process tasks use the local authority.
		super.registerSupportedExecutions(true, shell, true);
	}

	override registerTaskSystem(key: string, info: ITaskSystemInfo): void {
		if (key === Schemas.file && info.context !== LOCAL_TASK_CONTEXT) {
			// Node runs on Darwin while task executables live in the Linux namespace. Its host
			// filesystem executable lookup cannot replace the registered local backend contract.
			return;
		}
		super.registerTaskSystem(key, info);
	}
}

export function registerNativeTaskSupport(
	taskService: ITaskService,
	configurationResolverService: IConfigurationResolverService
): void {
	const taskSystemInfo: ITaskSystemInfo = {
		// Task configuration and quoting follow the execution backend, including `linux` task
		// overrides. This does not change the renderer's isWeb or native Node's process.platform.
		platform: Platform.Platform.Linux,
		context: LOCAL_TASK_CONTEXT,
		uriProvider: path => URI.file(path),
		// Workspace and authorized tool roots are mounted at their canonical native paths.
		// Keep resolved task values, including environment path lists, unchanged.
		resolveVariables: async (
			workspaceFolder: IWorkspaceFolder,
			toResolve: IResolveSet,
			target: ConfigurationTarget
		): Promise<IResolvedVariables | undefined> => {
			const resolved = await configurationResolverService.resolveWithInteraction(
				workspaceFolder,
				Array.from(toResolve.variables),
				'tasks',
				undefined,
				target
			);
			return resolved ? { variables: resolved } : undefined;
		},
		// Do not let the upstream fallback turn an unresolved guest command into cwd/command.
		// The shared process authority resolves the unchanged name against guest PATH at spawn.
		findExecutable: async (command: string): Promise<string> => command
	};

	taskService.registerTaskSystem(Schemas.file, taskSystemInfo);
	// CustomExecution uses VS Code's extension-owned pseudoterminal lifecycle; shell and direct
	// process tasks continue to use the local process authority.
	taskService.registerSupportedExecutions(true, true, true);
}
