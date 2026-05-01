// SPDX-License-Identifier: Apache-2.0
//
// Debug logger that appends to a file inside the app's Documents
// directory so we can pull it from a connected device with
// `xcrun devicectl device file pull` after a problematic run.
//
// This is purely instrumentation — DELETE when the bug is fixed.
//
// Output file: <app sandbox>/Documents/dazzle_debug.log

import Foundation

public enum DazzleDebugLog {

    /// Path to the log file. Created lazily on first write.
    private static let url: URL = {
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("dazzle_debug.log")
    }()

    /// Single shared queue serialises writes from many threads.
    private static let queue = DispatchQueue(label: "dev.dazzle.debug.log")

    /// Write a multi-line block (header + body). Adds a leading newline
    /// when the file already has content, so consecutive blocks are
    /// visually separated.
    public static func writeBlock(_ s: String) {
        queue.async {
            append(s)
        }
    }

    /// Write a single token piece — no header decoration. Used inside
    /// the streaming callback so the file shows the model's exact
    /// output character-for-character.
    public static func writeRaw(_ s: String) {
        queue.async {
            append(s)
        }
    }

    /// Truncate the log file. Call once at app launch so each run gets
    /// a fresh log.
    public static func reset() {
        queue.async {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func append(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            }
        } else {
            try? data.write(to: url)
        }
    }
}
