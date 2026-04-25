# Dazzle samples

Production-shaped demos of the Dazzle SDK. **One protocol, five LLM
adapters, three retrieval patterns** — pick the combination that matches
your codebase and migrate in a single file.

| Pattern | Native (iOS + Android) | Flutter | React Native | What it shows |
|---|---|---|---|---|
| **B. Chat memory** | [`chat-memory/`](chat-memory) | [`chat-memory-flutter/`](chat-memory-flutter) | [`chat-memory-rn/`](chat-memory-rn) | Pure chat — Dazzle persists every turn as a hash; `getAllDirect` (~30 µs on iPhone 12 Pro) rebuilds the context. The minimal pattern every dev ports first. |
| **A. Chat + IoT RAG** | [`chat-iot/`](chat-iot) | [`chat-iot-flutter/`](chat-iot-flutter) | _future_ | The paper workload wrapped in a chat UI. Tool-calling asks Dazzle for anomaly windows via SortedSet range queries (`dazzle-precompute` path, 33 µs / retrieval). |
| **C. Chat + knowledge base** | [`chat-kb/`](chat-kb) | [`chat-kb-flutter/`](chat-kb-flutter) | _future_ | Classic semantic-search RAG. Dazzle vector index (`dazzle-sq8`, int8 + NEON SDOT) answers "how do I use Dazzle?" from a bundled 30-row FAQ. |

Every sample is **iOS + Android** (4 platform surfaces: native Swift,
native Kotlin, Flutter, React Native) with identical shape. The only
file that changes when you pick a different LLM runtime is the
platform's LLMAdapter:

- native iOS  → [`_shared/ios/LLMAdapter.swift`](./_shared/ios/LLMAdapter.swift)
- native Android → [`_shared/android/LLMAdapter.kt`](./_shared/android/LLMAdapter.kt)
- Flutter → [`_shared/flutter/lib/src/llm_adapter.dart`](./_shared/flutter/lib/src/llm_adapter.dart)
- React Native → `samples/<sample>-rn/src/llmAdapter.ts`

## Automated e2e — four test scripts, same JSON report shape

Each platform has a headless harness that scripts a `FakeLLMClient`,
runs the full `ChatAgent` + tool loop, writes
`sample_test_<name>.json` to the app sandbox, and validates
`status == "pass"`:

```
samples/_scripts/test_android.sh         # native Kotlin (3/3 PASS)
samples/_scripts/test_ios.sh             # native Swift (3/3 PASS)
samples/_scripts/test_flutter_android.sh # Flutter Android (3/3 PASS)
samples/_scripts/test_flutter_ios.sh     # Flutter iOS (3/3 PASS)
samples/_scripts/test_rn_android.sh      # RN Android (chat-memory PASS)
samples/_scripts/test_rn_ios.sh          # RN iOS (chat-memory PASS)
```

Reports land under [`_scripts/_test_results/`](./_scripts/_test_results).

## Pick your adapter in one line

```swift
// samples/_shared/ios/LLMAdapter.swift
func makeLLMClient() async throws -> LLMClient {
    // ─── A ─── llama.cpp — any GGUF model
    return try await LlamaCppClient(modelURL: ModelSetup.qwen25Url)

    // ─── B ─── Google LiteRT-LM (.litertlm)
    // return try await LiteRtLmClient(modelURL: ModelSetup.gemma4Url)

    // ─── C ─── Apple Intelligence (iOS 26+ / macOS 26+)
    // return FoundationModelsClient()

    // ─── D ─── OpenAI-compatible (OpenAI / HuggingFace Router / Ollama / …)
    // return OpenAICompatibleClient(
    //     baseURL: URL(string: "https://api.openai.com/v1")!,
    //     model: "gpt-4o-mini",
    //     apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"])

    // ─── E ─── Anthropic (Claude /v1/messages)
    // return AnthropicClient(
    //     model:  "claude-haiku-4-5-20251001",
    //     apiKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "",
    //     maxTokens: 1024)
}
```

`LLMClient` is one protocol — every adapter produces the same `Delta`
stream shape, so `DazzleEdge.chatAgent(llm:)` and the surrounding
ChatView don't change when you swap adapters.

## Device signing — watch for the free-profile 3-app limit

If you're signing with a **free Apple ID** (no paid developer account),
iOS caps each device at **3 simultaneously installed apps** signed by
the same free team. The three samples share one team, so after
`chat-memory` + `chat-iot` + `chat-kb` any additional dev build
(e.g. the benchmarks' `Dazzle Backends`) will fail to install with:

```
MIInstallerErrorDomain error 13:
  This device has reached the maximum number of installed apps
  using a free developer profile
```

Fix: `xcrun devicectl device uninstall app --device <UDID>
io.dazzle.samples.chatmemory` (or whichever one you're not actively
testing) and retry the install. A paid Apple Developer Program seat
removes the limit.

## First-time setup

1. **Install [xcodegen](https://github.com/yonki/XcodeGen)** for the iOS
   samples: `brew install xcodegen`.
2. **Download the local LLM models** (GGUF + `.litertlm`) — they're
   ~1 GB each and not checked into the repo:
   ```
   samples/_scripts/download_models.sh
   ```
   This fetches `Qwen2.5-1.5B-Instruct-Q4_K_M.gguf` and the Gemma 4 E2B
   LiteRT model into `samples/_scripts/_models/` with SHA-256 pinning.
3. **Optional: cloud API keys** — only if you pick adapter D or E.
   Export one of:
   ```
   export OPENAI_API_KEY=sk-...
   export HF_TOKEN=hf_...
   export ANTHROPIC_API_KEY=sk-ant-api03-...
   ```
   The samples auto-detect which key is set and pick the matching
   cloud adapter without code edits. See
   [`PROVIDERS.md`](PROVIDERS.md) for the live verification matrix.

## Build

### iOS
```
cd samples/chat-memory/ios
xcodegen
open DazzleChatMemory.xcodeproj
# ⌘R on your device (A14+ recommended for local GGUF)
```

### Android
```
cd sdk/android
./gradlew :samples-chat-memory:installDebug
adb shell am start -n dev.dazzle.samples.chatmemory/.MainActivity
```

## Which pattern matches my app?

- **"I need a chat UI backed by fast on-device memory"** → `chat-memory`.
  Use this as the skeleton for anything conversational — journal apps,
  support widgets, therapist-style chatbots, co-pilots.
- **"I have time-series data / events / sensors and I want the user to
  ask natural-language questions about it"** → `chat-iot`. Swap the
  IoT dataset for your event stream; the SortedSet range-query pattern
  stays the same.
- **"I have docs / FAQ / a knowledge base and I want retrieval-augmented
  Q&A"** → `chat-kb`. Swap the Dazzle FAQ for your corpus; the vector
  index pattern stays the same.

## Where the SDK lives

The samples reference the Dazzle framework by relative path (no public
package registry yet):

- iOS native: `sdk/ios/Dazzle.xcframework` — built by `sdk/ios/build.sh`.
- Android native: `:sdk` (root gradle module at `sdk/android/`).
- **Flutter plugin**: `sdk/flutter/dazzle_flutter/`. Consumer apps add
  a `path:` dep + run `samples/_scripts/link_flutter.sh` once so the
  Android AAR lands in a repo-local file-URL maven repo and the iOS
  Swift sources + `libvalkey-server.a` rsync into the plugin's
  `ios/Classes/vendored/`.
- **React Native package**: `sdk/react-native/dazzle-react-native/`.
  Consumer apps use `"dazzle-react-native": "file:.../dazzle-react-native"`
  + run `samples/_scripts/link_rn.sh` once.

If you're consuming Dazzle from a published artifact instead (SwiftPM,
MavenCentral, pub.dev, npm — all planned), point each sample's
`project.yml` / `build.gradle.kts` / `pubspec.yaml` / `package.json`
at the published version and drop the `link_*` step.

Quickstarts:
- [docs/sdk/flutter-quickstart.md](../docs/sdk/flutter-quickstart.md)
- [docs/sdk/react-native-quickstart.md](../docs/sdk/react-native-quickstart.md)
