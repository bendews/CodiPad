/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench — updater.
 *
 *  The app ships through the App Store / an MDM channel, not through a web deployment, so there is
 *  no in-app updater. This is a normal platform decision, expressed with upstream's own state
 *  vocabulary: `State.Disabled(DisablementReason.DisabledByEnvironment)`.
 *
 *  Two rules make it honest:
 *   - `isLatestVersion()` returns `undefined` (unknown), never `true`. Claiming "latest" would be a
 *     fabricated success and the deprecated `IUpdateService` contract allows `undefined`.
 *   - every mutating or checking call rejects with a named unsupported error, so nothing silently
 *     resolves as if an update flow completed.
 *---------------------------------------------------------------------------------------------*/

import { Event } from '../../base/common/event.js';
import { DisablementReason, IUpdateService, State } from '../../platform/update/common/update.js';

const REASON = 'in-app updates are disabled on iPad: the app is updated through its distribution channel';

function refuse(operation: string): Promise<never> {
	return Promise.reject(new Error(`[codipad-unsupported] IUpdateService.${operation}: ${REASON}`));
}

export class IpadUpdateService implements IUpdateService {

	readonly _serviceBrand: undefined = undefined;

	readonly onStateChange = Event.None;
	readonly state = State.Disabled(DisablementReason.DisabledByEnvironment);

	checkForUpdates(): Promise<void> {
		return refuse('checkForUpdates');
	}

	downloadUpdate(): Promise<void> {
		return refuse('downloadUpdate');
	}

	applyUpdate(): Promise<void> {
		return refuse('applyUpdate');
	}

	quitAndInstall(): Promise<void> {
		return refuse('quitAndInstall');
	}

	/** Deprecated upstream; `undefined` means "unknown", which is the truthful answer. */
	async isLatestVersion(): Promise<boolean | undefined> {
		return undefined;
	}

	_applySpecificUpdate(): Promise<void> {
		return refuse('_applySpecificUpdate');
	}

	setInternalOrg(): Promise<void> {
		return refuse('setInternalOrg');
	}
}
