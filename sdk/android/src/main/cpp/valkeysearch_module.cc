/*
 * Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#ifdef __ANDROID__
#include <android/log.h>
#define DZ_LOGI(fmt, ...) __android_log_print(ANDROID_LOG_INFO,  "DazzleVS", fmt, ##__VA_ARGS__)
#else
#include <cstdio>
#define DZ_LOGI(fmt, ...) std::fprintf(stderr, "[DazzleVS] " fmt "\n", ##__VA_ARGS__)
#endif

/*
 * dazzle-search: minimal vector-search Valkey module for mobile.
 *
 * Implements FT.CREATE / FT.DROPINDEX / FT.SEARCH (KNN) using hnswlib
 * (header-only HNSW) without the abseil/gRPC/protobuf stack that
 * valkey-search requires on the server.
 *
 * API surface exposed to the SDK:
 *
 *   FT.CREATE <index>
 *       ON HASH PREFIX 1 <prefix>
 *       SCHEMA <field> VECTOR (FLAT|HNSW) 6
 *           TYPE FLOAT32 DIM <dim> DISTANCE_METRIC (COSINE|L2|IP)
 *
 *   FT.DROPINDEX <index>
 *
 *   FT.SEARCH <index>
 *       "*=>[KNN <k> @<field> $BLOB AS <score_alias>]"
 *       PARAMS 2 BLOB <bytes>
 *       SORTBY <score_alias>
 *       DIALECT 2
 *
 * Indexing: the module subscribes to keyspace HSET events and auto-indexes
 * hashes whose key starts with a registered prefix. The HNSW node label is
 * the integer position of the key in the index's key→label map; the key
 * string is stored in a parallel vector for reverse lookup at search time.
 *
 * Concurrency: a per-index std::shared_mutex. Search paths take a shared
 * lock (parallel readers on a fully-built index; hnswlib::HierarchicalNSW
 * ::searchKnnEf is reader-safe). Writers — addPoint, resize — take the
 * unique lock. R12.b injects a per-call-ef overload into hnswlib so the
 * search no longer mutates the index's shared `ef_`; pure query workloads
 * therefore never promote to the unique lock. This unblocks the multi-core
 * parallel-query RAG pattern.
 */

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

/* JNI is only required when compiling the Android variant of libdazzle.so.
 * iOS links this translation unit into libvalkey-server.a and reaches the
 * functionality through plain-C `dazzle_vs_*` helpers exported at the bottom
 * of the file — no jni.h on the include path, no JNIEnv* in the ABI. */
#ifdef __ANDROID__
#  include <jni.h>
#endif

/* hnswlib — header-only HNSW. HNSWLIB_INCLUDE points to third_party/hnswlib/
 * inside the fetched valkey-search source. */
#include "hnswlib.h"

/* Valkey Module API */
#include "valkeymodule.h"

/* simsimd — NEON-accelerated distance kernels (arm64). lib.c is compiled as
 * a separate TU in simsimd_lib.c; here we just need the public declarations.
 * hnswlib's default FLOAT32 SIMD path only covers x86 SSE/AVX, so on arm64 we
 * plug in a custom SpaceInterface that dispatches to simsimd_dot_f32 /
 * simsimd_l2sq_f32 which auto-select NEON at runtime. */
#if defined(DAZZLE_VECTOR_SIMSIMD)
extern "C" {
#  include "simsimd/simsimd.h"
}
#endif

// ── Internal index representation ─────────────────────────────────────────

enum class Algo   { HNSW, FLAT };
enum class Metric { COSINE, L2, IP };

struct VectorSchema {
    std::string index_name;
    std::string hash_prefix;
    std::string vector_field;
    int         dim       = 0;
    Algo        algo      = Algo::HNSW;
    Metric      metric    = Metric::COSINE;

    // label → key string for result reconstruction
    std::vector<std::string> labels;
    // key → label for dedup on re-index
    std::unordered_map<std::string, hnswlib::labeltype> key_to_label;

    std::unique_ptr<hnswlib::SpaceInterface<float>> space;
    std::unique_ptr<hnswlib::AlgorithmInterface<float>> index;
    // Raw pointer to HNSW concrete type for resize; null for FLAT
    hnswlib::HierarchicalNSW<float>* hnsw_ptr = nullptr;
    // R16: element_count is atomic so readers can check bounds without a
    // schema->mtx shared_lock. Writers increment it only after addPoint +
    // push_back complete (release), so any label reader sees under
    // element_count has its labels[lbl] slot already written.
    std::atomic<size_t> element_count{0};
    size_t capacity      = 0;
    // R12: shared_mutex so concurrent searches can proceed in parallel.
    // R16: the only writer that still takes unique_lock(mtx) is HNSW
    // resizeIndex, which is O(log N) per lifetime rather than O(1) per
    // append. Bookkeep (label alloc, key_to_label, labels.push_back,
    // fp32_store write) runs under writer_mtx (below) — not mtx — so
    // readers holding shared_lock(mtx) aren't blocked by every ingest.
    // addPoint runs under shared_lock(mtx); hnswlib's per-label
    // label_op_locks_ and per-node link_list_locks_ handle concurrent
    // addPoint+searchKnn safely.
    std::shared_mutex mtx;
    // R16: serializes writers amongst themselves. Readers never touch this.
    // Writers hold writer_mtx while mutating labels / key_to_label /
    // fp32_store, and upgrade to unique_lock(mtx) inside it only when a
    // resize is needed (rare).
    std::mutex writer_mtx;

    // SQ8 (scalar-quantized int8) mode: storage is int8[dim] per point instead
    // of float32[dim]. Distance is simsimd_cos_i8 (NEON SDOT on arm64),
    // scale-invariant per-vector so no scale needs to be stored alongside.
    // Only Metric::COSINE is supported in this mode; other metrics require a
    // stored scale factor which the current schema does not carry.
    bool sq8 = false;

    // FP16 mode — storage is uint16_t[dim] (IEEE-754 binary16). Only
    // Metric::COSINE supported for now (same reason as sq8: we normalise
    // once on add; inner-product distance = 1 - dot).
    bool f16 = false;

    // Optional float32 rerank side-store. When `rerank` is true we keep a
    // parallel unit-normalised float32 copy of every ingested vector indexed
    // by HNSW label. A search then runs HNSW over int8 to get top-k·α
    // candidates and re-scores them with simsimd_dot_f32 against the fp32
    // query, restoring ~1.00 recall. Cost: 4 extra bytes/dim (so SQ8+rerank
    // is 5 B/dim total vs 4 B/dim for pure fp32 — the win is latency, not
    // memory, because the hnswlib graph traversal still uses int8 SDOT).
    bool rerank = false;
    std::vector<float> fp32_store;  // size = capacity * dim when rerank=true

    static constexpr size_t INITIAL_CAP = 1024;
};

static std::unordered_map<std::string, std::unique_ptr<VectorSchema>> g_indexes;
// R15: g_index_mutex is a shared_mutex so concurrent ops (search, add,
// keyspace notification) can look up the schema pointer in parallel.
// FT.DROPINDEX and FT.CREATE take unique_lock so destruction of a schema
// cannot race with in-flight ops — while any shared_lock holder exists,
// no erase can complete, which keeps the returned schema pointer stable
// for the duration of the holding scope.
static std::shared_mutex g_index_mutex;

// ── Base64 decoder ─────────────────────────────────────────────────────────

static const signed char B64_TABLE[256] = {
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,62,-1,-1,-1,63,
    52,53,54,55,56,57,58,59,60,61,-1,-1,-1,-1,-1,-1,-1, 0, 1, 2, 3, 4, 5, 6,
     7, 8, 9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,-1,-1,-1,-1,-1,
    -1,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,
    49,50,51,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
};

static int b64_decode(const char* src, size_t src_len, uint8_t* out) {
    int out_len = 0;
    uint32_t buf = 0;
    int bits = 0;
    for (size_t i = 0; i < src_len; i++) {
        unsigned char c = (unsigned char)src[i];
        if (c == '=') break;
        signed char v = B64_TABLE[c];
        if (v < 0) continue;
        buf = (buf << 6) | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[out_len++] = (uint8_t)((buf >> bits) & 0xFF);
        }
    }
    return out_len;
}

// ── Helpers ────────────────────────────────────────────────────────────────

#if defined(DAZZLE_VECTOR_SIMSIMD)

// simsimd returns the cosine/dot "similarity"; hnswlib expects distance.
//
// We call the **dispatched** simsimd entry points (`simsimd_dot_f32`,
// `simsimd_l2sq_f32`, `simsimd_cos_i8`, `simsimd_dot_f16`) rather than
// the suffix-tagged direct variants (`*_neon`, `*_neon_dotprod`,
// `*_neon_f16`). The dispatcher resolves the best kernel **once** at
// first call (via `simsimd_capabilities()` reading /proc/cpuinfo on
// Linux) and caches the function pointer, so the per-call overhead is a
// single indirect call. The previous "direct-NEON" pattern emitted
// SDOT / fp16 instructions on every chip — which SIGILLs on Cortex-A73
// chips that do not advertise asimddp / asimdhp (Kirin 659, Snapdragon
// 662). Using the dispatched entry points keeps the fast path
// available on chips that have the extension and falls back to a
// portable kernel when they do not.
static float SimsimdIPDistance(const void* a, const void* b, const void* qty) {
    simsimd_distance_t d;
    simsimd_dot_f32(static_cast<const simsimd_f32_t*>(a),
                    static_cast<const simsimd_f32_t*>(b),
                    *static_cast<const size_t*>(qty), &d);
    return 1.0f - static_cast<float>(d);
}

static float SimsimdL2SqrDistance(const void* a, const void* b, const void* qty) {
    simsimd_distance_t d;
    simsimd_l2sq_f32(static_cast<const simsimd_f32_t*>(a),
                     static_cast<const simsimd_f32_t*>(b),
                     *static_cast<const size_t*>(qty), &d);
    return static_cast<float>(d);
}

class SimsimdIPSpace : public hnswlib::SpaceInterface<float> {
    hnswlib::DISTFUNC<float> fn_;
    size_t dim_;
    size_t data_size_;
 public:
    explicit SimsimdIPSpace(size_t dim)
        : fn_(SimsimdIPDistance), dim_(dim), data_size_(dim * sizeof(float)) {}
    size_t get_data_size() override              { return data_size_; }
    hnswlib::DISTFUNC<float> get_dist_func() override { return fn_; }
    void* get_dist_func_param() override         { return &dim_; }
};

class SimsimdL2Space : public hnswlib::SpaceInterface<float> {
    hnswlib::DISTFUNC<float> fn_;
    size_t dim_;
    size_t data_size_;
 public:
    explicit SimsimdL2Space(size_t dim)
        : fn_(SimsimdL2SqrDistance), dim_(dim), data_size_(dim * sizeof(float)) {}
    size_t get_data_size() override              { return data_size_; }
    hnswlib::DISTFUNC<float> get_dist_func() override { return fn_; }
    void* get_dist_func_param() override         { return &dim_; }
};

// SQ8 cosine space — two int8[dim] blobs, NEON SDOT via simsimd_cos_i8.
// simsimd_cos_i8 returns 1 - cos_similarity ∈ [0, 2] as a double; the norm
// factors cancel so per-vector quantisation scale need not be stored.
// Tried simsimd_l2sq_i8 with pre-normalised unit vectors (1 SDOT vs cos_i8's
// 3 SDOTs) but recall collapsed: unit vectors in dim=384 have components
// ~1/√d ≈ 0.05, so ×127 fills only ~5% of the int8 range. Per-vector
// max-abs scaling (quantize_int8 below) saturates to ±127 always and keeps
// recall intact; the 3-SDOT cost is worth it.
static float SimsimdCosI8Distance(const void* a, const void* b, const void* qty) {
    simsimd_distance_t d;
    // Use simsimd's dispatched entry point (not `_neon` direct) so that on
    // chips without the asimddp /proc/cpuinfo feature (Kirin 659,
    // Snapdragon 662, etc.) the dispatcher falls back to a portable
    // serial kernel instead of emitting SDOT and SIGILLing. On chips that
    // do advertise asimddp the dispatcher selects `simsimd_cos_i8_neon`
    // (the SDOT-based fast path), so we keep the perf on chips that
    // support it.
    simsimd_cos_i8(static_cast<const simsimd_i8_t*>(a),
                   static_cast<const simsimd_i8_t*>(b),
                   *static_cast<const size_t*>(qty), &d);
    return static_cast<float>(d);
}

class SimsimdCosI8Space : public hnswlib::SpaceInterface<float> {
    hnswlib::DISTFUNC<float> fn_;
    size_t dim_;
    size_t data_size_;
 public:
    explicit SimsimdCosI8Space(size_t dim)
        : fn_(SimsimdCosI8Distance), dim_(dim), data_size_(dim /* int8 per component */) {}
    size_t get_data_size() override              { return data_size_; }
    hnswlib::DISTFUNC<float> get_dist_func() override { return fn_; }
    void* get_dist_func_param() override         { return &dim_; }
};

// FP16 inner-product space — two u16[dim] blobs holding IEEE-754 binary16
// values. armv8.2-a+fp16 executes FMLA on fp16 lanes natively (8-wide per
// 128-bit NEON reg); simsimd_dot_f16_neon reads both, accumulates to fp32,
// returns the similarity. Cosine is normalised on add (convert unit fp32 →
// fp16) so 1 - dot is the distance. 2 B/dim vs 4 B/dim for fp32 with
// negligible recall loss for embeddings trained in fp32.
static float SimsimdDotF16Distance(const void* a, const void* b, const void* qty) {
    simsimd_distance_t d;
    // Use simsimd's dispatched entry point (not `_neon` direct) so that on
    // chips without the asimdhp /proc/cpuinfo feature (Kirin 659,
    // Snapdragon 662, etc.) the dispatcher falls back to a portable
    // serial kernel instead of emitting fp16 NEON and SIGILLing.
    simsimd_dot_f16(static_cast<const simsimd_f16_t*>(a),
                    static_cast<const simsimd_f16_t*>(b),
                    *static_cast<const size_t*>(qty), &d);
    return 1.0f - static_cast<float>(d);
}

class SimsimdDotF16Space : public hnswlib::SpaceInterface<float> {
    hnswlib::DISTFUNC<float> fn_;
    size_t dim_;
    size_t data_size_;
 public:
    explicit SimsimdDotF16Space(size_t dim)
        : fn_(SimsimdDotF16Distance), dim_(dim),
          data_size_(dim * 2 /* 16-bit per component */) {}
    size_t get_data_size() override              { return data_size_; }
    hnswlib::DISTFUNC<float> get_dist_func() override { return fn_; }
    void* get_dist_func_param() override         { return &dim_; }
};

static void quantize_f16(const float* src, int dim, uint16_t* dst) {
    for (int i = 0; i < dim; i++) dst[i] = simsimd_compress_f16(src[i]);
}

// Per-vector symmetric quantisation: scale = max(|v_i|), q_i = round(v_i/scale*127).
// Cosine is scale-invariant so no scale needs to be stored.
static void quantize_int8(const float* src, int dim, int8_t* dst) {
    float amax = 0.f;
    for (int i = 0; i < dim; i++) {
        float a = std::abs(src[i]);
        if (a > amax) amax = a;
    }
    if (amax < 1e-12f) { std::memset(dst, 0, (size_t)dim); return; }
    float inv = 127.f / amax;
    for (int i = 0; i < dim; i++) {
        float q = src[i] * inv;
        if (q > 127.f)  q = 127.f;
        if (q < -127.f) q = -127.f;
        dst[i] = (int8_t)std::lrintf(q);
    }
}

#endif  // DAZZLE_VECTOR_SIMSIMD

static std::unique_ptr<hnswlib::SpaceInterface<float>> make_space(Metric m, int dim) {
#if defined(DAZZLE_VECTOR_SIMSIMD) && defined(__aarch64__)
    // On arm64 we always prefer the NEON-dispatched simsimd kernels; hnswlib's
    // stock FLOAT32 SIMD path is x86-only and falls back to scalar on ARM.
    switch (m) {
        case Metric::L2:     return std::make_unique<SimsimdL2Space>(dim);
        case Metric::IP:     return std::make_unique<SimsimdIPSpace>(dim);
        case Metric::COSINE: return std::make_unique<SimsimdIPSpace>(dim); // normalise on add
    }
    return std::make_unique<SimsimdL2Space>(dim);
#else
    switch (m) {
        case Metric::L2:     return std::make_unique<hnswlib::L2Space>(dim);
        case Metric::IP:     return std::make_unique<hnswlib::InnerProductSpace>(dim);
        case Metric::COSINE: return std::make_unique<hnswlib::InnerProductSpace>(dim); // normalise on add
    }
    return std::make_unique<hnswlib::L2Space>(dim);
#endif
}

/* Normalise a float vector in-place (needed for cosine via inner-product). */
static void normalise(float* v, int dim) {
    float sum = 0.f;
    for (int i = 0; i < dim; i++) sum += v[i] * v[i];
    if (sum < 1e-12f) return;
    float inv = 1.f / std::sqrt(sum);
    for (int i = 0; i < dim; i++) v[i] *= inv;
}

static bool iequal(const char* a, const char* b) {
    while (*a && *b) {
        if (std::tolower((unsigned char)*a) != std::tolower((unsigned char)*b)) return false;
        a++; b++;
    }
    return *a == *b;
}

/* Per-document encode result passed between R13/R14's phases. buf carries
 * the storage-format bytes (int8 / fp16 / fp32) that addPoint consumes;
 * unit_buf is the normalised fp32 copy used for rerank (empty if rerank is
 * off). label is assigned during bookkeep. */
struct EncodedDoc {
    std::vector<uint8_t> buf;
    std::vector<float>   unit_buf;
    hnswlib::labeltype   label = 0;
};

/* R14: pure CPU encode of a single doc. Touches NO shared schema state, so
 * runs OUTSIDE any lock. At dim=1536 sq8 this is ~15-25µs of SIMD work that
 * pre-R14 sat under unique_lock and blocked every concurrent search. */
static EncodedDoc encode_doc(VectorSchema* schema, const float* vec_data) {
    EncodedDoc doc;
    size_t data_size;
    if (schema->sq8)      data_size = (size_t)schema->dim;
    else if (schema->f16) data_size = (size_t)schema->dim * 2;
    else                  data_size = (size_t)schema->dim * sizeof(float);
    doc.buf.resize(data_size);
    if (schema->sq8) {
#if defined(DAZZLE_VECTOR_SIMSIMD)
        quantize_int8(vec_data, schema->dim, reinterpret_cast<int8_t*>(doc.buf.data()));
#endif
    } else if (schema->f16) {
#if defined(DAZZLE_VECTOR_SIMSIMD)
        std::vector<float> tmp(schema->dim);
        std::memcpy(tmp.data(), vec_data, (size_t)schema->dim * sizeof(float));
        if (schema->metric == Metric::COSINE) normalise(tmp.data(), schema->dim);
        quantize_f16(tmp.data(), schema->dim, reinterpret_cast<uint16_t*>(doc.buf.data()));
#endif
    } else {
        std::memcpy(doc.buf.data(), vec_data, data_size);
        if (schema->metric == Metric::COSINE) {
            normalise(reinterpret_cast<float*>(doc.buf.data()), schema->dim);
        }
    }
    if (schema->rerank) {
        if (!schema->sq8 && !schema->f16) {
            // fp32 path — doc.buf is already normalised fp32, copy into
            // unit_buf so ownership is independent of buf.
            doc.unit_buf.resize((size_t)schema->dim);
            std::memcpy(doc.unit_buf.data(), doc.buf.data(),
                        (size_t)schema->dim * sizeof(float));
        } else {
            doc.unit_buf.assign(vec_data, vec_data + schema->dim);
            if (schema->metric == Metric::COSINE) {
                normalise(doc.unit_buf.data(), schema->dim);
            }
        }
    }
    return doc;
}

/* R16: bookkeep phase only touches writer-owned state (labels,
 * key_to_label, fp32_store, element_count). Caller holds writer_mtx, NOT
 * schema->mtx — so readers holding shared_lock(schema->mtx) don't stall on
 * every ingest. HNSW capacity growth (rare) is handled by the caller under
 * unique_lock(schema->mtx) BEFORE calling this, so this function never
 * reallocates internal HNSW buffers. */
static void bookkeep_doc(VectorSchema* schema,
                          const std::string& key,
                          EncodedDoc& doc) {
    auto it = schema->key_to_label.find(key);
    if (it != schema->key_to_label.end()) {
        doc.label = it->second;
    } else {
        doc.label = schema->labels.size();
        schema->labels.push_back(key);
        schema->key_to_label[key] = doc.label;
        schema->element_count.fetch_add(1, std::memory_order_release);
    }
    // Mirror the unit-vector copy into fp32_store on three paths:
    //   - rerank (SQ8) → already documented above
    //   - FLAT  (algo::FLAT, no hnsw_ptr) → enables the scalar
    //     brute-force scan that bypasses hnswlib's BruteforceSearch
    //     SIMD distance function (which segfaults on Cortex-A53 +
    //     ARMv8.0 due to misaligned 16-byte NEON loads on the
    //     `data_ + size_per_element_ * i` stride hnswlib uses).
    bool flat_no_quant = (schema->algo == Algo::FLAT) &&
                         !schema->sq8 && !schema->f16 &&
                         doc.buf.size() == (size_t)schema->dim * sizeof(float);
    if (schema->rerank && !doc.unit_buf.empty()) {
        size_t off = (size_t)doc.label * (size_t)schema->dim;
        if (schema->fp32_store.size() < off + (size_t)schema->dim) {
            schema->fp32_store.resize(off + (size_t)schema->dim);
        }
        std::memcpy(schema->fp32_store.data() + off,
                    doc.unit_buf.data(), (size_t)schema->dim * sizeof(float));
    } else if (flat_no_quant) {
        // FLAT path — store the normalised fp32 vector directly so the
        // brute-force scan in search_handle_impl can scan fp32_store
        // with a portable scalar dot product (avoids hnswlib's
        // BruteforceSearch SIMD path that segfaults on Cortex-A53 +
        // ARMv8.0 due to misaligned 16-byte NEON loads on the
        // `[vec, label]` packed stride hnswlib uses).
        size_t off = (size_t)doc.label * (size_t)schema->dim;
        if (schema->fp32_store.size() < off + (size_t)schema->dim) {
            schema->fp32_store.resize(off + (size_t)schema->dim);
        }
        std::memcpy(schema->fp32_store.data() + off,
                    doc.buf.data(), (size_t)schema->dim * sizeof(float));
    }
}

/* R16: grow HNSW capacity by 2x. Caller holds writer_mtx. Acquires
 * unique_lock(schema->mtx) for the resize itself — this is the ONLY writer
 * path that ever takes unique on mtx, and it runs log2(N) times over the
 * index lifetime rather than once per append. Pre-reserves labels /
 * key_to_label / fp32_store to the new capacity so subsequent
 * bookkeep_doc calls under writer_mtx never reallocate. */
static void grow_capacity_locked(VectorSchema* schema, size_t min_needed) {
    if (min_needed <= schema->capacity) return;
    size_t new_cap = schema->capacity ? schema->capacity : VectorSchema::INITIAL_CAP;
    while (new_cap < min_needed) new_cap *= 2;
    std::unique_lock<std::shared_mutex> excl(schema->mtx);
    if (schema->hnsw_ptr) {
        schema->hnsw_ptr->resizeIndex(new_cap);
    }
    schema->capacity = new_cap;
    schema->labels.reserve(new_cap);
    schema->key_to_label.reserve(new_cap);
    if (schema->rerank) {
        size_t want = new_cap * (size_t)schema->dim;
        if (schema->fp32_store.size() < want) schema->fp32_store.resize(want);
    }
}

/* Commit the graph insert. For HNSW, caller holds shared_lock(schema->mtx);
 * hnswlib's per-label locks handle concurrent addPoint + searchKnn. For FLAT
 * (BruteforceSearch), concurrent addPoint is not safe and caller must pass
 * a unique_lock instead. */
static void index_document_add(VectorSchema* schema, const EncodedDoc& doc) {
    schema->index->addPoint(doc.buf.data(), doc.label);
}

/* R16 single-doc entry point. HNSW path splits bookkeep (writer_mtx only)
 * from addPoint (shared_lock on mtx). Capacity growth is the only path that
 * still takes unique on mtx — and it's rare. FLAT stays serialized. */
static void index_document(VectorSchema* schema,
                            const std::string& key,
                            const float* vec_data) {
    EncodedDoc doc = encode_doc(schema, vec_data);
    if (schema->hnsw_ptr) {
        {
            std::unique_lock<std::mutex> w(schema->writer_mtx);
            // Grow before assigning a label so bookkeep never sees an
            // under-capacity HNSW. Only a fresh key triggers growth.
            if (schema->key_to_label.find(key) == schema->key_to_label.end() &&
                schema->labels.size() >= schema->capacity) {
                grow_capacity_locked(schema, schema->labels.size() + 1);
            }
            bookkeep_doc(schema, key, doc);
        }
        std::shared_lock<std::shared_mutex> add(schema->mtx);
        index_document_add(schema, doc);
    } else {
        std::unique_lock<std::shared_mutex> excl(schema->mtx);
        bookkeep_doc(schema, key, doc);
        index_document_add(schema, doc);
    }
}

// ── FT.CREATE ──────────────────────────────────────────────────────────────
// FT.CREATE <index> ON HASH PREFIX 1 <prefix> SCHEMA <field> VECTOR <algo>
//     6 TYPE FLOAT32 DIM <dim> DISTANCE_METRIC <metric>

static int ft_create_cmd(ValkeyModuleCtx* ctx, ValkeyModuleString** argv, int argc) {
    if (argc < 14) {
        return ValkeyModule_WrongArity(ctx);
    }

    size_t len;
    const char* index_name = ValkeyModule_StringPtrLen(argv[1], &len);
    // argv[2] = ON, argv[3] = HASH, argv[4] = PREFIX, argv[5] = 1
    const char* hash_prefix = ValkeyModule_StringPtrLen(argv[6], &len);
    // argv[7] = SCHEMA, argv[8] = <field>
    const char* vector_field = ValkeyModule_StringPtrLen(argv[8], &len);
    // argv[9] = VECTOR, argv[10] = <algo>, argv[11] = 6
    // argv[12] = TYPE, argv[13] = FLOAT32, argv[14] = DIM, argv[15] = <dim>
    // argv[16] = DISTANCE_METRIC, argv[17] = <metric>

    if (argc < 18) return ValkeyModule_WrongArity(ctx);

    const char* algo_str   = ValkeyModule_StringPtrLen(argv[10], &len);
    const char* dim_str    = ValkeyModule_StringPtrLen(argv[15], &len);
    const char* metric_str = ValkeyModule_StringPtrLen(argv[17], &len);

    int dim = std::atoi(dim_str);
    if (dim <= 0) {
        return ValkeyModule_ReplyWithError(ctx, "ERR DIM must be a positive integer");
    }

    Algo algo = Algo::HNSW;
    if (iequal(algo_str, "FLAT")) algo = Algo::FLAT;

    Metric metric = Metric::COSINE;
    if (iequal(metric_str, "L2"))  metric = Metric::L2;
    if (iequal(metric_str, "IP"))  metric = Metric::IP;

    // R17/R18: optional trailing HNSW knobs. INITIAL_CAP pre-allocates
    // graph + companion buffers so the first n inserts incur zero
    // resizeIndex events (R17). M and EF_CONSTRUCTION control hnswlib
    // graph degree and build-time candidate width (R18) — lowering
    // EF_CONSTRUCTION from 400 → 200 roughly halves the time each
    // addPoint spends inside hnswlib's internal per-link locks, which
    // shortens the live-append p95 tail at the cost of a small build
    // recall hit. Unknown tokens are ignored for forward-compat.
    size_t initial_cap      = VectorSchema::INITIAL_CAP;
    int    hnsw_m           = 32;
    int    hnsw_ef_c        = 400;
    for (int i = 18; i + 1 < argc; i++) {
        const char* opt = ValkeyModule_StringPtrLen(argv[i], &len);
        const char* val = ValkeyModule_StringPtrLen(argv[i + 1], &len);
        if (iequal(opt, "INITIAL_CAP")) {
            long long n = std::atoll(val);
            if (n > 0) initial_cap = (size_t)n;
        } else if (iequal(opt, "M")) {
            int n = std::atoi(val);
            if (n > 0) hnsw_m = n;
        } else if (iequal(opt, "EF_CONSTRUCTION")) {
            int n = std::atoi(val);
            if (n > 0) hnsw_ef_c = n;
        }
    }

    std::unique_lock<std::shared_mutex> g(g_index_mutex);

    if (g_indexes.count(index_name)) {
        return ValkeyModule_ReplyWithError(ctx, "ERR Index already exists");
    }

    auto schema = std::make_unique<VectorSchema>();
    schema->index_name   = index_name;
    schema->hash_prefix  = hash_prefix;
    schema->vector_field = vector_field;
    schema->dim          = dim;
    schema->algo         = algo;
    schema->metric       = metric;
    schema->space        = make_space(metric, dim);

    schema->capacity = initial_cap;
    // R16: pre-reserve so the first initial_cap inserts never realloc
    // labels/key_to_label under writer_mtx while readers hold shared(mtx).
    schema->labels.reserve(initial_cap);
    schema->key_to_label.reserve(initial_cap);
    if (algo == Algo::FLAT) {
        schema->index = std::make_unique<hnswlib::BruteforceSearch<float>>(
            schema->space.get(), initial_cap);
        schema->hnsw_ptr = nullptr;
    } else {
        auto* hnsw = new hnswlib::HierarchicalNSW<float>(
            schema->space.get(), initial_cap,
            (size_t)hnsw_m, (size_t)hnsw_ef_c);
        schema->hnsw_ptr = hnsw;
        schema->index.reset(hnsw);
    }

    g_indexes[index_name] = std::move(schema);
    return ValkeyModule_ReplyWithSimpleString(ctx, "OK");
}

// ── FT.DROPINDEX ───────────────────────────────────────────────────────────

static int ft_dropindex_cmd(ValkeyModuleCtx* ctx, ValkeyModuleString** argv, int argc) {
    if (argc < 2) return ValkeyModule_WrongArity(ctx);
    size_t len;
    const char* index_name = ValkeyModule_StringPtrLen(argv[1], &len);

    std::unique_lock<std::shared_mutex> g(g_index_mutex);
    auto it = g_indexes.find(index_name);
    if (it == g_indexes.end()) {
        return ValkeyModule_ReplyWithError(ctx, "ERR Unknown index");
    }
    g_indexes.erase(it);
    return ValkeyModule_ReplyWithSimpleString(ctx, "OK");
}

// ── FT.SEARCH ──────────────────────────────────────────────────────────────
// FT.SEARCH <index> "*=>[KNN k @field $BLOB AS alias]"
//           PARAMS 2 BLOB <bytes> [EF_RUNTIME <n>] [SORTBY alias] [DIALECT 2]
//
// EF_RUNTIME controls hnswlib's ef search-time parameter. Higher values
// trade latency for recall. Only meaningful for HNSW indexes; ignored on
// FLAT (brute-force) indexes. If omitted, the library default (10) stands.
//
// Returns: [total_count, key1, [score_alias, score1, ...], key2, ...]

static int ft_search_cmd(ValkeyModuleCtx* ctx, ValkeyModuleString** argv, int argc) {
    if (argc < 6) return ValkeyModule_WrongArity(ctx);

    size_t len;
    const char* index_name = ValkeyModule_StringPtrLen(argv[1], &len);

    // Parse query string: "*=>[KNN <k> @<field> $BLOB AS <alias>]"
    const char* query_str = ValkeyModule_StringPtrLen(argv[2], &len);
    int k = 10;
    int ef_runtime = 0;  // 0 = leave hnswlib default
    char score_alias[128] = "__score";

    {
        const char* knn_p = std::strstr(query_str, "KNN");
        if (knn_p) {
            knn_p += 3;
            while (*knn_p == ' ') knn_p++;
            k = std::atoi(knn_p);
            if (k <= 0) k = 10;
        }
        const char* as_p = std::strstr(query_str, " AS ");
        if (as_p) {
            as_p += 4;
            const char* end = std::strpbrk(as_p, " ]\0");
            size_t alen = end ? (size_t)(end - as_p) : std::strlen(as_p);
            if (alen > 0 && alen < sizeof(score_alias) - 1) {
                std::memcpy(score_alias, as_p, alen);
                score_alias[alen] = '\0';
            }
        }
    }

    // Find PARAMS … BLOB <bytes> and optional top-level EF_RUNTIME <n>
    const char* blob_data = nullptr;
    size_t blob_len = 0;
    for (int i = 3; i < argc; i++) {
        const char* arg = ValkeyModule_StringPtrLen(argv[i], &len);
        if (iequal(arg, "PARAMS") && i + 3 < argc) {
            // PARAMS <n> <name> <val> …
            int n = std::atoi(ValkeyModule_StringPtrLen(argv[i + 1], &len));
            for (int p = 0; p < n; p += 2) {
                if (i + 2 + p + 1 >= argc) break;
                const char* pname = ValkeyModule_StringPtrLen(argv[i + 2 + p], &len);
                if (iequal(pname, "BLOB")) {
                    blob_data = ValkeyModule_StringPtrLen(argv[i + 2 + p + 1], &blob_len);
                } else if (iequal(pname, "EF_RUNTIME")) {
                    ef_runtime = std::atoi(ValkeyModule_StringPtrLen(argv[i + 2 + p + 1], &len));
                }
            }
        } else if (iequal(arg, "EF_RUNTIME") && i + 1 < argc) {
            ef_runtime = std::atoi(ValkeyModule_StringPtrLen(argv[i + 1], &len));
        }
    }

    if (!blob_data) {
        return ValkeyModule_ReplyWithError(ctx, "ERR BLOB parameter missing");
    }

    // Validate blob size
    std::shared_lock<std::shared_mutex> g(g_index_mutex);
    auto it = g_indexes.find(index_name);
    if (it == g_indexes.end()) {
        return ValkeyModule_ReplyWithError(ctx, "ERR Unknown index");
    }
    VectorSchema* schema = it->second.get();

    size_t n_elems = schema->element_count.load(std::memory_order_acquire);
    if (n_elems == 0) {
        ValkeyModule_ReplyWithArray(ctx, 1);
        ValkeyModule_ReplyWithLongLong(ctx, 0);
        return VALKEYMODULE_OK;
    }

    // Decode base64 blob from Kotlin (binary blobs go through JNI UTF-8 path,
    // so they are base64-encoded on the Kotlin side to stay 7-bit clean).
    size_t expected = (size_t)(schema->dim * 4);
    std::vector<uint8_t> raw_blob(expected);
    int decoded = b64_decode(blob_data, blob_len, raw_blob.data());
    if (decoded != (int)expected) {
        return ValkeyModule_ReplyWithError(ctx, "ERR decoded query blob size mismatch");
    }

    std::vector<float> query_vec(schema->dim);
    std::memcpy(query_vec.data(), raw_blob.data(), expected);
    if (schema->metric == Metric::COSINE) normalise(query_vec.data(), schema->dim);

    int actual_k = (int)std::min((size_t)k, n_elems);

    std::shared_lock<std::shared_mutex> index_lock(schema->mtx);
    auto results = (schema->hnsw_ptr && ef_runtime > 0)
        ? schema->hnsw_ptr->searchKnnEf(query_vec.data(), (size_t)actual_k, (size_t)ef_runtime)
        : schema->index->searchKnn(query_vec.data(), actual_k);

    // FT.SEARCH reply format: [total, id1, [f1,v1,...], id2, ...]
    // results is a max-heap (farthest first); reverse for ascending distance
    std::vector<std::pair<float, hnswlib::labeltype>> sorted;
    while (!results.empty()) {
        sorted.push_back(results.top());
        results.pop();
    }
    std::reverse(sorted.begin(), sorted.end());

    ValkeyModule_ReplyWithArray(ctx, 1 + (long long)sorted.size() * 2);
    ValkeyModule_ReplyWithLongLong(ctx, (long long)sorted.size());

    // R16: no bounds check on labels.size(). HNSW/FLAT only returns a
    // label whose addPoint completed, and bookkeep sequences push_back →
    // element_count-release → addPoint. No realloc can happen while we
    // hold shared(mtx) (reserve is confined to grow_capacity_locked under
    // unique(mtx)), so labels.data() is stable for this scope.
    for (auto& [dist, label] : sorted) {
        const std::string& key = schema->labels[label];
        ValkeyModule_ReplyWithStringBuffer(ctx, key.c_str(), key.size());

        // Per-document field array: [score_alias, <dist>]
        ValkeyModule_ReplyWithArray(ctx, 2);
        ValkeyModule_ReplyWithStringBuffer(ctx, score_alias, std::strlen(score_alias));
        char dist_buf[32];
        int dlen = std::snprintf(dist_buf, sizeof(dist_buf), "%.6f", dist);
        ValkeyModule_ReplyWithStringBuffer(ctx, dist_buf, dlen);
    }

    return VALKEYMODULE_OK;
}

// ── FT.HADD — HSET + synchronous vector index ──────────────────────────────
// FT.HADD <index> <key> <vecfield> <base64_blob> [field val ...]
//
// Stores all field/value pairs in the Valkey hash AND indexes the vector
// synchronously. No keyspace notification dependency.

static int ft_hadd_cmd(ValkeyModuleCtx* ctx, ValkeyModuleString** argv, int argc) {
    if (argc < 5) return ValkeyModule_WrongArity(ctx);

    size_t len;
    const char* index_name  = ValkeyModule_StringPtrLen(argv[1], &len);
    const char* key_str     = ValkeyModule_StringPtrLen(argv[2], &len);
    size_t key_len = len;
    const char* vec_field   = ValkeyModule_StringPtrLen(argv[3], &len);
    const char* b64_blob    = ValkeyModule_StringPtrLen(argv[4], &len);
    size_t b64_len = len;

    std::shared_lock<std::shared_mutex> g(g_index_mutex);
    auto it = g_indexes.find(index_name);
    if (it == g_indexes.end()) {
        return ValkeyModule_ReplyWithError(ctx, "ERR Unknown index");
    }
    VectorSchema* schema = it->second.get();

    // Decode base64 blob
    size_t expected = (size_t)(schema->dim * 4);
    std::vector<uint8_t> raw(expected);
    int decoded = b64_decode(b64_blob, b64_len, raw.data());
    if (decoded != (int)expected) {
        return ValkeyModule_ReplyWithError(ctx, "ERR decoded blob size mismatch");
    }

    // HSET key vecfield <raw_bytes> [extra fields…]
    ValkeyModuleKey* mk = (ValkeyModuleKey*)ValkeyModule_OpenKey(
        ctx, argv[2], VALKEYMODULE_WRITE);
    if (!mk) return ValkeyModule_ReplyWithError(ctx, "ERR cannot open key");

    // Store the raw binary vector in the hash
    ValkeyModuleString* vf_str = ValkeyModule_CreateString(ctx, vec_field, std::strlen(vec_field));
    // Store raw bytes (binary-safe via Valkey hash)
    ValkeyModuleString* vf_val = ValkeyModule_CreateString(
        ctx, reinterpret_cast<const char*>(raw.data()), expected);
    ValkeyModule_HashSet(mk, VALKEYMODULE_HASH_NONE, vf_str, vf_val, nullptr);
    ValkeyModule_FreeString(ctx, vf_str);
    ValkeyModule_FreeString(ctx, vf_val);

    // Extra metadata fields (argv[5], argv[6], argv[7], argv[8], ...)
    for (int i = 5; i + 1 < argc; i += 2) {
        ValkeyModule_HashSet(mk, VALKEYMODULE_HASH_NONE, argv[i], argv[i + 1], nullptr);
    }
    ValkeyModule_CloseKey(mk);

    // Index vector synchronously. R13: index_document manages its own locks
    // (brief unique for bookkeeping, shared for HNSW addPoint so concurrent
    // searches aren't blocked by graph inserts).
    std::string key_owned(key_str, key_len);
    const float* fptr = reinterpret_cast<const float*>(raw.data());
    index_document(schema, key_owned, fptr);

    return ValkeyModule_ReplyWithSimpleString(ctx, "OK");
}

// ── Keyspace notification: auto-index on HSET ──────────────────────────────

static int on_keyspace_event(ValkeyModuleCtx* ctx,
                             int /*type*/,
                             const char* event,
                             ValkeyModuleString* key_str) {
    if (!iequal(event, "hset") && !iequal(event, "hmset")) return VALKEYMODULE_OK;

    size_t key_len;
    const char* key = ValkeyModule_StringPtrLen(key_str, &key_len);

    std::shared_lock<std::shared_mutex> g(g_index_mutex);

    for (auto& [name, schema] : g_indexes) {
        const std::string& pfx = schema->hash_prefix;
        if (key_len < pfx.size()) continue;
        if (std::memcmp(key, pfx.c_str(), pfx.size()) != 0) continue;

        // Open the key read-only from within the keyspace notification
        ValkeyModuleKey* mk = (ValkeyModuleKey*)ValkeyModule_OpenKey(
            ctx, key_str, VALKEYMODULE_READ);
        if (!mk) continue;
        if (ValkeyModule_KeyType(mk) != VALKEYMODULE_KEYTYPE_HASH) {
            ValkeyModule_CloseKey(mk);
            continue;
        }

        ValkeyModuleString* field_name = ValkeyModule_CreateString(
            ctx, schema->vector_field.c_str(), schema->vector_field.size());
        ValkeyModuleString* field_val = nullptr;
        ValkeyModule_HashGet(mk, VALKEYMODULE_HASH_NONE, field_name, &field_val, nullptr);
        ValkeyModule_FreeString(ctx, field_name);
        ValkeyModule_CloseKey(mk);

        if (!field_val) continue;

        size_t vec_len;
        const char* vec_bytes = ValkeyModule_StringPtrLen(field_val, &vec_len);

        if (vec_len == (size_t)(schema->dim * 4)) {
            std::string key_str_owned(key, key_len);
            // R13: index_document manages locks internally.
            index_document(schema.get(), key_str_owned,
                           reinterpret_cast<const float*>(vec_bytes));
        }
        ValkeyModule_FreeString(ctx, field_val);
    }

    return VALKEYMODULE_OK;
}

// ── Module entry point ─────────────────────────────────────────────────────

// Per-module OnLoad name. When Dazzle is linked statically into libdazzle.so
// (the only supported deployment — iOS via xcframework, Android via AAR)
// multiple modules coexist in the same binary, so each one must expose a
// distinct OnLoad symbol. The patched Valkey module loader composes the
// symbol name as `ValkeyModule_OnLoad_<name>` from the `@static:<name>`
// sentinel passed to `--loadmodule`.
extern "C" __attribute__((visibility("default"))) int ValkeyModule_OnLoad_vectorsearch(ValkeyModuleCtx* ctx,
                                   ValkeyModuleString** /*argv*/,
                                   int /*argc*/) {
    if (ValkeyModule_Init(ctx, "vectorsearch", 1, VALKEYMODULE_APIVER_1) == VALKEYMODULE_ERR) {
        return VALKEYMODULE_ERR;
    }

    if (ValkeyModule_CreateCommand(ctx, "FT.CREATE",
            ft_create_cmd, "write deny-oom", 0, 0, 0) == VALKEYMODULE_ERR) {
        return VALKEYMODULE_ERR;
    }
    if (ValkeyModule_CreateCommand(ctx, "FT.DROPINDEX",
            ft_dropindex_cmd, "write", 1, 1, 1) == VALKEYMODULE_ERR) {
        return VALKEYMODULE_ERR;
    }
    if (ValkeyModule_CreateCommand(ctx, "FT.SEARCH",
            ft_search_cmd, "readonly", 0, 0, 0) == VALKEYMODULE_ERR) {
        return VALKEYMODULE_ERR;
    }
    // FT.HADD: synchronous HSET + index (avoids keyspace notification dependency)
    if (ValkeyModule_CreateCommand(ctx, "FT.HADD",
            ft_hadd_cmd, "write deny-oom", 2, 2, 1) == VALKEYMODULE_ERR) {
        return VALKEYMODULE_ERR;
    }

    // Also subscribe to HSET keyspace events as a convenience path for plain
    // HSET callers — requires notify-keyspace-events but is non-fatal if absent.
    ValkeyModule_SubscribeToKeyspaceEvents(ctx,
        VALKEYMODULE_NOTIFY_HASH, on_keyspace_event);

    return VALKEYMODULE_OK;
}

// ── JNI handle lookup — skip the g_indexes hash+mutex on every call ────────
// Kotlin can open a handle once after FT.CREATE; subsequent search/add calls
// operate on the raw pointer directly. Safe because the VectorSchema owned
// by g_indexes is never freed while an index is live — FT.DROPINDEX is the
// only path that destroys it, and that is the caller's responsibility.

// SQ8 index creation — bypasses FT.CREATE and constructs an HNSW schema that
// stores int8[dim] per point with simsimd_cos_i8 as the distance. Cosine-only
// (the metric is scale-invariant so per-vector quantisation needs no stored
// scale). Returns the opaque schema handle, same shape as open_handle_impl.
//
// Pure C++ impl — JNI and plain-C entry points both delegate here so the
// business logic lives once.
#if defined(DAZZLE_VECTOR_SIMSIMD)
static VectorSchema* create_sq8_index_impl(const char* name_c,
                                           int dim,
                                           int M,
                                           int efC,
                                           int initialCap,
                                           bool rerank) {
    if (!name_c || dim <= 0) return nullptr;
    std::string name(name_c);

    std::unique_lock<std::shared_mutex> g(g_index_mutex);
    if (g_indexes.count(name)) {
        return g_indexes[name].get();
    }

    size_t initial_cap = (initialCap > 0)
        ? (size_t)initialCap : VectorSchema::INITIAL_CAP;

    auto schema = std::make_unique<VectorSchema>();
    schema->index_name = name;
    schema->dim        = dim;
    schema->algo       = Algo::HNSW;
    schema->metric     = Metric::COSINE;
    schema->sq8        = true;
    schema->rerank     = rerank;
    schema->space      = std::make_unique<SimsimdCosI8Space>((size_t)dim);
    schema->capacity   = initial_cap;
    // R16: see note in ft_create_cmd.
    schema->labels.reserve(initial_cap);
    schema->key_to_label.reserve(initial_cap);
    if (rerank) {
        schema->fp32_store.resize(initial_cap * (size_t)dim);
    }

    int Mv   = M   > 0 ? M   : 32;
    int efCv = efC > 0 ? efC : 400;
    auto* hnsw = new hnswlib::HierarchicalNSW<float>(
        schema->space.get(), initial_cap, (size_t)Mv, (size_t)efCv);
    schema->hnsw_ptr = hnsw;
    schema->index.reset(hnsw);

    VectorSchema* raw = schema.get();
    g_indexes[name] = std::move(schema);
    return raw;
}

static VectorSchema* create_f16_index_impl(const char* name_c,
                                           int dim,
                                           int M,
                                           int efC,
                                           int initialCap) {
    if (!name_c || dim <= 0) return nullptr;
    std::string name(name_c);

    std::unique_lock<std::shared_mutex> g(g_index_mutex);
    if (g_indexes.count(name)) {
        return g_indexes[name].get();
    }

    size_t initial_cap = (initialCap > 0)
        ? (size_t)initialCap : VectorSchema::INITIAL_CAP;

    auto schema = std::make_unique<VectorSchema>();
    schema->index_name = name;
    schema->dim        = dim;
    schema->algo       = Algo::HNSW;
    schema->metric     = Metric::COSINE;
    schema->f16        = true;
    schema->space      = std::make_unique<SimsimdDotF16Space>((size_t)dim);
    schema->capacity   = initial_cap;
    // R16: see note in ft_create_cmd.
    schema->labels.reserve(initial_cap);
    schema->key_to_label.reserve(initial_cap);

    int Mv   = M   > 0 ? M   : 32;
    int efCv = efC > 0 ? efC : 400;
    auto* hnsw = new hnswlib::HierarchicalNSW<float>(
        schema->space.get(), initial_cap, (size_t)Mv, (size_t)efCv);
    schema->hnsw_ptr = hnsw;
    schema->index.reset(hnsw);

    VectorSchema* raw = schema.get();
    g_indexes[name] = std::move(schema);
    return raw;
}
#endif

// Plain-C impl for open_handle — resolves a name to a VectorSchema pointer.
static VectorSchema* open_handle_impl(const char* name_c) {
    if (!name_c) return nullptr;
    std::shared_lock<std::shared_mutex> g(g_index_mutex);
    auto it = g_indexes.find(name_c);
    if (it == g_indexes.end()) return nullptr;
    return it->second.get();
}

// Plain-C impl for add_direct — adds a single vector to a named index.
static void add_direct_impl(const char* name_c,
                            const char* key_c,
                            size_t key_len,
                            const float* vec) {
    if (!name_c || !key_c || !vec) return;
    std::shared_lock<std::shared_mutex> g(g_index_mutex);
    auto it = g_indexes.find(name_c);
    if (it == g_indexes.end()) return;
    VectorSchema* schema = it->second.get();
    std::string key_owned(key_c, key_len);
    // R13: index_document manages locks internally.
    index_document(schema, key_owned, vec);
}

// Plain-C impl for batch add. Mirrors the JNI nAddBatchDirect flow: two-phase
// label-alloc + parallel addPoint, with FLAT fallback when hnsw_ptr is null.
static void add_batch_direct_impl(const char* name_c,
                                  int nVecs,
                                  const char* const* ids,
                                  const size_t* id_lens,
                                  const float* vecs_flat) {
    if (!name_c || !ids || !vecs_flat || nVecs <= 0) return;

    std::shared_lock<std::shared_mutex> g(g_index_mutex);
    auto it = g_indexes.find(name_c);
    if (it == g_indexes.end()) return;
    VectorSchema* schema = it->second.get();
    int dim = schema->dim;

    std::vector<std::string> keys;
    keys.reserve(nVecs);
    for (int i = 0; i < nVecs; i++) {
        size_t klen = id_lens ? id_lens[i] : std::strlen(ids[i]);
        keys.emplace_back(ids[i], klen);
    }

    if (!schema->hnsw_ptr) {
        for (int i = 0; i < nVecs; i++) {
            index_document(schema, keys[(size_t)i], vecs_flat + (size_t)i * dim);
        }
        return;
    }

    std::vector<hnswlib::labeltype> labels((size_t)nVecs);
    size_t new_elems = 0;
    {
        std::unique_lock<std::mutex> w(schema->writer_mtx);
        size_t projected = schema->labels.size() + (size_t)nVecs;
        if (projected > schema->capacity) {
            grow_capacity_locked(schema, projected);
        } else if (projected > schema->labels.capacity()) {
            schema->labels.reserve(projected);
            schema->key_to_label.reserve(projected);
            if (schema->rerank) {
                size_t want = projected * (size_t)schema->dim;
                if (schema->fp32_store.size() < want) schema->fp32_store.resize(want);
            }
        }
        for (int i = 0; i < nVecs; i++) {
            auto kit = schema->key_to_label.find(keys[(size_t)i]);
            if (kit != schema->key_to_label.end()) {
                labels[(size_t)i] = kit->second;
            } else {
                hnswlib::labeltype lbl = schema->labels.size();
                schema->labels.push_back(keys[(size_t)i]);
                schema->key_to_label.emplace(keys[(size_t)i], lbl);
                labels[(size_t)i] = lbl;
                new_elems++;
            }
        }
        schema->element_count.fetch_add(new_elems, std::memory_order_release);
    }
    g.unlock();
    std::shared_lock<std::shared_mutex> phase2_lock(schema->mtx);

    auto* hnsw = schema->hnsw_ptr;
    bool normalise_cosine = (schema->metric == Metric::COSINE);
    unsigned hw = std::thread::hardware_concurrency();
    int nThreads = (int)std::min<unsigned>(hw == 0 ? 2u : hw, 8u);
    if (nVecs < nThreads * 32) nThreads = 1;
    // Allow caller to override via env (set via the JNI helper
    // `nSetAddBatchThreads`). This is the escape hatch for chips
    // where 8-way parallel `hnsw->addPoint` deadlocks under EMUI
    // iAware-style cgroup throttling (Kirin 659 / Cortex-A53). On
    // those targets the test harness sets it to 1 before the
    // first addBatchDirect call; on chips with adequate scheduler
    // headroom (G80 / SD662 / T760 / iPhone) the env stays unset
    // and the original 8-way pool runs as before.
    if (const char* env = std::getenv("DAZZLE_HNSW_BATCH_THREADS")) {
        int forced = std::atoi(env);
        if (forced >= 1) nThreads = forced;
    }
    DZ_LOGI("addBatchDirect: nVecs=%d hw=%u nThreads=%d (env=%s)",
            nVecs, hw, nThreads,
            std::getenv("DAZZLE_HNSW_BATCH_THREADS") ?
            std::getenv("DAZZLE_HNSW_BATCH_THREADS") : "<unset>");

    bool sq8 = schema->sq8;
    bool f16 = schema->f16;
    bool rerank = schema->rerank;
    float* fp32_base = rerank ? schema->fp32_store.data() : nullptr;
    auto worker = [&](int t) {
        std::vector<float>    scratch_f(dim);
        std::vector<int8_t>   scratch_i8((size_t)(sq8 ? dim : 0));
        std::vector<uint16_t> scratch_f16((size_t)(f16 ? dim : 0));
        if (t == 0) DZ_LOGI("addBatchDirect: worker(0) entered, will iterate %d vecs", nVecs);
        for (int i = t; i < nVecs; i += nThreads) {
            if (t == 0 && (i % 200 == 0)) {
                DZ_LOGI("addBatchDirect: worker(0) at vec %d/%d", i, nVecs);
            }
            const float* src = vecs_flat + (size_t)i * dim;
            const void* vec_to_add;
            bool have_norm = false;
            if (rerank || f16 || (normalise_cosine && !sq8)) {
                std::memcpy(scratch_f.data(), src, dim * sizeof(float));
                if (normalise_cosine) normalise(scratch_f.data(), dim);
                have_norm = true;
            }
            if (sq8) {
#if defined(DAZZLE_VECTOR_SIMSIMD)
                quantize_int8(src, dim, scratch_i8.data());
                vec_to_add = scratch_i8.data();
#else
                vec_to_add = nullptr;
#endif
            } else if (f16) {
#if defined(DAZZLE_VECTOR_SIMSIMD)
                quantize_f16(scratch_f.data(), dim, scratch_f16.data());
                vec_to_add = scratch_f16.data();
#else
                vec_to_add = nullptr;
#endif
            } else if (have_norm) {
                vec_to_add = scratch_f.data();
            } else {
                vec_to_add = src;
            }
            if (rerank && have_norm) {
                hnswlib::labeltype lbl = labels[(size_t)i];
                std::memcpy(fp32_base + (size_t)lbl * (size_t)dim,
                            scratch_f.data(), (size_t)dim * sizeof(float));
            }
            hnsw->addPoint(vec_to_add, labels[(size_t)i]);
        }
    };

    if (nThreads == 1) {
        worker(0);
    } else {
        std::vector<std::thread> pool;
        pool.reserve((size_t)nThreads);
        for (int t = 0; t < nThreads; t++) pool.emplace_back(worker, t);
        for (auto& th : pool) th.join();
    }
    DZ_LOGI("addBatchDirect: all workers joined, nVecs=%d done", nVecs);
}

// Search impl on a resolved schema pointer. Result fills out_ids[] with
// strdup'd NUL-terminated strings (caller frees with dazzle_vs_free_id) and
// out_dists[] with float distances. Returns the number of results written
// (<= max_out). Mirrors the Java_*_nSearchHandle path: rerank, thread-local
// scratch, searchKnnEf when ef > 0.
static int search_handle_impl(VectorSchema* schema,
                              const float* qsrc,
                              int k,
                              int ef,
                              char** out_ids,
                              float* out_dists,
                              int max_out) {
    if (!schema || !qsrc || !out_ids || !out_dists || max_out <= 0) return 0;
    size_t n_elems = schema->element_count.load(std::memory_order_acquire);
    if (n_elems == 0) return 0;

    thread_local std::vector<float>    q_tls;
    thread_local std::vector<int8_t>   q_i8_tls;
    thread_local std::vector<uint16_t> q_f16_tls;
    const void* q_ptr;
    bool need_fp32_q = schema->rerank;
    if (schema->sq8) {
#if defined(DAZZLE_VECTOR_SIMSIMD)
        q_i8_tls.resize((size_t)schema->dim);
        quantize_int8(qsrc, schema->dim, q_i8_tls.data());
        q_ptr = q_i8_tls.data();
        if (need_fp32_q) {
            q_tls.assign(qsrc, qsrc + schema->dim);
            if (schema->metric == Metric::COSINE) normalise(q_tls.data(), schema->dim);
        }
#else
        q_ptr = nullptr;
#endif
    } else if (schema->f16) {
#if defined(DAZZLE_VECTOR_SIMSIMD)
        q_tls.assign(qsrc, qsrc + schema->dim);
        if (schema->metric == Metric::COSINE) normalise(q_tls.data(), schema->dim);
        q_f16_tls.resize((size_t)schema->dim);
        quantize_f16(q_tls.data(), schema->dim, q_f16_tls.data());
        q_ptr = q_f16_tls.data();
#else
        q_ptr = nullptr;
#endif
    } else {
        q_tls.assign(qsrc, qsrc + schema->dim);
        if (schema->metric == Metric::COSINE) normalise(q_tls.data(), schema->dim);
        q_ptr = q_tls.data();
    }

    int actual_k = (int)std::min((size_t)k, n_elems);
    constexpr int kRerankFactor = 2;
    int fetch_k = actual_k;
    if (schema->rerank) {
        size_t want = (size_t)actual_k * (size_t)kRerankFactor;
        fetch_k = (int)std::min(want, n_elems);
    }

    std::shared_lock<std::shared_mutex> idx_lock(schema->mtx);
    std::priority_queue<std::pair<float, hnswlib::labeltype>> results;
    bool flat_scalar = (schema->algo == Algo::FLAT) &&
                       !schema->sq8 && !schema->f16 &&
                       !schema->fp32_store.empty();
    if (flat_scalar) {
        // Portable scalar brute-force scan over the stored fp32_store —
        // bypasses hnswlib's BruteforceSearch SIMD distance kernel which
        // segfaults on Cortex-A53 + ARMv8.0 (Kirin 659 / EMUI 9) due to
        // misaligned 16-byte NEON loads on hnswlib's `[vec, label]`
        // packed stride. This loop is unconditionally safe on every
        // arm64 chip and ~1.5 ms for N=2000, dim=384 on Cortex-A53.
        // Distance is `1 - dot(q, v)` for COSINE / IP (both already
        // normalised on add) and the squared L2 distance for L2.
        size_t dim_sz = (size_t)schema->dim;
        size_t n      = n_elems;
        const float* q_f = static_cast<const float*>(q_ptr);
        const float* base = schema->fp32_store.data();
        for (size_t i = 0; i < n; i++) {
            const float* v = base + i * dim_sz;
            float d = 0.0f;
            if (schema->metric == Metric::L2) {
                for (size_t j = 0; j < dim_sz; j++) {
                    float diff = q_f[j] - v[j];
                    d += diff * diff;
                }
            } else {
                // COSINE / IP — both run on unit-normalised vectors so the
                // similarity is the dot product; distance = 1 - sim.
                float dot = 0.0f;
                for (size_t j = 0; j < dim_sz; j++) dot += q_f[j] * v[j];
                d = 1.0f - dot;
            }
            results.emplace(d, (hnswlib::labeltype)i);
            if ((int)results.size() > fetch_k) results.pop();
        }
    } else {
        results = (schema->hnsw_ptr && ef > 0)
            ? schema->hnsw_ptr->searchKnnEf(q_ptr, (size_t)fetch_k, (size_t)ef)
            : schema->index->searchKnn(q_ptr, fetch_k);
    }

    thread_local std::vector<std::pair<float, hnswlib::labeltype>> sorted_tls;
    sorted_tls.clear();
    sorted_tls.reserve(results.size());
    while (!results.empty()) { sorted_tls.push_back(results.top()); results.pop(); }
    std::reverse(sorted_tls.begin(), sorted_tls.end());
    auto& sorted = sorted_tls;

    if (schema->rerank) {
#if defined(DAZZLE_VECTOR_SIMSIMD)
        const float* qf = q_tls.data();
        const float* base_fp32 = schema->fp32_store.data();
        size_t dim_sz = (size_t)schema->dim;
        size_t row_bytes = dim_sz * sizeof(float);
        size_t nc = sorted.size();
        for (size_t i = 0; i < nc; i++) {
            if (i + 1 < nc) {
                const float* nxt = base_fp32 + (size_t)sorted[i + 1].second * dim_sz;
                for (size_t off = 0; off < row_bytes; off += 64) {
                    __builtin_prefetch(reinterpret_cast<const char*>(nxt) + off, 0, 0);
                }
            }
            hnswlib::labeltype lbl = sorted[i].second;
            simsimd_distance_t d;
#if defined(__aarch64__)
            simsimd_dot_f32_neon(qf, base_fp32 + (size_t)lbl * dim_sz, dim_sz, &d);
#else
            simsimd_dot_f32(qf, base_fp32 + (size_t)lbl * dim_sz, dim_sz, &d);
#endif
            sorted[i].first = 1.0f - (float)d;
        }
        std::sort(sorted.begin(), sorted.end(),
                  [](const auto& a, const auto& b) { return a.first < b.first; });
#endif
        if ((int)sorted.size() > actual_k) sorted.resize((size_t)actual_k);
    }

    int n = (int)std::min<size_t>(sorted.size(), (size_t)max_out);
    for (int i = 0; i < n; i++) {
        float dist = sorted[(size_t)i].first;
        hnswlib::labeltype lbl = sorted[(size_t)i].second;
        const std::string& key = schema->labels[lbl];
        char* cstr = (char*)std::malloc(key.size() + 1);
        if (cstr) {
            std::memcpy(cstr, key.data(), key.size());
            cstr[key.size()] = '\0';
        }
        out_ids[i] = cstr;
        out_dists[i] = dist;
    }
    return n;
}

// search_direct_impl is the name-resolving variant; it looks up the schema
// under g_index_mutex and defers to search_handle_impl for the hot loop.
// Mirrors the Java_*_nSearchDirect path but returns ids + dists in parallel
// out-arrays instead of an interleaved jobjectArray.
static int search_direct_impl(const char* name_c,
                              const float* qsrc,
                              int k,
                              int ef,
                              char** out_ids,
                              float* out_dists,
                              int max_out) {
    VectorSchema* schema = nullptr;
    {
        std::shared_lock<std::shared_mutex> g(g_index_mutex);
        auto it = g_indexes.find(name_c);
        if (it == g_indexes.end()) return 0;
        schema = it->second.get();
    }
    return search_handle_impl(schema, qsrc, k, ef, out_ids, out_dists, max_out);
}

// ── Plain-C fast-path — iOS (Swift) and Android (Kotlin JNI shims below) ──
// These entry points depend ONLY on <stdlib.h>/<string.h>, no JNI, no Swift
// interop shim. Android JNI wrappers further down translate jstring /
// jobjectArray / direct-ByteBuffer into the pointers + lengths these helpers
// consume. iOS calls these directly from DazzleC's modulemap.

extern "C" __attribute__((visibility("default")))
void* dazzle_vs_create_sq8(const char* name, int dim, int M, int efC,
                           int initialCap, int rerank) {
#if defined(DAZZLE_VECTOR_SIMSIMD)
    return create_sq8_index_impl(name, dim, M, efC, initialCap, rerank != 0);
#else
    (void)name; (void)dim; (void)M; (void)efC; (void)initialCap; (void)rerank;
    return nullptr;
#endif
}

extern "C" __attribute__((visibility("default")))
void* dazzle_vs_create_f16(const char* name, int dim, int M, int efC,
                           int initialCap) {
#if defined(DAZZLE_VECTOR_SIMSIMD)
    return create_f16_index_impl(name, dim, M, efC, initialCap);
#else
    (void)name; (void)dim; (void)M; (void)efC; (void)initialCap;
    return nullptr;
#endif
}

extern "C" __attribute__((visibility("default")))
void* dazzle_vs_open_handle(const char* name) {
    return open_handle_impl(name);
}

extern "C" __attribute__((visibility("default")))
void dazzle_vs_add_direct(const char* name, const char* key, int key_len,
                          const float* vec) {
    size_t klen = key_len >= 0 ? (size_t)key_len
                               : (key ? std::strlen(key) : 0);
    add_direct_impl(name, key, klen, vec);
}

// Batch helper with a single contiguous `vecs_flat` layout (N * dim * 4
// bytes). `ids` is a parallel array of NUL-terminated strings; pass NULL
// for `id_lens` if the caller did not precompute lengths.
extern "C" __attribute__((visibility("default")))
void dazzle_vs_add_batch_direct(const char* name, int n_vecs,
                                const char* const* ids,
                                const int* id_lens,
                                const float* vecs_flat) {
    std::vector<size_t> lens_buf;
    const size_t* lens = nullptr;
    if (id_lens) {
        lens_buf.resize((size_t)n_vecs);
        for (int i = 0; i < n_vecs; i++) lens_buf[(size_t)i] = (size_t)id_lens[i];
        lens = lens_buf.data();
    }
    add_batch_direct_impl(name, n_vecs, ids, lens, vecs_flat);
}

// The two search variants. Caller provides parallel `out_ids` + `out_dists`
// of size `max_out`. On return, `out_ids[i]` holds a malloc'd NUL-terminated
// string (free each with `dazzle_vs_free_id`) and `out_dists[i]` the cosine
// distance. Return value = number of slots actually populated (<= max_out).
extern "C" __attribute__((visibility("default")))
int dazzle_vs_search_handle(void* handle, const float* query, int k, int ef,
                            char** out_ids, float* out_dists, int max_out) {
    return search_handle_impl(reinterpret_cast<VectorSchema*>(handle),
                              query, k, ef, out_ids, out_dists, max_out);
}

extern "C" __attribute__((visibility("default")))
int dazzle_vs_search_direct(const char* name, const float* query, int k,
                            int ef, char** out_ids, float* out_dists,
                            int max_out) {
    return search_direct_impl(name, query, k, ef, out_ids, out_dists, max_out);
}

extern "C" __attribute__((visibility("default")))
void dazzle_vs_free_id(char* id) {
    if (id) std::free(id);
}

// ── Android JNI shims ──────────────────────────────────────────────────────
// Kotlin `VectorIndex` keeps the `n*` JNI entry points it already uses; the
// shims below pull jstring/jobjectArray payloads out of JNI land and hand
// them over to the plain-C helpers above. iOS skips this entire block.

#ifdef __ANDROID__

extern "C" JNIEXPORT jlong JNICALL
Java_dev_dazzle_sdk_VectorIndex_nCreateSq8(
        JNIEnv* env, jclass, jstring jName, jint jDim, jint jM, jint jEfC,
        jint jInitialCap) {
    const char* name_c = env->GetStringUTFChars(jName, nullptr);
    void* h = dazzle_vs_create_sq8(name_c, (int)jDim, (int)jM, (int)jEfC,
                                   (int)jInitialCap, /*rerank=*/0);
    env->ReleaseStringUTFChars(jName, name_c);
    return (jlong)(intptr_t)h;
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_dazzle_sdk_VectorIndex_nCreateSq8Rerank(
        JNIEnv* env, jclass, jstring jName, jint jDim, jint jM, jint jEfC,
        jint jInitialCap) {
    const char* name_c = env->GetStringUTFChars(jName, nullptr);
    void* h = dazzle_vs_create_sq8(name_c, (int)jDim, (int)jM, (int)jEfC,
                                   (int)jInitialCap, /*rerank=*/1);
    env->ReleaseStringUTFChars(jName, name_c);
    return (jlong)(intptr_t)h;
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_dazzle_sdk_VectorIndex_nCreateF16(
        JNIEnv* env, jclass, jstring jName, jint jDim, jint jM, jint jEfC,
        jint jInitialCap) {
    const char* name_c = env->GetStringUTFChars(jName, nullptr);
    void* h = dazzle_vs_create_f16(name_c, (int)jDim, (int)jM, (int)jEfC,
                                   (int)jInitialCap);
    env->ReleaseStringUTFChars(jName, name_c);
    return (jlong)(intptr_t)h;
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_dazzle_sdk_VectorIndex_nOpenHandle(
        JNIEnv* env, jclass, jstring jIndex) {
    const char* index_name = env->GetStringUTFChars(jIndex, nullptr);
    void* h = dazzle_vs_open_handle(index_name);
    env->ReleaseStringUTFChars(jIndex, index_name);
    return (jlong)(intptr_t)h;
}

// Handle-based search returning parallel arrays (ids String[], distances
// float[]) wrapped in a 2-element Object[]. Avoids the snprintf("%.9g") +
// NewStringUTF of the distance that the interleaved-String[] variant costs.
extern "C" JNIEXPORT jobjectArray JNICALL
Java_dev_dazzle_sdk_VectorIndex_nSearchHandle(
        JNIEnv* env, jclass, jlong handle, jobject jVecBuf, jint k, jint ef) {
    const float* qsrc = static_cast<const float*>(env->GetDirectBufferAddress(jVecBuf));

    jclass strCls = env->FindClass("java/lang/String");
    jclass objCls = env->FindClass("java/lang/Object");

    int cap = (int)std::max<jint>(k, 0);
    std::vector<char*>  id_buf((size_t)cap, nullptr);
    std::vector<float>  dist_buf((size_t)cap, 0.f);
    int n = dazzle_vs_search_handle(reinterpret_cast<void*>((intptr_t)handle),
                                    qsrc, (int)k, (int)ef,
                                    id_buf.data(), dist_buf.data(), cap);

    jobjectArray ids_arr  = env->NewObjectArray((jsize)n, strCls, nullptr);
    jfloatArray  dist_arr = env->NewFloatArray((jsize)n);
    for (int i = 0; i < n; i++) {
        if (id_buf[(size_t)i]) {
            jstring jId = env->NewStringUTF(id_buf[(size_t)i]);
            env->SetObjectArrayElement(ids_arr, (jsize)i, jId);
            env->DeleteLocalRef(jId);
            dazzle_vs_free_id(id_buf[(size_t)i]);
        }
    }
    if (n > 0) env->SetFloatArrayRegion(dist_arr, 0, (jsize)n, dist_buf.data());

    jobjectArray out = env->NewObjectArray(2, objCls, nullptr);
    env->SetObjectArrayElement(out, 0, ids_arr);
    env->SetObjectArrayElement(out, 1, dist_arr);
    return out;
}

// ── JNI fast-path — Kotlin ↔ hnswlib without RESP / base64 ─────────────────
// Bypasses FT.HADD + FT.SEARCH for hot-loop callers (benchmarks, inner
// retrieval loops). Operates on the same g_indexes map populated by
// FT.CREATE, so the index must be created via the normal FT.CREATE path
// first. Vectors cross the boundary as direct FLOAT32 ByteBuffers in
// little-endian layout — no base64, no UTF-8 round-trip.

extern "C" JNIEXPORT void JNICALL
Java_dev_dazzle_sdk_VectorIndex_nAddDirect(
        JNIEnv* env, jclass, jstring jIndex, jstring jKey, jobject jVecBuf) {
    const char* index_name = env->GetStringUTFChars(jIndex, nullptr);
    const char* key_cstr   = env->GetStringUTFChars(jKey,   nullptr);
    jsize key_len = env->GetStringUTFLength(jKey);
    const float* vec = static_cast<const float*>(env->GetDirectBufferAddress(jVecBuf));
    dazzle_vs_add_direct(index_name, key_cstr, (int)key_len, vec);
    env->ReleaseStringUTFChars(jIndex, index_name);
    env->ReleaseStringUTFChars(jKey,   key_cstr);
}

// Batch add — one JNI round-trip for N vectors laid out contiguously in one
// direct ByteBuffer (N * dim * 4 bytes). Ids come as String[]. JNI shim
// pulls ids out of JNI land into plain C arrays and delegates to
// `dazzle_vs_add_batch_direct` — which runs the two-phase label-alloc +
// parallel addPoint flow from any thread.
extern "C" JNIEXPORT void JNICALL
Java_dev_dazzle_sdk_VectorIndex_nAddBatchDirect(
        JNIEnv* env, jclass, jstring jIndex,
        jobjectArray jIds, jobject jVecBuf, jint nVecs) {
    const char* index_name = env->GetStringUTFChars(jIndex, nullptr);
    const float* base = static_cast<const float*>(env->GetDirectBufferAddress(jVecBuf));
    if (!base || nVecs <= 0) {
        env->ReleaseStringUTFChars(jIndex, index_name);
        return;
    }

    // Pull keys out of JNI land up front (JNI calls are main-thread only).
    std::vector<const char*> id_ptrs((size_t)nVecs, nullptr);
    std::vector<int>         id_lens((size_t)nVecs, 0);
    std::vector<jstring>     id_jstrings((size_t)nVecs, nullptr);
    for (int i = 0; i < nVecs; i++) {
        jstring jKey = (jstring)env->GetObjectArrayElement(jIds, i);
        id_jstrings[(size_t)i] = jKey;
        id_ptrs[(size_t)i]     = env->GetStringUTFChars(jKey, nullptr);
        id_lens[(size_t)i]     = (int)env->GetStringUTFLength(jKey);
    }

    dazzle_vs_add_batch_direct(index_name, (int)nVecs,
                               id_ptrs.data(), id_lens.data(), base);

    for (int i = 0; i < nVecs; i++) {
        env->ReleaseStringUTFChars(id_jstrings[(size_t)i], id_ptrs[(size_t)i]);
        env->DeleteLocalRef(id_jstrings[(size_t)i]);
    }
    env->ReleaseStringUTFChars(jIndex, index_name);
}

// Force the parallelism level used by `add_batch_direct_impl` for the
// `hnsw->addPoint` worker pool. `n` ≥ 1 pins to that exact thread count;
// `n` ≤ 0 restores the auto-detected default
// (min(hardware_concurrency, 8)). Mirrors the `DAZZLE_HNSW_BATCH_THREADS`
// env-var path but doesn't require process-level env mutation, so a
// single-process instrumentation test can switch policies on the fly.
//
// Concretely: tight 4 GB devices where EMUI iAware throttles cgroup CPU
// shares (Kirin 659 / Cortex-A53) deadlock on the default 8-way
// std::thread pool because the workers spin on hnswlib's per-element
// mutex while the kernel only schedules a fraction of them. Calling
// `nSetAddBatchThreads(1)` before the first `addBatchDirect` forces a
// single-threaded build that finishes in linear time without
// contention.
extern "C" JNIEXPORT void JNICALL
Java_dev_dazzle_sdk_VectorIndex_nSetAddBatchThreads(
        JNIEnv* /*env*/, jclass, jint n) {
    if (n >= 1) {
        char buf[16];
        std::snprintf(buf, sizeof(buf), "%d", (int)n);
        ::setenv("DAZZLE_HNSW_BATCH_THREADS", buf, /*overwrite=*/1);
    } else {
        ::unsetenv("DAZZLE_HNSW_BATCH_THREADS");
    }
}

// Returns String[] interleaved [id0, dist0, id1, dist1, …].
extern "C" JNIEXPORT jobjectArray JNICALL
Java_dev_dazzle_sdk_VectorIndex_nSearchDirect(
        JNIEnv* env, jclass, jstring jIndex,
        jobject jVecBuf, jint k, jint ef) {
    const char* index_name = env->GetStringUTFChars(jIndex, nullptr);
    const float* qsrc = static_cast<const float*>(env->GetDirectBufferAddress(jVecBuf));

    jclass strCls = env->FindClass("java/lang/String");

    int cap = (int)std::max<jint>(k, 0);
    std::vector<char*>  id_buf((size_t)cap, nullptr);
    std::vector<float>  dist_buf((size_t)cap, 0.f);
    int n = dazzle_vs_search_direct(index_name, qsrc, (int)k, (int)ef,
                                    id_buf.data(), dist_buf.data(), cap);
    env->ReleaseStringUTFChars(jIndex, index_name);

    jobjectArray out = env->NewObjectArray((jsize)(n * 2), strCls, nullptr);
    char dbuf[32];
    for (int i = 0; i < n; i++) {
        if (id_buf[(size_t)i]) {
            jstring jId = env->NewStringUTF(id_buf[(size_t)i]);
            std::snprintf(dbuf, sizeof(dbuf), "%.9g", dist_buf[(size_t)i]);
            jstring jDist = env->NewStringUTF(dbuf);
            env->SetObjectArrayElement(out, (jsize)(i * 2),     jId);
            env->SetObjectArrayElement(out, (jsize)(i * 2 + 1), jDist);
            env->DeleteLocalRef(jId);
            env->DeleteLocalRef(jDist);
            dazzle_vs_free_id(id_buf[(size_t)i]);
        }
    }
    return out;
}

#endif  // __ANDROID__

// Static-link dead-strip prevention. When libdazzle.so is built with -Wl,--gc-sections
// (Android) or the iOS archive packs unreferenced objects, the linker may drop
// `ValkeyModule_OnLoad_vectorsearch` because nothing inside the main binary
// appears to call it. dazzle_jni.c (Android) and dazzle_ios.c (iOS) take the
// address of this `_ref` symbol, which in turn references OnLoad, so the linker
// treats both as live.
extern "C" __attribute__((visibility("default"))) void* const dazzle_vectorsearch_onload_ref =
    reinterpret_cast<void*>(ValkeyModule_OnLoad_vectorsearch);
