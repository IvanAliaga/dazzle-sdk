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
import UIKit

/// Paired vector-search benchmark: dazzle-vector (HNSW fp32 / sq8 / sq8+rerank
/// / f16) vs sqlite-vec. Uses sqlite-vec's exact cosine top-k as the recall
/// ground truth — vec0 is a linear scan in tight C so by construction
/// recall@k == 1.0 for it; HNSW recall is reported relative to it.
///
/// Mirrors experiment/backends/android/core/VectorBenchmark.kt. Sweep is the
/// same 9-config matrix so iOS numbers are directly comparable to Android.
///
/// Plain-SQLite and ObjectBox rows from the Android bench are intentionally
/// omitted here — per the project-wide decision the public comparison is
/// dazzle-* vs sqlite-vec only.
enum VectorBenchmark {

    struct Config {
        let dim: Int
        let nDocs: Int
        let nQueries: Int
        let k: Int
        let efRuntimes: [Int]
        let seed: UInt64

        init(dim: Int, nDocs: Int,
             nQueries: Int = 100, k: Int = 10,
             efRuntimes: [Int] = [10, 50, 100, 200],
             seed: UInt64 = 42) {
            self.dim = dim; self.nDocs = nDocs
            self.nQueries = nQueries; self.k = k
            self.efRuntimes = efRuntimes; self.seed = seed
        }
    }

    /// 9-config sweep that matches the Android bench.
    static let DEFAULT_CONFIGS: [Config] = [
        Config(dim: 16,  nDocs: 500),
        Config(dim: 16,  nDocs: 2_000),
        Config(dim: 16,  nDocs: 10_000),
        Config(dim: 128, nDocs: 500),
        Config(dim: 128, nDocs: 2_000),
        Config(dim: 128, nDocs: 10_000),
        Config(dim: 384, nDocs: 500),
        Config(dim: 384, nDocs: 2_000),
        Config(dim: 384, nDocs: 10_000),
    ]

    static func run(configs: [Config] = DEFAULT_CONFIGS) {
        print("[VecBench] ══ \(configs.count) configs ══")

        let deviceInfo = collectDeviceInfo()
        var allResults: [[String: Any]] = []

        // The shared Dazzle server is already started in BackendsApp.init()
        // with modules=[.vectorSearch], so FT.* and dazzle_vs_* work here.

        // Cold-start warmup — mirror the Android dance. The first FT.HADD /
        // FT.SEARCH cycle after server boot occasionally shows depressed
        // recall while the hnswlib allocator settles. One throwaway config
        // bleeds that into the discard bucket.
        print("[VecBench] ── cold-start warmup (discarded) ──")
        _ = try? runOne(
            cfg: Config(dim: 8, nDocs: 32, nQueries: 10, k: 3,
                        efRuntimes: [10]))

        for cfg in configs {
            print("[VecBench] ── cfg dim=\(cfg.dim) N=\(cfg.nDocs) ──")
            do {
                let r = try runOne(cfg: cfg)
                allResults.append(r)
            } catch {
                print("[VecBench] cfg failed: \(error)")
                allResults.append([
                    "dim":    cfg.dim,
                    "n_docs": cfg.nDocs,
                    "error":  "\(error)",
                ])
            }
        }

        // Write one aggregated JSON to Documents/.
        let out: [String: Any] = [
            "type":      "vector_benchmark",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "device":    deviceInfo,
            "configs":   allResults,
        ]
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let safeModel = deviceInfo["hw_model"] as? String ?? "iPhone"
        let safe = safeModel.replacingOccurrences(
            of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        let fname = "vecbench_\(safe)_\(ts).json"
        let docs  = FileManager.default.urls(for: .documentDirectory,
                                             in: .userDomainMask)[0]
        let url   = docs.appendingPathComponent(fname)

        guard JSONSerialization.isValidJSONObject(out) else {
            print("[VecBench] ERROR: result dict not JSON-serialisable")
            return
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: out,
                options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
            print("[VecBench] wrote \(url.path)")
        } catch {
            print("[VecBench] ERROR writing JSON: \(error)")
        }
    }

    // MARK: - Core per-config bench

    private static func runOne(cfg: Config) throws -> [String: Any] {
        var rng = LCGRandom(seed: cfg.seed)
        let docIds  = (0..<cfg.nDocs).map { "doc:\($0)" }
        var docVecs = [[Float]]()
        docVecs.reserveCapacity(cfg.nDocs)
        for _ in 0..<cfg.nDocs {
            var v = [Float](repeating: 0, count: cfg.dim)
            for i in 0..<cfg.dim { v[i] = rng.nextFloat() * 2 - 1 }
            docVecs.append(v)
        }
        let qIdxs: [Int] = (0..<cfg.nQueries).map { _ in
            Int(rng.nextUInt32()) % cfg.nDocs
        }
        let queryRaw = qIdxs.map { docVecs[$0] }

        // ── sqlite-vec (Alex Garcia, OSS brute-force — ground truth) ─────
        let sv = SqliteVecVector(dim: cfg.dim,
                                 dbName: "vecbench_sqv_d\(cfg.dim)_n\(cfg.nDocs)")
        sv.create()
        let svIngestStart = DispatchTime.now()
        sv.addAll(ids: docIds, vectors: docVecs)
        let svIngestNs = DispatchTime.now().uptimeNanoseconds
                       - svIngestStart.uptimeNanoseconds
        print("[VecBench] sqlite-vec ingest \(cfg.nDocs)×dim=\(cfg.dim): "
              + "\(svIngestNs / 1_000_000) ms")

        var svLatUs = [Int64](repeating: 0, count: cfg.nQueries)
        // truthTopK[qi] holds sqlite-vec's exact top-k (k strings, blanks padded).
        var truthTopK = Array(repeating: [String](repeating: "", count: cfg.k),
                              count: cfg.nQueries)
        for qi in 0..<cfg.nQueries {
            let q = docVecs[qIdxs[qi]]
            let t0 = DispatchTime.now()
            let res = sv.search(query: q, k: cfg.k)
            svLatUs[qi] = Int64((DispatchTime.now().uptimeNanoseconds
                                 - t0.uptimeNanoseconds) / 1_000)
            for j in 0..<cfg.k {
                truthTopK[qi][j] = j < res.count ? res[j].id : ""
            }
        }
        let svFileBytes = sv.dbFileSizeBytes()
        sv.close()
        let sqliteVecDefault: [String: Any] = [
            "algorithm_class": "linear_scan",
            "variant": "default",
            "normalize_on_access": true,
            "ingest_total_ms": (svIngestNs / 1_000_000),
            "ingest_avg_us":   Double(svIngestNs) / 1_000.0 / Double(cfg.nDocs),
            "recall_at_k":     1.0, // ground truth by construction
            "search_lat_us":   latencyStats(svLatUs),
            "db_file_bytes":   svFileBytes,
        ]

        let docNorm = docVecs.map(l2Normalize)
        let queryNorm = queryRaw.map(l2Normalize)
        let sqliteVecOptimized = runSqliteVecVariant(
            cfg: cfg,
            variant: "optimized",
            normalizeOnAccess: false,
            extraWarmup: 0,
            ids: docIds,
            docs: docNorm,
            queries: queryNorm,
            truthTopK: truthTopK
        )
        let sqliteVecPrecompute = runSqliteVecVariant(
            cfg: cfg,
            variant: "precompute",
            normalizeOnAccess: false,
            extraWarmup: max(cfg.nQueries, 100),
            ids: docIds,
            docs: docNorm,
            queries: queryNorm,
            truthTopK: truthTopK
        )

        // ── sqlite-vector-ai variants (default / optimized / precompute) ──
        let sqliteAiDefault = runSqliteVectorAiVariant(
            cfg: cfg,
            variant: "default",
            quantizeMemoryMb: 16,
            preload: false,
            ids: docIds,
            docs: docNorm,
            queries: queryNorm,
            truthTopK: truthTopK
        )
        let sqliteAiOptimized = runSqliteVectorAiVariant(
            cfg: cfg,
            variant: "optimized",
            quantizeMemoryMb: 50,
            preload: false,
            ids: docIds,
            docs: docNorm,
            queries: queryNorm,
            truthTopK: truthTopK
        )
        let sqliteAiPrecompute = runSqliteVectorAiVariant(
            cfg: cfg,
            variant: "precompute",
            quantizeMemoryMb: 50,
            preload: true,
            ids: docIds,
            docs: docNorm,
            queries: queryNorm,
            truthTopK: truthTopK
        )

        // ── dazzle HNSW fp32 ─────────────────────────────────────────────
        // `vectorIndex(...)` lives on DazzleServer directly — not on the
        // `Dazzle` client facade (which only has K/V primitives).
        let idx = DazzleServer.shared.vectorIndex(
            name:        "bench_d\(cfg.dim)_n\(cfg.nDocs)",
            hashPrefix:  "vb:d\(cfg.dim)n\(cfg.nDocs):",
            vectorField: "emb",
            dim:         cfg.dim,
            algorithm:   .hnsw,
            metric:      .cosine
        )
        guard idx.create() else { throw BenchError.createFailed("hnsw") }
        let dzIds = (0..<cfg.nDocs).map { "vb:d\(cfg.dim)n\(cfg.nDocs):\($0)" }

        let dzIngestStart = DispatchTime.now()
        idx.addBatchDirect(ids: dzIds, vectors: docVecs)
        let dzIngestNs = DispatchTime.now().uptimeNanoseconds
                       - dzIngestStart.uptimeNanoseconds
        print("[VecBench] dazzle-hnsw ingest \(cfg.nDocs)×dim=\(cfg.dim): "
              + "\(dzIngestNs / 1_000_000) ms")

        let dzByEf = sweepEf(idx: idx, cfg: cfg,
                             docVecs: docVecs, qIdxs: qIdxs,
                             truthTopK: truthTopK,
                             hashPrefix: "vb:d\(cfg.dim)n\(cfg.nDocs):",
                             label: "hnsw")

        // ── dazzle HNSW_SQ8 (int8 + NEON SDOT) ───────────────────────────
        let idxQ = DazzleServer.shared.vectorIndex(
            name:        "benchq_d\(cfg.dim)_n\(cfg.nDocs)",
            hashPrefix:  "vbq:d\(cfg.dim)n\(cfg.nDocs):",
            vectorField: "emb",
            dim:         cfg.dim,
            algorithm:   .hnswSq8,
            metric:      .cosine
        )
        guard idxQ.create() else { throw BenchError.createFailed("hnswSq8") }
        let dzQIds = (0..<cfg.nDocs).map { "vbq:d\(cfg.dim)n\(cfg.nDocs):\($0)" }

        let dzQIngestStart = DispatchTime.now()
        idxQ.addBatchDirect(ids: dzQIds, vectors: docVecs)
        let dzQIngestNs = DispatchTime.now().uptimeNanoseconds
                        - dzQIngestStart.uptimeNanoseconds
        print("[VecBench] dazzle-sq8 ingest \(cfg.nDocs)×dim=\(cfg.dim): "
              + "\(dzQIngestNs / 1_000_000) ms")

        let dzQByEf = sweepEf(idx: idxQ, cfg: cfg,
                              docVecs: docVecs, qIdxs: qIdxs,
                              truthTopK: truthTopK,
                              hashPrefix: "vbq:d\(cfg.dim)n\(cfg.nDocs):",
                              label: "sq8")

        // ── dazzle HNSW_SQ8_RERANK (sq8 scan + fp32 rescore) ─────────────
        let idxR = DazzleServer.shared.vectorIndex(
            name:        "benchr_d\(cfg.dim)_n\(cfg.nDocs)",
            hashPrefix:  "vbr:d\(cfg.dim)n\(cfg.nDocs):",
            vectorField: "emb",
            dim:         cfg.dim,
            algorithm:   .hnswSq8Rerank,
            metric:      .cosine
        )
        guard idxR.create() else { throw BenchError.createFailed("hnswSq8Rerank") }
        let dzRIds = (0..<cfg.nDocs).map { "vbr:d\(cfg.dim)n\(cfg.nDocs):\($0)" }

        let dzRIngestStart = DispatchTime.now()
        idxR.addBatchDirect(ids: dzRIds, vectors: docVecs)
        let dzRIngestNs = DispatchTime.now().uptimeNanoseconds
                        - dzRIngestStart.uptimeNanoseconds
        print("[VecBench] dazzle-sq8-rerank ingest \(cfg.nDocs)×dim=\(cfg.dim): "
              + "\(dzRIngestNs / 1_000_000) ms")

        let dzRByEf = sweepEf(idx: idxR, cfg: cfg,
                              docVecs: docVecs, qIdxs: qIdxs,
                              truthTopK: truthTopK,
                              hashPrefix: "vbr:d\(cfg.dim)n\(cfg.nDocs):",
                              label: "sq8-rerank")

        // ── dazzle HNSW_F16 (half-precision storage) ─────────────────────
        let idxH = DazzleServer.shared.vectorIndex(
            name:        "benchh_d\(cfg.dim)_n\(cfg.nDocs)",
            hashPrefix:  "vbh:d\(cfg.dim)n\(cfg.nDocs):",
            vectorField: "emb",
            dim:         cfg.dim,
            algorithm:   .hnswF16,
            metric:      .cosine
        )
        guard idxH.create() else { throw BenchError.createFailed("hnswF16") }
        let dzHIds = (0..<cfg.nDocs).map { "vbh:d\(cfg.dim)n\(cfg.nDocs):\($0)" }

        let dzHIngestStart = DispatchTime.now()
        idxH.addBatchDirect(ids: dzHIds, vectors: docVecs)
        let dzHIngestNs = DispatchTime.now().uptimeNanoseconds
                        - dzHIngestStart.uptimeNanoseconds
        print("[VecBench] dazzle-f16 ingest \(cfg.nDocs)×dim=\(cfg.dim): "
              + "\(dzHIngestNs / 1_000_000) ms")

        let dzHByEf = sweepEf(idx: idxH, cfg: cfg,
                              docVecs: docVecs, qIdxs: qIdxs,
                              truthTopK: truthTopK,
                              hashPrefix: "vbh:d\(cfg.dim)n\(cfg.nDocs):",
                              label: "f16")

        return [
            "dim":       cfg.dim,
            "n_docs":    cfg.nDocs,
            "n_queries": cfg.nQueries,
            "k":         cfg.k,
            "sqlite_vec": sqliteVecDefault,
            "sqlite_vec_default": sqliteVecDefault,
            "sqlite_vec_optimized": sqliteVecOptimized,
            "sqlite_vec_precompute": sqliteVecPrecompute,
            "sqlite_vector_ai": sqliteAiDefault,
            "sqlite_vector_ai_default": sqliteAiDefault,
            "sqlite_vector_ai_optimized": sqliteAiOptimized,
            "sqlite_vector_ai_precompute": sqliteAiPrecompute,
            "dazzle_hnsw": [
                "ingest_total_ms": (dzIngestNs / 1_000_000),
                "ingest_avg_us":   Double(dzIngestNs) / 1_000.0 / Double(cfg.nDocs),
                "by_ef":           dzByEf,
            ],
            "dazzle_sq8": [
                "ingest_total_ms": (dzQIngestNs / 1_000_000),
                "ingest_avg_us":   Double(dzQIngestNs) / 1_000.0 / Double(cfg.nDocs),
                "by_ef":           dzQByEf,
            ],
            "dazzle_sq8_rerank": [
                "ingest_total_ms": (dzRIngestNs / 1_000_000),
                "ingest_avg_us":   Double(dzRIngestNs) / 1_000.0 / Double(cfg.nDocs),
                "by_ef":           dzRByEf,
            ],
            "dazzle_f16": [
                "ingest_total_ms": (dzHIngestNs / 1_000_000),
                "ingest_avg_us":   Double(dzHIngestNs) / 1_000.0 / Double(cfg.nDocs),
                "by_ef":           dzHByEf,
            ],
        ]
    }

    // MARK: - Per-ef sweep

    private static func sweepEf(idx: VectorIndex, cfg: Config,
                                docVecs: [[Float]], qIdxs: [Int],
                                truthTopK: [[String]],
                                hashPrefix: String,
                                label: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for ef in cfg.efRuntimes {
            var lat = [Int64](repeating: 0, count: cfg.nQueries)
            var hits = 0, totalPairs = 0
            for qi in 0..<cfg.nQueries {
                let q = docVecs[qIdxs[qi]]
                let t0 = DispatchTime.now()
                let res = idx.searchDirect(query: q, k: cfg.k, efRuntime: ef)
                lat[qi] = Int64((DispatchTime.now().uptimeNanoseconds
                                 - t0.uptimeNanoseconds) / 1_000)

                let dzSet = Set(res.map { $0.id })
                let truthSet = Set(truthTopK[qi].filter { !$0.isEmpty }.map { sq -> String in
                    // sqlite id "doc:N" → dazzle id "<prefix>N"
                    let n = sq.replacingOccurrences(of: "doc:", with: "")
                    return "\(hashPrefix)\(n)"
                })
                hits += dzSet.intersection(truthSet).count
                totalPairs += truthSet.count
            }
            let recall = totalPairs > 0 ? Double(hits) / Double(totalPairs) : 0.0
            out.append([
                "ef_runtime":    ef,
                "recall_at_k":   recall,
                "search_lat_us": latencyStats(lat),
            ])
            let ls = latencyStats(lat)
            let p50 = ls["p50"] ?? 0, p95 = ls["p95"] ?? 0
            print("[VecBench]   \(label) ef=\(ef) recall@\(cfg.k)=\(String(format: "%.4f", recall))"
                  + "  p50=\(p50)µs p95=\(p95)µs")
        }
        return out
    }

    // MARK: - Helpers

    private static func runSqliteVecVariant(
        cfg: Config,
        variant: String,
        normalizeOnAccess: Bool,
        extraWarmup: Int,
        ids: [String],
        docs: [[Float]],
        queries: [[Float]],
        truthTopK: [[String]]
    ) -> [String: Any] {
        let safeVariant = variant.replacingOccurrences(of: "[^A-Za-z0-9_]",
                                                       with: "_",
                                                       options: .regularExpression)
        let sv = SqliteVecVector(
            dim: cfg.dim,
            dbName: "vecbench_sqv_\(safeVariant)_d\(cfg.dim)_n\(cfg.nDocs)",
            normalizeOnAccess: normalizeOnAccess
        )
        sv.create()
        let ingestStart = DispatchTime.now()
        sv.addAll(ids: ids, vectors: docs)
        let ingestNs = DispatchTime.now().uptimeNanoseconds
                     - ingestStart.uptimeNanoseconds

        let warmups = min(cfg.nQueries, max(20 + extraWarmup, 20))
        for qi in 0..<warmups {
            _ = sv.search(query: queries[qi], k: cfg.k)
        }

        var latUs = [Int64](repeating: 0, count: cfg.nQueries)
        var hits = 0
        var total = 0
        for qi in 0..<cfg.nQueries {
            let t0 = DispatchTime.now()
            let res = sv.search(query: queries[qi], k: cfg.k)
            latUs[qi] = Int64((DispatchTime.now().uptimeNanoseconds
                               - t0.uptimeNanoseconds) / 1_000)
            let set = Set(res.map { $0.id })
            let truth = Set(truthTopK[qi].filter { !$0.isEmpty })
            hits += set.intersection(truth).count
            total += truth.count
        }
        let recall = total > 0 ? Double(hits) / Double(total) : 0.0
        let fileBytes = sv.dbFileSizeBytes()
        sv.close()

        print("[VecBench] sqlite-vec/\(variant) p50=\(latencyStats(latUs)["p50"] ?? 0)µs recall=\(String(format: "%.4f", recall))")
        return [
            "algorithm_class": "linear_scan",
            "variant": variant,
            "normalize_on_access": normalizeOnAccess,
            "recall_at_k": recall,
            "ingest_total_ms": (ingestNs / 1_000_000),
            "ingest_avg_us": Double(ingestNs) / 1_000.0 / Double(cfg.nDocs),
            "search_lat_us": latencyStats(latUs),
            "db_file_bytes": fileBytes,
        ]
    }

    private static func runSqliteVectorAiVariant(
        cfg: Config,
        variant: String,
        quantizeMemoryMb: Int,
        preload: Bool,
        ids: [String],
        docs: [[Float]],
        queries: [[Float]],
        truthTopK: [[String]]
    ) -> [String: Any] {
        let safeVariant = variant.replacingOccurrences(of: "[^A-Za-z0-9_]",
                                                       with: "_",
                                                       options: .regularExpression)
        let svai = SqliteVectorAiVector(
            dim: cfg.dim,
            dbName: "vecbench_svai_\(safeVariant)_d\(cfg.dim)_n\(cfg.nDocs)"
        )
        guard svai.create() else {
            return [
                "skipped": true,
                "variant": variant,
                "reason": "create failed (vector extension not available on this iOS build)",
            ]
        }

        let ingestStart = DispatchTime.now()
        svai.addAll(ids: ids, vectors: docs)
        guard svai.finalizeIndex(maxMemoryMb: quantizeMemoryMb, preload: preload) else {
            svai.close()
            return [
                "skipped": true,
                "variant": variant,
                "reason": "vector_quantize/finalize failed on this iOS build",
            ]
        }
        let ingestNs = DispatchTime.now().uptimeNanoseconds
                     - ingestStart.uptimeNanoseconds

        let warmups = min(cfg.nQueries, 20)
        for qi in 0..<warmups {
            _ = svai.search(query: queries[qi], k: cfg.k)
        }

        var latUs = [Int64](repeating: 0, count: cfg.nQueries)
        var hits = 0
        var total = 0
        for qi in 0..<cfg.nQueries {
            let t0 = DispatchTime.now()
            let res = svai.search(query: queries[qi], k: cfg.k)
            latUs[qi] = Int64((DispatchTime.now().uptimeNanoseconds
                               - t0.uptimeNanoseconds) / 1_000)
            let set = Set(res.map { $0.id })
            let truth = Set(truthTopK[qi].filter { !$0.isEmpty })
            hits += set.intersection(truth).count
            total += truth.count
        }
        let recall = total > 0 ? Double(hits) / Double(total) : 0.0
        let fileBytes = svai.dbFileSizeBytes()
        svai.close()

        print("[VecBench] sqlite-vector-ai/\(variant) p50=\(latencyStats(latUs)["p50"] ?? 0)µs recall=\(String(format: "%.4f", recall))")
        return [
            "algorithm_class": "quantized_linear_scan",
            "variant": variant,
            "quantize_memory_mb": quantizeMemoryMb,
            "preload": preload,
            "recall_at_k": recall,
            "ingest_total_ms": (ingestNs / 1_000_000),
            "ingest_avg_us": Double(ingestNs) / 1_000.0 / Double(cfg.nDocs),
            "search_lat_us": latencyStats(latUs),
            "db_file_bytes": fileBytes,
        ]
    }

    private static func l2Normalize(_ v: [Float]) -> [Float] {
        var s: Float = 0
        for x in v { s += x * x }
        if s <= 1e-12 { return v }
        let inv = 1.0 / sqrt(s)
        var out = [Float](repeating: 0, count: v.count)
        for i in 0..<v.count { out[i] = v[i] * inv }
        return out
    }

    private static func latencyStats(_ vs: [Int64]) -> [String: Int64] {
        guard !vs.isEmpty else { return [:] }
        let sorted = vs.sorted()
        func pct(_ p: Double) -> Int64 {
            sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)]
        }
        return [
            "n":   Int64(sorted.count),
            "avg": Int64(sorted.reduce(0, +) / Int64(sorted.count)),
            "p50": pct(0.50),
            "p95": pct(0.95),
            "p99": pct(0.99),
            "min": sorted.first ?? 0,
            "max": sorted.last  ?? 0,
        ]
    }

    private static func collectDeviceInfo() -> [String: Any] {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { bytes in
            String(bytes: bytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
        }
        let pi = ProcessInfo.processInfo
        return [
            "hw_model":      machine,             // e.g. "iPhone13,3" for 12 Pro
            "model":         UIDevice.current.model,
            "name":          UIDevice.current.name,
            "systemName":    UIDevice.current.systemName,
            "systemVersion": UIDevice.current.systemVersion,
            "platform":      "iOS",
            "cpu_cores":     NSNumber(value: pi.processorCount),
            "active_cpu_cores": NSNumber(value: pi.activeProcessorCount),
            "ram_total_bytes": NSNumber(value: pi.physicalMemory),
        ]
    }

    enum BenchError: Error {
        case createFailed(String)
    }
}

// MARK: - LCG

private struct LCGRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x4d595df4d0f33173 : seed }

    mutating func nextUInt32() -> UInt32 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt32(state >> 33)
    }
    mutating func nextFloat() -> Float {
        Float(nextUInt32()) / Float(UInt32.max)
    }
}
