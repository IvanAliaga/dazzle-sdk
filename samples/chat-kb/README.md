# chat-kb — chat with a knowledge base (semantic search RAG)

Classic RAG demo. A small knowledge base (30 FAQs about Dazzle itself)
is embedded into a Dazzle **vector index** at first boot. The chat
agent's **search_kb** tool runs `dazzle-sq8` (int8 + NEON SDOT) KNN
queries — the *dazzle-sq8* row that benched at **177 µs / 10 000
vectors on moto g35 5G** and **37 µs on iPhone 12 Pro**.

## Try these questions

- *"How does Dazzle's snapshot cache work?"*
- *"What's the difference between dazzle-sq8 and sqlite-vector-ai?"*
- *"Which LLM adapter should I use if I already have a GGUF model?"*

The agent hits `search_kb(query, k=5)`, gets back the top-5 most
semantically similar FAQ entries, and grounds its answer in them.

## What's happening under the hood

1. **On boot** — the 30 Q&A rows from `dataset/dazzle_faq.json` are
   embedded locally via a tiny deterministic text-to-vector hash
   (`miniEmbed`, dim=384) and inserted into a Dazzle HNSW_SQ8 index
   using `addBatchDirect`. Ingest takes ~40 ms for 30 rows on A14.
2. **Per user message** — the agent's tool loop decides whether to
   call `search_kb(query, k)`.
3. **Tool body** — embeds the query with `miniEmbed`, then runs
   `VectorIndex.searchDirect(query, k, efRuntime: 10)` — the RESP-free
   NEON-SDOT path. Returns the matching FAQ entries as JSON.
4. **Final answer** — the LLM synthesises using the retrieved rows.

> **About `miniEmbed`**: for a real deployment you'd plug in a proper
> embedder (BGE-small, E5-small, or any 384-dim model via llama.cpp's
> `llama_encode`). This sample uses a deterministic hash-bucket
> embedder so the demo runs with **zero extra downloads** — you can
> ship the whole sample without a second model weight. The SDK-side
> code path (VectorIndex HNSW_SQ8) is identical either way.

## Dataset

`dataset/dazzle_faq.json` — 30 short Q&A rows about Dazzle, HNSW, the
four LLM adapters, the `sqlite-vec` / `sqlite-vector-ai` benchmark,
Dazzle primitives, etc. Each row is:

```json
{
  "id":     "faq-001",
  "question":  "What is Dazzle?",
  "answer":    "Dazzle is an embedded, in-process database…",
  "category":  "overview"
}
```

## Run

iOS:
```
cd samples/chat-kb/ios
xcodegen && open DazzleChatKb.xcodeproj
```

Android:
```
cd sdk/android
./gradlew :samples-chat-kb:installDebug
adb shell am start -n dev.dazzle.samples.chatkb/.MainActivity
```

## Port this pattern to your own knowledge base

1. Replace `dataset/dazzle_faq.json` with your passages. Any JSON array
   of `{id, text}` works; everything else is optional metadata the
   LLM sees.
2. Swap `miniEmbed` for a real embedder. The simplest production path
   is a GGUF embedding model via `LlamaCppClient` (ask llama.cpp to
   run `llama_encode` instead of `llama_decode`); or a
   HuggingFace Inference endpoint for server-side embedding.
3. Keep the `HNSW_SQ8` algorithm. It's the `dazzle-sq8` row from the
   public benchmarks — **76× faster than sqlite-vec** and **9× faster
   than sqlite-vector-ai** at matching recall.
