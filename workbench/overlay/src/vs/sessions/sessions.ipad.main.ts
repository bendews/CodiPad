/*---------------------------------------------------------------------------------------------
 * CodiPad Agents Window entrypoint. The sessions and editor graphs run in separate pages.
 *--------------------------------------------------------------------------------------------*/
import './sessions.web.main.js';
import './nativeEditorWindowAction.js';
import '../workbench/ipad-browser/nativeSessionsPlatform.js';
import { main } from './sessions.ipad.bootstrap.js';
import { mark } from '../base/common/performance.js';
import { installBootErrorHooks, bootError } from '../workbench/ipad-browser/boot.js';
mark('code/didLoadWorkbenchMain');
installBootErrorHooks();
main().catch(error => bootError('agents-autostart', error));
