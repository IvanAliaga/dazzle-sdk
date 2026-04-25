# chat-memory — pure conversational memory, zero RAG

The minimal Dazzle chat pattern. No tools, no retrieval, no dataset —
just an `LLMClient` plus Dazzle persisting every turn as a hash so the
conversation survives app restarts and can be replayed on a cold boot.

## What the code does

```
User types  →  ChatAgent runs llm.stream(messages=history + userInput)
            →  assistant delta arrives, view updates
            →  assistant turn committed to Dazzle as a hash
```

Dazzle storage under the hood:
- Every `ChatTurn` goes into `ContextStore<ChatTurn>` which maps to
  hashes named `agent:<threadId>:memory:<turnId>`. Reads use
  `HashKey.getAllDirect()` — the RESP-free snapshot-cache path, **~30 µs
  per turn on iPhone 12 Pro** (full benchmark released with the paper).
- The full history is iterated once on app start (`memory.iterate()`)
  to restore the previous conversation — order preserved by the
  `timestamp` field on each turn.

## Run

### iOS

```
brew install xcodegen                           # one-time
cd samples/chat-memory/ios
xcodegen                                        # → DazzleChatMemory.xcodeproj
open DazzleChatMemory.xcodeproj                 # ⌘R on an iOS device
```

First build downloads nothing. If you keep the default `LlamaCppClient`
adapter you need the Qwen GGUF (~1 GB):

```
samples/_scripts/download_models.sh
# then rebuild so the GGUF is copied into the bundle
```

### Android

```
cd sdk/android
./gradlew :samples-chat-memory:installDebug
# push the GGUF once (if using LlamaCppClient)
adb push samples/_scripts/_models/qwen2.5-1.5b-instruct-q4_k_m.gguf \
         /data/local/tmp/
adb shell am start -n dev.dazzle.samples.chatmemory/.MainActivity
```

## Swap the LLM adapter

Open `samples/_shared/ios/LLMAdapter.swift` (iOS) or
`samples/_shared/android/LLMAdapter.kt` (Android). Four options are
commented in the same file — uncomment the one you want, comment the
rest, rebuild. Nothing else changes.

## What to port when you use this for your own app

1. Copy this sample's directory.
2. Change `threadId = "chat-memory-default"` to whatever namespacing
   makes sense for your user (per-user, per-topic, per-device…).
3. Change the system prompt in the app's `buildAgent()` block.
4. Optionally add tools — the next sample (`chat-iot`) shows how.
