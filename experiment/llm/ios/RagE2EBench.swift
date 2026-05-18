// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0

import Foundation
import DazzleC
import Darwin

#if canImport(UIKit)
import UIKit
#endif

/// iOS port of `experiment/backends/android/core/RagE2EBench.kt`.
///
/// Same workload, same prompts, same scoring, same JSON shape — so
/// `bootstrap_rag_cross_platform.py` ingests the iOS row alongside
/// the three Android rows of Table 17 without any per-platform
/// branching.
///
/// The port omits the multi-process driver (`RagE2EBenchPhases.kt`)
/// because iOS jetsam has plenty of headroom on A14 (6 GB) for the
/// full 200-query × 4-variant run in one process.
public enum RagE2EBench {

    // ── Config (mirrors Kotlin Config) ─────────────────────────────
    public struct Config {
        public var embedFile:     String = "bge-small-en-v1.5-q4_k_m.gguf"
        public var smallLlmFile:  String = "qwen2.5-0.5b-instruct-q4_k_m.gguf"
        public var largeLlmFile:  String = "qwen2.5-1.5b-instruct-q4_k_m.gguf"
        public var embedNCtx:     Int    = 512
        public var llmNCtx:       Int    = 2048
        public var llmNBatch:     Int    = 2048   // == n_ctx; avoids split-prefill
        public var maxNewTokens:  Int    = 64
        public var k:             Int    = 5
        public var efRuntime:     Int    = 64
        public var indexName:     String = "nq:e2e"
        public var hashPrefix:    String = "nq:e2e:"
        public var passagesAsset: String = "nq_slice/passages.jsonl"
        public var queriesAsset:  String = "nq_slice/queries.jsonl"
        public var maxQueries:    Int?   = nil
        public init() {}
    }

    private struct Passage { let id: String; let text: String }
    private struct Query   { let id: String; let text: String; let gold: [String]; let shortAnswers: [String] }

    // ── Public entry ───────────────────────────────────────────────
    public static func run(config baseCfg: Config = Config()) {
        NSLog("[RagE2EBench] run() entered")
        var cfg = baseCfg
        if let n = ProcessInfo.processInfo.environment["MAX_QUERIES"].flatMap(Int.init) {
            cfg.maxQueries = n
            NSLog("[RagE2EBench] MAX_QUERIES override = %d", n)
        }
        #if canImport(UIKit)
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        #endif
        do {
            NSLog("[RagE2EBench] calling runInner ...")
            let result = try runInner(cfg: cfg)
            NSLog("[RagE2EBench] runInner returned, writing JSON ...")
            try writeJson(result, smallLlmFile: cfg.smallLlmFile)
            NSLog("[RagE2EBench] complete")
        } catch {
            NSLog("[RagE2EBench] FAILED: %@", "\(error)")
        }
    }

    // ── Inner orchestration ────────────────────────────────────────
    private static func runInner(cfg: Config) throws -> [String: Any] {
        NSLog("[RagE2EBench] runInner: resolving weights ...")
        // Resolve weights — Documents/ is where xcrun devicectl pushes them.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        func resolveWeight(_ name: String) throws -> URL {
            let u = docs.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: u.path) else {
                throw RagBenchError.weightMissing(name)
            }
            return u
        }
        let embedURL = try resolveWeight(cfg.embedFile)
        let smallURL = try resolveWeight(cfg.smallLlmFile)
        let largeURL = try resolveWeight(cfg.largeLlmFile)
        NSLog("[RagE2EBench] runInner: weights resolved (BGE=%@, small=%@, large=%@)",
              embedURL.lastPathComponent, smallURL.lastPathComponent, largeURL.lastPathComponent)

        // Slice assets — bundled in the .app
        NSLog("[RagE2EBench] runInner: loading slice ...")
        let passages = try loadPassages(asset: cfg.passagesAsset)
        let queriesAll = try loadQueries(asset: cfg.queriesAsset)
        let queries = cfg.maxQueries.map { Array(queriesAll.prefix($0)) } ?? queriesAll
        NSLog("[RagE2EBench] slice: %d passages, %d queries", passages.count, queries.count)
        let passageById = Dictionary(uniqueKeysWithValues: passages.map { (cfg.hashPrefix + $0.id, $0) })

        // Server + vector index. The host app has already started the
        // server in `DazzleExperimentApp.init()` with the vectorSearch
        // module loaded; we just reuse that instance.
        if !DazzleServer.shared.isRunning {
            try DazzleServer.shared.start(config: DazzleConfig(
                port:        6380,
                persistence: .none,
                wipeOnStart: [.aof, .rdb],
                modules:     [.vectorSearch]
            ))
        }
        // Probe the embedding dim once so the index can be created with
        // the right shape — building the embedder twice is fine because
        // weight load amortises over the 200-passage embed loop below.
        NSLog("[RagE2EBench] loading BGE for probeDim ...")
        let probeDim = try EmbedHandle(modelPath: embedURL.path, nCtx: cfg.embedNCtx).dim
        NSLog("[RagE2EBench] probeDim = %d", probeDim)
        let index = DazzleServer.shared.vectorIndex(
            name:        cfg.indexName,
            hashPrefix:  cfg.hashPrefix,
            vectorField: "emb",
            dim:         probeDim,
            algorithm:   .flat,           // FLAT — same as the Kirin row
            metric:      .cosine,
            initialCapacity: passages.count   // pre-size 2000 → BruteforceSearch
                                              // doesn't throw at element 1024
        )
        _ = index.create()

        // ── Embedder + per-passage / per-query embed ──
        let embedder = try EmbedHandle(modelPath: embedURL.path, nCtx: cfg.embedNCtx)
        let dim = embedder.dim

        var passageEmbeds = [[Float]](); passageEmbeds.reserveCapacity(passages.count)
        for (i, p) in passages.enumerated() {
            let v = try embedder.embed(p.text)
            passageEmbeds.append(v)
            if i < 5 || i >= passages.count - 5 || i % 200 == 0 {
                print("[RagE2EBench]   embed passage \(i)/\(passages.count)")
            }
        }
        let ids = passages.map { cfg.hashPrefix + $0.id }
        let tBatch0 = Date()
        index.addBatchDirect(ids: ids, vectors: passageEmbeds)
        print("[RagE2EBench] addBatchDirect \(passages.count) vecs in \(Int(-tBatch0.timeIntervalSinceNow * 1000)) ms")

        var queryEmbeds = [[Float]](); queryEmbeds.reserveCapacity(queries.count)
        var queryEmbedUs = [Int64](); queryEmbedUs.reserveCapacity(queries.count)
        for q in queries {
            let t0 = nowUs()
            queryEmbeds.append(try embedder.embed(q.text))
            queryEmbedUs.append(nowUs() - t0)
        }
        embedder.close()

        // ── 4 variants ──
        var variants = [String: Any]()
        // small RAG + small no-RAG share the small LLM
        let small = try GenHandle(modelPath: smallURL.path,
                                  nCtx: cfg.llmNCtx, nBatch: cfg.llmNBatch)
        variants["small_rag"]    = try runVariantRag(llm: small, queryEmbeds: queryEmbeds,
            queryEmbedUs: queryEmbedUs, index: index, queries: queries,
            passageById: passageById, cfg: cfg, dim: dim)
        variants["small_no_rag"] = try runVariantNoRag(llm: small, queries: queries,
            passageById: passageById, cfg: cfg)
        small.close()
        // large RAG + large no-RAG share the large LLM
        let large = try GenHandle(modelPath: largeURL.path,
                                  nCtx: cfg.llmNCtx, nBatch: cfg.llmNBatch)
        variants["large_no_rag"] = try runVariantNoRag(llm: large, queries: queries,
            passageById: passageById, cfg: cfg)
        variants["large_rag"]    = try runVariantRag(llm: large, queryEmbeds: queryEmbeds,
            queryEmbedUs: queryEmbedUs, index: index, queries: queries,
            passageById: passageById, cfg: cfg, dim: dim)
        large.close()

        return [
            "type":      "rag_e2e",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "device":    collectDeviceInfo(),
            "models":    [
                "embedder":  fileInfo(embedURL, dim: dim, nCtx: cfg.embedNCtx),
                "small_llm": fileInfo(smallURL, dim: nil, nCtx: cfg.llmNCtx),
                "large_llm": fileInfo(largeURL, dim: nil, nCtx: cfg.llmNCtx),
            ],
            "slice":     ["n_passages": passages.count, "n_queries": queries.count],
            "config":    [
                "k":               cfg.k,
                "ef_runtime":      cfg.efRuntime,
                "ef_construction": 400,
                "algorithm":       "FLAT",
                "max_new_tokens":  cfg.maxNewTokens,
                "decoding":        "greedy",
                "embed_n_ctx":     cfg.embedNCtx,
                "embed_n_batch":   cfg.embedNCtx,
                "llm_n_ctx":       cfg.llmNCtx,
                "llm_n_batch":     cfg.llmNBatch,
                "llm_kv_cache":    "F16",
                "flash_attn":      false,
                "use_mlock":       false,
                "n_threads":       4,
            ],
            "variants":  variants,
        ]
    }

    // ── Variants ───────────────────────────────────────────────────
    private static func runVariantRag(
        llm: GenHandle,
        queryEmbeds: [[Float]], queryEmbedUs: [Int64],
        index: VectorIndex, queries: [Query],
        passageById: [String: Passage], cfg: Config, dim: Int
    ) throws -> [String: Any] {
        let n = queries.count
        var embedUs = [Int64](repeating: 0, count: n)
        var searchUs = [Int64](repeating: 0, count: n)
        var prefillUs = [Int64](repeating: 0, count: n)
        var decodeUs = [Int64](repeating: 0, count: n)
        var totalUs = [Int64](repeating: 0, count: n)
        var pTokens = [Int](repeating: 0, count: n)
        var nTokens = [Int](repeating: 0, count: n)
        var f1s = [Double](repeating: 0, count: n)
        var ems = [Double](repeating: .nan, count: n)
        var emsCt = [Double](repeating: .nan, count: n)
        var f1sh = [Double](repeating: .nan, count: n)
        var records = [[String: Any]]()

        for (qi, q) in queries.enumerated() {
            let tTotal = nowUs()
            embedUs[qi] = queryEmbedUs[qi]
            let t1 = nowUs()
            let hits = index.searchDirect(query: queryEmbeds[qi], k: cfg.k, efRuntime: cfg.efRuntime)
            searchUs[qi] = nowUs() - t1
            let retrieved = hits.compactMap { passageById[$0.id] }
            let prompt = buildPromptWithPassages(question: q.text, passages: retrieved)
            let answer = try llm.generate(prompt: prompt, maxNewTokens: cfg.maxNewTokens)
            totalUs[qi] = nowUs() - tTotal
            prefillUs[qi] = llm.lastPrefillUs
            decodeUs[qi]  = llm.lastDecodeUs
            pTokens[qi]   = llm.lastPromptTokens
            nTokens[qi]   = llm.lastNewTokens

            let goldText: String = {
                for gid in q.gold { if let p = passageById[cfg.hashPrefix + gid] { return p.text } }
                return ""
            }()
            let span = extractAnswerSpan(answer)
            f1s[qi]  = tokenF1(answer, goldText)
            ems[qi]  = emStrict(span, q.shortAnswers)
            emsCt[qi] = emContains(answer, q.shortAnswers)
            f1sh[qi] = f1Short(span, q.shortAnswers)

            if qi % 5 == 0 {
                print(String(format: "[RagE2EBench]   A[%d/%d] total=%dus prefill=%dus decode=%dus ptok=%d ntok=%d f1s=%.2f",
                    qi, n, totalUs[qi], prefillUs[qi], decodeUs[qi], pTokens[qi], nTokens[qi],
                    f1sh[qi].isNaN ? 0 : f1sh[qi]))
            }
            records.append([
                "qid": q.id, "answer": answer, "answer_span": span,
                "short_answers": q.shortAnswers,
                "em_short": ems[qi].isNaN ? NSNull() : ems[qi],
                "em_contains": emsCt[qi].isNaN ? NSNull() : emsCt[qi],
                "f1_short": f1sh[qi].isNaN ? NSNull() : f1sh[qi],
                "f1_passage": f1s[qi],
                "embed_us": embedUs[qi], "search_us": searchUs[qi],
                "prefill_us": prefillUs[qi], "decode_us": decodeUs[qi],
                "total_us": totalUs[qi],
                "prompt_tokens": pTokens[qi], "new_tokens": nTokens[qi],
            ])
        }
        return [
            "embed_us":     latencyStats(embedUs),
            "search_us":    latencyStats(searchUs),
            "prefill_us":   latencyStats(prefillUs),
            "decode_us":    latencyStats(decodeUs),
            "total_us":     latencyStats(totalUs),
            "prompt_tokens": intStats(pTokens),
            "new_tokens":    intStats(nTokens),
            "em_short":     doubleStats(ems),
            "em_contains":  doubleStats(emsCt),
            "f1_short":     doubleStats(f1sh),
            "token_f1_vs_gold_passage": doubleStats(f1s),
            "examples":     records,
        ]
    }

    private static func runVariantNoRag(
        llm: GenHandle, queries: [Query],
        passageById: [String: Passage], cfg: Config
    ) throws -> [String: Any] {
        let n = queries.count
        var prefillUs = [Int64](repeating: 0, count: n)
        var decodeUs = [Int64](repeating: 0, count: n)
        var totalUs = [Int64](repeating: 0, count: n)
        var pTokens = [Int](repeating: 0, count: n)
        var nTokens = [Int](repeating: 0, count: n)
        var f1s = [Double](repeating: 0, count: n)
        var ems = [Double](repeating: .nan, count: n)
        var emsCt = [Double](repeating: .nan, count: n)
        var f1sh = [Double](repeating: .nan, count: n)
        var records = [[String: Any]]()

        for (qi, q) in queries.enumerated() {
            let tTotal = nowUs()
            let prompt = buildPromptNoContext(question: q.text)
            let answer = try llm.generate(prompt: prompt, maxNewTokens: cfg.maxNewTokens)
            totalUs[qi] = nowUs() - tTotal
            prefillUs[qi] = llm.lastPrefillUs
            decodeUs[qi]  = llm.lastDecodeUs
            pTokens[qi]   = llm.lastPromptTokens
            nTokens[qi]   = llm.lastNewTokens

            let goldText: String = {
                for gid in q.gold { if let p = passageById[cfg.hashPrefix + gid] { return p.text } }
                return ""
            }()
            let span = extractAnswerSpan(answer)
            f1s[qi]   = tokenF1(answer, goldText)
            ems[qi]   = emStrict(span, q.shortAnswers)
            emsCt[qi] = emContains(answer, q.shortAnswers)
            f1sh[qi]  = f1Short(span, q.shortAnswers)

            if qi % 5 == 0 {
                print(String(format: "[RagE2EBench]   B[%d/%d] total=%dus ptok=%d f1s=%.2f",
                    qi, n, totalUs[qi], pTokens[qi], f1sh[qi].isNaN ? 0 : f1sh[qi]))
            }
            records.append([
                "qid": q.id, "answer": answer, "answer_span": span,
                "short_answers": q.shortAnswers,
                "em_short": ems[qi].isNaN ? NSNull() : ems[qi],
                "em_contains": emsCt[qi].isNaN ? NSNull() : emsCt[qi],
                "f1_short": f1sh[qi].isNaN ? NSNull() : f1sh[qi],
                "f1_passage": f1s[qi],
                "prefill_us": prefillUs[qi], "decode_us": decodeUs[qi],
                "total_us": totalUs[qi],
                "prompt_tokens": pTokens[qi], "new_tokens": nTokens[qi],
            ])
        }
        return [
            "embed_us":     [String: Any](),
            "search_us":    [String: Any](),
            "prefill_us":   latencyStats(prefillUs),
            "decode_us":    latencyStats(decodeUs),
            "total_us":     latencyStats(totalUs),
            "prompt_tokens": intStats(pTokens),
            "new_tokens":    intStats(nTokens),
            "em_short":     doubleStats(ems),
            "em_contains":  doubleStats(emsCt),
            "f1_short":     doubleStats(f1sh),
            "token_f1_vs_gold_passage": doubleStats(f1s),
            "examples":     records,
        ]
    }

    // ── Prompt builders ────────────────────────────────────────────
    private static func buildPromptWithPassages(question: String, passages: [Passage]) -> String {
        var s = "Answer the question using only the context below. "
        s += "Reply with a short factual answer (one phrase).\n\nContext:\n"
        for (i, p) in passages.enumerated() {
            s += "[\(i + 1)] " + String(p.text.prefix(500)) + "\n"
        }
        s += "\nQuestion: \(question)\nAnswer:"
        return s
    }
    private static func buildPromptNoContext(question: String) -> String {
        "Answer the question with a short factual phrase (one line).\nQuestion: \(question)\nAnswer:"
    }

    // ── Slice loaders ──────────────────────────────────────────────
    private static func resourceURL(_ asset: String) throws -> URL {
        // `asset` is "nq_slice/passages.jsonl" in the Android bench;
        // on iOS xcodegen flattens the Resources/ tree by default, so
        // we try both with-subdir and bundle-root lookups before
        // giving up. As a last resort, also probe the app's Documents/
        // dir (where `xcrun devicectl` can drop dev-time assets).
        let name = (asset as NSString).lastPathComponent
        let subdir = (asset as NSString).deletingLastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let ext  = (name as NSString).pathExtension
        if let u = Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: subdir) {
            return u
        }
        if let u = Bundle.main.url(forResource: stem, withExtension: ext) {
            return u
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let candidate = docs.appendingPathComponent(asset)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw RagBenchError.assetMissing(asset)
    }
    private static func loadPassages(asset: String) throws -> [Passage] {
        let url = try resourceURL(asset)
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RagBenchError.assetMissing(asset)
        }
        var out = [Passage]()
        for line in text.split(separator: "\n") where !line.isEmpty {
            if let obj = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any],
               let id = obj["_id"] as? String,
               let txt = obj["text"] as? String {
                out.append(Passage(id: id, text: txt))
            }
        }
        return out
    }
    private static func loadQueries(asset: String) throws -> [Query] {
        let url = try resourceURL(asset)
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RagBenchError.assetMissing(asset)
        }
        var out = [Query]()
        for line in text.split(separator: "\n") where !line.isEmpty {
            if let obj = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any],
               let id = obj["_id"] as? String,
               let txt = obj["text"] as? String {
                let gold = (obj["gold"] as? [String]) ?? []
                let shortA = (obj["short_answers"] as? [String]) ?? []
                out.append(Query(id: id, text: txt, gold: gold, shortAnswers: shortA))
            }
        }
        return out
    }

    // ── Scoring (mirrors Kotlin pure-logic helpers) ────────────────
    private static let stopWords: Set<String> = ["a", "an", "the"]
    private static func normalize(_ s: String) -> [String] {
        // Mirror Kotlin `normalize`: lowercase, replace any non-alphanumeric
        // /non-whitespace char with space, split on whitespace, drop the
        // article stop-words. Implemented via `unicodeScalars` for byte-
        // exact parity with Android `Character.isLetterOrDigit`.
        let keep = CharacterSet.alphanumerics.union(.whitespaces)
        var out = String()
        out.reserveCapacity(s.count)
        for scalar in s.lowercased().unicodeScalars {
            out.unicodeScalars.append(keep.contains(scalar) ? scalar : Unicode.Scalar(0x20))
        }
        return out.split(whereSeparator: { $0.isWhitespace })
            .map(String.init).filter { !stopWords.contains($0) }
    }
    private static func extractAnswerSpan(_ raw: String) -> String {
        // Truncate at first newline OR at first "Question:" / "Answer:" echo.
        var s = raw
        if let r = s.range(of: "\n") { s = String(s[..<r.lowerBound]) }
        for kw in ["Question:", "Answer:"] {
            if let r = s.range(of: kw) { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func tokenF1Tokens(_ p: [String], _ g: [String]) -> Double {
        if p.isEmpty || g.isEmpty { return p.isEmpty == g.isEmpty ? 1.0 : 0.0 }
        var pCount = [String: Int](); for t in p { pCount[t, default: 0] += 1 }
        var common = 0
        for t in g { if let c = pCount[t], c > 0 { common += 1; pCount[t] = c - 1 } }
        if common == 0 { return 0 }
        let prec = Double(common) / Double(p.count)
        let rec  = Double(common) / Double(g.count)
        return 2 * prec * rec / (prec + rec)
    }
    private static func tokenF1(_ pred: String, _ gold: String) -> Double {
        gold.isEmpty ? 0 : tokenF1Tokens(normalize(pred), normalize(gold))
    }
    private static func emStrict(_ span: String, _ aliases: [String]) -> Double {
        if aliases.isEmpty { return .nan }
        let s = normalize(span).joined(separator: " ")
        for a in aliases { if normalize(a).joined(separator: " ") == s { return 1 } }
        return 0
    }
    private static func emContains(_ pred: String, _ aliases: [String]) -> Double {
        if aliases.isEmpty { return .nan }
        let p = normalize(pred).joined(separator: " ")
        for a in aliases {
            let aN = normalize(a).joined(separator: " ")
            if !aN.isEmpty && p.contains(aN) { return 1 }
        }
        return 0
    }
    private static func f1Short(_ span: String, _ aliases: [String]) -> Double {
        if aliases.isEmpty { return .nan }
        let p = normalize(span)
        var best = 0.0
        for a in aliases { best = max(best, tokenF1Tokens(p, normalize(a))) }
        return best
    }

    // ── Stats ──────────────────────────────────────────────────────
    private static func latencyStats(_ vs: [Int64]) -> [String: Any] {
        if vs.isEmpty { return [:] }
        let sorted = vs.sorted()
        func pct(_ p: Double) -> Int64 {
            sorted[max(0, min(sorted.count - 1, Int(p * Double(sorted.count - 1))))]
        }
        return ["avg": Double(vs.reduce(0, +)) / Double(vs.count),
                "p50": pct(0.50), "p95": pct(0.95),
                "min": sorted.first!, "max": sorted.last!]
    }
    private static func intStats(_ vs: [Int]) -> [String: Any] {
        if vs.isEmpty { return [:] }
        let sorted = vs.sorted()
        func pct(_ p: Double) -> Int {
            sorted[max(0, min(sorted.count - 1, Int(p * Double(sorted.count - 1))))]
        }
        return ["avg": Double(vs.reduce(0, +)) / Double(vs.count),
                "p50": pct(0.50), "p95": pct(0.95),
                "min": sorted.first!, "max": sorted.last!]
    }
    private static func doubleStats(_ vs: [Double]) -> [String: Any] {
        let clean = vs.filter { !$0.isNaN }
        if clean.isEmpty { return ["avg": NSNull(), "n": 0] }
        return ["avg": clean.reduce(0, +) / Double(clean.count), "n": clean.count]
    }

    // ── Device / file info ─────────────────────────────────────────
    private static func collectDeviceInfo() -> [String: Any] {
        var info: [String: Any] = [
            "manufacturer": "Apple", "abi": "arm64",
            "cpu_cores": ProcessInfo.processInfo.activeProcessorCount,
        ]
        #if canImport(UIKit)
        info["os"] = "iOS"
        info["os_version"] = UIDevice.current.systemVersion
        info["model"] = sysctlString("hw.machine") ?? UIDevice.current.model
        #endif
        return info
    }
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        if size == 0 { return nil }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }
    private static func fileInfo(_ url: URL, dim: Int?, nCtx: Int) -> [String: Any] {
        var info: [String: Any] = ["path": url.lastPathComponent, "n_ctx": nCtx]
        if let d = dim { info["dim"] = d }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 { info["size_bytes"] = size }
        return info
    }

    // ── JSON output ────────────────────────────────────────────────
    private static func writeJson(_ result: [String: Any], smallLlmFile: String) throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let stem = (smallLlmFile as NSString).deletingPathExtension
        let out = docs.appendingPathComponent("rag_e2e_\(stem)_\(ts).json")
        let data = try JSONSerialization.data(withJSONObject: result,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out)
        print("[RagE2EBench] wrote \(out.path) (\(data.count) bytes)")
    }

    private static func nowUs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000_000)
    }

    enum RagBenchError: Error {
        case weightMissing(String)
        case assetMissing(String)
        case generateFailed(Int32)
        case embedFailed(Int32)
    }

    // ── Low-level llama wrappers (use the new dazzle_llama_* C API) ──
    final class GenHandle {
        let model: OpaquePointer
        let ctx:   OpaquePointer
        init(modelPath: String, nCtx: Int, nBatch: Int) throws {
            dazzle_llama_backend_init()
            guard let m = modelPath.withCString({ p in dazzle_llama_load_model(p, 0) }) else {
                throw RagBenchError.weightMissing(modelPath)
            }
            guard let c = dazzle_llama_new_context(m, Int32(nCtx), 4) else {
                dazzle_llama_free_model(m)
                throw RagBenchError.weightMissing(modelPath)
            }
            self.model = m; self.ctx = c
        }
        func close() { dazzle_llama_free_context(ctx); dazzle_llama_free_model(model) }
        func generate(prompt: String, maxNewTokens: Int) throws -> String {
            // Collect tokens via a C callback into a Swift box.
            class Box { var s = "" }
            let box = Box()
            let unmanaged = Unmanaged.passUnretained(box)
            let rc = prompt.withCString { p -> Int32 in
                dazzle_llama_generate(ctx, p, Int32(maxNewTokens),
                                      0.0,    // greedy
                                      1.0,    // top_p disabled
                                      0,      // seed
                                      { piece, ud in
                                          guard let piece = piece, let ud = ud else { return 0 }
                                          let b = Unmanaged<Box>.fromOpaque(ud).takeUnretainedValue()
                                          b.s += String(cString: piece)
                                          return 0
                                      },
                                      unmanaged.toOpaque())
            }
            if rc < 0 { throw RagBenchError.generateFailed(rc) }
            return box.s
        }
        var lastPrefillUs:  Int64 { dazzle_llama_last_prefill_us(ctx) }
        var lastDecodeUs:   Int64 { dazzle_llama_last_decode_us(ctx) }
        var lastPromptTokens: Int { Int(dazzle_llama_last_prompt_tokens(ctx)) }
        var lastNewTokens:   Int  { Int(dazzle_llama_last_new_tokens(ctx)) }
    }

    final class EmbedHandle {
        let model: OpaquePointer
        let ctx:   OpaquePointer
        let dim: Int
        init(modelPath: String, nCtx: Int) throws {
            dazzle_llama_backend_init()
            guard let m = modelPath.withCString({ p in dazzle_llama_load_model(p, 0) }) else {
                throw RagBenchError.weightMissing(modelPath)
            }
            guard let c = dazzle_llama_new_embed_context(m, Int32(nCtx), 4) else {
                dazzle_llama_free_model(m)
                throw RagBenchError.weightMissing(modelPath)
            }
            self.model = m; self.ctx = c
            self.dim = Int(dazzle_llama_embed_dim(c))
        }
        func close() { dazzle_llama_free_context(ctx); dazzle_llama_free_model(model) }
        func embed(_ text: String) throws -> [Float] {
            var out = [Float](repeating: 0, count: dim)
            let rc = text.withCString { p -> Int32 in
                out.withUnsafeMutableBufferPointer { buf in
                    dazzle_llama_embed(ctx, p, buf.baseAddress, Int32(buf.count))
                }
            }
            if rc < 0 { throw RagBenchError.embedFailed(rc) }
            return out
        }
    }
}
