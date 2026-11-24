/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See workbench/notices/VSCODE-LICENSE.txt for license information.
 *--------------------------------------------------------------------------------------------*/

import { ExtensionKind } from '../../platform/environment/common/environment.js';
import { ExtensionIdentifier } from '../../platform/extensions/common/extensions.js';
import { ExtensionHostKind, ExtensionRunningPreference, IExtensionHostKindPicker } from '../services/extensions/common/extensionHostKind.js';

/** Pinned desktop host-selection policy; no Electron process dependency. */
export class IpadExtensionHostKindPicker implements IExtensionHostKindPicker {
	constructor(private readonly hasRemoteExtHost: boolean, private readonly hasWebWorkerExtHost = false) { }

	pickExtensionHostKind(_id: ExtensionIdentifier, kinds: ExtensionKind[], local: boolean, remote: boolean, preference: ExtensionRunningPreference): ExtensionHostKind | null {
		return pickExtensionHostKind(kinds, local, remote, preference, this.hasRemoteExtHost, this.hasWebWorkerExtHost);
	}
}

export function pickExtensionHostKind(extensionKinds: ExtensionKind[], isInstalledLocally: boolean, isInstalledRemotely: boolean, preference: ExtensionRunningPreference, hasRemoteExtHost: boolean, hasWebWorkerExtHost: boolean): ExtensionHostKind | null {
	const result: ExtensionHostKind[] = [];
	for (const extensionKind of extensionKinds) {
		if (extensionKind === 'ui' && isInstalledLocally) {
			// ui extensions run locally if possible
			if (preference === ExtensionRunningPreference.None || preference === ExtensionRunningPreference.Local) {
				return ExtensionHostKind.LocalProcess;
			} else {
				result.push(ExtensionHostKind.LocalProcess);
			}
		}
		if (extensionKind === 'workspace' && isInstalledRemotely) {
			// workspace extensions run remotely if possible
			if (preference === ExtensionRunningPreference.None || preference === ExtensionRunningPreference.Remote) {
				return ExtensionHostKind.Remote;
			} else {
				result.push(ExtensionHostKind.Remote);
			}
		}
		if (extensionKind === 'workspace' && !hasRemoteExtHost) {
			// workspace extensions also run locally if there is no remote
			if (preference === ExtensionRunningPreference.None || preference === ExtensionRunningPreference.Local) {
				return ExtensionHostKind.LocalProcess;
			} else {
				result.push(ExtensionHostKind.LocalProcess);
			}
		}
		if (extensionKind === 'web' && isInstalledLocally && hasWebWorkerExtHost) {
			// web worker extensions run in the local web worker if possible
			if (preference === ExtensionRunningPreference.None || preference === ExtensionRunningPreference.Local) {
				return ExtensionHostKind.LocalWebWorker;
			} else {
				result.push(ExtensionHostKind.LocalWebWorker);
			}
		}
	}
	return (result.length > 0 ? result[0] : null);
}
