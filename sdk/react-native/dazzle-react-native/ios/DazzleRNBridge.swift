// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
//
// Swift side of the React Native module. Forwards lifecycle + command
// calls to the native Swift `DazzleServer` + `VectorIndex`.

import Foundation

@objc(DazzleRNBridge)
public class DazzleRNBridge: NSObject {
  @objc public static let shared = DazzleRNBridge()

  private override init() {}

  // MARK: – Lifecycle

  @objc public func start(
    config: [String: Any]?,
    resolve: @escaping (Any?) -> Void,
    reject: @escaping (String, String, NSError?) -> Void
  ) {
    do {
      if DazzleServer.shared.isRunning { resolve(nil); return }
      let cfg = Self.parseConfig(config)
      try DazzleServer.shared.start(config: cfg)
      resolve(nil)
    } catch {
      reject("DAZZLE_START_FAILED",
             "\(type(of: error)): \(error.localizedDescription)",
             nil)
    }
  }

  @objc public func stop(
    resolve: @escaping (Any?) -> Void,
    reject: @escaping (String, String, NSError?) -> Void
  ) {
    if DazzleServer.shared.isRunning { DazzleServer.shared.stop() }
    resolve(nil)
  }

  @objc public var isRunning: Bool { DazzleServer.shared.isRunning }

  @objc public func waitForReady(timeoutMs: Int32) -> Bool {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
    while !DazzleServer.shared.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.025)
    }
    return DazzleServer.shared.isRunning
  }

  // MARK: – Synchronous hot-path methods
  // Cut per-call overhead from ~100 µs (async bridge + microtask) to
  // ~15 µs. The JS shim picks these first and falls back to the async
  // variants below if a method isn't exposed.

  @objc public func dazzleCommandSync(argv: [String]) -> String? {
    // Return the RAW RESP bytes — the JS-side parser needs the wire
    // format intact. `directArgs` flattens multi-bulk replies into a
    // newline-joined string that JS cannot re-parse as RESP, which
    // made every `rangeByScore` / `HGETALL` come back as an empty
    // array on iOS before this fix.
    return DazzleServer.shared.directArgsRaw(argv)
  }

  @objc public func snapHGetAllSync(key: String) -> [String]? {
    do {
      let fields = try DazzleServer.shared.client().hash(key).getAllDirect()
      if fields.isEmpty { return nil }
      var flat: [String] = []
      flat.reserveCapacity(fields.count * 2)
      for (k, v) in fields { flat.append(k); flat.append(v) }
      return flat
    } catch { return nil }
  }

  @objc public func snapZRangeByScoreSync(
      key: String, min: Double, max: Double, maxMembers: Int32) -> [String]? {
    do {
      let all = try DazzleServer.shared.client()
          .sortedSet(key)
          .rangeByScoreDirect(min: min, max: max)
      return Array(all.prefix(Int(maxMembers)))
    } catch { return nil }
  }

  @objc public func snapSMembersSync(
      key: String, maxMembers: Int32) -> [String]? {
    do {
      let all = try DazzleServer.shared.client().set(key).membersDirect()
      return Array(all.prefix(Int(maxMembers)))
    } catch { return nil }
  }

  @objc public func snapGetSync(key: String) -> String? {
    do {
      return try DazzleServer.shared.client().string(key).getDirect()
    } catch { return nil }
  }

  // MARK: – Commands + snapshot cache (async fallback)

  @objc public func dazzleCommand(
    argv: [String],
    resolve: @escaping (Any?) -> Void,
    reject: @escaping (String, String, NSError?) -> Void
  ) {
    // Raw RESP path — the JS-side parser expects the untouched wire
    // format. See `dazzleCommandSync` above for the same rationale.
    Task {
      let reply = await DazzleServer.shared.directArgsRawAsync(argv) ?? ""
      resolve(reply)
    }
  }

  @objc public func snapHGetAll(
    key: String,
    resolve: @escaping (Any?) -> Void,
    reject: @escaping (String, String, NSError?) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let fields = try DazzleServer.shared.client().hash(key).getAllDirect()
        if fields.isEmpty { resolve(nil); return }
        var flat: [String] = []
        for (k, v) in fields { flat.append(k); flat.append(v) }
        resolve(flat)
      } catch {
        resolve(nil)
      }
    }
  }

  @objc public func snapZRangeByScore(
    key: String, min: Double, max: Double, maxMembers: Int32,
    resolve: @escaping (Any?) -> Void,
    reject: @escaping (String, String, NSError?) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let all = try DazzleServer.shared.client()
          .sortedSet(key)
          .rangeByScoreDirect(min: min, max: max)
        let slice = Array(all.prefix(Int(maxMembers)))
        resolve(slice)
      } catch {
        resolve(nil)
      }
    }
  }

  @objc public func snapSMembers(
    key: String, maxMembers: Int32,
    resolve: @escaping (Any?) -> Void,
    reject: @escaping (String, String, NSError?) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let all = try DazzleServer.shared.client()
          .set(key)
          .membersDirect()
        let slice = Array(all.prefix(Int(maxMembers)))
        resolve(slice)
      } catch {
        resolve(nil)
      }
    }
  }

  @objc public func snapGet(
    key: String,
    resolve: @escaping (Any?) -> Void,
    reject: @escaping (String, String, NSError?) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let value = try DazzleServer.shared.client().string(key).getDirect()
        resolve(value as Any?)
      } catch {
        resolve(nil)
      }
    }
  }

  // MARK: – Vector index

  @objc public func vsCreate(
    opts: [String: Any],
    resolve: @escaping (Any?) -> Void,
    reject: @escaping (String, String, NSError?) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      guard let name = opts["name"] as? String,
            let dim  = opts["dim"]  as? Int else {
        reject("DAZZLE_VS_CREATE_FAILED", "missing name/dim", nil); return
      }
      let algo = (opts["algorithm"] as? String) ?? "hnswSq8"
      let algorithm: VectorIndex.Algorithm
      switch algo {
      case "hnswSq8Rerank": algorithm = .hnswSq8Rerank
      case "hnswF16":       algorithm = .hnswF16
      default:              algorithm = .hnswSq8
      }
      let idx = DazzleServer.shared.vectorIndex(
        name: name,
        hashPrefix: "\(name):",
        vectorField: "emb",
        dim: dim,
        algorithm: algorithm,
        metric: .cosine)
      _ = idx.create()
      resolve(nil)
    }
  }

  @objc public func vsAddDirect(
    name: String, id: String, vector: [NSNumber],
    resolve: @escaping (Any?) -> Void,
    reject: @escaping (String, String, NSError?) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let vec = vector.map { $0.floatValue }
      let idx = self.findIndex(name: name, dim: vec.count)
      idx.addDirect(id: id, vector: vec)
      resolve(nil)
    }
  }

  @objc public func vsAddBatchDirect(
    name: String, ids: [String], flat: [NSNumber], dim: Int32,
    resolve: @escaping (Any?) -> Void,
    reject: @escaping (String, String, NSError?) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let n = ids.count
      let d = Int(dim)
      var vectors: [[Float]] = []
      vectors.reserveCapacity(n)
      for i in 0..<n {
        var row = [Float](); row.reserveCapacity(d)
        for j in 0..<d { row.append(flat[i * d + j].floatValue) }
        vectors.append(row)
      }
      let idx = self.findIndex(name: name, dim: d)
      idx.addBatchDirect(ids: ids, vectors: vectors)
      resolve(nil)
    }
  }

  @objc public func vsSearchDirect(
    name: String, query: [NSNumber], k: Int32, efRuntime: Int32,
    resolve: @escaping (Any?) -> Void,
    reject: @escaping (String, String, NSError?) -> Void
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let q = query.map { $0.floatValue }
      let idx = self.findIndex(name: name, dim: q.count)
      let hits = idx.searchDirect(query: q, k: Int(k),
                                  efRuntime: Int(efRuntime))
      let out = hits.map {
        ["id": $0.id, "distance": Double($0.distance)] as [String: Any]
      }
      resolve(out)
    }
  }

  private func findIndex(name: String, dim: Int) -> VectorIndex {
    DazzleServer.shared.vectorIndex(
      name: name,
      hashPrefix: "\(name):",
      vectorField: "emb",
      dim: dim,
      algorithm: .hnswSq8,
      metric: .cosine)
  }

  // MARK: – Foundation Models availability probe

  @objc public func fmIsAvailable(
    resolve: @escaping (Any?) -> Void,
    reject: @escaping (String, String, NSError?) -> Void
  ) {
    if #available(iOS 26.0, macOS 26.0, *) {
      Task {
        let ok = await FoundationModelsClient.isAvailable
        resolve(ok)
      }
    } else {
      resolve(false)
    }
  }

  // MARK: – Config

  private static func parseConfig(_ m: [String: Any]?) -> DazzleConfig {
    guard let m = m else { return DazzleConfig() }
    let maxMemory = (m["maxMemory"] as? String) ?? "64mb"

    var modules: Set<DazzleModule> = []
    if let arr = m["modules"] as? [String], arr.contains("vectorSearch") {
      modules.insert(.vectorSearch)
    }
    var wipe: WipeTarget = []
    if let arr = m["wipeOnStart"] as? [String] {
      if arr.contains("aof") { wipe.insert(.aof) }
      if arr.contains("rdb") { wipe.insert(.rdb) }
    }
    let persistence: DazzlePersistence = {
      guard let p = m["persistence"] as? [String: Any] else { return .aof() }
      switch p["kind"] as? String {
      case "none": return .none
      case "rdb":  return .rdb()
      default:
        let fsync: AppendFsync
        switch p["fsync"] as? String {
        case "always": fsync = .always
        case "no":     fsync = .no
        default:       fsync = .everysec
        }
        return .aof(fsync: fsync)
      }
    }()
    return DazzleConfig(
      maxMemory: maxMemory,
      persistence: persistence,
      wipeOnStart: wipe,
      modules: modules)
  }
}
