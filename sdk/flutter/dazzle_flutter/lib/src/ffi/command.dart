// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Thin dart:ffi wrapper that lifts a Dart List<String> argv into a heap
// argv array the C function signature expects, calls
// `dazzle_direct_command`, parses the RESP-over-string reply into a
// typed Dart `RespValue`, and frees everything. Zero-copy for our
// allocation pool — Utf8 comes back via `toDartString`, no double
// conversion.

import 'dart:convert' show utf8;
import 'dart:ffi' as ffi;
import 'dart:typed_data' show Uint8List;
import 'package:ffi/ffi.dart';

import 'bindings.dart';

sealed class RespValue {
  const RespValue();

  /// Convenience: return this value as a `String?` if it's a simple
  /// scalar, null if array / null / error.
  String? get asStringOrNull => switch (this) {
        RespBulk(:final value) => value,
        RespInt(:final value)  => value.toString(),
        _                      => null,
      };

  List<String?>? get asBulkArrayOrNull => switch (this) {
        RespArray(:final items) => items
            .map((e) => switch (e) {
                  RespBulk(:final value) => value,
                  RespNull _             => null,
                  _                      => null,
                })
            .toList(growable: false),
        _ => null,
      };

  int? get asLongOrNull => switch (this) {
        RespInt(:final value)  => value,
        RespBulk(:final value) => int.tryParse(value),
        _                      => null,
      };
}

class RespBulk   extends RespValue { final String value; const RespBulk(this.value); }
class RespInt    extends RespValue { final int    value; const RespInt (this.value); }
class RespArray  extends RespValue { final List<RespValue> items; const RespArray(this.items); }
class RespError  extends RespValue { final String message; const RespError(this.message); }
class RespNull   extends RespValue { const RespNull(); }

/// Execute a Valkey command against the in-process Dazzle server and
/// return a parsed RESP value.
///
/// This is the generic backbone every primitive wrapper (HashKey,
/// SortedSetKey, StringKey, …) uses for its write path and for the
/// RESP-fallback read path. Hot reads should go through the
/// snapshot-cache typed functions (`hgetAllDirect`, etc.) that skip
/// RESP entirely.
///
/// Throws [DazzleTransportException] if the transport is down.
RespValue dazzleCommand(List<String> args) {
  if (args.isEmpty) {
    throw ArgumentError('dazzleCommand requires at least one argv entry');
  }
  final bindings = DazzleBindings.load();

  // Stage argv: char**.
  final argvNative =
      calloc<ffi.Pointer<Utf8>>(args.length);
  final argvStrings = <ffi.Pointer<Utf8>>[];
  try {
    for (var i = 0; i < args.length; i++) {
      final cstr = args[i].toNativeUtf8();
      argvStrings.add(cstr);
      argvNative[i] = cstr;
    }
    final replyPtr = bindings.directCommand(args.length, argvNative);
    if (replyPtr == ffi.nullptr) {
      throw DazzleTransportException(
          'directCommand(${args.join(' ')}) returned null — server down?');
    }
    try {
      // Parse in UTF-8 byte space, not UTF-16 character space. RESP
      // bulk lengths are BYTE counts — using `toDartString()` and then
      // `substring(start, start + len)` truncates whenever the payload
      // contains a multi-byte codepoint (e.g. "°" in a summary field),
      // shifting every subsequent read and corrupting downstream JSON.
      final bytes = _rawBytes(replyPtr);
      return _parseResp(bytes);
    } finally {
      bindings.directFree(replyPtr);
    }
  } finally {
    for (final p in argvStrings) {
      calloc.free(p);
    }
    calloc.free(argvNative);
  }
}

/// Copy the null-terminated UTF-8 reply into a Dart [Uint8List] so we
/// can parse in byte space. The C side owns the memory; we free it
/// after this returns via `directFree`.
Uint8List _rawBytes(ffi.Pointer<Utf8> p) {
  final bytes = p.cast<ffi.Uint8>();
  var n = 0;
  while (bytes.elementAt(n).value != 0) {
    n++;
  }
  // `.asTypedList(n)` aliases the C buffer; copy into an owned list
  // before the caller frees the native allocation.
  return Uint8List.fromList(bytes.asTypedList(n));
}

/// RESP parser. Same grammar the Kotlin `RespParser.kt` and Swift
/// `parseResp` handle. Operates on UTF-8 bytes directly — the bulk
/// length on the wire is a byte count.
RespValue _parseResp(Uint8List bytes) {
  final (v, _) = _parseOne(bytes, 0);
  return v;
}

// ASCII bytes used for scanning.
const int _cr   = 0x0d; // '\r'
const int _lf   = 0x0a; // '\n'
const int _plus = 0x2b; // '+'
const int _dash = 0x2d; // '-'
const int _col  = 0x3a; // ':'
const int _dol  = 0x24; // '$'
const int _star = 0x2a; // '*'

// Find the index of the next '\n'. CRLF and bare LF both terminate —
// we just locate the LF and the `_lineText` helper strips a trailing CR.
int _findLf(Uint8List s, int from) {
  for (var i = from; i < s.length; i++) {
    if (s[i] == _lf) return i;
  }
  throw DazzleTransportException('unterminated RESP line');
}

// Decode the line [from, lf) as UTF-8, dropping a trailing CR if
// present. Used for +/-/: prefixes and for bulk/array length headers.
String _lineText(Uint8List s, int from, int lf) {
  var end = lf;
  if (end > from && s[end - 1] == _cr) end -= 1;
  return utf8.decode(s.sublist(from, end));
}

(RespValue, int) _parseOne(Uint8List s, int idx) {
  if (idx >= s.length) {
    throw DazzleTransportException('unexpected end of RESP reply');
  }
  final tag = s[idx];
  final cur = idx + 1;
  switch (tag) {
    case _plus:
      final lf = _findLf(s, cur);
      return (RespBulk(_lineText(s, cur, lf)), lf + 1);
    case _dash:
      final lf = _findLf(s, cur);
      return (RespError(_lineText(s, cur, lf)), lf + 1);
    case _col:
      final lf = _findLf(s, cur);
      return (RespInt(int.parse(_lineText(s, cur, lf))), lf + 1);
    case _dol:
      final lf = _findLf(s, cur);
      final len = int.parse(_lineText(s, cur, lf));
      if (len == -1) return (const RespNull(), lf + 1);
      final start = lf + 1;
      final end = start + len;
      final value = utf8.decode(s.sublist(start, end));
      // Skip trailing CRLF (or bare LF).
      var next = end;
      if (next < s.length && s[next] == _cr) next++;
      if (next < s.length && s[next] == _lf) next++;
      return (RespBulk(value), next);
    case _star:
      final lf = _findLf(s, cur);
      final count = int.parse(_lineText(s, cur, lf));
      if (count == -1) return (const RespNull(), lf + 1);
      var p = lf + 1;
      final items = <RespValue>[];
      for (var i = 0; i < count; i++) {
        final (child, next) = _parseOne(s, p);
        items.add(child);
        p = next;
      }
      return (RespArray(items), p);
    default:
      // Inline reply fallback.
      final lf = _findLf(s, idx);
      return (RespBulk(_lineText(s, idx, lf)), lf + 1);
  }
}

class DazzleTransportException implements Exception {
  final String message;
  DazzleTransportException(this.message);
  @override
  String toString() => 'DazzleTransportException: $message';
}
