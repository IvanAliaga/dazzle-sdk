// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Bridge from JS to the in-process Dazzle server. Three tiers picked
// in order of per-call latency (fastest first):
//
//   1. JSI HostObject (`globalThis.__dazzle.*`)  ~1  µs   — bindings
//      installed by the native module on init (Android loads
//      `libdazzle_rn_jsi.so` via System.loadLibrary + an
//      `nativeInstallJsi(runtimePtr)` JNI call; iOS grabs the
//      runtime executor from the bridge).
//   2. Sync NativeModule (`DazzleReactNative.*Sync`)  ~15 µs
//      — isBlockingSynchronousMethod on Kotlin / ObjC++.
//   3. Async NativeModule (`DazzleReactNative.*`)  ~100 µs
//      — standard Promise bridge.

import { NativeModules } from 'react-native';

const { DazzleReactNative } = NativeModules;

if (!DazzleReactNative) {
  // eslint-disable-next-line no-console
  console.warn(
    '[dazzle-react-native] native module not linked — run `pod install` on iOS and make sure autolinking picked the Android library.'
  );
}

/** JSI HostObject registered by the native module when the RN
 *  `jsi::Runtime*` is available. When set, hot-path primitives
 *  call into it directly — ~1 µs per call, zero bridge/JSON cost. */
function jsi(): any | undefined {
  return (globalThis as any).__dazzle;
}

export type RespValue =
  | RespBulk
  | RespInt
  | RespArray
  | RespError
  | RespNull;

export class RespBulk { constructor(public readonly value: string) {} }
export class RespInt { constructor(public readonly value: number) {} }
export class RespArray { constructor(public readonly items: RespValue[]) {} }
export class RespError { constructor(public readonly message: string) {} }
export class RespNull {}

export class DazzleTransportError extends Error {
  constructor(msg: string) {
    super(msg);
    this.name = 'DazzleTransportError';
  }
}

/**
 * Execute a Valkey command against the in-process Dazzle server and
 * return a parsed RESP value. Auto-picks the fastest available path.
 */
export async function dazzleCommand(argv: string[]): Promise<RespValue> {
  if (argv.length === 0) {
    throw new Error('dazzleCommand requires at least one argv entry');
  }
  // JSI hot path — ~1 µs.
  const j = jsi();
  if (j?.dazzleCommand) {
    try {
      const raw = j.dazzleCommand(argv) as string | undefined;
      return parseResp(raw ?? '');
    } catch (e: any) {
      throw new DazzleTransportError(
          `dazzleCommand (JSI) failed: ${e?.message ?? e}`);
    }
  }
  // Sync bridge — ~15 µs.
  if (DazzleReactNative?.dazzleCommandSync) {
    try {
      const raw = DazzleReactNative.dazzleCommandSync(argv) as string;
      return parseResp(raw);
    } catch (e: any) {
      throw new DazzleTransportError(
          `dazzleCommandSync(${argv.join(' ')}) failed: ${e?.message ?? e}`);
    }
  }
  // Async bridge fallback.
  let raw: string;
  try {
    raw = await DazzleReactNative.dazzleCommand(argv);
  } catch (e: any) {
    throw new DazzleTransportError(
        `dazzleCommand(${argv.join(' ')}) failed: ${e?.message ?? e}`);
  }
  return parseResp(raw);
}

/** Synchronous hot-path mirror. JSI first, then the blocking
 *  bridge; throws when neither is linked. */
export function dazzleCommandSync(argv: string[]): RespValue {
  if (argv.length === 0) {
    throw new Error('dazzleCommandSync requires at least one argv entry');
  }
  const j = jsi();
  if (j?.dazzleCommand) {
    const raw = j.dazzleCommand(argv) as string | undefined;
    return parseResp(raw ?? '');
  }
  if (!DazzleReactNative?.dazzleCommandSync) {
    throw new Error(
        'dazzleCommandSync not exposed by the native module — fall back to ' +
        'await dazzleCommand() instead.');
  }
  const raw = DazzleReactNative.dazzleCommandSync(argv) as string;
  return parseResp(raw);
}

/** JSI-preferred snapshot accessors the primitives call when
 *  available. They return `null` on miss (caller falls back to
 *  RESP) or `undefined` when the binding isn't installed. */
export const jsiSnap = {
  hgetAll(key: string): string[] | null | undefined {
    const j = jsi();
    return j?.snapHGetAll ? (j.snapHGetAll(key) as string[] | null) : undefined;
  },
  zrangeByScore(
      key: string, min: number, max: number, maxMembers: number,
  ): string[] | null | undefined {
    const j = jsi();
    return j?.snapZRangeByScore
        ? (j.snapZRangeByScore(key, min, max, maxMembers) as string[] | null)
        : undefined;
  },
  sMembers(key: string, maxMembers: number): string[] | null | undefined {
    const j = jsi();
    return j?.snapSMembers ? (j.snapSMembers(key, maxMembers) as string[] | null) : undefined;
  },
  get(key: string): string | null | undefined {
    const j = jsi();
    return j?.snapGet ? (j.snapGet(key) as string | null) : undefined;
  },
};

// ── RESP parser, matching Kotlin `RespParser.kt` / Swift / Dart ──
//
// Parses in UTF-8 BYTE space rather than UTF-16 code-unit space. The
// bulk-length header on the wire (`$NNN`) is a byte count — doing
// `substring(start, start + len)` on a JS UTF-16 string silently
// truncates any bulk containing a multi-byte codepoint (e.g. "°",
// non-ASCII) and shifts every subsequent offset, which is why the
// chat-iot sample (spike summary contains "°") would come back as
// either `[]` or the joined-then-re-parsed remnant on RN.

const _CR   = 0x0d;
const _LF   = 0x0a;
const _PLUS = 0x2b;
const _DASH = 0x2d;
const _COL  = 0x3a;
const _DOL  = 0x24;
const _STAR = 0x2a;

// Hermes on some RN versions does not expose TextEncoder / TextDecoder
// as globals — and any ReferenceError at module-evaluation time would
// turn every downstream import into `undefined`. Use hand-rolled
// UTF-8 encode/decode instead; ASCII stays a tight hot path and the
// occasional multi-byte codepoint is handled inline.

function _utf8Encode(s: string): Uint8Array {
  // Fast path: all ASCII → 1-byte-per-char. Most of our RESP payloads
  // hit this (commands + JSON without non-ASCII).
  const n = s.length;
  let asciiOnly = true;
  for (let i = 0; i < n; i++) {
    if (s.charCodeAt(i) > 0x7f) { asciiOnly = false; break; }
  }
  if (asciiOnly) {
    const out = new Uint8Array(n);
    for (let i = 0; i < n; i++) out[i] = s.charCodeAt(i);
    return out;
  }
  // Slow path: measure byte length, then fill. Handles BMP + surrogate
  // pairs (codepoints above 0xFFFF).
  let byteLen = 0;
  for (let i = 0; i < n; i++) {
    let c = s.charCodeAt(i);
    if (c < 0x80)          byteLen += 1;
    else if (c < 0x800)    byteLen += 2;
    else if (c < 0xd800 || c >= 0xe000) byteLen += 3;
    else { byteLen += 4; i++; } // surrogate pair — skip low surrogate
  }
  const out = new Uint8Array(byteLen);
  let p = 0;
  for (let i = 0; i < n; i++) {
    let c = s.charCodeAt(i);
    if (c < 0x80) {
      out[p++] = c;
    } else if (c < 0x800) {
      out[p++] = 0xc0 | (c >> 6);
      out[p++] = 0x80 | (c & 0x3f);
    } else if (c < 0xd800 || c >= 0xe000) {
      out[p++] = 0xe0 | (c >> 12);
      out[p++] = 0x80 | ((c >> 6) & 0x3f);
      out[p++] = 0x80 | (c & 0x3f);
    } else {
      // Surrogate pair — combine into a single codepoint.
      const hi = c;
      const lo = s.charCodeAt(++i);
      const cp = 0x10000 + (((hi & 0x3ff) << 10) | (lo & 0x3ff));
      out[p++] = 0xf0 | (cp >> 18);
      out[p++] = 0x80 | ((cp >> 12) & 0x3f);
      out[p++] = 0x80 | ((cp >>  6) & 0x3f);
      out[p++] = 0x80 | (cp & 0x3f);
    }
  }
  return out;
}

function _utf8Decode(b: Uint8Array, from: number, to: number): string {
  // ASCII fast path.
  let asciiOnly = true;
  for (let i = from; i < to; i++) {
    if (b[i] > 0x7f) { asciiOnly = false; break; }
  }
  if (asciiOnly) {
    let s = '';
    // Chunk to avoid fromCharCode stack-argument blowup.
    for (let i = from; i < to; i += 0x8000) {
      const end = Math.min(i + 0x8000, to);
      s += String.fromCharCode(...b.subarray(i, end));
    }
    return s;
  }
  // Slow path: decode codepoint-by-codepoint.
  let s = '';
  let i = from;
  while (i < to) {
    const c = b[i];
    if (c < 0x80) {
      s += String.fromCharCode(c);
      i += 1;
    } else if ((c & 0xe0) === 0xc0 && i + 1 < to) {
      const c1 = b[i + 1];
      s += String.fromCharCode(((c & 0x1f) << 6) | (c1 & 0x3f));
      i += 2;
    } else if ((c & 0xf0) === 0xe0 && i + 2 < to) {
      const c1 = b[i + 1];
      const c2 = b[i + 2];
      s += String.fromCharCode(
        ((c & 0x0f) << 12) | ((c1 & 0x3f) << 6) | (c2 & 0x3f));
      i += 3;
    } else if ((c & 0xf8) === 0xf0 && i + 3 < to) {
      const c1 = b[i + 1];
      const c2 = b[i + 2];
      const c3 = b[i + 3];
      let cp = ((c & 0x07) << 18) | ((c1 & 0x3f) << 12) |
               ((c2 & 0x3f) << 6) | (c3 & 0x3f);
      cp -= 0x10000;
      s += String.fromCharCode(0xd800 | (cp >> 10));
      s += String.fromCharCode(0xdc00 | (cp & 0x3ff));
      i += 4;
    } else {
      // Invalid leading byte — replace with U+FFFD and skip.
      s += '\ufffd';
      i += 1;
    }
  }
  return s;
}

export function parseResp(raw: string): RespValue {
  if (!raw || raw.length === 0) {
    throw new DazzleTransportError('empty RESP reply');
  }
  const bytes = _utf8Encode(raw);
  const [v] = parseOne(bytes, 0);
  return v;
}

function _findLf(s: Uint8Array, from: number): number {
  for (let i = from; i < s.length; i++) {
    if (s[i] === _LF) return i;
  }
  throw new DazzleTransportError('unterminated RESP line');
}

function _lineText(s: Uint8Array, from: number, lf: number): string {
  let end = lf;
  if (end > from && s[end - 1] === _CR) end -= 1;
  return _utf8Decode(s, from, end);
}

function parseOne(s: Uint8Array, idx: number): [RespValue, number] {
  if (idx >= s.length) {
    throw new DazzleTransportError('unexpected end of RESP reply');
  }
  const tag = s[idx];
  const cur = idx + 1;
  switch (tag) {
    case _PLUS: {
      const lf = _findLf(s, cur);
      return [new RespBulk(_lineText(s, cur, lf)), lf + 1];
    }
    case _DASH: {
      const lf = _findLf(s, cur);
      return [new RespError(_lineText(s, cur, lf)), lf + 1];
    }
    case _COL: {
      const lf = _findLf(s, cur);
      return [new RespInt(parseInt(_lineText(s, cur, lf), 10)), lf + 1];
    }
    case _DOL: {
      const lf = _findLf(s, cur);
      const len = parseInt(_lineText(s, cur, lf), 10);
      if (len === -1) return [new RespNull(), lf + 1];
      const start = lf + 1;
      const end = start + len;
      const value = _utf8Decode(s, start, end);
      // Skip trailing CRLF (or bare LF).
      let next = end;
      if (next < s.length && s[next] === _CR) next++;
      if (next < s.length && s[next] === _LF) next++;
      return [new RespBulk(value), next];
    }
    case _STAR: {
      const lf = _findLf(s, cur);
      const count = parseInt(_lineText(s, cur, lf), 10);
      if (count === -1) return [new RespNull(), lf + 1];
      let p = lf + 1;
      const items: RespValue[] = [];
      for (let i = 0; i < count; i++) {
        const [child, next] = parseOne(s, p);
        items.push(child);
        p = next;
      }
      return [new RespArray(items), p];
    }
    default: {
      const lf = _findLf(s, idx);
      return [new RespBulk(_lineText(s, idx, lf)), lf + 1];
    }
  }
}

/** Convenience helpers used by primitives. */
export function asString(v: RespValue): string | null {
  if (v instanceof RespBulk) return v.value;
  if (v instanceof RespInt) return String(v.value);
  return null;
}
export function asLong(v: RespValue): number | null {
  if (v instanceof RespInt) return v.value;
  if (v instanceof RespBulk) {
    const n = parseInt(v.value, 10);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}
export function asBulkArray(v: RespValue): (string | null)[] | null {
  if (!(v instanceof RespArray)) return null;
  return v.items.map((e) => {
    if (e instanceof RespBulk) return e.value;
    if (e instanceof RespNull) return null;
    return null;
  });
}
