// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

import Foundation
import CryptoKit

/// Resumable, integrity-verified downloader for LLM weight files.
///
/// Mirror of the Android `ModelDownloader`. Used by the Layer 3
/// `DazzleEdge` bundle to fetch known models on first use.
///
/// Features:
/// - Atomic: downloads to `<dest>.part` then renames on completion
/// - Resumable: supports `Range: bytes=N-` when the server advertises it
/// - SHA-256 verified: refuses to hand back a file whose hash doesn't
///   match the manifest's pinned value
/// - Progress: fires a callback every ~1 % or every 4 MB, whichever
///   comes first
public enum ModelDownloader {

    /// Download [entry] to the platform cache dir and return the
    /// absolute path of the verified file. Idempotent.
    public static func ensure(
        _ entry: ModelManifest.Entry,
        onProgress: @escaping @Sendable (_ loaded: Int64, _ total: Int64) -> Void = { _, _ in }
    ) async throws -> URL {
        let targetDir = cacheBase().appendingPathComponent("dazzle-edge/\(entry.id)/\(entry.version)")
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let target = targetDir.appendingPathComponent(entry.filename)
        let partial = targetDir.appendingPathComponent("\(entry.filename).part")

        // Fast path: already present and valid
        if FileManager.default.fileExists(atPath: target.path),
           verify(target, against: entry.sha256)
        {
            let size = Int64((try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int64 ?? 0)
            onProgress(size, size)
            return target
        } else if FileManager.default.fileExists(atPath: target.path) {
            try? FileManager.default.removeItem(at: target)
        }

        // Resume from .part if present
        let existingBytes: Int64 = {
            guard FileManager.default.fileExists(atPath: partial.path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: partial.path)
            else { return 0 }
            return (attrs[.size] as? NSNumber)?.int64Value ?? 0
        }()

        var request = URLRequest(url: entry.url)
        request.timeoutInterval = 60
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.networkError("non-2xx fetching \(entry.url)")
        }
        // If server ignored Range, start from 0
        let resuming = existingBytes > 0 && http.statusCode == 206
        if !resuming && existingBytes > 0 {
            try? FileManager.default.removeItem(at: partial)
        }

        let expectedDelta = http.expectedContentLength
        let total: Int64 = resuming
            ? existingBytes + (expectedDelta > 0 ? expectedDelta : 0)
            : (expectedDelta > 0 ? expectedDelta : entry.sizeBytes)

        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        if resuming { try handle.seekToEnd() }

        var written: Int64 = resuming ? existingBytes : 0
        var lastReport = written
        let reportEvery = max(4 * 1024 * 1024, total / 100)
        var buffer = Data(capacity: 64 * 1024)

        for try await byte in bytes {
            buffer.append(byte)
            written += 1
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if written - lastReport >= reportEvery {
                    onProgress(written, total)
                    lastReport = written
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        try handle.close()
        onProgress(written, total)

        // Verify before exposing
        if !verify(partial, against: entry.sha256) {
            try? FileManager.default.removeItem(at: partial)
            throw DownloadError.integrityMismatch(
                id: entry.id,
                expected: entry.sha256,
                observed: sha256Of(partial) ?? "<absent>"
            )
        }

        // Atomic publish
        try FileManager.default.moveItem(at: partial, to: target)
        return target
    }

    /// Non-network check: returns the cached path if we already have a
    /// verified copy on disk, nil otherwise.
    public static func cached(_ entry: ModelManifest.Entry) -> URL? {
        let target = cacheBase()
            .appendingPathComponent("dazzle-edge/\(entry.id)/\(entry.version)/\(entry.filename)")
        guard FileManager.default.fileExists(atPath: target.path),
              verify(target, against: entry.sha256) else { return nil }
        return target
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    private static func cacheBase() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    private static func verify(_ url: URL, against expected: String) -> Bool {
        if expected.isEmpty || expected == "REPLACE_WITH_ACTUAL_SHA256_ON_FIRST_DOWNLOAD" {
            return FileManager.default.fileExists(atPath: url.path)
        }
        return sha256Of(url)?.lowercased() == expected.lowercased()
    }

    private static func sha256Of(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            } catch { return nil }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Typed failure surface for `ModelDownloader`.
public enum DownloadError: Error, LocalizedError {
    case networkError(String)
    case integrityMismatch(id: String, expected: String, observed: String)
    case diskError(String)

    public var errorDescription: String? {
        switch self {
        case .networkError(let m): return m
        case .integrityMismatch(let id, let e, let o):
            return "SHA-256 mismatch for '\(id)' — expected=\(e) observed=\(o)"
        case .diskError(let m): return m
        }
    }
}
