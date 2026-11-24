/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench — native Node extension host, over the real wire protocol.
 *
 *  The real `extensionHostProcess` speaks VS Code's `PersistentProtocol` over a byte stream, not raw
 *  payloads: the node side builds `new PersistentProtocol({ socket, initialChunk })`
 *  (`workbench/api/node/extensionHostProcess.ts:243`), which owns 13-byte framing, ack ids and
 *  heartbeats. So this class does exactly what the desktop host does, with a different socket:
 *
 *    codipadNative exthost.start -> sessionId
 *      -> NativeSocket (byte pipe, `nativeSocket.ts`)
 *      -> new PersistentProtocol({ socket })          [upstream framing, no invention here]
 *      -> handshake on the protocol: Ready -> JSON IExtensionHostInitData -> Initialized
 *      -> return the protocol to ExtensionHostManager
 *
 *  Nothing in this file frames, splits, coalesces or re-orders bytes.
 *---------------------------------------------------------------------------------------------*/

import { Emitter, Event } from '../../base/common/event.js';
import { Disposable, DisposableStore, IDisposable } from '../../base/common/lifecycle.js';
import { decodeBase64, encodeBase64, VSBuffer } from '../../base/common/buffer.js';
import { IMessagePassingProtocol } from '../../base/parts/ipc/common/ipc.js';
import { PersistentProtocol } from '../../base/parts/ipc/common/ipc.net.js';
import { ExtensionRunningLocation, LocalProcessRunningLocation } from '../services/extensions/common/extensionRunningLocation.js';
import { MessageType, createMessageOfType, isMessageOfType, IExtensionHostInitData } from '../services/extensions/common/extensionHostProtocol.js';
import { ExtensionHostExtensions, ExtensionHostStartup, IExtensionHost } from '../services/extensions/common/extensions.js';
import { callNative, isNativeAvailable } from './nativeBridge.js';
import { installReverseEventReceiver, onReverseEvent, onSessionOverflow, releaseReverseEvents } from './reverseEvents.js';
import { NativeSocket } from './nativeSocket.js';

/** Native side of the transport: raw socket bytes plus session lifecycle. Injected so tests can drive a real protocol peer. */
export interface IExtensionHostTransport {
	start(generation: number): Promise<{ sessionId: number }>;
	updateLease?(sessionId: number, uris: readonly string[]): Promise<void>;
	send(sessionId: number, dataBase64: string): Promise<void>;
	stop(sessionId: number): Promise<void>;
	onData(sessionId: number, listener: (dataBase64: string) => void): IDisposable;
	onExit(sessionId: number, listener: (code: number, reason: string) => void): IDisposable;
	/** Transport-level failure (native socket error). Not a process lifecycle event. */
	onTransportError(sessionId: number, listener: (reason: string) => void): IDisposable;
}

const HANDSHAKE_TIMEOUT_MS = 60_000;
/** A clean stop is only clean once the native side reported its real exit. */
const EXIT_TIMEOUT_MS = 10_000;
/** Give VS Code's extension host time to deactivate extensions and close owned pseudoterminals. */
const GRACEFUL_STOP_TIMEOUT_MS = 1_000;

export class NativeExtensionHost extends Disposable implements IExtensionHost {

	readonly remoteAuthority = null;
	/** Platform exclusions, enforced by RPC rejection rather than placeholder actors. */
	readonly unavailableMainThreadCustomers = new Map<string, string>([
		['MainThreadChatDebug', 'Chat debugging is not implemented on iPad.'],
		['MainThreadBrowserTunnelProxy', 'Browser tunnel control is not implemented on iPad.'],
		['MainThreadBrowsers', 'Browser CDP control is not implemented on iPad.'],
	]);
	pid: number | null = null;
	extensions: ExtensionHostExtensions | null = null;

	private readonly _onExit = this._register(new Emitter<[number, string | null]>());
	readonly onExit: Event<[number, string | null]> = this._onExit.event;

	private _startPromise: Promise<IMessagePassingProtocol> | null = null;
	private _sessionId: number | null = null;
	private _protocol: PersistentProtocol | null = null;
	private _socket: NativeSocket | null = null;
	/** Set while a handshake is in flight so dispose() can fail it instead of waiting out the timer. */
	private _abortHandshake: ((error: Error) => void) | null = null;
	/** Set from the first line of `_start()` so dispose() can fail a pending native start. */
	private _abortStart: ((error: Error) => void) | null = null;
	/** Own dispose flag: `IDisposable` has no `isDisposed` contract to rely on. */
	private _disposed = false;
	private _exitEmitted = false;
	private _transportFailureReason: string | null = null;
	/** Sessions are stopped at most once, whichever path gets there first. */
	private _stoppedSessions = new Set<number>();
	/** Data/protocol subscriptions; disposed on failure, disconnect timeout or real exit. */
	private _sessionStore: DisposableStore | null = null;
	/** Kept separate so dispose can close the data path while still observing the real native exit. */
	private readonly _exitStores = new Map<number, DisposableStore>();
	/** Sessions whose real native exit was observed, so a stop can tell "already exited" apart. */
	private readonly _exitedSessions = new Set<number>();
	private readonly _exitWaiters = new Map<number, () => void>();

	constructor(
		readonly runningLocation: ExtensionRunningLocation,
		readonly startup: ExtensionHostStartup,
		private readonly _initDataProvider: () => Promise<IExtensionHostInitData>,
		private readonly _transport: IExtensionHostTransport = createNativeTransport(),
		private readonly _log: (message: string) => void = message => console.info(`[codipad-exthost] ${message}`)
	) {
		super();
	}

	start(): Promise<IMessagePassingProtocol> {
		if (this._disposed) {
			return Promise.reject(new Error('[codipad-exthost] host is disposed; start() is not allowed'));
		}
		if (this._protocol) {
			return Promise.resolve(this._protocol);
		}
		// Concurrent callers share one session: a second start() must never spawn a second host.
		this._startPromise ??= this._start().catch(error => {
			this._startPromise = null;
			throw error;
		});

		return this._startPromise;
	}

	private async _start(): Promise<IMessagePassingProtocol> {
		// Abort hook installed before the first await, so a dispose during the native start promise
		// rejects immediately instead of waiting for a session id that may never be useful.
		let aborted = false;
		let rejectStart!: (error: Error) => void;
		const abortedSignal = new Promise<never>((_, reject) => { rejectStart = reject; });
		this._abortStart = error => {
			if (aborted) {
				return;
			}
			aborted = true;
			rejectStart(error);
		};
		abortedSignal.catch(() => { /* observed by the race below */ });

		if (!(this.runningLocation instanceof LocalProcessRunningLocation)) {
			throw new Error(`[codipad-exthost] unsupported running location ${JSON.stringify(this.runningLocation)}`);
		}


		const nativeStart = this._transport.start(0);
		let stoppedLate = false;
		// A session id that arrives after we aborted must still be stopped, exactly once, and must not
		// get listeners or a protocol attached: nothing else touches it.
		nativeStart.then(({ sessionId }) => {
			if ((aborted || this._disposed) && !stoppedLate) {
				stoppedLate = true;
				void this._transport.stop(sessionId).catch(() => { /* already gone */ });
			}
		}, () => { /* observed by the race below */ });

		const { sessionId } = await Promise.race([nativeStart, abortedSignal]);

		if (aborted || this._disposed) {
			throw new Error('[codipad-exthost] host disposed during start');
		}
		this._sessionId = sessionId;

		const store = new DisposableStore();
		const exitStore = new DisposableStore();
		this._exitStores.set(sessionId, exitStore);

		const socket = this._socket = store.add(new NativeSocket({
			write: data => this._transport.send(sessionId, data),
			end: () => this.stopSession(sessionId),
			onFailure: reason => {
				// A socket write failure is a transport failure: reject the handshake and stop the
				// session instead of leaving a native host running with no bytes flowing.

				this._transportFailureReason = reason;
				this._abortHandshake?.(new Error(`[codipad-exthost] socket failure: ${reason}`));
				void this.stopSession(sessionId);
			}
		}));

		// Upstream framing: PersistentProtocol writes/reads the 13-byte protocol header itself. It is
		// constructed BEFORE subscribing to native data, so a `Ready` that was already queued is
		// replayed into a socket that has a protocol consumer (NativeSocket buffers until then).
		const protocol = this._protocol = store.add(new PersistentProtocol({ socket }));
		// A protocol dispose is NOT a process exit: firing onExit here would fabricate a lifecycle
		// event (and double-fire when the native exit arrives).
		store.add(protocol.onDidDispose(() => { /* transport teardown only */ }));

		store.add(this._transport.onData(sessionId, dataBase64 => {
			socket.acceptData(decodeBase64(dataBase64));
		}));

		// One exit subscription for both jobs: fail a pending handshake fast, and emit the single
		// lifecycle exit. `exitReject` exists before the subscription is created, so a transport that
		// replays a pending exit synchronously inside onExit() cannot hit a TDZ reference.
		let exitReject!: (error: Error) => void;
		const exited = new Promise<never>((_, reject) => { exitReject = reject; });
		exited.catch(() => { /* observed by the handshake race; also settles after a successful start */ });
		exitStore.add(this._transport.onExit(sessionId, (code, reason) => {

			socket.acceptClose(new Error(reason || `host exited with code ${code}`));
			const detail = `[codipad-exthost] host exited during handshake (code ${code}${reason ? `: ${reason}` : ''})`;
			exitReject(new Error(detail));
			// The exit is terminal: remember it, release a disconnect waiting for it, then clean up
			// this session's listeners once the emitter has finished firing.
			this._exitedSessions.add(sessionId);
			while (this._exitedSessions.size > 16) {
				const oldest = this._exitedSessions.values().next().value;
				if (oldest === undefined) { break; }
				this._exitedSessions.delete(oldest);
			}
			const waiter = this._exitWaiters.get(sessionId);
			if (waiter) {
				this._exitWaiters.delete(sessionId);
				waiter();
			}
			queueMicrotask(() => {
				if (this._sessionStore === store) {
					this._sessionStore = null;
					store.dispose();
				}
				exitStore.dispose();
				if (this._exitStores.get(sessionId) === exitStore) {
					this._exitStores.delete(sessionId);
				}
			});
			if (this._exitEmitted) {
				return; // exactly one lifecycle exit per host
			}
			this._exitEmitted = true;
			if (!this._disposed) {
				this._onExit.fire([code, reason || null]);
			}
		}));

		// Transport failure: reject the handshake, close the socket, ask native to stop. It does not
		// pretend the process exited.
		store.add(this._transport.onTransportError(sessionId, reason => {
			this._transportFailureReason = reason;
			socket.acceptClose(new Error(reason));
			void this.stopSession(sessionId);
			this._abortHandshake?.(new Error(`[codipad-exthost] transport error: ${reason}`));
		}));

		try {
			if (this._transportFailureReason) {
				throw new Error(`[codipad-exthost] transport error: ${this._transportFailureReason}`);
			}
			await Promise.race([this._performHandshake(protocol, sessionId), exited]);
		} catch (error) {
			// The handshake may have lost the race to `exited` or to a transport error. Invoke the abort
			// hook first so `_performHandshake` clears its own 60s timer and message subscription;
			// clearing the hook without calling it is what leaves the timer armed.
			const abort = this._abortHandshake;
			this._abortHandshake = null;
			abort?.(error instanceof Error ? error : new Error(String(error)));
			this._protocol = null;
			this._socket = null;
			this._sessionId = null;
			this._startPromise = null;
			store.dispose();
			// A failed handshake does not prove the native process exited. Keep this generation's
			// lifecycle subscription until its real exit arrives; native start rejects while it lives.
			await this.stopSession(sessionId);
			throw error;
		}
		this._sessionStore = store;
		this._log(`session ${sessionId} initialized with ${this.extensions?.allExtensions.length ?? 0} extension(s)`);

		return protocol;
	}

	/**
	 * Explicit handshake FSM: `AwaitReady` -> `AwaitInitialized`, with exactly one init-data frame in
	 * between. A duplicate `Ready`, an `Initialized` before `Ready`, or any stray payload is a
	 * protocol violation and fails the start instead of being tolerated.
	 */
	private _performHandshake(protocol: PersistentProtocol, sessionId: number): Promise<void> {
		const self = this;
		return new Promise<void>((resolve, reject) => {
			type Phase = 'awaitReady' | 'preparingInitData' | 'awaitInitialized' | 'settled';
			let phase: Phase = 'awaitReady';
			let timer: ReturnType<typeof setTimeout> | undefined;
			let initDataSent = false;

			const subscription = protocol.onMessage(message => {
				if (phase === 'settled') {
					return;
				}
				if (isMessageOfType(message, MessageType.Ready)) {
					if (phase !== 'awaitReady' || initDataSent) {
						fail('duplicate Ready message in the handshake');
						return;
					}
					phase = 'preparingInitData';

					arm(`session ${sessionId} did not send Initialized within ${HANDSHAKE_TIMEOUT_MS}ms`);
					void this._initDataProvider().then(async initData => {
						const uris = initData.extensions.allExtensions.map(extension => extension.extensionLocation).filter(uri => uri.scheme === 'file').map(uri => uri.toString());
						await this._transport.updateLease?.(sessionId, [...new Set(uris)]);
						if (phase === 'settled') {
							return;
						}
						this.extensions = new ExtensionHostExtensions(
							initData.extensions.versionId, initData.extensions.allExtensions,
							initData.extensions.myExtensions
						);
						protocol.send(VSBuffer.fromString(JSON.stringify(initData)));
						initDataSent = true;       // only now may the host answer with Initialized
						phase = 'awaitInitialized';

					}).catch(error => fail(`init data unavailable: ${error instanceof Error ? error.message : String(error)}`));
					return;
				}
				if (isMessageOfType(message, MessageType.Initialized)) {
					if (phase !== 'awaitInitialized' || !initDataSent) {
						fail(`Initialized received before the init data was sent (phase ${phase})`);
						return;
					}
					phase = 'settled';

					complete();
					return;
				}
				fail(`unexpected ${message.byteLength}-byte protocol message during handshake (phase ${phase})`);
			});

			function arm(message: string): void {
				clearTimeout(timer);
				timer = setTimeout(() => fail(message), HANDSHAKE_TIMEOUT_MS);
			}

			function complete(): void {
				phase = 'settled';
				self._abortHandshake = null;
				clearTimeout(timer);
				subscription.dispose();
				resolve();
			}

			function fail(message: string): void {
				if (phase === 'settled') {
					return;
				}

				phase = 'settled';
				self._abortHandshake = null;
				clearTimeout(timer);
				subscription.dispose();
				reject(new Error(`[codipad-exthost] ${message}`));
			}

			self._abortHandshake = error => fail(error.message);
			arm(`session ${sessionId} did not send Ready within ${HANDSHAKE_TIMEOUT_MS}ms`);
		});
	}

	/** Stops the native session exactly once, no matter which failure path requests it. */
	private async stopSession(sessionId: number): Promise<void> {
		if (this._stoppedSessions.has(sessionId)) {
			return;
		}
		this._stoppedSessions.add(sessionId);
		await this._transport.stop(sessionId).catch(() => { /* already gone */ });
	}

	/**
	 * Stops the active session and waits for the real native exit, not just the `exthost.stop` ACK.
	 * `AbstractExtensionService.stopAllInReverse()` awaits this and then immediately starts the next
	 * host, so resolving early would race the old host against native's "already running" check.
	 * The exit subscription exists from `start()`, so it is armed before the stop is requested.
	 */
	async disconnect(): Promise<void> {
		if (this._sessionId === null) {
			return;
		}
		const sessionId = this._sessionId;
		const sessionStore = this._sessionStore;
		const protocol = this._protocol;
		this._sessionId = null;
		this._protocol = null;
		this._socket = null;
		if (this._exitedSessions.has(sessionId)) {
			await this.stopSession(sessionId);
			return;
		}
		const exited = new Promise<void>((resolve, reject) => {
			const timer = setTimeout(() => {
				this._exitWaiters.delete(sessionId);
				reject(new Error(`[codipad-exthost] session ${sessionId} did not report a native exit within ${EXIT_TIMEOUT_MS}ms; cleanup is incomplete`));
			}, EXIT_TIMEOUT_MS);
			this._exitWaiters.set(sessionId, () => {
				clearTimeout(timer);
				resolve();
			});
		});
		exited.catch(() => { /* observed below; a rejection must reach the caller, not the console */ });
		let gracefulTimer: ReturnType<typeof setTimeout> | undefined;
		try {
			const gracefulExit = protocol
				? new Promise<boolean>(resolve => { gracefulTimer = setTimeout(() => resolve(false), GRACEFUL_STOP_TIMEOUT_MS); })
				: Promise.resolve(false);
			try {
				protocol?.send(createMessageOfType(MessageType.Terminate));
			} catch {
				// A closed protocol uses the existing native stop path below.
			}
			const stoppedGracefully = await Promise.race([exited.then(() => true), gracefulExit]);
			if (!stoppedGracefully) {
				await this.stopSession(sessionId);
			}
			await exited;
			// Keep native session cleanup (including owned descendants) on both graceful and forced stops.
			await this.stopSession(sessionId);
		} catch (error) {
			// A missing native exit is incomplete cleanup. Dispose the data path above, but preserve the
			// generation-scoped lifecycle observer so a late real exit can settle native ownership.
			if (!this._exitedSessions.has(sessionId)) {
				if (this._sessionStore === sessionStore) {
					this._sessionStore = null;
					sessionStore?.dispose();
				}
			}
			throw error;
		} finally {
			if (gracefulTimer !== undefined) {
				clearTimeout(gracefulTimer);
			}
		}
	}

	override dispose(): void {
		this._disposed = true;
		this._abortStart?.(new Error('[codipad-exthost] host disposed during start'));
		this._abortHandshake?.(new Error('[codipad-exthost] host disposed during start; native session stopped'));
		const disconnect = this.disconnect();
		super.dispose();
		// dispose() is synchronous and cannot await; the rejection is logged, never unhandled.
		void disconnect.catch(error => {
			this._log(`disconnect during dispose did not complete: ${error instanceof Error ? error.message : String(error)}`);
		});
	}

	getInspectPort(): undefined {
		return undefined; // no debugger attach over this channel
	}

	async enableInspectPort(): Promise<boolean> {
		return false; // inspect ports need a loopback listener we do not run
	}
}

/**
 * Default transport: the shell's `codipadNative` channel. Reverse events arrive through the single
 * page-wide receiver in `reverseEvents.ts` (shared with the terminal backend), so this must not
 * install a receiver of its own.
 */
export function createNativeTransport(workspaceKind: 'native' | 'remote' | 'empty' = 'native'): IExtensionHostTransport {
	installReverseEventReceiver();

	return {
		async start(generation) {
			if (!isNativeAvailable()) {
				throw new Error('[codipad-exthost] codipadNative is not installed by the shell; refusing to pretend a host started');
			}
			const reply = await callNative<{ sessionId: number }>('exthost.start', { generation, workspaceKind });

			return reply;
		},
		async updateLease(sessionId, uris) {
			await callNative('extension.hostLease', { sessionId, uris });
		},
		async send(sessionId, dataBase64) {
			await callNative('exthost.send', { sessionId, data: dataBase64 });
		},
		async stop(sessionId) {
			// Data for a stopped session is moot, but the exit subscription stays: the real native
			// exit must still reach onExit (no fabricated stop acknowledgement).
			releaseReverseEvents('exthost.data', sessionId);
			await callNative('exthost.stop', { sessionId });
		},
		onData(sessionId, listener) {
			return onReverseEvent('exthost.data', sessionId, event => {
				if (event.overflow) {
					return; // reported through onExit below, never as truncated protocol bytes
				}
				if (typeof event.data === 'string') {
					listener(event.data);
				}
			});
		},
		onExit(sessionId, listener) {
			return onReverseEvent('exthost.exit', sessionId, event => {
				if (event.overflow) {
					releaseReverseEvents('exthost.exit', sessionId);
					listener(1, event.reason ?? 'pre-subscribe buffer exceeded');
					return;
				}
				listener(event.code ?? 1, event.reason ?? '');
			});
		},
		onTransportError(sessionId, listener) {
			const disposables = [
				onReverseEvent('exthost.transportError', sessionId, event => listener(event.reason ?? 'transport error')),
				onSessionOverflow('exthost', sessionId, reason => listener(reason)),
			];

			return { dispose: () => disposables.forEach(disposable => disposable.dispose()) };
		}
	};
}

export { createMessageOfType, MessageType };
