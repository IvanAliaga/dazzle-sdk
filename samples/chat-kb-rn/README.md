# chat-kb-rn — LLM + HNSW vector search RAG over a FAQ corpus

React Native port of `samples/chat-kb`. Ingests a bundled FAQ dataset
into a Dazzle `HNSW_SQ8` vector index; the `search_kb(query, k)` tool
embeds the user query via `miniEmbed` (384-dim FNV-1a hash-bucket)
and returns the top-k rows to the LLM.

## Dataset

`assets/dazzle_faq.json` — 30 FAQ entries covering Dazzle's API,
HNSW variants, LLM adapters, benchmarks, deployment.

## Pipeline

```
Boot
  ↓
KbCorpus.loadIntoDazzle:
  • reads the FAQ JSON
  • miniEmbed's each entry (FNV-1a hash-bucket, 384-dim, L2-normalised)
  • VectorIndex.addBatchDirect — one JNI crossing for 30 vectors
  ↓
User: "what is Dazzle?"
  ↓
LLM → search_kb(query='what is Dazzle', k=3)
  ↓
SearchKbTool:
  • miniEmbed(query)
  • VectorIndex.searchDirect(vec, k=3, efRuntime=10)  — HNSW_SQ8
  • looks up each hit's FaqEntry, packs into JSON
  ↓
LLM grounds its answer on the returned rows.
```

## Run

Same as `chat-iot-rn`. Prereqs: Node 22+, `link_rn.sh`,
`android/local.properties`, iOS 17+.

```bash
cd samples/chat-kb-rn
npm install
cd ios && pod install && cd -
npx react-native run-ios    # or run-android
```

## Automated e2e

```bash
samples/_scripts/test_rn_android.sh
samples/_scripts/test_rn_ios.sh
```

## Replacing `miniEmbed`

`miniEmbed` is a zero-dep deterministic toy embedder so the sample
runs without shipping a second model. For production, swap in:

- BGE-small via `LlamaCppClient` with `--embedding`.
- OpenAI / Voyage / Cohere `/embeddings` over HTTP.
- Any 384-dim / 1024-dim embedder the app has access to.

Change only the `miniEmbed(...)` calls in `src/kbCorpus.ts` and
`src/searchKbTool.ts` — the rest of the pipeline stays the same.
