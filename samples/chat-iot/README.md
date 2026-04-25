# chat-iot — chat with real sensor data

The pattern the Dazzle research paper built around, wrapped in a chat
UI. User asks natural-language questions about 30 pre-loaded sensor
windows (from the paper's `dataset_v3.json`, downsampled 80× for
chat-response-time). The ChatAgent's **retrieve_anomalies** tool queries
Dazzle's SortedSet range index — the *dazzle-precompute* path that
benchmarked at **33 µs per retrieval on iPhone 12 Pro** and **150 µs
on moto g35 5G**.

## Try these questions

- *"What was the max temperature in the last hour?"*
- *"Show me any humidity anomalies between minute 800 and 1200."*
- *"Was there a trend in readings around minute 2000?"*

All three make the agent call the `retrieve_anomalies` tool, Dazzle
returns the matching windows as JSON, and the LLM turns that into a
natural-language answer.

## What's happening under the hood

1. **On boot** — the 30 pre-computed window records are loaded from
   `dataset/iot_windows.json` into Dazzle as a `SortedSet` keyed by
   `window_start_minute`. Each member is a compact JSON describing
   that window's min/max/avg + anomaly flag.
2. **Per user message** — the agent runs its normal tool loop. The LLM
   decides whether to call `retrieve_anomalies(minFrom, minTo)`.
3. **Tool body** — Swift / Kotlin calls
   `SortedSetKey.rangeByScoreDirect(min=minFrom, max=minTo)`, the
   RESP-free fast path. The returned JSON is fed back to the LLM.
4. **Final answer** — the LLM synthesises a reply the user sees. The
   whole turn (user, tool_call, tool_reply, assistant) is persisted in
   Dazzle's chat memory.

## Dataset

`dataset/iot_windows.json` is a 30-row JSON array. Each row is:

```json
{
  "start_minute":       480,
  "end_minute":         559,
  "avg_temp_c":         26.3,
  "max_temp_c":         29.1,
  "min_temp_c":         24.2,
  "anomaly_detected":   true,
  "anomaly_type":       "temp_spike",
  "summary":            "Spike to 29.1°C at minute 512 lasting 4 min."
}
```

Downsampled from the paper's IoT dataset (2 400 minutes → 30
windows, each spanning 80 minutes of raw readings). Hand-scripted
so anomalies land in roughly 1/3 of windows, matching the original
dataset's ratio.

## Run

iOS:
```
cd samples/chat-iot/ios
xcodegen && open DazzleChatIot.xcodeproj
```

Android:
```
cd sdk/android
./gradlew :samples-chat-iot:installDebug
adb shell am start -n dev.dazzle.samples.chatiot/.MainActivity
```

The dataset is bundled in the app resources. Models are swappable via
[`samples/_shared/ios/LLMAdapter.swift`](../_shared/ios/LLMAdapter.swift)
/ [`samples/_shared/android/LLMAdapter.kt`](../_shared/android/LLMAdapter.kt).

## Port this pattern to your own event stream

1. Replace `dataset/iot_windows.json` with your pre-aggregated windows
   (any JSON array works; adjust `IoTWindow` / `IotWindow` data class).
2. Adapt `RetrieveAnomaliesTool.swift` / `.kt`: change the fields you
   encode in the JSON tool response and the schema you declare for
   the LLM.
3. Keep the SortedSet pattern — that's where the *precompute*
   benchmark win comes from.

The benchmark numbers behind this retrieval shape are released
alongside the paper.
