/*---------------------------------------------------------------------------------------------
 * Opens the dedicated sessions workbench in a native iPad scene.
 *--------------------------------------------------------------------------------------------*/
import { localize2 } from '../../nls.js';
import { Action2, MenuId, registerAction2 } from '../../platform/actions/common/actions.js';
import { OPEN_AGENTS_WINDOW_COMMAND_ID, OPEN_AGENTS_WINDOW_PRECONDITION } from '../contrib/chat/common/constants.js';
import { callNative } from './nativeBridge.js';
import { IContextKeyService } from '../../platform/contextkey/common/contextkey.js';
import { ServicesAccessor } from '../../platform/instantiation/common/instantiation.js';

registerAction2(class extends Action2 {
 constructor() {
  super({id: OPEN_AGENTS_WINDOW_COMMAND_ID, title: localize2('openAgentsWindow', 'Open Agents Window'),
   f1: true, precondition: OPEN_AGENTS_WINDOW_PRECONDITION,
   menu: {id: MenuId.MenubarFileMenu, group: '2_open', order: 4}});
 }
 override async run(accessor: ServicesAccessor): Promise<void> {
  if (!accessor.get(IContextKeyService).contextMatchesRules(OPEN_AGENTS_WINDOW_PRECONDITION)) {
   throw new Error('Agents Window is unavailable under the current AI settings or workspace policy');
  }
  await callNative('window.openScene', {kind: 'agents'});
 }
});
