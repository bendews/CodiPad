/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench — the one page-wide reverse channel from the native shell.
 *
 *  The shell calls exactly one function:
 *
 *    window.__codipadRuntimeEvent({ kind, sessionId, data?, dataId?, byteCount?, code?, reason? })
 *  It returns true only when the event was delivered or retained within the bounded buffer.
 *
 *  Both the extension host (`exthost.data` / `exthost.exit`) and the terminal (`terminal.data` /
 *  `terminal.exit` / `terminal.error`) ride it. One receiver is installed for the whole page; a
 *  second module must never replace it, so every consumer subscribes through here.
 *
 *  Per-session pending buffers are bounded; overflow is reported to subscribers as an error rather
 *  than silently truncating a stream (truncation would corrupt a pty's byte stream).
 *---------------------------------------------------------------------------------------------*/

import { IDisposable } from '../../base/common/lifecycle.js';

export type ReverseEventKind = 'exthost.data' | 'exthost.exit' | 'terminal.data' | 'terminal.exit' | 'terminal.error' | (string & {});

export interface ReverseEvent {
	readonly kind: ReverseEventKind;
	readonly sessionId: number;
	readonly pageId?: string;
	readonly generation?: string;
	readonly data?: string;
	/** Native terminal output identity, held until the workbench acknowledges the decoded text. */
	readonly dataId?: number;
	readonly dataIds?: readonly number[];
	/** Original output bytes for diagnostics; flow control is released by dataId. */
	readonly byteCount?: number;
	readonly code?: number;
	readonly signal?: string;
	readonly reason?: string;
	readonly message?: string;
	/** Set when this event reports a dropped pre-subscribe buffer (never truncated stream data). */
	readonly overflow?: boolean;
}

interface Pending {
	readonly events: ReverseEventWithSession[];
	bytes: number;
}

type ReverseEventWithSession = ReverseEvent & { readonly sessionId: number };

const MAX_PENDING_BYTES_PER_KEY = 1 * 1024 * 1024;
// The terminal authority admits 4 MiB of raw output; base64 expands this before start subscribes.
const MAX_PENDING_TERMINAL_BYTES = 6 * 1024 * 1024;
const MAX_PENDING_KEYS = 16;

const listeners = new Map<string, Set<(event: ReverseEventWithSession) => void>>();
const pending = new Map<string, Pending>();
const overflowed = new Set<string>();
/** Family-scoped overflow: exthost session 1 and terminal session 1 are different sessions. */
const familyOf = (kind: string) => kind.includes('.') ? kind.slice(0, kind.indexOf('.')) : kind;
const overflowKey = (family: string, sessionId: number) => `${family}#${sessionId}`;
const overflowedSessions = new Map<string, string>();

const keyOf = (kind: string, sessionId: number) => `${kind}:${sessionId}`;

function deliver(key: string, event: ReverseEventWithSession): void {
	for (const listener of listeners.get(key) ?? []) {
		listener(event);
	}
}

export function installReverseEventReceiver(): void {
	const target = globalThis as { __codipadRuntimeEvent?: (event: ReverseEvent) => boolean };
	if (target.__codipadRuntimeEvent) {
		return; // already owned by this module (or by an earlier identical install)
	}

	target.__codipadRuntimeEvent = event => {
		if (!event || typeof event.sessionId !== 'number' || typeof event.kind !== 'string') {
			return false;
		}
		const key = keyOf(event.kind, event.sessionId);
		if (overflowed.has(key)) {
			return false;
		}
		if (listeners.get(key)?.size) {
			deliver(key, event);
			return true;
		}

		// Held until a consumer subscribes (e.g. bytes that arrive before the create() reply).
		const size = event.data?.length ?? 0;
		const held = pending.get(key) ?? { events: [], bytes: 0 };
		if (held.bytes + size > (familyOf(event.kind) === 'terminal' ? MAX_PENDING_TERMINAL_BYTES : MAX_PENDING_BYTES_PER_KEY) || (!pending.has(key) && pending.size >= MAX_PENDING_KEYS)) {
			if (!overflowed.has(key)) {
				overflowed.add(key);
				const reason = `pre-subscribe buffer exceeded for ${key}`;
				overflowedSessions.set(overflowKey(familyOf(event.kind), event.sessionId), reason);
				pending.delete(key);
				const overflowEvent: ReverseEventWithSession = { kind: event.kind, sessionId: event.sessionId, reason, overflow: true };
				for (const sessionListener of sessionOverflowListeners.get(overflowKey(familyOf(event.kind), event.sessionId)) ?? []) {
					sessionListener(reason);
					overflowedSessions.delete(overflowKey(familyOf(event.kind), event.sessionId));
				}
				if (listeners.get(key)?.size) {
					deliver(key, overflowEvent);
				}
			}
			return false;
		}
		held.events.push(event);
		held.bytes += size;
		pending.set(key, held);
		return true;
	};
}

/** Subscribes a session/kind; replays anything held, in arrival order. */
export function onReverseEvent(kind: ReverseEventKind, sessionId: number, listener: (event: ReverseEventWithSession) => void): IDisposable {
	installReverseEventReceiver();
	const key = keyOf(kind, sessionId);
	let set = listeners.get(key);
	if (!set) {
		set = new Set();
		listeners.set(key, set);
	}
	set.add(listener);

	const overflowLookup = overflowKey(familyOf(kind), sessionId);
	const sessionOverflow = overflowedSessions.get(overflowLookup);
	if (sessionOverflow) {
		overflowedSessions.delete(overflowLookup);
		listener({ kind, sessionId, reason: sessionOverflow, overflow: true });
	}

	const held = pending.get(key);
	if (held) {
		pending.delete(key);
		for (const event of held.events) {
			listener(event);
		}
	}

	return { dispose: () => set?.delete(listener) };
}

/**
 * Session-wide overflow: a truncated pre-subscribe buffer affects every channel of that session, so
 * consumers that own the lifecycle (not one kind's data) subscribe here.
 */
export function onSessionOverflow(family: string, sessionId: number, listener: (reason: string) => void): IDisposable {
	installReverseEventReceiver();
	const key = overflowKey(family, sessionId);
	const existing = overflowedSessions.get(key);
	if (existing) {
		overflowedSessions.delete(key);
		listener(existing);
	}

	let set = sessionOverflowListeners.get(key);
	if (!set) {
		set = new Set();
		sessionOverflowListeners.set(key, set);
	}
	set.add(listener);

	return {
		dispose: () => {
			set?.delete(listener);
			if (set?.size === 0) {
				sessionOverflowListeners.delete(key);
			}
		}
	};
}

const sessionOverflowListeners = new Map<string, Set<(reason: string) => void>>();

export function releaseReverseEvents(kind: ReverseEventKind, sessionId: number): void {
	const key = keyOf(kind, sessionId);
	listeners.delete(key);
	pending.delete(key);
	overflowed.delete(key);
	const family = familyOf(kind);
	if (![...listeners.keys()].some(existing => existing.startsWith(`${family}.`) && existing.endsWith(`:${sessionId}`))) {
		overflowedSessions.delete(overflowKey(family, sessionId));
		sessionOverflowListeners.delete(overflowKey(family, sessionId));
	}
}
