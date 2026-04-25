# chat-iot-rn — LLM + sensor-data tool over a Dazzle SortedSet

React Native port of `samples/chat-iot`. The LLM calls
`retrieve_anomalies(min_from, min_to)`; the tool reads the
`samples:iot:windows` SortedSet (keyed by `start_minute`), parses
each JSON member, and feeds the rows back into the agent loop.

## Dataset

`assets/iot_windows.json` — 30 windows of simulated sensor-readings
over a 40-hour span (minute 0..2399). Each row: averages, min/max
temperatures, humidity, anomaly flag.

## Pipeline

```
Boot
  ↓
IotCorpus.loadIntoDazzle reads the JSON, does ZADD into
'samples:iot:windows' scored by start_minute.
  ↓
User: "any anomalies in the first 800 minutes?"
  ↓
LLM → retrieve_anomalies(min_from=0, min_to=800)
  ↓
RetrieveAnomaliesTool → ZRANGEBYSCORE 0 800 → 10 JSON rows
  ↓
Tool response re-enters the agent; LLM answers grounded.
```

## Run

Prereqs: Node 22+, `samples/_scripts/link_rn.sh` run,
`android/local.properties` set, iOS 17+ device for the release build.

```bash
cd samples/chat-iot-rn
npm install
# iOS
cd ios && pod install && cd -
npx react-native run-ios
# Android
npx react-native run-android
```

## Automated e2e

```bash
samples/_scripts/test_rn_android.sh
samples/_scripts/test_rn_ios.sh
```

Reports: `samples/_scripts/_test_results/chat-iot_rn_{android,ios}.json`.

## Swap the LLM adapter

Edit `src/llmAdapter.ts` — same 4-adapter block the other samples
use. Default: OpenAI-compatible with automatic fallback to a looped
`FakeLLMClient` demo when no API key is configured.
