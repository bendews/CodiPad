/* Return from the Agents Window to an editor scene owned by the native app. */
import { localize2 } from '../nls.js';
import { Action2, MenuId, registerAction2 } from '../platform/actions/common/actions.js';
import { callNative } from '../workbench/ipad-browser/nativeBridge.js';

registerAction2(class extends Action2 {
 constructor() {
  super({ id: 'codipad.showEditorWindow', title: localize2('showEditorWindow', 'Show Editor Window'),
   f1: true, menu: { id: MenuId.MenubarFileMenu, group: '2_open', order: 3 } });
 }
 override async run(): Promise<void> {
  await callNative('window.showEditor', {});
 }
});
