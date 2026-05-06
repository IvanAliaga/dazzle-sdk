// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Dazzle SDK for Flutter — public entry point.
//
// ```dart
// import 'package:dazzle_flutter/dazzle_flutter.dart';
//
// Future<void> main() async {
//   WidgetsFlutterBinding.ensureInitialized();
//   await DazzleServer.shared.start();
//
//   final hash = DazzleServer.shared.client().hash('agent:chat:turn_1');
//   hash.set('role', 'user');
//   hash.set('text', "What's the weather in Lima?");
//
//   final turn = hash.getAllDirect();   // RESP-free fast path (~30 µs on A14)
// }
// ```

library dazzle_flutter;

// Config + server lifecycle.
export 'src/config.dart';
export 'src/server.dart';

// Primitives.
export 'src/primitives/dazzle.dart'     show Dazzle;
export 'src/primitives/hash.dart';
export 'src/primitives/list.dart';
export 'src/primitives/set.dart';
export 'src/primitives/sorted_set.dart' show SortedSetKey, ScoredMember;
export 'src/primitives/stream.dart'     show StreamKey, StreamEntry;
export 'src/primitives/string.dart';

// Vector index.
export 'src/vector/vector_index.dart';

// Agent core.
export 'src/agent/message.dart';
export 'src/agent/tool.dart';
export 'src/agent/context_store.dart';
export 'src/agent/context_window.dart';
export 'src/agent/llm_client.dart';
export 'src/agent/chat_agent.dart';

// 5 LLM adapters.
export 'src/edge/openai_compatible_client.dart';
export 'src/edge/anthropic_client.dart';
export 'src/edge/llama_cpp_client.dart';
export 'src/edge/litertlm_client.dart';
export 'src/edge/foundation_models_client.dart';

// Command helpers (advanced users only — direct RESP access).
export 'src/ffi/command.dart'
    show dazzleCommand, RespValue, RespBulk, RespInt, RespArray,
         RespError, RespNull, DazzleTransportException;

// Web target — Flutter Web embedded WASM runtime (Scope A: Hash + Vector
// + OPFS persistence).  See the README "Flutter Web" section for the
// index.html setup snippet that loads dazzle.wasm before Flutter boots.
export 'src/web/dazzle_web.dart'
    show DazzleWeb, DazzleWebHash, DazzleWebVectorIndex;

// Desktop targets — Linux / macOS / Windows native via dart:ffi.  Same
// API surface as DazzleWeb (Hash + Vector + binary snapshot), backed by
// libdazzle_lite compiled from the same C++ source as dazzle.wasm.
export 'src/desktop/dazzle_desktop.dart'
    show DazzleDesktop, DazzleDesktopHash, DazzleDesktopVectorIndex;
