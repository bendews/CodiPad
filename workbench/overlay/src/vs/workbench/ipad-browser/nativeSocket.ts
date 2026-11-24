/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench — `ISocket` over the native extension-host channel.
 *
 *  The real `extensionHostProcess` speaks VS Code's `PersistentProtocol` over a byte stream
 *  (`workbench/api/node/extensionHostProcess.ts:243` builds `new PersistentProtocol({ socket, initialChunk })`
 *  from a socket the renderer hands it). `PersistentProtocol` does its own 13-byte framing, acks and
 *  heartbeats, so this adapter is a byte pipe: bounded writes may coalesce or split protocol
 *  chunks, but bytes must never be duplicated or reordered.
 *
 *  Native contract used here (raw socket bytes, base64 on the wire):
 *    exthost.send {sessionId, data}         -> bytes written to the socket
 *    __codipadRuntimeEvent {kind:'exthost.data', sessionId, data}  <- bytes read from the socket
 *    __codipadRuntimeEvent {kind:'exthost.exit', sessionId, code, reason} <- socket closed
 *---------------------------------------------------------------------------------------------*/

import { Emitter, Event } from '../../base/common/event.js';
import { Disposable, IDisposable } from '../../base/common/lifecycle.js';
import { decodeBase64, encodeBase64, VSBuffer } from '../../base/common/buffer.js';
import { ISocket, NodeSocketCloseEvent, SocketCloseEvent, SocketCloseEventType, SocketDiagnosticsEventType } from '../../base/parts/ipc/common/ipc.net.js';

export interface INativeSocketPort {
	/** Writes raw bytes to the native socket. `data` is base64 of exactly those bytes. */
	write(data: string): Promise<void>;
	/** Closes the native socket. */
	end(): Promise<void>;
	/** A write failed; the owner must treat the transport as failed, not merely closed. */
	onFailure?(reason: string): void;
}

export class NativeSocket extends Disposable implements ISocket {

	private readonly _onData = this._register(new Emitter<VSBuffer>());
	private readonly _onEnd = this._register(new Emitter<void>());
	private readonly _onClose = this._register(new Emitter<NodeSocketCloseEvent>());

	private _closed = false;
	/** Bytes accepted before the protocol subscribed. `PersistentProtocol` is constructed after the
	 *  socket exists, and production must replay queued native bytes into it, not into the void. */
	private _pending: VSBuffer[] = [];
	private _pendingBytes = 0;
	private static readonly MAX_PENDING_BYTES = 2 * 1024 * 1024;
	/** Bound raw bytes and fixed-size queued buffers before base64 bridge allocation. */
	private static readonly MAX_PENDING_WRITE_BYTES = 8 * 1024 * 1024;
	private static readonly MAX_PENDING_WRITE_COUNT = 128;
	private static readonly WRITE_CHUNK_BYTES = 64 * 1024;
	private _pendingWriteBytes = 0;
	private readonly _writeChunks: { readonly buffer: VSBuffer; offset: number; length: number; readonly direct: boolean }[] = [];
	/** One pump awaits actual native completions; individual stream writes retain no promises. */
	private _writePump: Promise<void> | null = null;
	private _ended = false;
	/** First write failure; `drain()` must surface it instead of resolving as if bytes were sent. */
	private _failure: Error | null = null;

	constructor(private readonly _port: INativeSocketPort) {
		super();
	}

	/** Numeric credits only; profile diagnostics must never inspect retained protocol payloads. */
	get pendingWriteState(): Readonly<{ bytes: number; frames: number }> {
		return Object.freeze({ bytes: this._pendingWriteBytes, frames: this._writeChunks.length });
	}

	/** Called by the session router for every `exthost.data` frame of this session. */
	acceptData(bytes: VSBuffer): void {
		if (this._closed) {
			return;
		}
		if (!this._onData.hasListeners()) {
			this._pendingBytes += bytes.byteLength;
			if (this._pendingBytes > NativeSocket.MAX_PENDING_BYTES) {
				this._pending = [];
				this._pendingBytes = 0;
				this.acceptClose(new Error('pre-protocol socket buffer exceeded'));
				return;
			}
			this._pending.push(bytes);
			return;
		}
		this._onData.fire(bytes);
	}

	/**
	 * Called when the native side closed the socket. `error` is undefined for a clean close; the
	 * event shape is upstream's `NodeSocketCloseEvent`, so no cast is needed anywhere.
	 */
	acceptClose(error?: Error): void {
		if (this._closed) {
			return;
		}
		this._closed = true;
		if (this._pendingWriteBytes > 0) {
			this._failure ??= error ?? new Error('socket closed before pending writes completed');
		}
		this._onClose.fire({
			type: SocketCloseEventType.NodeSocketCloseEvent,
			hadError: error !== undefined,
			error
		});
		this._onEnd.fire();
	}

	onData(listener: (e: VSBuffer) => void): IDisposable {
		const subscription = this._onData.event(listener);
		if (this._pending.length) {
			const flush = this._pending.splice(0, this._pending.length);
			this._pendingBytes = 0;
			for (const buffer of flush) {
				this._onData.fire(buffer);
			}
		}
		return subscription;
	}

	onEnd(listener: () => void): IDisposable {
		return this._onEnd.event(listener);
	}

	onClose(listener: (e: SocketCloseEvent) => void): IDisposable {
		return this._onClose.event(listener);
	}

	write(buffer: VSBuffer): void {
		if (this._closed) {
			// Bytes after a close are a bug in the caller, not a normal no-op: record it so drain()
			// reports the loss instead of claiming everything was written.
			this._failure ??= new Error('socket write after close; bytes were not sent');
			return;
		}
		const byteLength = buffer.byteLength;
		if (byteLength === 0) {
			return;
		}
		const direct = byteLength > NativeSocket.WRITE_CHUNK_BYTES;
		const head = this._writeChunks[0];
		const tail = this._writeChunks.at(-1);
		const tailCapacity = tail && !tail.direct ? tail.buffer.byteLength - tail.length : 0;
		const count = this._writeChunks.length + (direct || byteLength > tailCapacity ? 1 : 0);

		// ProtocolWriter hands us a complete frame. Keep one such frame at its original size
		// and bound everything queued alongside it, including small protocol/control writes.
		// A partially sent direct buffer retains its full allocation until its last slice drains.
		const retained = this._pendingWriteBytes + byteLength + (head?.direct ? head.offset : 0);
		if (retained > NativeSocket.MAX_PENDING_WRITE_BYTES || count > NativeSocket.MAX_PENDING_WRITE_COUNT) {
			let largest = direct ? byteLength : 0;
			for (const chunk of this._writeChunks) {
				if (chunk.direct) { largest = Math.max(largest, chunk.buffer.byteLength); }
			}
			if (retained - largest > NativeSocket.MAX_PENDING_WRITE_BYTES || count - (largest ? 1 : 0) > NativeSocket.MAX_PENDING_WRITE_COUNT) {
				const error = new Error(`native socket pending write credit limit exceeded (${this._pendingWriteBytes} bytes, ${this._writeChunks.length} writes)`);
				this.failWrite(error, error.message);
				return;
			}
		}

		this._pendingWriteBytes += byteLength;
		if (direct) {
			this._writeChunks.push({ buffer, offset: 0, length: byteLength, direct: true });
		} else {
			const copied = Math.min(tailCapacity, byteLength);
			if (tail && copied) {
				tail.buffer.set(buffer.slice(0, copied), tail.length);
				tail.length += copied;
			}
			if (copied < byteLength) {
				const chunk = VSBuffer.alloc(NativeSocket.WRITE_CHUNK_BYTES);
				chunk.set(buffer.slice(copied));
				this._writeChunks.push({ buffer: chunk, offset: 0, length: byteLength - copied, direct: false });
			}
		}
		this.startWritePump();
	}

	private startWritePump(): void {
		if (this._writePump) {
			return;
		}
		this._writePump = Promise.resolve().then(() => this.flushWrites()).finally(() => {
			this._writePump = null;
			if (this._writeChunks.length && !this._failure) {
				this.startWritePump();
			}
		});
	}

	private async flushWrites(): Promise<void> {
		try {
			while (this._writeChunks.length && !this._failure) {
				const chunk = this._writeChunks[0];
				const length = Math.min(chunk.length - chunk.offset, NativeSocket.WRITE_CHUNK_BYTES);
				await this._port.write(encodeBase64(chunk.buffer.slice(chunk.offset, chunk.offset + length)));
				chunk.offset += length;
				this._pendingWriteBytes -= length;
				if (chunk.offset === chunk.length) { this._writeChunks.shift(); }
			}
		} catch (error) {
			const reason = error instanceof Error ? error.message : String(error);
			this.failWrite(new Error(`native socket write failed: ${reason}`), reason);
		} finally {
			if (this._failure) {
				this._writeChunks.length = 0;
				this._pendingWriteBytes = 0;
			}
		}
	}

	private failWrite(error: Error, reason: string): void {
		if (this._failure) {
			return;
		}
		this._failure = error;
		this.acceptClose(error);
		this._port.onFailure?.(reason);
	}

	end(): void {
		if (this._closed || this._ended) {
			return;
		}
		this._ended = true;
		this._closed = true;
		this._onEnd.fire();
		void this.drain().catch(() => { /* failed writes already notify the owner */ }).then(() => this._port.end()).catch(() => { /* already gone */ });
	}

	override dispose(): void {
		// Closing the native side is part of disposing the socket, not an optional extra.
		this.end();
		super.dispose();
	}

	async drain(): Promise<void> {
		// Wait for every write the protocol handed us; a no-op here would report data as sent early.
		while (this._writePump) {
			await this._writePump;
		}
		if (this._failure) {
			throw this._failure;
		}
	}

	traceSocketEvent(_type: SocketDiagnosticsEventType, _data?: VSBuffer | Uint8Array | ArrayBuffer | ArrayBufferView): void {
		// No socket diagnostics channel on this transport.
	}
}

export type { ISocket };
export { Event };
