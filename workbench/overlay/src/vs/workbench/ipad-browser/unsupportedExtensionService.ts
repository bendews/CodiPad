/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench — extension host is absent in this slice.
 *
 *  `IExtensionService` is required by the workbench graph. An explicitly failing implementation
 *  keeps the cause attributable ("extension host unsupported") instead of surfacing later as
 *  `undefined is not a function`. It does not fake activation: activation calls reject, so any
 *  activation attempt is visibly unsupported. Member list checked against
 *  `workbench/services/extensions/common/extensions.ts` at e646868 (IExistingExtensionService).
 *
 *  shortcut: no extension host at all; replace with the native Node host (§3) behind the real
 *  IExtensionService contract — do not grow this class.
 *--------------------------------------------------------------------------------------------*/

import { Event } from '../../base/common/event.js';
import { CommandsRegistry } from '../../platform/commands/common/commands.js';

const REASON = 'extension host is not implemented in this build (native Node host arrives in a later slice)';

let reported = false;

/**
 * Rejects for every real caller, and logs once. The extra `.catch` only stops the same rejection
 * being reported again as a global `unhandledrejection` by callers that fire-and-forget; it does not
 * turn the failure into a success — anyone awaiting the promise still gets the rejection.
 */
function refuse(operation: string): Promise<never> {
	const error = new Error(`[codipad-unsupported] IExtensionService.${operation}: ${REASON}`);
	if (!reported) {
		reported = true;
		console.warn(`[codipad-boot] ${error.message}`);
	}
	const rejection = Promise.reject(error);
	rejection.catch(() => { /* see comment above: caller-visible rejection is preserved */ });
	return rejection;
}

export class UnsupportedExtensionService {

	readonly _serviceBrand: undefined = undefined;

	readonly onDidRegisterExtensions = Event.None;
	readonly onDidChangeExtensionsStatus = Event.None;
	readonly onDidChangeExtensions = Event.None;
	readonly onWillActivateByEvent = Event.None;
	readonly onDidChangeResponsiveChange = Event.None;
	readonly onWillStop = Event.None;

	readonly extensions = [];

	async activateByEvent(event: string): Promise<void> {
		// The bootstrap registry contains no extensions. Existing workbench commands therefore
		// have no extension listeners to activate; allow those commands to run normally. This
		// does not activate an extension or admit an extension-contributed command.
		if (this.activationEventIsDone(event)) { return; }
		return refuse('activateByEvent');
	}

	async activateById(): Promise<void> {
		return refuse('activateById');
	}

	activationEventIsDone(event: string): boolean {
		const prefix = 'onCommand:';
		return event.startsWith(prefix) && !!CommandsRegistry.getCommand(event.slice(prefix.length));
	}

	async whenInstalledExtensionsRegistered(): Promise<boolean> {
		return true; // nothing to install: an empty registry is a true statement, not a fake success
	}

	async getExtension(): Promise<undefined> {
		return undefined;
	}

	canAddExtension(): boolean {
		return false;
	}

	canRemoveExtension(): boolean {
		return false;
	}

	async readExtensionPointContributions(): Promise<never[]> {
		return [];
	}

	getExtensionsStatus(): Record<string, never> {
		return {};
	}

	stopExtensionHosts(): boolean {
		return false;
	}

	startExtensionHosts(): Promise<never> {
		return refuse('startExtensionHosts');
	}

	setRemoteEnvironment(): Promise<never> {
		return refuse('setRemoteEnvironment');
	}
}
