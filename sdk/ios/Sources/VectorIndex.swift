// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import DazzleC

/// Type-safe wrapper around a dazzle-search vector index.
///
/// Mirrors `VectorIndex.kt`. Requires `.vectorSearch` in `DazzleConfig.modules`.
/// Exposes two API tiers:
///
/// - **RESP path** (`add`, `search`): uses FT.CREATE / FT.HADD / FT.SEARCH with
///   a base64 blob. Slower but integrated with the keyspace (HSET triggers
///   auto-indexing, metadata is stored in the underlying hash).
/// - **Direct fast-path** (`addDirect`, `addBatchDirect`, `searchDirect`): goes
///   straight to hnswlib via plain-C `dazzle_vs_*` helpers, skipping the
///   RESP/base64 round-trip. Identical to the Android JNI fast-path;
///   intended for hot loops (benchmarks, bulk import).
///
/// SQ8 (`hnswSq8`, `hnswSq8Rerank`) and FP16 (`hnswF16`) indexes store
/// quantised vectors inside hnswlib with NEON SDOT / FMLA-f16 distances.
/// They bypass FT.CREATE entirely — the schema lives only inside the
/// module — and therefore only support the direct fast-path.
public final class VectorIndex {

    public enum Algorithm { case flat, hnsw, hnswSq8, hnswSq8Rerank, hnswF16 }
    public enum Metric    { case cosine, l2, ip }

    public struct SearchResult {
        public let id: String
        public let score: Float
        public let fields: [String: String]
    }

    private unowned let server: DazzleServer
    public  let name: String
    public  let hashPrefix: String
    public  let vectorField: String
    public  let dim: Int
    public  let algorithm: Algorithm
    public  let metric: Metric

    /// Pre-allocated HNSW capacity. 0 = library default (1024, doubles on
    /// demand). Setting this to the final corpus size avoids every mid-
    /// traffic `resizeIndex` event (each takes the one exclusive write
    /// lock readers do fence on).
    public  let initialCapacity: Int
    /// HNSW graph degree — max number of outgoing links per node in the
    /// base layer. 0 = library default (32). Higher = higher recall,
    /// more memory, slower inserts.
    public  let m: Int
    /// HNSW build-time candidate-list width. 0 = library default (400).
    /// Lower values shrink per-insert time inside hnswlib's internal
    /// per-link locks at a small recall cost.
    public  let efConstruction: Int

    /// Cached opaque schema handle. Populated after `create()` or the
    /// first `searchDirect` — avoids the per-call name→schema hash lookup
    /// on the fast path.
    private var cachedHandle: UnsafeMutableRawPointer?

    internal init(server: DazzleServer, name: String, hashPrefix: String,
                  vectorField: String, dim: Int,
                  algorithm: Algorithm, metric: Metric,
                  initialCapacity: Int = 0,
                  m: Int = 0,
                  efConstruction: Int = 0) {
        self.server = server
        self.name = name
        self.hashPrefix = hashPrefix
        self.vectorField = vectorField
        self.dim = dim
        self.algorithm = algorithm
        self.metric = metric
        self.initialCapacity = initialCapacity
        self.m = m
        self.efConstruction = efConstruction
    }

    // MARK: – Index management

    /// FT.CREATE. Returns false (not an error) if the index already exists.
    /// For SQ8 / F16 algorithms, bypasses FT.CREATE and invokes the plain-C
    /// helper directly — no RESP round-trip. Cosine-only for those two
    /// (per-vector quantisation needs no stored scale; `l2` / `ip` require
    /// one which the current schema does not carry).
    @discardableResult
    public func create() -> Bool {
        let mArg  = Int32(m > 0 ? m : 32)
        let efArg = Int32(efConstruction > 0 ? efConstruction : 400)
        let capArg = Int32(initialCapacity)

        switch algorithm {
        case .hnswF16:
            precondition(metric == .cosine, "hnswF16 only supports Metric.cosine")
            cachedHandle = name.withCString { namePtr in
                dazzle_vs_create_f16(namePtr, Int32(dim), mArg, efArg, capArg)
            }
            return cachedHandle != nil
        case .hnswSq8, .hnswSq8Rerank:
            precondition(metric == .cosine, "\(algorithm) only supports Metric.cosine")
            let rerank: Int32 = (algorithm == .hnswSq8Rerank) ? 1 : 0
            cachedHandle = name.withCString { namePtr in
                dazzle_vs_create_sq8(namePtr, Int32(dim), mArg, efArg, capArg, rerank)
            }
            return cachedHandle != nil
        case .flat, .hnsw:
            break  // fall through to RESP FT.CREATE below
        }

        let algoStr   = algorithm == .flat ? "FLAT" : "HNSW"
        let metricStr: String
        switch metric {
        case .cosine: metricStr = "COSINE"
        case .l2:     metricStr = "L2"
        case .ip:     metricStr = "IP"
        }
        var args = [
            "FT.CREATE", name,
            "ON", "HASH",
            "PREFIX", "1", hashPrefix,
            "SCHEMA",
            vectorField, "VECTOR", algoStr,
            "6",
            "TYPE", "FLOAT32",
            "DIM", "\(dim)",
            "DISTANCE_METRIC", metricStr,
        ]
        if initialCapacity > 0 { args.append("INITIAL_CAP"); args.append("\(initialCapacity)") }
        if m > 0               { args.append("M"); args.append("\(m)") }
        if efConstruction > 0  { args.append("EF_CONSTRUCTION"); args.append("\(efConstruction)") }

        let resp = server.directArgs(args)
        if let r = resp, r.lowercased().contains("already") { return false }
        return resp != nil
    }

    /// FT.DROPINDEX (does NOT delete underlying hashes).
    @discardableResult
    public func drop() -> Bool {
        cachedHandle = nil
        // For SQ8 / F16 the index is not registered via FT.CREATE so FT.DROPINDEX
        // returns an error; try it anyway and fall through gracefully.
        return server.directArgs(["FT.DROPINDEX", name]) != nil
    }

    // MARK: – RESP-path add / search (cosine fp32 only)

    /// HSET + synchronous vector index via FT.HADD.
    public func add(id: String, vector: [Float], metadata: [String: String] = [:]) {
        precondition(vector.count == dim, "vector has \(vector.count) dims, expects \(dim)")
        let blob = toBlob(vector)
        var args = ["FT.HADD", name, id, vectorField, blob]
        for (k, v) in metadata { args.append(k); args.append(v) }
        _ = server.directArgs(args)
    }

    /// FT.SEARCH KNN — find the `k` nearest neighbours to `query`.
    /// Returns results sorted by ascending distance (score ≈ 0 is identical).
    public func search(query: [Float], k: Int = 10,
                       returnFields: [String] = []) -> [SearchResult] {
        precondition(query.count == dim, "query has \(query.count) dims, expects \(dim)")
        let blob = toBlob(query)
        let scoreAlias = "__\(vectorField)_score"

        var args = [
            "FT.SEARCH", name,
            "*=>[KNN \(k) @\(vectorField) $BLOB AS \(scoreAlias)]",
            "PARAMS", "2", "BLOB", blob,
            "SORTBY", scoreAlias,
            "DIALECT", "2",
            // Always specify RETURN so the token count per doc is predictable
            "RETURN", "\(1 + returnFields.count)", scoreAlias,
        ] + returnFields

        guard let raw = server.directArgsRaw(args) else { return [] }
        // Swift treats \r\n (CRLF) as a single Character/grapheme cluster, so
        // firstIndex(of: "\n") would not find the LF within it. Normalise to
        // bare \n so the RESP parser can split on \n correctly.
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        return parseSearchResp(normalized, scoreAlias: scoreAlias)
    }

    // MARK: – Direct fast-path (hnswlib via dazzle_vs_* helpers)

    /// Fast-path add: stores the vector directly in the HNSW index via the
    /// plain-C bridge, bypassing FT.HADD / RESP / base64. The key is NOT
    /// stored as a Valkey hash — use `add` if you also need hash metadata.
    /// Intended for hot loops (benchmarks, bulk import). Requires the
    /// index to exist (`create()`).
    public func addDirect(id: String, vector: [Float]) {
        precondition(vector.count == dim, "vector has \(vector.count) dims, index expects \(dim)")
        let keyLen = Int32(id.utf8.count)
        vector.withUnsafeBufferPointer { vecPtr in
            name.withCString { namePtr in
                id.withCString { idPtr in
                    dazzle_vs_add_direct(namePtr, idPtr, keyLen, vecPtr.baseAddress)
                }
            }
        }
    }

    /// Bulk fast-path add: one plain-C crossing for N vectors laid out
    /// contiguously as FLOAT32 little-endian. Intended for initial corpus
    /// import where the FFI overhead otherwise dominates per-vector.
    public func addBatchDirect(ids: [String], vectors: [[Float]]) {
        precondition(ids.count == vectors.count, "ids and vectors must be parallel")
        let n = ids.count
        if n == 0 { return }

        // Flatten vectors into a contiguous fp32 buffer.
        var flat = [Float]()
        flat.reserveCapacity(n * dim)
        for v in vectors {
            precondition(v.count == dim, "vector size \(v.count) != \(dim)")
            flat.append(contentsOf: v)
        }

        // Keep id bytes alive for the whole call. strdup guarantees a
        // stable pointer; the fp16/sq8 workers spawn background threads
        // and may outlive a plain withCString scope.
        var cids = [UnsafePointer<CChar>?]()
        var lens = [Int32]()
        var dupBufs = [UnsafeMutablePointer<CChar>]()
        cids.reserveCapacity(n)
        lens.reserveCapacity(n)
        dupBufs.reserveCapacity(n)
        for id in ids {
            guard let dup = strdup(id) else {
                for b in dupBufs { free(b) }
                return
            }
            dupBufs.append(dup)
            cids.append(UnsafePointer(dup))
            lens.append(Int32(id.utf8.count))
        }
        defer { for b in dupBufs { free(b) } }

        flat.withUnsafeBufferPointer { fp in
            cids.withUnsafeMutableBufferPointer { cidsP in
                lens.withUnsafeMutableBufferPointer { lensP in
                    name.withCString { namePtr in
                        dazzle_vs_add_batch_direct(
                            namePtr,
                            Int32(n),
                            cidsP.baseAddress,
                            lensP.baseAddress,
                            fp.baseAddress
                        )
                    }
                }
            }
        }
    }

    /// Fast-path search: runs HNSW KNN directly via the plain-C bridge,
    /// returning (id, distance) pairs sorted by ascending distance. No RESP
    /// encoding, no base64 — the query vector crosses as fp32 directly.
    ///
    /// Caches the opaque schema handle after the first call so subsequent
    /// hot-loop invocations skip the name→schema hash lookup.
    ///
    /// `efRuntime > 0` picks hnswlib's per-call `searchKnnEf` overload
    /// (thread-safe; no shared mutation), while `efRuntime = 0` uses the
    /// default `searchKnn`.
    public func searchDirect(query: [Float], k: Int = 10, efRuntime: Int = 0) -> [(id: String, distance: Float)] {
        precondition(query.count == dim, "query has \(query.count) dims, index expects \(dim)")
        if cachedHandle == nil {
            cachedHandle = name.withCString { namePtr in
                dazzle_vs_open_handle(namePtr)
            }
        }
        guard let h = cachedHandle else { return [] }

        var outIds  = [UnsafeMutablePointer<CChar>?](repeating: nil, count: k)
        var outDist = [Float](repeating: 0, count: k)
        let n: Int32 = query.withUnsafeBufferPointer { qp in
            outIds.withUnsafeMutableBufferPointer { idsP in
                outDist.withUnsafeMutableBufferPointer { distsP in
                    dazzle_vs_search_handle(
                        h,
                        qp.baseAddress,
                        Int32(k),
                        Int32(efRuntime),
                        idsP.baseAddress,
                        distsP.baseAddress,
                        Int32(k)
                    )
                }
            }
        }

        var results: [(id: String, distance: Float)] = []
        results.reserveCapacity(Int(n))
        for i in 0..<Int(n) {
            if let cstr = outIds[i] {
                results.append((id: String(cString: cstr), distance: outDist[i]))
                dazzle_vs_free_id(cstr)
            }
        }
        return results
    }

    // MARK: – RESP parser

    private indirect enum RV {
        case bulk(String)
        case integer(Int)
        case array([RV])
        case error(String)
        case null
    }

    private func parseResp(_ s: String, at idx: String.Index) -> (RV, String.Index)? {
        guard idx < s.endIndex else { return nil }
        let tag = s[idx]
        let next = s.index(after: idx)
        switch tag {
        case "+":
            guard let lf = s[next...].firstIndex(of: "\n") else { return nil }
            let line = String(s[next..<lf])
            return (.bulk(line), s.index(after: lf))
        case "-":
            guard let lf = s[next...].firstIndex(of: "\n") else { return nil }
            let line = String(s[next..<lf])
            return (.error(line), s.index(after: lf))
        case ":":
            guard let lf = s[next...].firstIndex(of: "\n") else { return nil }
            let line = String(s[next..<lf])
            return (.integer(Int(line) ?? 0), s.index(after: lf))
        case "$":
            guard let lf = s[next...].firstIndex(of: "\n") else { return nil }
            let lenStr = String(s[next..<lf])
            guard let len = Int(lenStr) else { return nil }
            if len == -1 { return (.null, s.index(after: lf)) }
            let start = s.index(after: lf)
            guard let end = s.index(start, offsetBy: len, limitedBy: s.endIndex) else { return nil }
            let value = String(s[start..<end])
            // Skip trailing \n (CRLF was normalized to \n)
            let afterLF = s.index(end, offsetBy: 1, limitedBy: s.endIndex) ?? end
            return (.bulk(value), afterLF)
        case "*":
            guard let lf = s[next...].firstIndex(of: "\n") else { return nil }
            let countStr = String(s[next..<lf])
            guard let count = Int(countStr) else { return nil }
            if count == -1 { return (.null, s.index(after: lf)) }
            var cur = s.index(after: lf)
            var items: [RV] = []
            for _ in 0..<count {
                guard let (child, after) = parseResp(s, at: cur) else { return nil }
                items.append(child)
                cur = after
            }
            return (.array(items), cur)
        default:
            // inline reply fallback
            guard let lf = s[idx...].firstIndex(of: "\n") else { return nil }
            let line = String(s[idx..<lf])
            return (.bulk(line), s.index(after: lf))
        }
    }

    private func parseSearchResp(_ raw: String, scoreAlias: String) -> [SearchResult] {
        guard let (rv, _) = parseResp(raw, at: raw.startIndex),
              case .array(let items) = rv,
              items.count >= 1 else { return [] }

        var results: [SearchResult] = []
        var i = 1
        while i + 1 < items.count {
            guard case .bulk(let id) = items[i] else { i += 2; continue }
            guard case .array(let fieldArr) = items[i + 1] else { i += 2; continue }
            var fields: [String: String] = [:]
            var j = 0
            while j + 1 < fieldArr.count {
                if case .bulk(let fk) = fieldArr[j], case .bulk(let fv) = fieldArr[j + 1] {
                    fields[fk] = fv
                }
                j += 2
            }
            let score = fields.removeValue(forKey: scoreAlias).flatMap(Float.init) ?? Float.greatestFiniteMagnitude
            results.append(SearchResult(id: id, score: score, fields: fields))
            i += 2
        }
        return results
    }

    // MARK: – Blob encoding

    private func toBlob(_ vec: [Float]) -> String {
        var data = Data(count: vec.count * 4)
        data.withUnsafeMutableBytes { ptr in
            let floats = ptr.bindMemory(to: Float.self)
            for (i, f) in vec.enumerated() {
                floats[i] = f   // arm64 is little-endian natively
            }
        }
        return data.base64EncodedString()
    }
}
