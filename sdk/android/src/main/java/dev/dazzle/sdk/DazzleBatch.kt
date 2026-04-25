/*
 * Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
 * Licensed under the Apache License, Version 2.0.
 *
 * DazzleBatch.kt — high-level batch primitives (Phase 6).
 *
 * These helpers sit on top of the typed multi-key snapshot read and the
 * coalesced pipeline dispatch that ship in dazzle_transport.c + the Android
 * JNI bridge.  They let a retrieval or ingest path issue N operations with a
 * single JNI crossing:
 *
 *   • multiHashFields — N HMGETs → 1 crossing, 1 rwlock, snapshot-backed.
 *   • pipelineArgs    — N writes → 1 JNI trip, ring-buffer dispatch on
 *                       Android 12+ (io_uring batch notify).
 *
 * The iOS mirror lives in sdk/ios/Sources/DazzleBatch.swift.
 */

package dev.dazzle.sdk

/**
 * Snapshot-backed multi-key typed HMGET.  Each request is applied with the
 * active `prefix` so namespaced Dazzle facades behave naturally.
 *
 * ```kotlin
 * val rows = dazzle.multiHashFields(listOf(
 *     "user:1"      to listOf("name", "lang"),
 *     "sensor:temp" to listOf("last", "avg"),
 * ))
 * // rows[0] == listOf("ivan", "es")
 * // rows[1] == listOf("21.4", "20.1")
 * ```
 *
 * A key that is absent from the in-process snapshot falls back to a standard
 * HMGET via [HashKey.mGet], so callers always observe consistent semantics —
 * snapshot misses cost one extra pipe round-trip for that key, never a wrong
 * answer.
 */
fun Dazzle.multiHashFields(
    requests: List<Pair<String, List<String>>>
): List<List<String?>> {
    if (requests.isEmpty()) return emptyList()

    val prefixed: List<Pair<String, List<String>>> =
        requests.map { (k, fs) -> (prefix + k) to fs }

    val rows = server.directReadMFields(prefixed)
    if (rows != null) {
        return prefixed.mapIndexed { i, req ->
            val row = rows[i]
            if (row != null) row.toList()
            else pipeHashFieldsFallback(req.first, req.second)
        }
    }
    // Whole batch missed the snapshot — fall back per key.
    return prefixed.map { pipeHashFieldsFallback(it.first, it.second) }
}

/**
 * Coalesced pipeline dispatch at the [Dazzle] facade level — same transport
 * as [DazzleServer.directPipeline] but scoped to the current namespace.
 * Returns one RESP reply per command; the caller is responsible for parsing
 * them with [RespParser] if they need the structured form.
 */
fun Dazzle.pipelineArgs(commands: List<List<String>>): List<String?> =
    server.directPipeline(commands)

// ── internals ─────────────────────────────────────────────────────────────

private fun Dazzle.pipeHashFieldsFallback(
    key: String, fields: List<String>
): List<String?> {
    if (fields.isEmpty()) return emptyList()
    val args = arrayOf("HMGET", key, *fields.toTypedArray())
    return try {
        server.commandTyped(*args).asArray().map { it.asBulkOrNull() }
    } catch (_: Throwable) {
        List(fields.size) { null }
    }
}
