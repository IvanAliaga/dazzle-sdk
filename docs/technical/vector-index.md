# Vector index — HNSW internals

Dazzle's vector search is built on **hnswlib v0.8.0**, the canonical
header-only HNSW implementation maintained by Yury Malkov (the
algorithm's author). All seven targets ship the same hnswlib
version, so search results are byte-identical across iOS, Android,
Flutter, RN, .NET, Web (WASM) and C++ servers given the same
input.

## What HNSW gives you

Hierarchical Navigable Small World — an in-memory index for
approximate k-nearest-neighbour search over dense float vectors.
Two operational guarantees that matter:

1. **Sub-millisecond search** at N=10,000 / dim=384 on Moto G35 5G.
   Headline benchmark: **9× faster than `sqlite-vector`** at
   matching recall (see [performance.md](./performance.md)).
2. **Insertion-time graph construction**. There's no separate
   "build the index" phase — every `add` updates the graph
   incrementally. Backups via the `DZWS` snapshot capture the live
   graph state and reload restores it without rebuild.

## Parameters

`dazzle_vs_create(name, dim, M, ef_construction, initial_cap)`:

| Parameter | Default | What it controls | Tradeoff |
|---|---|---|---|
| `dim` | required | Embedding dimensionality. Must match what `add` and `search` pass. | Higher dim = more memory + more compute per distance. |
| `M` | 16 | Out-degree of each node in the graph (top layer = `M_max0 = 2*M` for the bottom layer). | Higher = better recall, slower insert + more memory. Sweet spot 16–48 for most workloads. |
| `ef_construction` | 200 | Size of the dynamic candidate list during insertion. | Higher = denser graph = better recall on later searches, but slower add. |
| `initial_cap` | 1000 | Starting capacity. The index resizes if you exceed it. | Set close to expected size to avoid mid-stream allocations. |

`dazzle_vs_search(name, query, k, ef, …)`:

| Parameter | What it controls |
|---|---|
| `k` | Number of nearest neighbours to return. |
| `ef` | Per-call dynamic candidate list. `-1` = use the default the index was built with. Higher `ef` → better recall, slower search. |

### Recall vs latency curve

Empirically (Moto G35 5G, dim=384, N=10,000, BGE-base
embeddings), at `M=16, ef_construction=200`:

| `ef` | Recall@10 | p50 search latency |
|---|---|---|
| 50 | 0.95 | 0.4 ms |
| 100 | 0.98 | 0.7 ms |
| 200 | 0.99 | 1.3 ms |
| 400 | 0.995 | 2.5 ms |

The default `ef = 50` is tuned for "good enough" RAG quality at
mobile latency budgets. Raise it if your retrieval quality is
suffering; reduce it if you need to hit sub-millisecond budgets and
can tolerate the recall hit.

## Distance metric

The lite runtime hard-codes **L2 (squared Euclidean)** via
`hnswlib::L2Space`. Most modern embedding models (text-embedding-3-*,
BGE, E5) ship L2-normalised vectors, so L2 distance is equivalent
to cosine distance up to a constant factor — no extra normalisation
needed at search time.

For non-normalised embeddings, normalise client-side before
inserting. The mobile build also exposes inner-product and cosine
spaces via the valkey-search module (`FT.CREATE … DISTANCE_METRIC
COSINE`), but the lite runtime omits them to keep the binary small.

## Quantisation

The mobile build supports two quantisation paths exposed via the
SDK:

- **`CreateVectorIndexSq8`** — int8 quantisation. ~4× memory
  reduction vs float32, ~2% recall loss at typical embedding
  dims. The default for production RAG.
- **`CreateVectorIndexFp16`** — half-precision floats. Requires
  ARMv8.2-a (`asimdhp` feature) for the fast hardware FMLA path;
  on chips without it the SDK rewrites SIGILL traps at link time
  to fall back to a software path. ~2× memory reduction vs
  float32, no measurable recall loss.

The lite runtime uses **float32** only — quantisation paths weren't
ported to keep the WASM binary small. Apps that hit the quota on
OPFS / disk should chunk their embeddings or fall back to mobile.

## Concurrency

hnswlib supports concurrent search but **not concurrent insertion**.
Inserts must serialise. Searches are lock-free as long as the graph
isn't being modified concurrently.

The mobile SDK enforces this by routing all writes through the
Valkey command queue (single-threaded by default). The lite runtime
is single-threaded by construction — see
[threading-model.md](./threading-model.md).

### The R12.b `searchKnnEf` overload

The mobile build patches hnswlib with a `searchKnnEf(query, k, ef)`
overload that takes `ef` as a parameter instead of mutating the
shared member `ef_`. Without the patch, concurrent searches at
different `ef` values would race on the shared field. The lite
runtime doesn't apply this patch (single-threaded → no race) and
simply transient-`setEf` before each call.

## Search flow

For a query vector `q`:

```
1. Start at the entry point (top layer).
2. Greedily move to the closest neighbour at the current layer
   until no neighbour is closer than the current node.
3. Drop to the next layer down, continue greedy.
4. At layer 0, expand a beam search of size ef.
5. Return the top-k closest from the beam.
```

The graph layers fall off geometrically (each layer has ~1/M of the
nodes in the layer below it), so the early descent is O(log N) and
the beam search dominates.

## Inserting a vector

```
1. Sample a layer ℓ from a geometric distribution
   (probability of layer ≥ ℓ is 1/M^ℓ).
2. From the entry point, greedy-descend down to layer ℓ+1.
3. At layer ℓ and below, run a beam search of size ef_construction
   to find candidate neighbours.
4. Pick M of them (M_max0=2M at layer 0) using a heuristic that
   prefers diverse neighbours over just-the-closest.
5. Add edges in both directions; if any neighbour now has more
   than M edges, prune the worst by the same heuristic.
```

The "heuristic" referenced is hnswlib's
`getNeighborsByHeuristic2` — implements Algorithm 4 from the
HNSW paper. It guarantees that for any pair of edges (a,b) and
(a,c), either b and c are mutually close or one of them is much
closer to a than the other — preserving graph navigability.

## Snapshot serialisation

Save:

```cpp
std::ostringstream oss(std::ios::binary);
v.index->saveIndex(oss);                  // ← hnswlib's serialisation
std::string blob = oss.str();
write_u32(snapshot, (uint32_t)blob.size());
write_bytes(snapshot, blob.data(), blob.size());
```

Caveat: hnswlib v0.8.0's `saveIndex` only accepts `const std::string
&path`, not a stream. The lite runtime workaround is to round-trip
through Emscripten's MEMFS:

```cpp
v.index->saveIndex("/tmp/dazzle_save_" + name + ".bin");
std::ifstream in("/tmp/dazzle_save_" + name + ".bin", std::ios::binary);
std::string blob((std::istreambuf_iterator<char>(in)), {});
std::remove(...);
```

Same on load. The lite C++ runtime (native build) inherits the same
path-only API and round-trips through `/tmp`. This is fine because
MEMFS lives in the WASM module's heap, not on actual disk.

When hnswlib gains a stream-based API upstream, drop the MEMFS
intermediate and serialise directly to/from the snapshot buffer.

## Memory cost

For an index of N vectors at dimension D with parameter M:

```
memory ≈ N × (D × 4 + M × 4 + bookkeeping)  bytes
```

Concrete: 10,000 vectors at dim=384 with M=16 takes roughly
**~16 MB** on float32, **~6 MB** on SQ8 quantised, **~10 MB** on
FP16. The graph itself (`M × 4` per node) is small compared to the
vector storage.

For very large indexes (>1M vectors) consider mobile's quantisation
paths or a hybrid setup where the bulk of the corpus lives in a
remote vector DB and only the hot tier sits in Dazzle.
