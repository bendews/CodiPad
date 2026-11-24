/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench — native terminal backend (two independent PTYs).
 *
 *  Registered once into VS Code's own backend registry for the local (undefined) authority, so the
 *  ordinary New Terminal UI, terminal actions and xterm rendering are untouched. Each terminal is a
 *  native session with its own PTY in the emulated guest; nothing is multiplexed and there is no
 *  second process registry here.
 *
 *  Native contract (owned by the shell):
 *    terminal.create {cols,rows,cwdUri?,executable,args?,env?} -> {sessionId,pid,cwd,guestCwd}
 *    terminal.input {sessionId,data:base64} -> {acceptedBytes,queuedBytes}
 *    terminal.ack {sessionId,dataId} releases output bytes after the renderer consumes text
 *    terminal.resize {sessionId,cols,rows}
 *    terminal.signal {sessionId,signal}
 *    terminal.stop  {sessionId}
 *    terminal.cwd   {sessionId} -> {cwd,guestCwd}
 *    terminal.list  -> [{sessionId,pid,cwd,guestCwd,…}]
 *  Reverse (via reverseEvents.ts): terminal.data {sessionId,dataId,byteCount,data:base64}, terminal.exit
 *  {sessionId,code,signal}, terminal.error {sessionId,code,message}.
 *
 *  Honest limits, stated rather than faked:
 *   - app restart replays checkpointed history into new processes; running commands do not survive;
 *   - native output bytes remain charged until VS Code acknowledges all decoded characters from
 *     their terminal.data event via the upstream tracked-write barrier;
 *---------------------------------------------------------------------------------------------*/

import { revive } from '../../base/common/marshalling.js';
import { Emitter, Event } from '../../base/common/event.js';
import { IDisposable } from '../../base/common/lifecycle.js';
import { decodeBase64, encodeBase64, VSBuffer } from '../../base/common/buffer.js';
import { Registry } from '../../platform/registry/common/platform.js';
import {
	ISerializedTerminalState, IProcessDataEvent, IProcessProperty, IProcessPropertyMap, IProcessReadyEvent,
	IPtyHostLatencyMeasurement, IShellLaunchConfig, ITerminalBackend, ITerminalBackendRegistry,
	ITerminalChildProcess, ITerminalLaunchError, ITerminalLaunchResult, ITerminalProcessOptions,
	ITerminalProfile, ITerminalsLayoutInfo, ITerminalsLayoutInfoById, ProcessPropertyType, TerminalExtensions,
	TerminalIcon, TerminalSettingId, TitleEventSource, TerminalExitReason, TerminalLocation
} from '../../platform/terminal/common/terminal.js';
import { IProcessDetails } from '../../platform/terminal/common/terminalProcess.js';
import { IProcessEnvironment, OperatingSystem } from '../../base/common/platform.js';
import { Schemas } from '../../base/common/network.js';
import { IInstantiationService } from '../../platform/instantiation/common/instantiation.js';
import { IConfigurationService } from '../../platform/configuration/common/configuration.js';
import { IConfigurationResolverService } from '../services/configurationResolver/common/configurationResolver.js';
import { IHistoryService } from '../services/history/common/history.js';
import { IWorkspaceContextService } from '../../platform/workspace/common/workspace.js';
import { URI } from '../../base/common/uri.js';
import { ILabelService } from '../../platform/label/common/label.js';
import { terminalLaunchMetadata, terminalPresentationMetadata, reviveTerminalProcessDetails } from './nativeTerminalMetadata.js';
import { ILogService } from '../../platform/log/common/log.js';
import { isNativeAvailable } from './nativeBridge.js';
import { callTerminal } from './nativeTerminalConnection.js';
import { installReverseEventReceiver, onReverseEvent, onSessionOverflow, releaseReverseEvents, ReverseEvent } from './reverseEvents.js';
import { guestDetectedShells, resolveGuestProfilePath } from './terminalProfileOS.js';
import { getNativeShellIntegration } from './nativeTerminalShellIntegration.js';
import { INotificationService, Severity } from '../../platform/notification/common/notification.js';
import { IEditorService } from '../services/editor/common/editorService.js';
import { removeAnsiEscapeCodes } from '../../base/common/strings.js';
import { IStorageService, StorageScope, StorageTarget, WillSaveStateReason } from '../../platform/storage/common/storage.js';
import { TerminalStorageKeys } from '../contrib/terminal/common/terminalStorageKeys.js';
import * as terminalEnvironment from '../contrib/terminal/common/terminalEnvironment.js';
import { shouldUseEnvironmentVariableCollection } from '../../platform/terminal/common/terminalEnvironment.js';
import { IEnvironmentVariableService } from '../contrib/terminal/common/environmentVariable.js';
import { IProductService } from '../../platform/product/common/productService.js';
import { ITerminalEditorService, ITerminalGroupService, ITerminalService, ITerminalInstance } from '../contrib/terminal/browser/terminal.js';
import { getTerminalUri } from '../contrib/terminal/browser/terminalUri.js';
import { readCheckpoint, savedLaunch, NativeTerminalCheckpoint, ArchivedTerminalHistory, failedTerminalRevival } from './nativeTerminalRevival.js';
import { ISerializedCommandDetectionCapability } from '../../platform/terminal/common/capabilities/capabilities.js';
import { IShellIntegrationConfigInjection, IShellIntegrationInjectionFailure } from '../../platform/terminal/common/shellIntegrationInjection.js';

const DEFAULT_SHELL = '/bin/bash';
const UNSUPPORTED = 'operation is unavailable in the native terminal backend';

/** Linux signal numbers the shell accepts; anything else is rejected by name. */
const SIGNALS: Record<string, number> = {
	HUP: 1, INT: 2, QUIT: 3, ILL: 4, TRAP: 5, ABRT: 6, IOT: 6, BUS: 7, FPE: 8,
	KILL: 9, USR1: 10, SEGV: 11, USR2: 12, PIPE: 13, ALRM: 14, TERM: 15,
	STKFLT: 16, CHLD: 17, CLD: 17, CONT: 18, STOP: 19, TSTP: 20, TTIN: 21,
	TTOU: 22, URG: 23, XCPU: 24, XFSZ: 25, VTALRM: 26, PROF: 27, WINCH: 28,
	IO: 29, POLL: 29, PWR: 30, SYS: 31, UNUSED: 31
};

function refuse(operation: string): Promise<never> {
	return Promise.reject(new Error(`[codipad-terminal] ${operation}: ${UNSUPPORTED}`));
}

interface NativeCreateReply {
	readonly sessionId: number; readonly pid: number; readonly cwd: string; readonly guestCwd: string;
	readonly processIdentity: string; readonly pageId: string; readonly generation: string;
	readonly throughDataId?: number;
	readonly snapshot?: { data: string; pendingBytes: number[]; cols: number; rows: number; commands?: ISerializedCommandDetectionCapability };
}


function executionCwd(reply: { cwd: string | null; guestCwd: string }): string {
	if (reply.cwd === null) {
		return reply.guestCwd;
	}
	const uri = URI.parse(reply.cwd);
	if (uri.scheme !== 'file') {
		throw new Error('[codipad-terminal] native cwd must be a file URI');
	}
	return uri.fsPath;
}

export class NativeTerminalProcess implements ITerminalChildProcess {

	private readonly _onProcessReplayComplete = new Emitter<void>();
	readonly onProcessReplayComplete = this._onProcessReplayComplete.event;
	private readonly _onRestoreCommands = new Emitter<ISerializedCommandDetectionCapability>();
	readonly onRestoreCommands = this._onRestoreCommands.event;
	private _pendingWrites: Promise<void> = Promise.resolve();
	private _replaying = false;
	private _detached = false;

	private readonly _onProcessData = new Emitter<IProcessDataEvent | string>();
	readonly onProcessData: Event<IProcessDataEvent | string> = this._onProcessData.event;

	private readonly _onProcessReady = new Emitter<IProcessReadyEvent>();
	readonly onProcessReady: Event<IProcessReadyEvent> = this._onProcessReady.event;

	private readonly _onDidChangeProperty = new Emitter<IProcessProperty>();
	readonly onDidChangeProperty: Event<IProcessProperty> = this._onDidChangeProperty.event;

	private readonly _onProcessExit = new Emitter<number | undefined>();
	readonly onProcessExit: Event<number | undefined> = this._onProcessExit.event;

	private _exitEmitted = false;
	private _stopped = false;
	private _stopRequested = false;
	private _lastError: string | undefined;
	private _subscriptions: IDisposable[] = [];
	/** Streaming decoder: multi-byte sequences must not be split at chunk boundaries. */
	private readonly _decoder = new TextDecoder('utf-8');
	/** Native event IDs that have not yet produced decoded text. */
	private _undeliveredDataIds: number[] = [];

	/** Current PTY dimensions, tracked after every accepted resize request. */
	private _cols: number;
	private _rows: number;
	private _requestedSize: { cols: number; rows: number } | undefined;
	private _resizePending = false;

	constructor(
		readonly id: number,
		private readonly _sessionId: number,
		private readonly _pid: number,
		private readonly _cwd: string,
		cols: number,
		rows: number,
		private readonly _logService: ILogService,
		private readonly _attachment: NativeCreateReply,
		readonly shouldPersist: boolean,
		private readonly _shellIntegration?: IShellIntegrationConfigInjection | IShellIntegrationInjectionFailure
	) {
		this._cols = cols;
		this._rows = rows;
	}

	get processIdentity(): string { return this._attachment.processIdentity; }
	get handoffGeneration(): string { return this._attachment.generation; }
	markTransferred(): void {
		this._detached = true;
		this._stopped = true;
		this._disposeSubscriptions();
	}

	async start(): Promise<ITerminalLaunchError | ITerminalLaunchResult | undefined> {
		this._subscriptions.push(onReverseEvent('terminal.data', this._sessionId, event => { if (this._matches(event)) { this._onNativeData(event); } }));
		this._subscriptions.push(onReverseEvent('terminal.exit', this._sessionId, event => { if (this._matches(event)) { void this._onNativeExit(event); } }));
		// A transport failure is surfaced and the PTY is asked to stop, but the exit itself must
		// still come from native: fabricating one here would report a process death that never
		// happened, and would hide the real code when it arrives.
		this._subscriptions.push(onReverseEvent('terminal.error', this._sessionId, event => { if (this._matches(event)) { this._onNativeError(event); } }));
		this._subscriptions.push(onSessionOverflow('terminal', this._sessionId, reason => this._onNativeError({ kind: 'terminal.error', sessionId: this._sessionId, reason })));

		if (this._shellIntegration?.type === 'injection') {
			this._onDidChangeProperty.fire({ type: ProcessPropertyType.UsedShellIntegrationInjection, value: true });
		} else if (this._shellIntegration) {
			this._onDidChangeProperty.fire({ type: ProcessPropertyType.FailedShellIntegrationActivation, value: true });
			this._onDidChangeProperty.fire({ type: ProcessPropertyType.ShellIntegrationInjectionFailureReason, value: this._shellIntegration.reason });
		}
		// Real lifecycle: the renderer learns pid and cwd from the native PTY itself.
		this._onProcessReady.fire({ pid: this._pid, cwd: this._cwd, windowsPty: undefined });

		const snapshot = this._attachment.snapshot;
		if (snapshot) {
			this._replaying = true;
			this._onDidChangeProperty.fire({ type: ProcessPropertyType.OverrideDimensions, value: { cols: snapshot.cols, rows: snapshot.rows, forceExactSize: true } });
			try {
				if (snapshot.data) { await this._writeTracked(snapshot.data); }
				if (snapshot.pendingBytes.length) {
					const prefix = this._decoder.decode(new Uint8Array(snapshot.pendingBytes), { stream: true });
					if (prefix) { await this._writeTracked(prefix); }
				}
				if (snapshot.commands) { this._onRestoreCommands.fire(snapshot.commands); }
				await this._call('terminal.resume', { throughDataId: this._attachment.throughDataId });
			} finally {
				this._replaying = false;
				void this._drainResize();
				this._onDidChangeProperty.fire({ type: ProcessPropertyType.OverrideDimensions, value: undefined });
			}
			this._onProcessReplayComplete.fire();
		}
		return this._shellIntegration?.type === 'injection' && this._shellIntegration.newArgs ? { injectedArgs: this._shellIntegration.newArgs } : undefined;
	}

	private _matches(event: ReverseEvent): boolean {
		return !this._detached && event.pageId === this._attachment.pageId && event.generation === this._attachment.generation;
	}

	private _call<T>(method: string, params: object = {}): Promise<T> {
		return callTerminal<T>(method, { ...params, sessionId: this._sessionId,
			pageId: this._attachment.pageId, generation: this._attachment.generation });
	}

	private _writeTracked(data: string): Promise<void> {
		const event: IProcessDataEvent = { data, trackCommit: true };
		this._onProcessData.fire(event);
		if (!event.writePromise) { return Promise.reject(new Error('[codipad-terminal] xterm did not accept a tracked write')); }
		return event.writePromise;
	}

	private _queueWrite(text: string, dataIds: number[]): void {
		const committed = this._writeTracked(text);
		this._pendingWrites = this._pendingWrites.then(() => committed).then(async () => {
			for (let offset = 0; offset < dataIds.length; offset += 512) {
				await this._call('terminal.ackBatch', { dataIds: dataIds.slice(offset, offset + 512) });
			}
		});
		void this._pendingWrites.catch(error => this._logService.error('[codipad-terminal] output commit failed', error));
	}

	private _onNativeData(event: ReverseEvent): void {
		if (typeof event.data !== 'string' || typeof event.dataId !== 'number' ||
			!Number.isSafeInteger(event.dataId) || event.dataId <= 0) {
			return;
		}
		const bytes = decodeBase64(event.data);
		const text = this._decoder.decode(bytes.buffer, { stream: true });
		const batch = (event as ReverseEvent & { dataIds?: unknown }).dataIds;
		const ids = batch === undefined ? [event.dataId] : batch;
		if (!Array.isArray(ids) || ids.length === 0 || ids.length > 256 ||
			ids.some((id, index) => !Number.isSafeInteger(id) || id <= 0 || (index > 0 && id <= ids[index - 1])) || ids[ids.length - 1] !== event.dataId) {
			this._onNativeError({ ...event, reason: 'invalid output batch identity' });
			return;
		}
		this._undeliveredDataIds.push(...ids);
		if (text.length) {
			this._queueWrite(text, this._undeliveredDataIds);
			this._undeliveredDataIds = [];
		}
	}

	/** Transport-level failure: log, surface, ask native to stop, keep waiting for the real exit. */
	private _onNativeError(event: ReverseEvent): void {
		const code = typeof event.code === 'number' && Number.isFinite(event.code) ? event.code : undefined;
		const message = event.reason ?? event.message ?? 'transport error';
		this._lastError = `session ${this._sessionId}: ${message}${code !== undefined ? ` (code ${code})` : ''}`;
		this._logService.error(`[codipad-terminal] ${this._lastError}`);
		if (!this._stopRequested) {
			this._stopRequested = true;
			void this._call('terminal.stop').catch(() => { /* already gone */ });
		}
	}

	get lastError(): string | undefined {
		return this._lastError;
	}

	private async _onNativeExit(event: ReverseEvent): Promise<void> {
		if (this._exitEmitted) {
			return; // exactly one exit, even if stop and the native event race
		}
		this._exitEmitted = true;
		const tail = this._decoder.decode();   // flush any incomplete sequence
		if (tail.length) {
			this._queueWrite(tail, this._undeliveredDataIds);
			this._undeliveredDataIds = [];
		}
		try {
			await this._pendingWrites;
			for (const dataId of this._undeliveredDataIds.splice(0)) { await this._call('terminal.ack', { dataId }); }
			await this._call('terminal.ackExit');
		} catch (error) {
			this._logService.error('[codipad-terminal] unread terminal exit retained by native', error);
		}
		if (this._detached) { return; }
		this._disposeSubscriptions();
		releaseReverseEvents('terminal.data', this._sessionId);
		releaseReverseEvents('terminal.exit', this._sessionId);
		releaseReverseEvents('terminal.error', this._sessionId);
		this._onProcessExit.fire(typeof event.code === 'number' && Number.isFinite(event.code) ? event.code : undefined);
	}

	private _disposeSubscriptions(): void {
		for (const subscription of this._subscriptions.splice(0)) {
			subscription.dispose();
		}
	}

	private _send(method: string, params: object): Promise<void> {
		if (this._stopped || this._replaying) {
			return Promise.resolve(); // already stopped: nothing to write to
		}

		return this._call(method, params).then(() => undefined, error => {
			this._logService.error(`[codipad-terminal] ${method} failed: ${error instanceof Error ? error.message : String(error)}`);
		});
	}

	input(data: string): void {
		void this._send('terminal.input', { sessionId: this._sessionId, data: encodeBase64(VSBuffer.wrap(new TextEncoder().encode(data))) });
	}

	resize(cols: number, rows: number): void {
		this._requestedSize = { cols, rows };
		void this._drainResize();
	}

	private async _drainResize(): Promise<void> {
		if (this._resizePending || this._stopped || this._replaying) { return; }
		this._resizePending = true;
		try {
			while (this._requestedSize && !this._stopped) {
				const size = this._requestedSize;
				this._requestedSize = undefined;
				if (size.cols === this._cols && size.rows === this._rows) { continue; }
				try {
					await this._call('terminal.resize', size);
					this._cols = size.cols;
					this._rows = size.rows;
				} catch (error) {
					this._logService.error('[codipad-terminal] resize failed', error);
				}
			}
		} finally { this._resizePending = false; }
	}

	/** Native expects Linux signal numbers; unsupported names are rejected, never sent as strings. */
	sendSignal(signal: string): void {
		const number = SIGNALS[signal.toUpperCase().replace(/^SIG/, '')];
		if (number === undefined) {
			throw new Error(`[codipad-terminal] sendSignal(${signal}): unsupported signal name`);
		}
		void this._send('terminal.signal', { sessionId: this._sessionId, signal: number });
	}

	shutdown(_immediate: boolean): void {
		if (this._stopped) {
			return;
		}
		this._stopped = true;
		// Stop requests the PTY close; the exit event comes from native, never fabricated here.
		void this._call('terminal.stop').catch(() => { /* already gone */ });
	}

	async processBinary(data: string): Promise<void> {
		if (this._stopped || this._replaying) { return; }
		const bytes = new Uint8Array(data.length);
		for (let i = 0; i < data.length; i++) {
			const byte = data.charCodeAt(i);
			if (byte > 255) { throw new Error('[codipad-terminal] binary input contains a non-byte character'); }
			bytes[i] = byte;
		}
		await this._call('terminal.input', { data: encodeBase64(VSBuffer.wrap(bytes)) });
	}

	async clearBuffer(): Promise<void> {
		await this._call('terminal.clearBuffer');
	}

	acknowledgeDataEvent(_charCount: number): void {
		// Upstream batches character ACKs; native event credits use the exact writePromise above.
	}

	async detach(): Promise<void> {
		if (this._detached) { return; }
		await this._call('terminal.detach');
		this._detached = true;
		this._stopped = true;
		this._disposeSubscriptions();
	}

	async setUnicodeVersion(version: '6' | '11'): Promise<void> {
		await this._call('terminal.setUnicodeVersion', { version });
	}

	async updateMetadata(metadata: object): Promise<void> {
		await this._call('terminal.metadata', { metadata: terminalPresentationMetadata(metadata) });
	}

	async setNextCommandId(commandLine: string, commandId: string): Promise<void> {
		await this._call('terminal.setNextCommandId', { commandLine, commandId });
	}

	async getInitialCwd(): Promise<string> {
		return this._cwd;
	}

	async getCwd(): Promise<string> {
		const reply = await this._call<{ cwd: string | null; guestCwd: string }>('terminal.cwd');

		return executionCwd(reply);
	}

	async refreshProperty<T extends ProcessPropertyType>(property: T): Promise<IProcessPropertyMap[T]> {
		if (property === ProcessPropertyType.Cwd) {
			return (await this.getCwd()) as IProcessPropertyMap[T];
		}

		return refuse(`refreshProperty(${property})`);
	}

	async updateProperty<T extends ProcessPropertyType>(property: T, value: IProcessPropertyMap[T]): Promise<void> {
		if (property === ProcessPropertyType.FixedDimensions) {
			await this.updateMetadata({ fixedDimensions: value });
			return;
		}
		return refuse(`updateProperty(${property})`);
	}

	dispose(): void {
		this._detached = true;
		this._disposeSubscriptions();
		this._onProcessData.dispose();
		this._onProcessReady.dispose();
		this._onDidChangeProperty.dispose();
		this._onProcessExit.dispose();
		this._onProcessReplayComplete.dispose();
		this._onRestoreCommands.dispose();
	}
}

export class NativeTerminalBackend implements ITerminalBackend {

	readonly remoteAuthority = undefined;   // local authority: the ordinary terminal UI path
	readonly isResponsive = true;
	readonly whenReady = Promise.resolve();

	readonly onPtyHostUnresponsive = Event.None;
	readonly onPtyHostResponsive = Event.None;
	readonly onPtyHostRestart = Event.None;
	readonly onDidRequestDetach = Event.None;

	private _ready = false;
	private readonly _handoffOffers = new Map<string, { instance: ITerminalInstance; process: NativeTerminalProcess }>();

	setHandoffServices(instantiation: IInstantiationService): void {
		onReverseEvent('terminal.handoffRequest', 0, event => {
			void (async () => {
				if (!event.data) { return; }
				const request = JSON.parse(event.data) as { requestId: string; workspaceId: string; instanceId: number };
				const instance = instantiation.invokeFunction(accessor => accessor.get(ITerminalService).getInstanceFromResource(getTerminalUri(request.workspaceId, request.instanceId)));
				if (!instance || !instance.persistentProcessId || instance.shellLaunchConfig.isFeatureTerminal || instance.shellLaunchConfig.customPtyImplementation) { return; }
				const process = this._processes.get(instance.persistentProcessId);
				if (!process) { return; }
				this._handoffOffers.set(request.requestId, { instance, process });
				try {
					await callTerminal('terminal.offerHandoff', { requestId: request.requestId, sessionId: process.id, generation: process.handoffGeneration });
				} catch { this._handoffOffers.delete(request.requestId); }
				// A timed-out or cancelled offer never owns the source view.
				setTimeout(() => this._handoffOffers.delete(request.requestId), 20_000);
			})().catch(error => this._logService.warn('[codipad-terminal] terminal handoff offer failed', error));
		});
		onReverseEvent('terminal.handoffComplete', 0, event => {
			if (!event.data) { return; }
			const { requestId, sessionId } = JSON.parse(event.data) as { requestId: string; sessionId: number };
			const offer = this._handoffOffers.get(requestId);
			if (!offer || offer.process.id !== sessionId) { return; }
			this._handoffOffers.delete(requestId);
			offer.process.markTransferred();
			if (this._processes.get(sessionId) === offer.process) { this._processes.delete(sessionId); }
			instantiation.invokeFunction(accessor => {
				if (offer.instance.target === TerminalLocation.Editor) {
					accessor.get(ITerminalEditorService).detachInstance(offer.instance);
				} else {
					accessor.get(ITerminalGroupService).getGroupForInstance(offer.instance)?.removeInstance(offer.instance);
				}
				void offer.instance.detachProcessAndDispose(TerminalExitReason.User);
			});
		});
	}
	private readonly _processes = new Map<number, NativeTerminalProcess>();
	private readonly _revivedIds = new Map<number, number>();
	private readonly _revivedIdentities = new Map<string, string>();
	private _restore: Promise<void> | undefined;
	private _checkpoint: NativeTerminalCheckpoint | undefined;
	private _virtualLayout: ITerminalsLayoutInfo | undefined;
	private readonly _pendingRevivals = new Map<number, ISerializedTerminalState>();
	private readonly _revivalRequests = new Map<number, Promise<ITerminalChildProcess | undefined>>();
	private _archive: ArchivedTerminalHistory[] = [];
	private readonly _failedRevivals = new Map<number, unknown>();
	private _restoreWorkspace: string | undefined;
	private _hostIncarnation: string | undefined;

	constructor(
		private readonly _logService: ILogService,
		@IConfigurationResolverService private readonly configurationResolverService: IConfigurationResolverService,
		@IHistoryService private readonly historyService: IHistoryService,
		@IWorkspaceContextService private readonly workspaceContextService: IWorkspaceContextService,
		@IConfigurationService private readonly configurationService: IConfigurationService,
		@ILabelService private readonly labelService: ILabelService,
		@IStorageService private readonly storageService: IStorageService,
		@IEnvironmentVariableService private readonly environmentVariableService: IEnvironmentVariableService,
		@IProductService private readonly productService: IProductService,
		@INotificationService private readonly notificationService: INotificationService,
		@IEditorService private readonly editorService: IEditorService
	) {
		installReverseEventReceiver();
	}

	setReady(): void {
		this._ready = true;
	}

	async createProcess(
		shellLaunchConfig: IShellLaunchConfig,
		cwd: string,
		cols: number,
		rows: number,
		unicodeVersion: '6' | '11',
		env: IProcessEnvironment,
		options: ITerminalProcessOptions,
		shouldPersist: boolean,
		revival?: { token: string; sourceIncarnation: string; data: string; commands?: ISerializedCommandDetectionCapability }
	): Promise<ITerminalChildProcess> {
		const revivalOwnership = revival ? this._scopeFence() : undefined;
		revivalOwnership?.();
		if (!isNativeAvailable()) {
			throw new Error('[codipad-terminal] codipadNative is not installed by the shell; no PTY can be created');
		}
		if (!this._ready) {
			throw new Error('[codipad-terminal] native terminal backend is not ready');
		}

		if (typeof shellLaunchConfig.args === 'string') {
			// A string here would be spread into characters; refuse rather than corrupt the argv.
			throw new Error('[codipad-terminal] createProcess: shellLaunchConfig.args must be a string[] on this platform');
		}

		const configuredScrollback = this.configurationService.getValue<number | undefined>(TerminalSettingId.PersistentSessionScrollback);
		const scrollback = configuredScrollback === undefined ? 100 : configuredScrollback;
		// Match the pinned serializer's allocation bounds before shell integration has side effects.
		if (!Number.isSafeInteger(scrollback) || scrollback < 0 || scrollback > 10000 ||
			!Number.isSafeInteger(cols) || cols < 2 || cols > 1000 ||
			!Number.isSafeInteger(rows) || rows < 1 || rows > 500 || cols * (rows + scrollback) > 2_000_000) {
			throw new Error(`[codipad-terminal] ${TerminalSettingId.PersistentSessionScrollback}: native replay requires 0–10000 whole lines and at most 2000000 cells at the requested dimensions`);
		}

		const workspace = this.workspaceContextService.getWorkspace();
		const workspaceId = workspace.id;
		// BrowserPathService uses '/' as a synthetic home when no folder is open. Let the
		// native host choose its authorized HOME, while preserving every explicit cwd.
		const configuredCwd = this.configurationService.getValue<string | undefined>('terminal.integrated.cwd');
		// With no folder, upstream ignores literal relative configured paths and returns
		// the browser's synthetic root. Do not override absolute or variable-based paths.
		const ignoredRelativeCwd = !!configuredCwd && !configuredCwd.startsWith('/') &&
			!configuredCwd.includes('${') && (cwd === '' || cwd === '/');
		const syntheticHome = workspace.folders?.length === 0 && !revival && !shellLaunchConfig.cwd &&
			(cwd === '' || cwd === '/') && (!configuredCwd || ignoredRelativeCwd);
		const launchConfig = savedLaunch(shellLaunchConfig, options);
		const launchMetadata = terminalLaunchMetadata(shellLaunchConfig, options, this.labelService.getWorkspaceLabel(workspace));
		const executable = shellLaunchConfig.executable ?? DEFAULT_SHELL;
		const stringEnv: Record<string, string> = {};
		for (const [name, value] of Object.entries(env)) {
			if (typeof value === 'string') {
				stringEnv[name] = value;
			}
		}
		const injection = await getNativeShellIntegration({ ...shellLaunchConfig, executable }, options, stringEnv, this._logService);
		if (injection.type === 'injection') {
			Object.assign(stringEnv, injection.envMixin);
		} else if (options.shellIntegration.nonce) {
			// Match the stock process: custom/manual integration still receives its nonce.
			stringEnv['VSCODE_NONCE'] = options.shellIntegration.nonce;
		}
		const nativeEnvironment = await this.getEnvironment();
		const unsetEnv = Object.keys(nativeEnvironment).filter(name => typeof stringEnv[name] !== 'string');

		if (revival) {
			revivalOwnership!();
			if (!this._revivalEnabled()) { throw new Error('[codipad-terminal] process revival is disabled'); }
		}
		const reply = await callTerminal<NativeCreateReply>('terminal.create', {
			workspaceId, launchMetadata, launchConfig, revival, shouldPersist, unicodeVersion, shellIntegrationNonce: options.shellIntegration.nonce, scrollback,
			cols,
			rows,
			// The native side maps the resolved host path once; it must be a file: URI, not a raw path.
			...(syntheticHome ? {} : { cwdUri: URI.file(cwd).toString() }),
			executable,
			args: injection.type === 'injection' && injection.newArgs ? injection.newArgs : shellLaunchConfig.args ? [...shellLaunchConfig.args] : [],
			env: stringEnv,
			unsetEnv,
		});

		// The child id is the native session id: listProcess reports the same ids.
		const process = new NativeTerminalProcess(reply.sessionId, reply.sessionId, reply.pid, executionCwd(reply), cols, rows, this._logService, reply, shouldPersist, injection);
		this._processes.set(process.id, process);
		process.onProcessExit(() => this._processes.delete(process.id));
		return process;
	}

	restartPtyHost(): void {
		// Genuinely unsupported: there is no pty host process to restart.
		throw new Error('[codipad-terminal] restartPtyHost: no pty host exists in this composition');
	}

	async attachToProcess(id: number): Promise<ITerminalChildProcess | undefined> {
		const reply = await callTerminal<NativeCreateReply>('terminal.attach', {
			sessionId: id, workspaceId: this.workspaceContextService.getWorkspace().id
		});
		this._processes.get(id)?.dispose();
		const process = new NativeTerminalProcess(id, id, reply.pid, executionCwd(reply),
			reply.snapshot!.cols, reply.snapshot!.rows, this._logService, reply, true);
		this._processes.set(id, process);
		process.onProcessExit(() => { if (this._processes.get(id) === process) { this._processes.delete(id); } });
		return process;
	}

	async attachToRevivedProcess(_id: number, _pid: number, identity?: string): Promise<ITerminalChildProcess | undefined> {
		try {
			if (!identity || !/^[a-f0-9-]{36}:[a-f0-9-]{36}$/i.test(identity)) { throw new Error('[codipad-terminal] missing or invalid process identity'); }
			const fence = this._scopeFence(); fence();
			await this.getTerminalLayoutInfo(); fence();
			const liveProcess = (await this.listProcesses()).find(process => process.processIdentity === identity);
			fence();
			if (liveProcess) { return await this._attachIdentity(identity); }
			if (identity.split(':')[0] === this._hostIncarnation) {
				const live = (await this.listProcesses()).find(process => process.processIdentity === identity);
				fence();
				if (!live) { throw new Error('[codipad-terminal] unknown live process identity'); }
				return await this._attachIdentity(identity);
			}
			const state = this._checkpoint?.state.find(state => state.processDetails.processIdentity === identity);
			if (!state) { throw new Error('[codipad-terminal] unknown checkpoint process identity'); }
			if (state.processDetails.workspaceId !== this.workspaceContextService.getWorkspace().id) { throw new Error('[codipad-terminal] checkpoint workspace owner mismatch'); }
			if (!this._revivalEnabled()) { throw new Error('[codipad-terminal] process revival is disabled; saved history retained'); }
			const newIdentity = this._revivedIdentities.get(identity);
			if (newIdentity !== undefined) {
				const live = (await this.listProcesses()).find(process => process.processIdentity === newIdentity);
				fence();
				if (!live?.processIdentity) { throw new Error('[codipad-terminal] revived record is no longer owned'); }
				return await this._attachIdentity(live.processIdentity);
			}
			if (this._failedRevivals.has(state.id)) { return failedTerminalRevival(this._failedRevivals.get(state.id)); }
			if (!this._pendingRevivals.has(state.id)) { throw new Error('[codipad-terminal] record is history only'); }
			let request = this._revivalRequests.get(state.id);
			if (!request) { request = this._spawnRevival(state); this._revivalRequests.set(state.id, request); }
			return await request;
		} catch (error) { return failedTerminalRevival(error); }
	}

	private async _attachIdentity(processIdentity: string): Promise<ITerminalChildProcess> {
		const ownership = this._scopeFence(); ownership();
		const reply = await callTerminal<NativeCreateReply>('terminal.attachIdentity', { processIdentity, workspaceId: this.workspaceContextService.getWorkspace().id });
		ownership();
		if (reply.processIdentity !== processIdentity) { throw new Error('[codipad-terminal] native attachment identity mismatch'); }
		this._processes.get(reply.sessionId)?.dispose();
		const process = new NativeTerminalProcess(reply.sessionId, reply.sessionId, reply.pid, executionCwd(reply), reply.snapshot!.cols, reply.snapshot!.rows, this._logService, reply, true);
		this._processes.set(process.id, process);
		process.onProcessExit(() => { if (this._processes.get(process.id) === process) { this._processes.delete(process.id); } });
		return process;
	}

	private _scopeFence(): () => void {
		const id = this.workspaceContextService.getWorkspace().id;
		return () => {
			if (id !== this.workspaceContextService.getWorkspace().id || !this.storageService.hasScope({ id })) { throw new Error('[codipad-terminal] workspace storage owner changed'); }
		};
	}

	private _revivalEnabled(): boolean {
		return this.configurationService.getValue<boolean>('terminal.integrated.enablePersistentSessions') === true && this.configurationService.getValue<string>('terminal.integrated.persistentSessionReviveProcess') !== 'never';
	}

	async listProcesses(): Promise<IProcessDetails[]> {
		return (await callTerminal<IProcessDetails[]>('terminal.list', { workspaceId: this.workspaceContextService.getWorkspace().id })).map(reviveTerminalProcessDetails);
	}

	async getLatency(): Promise<IPtyHostLatencyMeasurement[]> {
		return []; // no pty host, so no latency hops to measure
	}

	async getDefaultSystemShell(_osOverride?: OperatingSystem): Promise<string> {
		const environment = await callTerminal<IProcessEnvironment>('terminal.profileEnvironment', {});
		const root = this.historyService.getLastActiveWorkspaceRoot(Schemas.file);
		const folder = root ? this.workspaceContextService.getWorkspaceFolder(root) : undefined;
		return await resolveGuestProfilePath([environment.SHELL, DEFAULT_SHELL, '/bin/sh'].filter((path): path is string => typeof path === 'string' && !!path), environment,
			path => callTerminal<boolean>('terminal.pathExists', { path }), folder?.uri.fsPath ?? environment.HOME) ?? DEFAULT_SHELL;
	}

	async getProfiles(profiles: unknown, defaultProfile: unknown, includeDetectedProfiles = false): Promise<ITerminalProfile[]> {
		const candidates = new Map<string, { path: string; args?: string[]; env?: ITerminalProfile['env']; overrideName?: boolean; color?: string; icon?: ITerminalProfile['icon']; isAutoDetected?: boolean }>();
		if (includeDetectedProfiles) {
			const contents = await callTerminal<string>('terminal.shells', {});
			if (typeof contents !== 'string') { throw new Error('[codipad-terminal] invalid guest shell list'); }
			for (const { name, path } of await guestDetectedShells(contents, path => callTerminal<boolean>('terminal.pathExists', { path }))) {
				candidates.set(name, { path, isAutoDetected: true });
			}
		}
		if (profiles && typeof profiles === 'object' && !Array.isArray(profiles)) {
			for (const [profileName, value] of Object.entries(profiles)) {
				if (value === null) {
					candidates.delete(profileName);
					continue;
				}
				if (typeof value !== 'object' || Array.isArray(value)) {
					continue;
				}
				const configured = value as Record<string, unknown>;
				if (configured.source !== undefined) { continue; }
				let path = configured.path;
				if (Array.isArray(path)) {
					const environment = await callTerminal<IProcessEnvironment>('terminal.profileEnvironment', {});
					const root = this.historyService.getLastActiveWorkspaceRoot(Schemas.file);
					const folder = root ? this.workspaceContextService.getWorkspaceFolder(root) ?? undefined : undefined;
					if (path.every(candidate => typeof candidate === 'string')) {
						path = await Promise.all(path.map(candidate => this.configurationResolverService.resolveWithEnvironment(environment, folder, candidate)));
					}
					path = await resolveGuestProfilePath(path as unknown[], environment, async candidate => {
						const exists = await callTerminal<unknown>('terminal.pathExists', { path: candidate });
						if (typeof exists !== 'boolean') { throw new Error('[codipad-terminal] invalid guest lookup response'); }
						return exists;
					}, folder?.uri.fsPath ?? environment.HOME);
				}
				if (typeof path !== 'string' || !path || path.includes('\0')) { continue; }
				const icon = typeof configured.icon === 'string' ? { id: configured.icon } : configured.icon;
				candidates.set(profileName, {
					path,
					args: Array.isArray(configured.args) && configured.args.every(arg => typeof arg === 'string') ? configured.args : undefined,
					env: configured.env as ITerminalProfile['env'],
					overrideName: configured.overrideName === true,
					color: typeof configured.color === 'string' ? configured.color : undefined,
					icon: typeof icon === 'object' ? icon as ITerminalProfile['icon'] : undefined,
					isAutoDetected: configured.isAutoDetected === true,
				});
			}
		}
		return [...candidates].map(([profileName, profile]) => ({
			...profile,
			profileName,
			isDefault: profileName === defaultProfile,
		})) as ITerminalProfile[];
	}

	async getWslPath(): Promise<string> {
		return refuse('getWslPath');
	}

	/**
	 * The guest's configured default environment, read from native (`terminal.environment`) rather
	 * than duplicated here: the same per-session base the shell will use for `create`.
	 */
	async getEnvironment(): Promise<IProcessEnvironment> {
		return callTerminal<IProcessEnvironment>('terminal.environment', {});
	}

	/** Shells inherit the configured guest environment; no host/login-shell environment is used. */
	async getShellEnvironment(): Promise<IProcessEnvironment> {
		return this.getEnvironment();
	}

	/** Stock layout is also the app-restart layout; live host layout takes precedence. */
	async setTerminalLayoutInfo(layout?: ITerminalsLayoutInfoById, fence: () => void = () => {}): Promise<void> {
		const ownership = this._scopeFence(); ownership(); fence();
		await callTerminal('terminal.setLayout', { workspaceId: this.workspaceContextService.getWorkspace().id, ...(layout ? { layout } : {}) });
		ownership(); fence();
		this._virtualLayout = undefined;
		this.storageService.store(TerminalStorageKeys.TerminalLayoutInfo, JSON.stringify(layout ?? { tabs: [], background: [] }), StorageScope.WORKSPACE, StorageTarget.MACHINE);
	}

	async getTerminalLayoutInfo(): Promise<ITerminalsLayoutInfo | undefined> {
		this._scopeFence()();
		const workspaceId = this.workspaceContextService.getWorkspace().id;
		if (this._restoreWorkspace !== workspaceId) {
			this._restoreWorkspace = workspaceId;
			this._restore = undefined;
			this._checkpoint = undefined;
			this._virtualLayout = undefined;
			this._pendingRevivals.clear();
			this._revivalRequests.clear();
			this._failedRevivals.clear();
			this._archive = [];
			this._revivedIds.clear();
			this._revivedIdentities.clear();
		}
		await (this._restore ??= this._restoreCheckpoint());
		if (this._virtualLayout) { return this._virtualLayout; }
		const layout = await callTerminal<ITerminalsLayoutInfoById | null>('terminal.getLayout', { workspaceId });
		if (!layout) { return undefined; }
		const sessions = new Map((await this.listProcesses()).map(session => [session.id, session]));
		const seen = new Set<number>();
		const take = (id: number) => {
			if (seen.has(id)) { return null; }
			seen.add(id);
			return sessions.get(id) ?? null;
		};
		return {
			tabs: layout.tabs.map(tab => ({ ...tab, terminals: tab.terminals.map(item => ({ ...item, terminal: take(item.terminal) })).filter(item => item.terminal !== null) })).filter(tab => tab.terminals.length > 0),
			background: layout.background?.map(id => take(id)).filter(item => item !== null) ?? null
		};
	}

	async updateTitle(id: number, title: string, titleSource: TitleEventSource): Promise<void> {
		await this._processes.get(id)?.updateMetadata({ title, titleSource });
	}
	async updateIcon(id: number, _userInitiated: boolean, icon: TerminalIcon, color?: string): Promise<void> {
		await this._processes.get(id)?.updateMetadata({ icon, color: color ?? null });
	}
	async setNextCommandId(id: number, commandLine: string, commandId: string): Promise<void> {
		await this._processes.get(id)?.setNextCommandId(commandLine, commandId);
	}

	async getPerformanceMarks(): Promise<PerformanceMark[]> {
		return []; // measured in the renderer, not through a pty host
	}

	async reduceConnectionGraceTime(): Promise<void> {
		// Native sessions remain owned until explicit close or app-process death.
	}

	async requestDetachInstance(workspaceId: string, instanceId: number): Promise<IProcessDetails | undefined> {
		const result = await callTerminal<IProcessDetails | null>('terminal.requestHandoff', { workspaceId, instanceId, targetWorkspaceId: this.workspaceContextService.getWorkspace().id });
		return result ? reviveTerminalProcessDetails(result) : undefined;
	}

	async acceptDetachInstanceReply(_requestId: number, _persistentProcessId?: number): Promise<void> {
		// Source views are removed only after the destination acknowledges its snapshot.
	}

	async persistTerminalState(fence: () => void = () => {}): Promise<void> {
		const ownership = this._scopeFence();
		const check = () => { ownership(); fence(); };
		check();
		await this.getTerminalLayoutInfo();
		await Promise.allSettled(this._revivalRequests.values());
		check();
		const previous = this.storageService.get(TerminalStorageKeys.TerminalBufferState, StorageScope.WORKSPACE);
		const enabled = this.configurationService.getValue<boolean>('terminal.integrated.enablePersistentSessions');
		const revive = this.configurationService.getValue<string>('terminal.integrated.persistentSessionReviveProcess');
		const value = readCheckpoint(JSON.stringify(await callTerminal<unknown>('terminal.serialize', { workspaceId: this.workspaceContextService.getWorkspace().id })));
		check();
		if (!enabled || revive === 'never') { value.state = []; }
		// Records without an accepted consumer (including skipped tasks) become history only.
		const archive = [...this._archive];
		for (const state of this._pendingRevivals.values()) {
			const key = `${this._checkpoint!.codipad.checkpoint}:${state.id}`;
			if (!archive.some(entry => entry.key === key)) { archive.push({ key, cwd: state.processDetails.cwd, data: state.replayEvent.events[0].data, timestamp: state.timestamp }); }
		}
		value.codipad.archive = archive;
		const text = JSON.stringify(value);
		readCheckpoint(text);
		check();
		this.storageService.store(TerminalStorageKeys.TerminalBufferState, text, StorageScope.WORKSPACE, StorageTarget.MACHINE);
		try { await this.storageService.flush(WillSaveStateReason.SHUTDOWN); }
		catch (error) {
			try {
				check();
				if (previous === undefined) { this.storageService.remove(TerminalStorageKeys.TerminalBufferState, StorageScope.WORKSPACE); }
				else { this.storageService.store(TerminalStorageKeys.TerminalBufferState, previous, StorageScope.WORKSPACE, StorageTarget.MACHINE); }
			} catch { /* A replacement storage scope must never receive this rollback. */ }
			throw error;
		}
		check();
		this._archive = archive;
	}

	private _offerHistory(): void {
		const histories = [...this._archive, ...Array.from(this._pendingRevivals.values(), state => ({ key: String(state.id), cwd: state.processDetails.cwd, data: state.replayEvent.events[0].data, timestamp: state.timestamp }))];
		if (!histories.length) { return; }
		this.notificationService.prompt(Severity.Warning, 'Saved terminal history is available for sessions that have not restarted.', [{
			label: 'Open saved history', run: () => this.editorService.openEditor({ contents: histories.map(h => `Terminal ${h.key} (${h.cwd})\n${removeAnsiEscapeCodes(h.data)}`).join('\n\n'), languageId: 'plaintext', options: { pinned: true } })
		}]);
	}

	private async _restoreCheckpoint(): Promise<void> {
		const ownership = this._scopeFence(); ownership();
		const workspaceId = this.workspaceContextService.getWorkspace().id;
		const text = this.storageService.get(TerminalStorageKeys.TerminalBufferState, StorageScope.WORKSPACE);
		const status = await callTerminal<{ incarnation: string; revived: Record<string, number>; revivedIdentities: Record<string, string> }>('terminal.incarnation');
		ownership();
		this._hostIncarnation = status.incarnation;
		if (!text) { return; }
		const saved = readCheckpoint(text);
		const liveLayout = await callTerminal<ITerminalsLayoutInfoById | null>('terminal.getLayout', { workspaceId });
		const live = new Map((await this.listProcesses()).map(p => [p.id, p]));
		ownership();
		this._checkpoint = saved;
		this._archive = [...(saved.codipad.archive ?? [])];
		if (!this._revivalEnabled()) {
			for (const state of saved.state) {
				const key = `${saved.codipad.checkpoint}:${state.id}`;
				if (!this._archive.some(entry => entry.key === key)) { this._archive.push({ key, cwd: state.processDetails.cwd, data: state.replayEvent.events[0].data, timestamp: state.timestamp }); }
			}
			this._offerHistory();
			return;
		}
		for (const state of saved.state) {
			if (state.processDetails.workspaceId !== workspaceId) {
				this._failedRevivals.set(state.id, new Error('[codipad-terminal] checkpoint workspace owner mismatch'));
				this._pendingRevivals.set(state.id, state);
				continue;
			}
			const token = `${saved.codipad.checkpoint}:${state.id}`;
			const existing = status.revived[token];
			const identity = status.revivedIdentities?.[token];
			const process = identity ? Array.from(live.values()).find(process => process.processIdentity === identity) : undefined;
			if (existing !== undefined && process?.id === existing && state.processDetails.processIdentity) {
				this._revivedIds.set(state.id, process.id);
				this._revivedIdentities.set(state.processDetails.processIdentity, identity!);
			} else if (existing !== undefined) {
				this._failedRevivals.set(state.id, new Error('[codipad-terminal] consumed record no longer has matching ownership'));
				this._pendingRevivals.set(state.id, state);
			} else if (status.incarnation !== saved.codipad.incarnation && this._revivalEnabled()) { this._pendingRevivals.set(state.id, state); }
		}
		if (status.incarnation === saved.codipad.incarnation || (Object.keys(status.revived).length > 0 && liveLayout)) {
			if (status.incarnation === saved.codipad.incarnation) { for (const p of live.values()) { this._revivedIds.set(p.id, p.id); } }
			// Native layout includes terminals created/rearranged after the old app checkpoint.
			this._offerHistory();
			return;
		}
		if (!this._revivalEnabled()) { this._offerHistory(); return; }
		const targets = new Map(saved.state.map(state => {
			const existing = this._revivedIds.get(state.id);
			if (existing !== undefined) {
				const process = live.get(existing);
				if (!process) { this._pendingRevivals.set(state.id, state); return [state.id, null] as const; }
				return [state.id, { ...process, id: state.id, findRevivedId: true }] as const;
			}
			this._pendingRevivals.set(state.id, state);
			return [state.id, reviveTerminalProcessDetails({ ...state.processDetails, id: state.id, isOrphan: true, findRevivedId: true } as IProcessDetails)] as const;
		}));
		this._virtualLayout = {
			tabs: saved.codipad.layout.tabs.map(tab => ({ ...tab, terminals: tab.terminals.map(t => ({ ...t, terminal: targets.get(t.terminal) ?? null })).filter(t => t.terminal !== null) })).filter(tab => tab.terminals.length),
			background: saved.codipad.layout.background?.map(id => targets.get(id) ?? null).filter(t => t !== null) ?? null
		};
		this._offerHistory();
	}

	private async _spawnRevival(state: ISerializedTerminalState): Promise<ITerminalChildProcess> {
		const ownership = this._scopeFence();
		const workspaceId = this.workspaceContextService.getWorkspace().id;
		const saved = this._checkpoint!;
		try {
			ownership();
			if (!this._revivalEnabled()) { throw new Error('[codipad-terminal] process revival is disabled'); }
			const root = this.historyService.getLastActiveWorkspaceRoot();
			const folder = root ? this.workspaceContextService.getWorkspaceFolder(root) ?? undefined : undefined;
			const resolver = terminalEnvironment.createVariableResolver(folder, await this.getEnvironment(), this.configurationResolverService);
			const config = { ...state.shellLaunchConfig, cwd: typeof state.shellLaunchConfig.cwd === 'object' ? URI.revive(state.shellLaunchConfig.cwd) : state.shellLaunchConfig.cwd, icon: revive(state.shellLaunchConfig.icon) };
			const savedOptions = state.processLaunchConfig.options;
			const options: ITerminalProcessOptions = { ...savedOptions, workspaceFolder: savedOptions.workspaceFolder ? this.workspaceContextService.getWorkspaceFolder(URI.revive(savedOptions.workspaceFolder.uri)) ?? undefined : undefined, environmentVariableCollections: revive(savedOptions.environmentVariableCollections) };
			const env = await terminalEnvironment.createTerminalEnvironment(config, this.configurationService.getValue('terminal.integrated.env.linux'), resolver, this.productService.version, this.configurationService.getValue(TerminalSettingId.DetectLocale), await (config.useShellEnvironment ? this.getShellEnvironment() : this.getEnvironment()));
			if (shouldUseEnvironmentVariableCollection(config)) { await this.environmentVariableService.mergedCollection.applyToProcessEnvironment(env, { workspaceFolder: terminalEnvironment.getWorkspaceForTerminal(config.cwd, this.workspaceContextService, this.historyService) }, resolver); }
			ownership();
			if (!this._revivalEnabled()) { throw new Error('[codipad-terminal] process revival is disabled'); }
			const event = state.replayEvent.events[0];
			const process = await this.createProcess({ ...config, cwd: state.processDetails.cwd, color: state.processDetails.color, icon: revive(state.processDetails.icon), name: state.processDetails.titleSource === TitleEventSource.Api ? state.processDetails.title : undefined }, state.processDetails.cwd, event.cols, event.rows, state.unicodeVersion, env, options, true,
				{ token: `${saved.codipad.checkpoint}:${state.id}`, sourceIncarnation: saved.codipad.incarnation, commands: state.replayEvent.commands, data: event.data + '\r\n\x1b[0m[History restored — new process]\r\n' });
			ownership();
			if (!process.processIdentity || process.processIdentity.split(':')[0] !== this._hostIncarnation) { throw new Error('[codipad-terminal] new process identity is unavailable'); }
			this._revivedIds.set(state.id, process.id);
			this._revivedIdentities.set(state.processDetails.processIdentity!, process.processIdentity);
			this._pendingRevivals.delete(state.id);
			return process;
		} catch (error) {
			// Never let stock attach-failure fallback retry a partially executed command.
			try {
				ownership();
				this._failedRevivals.set(state.id, error);
				this._offerHistory();
			} catch { /* The previous workspace checkpoint remains owned by its original scope. */ }
			this._logService.warn('[codipad-terminal] accepted revival failed; history retained', state.id, error);
			return failedTerminalRevival(error);
		}
	}

	async installAutoReply(match: string, reply: string): Promise<void> {
		await callTerminal('terminal.installAutoReply', { match, reply });
	}

	async uninstallAllAutoReplies(): Promise<void> {
		await callTerminal('terminal.uninstallAllAutoReplies', {});
	}
}

/** Registers the backend for the local authority; safe to call once per page. */
export function registerNativeTerminalBackend(logService: ILogService, instantiationService: IInstantiationService): NativeTerminalBackend {
	const backend = instantiationService.createInstance(NativeTerminalBackend, logService);
	backend.setHandoffServices(instantiationService);
	backend.setReady();
	(globalThis as any).__codipadCheckpointTerminals = () => instantiationService.invokeFunction(async accessor => {
		const terminals = accessor.get(ITerminalService);
		const workspace = accessor.get(IWorkspaceContextService).getWorkspace().id;
		const storage = accessor.get(IStorageService);
		const page = (globalThis as any).__codipadIncomingDocumentPage;
		const deadline = Date.now() + 4500;
		const fence = () => {
			if (!page || page !== (globalThis as any).__codipadIncomingDocumentPage || workspace !== accessor.get(IWorkspaceContextService).getWorkspace().id || !storage.hasScope({ id: workspace }) || Date.now() >= deadline) { throw new Error('[codipad-terminal] checkpoint expired or owner changed'); }
		};
		let timer: ReturnType<typeof setTimeout> | undefined;
		try {
			await Promise.race([Promise.all([backend.getTerminalLayoutInfo(), terminals.whenConnected]), new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error('[codipad-terminal] terminal restoration is not ready')), 4500); })]);
			fence();
			const groups = accessor.get(ITerminalGroupService);
			const foreground = new Set(terminals.foregroundInstances);
			const background = terminals.instances.filter(instance => !foreground.has(instance) && instance.shouldPersist && instance.shellLaunchConfig.forcePersist).map(instance => instance.persistentProcessId).filter((id): id is number => id !== undefined);
			await backend.setTerminalLayoutInfo({ tabs: groups.groups.map(group => group.getLayoutInfo(group === groups.activeGroup)), background }, fence);
			fence();
			await backend.persistTerminalState(fence);
		} finally { if (timer !== undefined) { clearTimeout(timer); } }
	});
	Registry.as<ITerminalBackendRegistry>(TerminalExtensions.Backend).registerTerminalBackend(backend);

	return backend;
}
