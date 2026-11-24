import { NullLogService } from '../vendor/vscode/src/vs/platform/log/common/log.js';
import { Terminal } from '@xterm/headless';
import { Unicode11Addon } from '@xterm/addon-unicode11';
import { SerializeAddon } from '@xterm/addon-serialize';
import { ShellIntegrationAddon } from '../vendor/vscode/src/vs/platform/terminal/common/xterm/shellIntegrationAddon.js';
import { Emitter } from '../vendor/vscode/src/vs/base/common/event.js';
import { TerminalAutoResponder } from '../vendor/vscode/src/vs/platform/terminal/node/terminalContrib/autoReplies/terminalAutoResponder.js';
import type { ITerminalChildProcess } from '../vendor/vscode/src/vs/platform/terminal/common/terminal.js';

// Private seam: @xterm/headless 6.1.0-beta.303, commit c58ea3637f3968e0e6e79cd92cf9aace7ef89ee2.
// Mirror only the pinned decoder and transition lookup to identify a safe replay
// boundary. The real terminal still receives every byte through public write().
const MAX_PENDING = 1024 * 1024;
const MAX_CELLS = 2_000_000;
type Done = (error: string | null, value: unknown | null) => void;
function integer(value: number, min: number, max: number, name: string) {
  if (!Number.isInteger(value) || value < min || value > max) throw new Error(`Invalid ${name}`);
}
function dimensions(cols: number, rows: number, scrollback: number) {
  integer(cols, 2, 1000, 'cols');
  integer(rows, 1, 500, 'rows');
  if (cols * (rows + scrollback) > MAX_CELLS) throw new Error('Terminal cell limit exceeded');
}
function create(options: { cols: number; rows: number; scrollback: number; unicodeVersion: string; shellIntegrationNonce?: string }) {
  options = { ...options };
  integer(options.scrollback, 0, 10000, 'scrollback');
  dimensions(options.cols, options.rows, options.scrollback);
  if (!['6', '11'].includes(options.unicodeVersion)) throw new Error('Unsupported Unicode version');
  const terminal = new Terminal({ cols: options.cols, rows: options.rows, scrollback: options.scrollback, allowProposedApi: true });
  terminal.loadAddon(new Unicode11Addon());
  terminal.unicode.activeVersion = options.unicodeVersion;
  const serialize = new SerializeAddon();
  terminal.loadAddon(serialize);
  const log = new NullLogService();
  const shell = new ShellIntegrationAddon(options.shellIntegrationNonce ?? '', true, undefined, undefined, log);
  terminal.loadAddon(shell);
  const input = (terminal as any)._core?._inputHandler;
  const table = input?._parser?._transitions?.table;
  const Decoder = input?._utf8Decoder?.constructor;
  if (!(table instanceof Uint16Array) || typeof Decoder !== 'function') {
    terminal.dispose();
    throw new Error('Pinned xterm parser seam unavailable');
  }
  const decoder = new Decoder();
  const replyDecoder = new Decoder();
  const liveData = new Emitter<string>();
  const responders = new Map<string, TerminalAutoResponder>();
  let replies: string[] = [];
  const responderProcess = { onProcessData: liveData.event, input: (data: string) => replies.push(data) } as ITerminalChildProcess;
  const one = new Uint8Array(1);
  const decoded = new Uint32Array(4);
  let state = 0;
  let pending: number[] = [];
  let unavailable = false;
  let checkpoint: ReturnType<typeof capture> | undefined;
  function capture() {
    return { data: serialize.serialize({ scrollback: options.scrollback }), commands: shell.serialize(), cols: terminal.cols, rows: terminal.rows };
  }
  function scan(bytes: number[]) {
    let boundary = 0;
    for (let i = 0; i < bytes.length; i++) {
      one[0] = bytes[i];
      const length = decoder.decode(one, decoded);
      for (let j = 0; j < length; j++) {
        const transition = table[(state << 8) | Math.min(decoded[j], 0xa0)];
        const action = transition >> 8;
        // Pinned parser's DCS_UNHOOK/OSC_END/APC_END override the table
        // when ESC terminates a string: it also starts the next escape.
        state = (transition & 255) | (decoded[j] === 27 && [14, 6, 17].includes(action) ? 1 : 0);
      }
      if (state === 0 && decoder.interim.every((x: number) => x === 0)) boundary = i + 1;
    }
    if (boundary) {
      pending = [];
      unavailable = false;
    }
    const suffix = bytes.slice(boundary);
    if (pending.length + suffix.length > MAX_PENDING) {
      pending = [];
      unavailable = true;
    } else if (!unavailable) pending = pending.concat(suffix);
    return boundary;
  }
  let disposed = false;
  let running = false;
  let active: Done | undefined;
  const queue: { bytes?: number[]; normal?: boolean; live?: boolean; done: Done }[] = [];
  function alive() { if (disposed) throw new Error('Terminal state disposed'); }
  // Restore data and commands at the returned dimensions first. Then feed ALL
  // pendingBytes through the renderer's streaming UTF8 decoder and write any
  // decoded text before live bytes. This suffix can contain ESC/CSI/OSC/DCS,
  // not merely an incomplete UTF8 character; data excludes its effects.
  function snapshotValue() {
    if (unavailable) throw new Error('Snapshot unavailable until pending sequence reaches a replay boundary');
    const value = pending.length ? checkpoint : capture();
    if (!value) throw new Error('Missing replay boundary checkpoint');
    return { ...value, pendingBytes: pending.slice(), unicodeVersion: terminal.unicode.activeVersion };
  }
  function pump() {
    if (running || disposed) return;
    const next = queue.shift();
    if (!next) return;
    running = true;
    let called = false;
    const finish: Done = (error, value) => {
      if (called) return;
      called = true;
      active = undefined;
      running = false;
      // Keep processing even if the embedding callback throws.
      try { next.done(error, value); } finally { pump(); }
    };
    active = finish;
    if (next.bytes === undefined) {
      let value;
      try { value = next.normal ? { data: serialize.serialize({ scrollback: options.scrollback, excludeAltBuffer: true, excludeModes: true }), commands: shell.serialize(), cols: terminal.cols, rows: terminal.rows, unicodeVersion: terminal.unicode.activeVersion } : snapshotValue(); } catch (error) { finish(String(error), null); return; }
      finish(null, value); return;
    }
    try {
      const wasClean = !pending.length && !unavailable;
      const boundary = scan(next.bytes);
      const bytes = new Uint8Array(next.bytes);
      replies = [];
      if (next.live) {
        const decodedText = new Uint32Array(bytes.length + 4);
        const count = replyDecoder.decode(bytes, decodedText);
        let text = '';
        for (let offset = 0; offset < count; offset += 8192) text += String.fromCodePoint(...decodedText.subarray(offset, Math.min(count, offset + 8192)));
        if (text) liveData.fire(text);
      }
      const response = replies;
      if (pending.length && boundary < bytes.length) {
        const writeSuffix = () => {
          if (disposed) return;
          if (boundary || wasClean || !checkpoint) checkpoint = capture();
          terminal.write(bytes.subarray(boundary), () => finish(null, response));
        };
        if (boundary) terminal.write(bytes.subarray(0, boundary), writeSuffix);
        else writeSuffix();
      } else {
        terminal.write(bytes, () => finish(null, response));
      }
    } catch (error) { finish(String(error), null); }
  }
  return {
    write(bytes: number[], done: Done) {
      if (typeof done !== 'function') throw new Error('Write callback required');
      try {
        alive();
        if (!Array.isArray(bytes) || bytes.length > 1024 * 1024) throw new Error('Invalid UTF8 bytes');
        for (const byte of bytes) if (!Number.isInteger(byte) || byte < 0 || byte > 255) throw new Error('Invalid UTF8 bytes');
        queue.push({ bytes: bytes.slice(), done });
      } catch (error) { done(String(error), null); return; }
      pump();
    },
    writeLive(bytes: number[], done: Done) {
      if (typeof done !== 'function') throw new Error('Write callback required');
      try {
        alive();
        if (!Array.isArray(bytes) || bytes.length > 1024 * 1024 || bytes.some(byte => !Number.isInteger(byte) || byte < 0 || byte > 255)) throw new Error('Invalid UTF8 bytes');
        queue.push({ bytes: bytes.slice(), live: true, done });
      } catch (error) { done(String(error), null); return; }
      pump();
    },
    installAutoReply(match: string, reply: string) {
      alive();
      responders.get(match)?.dispose();
      responders.set(match, new TerminalAutoResponder(responderProcess, match, reply, log));
    },
    uninstallAllAutoReplies() {
      for (const responder of responders.values()) responder.dispose();
      responders.clear();
    },
    resize(cols: number, rows: number) {
      alive();
      if (running || queue.length) throw new Error('Resize requires settled write callbacks');
      dimensions(cols, rows, options.scrollback);
      terminal.resize(cols, rows);
      if (pending.length || state !== 0 || decoder.interim.some((x: number) => x !== 0)) unavailable = true;
    },
    clearBuffer() {
      alive();
      if (running || queue.length) throw new Error('Clear requires settled write callbacks');
      terminal.clear();
      if (pending.length) unavailable = true;
    },
    setNextCommandId(commandLine: string, commandId: string) {
      alive();
      if (running || queue.length) throw new Error('Command ID requires settled write callbacks');
      if (typeof commandLine !== 'string' || typeof commandId !== 'string') throw new Error('Invalid command ID');
      shell.setNextCommandId(commandLine, commandId);
      if (pending.length) unavailable = true;
    },
    setUnicodeVersion(version: string, done: Done) {
      if (typeof done !== 'function') throw new Error('Unicode callback required');
      try {
        alive();
        if (running || queue.length) throw new Error('Unicode change requires settled write callbacks');
        if (!['6', '11'].includes(version)) throw new Error('Unsupported Unicode version');
        terminal.unicode.activeVersion = version;
        if (pending.length) unavailable = true;
      } catch (error) { done(String(error), null); return; }
      done(null, null);
    },
    restoreCommands(commands: Parameters<typeof shell.deserialize>[0]) {
      alive();
      if (running || queue.length) throw new Error('Command restore requires settled writes');
      shell.deserialize(commands);
    },
    snapshotNormal(done: Done) {
      if (typeof done !== 'function') throw new Error('Snapshot callback required');
      if (disposed) { done('Terminal state disposed', null); return; }
      queue.push({ normal: true, done });
      pump();
    },
    snapshot(done: Done) {
      if (typeof done !== 'function') throw new Error('Snapshot callback required');
      if (disposed) { done('Terminal state disposed', null); return; }
      queue.push({ done });
      pump();
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      for (const responder of responders.values()) responder.dispose();
      responders.clear();
      liveData.dispose();
      terminal.dispose();
      const waiting = queue.splice(0);
      pending = [];
      try { active?.('Terminal state disposed', null); }
      finally { for (const item of waiting) item.done('Terminal state disposed', null); }
    }
  };
}
(globalThis as typeof globalThis & { CodiPadTerminalState: unknown }).CodiPadTerminalState = Object.freeze({ create });
