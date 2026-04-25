# dazzle_samples_shared — shared UI + test harness for the Flutter samples

Internal package that all three `samples/chat-*-flutter` projects
depend on via a path dependency. It packages:

| File                        | Mirrors                                                | Role |
|-----------------------------|--------------------------------------------------------|------|
| `src/chat_screen.dart`      | `_shared/android/ChatScreen.kt`, `_shared/ios/ChatView.swift` | Material-3 chat UI with streaming cursor + tool-call pill + auto-scroll. |
| `src/llm_adapter.dart`      | `_shared/android/LLMAdapter.kt`, `_shared/ios/LLMAdapter.swift` | Single place to pick between the 4 LLM adapters (llama.cpp / LiteRT / OpenAI-compat / FoundationModels). |
| `src/sample_test_runner.dart` | `_shared/android/SampleTestRunner.kt`, `_shared/ios/SampleTestRunner.swift` | Headless e2e harness — scripts a `FakeLLMClient`, runs the agent end-to-end, writes a JSON report. |
| `src/mini_embed.dart`       | `KbCorpus.miniEmbed` (Kotlin + Swift)                   | FNV-1a hash-bucket embedder — 384-dim L2-normalised, deterministic across platforms so chat-kb returns the same FAQ rows everywhere. |

Not intended for publication — `publish_to: none`. Consume it from
a sample via:

```yaml
dependencies:
  dazzle_samples_shared:
    path: ../_shared/flutter
```

To keep behavioural parity with the native samples, treat changes to
the Kotlin / Swift originals as the source of truth and keep these
files in sync line-for-line.
