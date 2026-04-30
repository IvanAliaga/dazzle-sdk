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

/// sqlite-vec (SQLite-AI's `vec0` virtual table) vector search backend for the
/// iOS benchmark. Mirrors
/// experiment/backends/android/core/SqliteVecVector.kt with an identical
/// surface and behaviour so the cross-platform bench is apples-to-apples.
///
/// Storage is a brute-force scan under the hood (vec0 is linear), so recall
/// is exact by construction — the interesting number is latency vs the
/// dazzle-vector HNSW variants on the same hardware / corpus.
///
/// `SVecHandle *` is imported from the bridging header as
/// `OpaquePointer` (the struct is forward-declared opaque in the C ABI), so
/// the handle type here matches what the C shim returns.
final class SqliteVecVector {

    private let dim: Int
    private let dbPath: String
    private let normalizeOnAccess: Bool
    private var handle: OpaquePointer?

    init(dim: Int,
         dbName: String = "vecbench_sqlitevec",
         normalizeOnAccess: Bool = true) {
        self.dim = dim
        self.normalizeOnAccess = normalizeOnAccess
        // Use the app sandbox cache dir so the file survives across the
        // benchmark without polluting Documents (which we scrape for JSONs).
        let caches = FileManager.default.urls(for: .cachesDirectory,
                                              in: .userDomainMask)[0]
        self.dbPath = caches.appendingPathComponent("\(dbName).db").path
    }

    func create() {
        // Fresh run: delete any existing DB + WAL/SHM.
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")

        handle = dbPath.withCString { cpath -> OpaquePointer? in
            svec_open(cpath, Int32(dim))
        }
        if handle == nil {
            fatalError("SqliteVecVector.create(): svec_open failed — see stderr")
        }
    }

    func close() {
        if let h = handle { svec_close(h); handle = nil }
    }

    private func l2Normalize(_ v: [Float]) -> [Float] {
        var s: Float = 0
        for x in v { s += x * x }
        guard s > 1e-12 else { return v }
        let inv = 1.0 / sqrt(s)
        var out = [Float](repeating: 0, count: v.count)
        for i in 0..<v.count { out[i] = v[i] * inv }
        return out
    }

    func add(id: String, vector: [Float]) {
        precondition(vector.count == dim, "vector size \(vector.count) != dim \(dim)")
        guard let h = handle else { return }
        let v = normalizeOnAccess ? l2Normalize(vector) : vector
        v.withUnsafeBufferPointer { vp in
            id.withCString { idp in
                svec_add(h, idp, Int32(id.utf8.count),
                         vp.baseAddress, Int32(dim))
            }
        }
    }

    /// Bulk ingest wrapped in a single SQLite transaction.
    func addAll(ids: [String], vectors: [[Float]]) {
        precondition(ids.count == vectors.count, "ids and vectors must be parallel")
        guard let h = handle else { return }
        svec_begin_tx(h)
        for i in 0..<ids.count {
            add(id: ids[i], vector: vectors[i])
        }
        svec_commit_tx(h)
    }

    /// k-NN search. Returns (id, distance) pairs sorted ascending (closest first).
    func search(query: [Float], k: Int) -> [(id: String, distance: Float)] {
        precondition(query.count == dim, "query size \(query.count) != dim \(dim)")
        guard let h = handle else { return [] }

        let q = normalizeOnAccess ? l2Normalize(query) : query
        var outIds  = [UnsafeMutablePointer<CChar>?](repeating: nil, count: k)
        var outDist = [Float](repeating: 0, count: k)

        let n: Int32 = q.withUnsafeBufferPointer { qp in
            outIds.withUnsafeMutableBufferPointer { idsP in
                outDist.withUnsafeMutableBufferPointer { distsP in
                    svec_knn(h, qp.baseAddress, Int32(dim), Int32(k),
                             idsP.baseAddress, distsP.baseAddress, Int32(k))
                }
            }
        }

        var out: [(id: String, distance: Float)] = []
        out.reserveCapacity(Int(n))
        for i in 0..<Int(n) {
            if let cstr = outIds[i] {
                out.append((id: String(cString: cstr), distance: outDist[i]))
                svec_free_id(cstr)
            }
        }
        return out
    }

    func count() -> Int64 {
        guard let h = handle else { return -1 }
        return svec_count(h)
    }

    func dbFileSizeBytes() -> Int64 {
        dbPath.withCString { svec_db_file_size($0) }
    }
}
