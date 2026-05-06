// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// dazzle_wasm.cpp — Emscripten build target for Flutter Web / React Native Web.
//
// MVP scope (Scope A revised):
//   - Hash KV (HSET / HGET / HGETALL / HDEL / HKEYS)
//   - Vector index (HNSW): create / add / add-batch / search / drop
//   - Snapshot serialise / deserialise (full state to a byte buffer)
//
// What we DO NOT include here:
//   - Lists / Sets / SortedSets / Streams / Strings (out of MVP)
//   - RESP protocol / TCP transport (the browser has neither use case nor sockets)
//   - Lua / pub-sub / cluster
//
// Persistence is done by the Dart / JS host: it calls
// `dazzle_save_snapshot` to obtain a byte blob and writes it to OPFS;
// on startup it reads the blob back and calls `dazzle_load_snapshot`.
//
// Threading model: single-threaded. WASM in the browser is single-threaded
// by default (multi-threading needs SharedArrayBuffer + COOP/COEP headers,
// which limits deployability). For the MVP we assume one VectorIndex per
// page session and serialise access at the Dart side.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

// hnswlib is header-only C++.  See sdk/android/.../CMakeLists.txt — same
// version (v0.8.0) the iOS / Android builds consume, with the R12.b
// `searchKnnEf` overload patch applied via CMake before this file compiles.
#include "hnswlib/hnswlib.h"

#ifdef __EMSCRIPTEN__
  #include <emscripten/emscripten.h>
  #define DAZZLE_EXPORT EMSCRIPTEN_KEEPALIVE extern "C"
#else
  #define DAZZLE_EXPORT extern "C"
#endif

namespace {

// ---------------------------------------------------------------------------
// Hash KV — std::unordered_map<key, std::unordered_map<field, value>>
//
// Simple, single-threaded.  We expose plain C strings across the WASM
// boundary and copy values into the host-owned buffer; HMGET / HGETALL
// returns a NUL-separated record set so the Dart side can split it
// without needing a JSON parser.
// ---------------------------------------------------------------------------

using HashTable = std::unordered_map<std::string, std::string>;
using DB        = std::unordered_map<std::string, HashTable>;

DB g_db;

// Heap-allocated return buffer for last get-all / search call; freed on the
// next call to keep the API allocation-free for the host on the hot path.
std::vector<char> g_return_buf;

const char* return_string(const std::string& s) {
    g_return_buf.assign(s.begin(), s.end());
    g_return_buf.push_back('\0');
    return g_return_buf.data();
}

// ---------------------------------------------------------------------------
// Vector indexes — registered by name; one HierarchicalNSW per name.
// ---------------------------------------------------------------------------

struct VectorIndex {
    int dim;
    std::unique_ptr<hnswlib::L2Space> space;
    std::unique_ptr<hnswlib::HierarchicalNSW<float>> index;
    // Map external string id ↔ internal hnswlib labeltype (uint64).
    std::unordered_map<std::string, hnswlib::labeltype> id_to_label;
    std::unordered_map<hnswlib::labeltype, std::string> label_to_id;
    hnswlib::labeltype next_label = 0;
};

std::unordered_map<std::string, std::unique_ptr<VectorIndex>> g_vs;

}  // namespace

// ===========================================================================
// Hash KV API
// ===========================================================================

DAZZLE_EXPORT int dazzle_hset(const char* key, const char* field, const char* value) {
    if (!key || !field || !value) return -1;
    g_db[key][field] = value;
    return 1;
}

// Returns NULL if the key/field doesn't exist; otherwise a C string owned by
// the WASM module — valid until the next call into this library.
DAZZLE_EXPORT const char* dazzle_hget(const char* key, const char* field) {
    if (!key || !field) return nullptr;
    auto it = g_db.find(key);
    if (it == g_db.end()) return nullptr;
    auto fit = it->second.find(field);
    if (fit == it->second.end()) return nullptr;
    return return_string(fit->second);
}

DAZZLE_EXPORT int dazzle_hdel(const char* key, const char* field) {
    if (!key || !field) return 0;
    auto it = g_db.find(key);
    if (it == g_db.end()) return 0;
    return static_cast<int>(it->second.erase(field));
}

DAZZLE_EXPORT int dazzle_hexists(const char* key, const char* field) {
    if (!key || !field) return 0;
    auto it = g_db.find(key);
    if (it == g_db.end()) return 0;
    return it->second.count(field) ? 1 : 0;
}

// Returns all field/value pairs as a NUL-separated record stream:
// "field1\0value1\0field2\0value2\0".  An empty hash returns "".
// The host splits on '\0' and pairs them up.
DAZZLE_EXPORT const char* dazzle_hgetall(const char* key) {
    static thread_local std::string out;
    out.clear();
    if (!key) return return_string(out);
    auto it = g_db.find(key);
    if (it == g_db.end()) return return_string(out);
    for (const auto& [f, v] : it->second) {
        out.append(f); out.push_back('\0');
        out.append(v); out.push_back('\0');
    }
    return return_string(out);
}

DAZZLE_EXPORT int dazzle_del(const char* key) {
    if (!key) return 0;
    return static_cast<int>(g_db.erase(key));
}

// ===========================================================================
// Vector index API
// ===========================================================================

DAZZLE_EXPORT int dazzle_vs_create(const char* name, int dim, int M, int ef_construction, int initial_cap) {
    if (!name || dim <= 0) return -1;
    if (g_vs.count(name)) return 0;   // already exists, idempotent

    auto v = std::make_unique<VectorIndex>();
    v->dim   = dim;
    v->space = std::make_unique<hnswlib::L2Space>(dim);
    v->index = std::make_unique<hnswlib::HierarchicalNSW<float>>(
        v->space.get(),
        static_cast<size_t>(initial_cap > 0 ? initial_cap : 1000),
        static_cast<size_t>(M > 0 ? M : 16),
        static_cast<size_t>(ef_construction > 0 ? ef_construction : 200));
    g_vs[name] = std::move(v);
    return 1;
}

DAZZLE_EXPORT int dazzle_vs_add(const char* name, const char* id, const float* embedding) {
    if (!name || !id || !embedding) return -1;
    auto it = g_vs.find(name);
    if (it == g_vs.end()) return -2;

    auto& v = *it->second;
    auto label = v.next_label++;
    v.index->addPoint(embedding, label);
    v.id_to_label[id]   = label;
    v.label_to_id[label] = id;
    return 1;
}

// Returns the number of hits found; writes ids (as a NUL-separated stream
// into return_string buffer) and writes distances to out_dists (host-owned).
// The caller passes max_out for both ids buffer (implicit, unbounded) and
// out_dists capacity.
DAZZLE_EXPORT int dazzle_vs_search(const char* name, const float* query, int k, int ef,
                                    float* out_dists, int max_out) {
    if (!name || !query || !out_dists || max_out <= 0) return 0;
    auto it = g_vs.find(name);
    if (it == g_vs.end()) return 0;

    auto& v = *it->second;
    // Single-threaded environment, so transient setEf is safe.
    if (ef > 0) v.index->setEf(static_cast<size_t>(ef));
    auto knn = v.index->searchKnn(query, static_cast<size_t>(k));

    std::vector<std::pair<float, std::string>> results;
    while (!knn.empty()) {
        auto top = knn.top(); knn.pop();
        auto lit = v.label_to_id.find(top.second);
        if (lit != v.label_to_id.end()) results.emplace_back(top.first, lit->second);
    }
    // hnswlib returns farthest-first; reverse to closest-first.
    std::reverse(results.begin(), results.end());

    int count = std::min(static_cast<int>(results.size()), max_out);
    std::string ids;
    for (int i = 0; i < count; i++) {
        ids.append(results[i].second); ids.push_back('\0');
        out_dists[i] = results[i].first;
    }
    return_string(ids);
    return count;
}

// Returns the ID stream from the LAST search call (NUL-separated).
// Two-step API because Emscripten doesn't allow returning two pointers
// from one call cleanly.
DAZZLE_EXPORT const char* dazzle_vs_search_ids() {
    return g_return_buf.empty() ? "" : g_return_buf.data();
}

DAZZLE_EXPORT int dazzle_vs_drop(const char* name) {
    if (!name) return 0;
    return static_cast<int>(g_vs.erase(name));
}

// ===========================================================================
// Snapshot API — serialise/deserialise full state for OPFS persistence.
//
// Wire format (little-endian, all sizes uint32):
//
//   MAGIC "DZWS"        (4 bytes)
//   VERSION 1           (uint32)
//
//   --- Hash DB ---
//   n_keys              (uint32)
//   for each key:
//     key_len           (uint32)
//     key               (key_len bytes, no NUL)
//     n_fields          (uint32)
//     for each field:
//       field_len       (uint32)
//       field           (field_len bytes)
//       value_len       (uint32)
//       value           (value_len bytes)
//
//   --- Vector indexes ---
//   n_indexes           (uint32)
//   for each index:
//     name_len          (uint32)
//     name              (name_len bytes)
//     dim               (uint32)
//     hnsw_blob_len     (uint32)
//     hnsw_blob         (hnsw_blob_len bytes — hnswlib's saveIndex stream)
//     n_id_pairs        (uint32)
//     for each pair:
//       id_len          (uint32)
//       id              (id_len bytes)
//       label           (uint64)
//     next_label        (uint64)
// ===========================================================================

namespace {

void write_u32(std::vector<uint8_t>& buf, uint32_t v) {
    for (int i = 0; i < 4; i++) buf.push_back(static_cast<uint8_t>((v >> (i * 8)) & 0xff));
}
void write_u64(std::vector<uint8_t>& buf, uint64_t v) {
    for (int i = 0; i < 8; i++) buf.push_back(static_cast<uint8_t>((v >> (i * 8)) & 0xff));
}
void write_bytes(std::vector<uint8_t>& buf, const char* p, size_t n) {
    buf.insert(buf.end(), p, p + n);
}

uint32_t read_u32(const uint8_t* p) {
    return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8)
         | (static_cast<uint32_t>(p[2]) << 16) | (static_cast<uint32_t>(p[3]) << 24);
}
uint64_t read_u64(const uint8_t* p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= static_cast<uint64_t>(p[i]) << (i * 8);
    return v;
}

std::vector<uint8_t> g_snapshot_buf;

}  // namespace

DAZZLE_EXPORT int dazzle_save_snapshot(uint8_t** out_buf, int* out_len) {
    if (!out_buf || !out_len) return -1;
    g_snapshot_buf.clear();

    write_bytes(g_snapshot_buf, "DZWS", 4);
    write_u32(g_snapshot_buf, 1);  // version

    // Hash DB
    write_u32(g_snapshot_buf, static_cast<uint32_t>(g_db.size()));
    for (const auto& [key, table] : g_db) {
        write_u32(g_snapshot_buf, static_cast<uint32_t>(key.size()));
        write_bytes(g_snapshot_buf, key.data(), key.size());
        write_u32(g_snapshot_buf, static_cast<uint32_t>(table.size()));
        for (const auto& [field, value] : table) {
            write_u32(g_snapshot_buf, static_cast<uint32_t>(field.size()));
            write_bytes(g_snapshot_buf, field.data(), field.size());
            write_u32(g_snapshot_buf, static_cast<uint32_t>(value.size()));
            write_bytes(g_snapshot_buf, value.data(), value.size());
        }
    }

    // Vector indexes — hnswlib serialises via std::ostream; we capture into a
    // string-backed stream and embed it.
    write_u32(g_snapshot_buf, static_cast<uint32_t>(g_vs.size()));
    for (const auto& [name, vptr] : g_vs) {
        const auto& v = *vptr;
        write_u32(g_snapshot_buf, static_cast<uint32_t>(name.size()));
        write_bytes(g_snapshot_buf, name.data(), name.size());
        write_u32(g_snapshot_buf, static_cast<uint32_t>(v.dim));

        // hnswlib v0.8.0 only exposes saveIndex/loadIndex via filesystem
        // paths.  Emscripten's MEMFS is in-memory (default), so writing
        // here doesn't touch disk.  We round-trip through /tmp so the
        // upstream library code stays unmodified.
        std::string tmp_path = "/tmp/dazzle_save_" + name + ".bin";
        v.index->saveIndex(tmp_path);
        std::ifstream in(tmp_path, std::ios::binary);
        std::string blob((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        std::remove(tmp_path.c_str());
        write_u32(g_snapshot_buf, static_cast<uint32_t>(blob.size()));
        write_bytes(g_snapshot_buf, blob.data(), blob.size());

        write_u32(g_snapshot_buf, static_cast<uint32_t>(v.id_to_label.size()));
        for (const auto& [id, label] : v.id_to_label) {
            write_u32(g_snapshot_buf, static_cast<uint32_t>(id.size()));
            write_bytes(g_snapshot_buf, id.data(), id.size());
            write_u64(g_snapshot_buf, label);
        }
        write_u64(g_snapshot_buf, v.next_label);
    }

    *out_buf = g_snapshot_buf.data();
    *out_len = static_cast<int>(g_snapshot_buf.size());
    return 1;
}

DAZZLE_EXPORT int dazzle_load_snapshot(const uint8_t* buf, int len) {
    if (!buf || len < 8) return -1;
    if (std::memcmp(buf, "DZWS", 4) != 0) return -2;
    uint32_t version = read_u32(buf + 4);
    if (version != 1) return -3;

    // Wipe current state — load is "replace", not "merge".
    g_db.clear();
    g_vs.clear();

    const uint8_t* p   = buf + 8;
    const uint8_t* end = buf + len;
    auto need = [&](size_t n) { return static_cast<size_t>(end - p) >= n; };

    if (!need(4)) return -4;
    uint32_t n_keys = read_u32(p); p += 4;
    for (uint32_t i = 0; i < n_keys; i++) {
        if (!need(4)) return -4;
        uint32_t klen = read_u32(p); p += 4;
        if (!need(klen + 4)) return -4;
        std::string key(reinterpret_cast<const char*>(p), klen); p += klen;
        uint32_t n_fields = read_u32(p); p += 4;
        auto& table = g_db[key];
        for (uint32_t j = 0; j < n_fields; j++) {
            if (!need(4)) return -4;
            uint32_t flen = read_u32(p); p += 4;
            if (!need(flen + 4)) return -4;
            std::string field(reinterpret_cast<const char*>(p), flen); p += flen;
            uint32_t vlen = read_u32(p); p += 4;
            if (!need(vlen)) return -4;
            std::string value(reinterpret_cast<const char*>(p), vlen); p += vlen;
            table[field] = std::move(value);
        }
    }

    if (!need(4)) return -4;
    uint32_t n_idx = read_u32(p); p += 4;
    for (uint32_t i = 0; i < n_idx; i++) {
        if (!need(4)) return -4;
        uint32_t nlen = read_u32(p); p += 4;
        if (!need(nlen + 4 + 4)) return -4;
        std::string name(reinterpret_cast<const char*>(p), nlen); p += nlen;
        uint32_t dim = read_u32(p); p += 4;
        uint32_t blob_len = read_u32(p); p += 4;
        if (!need(blob_len)) return -4;

        auto v = std::make_unique<VectorIndex>();
        v->dim   = static_cast<int>(dim);
        v->space = std::make_unique<hnswlib::L2Space>(dim);
        v->index = std::make_unique<hnswlib::HierarchicalNSW<float>>(v->space.get());

        // Round-trip the blob through MEMFS so we can call loadIndex(path).
        std::string tmp_path = "/tmp/dazzle_load_" + name + ".bin";
        {
            std::ofstream out(tmp_path, std::ios::binary);
            out.write(reinterpret_cast<const char*>(p), blob_len);
        }
        p += blob_len;
        v->index->loadIndex(tmp_path, v->space.get());
        std::remove(tmp_path.c_str());

        if (!need(4)) return -4;
        uint32_t n_pairs = read_u32(p); p += 4;
        for (uint32_t j = 0; j < n_pairs; j++) {
            if (!need(4)) return -4;
            uint32_t ilen = read_u32(p); p += 4;
            if (!need(ilen + 8)) return -4;
            std::string id(reinterpret_cast<const char*>(p), ilen); p += ilen;
            uint64_t label = read_u64(p); p += 8;
            v->id_to_label[id]    = label;
            v->label_to_id[label] = id;
        }
        if (!need(8)) return -4;
        v->next_label = read_u64(p); p += 8;

        g_vs[name] = std::move(v);
    }
    return 1;
}

// Free buffer — host calls this after copying the bytes into its OPFS write.
DAZZLE_EXPORT void dazzle_snapshot_release() {
    g_snapshot_buf.clear();
    g_snapshot_buf.shrink_to_fit();
}

// ===========================================================================
// Diagnostics
// ===========================================================================

DAZZLE_EXPORT const char* dazzle_version() {
    return "dazzle-wasm 1.0.0-beta.5";
}

DAZZLE_EXPORT int dazzle_clear() {
    g_db.clear();
    g_vs.clear();
    g_snapshot_buf.clear();
    return 1;
}
