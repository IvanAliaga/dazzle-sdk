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

package dev.dazzle.experiment

import dev.dazzle.sdk.DazzleServer
import java.io.BufferedInputStream
import java.io.BufferedWriter
import java.io.OutputStreamWriter
import java.net.Socket
import kotlin.math.max

/**
 * Stock-Valkey baseline that speaks RESP2 over TCP loopback.
 *
 * This backend is the "Valkey as you'd use it today" reference point in
 * the paper's comparison. Where [DazzleContextManager] dispatches every
 * command through the in-process pipe → ring → io_uring pipeline, this
 * one opens a real TCP socket to `127.0.0.1:<port>` and writes RESP2
 * frames on the wire — exactly what any app using a Jedis/Lettuce
 * client against a co-located Valkey server would pay per command.
 *
 * The server it talks to is still the same embedded Dazzle-patched
 * Valkey build (so command semantics match byte-for-byte). What varies
 * is the transport path:
 *
 *   Dazzle : app thread → self-pipe → server ae loop
 *   Valkey : app thread → kernel TCP → epoll → server ae loop
 *
 * Both backends store data in the exact same keys with the exact same
 * commands, so `buildContextBlock` produces byte-equivalent prompts;
 * the only variable across runs is the transport.
 */
class ValkeyContextManager(
    private val host: String = "127.0.0.1",
    private val port: Int = DazzleServer.getPort().takeIf { it > 0 } ?: 6380,
) : StorageBackend {

    override val backendName: String = "Valkey"

    private val socket: Socket = Socket(host, port).apply {
        tcpNoDelay = true
        soTimeout  = 10_000
    }
    private val writer = BufferedWriter(OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8))
    private val reader = BufferedInputStream(socket.getInputStream())

    // ── RESP encode / decode ─────────────────────────────────────────────

    /** Send one command as a RESP2 array and block until the reply parses. */
    private fun send(vararg args: String): Reply {
        val sb = StringBuilder()
        sb.append('*').append(args.size).append("\r\n")
        for (a in args) {
            sb.append('$').append(a.toByteArray(Charsets.UTF_8).size).append("\r\n")
            sb.append(a).append("\r\n")
        }
        writer.write(sb.toString())
        writer.flush()
        return readReply()
    }

    private fun readReply(): Reply {
        val marker = reader.read()
        if (marker < 0) throw IllegalStateException("socket closed")
        return when (marker.toChar()) {
            '+' -> Reply.Simple(readLine())
            '-' -> Reply.Error(readLine())
            ':' -> Reply.Integer(readLine().toLong())
            '$' -> {
                val n = readLine().toInt()
                if (n < 0) Reply.Bulk(null)
                else Reply.Bulk(readExact(n).also { readCrlf() })
            }
            '*' -> {
                val n = readLine().toInt()
                if (n < 0) Reply.Array(null)
                else Reply.Array(List(n) { readReply() })
            }
            else -> throw IllegalStateException("unknown RESP marker '${marker.toChar()}'")
        }
    }

    private fun readLine(): String {
        val out = StringBuilder()
        while (true) {
            val c = reader.read()
            if (c < 0) throw IllegalStateException("socket closed mid-line")
            if (c == '\r'.code) { reader.read(); return out.toString() }
            out.append(c.toChar())
        }
    }

    private fun readExact(n: Int): String {
        val buf = ByteArray(n)
        var off = 0
        while (off < n) {
            val r = reader.read(buf, off, n - off)
            if (r < 0) throw IllegalStateException("socket closed mid-bulk")
            off += r
        }
        return String(buf, Charsets.UTF_8)
    }

    private fun readCrlf() { reader.read(); reader.read() }

    private sealed class Reply {
        data class Simple(val value: String) : Reply()
        data class Error(val message: String) : Reply()
        data class Integer(val value: Long) : Reply()
        data class Bulk(val value: String?) : Reply()
        data class Array(val items: List<Reply>?) : Reply()
    }

    private fun Reply.asBulkOrNull(): String? = when (this) {
        is Reply.Bulk    -> value
        is Reply.Simple  -> value
        is Reply.Integer -> value.toString()
        else             -> null
    }

    private fun Reply.asArrayOfBulks(): List<String?> = when (this) {
        is Reply.Array   -> items?.map { it.asBulkOrNull() }.orEmpty()
        else             -> emptyList()
    }

    // ── StorageBackend ────────────────────────────────────────────────────

    override fun ingest(reading: SensorReading) {
        send(
            "XADD", "sensor:readings", "MAXLEN", "~", "200", "*",
            "temp",      reading.tempC.toString(),
            "humidity",  reading.humidity.toString(),
            "minute",    reading.minute.toString(),
            "anomalous", if (reading.anomalous) "1" else "0",
        )
        send("HINCRBYFLOAT", "sensor:stats", "temp_sum", reading.tempC.toString())
        send("HINCRBY",      "sensor:stats", "count",    "1")
        send("HSET",         "sensor:stats", "latest_temp",   reading.tempC.toString(),
                                              "latest_minute", reading.minute.toString())

        val curMin = send("HGET", "sensor:stats", "min_temp").asBulkOrNull()?.toDoubleOrNull()
        if (curMin == null || reading.tempC < curMin) {
            send("HSET", "sensor:stats", "min_temp", reading.tempC.toString())
        }
        val curMax = send("HGET", "sensor:stats", "max_temp").asBulkOrNull()?.toDoubleOrNull()
        if (curMax == null || reading.tempC > curMax) {
            send("HSET", "sensor:stats", "max_temp", reading.tempC.toString())
        }

        if (reading.anomalous) {
            send("ZADD", "sensor:anomalies", reading.minute.toString(), reading.minute.toString())
            send("HINCRBY", "sensor:stats", "anomaly_count", "1")
        }
    }

    override fun flush() {
        send("DEL", "sensor:readings", "sensor:stats", "sensor:anomalies", "agent:decisions")
        for (i in 0..9) send("DEL", "agent:checkpoint:$i")
    }

    override fun buildContextBlock(currentMinute: Int, windowMinutes: Int): String {
        val lines = mutableListOf<String>()

        // Last 10 entries — newest first
        val entries = send("XREVRANGE", "sensor:readings", "+", "-", "COUNT", "10")
        val temps = mutableListOf<Double>()
        (entries as? Reply.Array)?.items?.forEach { entry ->
            // entry is [id, [field, value, field, value, ...]]
            val pair = (entry as? Reply.Array)?.items ?: return@forEach
            val fields = (pair.getOrNull(1) as? Reply.Array)?.items ?: return@forEach
            var i = 0
            while (i < fields.size - 1) {
                if ((fields[i] as? Reply.Bulk)?.value == "temp") {
                    (fields[i + 1] as? Reply.Bulk)?.value?.toDoubleOrNull()?.let { temps.add(it) }
                    break
                }
                i += 2
            }
        }
        val recentTemps = temps.reversed()
        if (recentTemps.isNotEmpty()) {
            val formatted = recentTemps.joinToString(", ") { String.format("%.1f", it) }
            lines += "Last ${recentTemps.size} temperatures (oldest→newest, °C): $formatted"
            lines += "Recent trend: ${computeTrend(recentTemps)}"
        }

        // Aggregate stats via a single HMGET
        val statsReply = send("HMGET", "sensor:stats", "count", "temp_sum", "min_temp", "max_temp", "anomaly_count")
        val vals = statsReply.asArrayOfBulks()
        val count = vals.getOrNull(0)?.toIntOrNull()
        if (count != null && count > 0) {
            val sum    = vals.getOrNull(1)?.toDoubleOrNull() ?: 0.0
            val minT   = vals.getOrNull(2)?.toDoubleOrNull() ?: 0.0
            val maxT   = vals.getOrNull(3)?.toDoubleOrNull() ?: 0.0
            val anomCt = vals.getOrNull(4)?.toIntOrNull()    ?: 0
            lines += "Aggregate over $count readings: " +
                "avg=${String.format("%.1f", sum / count)}°C, " +
                "min=${String.format("%.1f", minT)}°C, " +
                "max=${String.format("%.1f", maxT)}°C"
            lines += "Total anomalies detected so far: $anomCt"
        }

        val windowStart = max(0, currentMinute - windowMinutes)
        val anomaliesInWindow = send(
            "ZRANGEBYSCORE", "sensor:anomalies",
            windowStart.toString(), currentMinute.toString()
        ).asArrayOfBulks().filterNotNull()
        if (anomaliesInWindow.isEmpty()) {
            lines += "No anomalies in the last $windowMinutes minutes."
        } else {
            lines += "Anomalous time indices in the last $windowMinutes minutes " +
                "(minute numbers, not temperatures): [${anomaliesInWindow.joinToString(", ")}]"
        }

        return lines.joinToString("\n")
    }

    override fun buildSynthesisContext(): String {
        val lines = mutableListOf<String>()
        val vals = send(
            "HMGET", "sensor:stats",
            "count", "temp_sum", "min_temp", "max_temp", "anomaly_count"
        ).asArrayOfBulks()
        val count = vals.getOrNull(0)?.toIntOrNull()
        if (count != null && count > 0) {
            val sum    = vals.getOrNull(1)?.toDoubleOrNull() ?: 0.0
            val minT   = vals.getOrNull(2)?.toDoubleOrNull() ?: 0.0
            val maxT   = vals.getOrNull(3)?.toDoubleOrNull() ?: 0.0
            val anomCt = vals.getOrNull(4)?.toIntOrNull()    ?: 0
            lines += "=== Full Session Stats ==="
            lines += "Total readings: $count"
            lines += "Temperature range: ${String.format("%.1f", minT)}°C to " +
                "${String.format("%.1f", maxT)}°C " +
                "(avg ${String.format("%.1f", sum / count)}°C)"
            lines += "Total anomalies detected: $anomCt"
        }

        val allAnomalies = send(
            "ZRANGEBYSCORE", "sensor:anomalies", "0", "99999"
        ).asArrayOfBulks().filterNotNull()
        if (allAnomalies.isNotEmpty()) {
            lines += "Anomalous time indices (minute numbers, not temperatures): " +
                "[${allAnomalies.joinToString(", ")}]"
        }

        val decisions = send("LRANGE", "agent:decisions", "0", "-1").asArrayOfBulks().filterNotNull()
        if (decisions.isNotEmpty()) {
            lines += "=== Monitoring Agent Decisions ==="
            decisions.forEachIndexed { i, d -> lines += "  Checkpoint ${i + 1}: $d" }
        }

        return lines.joinToString("\n")
    }

    override fun storeCheckpointDecision(
        index: Int,
        minute: Int,
        anomalyDetected: Boolean,
        severity: String,
        trend: String,
    ) {
        val decision = "anomaly=${if (anomalyDetected) "yes" else "no"} " +
            "severity=$severity trend=$trend"

        send(
            "HSET", "agent:checkpoint:$index",
            "minute",   minute.toString(),
            "anomaly",  if (anomalyDetected) "1" else "0",
            "severity", severity,
            "trend",    trend,
        )
        send("RPUSH", "agent:decisions", decision)
    }

    override fun measureRetrievalLatency(currentMinute: Int): Double {
        val start = System.nanoTime()
        buildContextBlock(currentMinute)
        val end = System.nanoTime()
        return (end - start) / 1_000.0
    }

    private fun computeTrend(temps: List<Double>): String {
        if (temps.size < 2) return "stable"
        val n = temps.size
        val meanX = (n - 1) / 2.0
        val meanY = temps.average()
        val num = (0 until n).sumOf { (it - meanX) * (temps[it] - meanY) }
        val den = (0 until n).sumOf { (it - meanX) * (it - meanX) }
        val slope = if (den != 0.0) num / den else 0.0
        return when {
            slope >  0.15 -> "increasing"
            slope < -0.15 -> "decreasing"
            else          -> "stable"
        }
    }

    // ── Footprint accounting ──────────────────────────────────────────────

    override val backendSizeMethod: String = "valkey:used_memory_dataset"

    /**
     * Issues an `INFO memory` over the same RESP socket and parses
     * the `used_memory_dataset` line. Stays loyal to the "as you'd
     * use Valkey in production" framing of this backend instead of
     * borrowing the in-process Dazzle SDK.
     */
    override fun backendSizeBytes(): Long {
        val raw = send("INFO", "memory").asBulkOrNull() ?: return -1L
        for (line in raw.lineSequence()) {
            val trimmed = line.trim()
            val colon = trimmed.indexOf(':')
            if (colon <= 0) continue
            val key = trimmed.substring(0, colon)
            if (key == "used_memory_dataset" || key == "used_memory") {
                val v = trimmed.substring(colon + 1).toLongOrNull()
                if (v != null && key == "used_memory_dataset") return v
                if (v != null && key == "used_memory") return v // fallback
            }
        }
        return -1L
    }
}
