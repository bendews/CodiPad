/* Copyright (c) CodiPad contributors. Licensed under GPL-3.0-only. */
import { ISerializedTerminalState, ITerminalsLayoutInfoById, ITerminalChildProcess } from '../../platform/terminal/common/terminal.js';
import { Event, Emitter } from '../../base/common/event.js';
import { cloneJSON, terminalLaunchMetadata, terminalWorkspaceFolderDTO, terminalIconDTO, terminalCollectionsDTO, terminalCwdDTO } from './nativeTerminalMetadata.js';

export interface ArchivedTerminalHistory { key: string; cwd: string; data: string; timestamp: number; }

export interface NativeTerminalCheckpoint {
	version: 1;
	state: ISerializedTerminalState[];
	codipad: { incarnation: string; checkpoint: string; layout: ITerminalsLayoutInfoById; archive?: ArchivedTerminalHistory[] };
}

// Stored launch configs never contain renderer-local functions or shell integration's injected argv.
export function savedLaunch(config: any, options: any): { shellLaunchConfig: any; options: any } {
	const { customPtyImplementation, waitOnExit, ...wire } = config;
	if (customPtyImplementation) { throw new Error('[codipad-terminal] custom PTYs cannot be revived'); }
	const value = cloneJSON({ shellLaunchConfig: { ...wire, cwd: terminalCwdDTO(wire.cwd), icon: terminalIconDTO(wire.icon), waitOnExit: typeof waitOnExit === 'function' ? undefined : waitOnExit }, options: { ...options, workspaceFolder: terminalWorkspaceFolderDTO(options?.workspaceFolder), environmentVariableCollections: terminalCollectionsDTO(options?.environmentVariableCollections) } });
	const c = value.shellLaunchConfig;
	if ((c.executable !== undefined && (typeof c.executable !== 'string' || !c.executable || c.executable.includes('\0'))) ||
		(c.args !== undefined && (!Array.isArray(c.args) || !c.args.every((a: any) => typeof a === 'string' && !a.includes('\0')))) ||
		(c.env !== undefined && (c.env === null || Array.isArray(c.env) || typeof c.env !== 'object' || !Object.entries(c.env).every(([k, v]) => !k.includes('\0') && !k.includes('=') && (v === null || typeof v === 'string' && !v.includes('\0'))))) ||
		!value.options?.shellIntegration || typeof value.options.shellIntegration.nonce !== 'string') {
		throw new Error('[codipad-terminal] malformed saved launch config');
	}
	terminalLaunchMetadata(c, value.options, '');
	return value;
}

export function readCheckpoint(text: string): NativeTerminalCheckpoint {
	if (new TextEncoder().encode(text).length > 16 * 1024 * 1024) { throw new Error('[codipad-terminal] checkpoint too large'); }
	const v = JSON.parse(text);
	const uuid = (s: any) => typeof s === 'string' && /^[a-f0-9-]{36}$/i.test(s);
	if (v?.version !== 1 || !Array.isArray(v.state) || v.state.length > 32 || !uuid(v.codipad?.incarnation) || !uuid(v.codipad?.checkpoint)) { throw new Error('[codipad-terminal] unsupported checkpoint'); }
	if (v.codipad.archive !== undefined && (!Array.isArray(v.codipad.archive) || v.codipad.archive.length > 128 || !v.codipad.archive.every((a: any) => a && typeof a.key === 'string' && a.key.length < 128 && typeof a.cwd === 'string' && a.cwd.length < 4096 && typeof a.data === 'string' && a.data.length <= 4 * 1024 * 1024 && Number.isFinite(a.timestamp)))) { throw new Error('[codipad-terminal] malformed history archive'); }
	const layout = v.codipad.layout;
	const id = (n: any) => Number.isSafeInteger(n) && n > 0;
	if (!layout || !Array.isArray(layout.tabs) || layout.tabs.length > 32 || !layout.tabs.every((t: any) => t && typeof t.isActive === 'boolean' && (t.activePersistentProcessId === undefined || id(t.activePersistentProcessId)) && Array.isArray(t.terminals) && t.terminals.length <= 32 && t.terminals.every((i: any) => i && id(i.terminal) && Number.isFinite(i.relativeSize) && i.relativeSize >= 0)) || (layout.background !== undefined && layout.background !== null && (!Array.isArray(layout.background) || layout.background.length > 32 || !layout.background.every(id)))) { throw new Error('[codipad-terminal] malformed checkpoint layout'); }
	const ids = new Set<number>();
	for (const s of v.state) {
		if (!Number.isSafeInteger(s.id) || s.id <= 0 || ids.has(s.id) || !Number.isFinite(s.timestamp) ||
			!['6', '11'].includes(s.unicodeVersion) || !s.processDetails || typeof s.processDetails.cwd !== 'string' || !s.processDetails.cwd.startsWith('/') || s.processDetails.cwd.includes('\0') ||
			!Array.isArray(s.replayEvent?.events) || s.replayEvent.events.length !== 1) { throw new Error('[codipad-terminal] malformed checkpoint record'); }
		// A moved terminal retains its source host identity; native routing checks its current owner.
		if (s.processDetails.processIdentity !== undefined && (typeof s.processDetails.processIdentity !== 'string' || !/^[a-f0-9-]{36}:[a-f0-9-]{36}$/i.test(s.processDetails.processIdentity))) { throw new Error('[codipad-terminal] malformed process identity'); }
		ids.add(s.id);
		const e = s.replayEvent.events[0];
		if (typeof e.data !== 'string' || e.data.length > 4 * 1024 * 1024 || !Number.isSafeInteger(e.cols) || e.cols < 2 || e.cols > 1000 || !Number.isSafeInteger(e.rows) || e.rows < 1 || e.rows > 500) { throw new Error('[codipad-terminal] malformed replay'); }
		savedLaunch(s.shellLaunchConfig, s.processLaunchConfig?.options);
		terminalLaunchMetadata(s.processDetails, s.processLaunchConfig.options, s.processDetails.workspaceName ?? '');
		if (s.replayEvent.commands) { cloneJSON(s.replayEvent.commands); }
	}
	return v;
}

// Failed attachment is a launch error, not an absent process that permits stock fallback launch.
// Negative ticket IDs cannot address native sessions; no PID, ready or exit event is fabricated.
let failedTicketId = 0;
export function failedTerminalRevival(error: unknown): ITerminalChildProcess {
	const message = `Terminal revival failed; saved history remains available: ${error instanceof Error ? error.message : String(error)}`;
	const replay = new Emitter<void>();
	const unavailable = (): never => { throw new Error(message); };
	return {
		id: --failedTicketId, shouldPersist: false,
		onProcessData: Event.None, onProcessReady: Event.None, onDidChangeProperty: Event.None, onProcessExit: Event.None,
		onProcessReplayComplete: replay.event,
		async start() {
			// Stock groups install replay listeners after accepting the attachment. There is no replay pending.
			await new Promise<void>(resolve => setTimeout(resolve, 0));
			replay.fire();
			return { message };
		},
		shutdown() { replay.dispose(); }, input: unavailable, sendSignal: unavailable, resize: unavailable,
		clearBuffer: unavailable, acknowledgeDataEvent: unavailable,
		async processBinary() { unavailable(); }, async setUnicodeVersion() { unavailable(); },
		async getInitialCwd() { return unavailable(); }, async getCwd() { return unavailable(); },
		async refreshProperty() { return unavailable(); }, async updateProperty() { unavailable(); }
	};
}
