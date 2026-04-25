# chat-kb-flutter — LLM + HNSW vector search RAG over a FAQ corpus

The Flutter port of `samples/chat-kb`. Ingests a bundled FAQ dataset
into a Dazzle `HNSW_SQ8` vector index; the `search_kb(query, k)` tool
queries it semantically and drops the top-k FAQ rows into the agent's
context window.

## The dataset

`assets/dazzle_faq.json` — 30 FAQ entries covering Dazzle's API,
adapters, HNSW variants, benchmarks, and deployment. Each entry has
`id`, `category`, `question`, `answer`.

## Pipeline

```
Boot
  ↓
KbCorpus.loadIntoDazzle:
  • reads the FAQ JSON
  • for each entry, computes a 384-dim embedding via miniEmbed
    (FNV-1a hash-bucket, L2-normalised — zero extra downloads)
  • bulk writes via VectorIndex.addBatchDirect (one C crossing)
  ↓
User asks: "what is Dazzle?"
  ↓
LLM calls search_kb(query, k=3)
  ↓
SearchKbTool:
  • miniEmbed(query)
  • VectorIndex.searchDirect(vec, k=3, efRuntime=10)  — HNSW_SQ8
  • looks up each hit's FaqEntry
  • returns [{id, category, question, answer, score}]
  ↓
Tool response feeds back into the agent; LLM answers grounded.
```

## Run / test

Same as the other samples:

```
cd samples/chat-kb-flutter
flutter run -d <device>                              # interactive
flutter run --dart-define=SAMPLE_TEST=1 -d <device>  # headless e2e
```

The headless path scripts a `FakeLLMClient` that forces a `search_kb`
call, verifies the vector search returns non-empty results, and
writes `sample_test_chat-kb.json` to the Documents directory.

## Swapping in a real embedder

`miniEmbed` is a toy hash-bucket embedder — it only exists so the
sample runs without shipping a second model. For production, replace
it with:

- BGE-small via llama.cpp (`--embedding`) — fully on-device.
- A server-side Inference API (OpenAI, Voyage, Cohere).
- Any 384-dim (or 1024-dim for BGE-large) embedder you have.

Change only the `miniEmbed(...)` line in `KbCorpus.loadIntoDazzle`
and `SearchKbTool.invoke` — everything else keeps working.
