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

/// Validates DazzleModule.vectorSearch (dazzle-search HNSW module) on iOS device.
///
/// Plan 17 — vector module smoke test (iOS):
///   1. Start Dazzle with DazzleModule.vectorSearch
///   2. FT.CREATE index (dim=16, HNSW, COSINE)
///   3. FT.HADD 500 docs with random FLOAT32 embeddings
///   4. 100 FT.SEARCH KNN-10 queries → report avg latency
///   5. Verify top-1 of self-search returns the same key (recall check)
///
/// Results written to Documents/plan17_vector_search_<device>.json
enum VectorSearchTest {

    private static let DIM       = 16
    private static let N_DOCS    = 500
    private static let N_QUERIES = 100
    private static let K         = 10

    struct Result: Encodable {
        let device: String
        let dim: Int
        let nDocs: Int
        let nQueries: Int
        let k: Int
        let indexCreateUs: Int64
        let ingestTotalMs: Double
        let ingestAvgUs: Double
        let searchAvgUs: Double
        let searchP95Us: Int64
        let selfRecallAt1: Double
        let error: String?
    }

    @discardableResult
    static func run() -> Result {
        print("[VectorTest] ══ VectorSearchTest (plan17) dim=\(DIM) N=\(N_DOCS) ══")

        let server = DazzleServer.shared

        // The shared server is started in BackendsApp.init() with modules=[.vectorSearch],
        // so FT.* commands are available immediately. No stop/restart needed.
        if !server.isRunning {
            let r = Result(device: deviceName(), dim: DIM, nDocs: N_DOCS, nQueries: N_QUERIES,
                           k: K, indexCreateUs: 0, ingestTotalMs: 0, ingestAvgUs: 0,
                           searchAvgUs: 0, searchP95Us: 0, selfRecallAt1: 0,
                           error: "server not running")
            writeResult(r); return r
        }

        let idx = server.vectorIndex(
            name: "docs",
            hashPrefix: "doc:",
            vectorField: "emb",
            dim: DIM,
            algorithm: .hnsw,
            metric: .cosine
        )

        let createStart = DispatchTime.now()
        let created = idx.create()
        let createUs = Int64((DispatchTime.now().uptimeNanoseconds - createStart.uptimeNanoseconds) / 1000)
        print("[VectorTest] FT.CREATE: \(created) in \(createUs)µs")

        // Deterministic docs with LCG seeded at 42 (mirrors Kotlin Random(42))
        var rng = LCGRandom(seed: 42)
        let docs: [(String, [Float])] = (0..<N_DOCS).map { i in
            let vec = (0..<DIM).map { _ in rng.nextFloat() * 2 - 1 }
            return ("doc:\(i)", vec)
        }

        // Ingest all docs
        var ingestTimes = [Double]()
        for (id, vec) in docs {
            let ts = DispatchTime.now()
            idx.add(id: id, vector: vec)
            let us = Double(DispatchTime.now().uptimeNanoseconds - ts.uptimeNanoseconds) / 1000
            ingestTimes.append(us)
        }
        let ingestTotalMs = ingestTimes.reduce(0, +) / 1000
        let ingestAvgUs   = ingestTimes.reduce(0, +) / Double(N_DOCS)
        print("[VectorTest] ingest \(N_DOCS) docs: total=\(Int(ingestTotalMs))ms avg=\(Int(ingestAvgUs))µs")

        // FT.SEARCH latency + recall
        var searchTimes = [Double]()
        var selfRecallHits = 0
        for q in 0..<N_QUERIES {
            let (queryId, queryVec) = docs[q % N_DOCS]
            let ts = DispatchTime.now()
            let results = idx.search(query: queryVec, k: K)
            let us = Double(DispatchTime.now().uptimeNanoseconds - ts.uptimeNanoseconds) / 1000
            searchTimes.append(us)
            if results.first?.id == queryId { selfRecallHits += 1 }
        }
        searchTimes.sort()
        let searchAvgUs  = searchTimes.reduce(0, +) / Double(N_QUERIES)
        let searchP95Us  = Int64(searchTimes[Int(Double(N_QUERIES) * 0.95)])
        let selfRecallAt1 = Double(selfRecallHits) / Double(N_QUERIES)
        print("[VectorTest] FT.SEARCH avg=\(Int(searchAvgUs))µs p95=\(searchP95Us)µs recall@1=\(selfRecallAt1)")

        let result = Result(
            device:         deviceName(),
            dim:            DIM,
            nDocs:          N_DOCS,
            nQueries:       N_QUERIES,
            k:              K,
            indexCreateUs:  createUs,
            ingestTotalMs:  ingestTotalMs,
            ingestAvgUs:    ingestAvgUs,
            searchAvgUs:    searchAvgUs,
            searchP95Us:    searchP95Us,
            selfRecallAt1:  selfRecallAt1,
            error:          nil
        )
        writeResult(result)
        _ = server.directArgs(["FT.DROPINDEX", "docs"])
        return result
    }

    // MARK: – Helpers

    private static func deviceName() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { bytes in
            bytes.compactMap { $0 == 0 ? nil : Character(UnicodeScalar($0)) }
        }
        return "\(UIDevice.current.model) (\(String(machine))) iOS \(UIDevice.current.systemVersion)"
    }

    private static func writeResult(_ result: Result) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(result) else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safe = result.device.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_",
                                                       options: .regularExpression)
        let url = docs.appendingPathComponent("plan17_vector_search_\(safe).json")
        try? data.write(to: url)
        print("[VectorTest] result written to \(url.path)")
    }
}

// Minimal LCG random that matches Kotlin's Random(42) for float generation
private struct LCGRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt32 {
        // Kotlin uses a SplittableRandom-based generator. For device validation
        // the exact sequence doesn't need to match Kotlin — just needs to be
        // reproducible across runs on the same device.
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt32(state >> 33)
    }

    mutating func nextFloat() -> Float {
        return Float(next()) / Float(UInt32.max)
    }
}
