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

/// Benchmark wrapper around the SQLiteAI `sqlite-vector` extension on iOS.
/// Mirrors experiment/backends/android/core/SqliteVectorAiVector.kt so
/// the cross-platform vector bench runs the exact same per-query shape on
/// both platforms (ingest → vector_quantize → vector_quantize_scan).
///
/// The extension binary is Elastic License 2.0 — benchmark-only, never
/// distributed inside the dazzle SDK. This file + the sqlitevectorai/
/// bridge are only compiled into the DazzleBackends experiment target.
final class SqliteVectorAiVector {

    private let dim: Int
    private let dbPath: String
    private var handle: OpaquePointer?
    // String id ↔ integer rowid mapping. `add(id:vector:)` takes a string
    // so the bench's recall comparison sees the same id space the other
    // backends return. sqlite-vector expects an INTEGER PRIMARY KEY, so we
    // keep a parallel array and translate back on search.
    private var idToRowid: [String: Int64] = [:]
    private var rowidToId: [String] = []

    init(dim: Int, dbName: String = "vecbench_sqlvectorai") {
        self.dim = dim
        let caches = FileManager.default.urls(for: .cachesDirectory,
                                              in: .userDomainMask)[0]
        self.dbPath = caches.appendingPathComponent("\(dbName).db").path
    }

    /// Path to the embedded vector.framework binary. The bundled
    /// (vendored) sqlite3 inside svai_ios.c calls `sqlite3_load_extension`
    /// with this absolute path; iOS resolves it via dlopen at runtime.
    /// Returns nil if the framework was not embedded — that is a config
    /// bug, not a runtime fallback path; callers should treat it as a
    /// hard skip of the SqliteVectorAi bench leg.
    private static func extensionBinaryPath() -> String? {
        // PrivateFrameworks dir is where Xcode embeds vector.xcframework
        // for `embed: true, codeSign: true`. On both device and simulator
        // bundles the Mach-O lives at <Frameworks>/vector.framework/vector.
        guard let fwBase = Bundle.main.privateFrameworksPath else {
            return nil
        }
        let candidate = "\(fwBase)/vector.framework/vector"
        guard FileManager.default.fileExists(atPath: candidate) else {
            return nil
        }
        return candidate
    }

    /// Returns true on success, false if the SQLiteAI extension couldn't
    /// be loaded. The most common failures here are (a) vector.framework
    /// not embedded into the bundle, or (b) the bundled sqlite3
    /// translation unit failed to compile in `SQLITE_ENABLE_LOAD_EXTENSION`
    /// mode — both are config bugs caught at first run, not transient.
    @discardableResult
    func create() -> Bool {
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: dbPath + "-wal")
        try? FileManager.default.removeItem(atPath: dbPath + "-shm")
        idToRowid.removeAll()
        rowidToId.removeAll()

        guard let extPath = Self.extensionBinaryPath() else {
            print("[svai] vector.framework binary not found in app bundle")
            return false
        }

        handle = dbPath.withCString { cdb -> OpaquePointer? in
            extPath.withCString { cext -> OpaquePointer? in
                svai_open(cdb, cext, Int32(dim))
            }
        }
        return handle != nil
    }

    func close() {
        if let h = handle { svai_close(h); handle = nil }
    }

    func add(id: String, vector: [Float]) {
        precondition(vector.count == dim, "vector size \(vector.count) != dim \(dim)")
        guard let h = handle else { return }
        // SQLite rowid is 1-indexed. Using size+1 keeps inserts monotonic
        // which helps the vector_quantize snapshot be stable.
        let rowid = Int64(rowidToId.count) + 1
        vector.withUnsafeBufferPointer { vp in
            svai_add(h, rowid, vp.baseAddress, Int32(dim))
        }
        idToRowid[id] = rowid
        rowidToId.append(id)
    }

    /// Bulk ingest wrapped in a single SQLite transaction, then builds the
    /// quantized snapshot via `vector_quantize` — mandatory before any
    /// search per SQLiteAI API.md.
    func addAll(ids: [String], vectors: [[Float]]) {
        precondition(ids.count == vectors.count,
                     "ids and vectors must be parallel")
        guard let h = handle else { return }
        svai_begin_tx(h)
        for i in 0..<ids.count {
            add(id: ids[i], vector: vectors[i])
        }
        svai_commit_tx(h)
    }

    /// Build the quantized snapshot. MUST be called after the last `add` /
    /// `addAll` and before the first `search`; without it
    /// `vector_quantize_scan` returns zero rows.
    @discardableResult
    func finalizeIndex(maxMemoryMb: Int = 50, preload: Bool = true) -> Bool {
        guard let h = handle else { return false }
        let rc = svai_finalize_index_ex(h, Int32(maxMemoryMb), preload ? 1 : 0)
        if rc != 0 {
            print("[svai] vector_quantize failed rc=\(rc)")
            return false
        }
        return true
    }

    /// k-NN scan. Returns (id, distance) pairs sorted ascending.
    func search(query: [Float], k: Int) -> [(id: String, distance: Float)] {
        precondition(query.count == dim, "query size \(query.count) != dim \(dim)")
        guard let h = handle else { return [] }

        var outRowids = [Int64](repeating: 0, count: k)
        var outDists  = [Float](repeating: 0, count: k)

        let n: Int32 = query.withUnsafeBufferPointer { qp in
            outRowids.withUnsafeMutableBufferPointer { idsP in
                outDists.withUnsafeMutableBufferPointer { distsP in
                    svai_knn(h, qp.baseAddress, Int32(dim), Int32(k),
                             idsP.baseAddress, distsP.baseAddress, Int32(k))
                }
            }
        }

        var out: [(id: String, distance: Float)] = []
        out.reserveCapacity(Int(n))
        for i in 0..<Int(n) {
            let rowid = outRowids[i]
            let idx = Int(rowid - 1)
            if idx >= 0 && idx < rowidToId.count {
                out.append((id: rowidToId[idx], distance: outDists[i]))
            }
        }
        return out
    }

    func count() -> Int64 {
        guard let h = handle else { return -1 }
        return svai_count(h)
    }

    func dbFileSizeBytes() -> Int64 {
        dbPath.withCString { svai_db_file_size($0) }
    }
}
