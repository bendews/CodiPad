/* Native app-lifetime launch metadata, using the pinned pty host's wire types. */
import { revive } from '../../base/common/marshalling.js';
import { IProcessDetails } from '../../platform/terminal/common/terminalProcess.js';
import { WorkspaceFolder } from '../../platform/workspace/common/workspace.js';
import { URI } from '../../base/common/uri.js';
import { IShellLaunchConfig, ITerminalProcessOptions } from '../../platform/terminal/common/terminal.js';
import { deserializeEnvironmentVariableCollections, serializeEnvironmentVariableCollections } from '../../platform/terminal/common/environmentVariableShared.js';

const fail = (): never => { throw new Error('[codipad-terminal] invalid or oversized restoration metadata'); };
const object = (v: any): v is Record<string, any> => v !== null && typeof v === 'object' && !Array.isArray(v);
const keys = (v: any, allowed: string[]) => object(v) && Object.keys(v).every(k => allowed.includes(k));
const optional = (v: any, key: string, check: (value: any) => boolean) => !(key in v) || check(v[key]);
const string = (v: any) => typeof v === 'string';
const boolean = (v: any) => typeof v === 'boolean';
const integer = (v: any, min: number, max: number) => Number.isSafeInteger(v) && v >= min && v <= max;
const uri = (v: any) => keys(v, ['$mid', 'scheme', 'authority', 'path', 'query', 'fragment', 'fsPath', 'external']) && string(v.scheme) &&
	['authority', 'path', 'query', 'fragment', 'fsPath', 'external'].every(k => optional(v, k, string)) && optional(v, '$mid', n => n === 1);
const themeIcon = (v: any) => keys(v, ['id', 'color']) && string(v.id) && optional(v, 'color', c => keys(c, ['id']) && string(c.id));
const icon = (v: any): boolean => themeIcon(v) || uri(v) || (keys(v, ['light', 'dark']) && uri(v.light) && uri(v.dark));
const dimensions = (v: any) => keys(v, ['cols', 'rows']) && optional(v, 'cols', n => integer(n, 1, 1000)) && optional(v, 'rows', n => integer(n, 1, 500));
const scope = (v: any) => keys(v, ['workspaceFolder']) && optional(v, 'workspaceFolder', f =>
	keys(f, ['uri', 'name', 'index']) && uri(f.uri) && string(f.name) && integer(f.index, 0, Number.MAX_SAFE_INTEGER));
const pairs = (v: any, check: (value: any) => boolean) => Array.isArray(v) && v.every(e => Array.isArray(e) && e.length === 2 && string(e[0]) && check(e[1])) && new Set(v.map(e => e[0])).size === v.length;
const mutator = (v: any) => keys(v, ['variable', 'value', 'type', 'scope', 'options']) && string(v.variable) && string(v.value) && integer(v.type, 1, 3) && optional(v, 'scope', scope) &&
	optional(v, 'options', o => keys(o, ['applyAtProcessCreation', 'applyAtShellIntegration']) && Object.values(o).every(boolean));
const description = (v: any) => keys(v, ['description', 'scope']) && optional(v, 'description', string) && optional(v, 'scope', scope);
const collections = (v: any) => Array.isArray(v) && v.every(e => Array.isArray(e) && e.length === 3 && string(e[0]) && pairs(e[1], mutator) && pairs(e[2], description)) && new Set(v.map(e => e[0])).size === v.length;

/** Detach caller-owned values before any asynchronous launch work. Functions/objects with custom
 * serialization are not transferable task data. Undefined object properties are optional wire fields. */
export function cloneJSON(value: unknown): any {
	let nodes = 0;
	const ancestors = new Set<object>();
	function visit(v: any, depth: number): any {
		if (++nodes > 16384 || depth > 32) { return fail(); }
		if (v === null || typeof v === 'boolean' || typeof v === 'string' || (typeof v === 'number' && Number.isFinite(v))) { return v; }
		if (!object(v) && !Array.isArray(v) || ancestors.has(v) || (!Array.isArray(v) && Object.getPrototypeOf(v) !== Object.prototype && Object.getPrototypeOf(v) !== null)) { return fail(); }
		ancestors.add(v);
		const result: any = Array.isArray(v) ? Array.from(v, item => visit(item, depth + 1)) : Object.fromEntries(Object.entries(v).filter(([, item]) => item !== undefined).map(([key, item]) => [visit(key, depth + 1), visit(item, depth + 1)]));
		ancestors.delete(v);
		return result;
	}
	const result = visit(value, 0);
	if (new TextEncoder().encode(JSON.stringify(result)).length > 256 * 1024) { return fail(); }
	return result;
}

// Project only typed IPC fields. Generic task payloads still require plain JSON and never run toJSON.
function uriDTO(value: any): any {
	return value instanceof URI ? { $mid: 1, ...Object.fromEntries(Object.entries({ scheme: value.scheme, authority: value.authority, path: value.path, query: value.query, fragment: value.fragment }).filter(([, field]) => field)) } : value;
}
function plain(value: any): value is Record<string, any> {
	return object(value) && (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null);
}
export function terminalWorkspaceFolderDTO(value: any): any {
	if (value === undefined) { return undefined; }
	const folder = value instanceof WorkspaceFolder ? { uri: value.uri, name: value.name, index: value.index } : value;
	if (!plain(folder)) { return fail(); }
	const result = cloneJSON({ ...folder, uri: uriDTO(folder.uri) });
	if (!keys(result, ['uri', 'name', 'index']) || !uri(result.uri) || !string(result.name) || !integer(result.index, 0, Number.MAX_SAFE_INTEGER)) { return fail(); }
	return result;
}
export function terminalIconDTO(value: any): any {
	if (value instanceof URI) { return uriDTO(value); }
	// The stock profile resolver may return an IconContribution, which is a ThemeIcon
	// with registry-only fields. Transfer only its ThemeIcon identity and color.
	if (plain(value) && string(value.id)) { return { id: value.id, color: value.color }; }
	return plain(value) && ('light' in value || 'dark' in value) ? { ...value, light: uriDTO(value.light), dark: uriDTO(value.dark) } : value;
}
export function terminalCollectionsDTO(value: any): any {
	const scoped = (v: any) => plain(v) && plain(v.scope) ? { ...v, scope: { ...v.scope, workspaceFolder: terminalWorkspaceFolderDTO(v.scope.workspaceFolder) } } : v;
	const pairsDTO = (v: any) => Array.isArray(v) ? v.map(e => Array.isArray(e) && e.length === 2 ? [e[0], scoped(e[1])] : e) : v;
	return Array.isArray(value) ? value.map(e => Array.isArray(e) && e.length === 3 ? [e[0], pairsDTO(e[1]), pairsDTO(e[2])] : e) : value;
}
export function terminalCwdDTO(value: any): any { return uriDTO(value); }

/** Also used for mutable presentation updates; launch identity is never writable through this RPC. */
export function terminalPresentationMetadata(value: unknown): Record<string, unknown> {
	const v = cloneJSON(plain(value) ? { ...value, icon: terminalIconDTO(value.icon) } : value);
	if (!keys(v, ['title', 'titleSource', 'icon', 'color', 'fixedDimensions']) ||
		!optional(v, 'title', string) || !optional(v, 'titleSource', n => integer(n, 0, 3)) ||
		!optional(v, 'icon', icon) || !optional(v, 'color', c => c === null || string(c)) || !optional(v, 'fixedDimensions', dimensions)) { return fail(); }
	return v;
}

export function terminalLaunchMetadata(config: IShellLaunchConfig, options: ITerminalProcessOptions, workspaceName: string): Record<string, unknown> {
	const v = cloneJSON({ workspaceName, environmentVariableCollections: terminalCollectionsDTO(options.environmentVariableCollections),
		reconnectionProperties: config.reconnectionProperties,
		// Desktop IPC JSON omits renderer-local callbacks. The original config retains the
		// callback; stock task reconnection supplies a new callback in the replacement renderer.
		waitOnExit: typeof config.waitOnExit === 'function' ? undefined : config.waitOnExit,
		hideFromUser: config.hideFromUser, isFeatureTerminal: config.isFeatureTerminal, type: config.type, tabActions: config.tabActions,
		...(config.name ? { title: config.name, titleSource: 0 } : {}), icon: terminalIconDTO(config.icon), color: config.color, fixedDimensions: config.fixedDimensions });
	if (!string(v.workspaceName) || !optional(v, 'environmentVariableCollections', collections) ||
		!optional(v, 'reconnectionProperties', r => keys(r, ['ownerId', 'data']) && string(r.ownerId)) ||
		!optional(v, 'waitOnExit', w => boolean(w) || string(w)) || !optional(v, 'hideFromUser', boolean) || !optional(v, 'isFeatureTerminal', boolean) ||
		!optional(v, 'type', t => t === 'Task' || t === 'Local') || !optional(v, 'tabActions', a => Array.isArray(a) && a.every(t => keys(t, ['id', 'label', 'icon']) && string(t.id) && string(t.label) && optional(t, 'icon', themeIcon)))) { return fail(); }
	terminalPresentationMetadata(Object.fromEntries(['title', 'titleSource', 'icon', 'color', 'fixedDimensions'].filter(k => k in v).map(k => [k, v[k]])));
	if (v.environmentVariableCollections) {
		// Keep the exact stock format consumed by TerminalInstance/TerminalProcessManager on restore.
		v.environmentVariableCollections = serializeEnvironmentVariableCollections(deserializeEnvironmentVariableCollections(v.environmentVariableCollections));
	}
	return v;
}

/** Restore URI prototypes only in typed fields; generic reconnection data remains ordinary JSON. */
export function reviveTerminalProcessDetails(details: IProcessDetails): IProcessDetails {
	if (details.icon) { details.icon = revive(details.icon) as IProcessDetails['icon']; }
	if (details.environmentVariableCollections) { details.environmentVariableCollections = revive(details.environmentVariableCollections) as IProcessDetails['environmentVariableCollections']; }
	return details;
}
