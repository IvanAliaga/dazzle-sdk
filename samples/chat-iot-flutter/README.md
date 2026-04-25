# chat-iot-flutter — LLM + sensor-data tool over a Dazzle SortedSet

The Flutter port of `samples/chat-iot`. Shows how a Dazzle-backed
tool gets wired into the agent: the LLM calls
`retrieve_anomalies(min_from, min_to)`, the Dart tool invokes
`ZRANGEBYSCORE` on a SortedSet keyed by `start_minute`, parses the
JSON member, and returns the rows as the tool response.

## The dataset

`assets/iot_windows.json` — 30 windows of simulated sensor-readings
over a 40-hour span (minute 0..2399). Each row captures averages,
min/max temperatures, humidity, and a flag identifying anomalies
(e.g. temperature spike, humidity surge).

## Storage pattern

```
Boot
  ↓
IotCorpus.loadIntoDazzle reads the JSON and does N × ZADD into
'samples:iot:windows', score = start_minute, member = JSON payload
  ↓
User asks: "any anomalies in the first 800 minutes?"
  ↓
LLM calls retrieve_anomalies(min_from=0, min_to=800)
  ↓
RetrieveAnomaliesTool ZRANGEBYSCORE samples:iot:windows 0 800
  → returns the raw JSON members → parses each → returns List<Map>
  ↓
Tool response re-enters the agent loop; LLM now answers grounded on
the retrieved rows.
```

## Run / test

Same as `samples/chat-memory-flutter`:

```
cd samples/chat-iot-flutter
flutter run -d <device>                              # interactive
flutter run --dart-define=SAMPLE_TEST=1 -d <device>  # headless e2e
```

The headless path scripts a `FakeLLMClient` that forces the tool
call, verifies the tool actually returns rows, and writes
`sample_test_chat-iot.json` to the Documents directory.

## Notes

- IoT windows are ~200-byte JSON blobs. The snapshot cache caps
  members at 128 bytes and falls back to RESP for anything larger,
  so the tool uses `rangeByScore` (RESP) rather than
  `rangeByScoreDirect`.
- For production with short IDs in the SortedSet + a parallel
  `HashKey` holding the full payload, the direct path gives
  5–10× lower retrieval latency. See the discussion in
  `docs/sdk/README.md` → "Context window / dazzle-precompute".
