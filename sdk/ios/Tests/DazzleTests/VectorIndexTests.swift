// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import XCTest
@testable import Dazzle

/// Requires DazzleModule.vectorSearch. Tests skip automatically via
/// XCTSkip in DazzleTestCase when the module isn't shipped.
final class VectorIndexTests: DazzleTestCase {

    override class var modules: Set<DazzleModule> { [.lua, .vectorSearch] }

    private func makeFlatIndex() -> VectorIndex {
        let idx = DazzleServer.shared.vectorIndex(
            name: "t_flat",
            hashPrefix: "vf:",
            dim: 4,
            algorithm: .flat,
            metric: .l2
        )
        _ = idx.create()
        return idx
    }

    func testAddAndSearchFindsNearestNeighbor() throws {
        let idx = makeFlatIndex()
        idx.add(id: "vf:1", vector: [1, 0, 0, 0])
        idx.add(id: "vf:2", vector: [0, 1, 0, 0])
        idx.add(id: "vf:3", vector: [0, 0, 1, 0])
        let hits = idx.search(query: [0.9, 0.1, 0, 0], k: 2)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.first?.id, "vf:1")
    }

    func testSearchReturnsScoresAscending() throws {
        let idx = makeFlatIndex()
        idx.add(id: "vf:a", vector: [0, 0, 0, 0])
        idx.add(id: "vf:b", vector: [10, 0, 0, 0])
        idx.add(id: "vf:c", vector: [20, 0, 0, 0])
        let hits = idx.search(query: [0, 0, 0, 0], k: 3)
        XCTAssertEqual(hits.map { $0.id }, ["vf:a", "vf:b", "vf:c"])
        for i in 1..<hits.count {
            XCTAssertLessThanOrEqual(hits[i - 1].score, hits[i].score)
        }
    }

    func testSearchWithMetadataStoresAndReturnsId() throws {
        // The iOS xcframework's FT.SEARCH RESP parser currently only surfaces
        // the score field via `returnFields:`; downstream metadata fields
        // round-trip via HGETALL in the experiment code rather than through
        // SearchResult.fields. Until that lands here we only assert the
        // stored item is retrievable by its id.
        let idx = makeFlatIndex()
        idx.add(id: "vf:10", vector: [1, 0, 0, 0], metadata: ["tag": "A"])
        idx.add(id: "vf:11", vector: [0, 1, 0, 0], metadata: ["tag": "B"])
        let hits = idx.search(query: [1, 0, 0, 0], k: 1)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, "vf:10")
    }

    func testDropRemovesTheIndex() throws {
        let idx = makeFlatIndex()
        XCTAssertTrue(idx.drop())
    }

    // MARK: – Fast-path parity with Android

    /// The plain-C fast path exposes addDirect/searchDirect mirror of the
    /// Android JNI entry points. Here we exercise them on an HNSW cosine
    /// index so the NEON simsimd kernels participate.
    func testAddDirectAndSearchDirect() throws {
        let idx = DazzleServer.shared.vectorIndex(
            name: "t_hnsw_direct",
            hashPrefix: "vd:",
            dim: 4,
            algorithm: .hnsw,
            metric: .cosine
        )
        // Drop any stale schema from a previous run — flushDb does not clear
        // module-owned index metadata on iOS either.
        _ = idx.drop()
        XCTAssertTrue(idx.create())

        idx.addDirect(id: "vd:1", vector: [1, 0, 0, 0])
        idx.addDirect(id: "vd:2", vector: [0, 1, 0, 0])
        idx.addDirect(id: "vd:3", vector: [0, 0, 1, 0])

        let hits = idx.searchDirect(query: [0.9, 0.1, 0, 0], k: 2)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.first?.id, "vd:1")
        for i in 1..<hits.count {
            XCTAssertLessThanOrEqual(hits[i - 1].distance, hits[i].distance)
        }

        _ = idx.drop()
    }

    func testAddBatchDirectMatchesSerialAdd() throws {
        let idx = DazzleServer.shared.vectorIndex(
            name: "t_hnsw_batch",
            hashPrefix: "vb:",
            dim: 4,
            algorithm: .hnsw,
            metric: .cosine
        )
        _ = idx.drop()
        XCTAssertTrue(idx.create())

        let ids = ["vb:1", "vb:2", "vb:3", "vb:4"]
        let vecs: [[Float]] = [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 1],
        ]
        idx.addBatchDirect(ids: ids, vectors: vecs)

        let hits = idx.searchDirect(query: [0.8, 0.0, 0.1, 0.0], k: 4)
        XCTAssertEqual(hits.count, 4)
        XCTAssertEqual(Set(hits.map { $0.id }), Set(ids))
        // Nearest on cosine for the biased vector should be vb:1.
        XCTAssertEqual(hits.first?.id, "vb:1")

        _ = idx.drop()
    }

    // MARK: – Quantised index paths (SQ8 + F16)

    /// SQ8 stores int8[dim] per point and runs simsimd_cos_i8 (NEON SDOT on
    /// arm64) as the distance. Cosine-only, no FT.CREATE involved.
    func testHnswSq8RetrievesExactMatch() throws {
        let idx = DazzleServer.shared.vectorIndex(
            name: "t_sq8",
            hashPrefix: "sq8:",
            dim: 8,
            algorithm: .hnswSq8,
            metric: .cosine
        )
        _ = idx.drop()
        XCTAssertTrue(idx.create())

        idx.addDirect(id: "sq8:a", vector: [1, 0, 0, 0, 0, 0, 0, 0])
        idx.addDirect(id: "sq8:b", vector: [0, 1, 0, 0, 0, 0, 0, 0])
        idx.addDirect(id: "sq8:c", vector: [0, 0, 1, 0, 0, 0, 0, 0])

        // Search with a vector biased towards sq8:a — quantisation rounds
        // values but cosine ordering stays stable.
        let hits = idx.searchDirect(query: [0.95, 0.05, 0, 0, 0, 0, 0, 0], k: 2)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.first?.id, "sq8:a")

        _ = idx.drop()
    }

    /// SQ8 + fp32 rerank — keeps the unit-normalised fp32 side-store and
    /// rescores the top-k·2 HNSW candidates with simsimd_dot_f32 so the
    /// final ordering matches the pure-fp32 path.
    func testHnswSq8RerankOrdersLikeFp32() throws {
        let idx = DazzleServer.shared.vectorIndex(
            name: "t_sq8_rerank",
            hashPrefix: "sr:",
            dim: 8,
            algorithm: .hnswSq8Rerank,
            metric: .cosine
        )
        _ = idx.drop()
        XCTAssertTrue(idx.create())

        idx.addDirect(id: "sr:a", vector: [1, 0, 0, 0, 0, 0, 0, 0])
        idx.addDirect(id: "sr:b", vector: [0.707, 0.707, 0, 0, 0, 0, 0, 0])
        idx.addDirect(id: "sr:c", vector: [0, 1, 0, 0, 0, 0, 0, 0])

        let hits = idx.searchDirect(query: [0.9, 0.1, 0, 0, 0, 0, 0, 0], k: 3)
        XCTAssertEqual(hits.count, 3)
        // Pure int8 ordering would still put sr:a first; the rerank pass
        // is exercised here to confirm at least the distances re-sort.
        XCTAssertEqual(hits.first?.id, "sr:a")
        for i in 1..<hits.count {
            XCTAssertLessThanOrEqual(hits[i - 1].distance, hits[i].distance)
        }

        _ = idx.drop()
    }

    /// FP16 stores uint16[dim] and runs simsimd_dot_f16 (armv8.2-a+fp16
    /// FMLA). 2 B/dim vs 4 B/dim fp32 with negligible recall loss.
    func testHnswF16RetrievesNearestNeighbor() throws {
        let idx = DazzleServer.shared.vectorIndex(
            name: "t_f16",
            hashPrefix: "f16:",
            dim: 8,
            algorithm: .hnswF16,
            metric: .cosine
        )
        _ = idx.drop()
        XCTAssertTrue(idx.create())

        idx.addDirect(id: "f16:a", vector: [1, 0, 0, 0, 0, 0, 0, 0])
        idx.addDirect(id: "f16:b", vector: [0, 1, 0, 0, 0, 0, 0, 0])
        idx.addDirect(id: "f16:c", vector: [0, 0, 1, 0, 0, 0, 0, 0])

        let hits = idx.searchDirect(query: [0.95, 0.05, 0, 0, 0, 0, 0, 0], k: 1)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.id, "f16:a")

        _ = idx.drop()
    }
}
