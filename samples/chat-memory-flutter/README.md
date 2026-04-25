# chat-memory-flutter — pure conversational memory, zero RAG

The Flutter port of `samples/chat-memory`. Minimal Dazzle chat
pattern: no tools, no retrieval, no dataset — just an `LLMClient`
plus Dazzle persisting every turn as a hash so the conversation
survives app restarts and replays on cold boot.

## What the code does

```
User types  →  ChatAgent runs llm.stream(messages=history + userInput)
            →  assistant delta arrives, ValueNotifier fires, UI rebuilds
            →  assistant turn committed to Dazzle as a hash
```

Dazzle storage under the hood:
- Every `ChatTurn` goes into `ContextStore<ChatTurn>` which maps to
  hashes named `agent:<threadId>:memory:<turnId>`. Reads use
  `HashKey.getAllDirect()` — the RESP-free snapshot-cache path,
  **~30 µs per turn on iPhone 12 Pro** (full benchmark released
  with the paper).
- The full history is iterated once on app start
  (`memory.iterate()`) to restore the previous conversation — order
  preserved by the `timestamp` field on each turn.

## Run

### Prerequisites

- Flutter 3.19+.
- `sdk/android/dazzle/build/outputs/aar/dazzle-release.aar` built (for
  Android) or `sdk/ios/Dazzle.xcframework` built (for iOS). Run
  `sdk/android/build.sh` or `sdk/ios/build.sh` once.
- A GGUF model file pushed to the device. Run
  `samples/_scripts/download_models.sh`, then for Android
  `adb push samples/_scripts/_models/qwen2.5-1.5b-instruct-q4_k_m.gguf
  /data/local/tmp/`.

### iOS

```
cd samples/chat-memory-flutter
flutter run -d <your iPhone UDID>
```

### Android

```
cd samples/chat-memory-flutter
flutter run -d <android device ID>
```

## Swap the LLM adapter

Open `samples/_shared/flutter/lib/src/llm_adapter.dart`. Four
adapters are commented in the same file — uncomment the one you want,
comment the rest, rebuild. Nothing else changes.

## Automated test

```
cd samples/chat-memory-flutter
flutter run --dart-define=SAMPLE_TEST=1 -d <device>
```

The app boots, scripts a `FakeLLMClient`, runs two turns, writes
`sample_test_chat-memory.json` into the app's Documents dir, and
exits. Use `samples/_scripts/test_flutter_*.sh` to drive the full
flow from CI.
