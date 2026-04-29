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

package dev.dazzle.experiment

import android.os.Bundle
import android.widget.Button
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import dev.dazzle.experiment.multiagent.R
import java.io.File
import kotlinx.coroutines.launch

/**
 * Lightweight wrapper around MultiAgentTest — an entirely separate APK from the
 * LLM/storage/backends experiments so benchmark automation can target it
 * without booting the Gemma runtime.
 *
 * adb automation:
 *   adb shell am start -n dev.dazzle.experiment.multiagent/dev.dazzle.experiment.MultiAgentActivity \
 *       --es mode parallel --ei agents 8 --ei duration_sec 30 \
 *       [--ei read_pct 80] [--ez cluster_enabled true]
 *
 * Modes:  main_thread (default) | parallel
 */
class MultiAgentActivity : AppCompatActivity() {

    private lateinit var runButton: Button
    private lateinit var logText: TextView
    private lateinit var logScroll: ScrollView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_multiagent)

        runButton = findViewById(R.id.runButton)
        logText   = findViewById(R.id.logText)
        logScroll = findViewById(R.id.logScroll)

        val rawMode = intent.getStringExtra("mode")?.lowercase()
        val isSweep = rawMode == "sweep" || rawMode == "ablation"
        val opts = parseOptions()

        runButton.setOnClickListener { startBench(opts) }

        // Auto-launch if the caller passed any explicit param
        val autoRunKeys = listOf(
            "mode", "backend", "agents", "duration_sec", "cluster_enabled",
            "sweep_ks", "sweep_backends", "sweep_modes",
        )
        val autoRun = autoRunKeys.any { intent.hasExtra(it) }
        if (autoRun) {
            if (isSweep) {
                val sweepOpts = parseSweepOptions()
                log("[auto-run sweep] ks=${sweepOpts.ks} modes=${sweepOpts.modes.map { it.name }} " +
                    "backends=${sweepOpts.backends} dur=${sweepOpts.durationSec}s")
                lifecycleScope.launch {
                    try {
                        AblationSweep.run(applicationContext, sweepOpts) { line ->
                            runOnUiThread { log(line) }
                        }
                        writeCompletionMarker(ok = true, message = "ablation sweep ok")
                    } catch (e: Exception) {
                        android.util.Log.e(TAG, "AblationSweep failed", e)
                        writeCompletionMarker(ok = false, message = e.message ?: e.toString())
                    }
                    kotlinx.coroutines.delay(2000)
                    finish()
                    android.os.Process.killProcess(android.os.Process.myPid())
                }
            } else {
                log("[auto-run] mode=${opts.mode} agents=${opts.agents} dur=${opts.durationSec}s " +
                    "cluster=${opts.clusterEnabled}")
                lifecycleScope.launch {
                    try {
                        MultiAgentTest.run(applicationContext, opts) { line ->
                            runOnUiThread { log(line) }
                        }
                        writeCompletionMarker(ok = true, message = "multiagent ok")
                    } catch (e: Exception) {
                        android.util.Log.e(TAG, "MultiAgentTest failed", e)
                        writeCompletionMarker(ok = false, message = e.message ?: e.toString())
                    }
                    // Give the user a few seconds to read the summary before the
                    // process disappears on `adb am start` automation.
                    kotlinx.coroutines.delay(2000)
                    finish()
                    android.os.Process.killProcess(android.os.Process.myPid())
                }
            }
        }
    }

    private fun parseOptions(): MultiAgentTest.Options {
        val mode = when (intent.getStringExtra("mode")?.lowercase()) {
            "parallel", "parallel_reads" -> MultiAgentTest.Mode.PARALLEL_READS
            else -> MultiAgentTest.Mode.MAIN_THREAD
        }
        // Default matches the LLM experiment for apples-to-apples:
        // dazzle-precompute is the fastest retrieval technique and the variant
        // the LLM experiment uses by default. The Kotlin wrapper's rolling
        // window was made thread-safe via @Synchronized on ingest/flush so it
        // can handle K-agent concurrent load without CME.
        val backend     = intent.getStringExtra("backend") ?: "dazzle-precompute"
        val agents      = intent.getIntExtra("agents", 8).coerceAtLeast(1)
        val durationSec = intent.getIntExtra("duration_sec", 30).coerceAtLeast(1)
        val readPct     = intent.getIntExtra("read_pct", 80).coerceIn(0, 100)
        val cluster     = intent.getBooleanExtra("cluster_enabled", false)
        val workers     = intent.getIntExtra("worker_threads", 0).coerceAtLeast(0)
        return MultiAgentTest.Options(
            mode = mode,
            backend = backend,
            agents = agents,
            durationSec = durationSec,
            readPct = readPct,
            clusterEnabled = cluster,
            workerThreads = workers,
        )
    }

    private fun parseSweepOptions(): AblationSweep.Options {
        fun csv(key: String, default: List<String>): List<String> =
            intent.getStringExtra(key)
                ?.split(",")
                ?.map { it.trim() }
                ?.filter { it.isNotEmpty() }
                ?: default
        val ks = csv("sweep_ks", listOf("1", "2", "4", "8"))
            .mapNotNull { it.toIntOrNull() }
            .filter { it >= 1 }
        val backends = csv("sweep_backends", listOf("dazzle-precompute", "dazzle-incremental"))

        // Variants: either use the defaults (ablation stack) or build a
        // custom list from `sweep_variants` (comma-separated names from the
        // defaults) plus an optional raw override syntax for power users.
        val variantNames = csv("sweep_variants", emptyList())
        val variants = if (variantNames.isEmpty()) emptyList()
            else AblationSweep.defaultVariants.filter { it.name in variantNames }

        val duration = intent.getIntExtra("sweep_duration_sec", 20).coerceAtLeast(1)
        val readPct  = intent.getIntExtra("sweep_read_pct", 80).coerceIn(0, 100)
        val workers  = intent.getIntExtra("sweep_worker_threads", 0).coerceAtLeast(0)
        val warmup   = intent.getIntExtra("sweep_warmup_reps", 20).coerceAtLeast(0)
        return AblationSweep.Options(
            variants      = variants,
            ks            = ks.ifEmpty { listOf(1, 2, 4, 8) },
            backends      = backends.ifEmpty { listOf("dazzle-precompute") },
            durationSec   = duration,
            readPct       = readPct,
            workerThreads = workers,
            warmupReps    = warmup,
        )
    }

    private fun startBench(opts: MultiAgentTest.Options) {
        runButton.isEnabled = false
        logText.text = ""
        lifecycleScope.launch {
            try {
                MultiAgentTest.run(applicationContext, opts) { line ->
                    runOnUiThread { log(line) }
                }
                writeCompletionMarker(ok = true, message = "ok")
            } catch (e: Exception) {
                runOnUiThread { log("ERROR: ${e.message}\n${e.stackTraceToString()}") }
                writeCompletionMarker(ok = false, message = e.message ?: e.toString())
            } finally {
                runOnUiThread { runButton.isEnabled = true }
            }
        }
    }

    private fun writeCompletionMarker(ok: Boolean, message: String) {
        try {
            val docs = android.os.Environment.getExternalStoragePublicDirectory(
                android.os.Environment.DIRECTORY_DOCUMENTS
            )
            docs.mkdirs()
            val marker = File(docs, "experiment_android_complete.marker")
            marker.writeText("${System.currentTimeMillis()} ${if (ok) "ok" else "error"} $message\n")
        } catch (_: Exception) { /* best-effort */ }
    }

    private fun log(msg: String) {
        logText.append("$msg\n")
        logScroll.post { logScroll.fullScroll(ScrollView.FOCUS_DOWN) }
    }

    companion object {
        private const val TAG = "MultiAgentActivity"
    }
}
