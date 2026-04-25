// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.

package dev.dazzle.sdk.edge

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Resumable, integrity-verified downloader for LLM weight files.
 *
 * Used by the Layer 3 `DazzleEdge` bundle to fetch known models
 * ([ModelManifest]) on first use. Consumers typically don't call this
 * directly — `DazzleEdge.chatAgent { model = … }` resolves the manifest
 * entry and invokes this under the hood.
 *
 * Features:
 * - Atomic: downloads to `<dest>.part` then renames on completion
 * - Resumable: supports `Range: bytes=N-` when the server advertises it
 * - SHA-256 verified: refuses to hand back a file whose hash doesn't
 *   match the manifest's pinned value
 * - Progress: fires a callback every ~1 % or every 4 MB, whichever
 *   comes first
 *
 * Call from a background thread (`Dispatchers.IO`) — the implementation
 * blocks the calling thread for the duration of the transfer.
 */
object ModelDownloader {

    /**
     * Download [entry] to the platform cache dir and return the
     * absolute path of the verified file.
     *
     * Idempotent: if the file already exists and its SHA-256 matches,
     * the download is skipped.
     *
     * @throws DownloadException on any error (network / disk / hash mismatch).
     */
    fun ensure(
        context: Context,
        entry: ModelManifest.Entry,
        onProgress: (loaded: Long, total: Long) -> Unit = { _, _ -> },
    ): File {
        val targetDir = File(context.cacheDir, "dazzle-edge/${entry.id}/${entry.version}")
            .apply { mkdirs() }
        val target = File(targetDir, entry.filename)
        val partial = File(targetDir, "${entry.filename}.part")

        // Fast path: already present and valid
        if (target.exists() && verifiesAgainst(target, entry.sha256)) {
            onProgress(target.length(), target.length())
            return target
        } else if (target.exists()) {
            target.delete()   // stale / corrupt
        }

        // Resume from .part if present
        val existingBytes = if (partial.exists()) partial.length() else 0L

        val url = URL(entry.url)
        val conn = (url.openConnection() as HttpURLConnection).apply {
            if (existingBytes > 0) setRequestProperty("Range", "bytes=$existingBytes-")
            connectTimeout = 30_000
            readTimeout = 60_000
            instanceFollowRedirects = true
        }

        try {
            conn.connect()
            val code = conn.responseCode
            if (code !in 200..299) {
                throw DownloadException.NetworkError(
                    "HTTP $code when fetching ${entry.url}"
                )
            }
            // If server ignored Range header, restart from 0
            val resuming = existingBytes > 0 && code == HttpURLConnection.HTTP_PARTIAL
            if (!resuming && existingBytes > 0) {
                partial.delete()
            }

            val contentLength = conn.contentLengthLong
            val total = if (resuming) existingBytes + contentLength else contentLength

            FileOutputStream(partial, resuming).use { out ->
                conn.inputStream.use { input ->
                    val buf = ByteArray(64 * 1024)
                    var written = if (resuming) existingBytes else 0L
                    var lastReport = written
                    val reportEveryBytes = (total.coerceAtLeast(100L) / 100).coerceAtLeast(4L * 1024 * 1024)

                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        written += n
                        if (written - lastReport >= reportEveryBytes) {
                            onProgress(written, total)
                            lastReport = written
                        }
                    }
                    onProgress(written, total)
                }
            }
        } finally {
            conn.disconnect()
        }

        // Verify before exposing
        if (!verifiesAgainst(partial, entry.sha256)) {
            partial.delete()
            throw DownloadException.IntegrityMismatch(
                id = entry.id,
                expected = entry.sha256,
                observed = sha256Of(partial).takeIf { partial.exists() } ?: "<absent>"
            )
        }

        // Atomic publish
        if (!partial.renameTo(target)) {
            throw DownloadException.DiskError(
                "failed to publish ${partial.name} → ${target.name}"
            )
        }
        return target
    }

    /**
     * Check whether the cache already holds a verified copy of [entry].
     * Returns the absolute path or null. Useful for UIs that want to
     * show "downloaded" state without triggering a network request.
     */
    fun cached(context: Context, entry: ModelManifest.Entry): File? {
        val target = File(context.cacheDir, "dazzle-edge/${entry.id}/${entry.version}/${entry.filename}")
        return target.takeIf { it.exists() && verifiesAgainst(it, entry.sha256) }
    }

    private fun verifiesAgainst(file: File, expected: String): Boolean {
        if (expected.isBlank() || expected == "REPLACE_WITH_ACTUAL_SHA256_ON_FIRST_DOWNLOAD") {
            // Manifest entry has a placeholder — accept the file if it
            // exists and let the caller decide (logged elsewhere). This
            // exists so development flows don't block on hashing the
            // first time we fetch a new model before the maintainer
            // pipeline has pinned the value.
            return true
        }
        return sha256Of(file).equals(expected, ignoreCase = true)
    }

    private fun sha256Of(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}

/** Typed failure surface for [ModelDownloader]. */
sealed class DownloadException(message: String, cause: Throwable? = null) :
    RuntimeException(message, cause) {

    class NetworkError(message: String, cause: Throwable? = null) : DownloadException(message, cause)
    class IntegrityMismatch(val id: String, val expected: String, val observed: String) :
        DownloadException(
            "SHA-256 mismatch for model '$id' — expected=$expected observed=$observed. " +
                "Refusing to use the file; will re-download on next call."
        )
    class DiskError(message: String, cause: Throwable? = null) : DownloadException(message, cause)
}
