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

import XCTest
@testable import DazzleBackends

/// Data-path tests for the SQLiteAI sqlite-vector wrapper. These tests
/// exist specifically to catch the "T4/T5b/T6 cells turned out to be
/// `n/a` once we ran the device" failure mode, by validating the full
/// stack on the iOS simulator BEFORE flashing onto iPhone 12 Pro:
///
///   Swift  → SqliteVectorAiVector.create()
///        → svai_open(db_path, ext_path, dim)
///        → bundled sqlite3 sqlite3_load_extension(ext_path, "sqlite3_vector_init")
///        → vector.framework registers vector_init / vector_quantize_scan
///        → INSERT + vector_quantize + vector_quantize_scan round-trip
///
/// If any of those steps regresses, these tests fail in seconds on the
/// simulator instead of after a full device flash + bench run.
///
/// Simulator latency numbers are NOT meaningful for the paper (M-series
/// host inflates them); we only check correctness here.
final class SVaiDataPathTests: XCTestCase {

    // MARK: - Bundle wiring

    func testVectorFrameworkBundleEmbedded() {
        // Sanity check: the embed-and-sign step in project.yml
        // (DazzleBackends/dependencies → vector.xcframework, embed: true)
        // produces a vector.framework inside the host app's
        // PrivateFrameworks dir. If this assertion fails, every
        // svai_open call below also fails with "framework not found".
        let host = Bundle.main.privateFrameworksPath ?? ""
        let candidate = "\(host)/vector.framework/vector"
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate),
                      "vector.framework binary missing at \(candidate)")
    }

    // MARK: - Open / load_extension dance

    func testCreateLoadsExtensionAndRegistersVectorInit() {
        let v = SqliteVectorAiVector(dim: 16, dbName: "svai_unit_open")
        defer { v.close() }
        XCTAssertTrue(v.create(),
                      "create() must succeed: implies sqlite3_load_extension found vector.framework, " +
                      "vector_init function registered, and `emb` table created")
    }

    func testCreateIsIdempotent() {
        // Calling create() twice on the same instance must wipe the
        // db file and rebuild — this is the contract used by the
        // benchmark harness's per-N reset.
        let v = SqliteVectorAiVector(dim: 16, dbName: "svai_unit_idem")
        defer { v.close() }
        XCTAssertTrue(v.create())
        XCTAssertTrue(v.create(), "second create() must succeed too")
    }

    // MARK: - Add / finalize / knn round-trip

    func testAddAllAndKnnReturnsOrderedNeighbours() {
        let dim = 16
        let v = SqliteVectorAiVector(dim: dim, dbName: "svai_unit_knn")
        defer { v.close() }
        XCTAssertTrue(v.create())

        let n = 100
        var ids: [String] = []
        var vectors: [[Float]] = []
        for i in 0..<n {
            ids.append("id-\(i)")
            // Make the vector's first component grow with i so we have
            // a deterministic ordering: query [1,0,0,...] returns id-0
            // closest, id-1 second, etc.
            var vec = [Float](repeating: 0, count: dim)
            vec[0] = 1.0 - Float(i) * 0.01
            vec[1] = Float(i) * 0.01
            vectors.append(vec)
        }
        v.addAll(ids: ids, vectors: vectors)
        XCTAssertEqual(v.count(), Int64(n), "all \(n) rows must be in `emb`")

        XCTAssertTrue(v.finalizeIndex(),
                      "vector_quantize must succeed before scans return rows")

        var query = [Float](repeating: 0, count: dim)
        query[0] = 1.0
        let k = 5
        let results = v.search(query: query, k: k)
        XCTAssertEqual(results.count, k,
                       "search must return exactly k=\(k) results, got \(results.count)")

        // First result must be id-0 (the vector closest to query
        // along the dominant axis). Catches the rowid↔id mapping bug
        // class.
        XCTAssertEqual(results.first?.id, "id-0",
                       "nearest neighbour mapping broken; got \(results.first?.id ?? "nil")")
    }

    func testKnnBeforeFinalizeReturnsZero() {
        // Documented SQLiteAI behaviour: vector_quantize_scan returns
        // zero rows until vector_quantize has built the snapshot.
        // This test pins that contract so a regression in
        // svai_finalize_index() (e.g. silently skipped) is caught.
        let v = SqliteVectorAiVector(dim: 16, dbName: "svai_unit_prefin")
        defer { v.close() }
        XCTAssertTrue(v.create())
        v.add(id: "x", vector: [Float](repeating: 0.5, count: 16))
        // No finalizeIndex() call.
        let results = v.search(query: [Float](repeating: 0.5, count: 16), k: 5)
        XCTAssertEqual(results.count, 0,
                       "scans before finalize must return 0 rows; got \(results.count)")
    }

    // MARK: - Footprint

    func testDbFileSizeNonZeroAfterIngest() {
        let v = SqliteVectorAiVector(dim: 16, dbName: "svai_unit_size")
        defer { v.close() }
        XCTAssertTrue(v.create())
        let vecs: [[Float]] = (0..<50).map { i in
            (0..<16).map { _ in Float(i) * 0.1 }
        }
        let ids = (0..<50).map { "id-\($0)" }
        v.addAll(ids: ids, vectors: vecs)
        XCTAssertTrue(v.finalizeIndex())
        XCTAssertGreaterThan(v.dbFileSizeBytes(), 0,
                             "db file size must be > 0 after 50 ingests + finalize")
    }
}
