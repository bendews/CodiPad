/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See workbench/notices/VSCODE-LICENSE.txt for license information.
 *--------------------------------------------------------------------------------------------*/

import { localize2 } from '../../nls.js';
import { Action2, registerAction2 } from '../../platform/actions/common/actions.js';
import { ContextKeyExpr } from '../../platform/contextkey/common/contextkey.js';
import { ServicesAccessor } from '../../platform/instantiation/common/instantiation.js';
import { IsSessionsWindowContext, RemoteNameContext, VirtualWorkspaceContext } from '../common/contextkeys.js';
import { IHostService } from '../services/host/browser/host.js';

// The pinned remote indicator skips this desktop action in WebKit's browser runtime.
registerAction2(class extends Action2 {
	constructor() {
		super({
			id: 'workbench.action.remote.close',
			category: localize2('remote.category', 'Remote'),
			title: localize2('remote.close', 'Close Remote Connection'),
			f1: true,
			precondition: ContextKeyExpr.and(ContextKeyExpr.or(RemoteNameContext, VirtualWorkspaceContext), IsSessionsWindowContext.negate())
		});
	}

	override run(accessor: ServicesAccessor): Promise<void> {
		return accessor.get(IHostService).openWindow({ forceReuseWindow: true, remoteAuthority: null });
	}
});
