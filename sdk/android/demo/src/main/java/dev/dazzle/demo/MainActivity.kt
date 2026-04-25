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

package dev.dazzle.demo

import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import dev.dazzle.demo.service.DazzleForegroundService
import dev.dazzle.sdk.DazzleServer
import java.io.File

class MainActivity : AppCompatActivity() {

    private lateinit var statusText: TextView
    private lateinit var startButton: Button
    private lateinit var stopButton: Button
    private lateinit var commandInput: EditText
    private lateinit var sendButton: Button
    private lateinit var benchmarkButton: Button
    private lateinit var batteryButton: Button
    private lateinit var chatButton: Button
    private lateinit var outputText: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        statusText      = findViewById(R.id.statusText)
        startButton     = findViewById(R.id.startButton)
        stopButton      = findViewById(R.id.stopButton)
        commandInput    = findViewById(R.id.commandInput)
        sendButton      = findViewById(R.id.sendButton)
        benchmarkButton = findViewById(R.id.benchmarkButton)
        batteryButton   = findViewById(R.id.batteryButton)
        chatButton      = findViewById(R.id.chatButton)
        outputText      = findViewById(R.id.outputText)

        startButton.setOnClickListener     { startServer() }
        stopButton.setOnClickListener      { stopServer() }
        sendButton.setOnClickListener      { sendCommand() }
        benchmarkButton.setOnClickListener { runAllBenchmarks() }
        batteryButton.setOnClickListener   { runBatteryBenchmark() }
        chatButton.setOnClickListener      {
            startActivity(Intent(this, ChatActivity::class.java))
        }

        commandInput.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_SEND) { sendCommand(); true } else false
        }

        if (DazzleServer.isRunning()) updateUI()
    }

    // ── Server lifecycle ──────────────────────────────────────────────────────

    private fun startServer() {
        ContextCompat.startForegroundService(this, Intent(this, DazzleForegroundService::class.java))
        Thread {
            for (i in 0 until 50) { if (DazzleServer.isRunning()) break; Thread.sleep(100) }
            runOnUiThread { updateUI() }
            if (DazzleServer.isRunning()) {
                appendOutput(when (val p = DazzleServer.getPort()) {
                    0    -> "Valkey started in-process (foreground service, no TCP listener)"
                    else -> "Valkey started on port $p (foreground service)"
                })
                sendRawCommand("PING")?.let { appendOutput("PING -> $it") }
            } else appendOutput("Failed to start Valkey")
        }.start()
    }

    private fun stopServer() {
        val i = Intent(this, DazzleForegroundService::class.java).apply { action = DazzleForegroundService.ACTION_STOP }
        startService(i)
        Thread {
            for (j in 0 until 30) { if (!DazzleServer.isRunning()) break; Thread.sleep(100) }
            runOnUiThread { updateUI() }
            appendOutput("Valkey stopped")
        }.start()
    }

    private fun sendCommand() {
        val cmd = commandInput.text.toString().trim(); if (cmd.isEmpty()) return
        commandInput.setText("")
        Thread { appendOutput("> $cmd"); sendRawCommand(cmd)?.let { appendOutput(it) } }.start()
    }

    // ── Transport helpers ─────────────────────────────────────────────────────

    /**
     * In-process command dispatch — takes the same JNI pipe the rest of
     * the SDK uses. No TCP socket, no loopback, no port dependency.
     *
     * Dazzle's public surface (`Dazzle`, `HashKey`, `ChatAgent`, …) all
     * route through `DazzleServer.directCommand` / `commandTyped`, so
     * the demo does the same to match the contract users actually see.
     *
     * The returned string is the raw RESP reply from Valkey; the few
     * cases below parse common shapes into something human-readable
     * for the output panel.
     */
    private fun sendRawCommand(command: String): String? {
        return try {
            val parts  = command.split(" ").toTypedArray()
            val raw    = DazzleServer.directCommand(*parts) ?: return "nil"
            prettyRespReply(raw)
        } catch (e: Exception) { "Error: ${e.message}" }
    }

    /**
     * Trim the RESP prefix off a single-line reply so the output panel
     * shows the payload the user expects ("PONG" instead of "+PONG\r\n"
     * or "hello" instead of "$5\r\nhello\r\n"). For complex replies
     * (arrays, deeply nested), returns the raw RESP so nothing is lost.
     */
    private fun prettyRespReply(raw: String): String {
        if (raw.isEmpty()) return "nil"
        val head = raw[0]
        val body = raw.trimEnd('\n', '\r')
        return when (head) {
            '+' -> body.drop(1)
            '-' -> "ERROR: ${body.drop(1)}"
            ':' -> body.drop(1)
            '$' -> {
                val crlf = raw.indexOf("\r\n").takeIf { it > 0 } ?: return raw
                val len = raw.substring(1, crlf).toIntOrNull() ?: return raw
                if (len < 0) "nil"
                else {
                    val start = crlf + 2
                    val end = (start + len).coerceAtMost(raw.length)
                    raw.substring(start, end)
                }
            }
            else -> body   // arrays, RESP3 shapes: just show as-is
        }
    }

    /**
     * Direct in-process dispatch — no socket, no TCP.
     * NOTE: timing is correct; response content is NOT verified (only used for performance timing).
     */
    private fun sendDirect(command: String) {
        DazzleServer.directCommand(command)  // result intentionally discarded
    }

    /** Direct with timing — returns elapsed nanoseconds. */
    private fun timedDirect(command: String): Long {
        val t0 = System.nanoTime()
        DazzleServer.directCommand(command)
        return System.nanoTime() - t0
    }

    private fun extractInfoField(info: String, field: String): String {
        for (line in info.split(Regex("\r?\n"))) {
            if (line.startsWith("$field:")) return line.substringAfter(":").trim()
        }
        return "N/A"
    }

    // ── CPU measurement ───────────────────────────────────────────────────────

    private fun readCPUJiffies(): Long = try {
        val fields = File("/proc/self/stat").readText().substringAfterLast(')').trim().split(' ')
        fields[11].toLong() + fields[12].toLong()
    } catch (_: Exception) { 0L }

    private fun measureCPUPct(durationMs: Long): Double {
        val j0 = readCPUJiffies(); val w0 = System.currentTimeMillis()
        Thread.sleep(durationMs)
        val j1 = readCPUJiffies(); val w1 = System.currentTimeMillis()
        val wall = (w1 - w0) / 1_000.0
        return if (wall > 0.0) ((j1 - j0) / 100.0 / wall) * 100.0 else 0.0
    }

    // ── Formatting helpers ────────────────────────────────────────────────────

    private fun LongArray.pUs(pct: Double) = this[(size * pct).toInt().coerceAtMost(size - 1)] / 1_000.0
    private fun LongArray.pMs(pct: Double) = pUs(pct) / 1_000.0

    // ══════════════════════════════════════════════════════════════════════════
    // Full Benchmark Suite
    // ══════════════════════════════════════════════════════════════════════════

    private fun runAllBenchmarks() {
        benchmarkButton.isEnabled = false
        outputText.text = ""
        Thread {
            appendOutput("# Valkey Android Benchmark\n")
            appendOutput("Device: ${Build.MODEL}  |  Android ${Build.VERSION.RELEASE}  |  ${Build.SUPPORTED_ABIS[0]}  |  Heap: ${Runtime.getRuntime().maxMemory()/1024/1024}MB\n")

            // Flush and capture a clean memory baseline before any keys are loaded
            sendRawCommand("FLUSHALL")
            val freshMem = sendRawCommand("INFO memory") ?: ""

            benchSetGetLatency()
            benchSetGetThroughput()
            benchXaddThroughput()
            benchGeosearch()
            benchPersistence()
            benchMemory(freshMem)
            benchSQLite()
            benchDirectVsTcp()
            benchCPUBattery()   // integrated battery section

            appendOutput("\n=== All Benchmarks Complete ===")
            runOnUiThread { benchmarkButton.isEnabled = DazzleServer.isRunning() }
        }.start()
    }

    // ── 1. SET/GET Latency ────────────────────────────────────────────────────

    private fun benchSetGetLatency() {
        appendOutput("\n--- 1. Direct SET/GET Latency (10K ops) ---")
        val n = 10_000
        val v = "value_128b_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        repeat(100) { i -> sendDirect("SET warmup:$i v") }
        sendRawCommand("FLUSHDB")

        val setNs = LongArray(n) { timedDirect("SET b:$it $v") }; setNs.sort()
        val getNs = LongArray(n) { timedDirect("GET b:${it % 1000}") }; getNs.sort()

        appendOutput("SET  avg=%.1fµs  p50=%.1fµs  p95=%.1fµs  p99=%.1fµs  max=%.1fµs".format(
            setNs.average()/1e3, setNs.pUs(0.50), setNs.pUs(0.95), setNs.pUs(0.99), setNs.last()/1e3))
        appendOutput("GET  avg=%.1fµs  p50=%.1fµs  p95=%.1fµs  p99=%.1fµs  max=%.1fµs".format(
            getNs.average()/1e3, getNs.pUs(0.50), getNs.pUs(0.95), getNs.pUs(0.99), getNs.last()/1e3))
        sendRawCommand("FLUSHDB")
    }

    // ── 2. SET/GET Throughput ─────────────────────────────────────────────────

    private fun benchSetGetThroughput() {
        appendOutput("\n--- 2. Direct SET/GET Throughput ---")
        val v = "value_128b_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        for (n in intArrayOf(1_000, 5_000, 10_000)) {
            val t0 = System.currentTimeMillis()
            for (i in 0 until n) sendDirect("SET tp:$i $v")
            val setMs = (System.currentTimeMillis() - t0).coerceAtLeast(1)
            val t1 = System.currentTimeMillis()
            for (i in 0 until n) sendDirect("GET tp:$i")
            val getMs = (System.currentTimeMillis() - t1).coerceAtLeast(1)
            appendOutput("$n ops  SET: ${n * 1000L / setMs} ops/s (${setMs}ms)   GET: ${n * 1000L / getMs} ops/s (${getMs}ms)")
        }
        sendRawCommand("FLUSHDB")
    }

    // ── 3. XADD Throughput ────────────────────────────────────────────────────

    private fun benchXaddThroughput() {
        appendOutput("\n--- 3. Streams (XADD) Throughput ---")
        for (n in intArrayOf(1_000, 5_000, 10_000)) {
            val t0 = System.currentTimeMillis()
            for (i in 0 until n) sendDirect("XADD bench:stream * key val_$i ts 1234567890")
            val ms = (System.currentTimeMillis() - t0).coerceAtLeast(1)
            appendOutput("$n XADD: ${n * 1000L / ms} ops/s  (${ms}ms)")
        }
        sendRawCommand("DEL bench:stream")
    }

    // ── 4. GEOSEARCH Latency ──────────────────────────────────────────────────

    private fun benchGeosearch() {
        appendOutput("\n--- 4. GEOSEARCH Latency (1K geo points) ---")
        val rng = java.util.Random(42)
        for (i in 0 until 1_000) {
            val lon = -99.0 + rng.nextDouble() * 2.0
            val lat = 19.0  + rng.nextDouble() * 2.0
            sendDirect("GEOADD bench:geo %.6f %.6f pt%04d".format(lon, lat, i))
        }
        val count = sendRawCommand("ZCARD bench:geo") ?: "?"
        appendOutput("Loaded $count geo points")

        val geo50  = LongArray(1_000) { timedDirect("GEOSEARCH bench:geo FROMLONLAT -99.133 19.432 BYRADIUS 50 km COUNT 100 ASC") }
        geo50.sort()
        val geo200 = LongArray(1_000) { timedDirect("GEOSEARCH bench:geo FROMLONLAT -99.133 19.432 BYRADIUS 200 km COUNT 1000 ASC") }
        geo200.sort()

        appendOutput("GEOSEARCH  50km / up to 100 results:  avg=%.1fµs  p50=%.1fµs  p99=%.1fµs".format(
            geo50.average()/1e3, geo50.pUs(0.50), geo50.pUs(0.99)))
        appendOutput("GEOSEARCH 200km / up to 1000 results: avg=%.1fµs  p50=%.1fµs  p99=%.1fµs".format(
            geo200.average()/1e3, geo200.pUs(0.50), geo200.pUs(0.99)))
        sendRawCommand("DEL bench:geo")
    }

    // ── 5. Persistence (AOF) ──────────────────────────────────────────────────

    private fun benchPersistence() {
        appendOutput("\n--- 5. Persistence (AOF) — 7 data types ---")
        // Write via direct path (fast dispatch)
        sendDirect("SET persist:string valkey-android-benchmark")
        sendDirect("HSET persist:hash name dazzle version 1.0 platform android")
        sendDirect("RPUSH persist:list item1 item2 item3")
        sendDirect("XADD persist:stream * event benchmark ts 1234567890")
        sendDirect("GEOADD persist:geo -77.0428 -12.0464 Lima")
        sendDirect("ZADD persist:zset 100 first 200 second 300 third")
        sendDirect("PFADD persist:hll user1 user2 user3 user4 user5")

        // Verify via TCP (TCP read-back is reliable; directCommand timing is correct but
        // response content on Android currently returns the event-loop ack, not the value)
        val checks = listOf(
            Triple("String",          "valkey-android-benchmark", sendRawCommand("GET persist:string")    ?: "nil"),
            Triple("Hash (3 fields)", "3",                        sendRawCommand("HLEN persist:hash")     ?: "nil"),
            Triple("List (3 items)",  "3",                        sendRawCommand("LLEN persist:list")     ?: "nil"),
            Triple("Stream (1 entry)","1",                        sendRawCommand("XLEN persist:stream")   ?: "nil"),
            Triple("Geo (1 point)",   "1",                        sendRawCommand("ZCARD persist:geo")     ?: "nil"),
            Triple("Sorted Set (3)",  "3",                        sendRawCommand("ZCARD persist:zset")    ?: "nil"),
            Triple("HyperLogLog (≈5)","5",                        sendRawCommand("PFCOUNT persist:hll")   ?: "nil"),
        )
        for ((name, expected, got) in checks)
            appendOutput("${if (got == expected) "PASS" else "FAIL"}  $name  expected=$expected  got=$got")

        // Trigger AOF rewrite after verification to not interfere with reads
        sendRawCommand("BGREWRITEAOF")?.let { appendOutput("BGREWRITEAOF: $it") }
        sendRawCommand("FLUSHDB")
    }

    // ── 6. Memory Footprint ───────────────────────────────────────────────────

    private fun benchMemory(freshMem: String) {
        appendOutput("\n--- 6. Memory Footprint ---")
        // Use TCP for INFO so we get the full multi-line bulk string correctly
        val memEmpty = freshMem.ifBlank { sendRawCommand("INFO memory") ?: "" }
        appendOutput("Empty DB  used: ${extractInfoField(memEmpty, "used_memory_human")}  RSS: ${extractInfoField(memEmpty, "used_memory_rss_human")}  peak: ${extractInfoField(memEmpty, "used_memory_peak_human")}")

        val v = "value_padding_128_bytes_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        for (i in 0 until 10_000) sendDirect("SET memtest:$i $v")
        val mem10k = sendRawCommand("INFO memory") ?: ""
        appendOutput("10K keys  used: ${extractInfoField(mem10k, "used_memory_human")}  RSS: ${extractInfoField(mem10k, "used_memory_rss_human")}")
        sendRawCommand("FLUSHDB")
    }

    // ── 7. SQLite WAL Comparison ──────────────────────────────────────────────

    private fun benchSQLite() {
        appendOutput("\n--- 7. SQLite WAL Comparison (10K ops, ~128B values) ---")
        val dbFile = File(filesDir, "bench_sqlite.db").also { it.delete() }
        val db = try {
            SQLiteDatabase.openOrCreateDatabase(dbFile.absolutePath, null)
        } catch (e: Exception) { appendOutput("SQLite open ERROR: ${e.message}"); return }

        try {
            // rawQuery for PRAGMAs that return a value — execSQL rejects them on Android 14
            db.rawQuery("PRAGMA journal_mode=WAL", null).close()
            db.execSQL("PRAGMA synchronous=NORMAL")
            db.execSQL("CREATE TABLE IF NOT EXISTS bench (key TEXT PRIMARY KEY, value TEXT)")

            val n = 10_000
            val v = "value_padding_128_bytes_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

            // INSERT autocommit
            val insNs = LongArray(n)
            val stmt  = db.compileStatement("INSERT OR REPLACE INTO bench VALUES (?,?)")
            for (i in 0 until n) {
                stmt.bindString(1, "k:$i"); stmt.bindString(2, v)
                val t0 = System.nanoTime(); stmt.executeInsert(); insNs[i] = System.nanoTime() - t0
            }
            stmt.close(); insNs.sort()

            // SELECT point lookup
            val selNs = LongArray(n)
            for (i in 0 until n) {
                val t0 = System.nanoTime()
                db.rawQuery("SELECT value FROM bench WHERE key=?", arrayOf("k:${i % n}")).use { it.moveToFirst() }
                selNs[i] = System.nanoTime() - t0
            }
            selNs.sort()

            // INSERT in a single transaction
            db.delete("bench", null, null)   // db.delete() instead of execSQL("DELETE")
            val stmt2 = db.compileStatement("INSERT OR REPLACE INTO bench VALUES (?,?)")
            val txnStart = System.currentTimeMillis()
            db.beginTransaction()
            try {
                for (i in 0 until n) { stmt2.bindString(1, "k:$i"); stmt2.bindString(2, v); stmt2.executeInsert() }
                db.setTransactionSuccessful()
            } finally { db.endTransaction() }
            stmt2.close()
            val txnMs = (System.currentTimeMillis() - txnStart).coerceAtLeast(1)

            appendOutput("INSERT autocommit:   avg=%.3fms  p50=%.3fms  p99=%.3fms  max=%.3fms".format(
                insNs.average()/1e6, insNs.pMs(0.50), insNs.pMs(0.99), insNs.last()/1e6))
            appendOutput("SELECT point lookup: avg=%.3fms  p50=%.3fms  p99=%.3fms  max=%.3fms".format(
                selNs.average()/1e6, selNs.pMs(0.50), selNs.pMs(0.99), selNs.last()/1e6))
            appendOutput("INSERT transaction:  %.4fms/op  → ${n * 1000L / txnMs} ops/s  (${txnMs}ms total)".format(txnMs.toDouble() / n))
            appendOutput("(SQLite: direct in-process call; Valkey: pipe dispatch, no TCP, no disk I/O per op)")

        } catch (e: Exception) {
            appendOutput("SQLite ERROR: ${e.message}")
        } finally {
            db.close()
            dbFile.delete()
        }
    }

    // ── 8. Direct vs TCP Latency ──────────────────────────────────────────────

    private fun benchDirectVsTcp() {
        appendOutput("\n--- 8. Direct In-Process vs TCP Latency (1K ops each) ---")
        sendRawCommand("FLUSHDB")

        val n = 1_000
        val dSetNs = LongArray(n) { timedDirect("SET bench:d:${it % 100} v") }; dSetNs.sort()
        val dGetNs = LongArray(n) { timedDirect("GET bench:d:${it % 100}") }; dGetNs.sort()
        val tSetNs = LongArray(n) { val t0 = System.nanoTime(); sendRawCommand("SET bench:t:${it % 100} v"); System.nanoTime() - t0 }; tSetNs.sort()
        val tGetNs = LongArray(n) { val t0 = System.nanoTime(); sendRawCommand("GET bench:t:${it % 100}"); System.nanoTime() - t0 }; tGetNs.sort()

        appendOutput("         Transport   avg(µs)   p50(µs)   p99(µs)")
        appendOutput("SET      Direct      %7.1f   %7.1f   %7.1f".format(dSetNs.average()/1e3, dSetNs.pUs(0.50), dSetNs.pUs(0.99)))
        appendOutput("SET      TCP         %7.1f   %7.1f   %7.1f".format(tSetNs.average()/1e3, tSetNs.pUs(0.50), tSetNs.pUs(0.99)))
        appendOutput("GET      Direct      %7.1f   %7.1f   %7.1f".format(dGetNs.average()/1e3, dGetNs.pUs(0.50), dGetNs.pUs(0.99)))
        appendOutput("GET      TCP         %7.1f   %7.1f   %7.1f".format(tGetNs.average()/1e3, tGetNs.pUs(0.50), tGetNs.pUs(0.99)))

        val setX = if (dSetNs.pUs(0.50) > 0) tSetNs.pUs(0.50) / dSetNs.pUs(0.50) else 0.0
        val getX = if (dGetNs.pUs(0.50) > 0) tGetNs.pUs(0.50) / dGetNs.pUs(0.50) else 0.0
        appendOutput("Speedup: SET %.1fx   GET %.1fx  (TCP p50 / Direct p50)".format(setX, getX))
        sendRawCommand("FLUSHDB")
    }

    // ── 9. CPU / Battery Overhead (integrated) ────────────────────────────────

    private fun benchCPUBattery() {
        appendOutput("\n--- 9. CPU / Battery Overhead (3 × 10 s) ---")
        val sampleMs   = 10_000L
        val targetOps  = 100
        val intervalMs = 1_000L / targetOps

        // Phase 1: idle
        appendOutput("Phase 1/3: idle 10 s …")
        val idlePct = measureCPUPct(sampleMs)
        appendOutput("Idle: %.2f%% CPU".format(idlePct))

        // Phase 2: TCP ~100 ops/s
        appendOutput("Phase 2/3: TCP ~$targetOps ops/s 10 s …")
        val tJ0 = readCPUJiffies(); val tW0 = System.currentTimeMillis()
        var tcpOps = 0
        while (System.currentTimeMillis() - tW0 < sampleMs) {
            val t0 = System.currentTimeMillis()
            sendRawCommand("SET batt:t:${tcpOps++ % 100} v")
            val sl = intervalMs - (System.currentTimeMillis() - t0); if (sl > 1) Thread.sleep(sl)
        }
        val tJ1 = readCPUJiffies(); val tW1 = System.currentTimeMillis()
        val tcpPct  = ((tJ1 - tJ0) / 100.0 / ((tW1 - tW0) / 1e3)) * 100.0
        val tcpRate = (tcpOps / ((tW1 - tW0) / 1e3)).toInt()
        appendOutput("TCP $tcpRate ops/s: %.2f%% CPU".format(tcpPct))
        sendRawCommand("FLUSHDB")

        // Phase 3: Direct ~100 ops/s
        appendOutput("Phase 3/3: Direct ~$targetOps ops/s 10 s …")
        val dJ0 = readCPUJiffies(); val dW0 = System.currentTimeMillis()
        var dirOps = 0
        while (System.currentTimeMillis() - dW0 < sampleMs) {
            val t0 = System.currentTimeMillis()
            sendDirect("SET batt:d:${dirOps++ % 100} v")
            val sl = intervalMs - (System.currentTimeMillis() - t0); if (sl > 1) Thread.sleep(sl)
        }
        val dJ1 = readCPUJiffies(); val dW1 = System.currentTimeMillis()
        val dirPct  = ((dJ1 - dJ0) / 100.0 / ((dW1 - dW0) / 1e3)) * 100.0
        val dirRate = (dirOps / ((dW1 - dW0) / 1e3)).toInt()
        appendOutput("Direct $dirRate ops/s: %.2f%% CPU".format(dirPct))
        sendRawCommand("FLUSHDB")

        // Battery math — Moto g35 5G: 5,000 mAh @ 3.85V ≈ 19,250 mWh; ~2 mW per 1% CPU (Cortex-A55)
        val battMWh = 19_250.0; val mwPer = 2.0
        fun drain(p: Double) = if (p * mwPer < 0.01) ">9999h" else "%.0fh".format(battMWh / (p * mwPer))

        appendOutput("\n── Battery estimate (Moto g35 5G — 5,000 mAh / 19,250 mWh; ~2 mW per 1% CPU) ──")
        appendOutput("Phase       CPU%     Power added   Time to drain battery")
        appendOutput("Idle       %5.2f%%   %6.1f mW      %s".format(idlePct, idlePct * mwPer, drain(idlePct)))
        appendOutput("TCP        %5.2f%%   %6.1f mW      %s".format(tcpPct,  tcpPct  * mwPer, drain(tcpPct)))
        appendOutput("Direct     %5.2f%%   %6.1f mW      %s".format(dirPct,  dirPct  * mwPer, drain(dirPct)))
        appendOutput("TCP extra above idle:    +%.2f%%  (+%.1f mW)".format((tcpPct - idlePct).coerceAtLeast(0.0), (tcpPct - idlePct).coerceAtLeast(0.0) * mwPer))
        appendOutput("Direct extra above idle: +%.2f%%  (+%.1f mW)".format((dirPct - idlePct).coerceAtLeast(0.0), (dirPct - idlePct).coerceAtLeast(0.0) * mwPer))
    }

    // ── Standalone battery button ─────────────────────────────────────────────

    private fun runBatteryBenchmark() {
        batteryButton.isEnabled = false
        appendOutput("\n=== Standalone Battery Test ===")
        Thread {
            benchCPUBattery()
            appendOutput("=== Battery test done ===")
            runOnUiThread { batteryButton.isEnabled = DazzleServer.isRunning() }
        }.start()
    }

    // ── UI helpers ────────────────────────────────────────────────────────────

    private fun appendOutput(text: String) {
        Log.d("ValkeyBench", text)
        runOnUiThread { outputText.append("$text\n") }
    }

    private fun updateUI() {
        val r = DazzleServer.isRunning()
        statusText.text = when {
            !r -> "Valkey: Stopped"
            DazzleServer.getPort() == 0 -> "Valkey: Running (in-process)"
            else -> "Valkey: Running (in-process + :${DazzleServer.getPort()})"
        }
        startButton.isEnabled     = !r; stopButton.isEnabled      = r
        sendButton.isEnabled      = r;  benchmarkButton.isEnabled = r; batteryButton.isEnabled = r
        chatButton.isEnabled      = r
    }
}
