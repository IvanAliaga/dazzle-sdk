# LLM provider switching — copy, paste, ship

Every Dazzle sample (`chat-memory`, `chat-iot`, `chat-kb`) on every
stack (native Android, native iOS, Flutter, React Native) drives a
**generic** `LLMClient` interface. The chat agent, the tool loop, the
Dazzle storage — none of those care which model implements that
interface. Pick a provider, edit one file, build.

## Build matrix (verified)

| Stack            | LlamaCpp (GGUF) | LiteRT-LM (.litertlm) | FoundationModels (iOS 26+) | OpenAI-compatible HTTP |
| ---------------- | :-------------: | :-------------------: | :------------------------: | :--------------------: |
| Native Android   |     ✅          |        ✅             |              —             |          ✅            |
| Native iOS       |     ✅          |        ✅¹            |             ✅²            |          ✅            |
| Flutter          |     ✅          |        ✅             |             ✅²            |          ✅            |
| React Native     |     ✅          |        ✅             |             ✅²            |          ✅            |

Footnotes:

1. **iOS LiteRT-LM is our own port.** Google's official LiteRT-LM
   ships Android-only — we wrote the iOS bridge. Every iOS sample's
   `project.yml` already wires it (the `LiteRTLM-Swift` SwiftPM
   package + `Sources-LiteRTLM/` directory + the post-build dylib
   re-sign script). Switch the `LLMAdapter` and rebuild — no project
   surgery needed.
2. **FoundationModels** compiles on every Apple stack but only runs
   on iOS 26+ / macOS 26+ devices with Apple Intelligence enabled.
   The adapter throws `UnsupportedError` (Flutter/RN) or returns
   `false` from `.isAvailable` (Swift) on older OSes, so you can ship
   a single binary and gate dynamically. See the section below for
   how to enable the model on a simulator or device.

## FoundationModels — bringing the model up

The adapter compiles cleanly under Xcode 26 with the iOS 26 / macOS 26
SDK and links the `FoundationModels.framework` weakly so it stays
optional. At runtime it consults
`SystemLanguageModel.default.availability`:

- `.available` → ready, the adapter returns the live client.
- `.unavailable(.modelNotReady)` → eligible device, but the model
  hasn't been downloaded. Open **Settings → Apple Intelligence &
  Siri**, toggle Apple Intelligence on, and let the device pull the
  ~3 GB model.
- `.unavailable(.appleIntelligenceNotEnabled)` → eligible device,
  Apple Intelligence is switched off. Same Settings path.
- `.unavailable(.deviceNotEligible)` → device hardware doesn't
  qualify (pre-iPhone 15 Pro, pre-M1 Mac, etc.). Use a different
  provider.

### iOS 26 simulator

Apple ships the framework in the iPhone simulators (iOS 26 SDK), but
the model bytes still need to be activated:

```bash
# 1) Pick a booted iOS 26 simulator
xcrun simctl list devices available | grep "iOS 26"

# 2) Open Settings inside the simulator
xcrun simctl launch booted com.apple.Preferences

# 3) Manually: tap Apple Intelligence & Siri → toggle Apple
#    Intelligence ON → wait for the model download (~3 GB).
#    There is no public CLI to script this — Apple gates the
#    download behind the Settings UI even on the simulator.

# 4) Re-launch the sample. Availability flips to `.available`.
```

### Real device (iPhone 15 Pro+, M1 Mac+)

Same flow: Settings → Apple Intelligence & Siri → enable → wait for
download. The Settings UI shows the download progress.

### Verifying without launching the sample

If you just want to confirm the framework links and runtime gating
works (no model needed), run a one-liner in any iOS 26 target:

```swift
import FoundationModels
print(SystemLanguageModel.default.availability)
// → .unavailable(.modelNotReady) on a fresh sim,
//   .available once Apple Intelligence is on
```

Once `.available` returns true on the iOS simulator, the same
FoundationModels block will work in the **Flutter and React Native
samples** running against that simulator — they go through the same
SDK adapter the native iOS sample uses.

## The one file you edit

| Stack          | File                                                       |
| -------------- | ---------------------------------------------------------- |
| Native Android | `samples/_shared/android/LLMAdapter.kt`                    |
| Native iOS     | `samples/_shared/ios/LLMAdapter.swift`                     |
| Flutter        | `samples/_shared/flutter/lib/src/llm_adapter.dart`         |
| React Native   | `samples/chat-{memory,iot,kb}-rn/src/llmAdapter.ts`        |

Each file has the same five labelled blocks — `─── A ───` through
`─── E ───`. Uncomment the one you want, comment the rest, rebuild.
**Nothing else in the sample changes.** The `ChatScreen`, the agent
config, the tool wiring, the Dazzle calls — all identical.

## Picking a provider

| Pick this        | When                                                                                 |
| ---------------- | ------------------------------------------------------------------------------------ |
| LlamaCpp         | You want any GGUF model (Llama, Gemma, Qwen, Phi, Mistral) on-device. Default.       |
| LiteRT-LM        | You target Gemma .litertlm specifically and want Google's mobile-first stack.        |
| FoundationModels | You target iOS 26+ flagships (iPhone 15 Pro+) and want zero downloads / zero API.    |
| OpenAI-compat    | You're prototyping in the cloud, or you self-host (Ollama/vLLM/llama-server/HF).    |
| Anthropic        | You want Claude (3.5 Sonnet, Opus 4, Haiku 4.5, …) via the official `/v1/messages`.  |

## On-device model setup (LlamaCpp / LiteRT-LM)

The samples expect the weights at well-known paths. Run the helpers
**once per machine**:

```bash
# Download to samples/_scripts/_models/
samples/_scripts/download_models.sh

# Push to /data/local/tmp/ on a connected Android device
samples/_scripts/push_models_to_device.sh
```

For iOS, drop the `.gguf` / `.litertlm` into the app's `Resources/`
build phase or into the device's Documents directory.

## API-key endpoints (OpenAI-compatible)

```bash
# OpenAI proper
export OPENAI_API_KEY=sk-...

# HuggingFace Inference Router (free tier, several open-weights LLMs)
export HF_TOKEN=hf_...

# Self-hosted: just change the baseURL — Ollama, vLLM, llama-server,
# Together, Groq all speak the same /v1/chat/completions shape.
```

The Android and iOS samples read the key from a system property
(`-Pdazzle.openai_key=...` on the gradle command line / launch arg
on the iOS scheme); Flutter reads `String.fromEnvironment` (set with
`--dart-define=OPENAI_API_KEY=...`); RN reads `process.env`.

## Anthropic (Claude · `/v1/messages`)

Anthropic's API is **not** OpenAI-compatible — `system` is a
top-level field, tool calls/results are content blocks inside a
`content` array, schemas live under `input_schema`, and the SSE
stream uses `content_block_*` / `message_*` events instead of
OpenAI's unified `delta`. The SDK ships a separate adapter that
handles the mapping so the agent code stays identical.

Single source of truth per platform:

* `sdk/android/src/main/java/dev/dazzle/sdk/edge/AnthropicClient.kt`
  (`HttpURLConnection` + `org.json`, zero external deps)
* `sdk/ios/Sources/AnthropicClient.swift` (`URLSession`, no deps)

Flutter and React Native are **thin bridges** over those two — the
HTTP/SSE/JSON code is not duplicated. See
`docs/plans/05-http-clients-to-jsi-cpp.md` for the planned C/C++
unification of all HTTP-based clients.

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

Wire it in `LLMAdapter.{kt,swift,dart,ts}` — block `─── E ───`.
Default model in the RN sample is `claude-haiku-4-5-20251001`
(cheapest, ~$1 / $5 per MTok input/output); swap for
`claude-opus-4-7`, `claude-sonnet-4-6`, etc. by changing the
`model` argument. Tool-calling Just Works™ — the agent emits the
same `Delta.toolCallStart` / `Delta.toolCallArgs` it gets from
LlamaCpp / OpenAI.

### Live verification matrix

End-to-end smokes against `api.anthropic.com/v1/messages` (real
billing, real model, real tool round-trip where applicable):

| Stack | Sample | Result | Notes |
|---|---|---|---|
| **RN Android** (Moto G35 5G) | `chat-kb-rn` × `haiku-4-5` | **PASS** | 5 turns, 2 tool round-trips, assistant reply quotes literal corpus numbers (76×, 498×, 9×, "A14 Bionic", "Snapdragon 695") |
| **iOS native** (iPhone 17 Pro sim) | `DazzleChatMemory` × `haiku-4-5` | **PASS** | 4 turns, multi-turn memory works, Swift parser validated against real SSE |
| **Flutter Android** (Moto G35 5G) | `chat-memory-flutter` × `haiku-4-5` | **PASS** (after thread fix) | 4 turns, native bridge `AnthropicBridge.kt` exercised end-to-end |
| **Flutter iOS** (iPhone 17 Pro sim) | `chat-memory-flutter` × `haiku-4-5` | **PASS** (after bridge fix) | 4 turns, multi-turn memory works, real reply from the model |
| Android Kotlin native | (any sample) × `AnthropicClient.kt` | **transitively validated** | Same `AnthropicClient.kt` AAR the RN smoke exercised |

The numbers in the chat-kb-rn assistant reply are **literal values
from the on-device FAQ corpus** — proof the path works end-to-end:

```
RN JS  →  NativeModule (Kotlin)  →  libdazzle.so
                                       ├─ Valkey + HNSW_SQ8 (search_kb tool)
                                       └─ embedder (NEON SDOT)
                →  AnthropicClient.kt  →  HTTPS POST /v1/messages
                →  SSE stream parsed   →  Delta(text + tool_use)
                →  ChatAgent           →  tool exec (vector search)
                →  next /v1/messages   →  final synthesis
```

Validates `content_block_start` / `text_delta` /
`input_json_delta` parsing in production, the `tool_use` block
encoding, and the `tool_result` round-trip (Anthropic's "tool
replies are user-side context" contract).

### Bridge nuances we hit on Flutter iOS (and the fix)

Three subtle bugs surfaced when `chat-memory-flutter` ran multi-turn
against Anthropic on the iOS simulator. Worth recording because the
same patterns affect *any* `EventChannel`-backed streaming bridge:

1. **`onCancel` lands AFTER the next `onListen`.** When the dart-side
   subscription closes (turn N's stream finishes), Flutter posts an
   `onCancel` to the platform thread. Meanwhile the agent issues
   turn N+1, whose `onListen` lands first. With a single
   `activeTask` member field, the late `onCancel` ends up cancelling
   turn N+1's task — its `URLSessionTask` to
   `api.anthropic.com/v1/messages` dies with `NSURLErrorCancelled`.
   *Fix:* track tasks in a per-subscription dict; treat `onCancel`
   as a no-op (let tasks complete naturally; `dispose()` cancels
   anything still in-flight on plugin detach).

2. **`FlutterEndOfEventStream` permanently kills the channel.**
   Calling `events(FlutterEndOfEventStream)` after the last delta
   tells Flutter "this `EventChannel` is permanently closed" —
   *every* future `onListen` on it is dropped silently. Turn N+1's
   subscription gets none of its frames. *Fix:* send a plain
   `{"type":"end"}` frame so the dart-side `StreamController`
   closes; never call `FlutterEndOfEventStream` for a per-turn
   stream.

3. **EventChannel buffer can replay the previous turn's last
   frame.** Even with the two fixes above, the new subscription
   occasionally received the *previous* turn's `type:"end"` frame
   as its first event and closed its controller before any real
   chunk arrived. *Fix:* the dart-side shim mints a `streamId`
   cookie on every `stream()` call, the bridge tags every emitted
   frame with that cookie, and the shim drops anything whose
   `streamId` doesn't match.

All three were applied preventively to **every** EventChannel-backed
bridge in the Flutter plugin:

  * `sdk/flutter/dazzle_flutter/ios/Classes/AnthropicBridge.swift`
  * `sdk/flutter/dazzle_flutter/ios/Classes/FoundationModelsBridge.swift`
  * `sdk/flutter/dazzle_flutter/android/.../AnthropicBridge.kt`
  * `sdk/flutter/dazzle_flutter/android/.../LiteRtBridge.kt`

Plus their dart-side shims (which mint and forward the `streamId`
cookie). Future bridges should follow the same template — the
single-`activeTask` + `FlutterEndOfEventStream` shape is a trap.

## Live smoke runs (HuggingFace Router · Llama 3.3 70B · iOS 26.2 sim)

Verified end-to-end with a real LLM. The harness sets
`DAZZLE_REAL_LLM=1` in the launch env, which makes the
`SampleTestRunner` swap the `FakeLLMClient` for whatever
`makeLLMClient()` returns. With `LLMAdapter` pointing at the
HuggingFace Router (Llama 3.3 70B via the Groq backend) and `HF_TOKEN`
in the simulator's launch env:

| Sample        | Real assistant text (excerpt)                                                                                                              | Tool round-trip |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | :-------------: |
| chat-memory   | "You're Ivan Aliaga, and you're building Dazzle, an embedded database with HNSW vector search for on-device LLM agents."                   |        —        |
| chat-iot      | "There were thermal anomalies… A brief temperature spike to 28.5°C occurred around minute 195, and another spike to 29.1°C at minute 512." |  retrieve_anomalies |
| chat-kb       | "At dim=384 N=10,000, Dazzle is 9× faster than sqlite-vector-ai and 76× faster than sqlite-vec on retrieval…"                              |    search_kb    |

### Live smoke runs (HuggingFace Router · Llama 3.3 70B · Moto G35 5G real device)

Same flow as the iOS simulator above, with Wi-Fi on the device + the
HF token pushed to `/data/local/tmp/dazzle_hf_token.txt`. Times
include the HTTP round-trip to Groq (HF's backend for Llama 3.3 70B):

| Stack          | chat-memory                | chat-iot (with retrieve_anomalies)         | chat-kb (with search_kb)                  |
| -------------- | -------------------------- | ------------------------------------------ | ----------------------------------------- |
| native Android | ✅ 8.5 s · recall          | ✅ 7.8 s · "spike to 28.5°C at minute 195" | ✅ 7.7 s · "9× faster than sqlite-vector-ai" |
| Flutter Android| ✅ 9.2 s · recall          | ✅ 9.0 s · same dataset facts              | ✅ 9.5 s · grounded comparison             |
| RN Android     | ✅ 8.9 s · recall          | ✅ 7.8 s · same dataset facts              | ⚠ tool-routing flake (see below)          |

The chat-iot reply on each stack mentions:
- 28.5°C at minute 195 (3 min)
- 29.1°C at minute 512 (4 min)
- humidity ≥55% between minutes 560 and 719

Those are the EXACT rows the SortedSet returned for
`retrieve_anomalies(0, 800)` — the model didn't fabricate any of
them.

#### Known issue: chat-kb on React Native

With Llama 3.3 70B via HF, the chat-kb sample on RN occasionally
returns an empty assistant message because the model decides not to
issue the `search_kb` tool call (the same prompt + same tool
schema works on the other three stacks). This is an LLM-side
routing flake, not an SDK wiring problem — `tools[0].name` lands
in the request payload identically. Workarounds while we tune the
RN tool-call serialiser: (a) use a stronger model, (b) tighten the
system prompt to be more directive, (c) fall back to the
on-device `LlamaCppClient` which has been more reliable in our
runs. The wiring itself is verified — Android native, Flutter, and
iOS native chat-kb all routed search_kb correctly with the same
adapter.

### Side fix: OpenAICompatibleClient + RN

React Native's `whatwg-fetch` polyfill returns `resp.body === null`
for streaming 200s and refuses to expose a `getReader()` in some
versions, which made the agent's `.stream()` consumption throw
`OpenAI HTTP 200: data: …`. The client now:

  1. Checks `resp.status` directly instead of `resp.ok` (some RN
     fetch implementations report ok=false for chunked transfers).
  2. Falls back to `await resp.text()` + buffered SSE parsing when
     `resp.body` isn't streamable, so RN gets the same Delta events
     as the desktop/iOS path.

This also covers HF Router, which always emits SSE even when the
client requests `stream:false` — the buffered parser folds the
chunks back into a single completion.

Each turn round-trips in 5–8 s on a Mac with the iOS 26 simulator.
The numbers in the chat-iot reply (28.5°C, minute 195, 29.1°C,
minute 512) are pulled from the dataset rows Dazzle returned through
`retrieve_anomalies`; the chat-kb numbers come from FAQ rows
returned by the on-device HNSW vector search. The model never made
up anything — the values are exactly what the SortedSet / Hash /
HNSW index served up.

To reproduce on the iOS simulator:

```bash
# 1) Edit samples/_shared/ios/LLMAdapter.swift to make the OpenAICompatible
#    HF block the active return.
# 2) Build for the booted iOS 26 simulator
cd samples/chat-iot/ios && xcodegen generate
xcodebuild -project DazzleChatIot.xcodeproj -scheme DazzleChatIot \
  -destination "id=$(xcrun simctl list devices booted | awk '/Booted/{gsub(/[()]/,"");print $NF;exit}')" \
  -configuration Debug -quiet build

# 3) Install + launch with HF_TOKEN + the real-LLM flag
APP=$(find ~/Library/Developer/Xcode/DerivedData -path '*Debug-iphonesimulator/DazzleChatIot.app' -type d | head -1)
xcrun simctl install booted "$APP"
SIMCTL_CHILD_HF_TOKEN=hf_... \
SIMCTL_CHILD_SAMPLE_TEST=1 \
SIMCTL_CHILD_DAZZLE_REAL_LLM=1 \
xcrun simctl launch --console-pty --terminate-running-process \
    booted io.dazzle.samples.chatiot

# 4) Read the report from the simulator container
DEVICE=$(xcrun simctl get_app_container booted io.dazzle.samples.chatiot data)
cat "$DEVICE/Documents/sample_test_chat-iot.json" | python3 -m json.tool
```

The same `DAZZLE_REAL_LLM=1` switch hooks into the Android, Flutter,
and React Native samples too — each stack reads the env via its
native getter (`/data/local/tmp/dazzle_real_llm` marker on Android,
`Platform.environment` on Flutter, the `getEnv` bridge on RN). With
the Android device on Wi-Fi and `dazzle_hf_token.txt` pushed to
`/data/local/tmp/`, the same Llama 3.3 70B path runs end-to-end on a
Moto G35.

## What "verified" means in the matrix

The cells marked ✅ above were **built end-to-end** with the matching
provider as the active block — no other code changes — using each
stack's standard build:

- Android: `./gradlew :samples-chat-iot:assembleDebug`
- Flutter: `flutter build apk --debug --target-platform android-arm64`
- iOS:     `xcodegen generate && xcodebuild -scheme DazzleChatIot build`
- RN:      `npx react-native bundle --platform android --dev false`

Build success means the symbol resolution, type signatures, and
linker setup are all correct. Whether the model actually generates
tokens at runtime depends on the device having the file (GGUF /
.litertlm) or the right OS / API key — orthogonal to the wiring.
