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

import android.os.Bundle
import android.view.View
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import java.io.File

/**
 * ExperimentActivity — runs the Sequential Monitoring Agent experiment.
 *
 * Mirrors the iOS ExperimentView: kicks off ExperimentPipelineIoTPaper2 on a background
 * thread, streams progress into the log, and prints the final recall / FPR /
 * synthesis summary on completion. The output JSON lives in
 *   /sdcard/Documents/experiment_android_<MODEL>_<timestamp>.json
 * and follows the same schema as the iOS exporter so a single downstream
 * script can consume both platforms' results.
 */
class ExperimentActivityPaper2 : AppCompatActivity() {

    private lateinit var modelPathInput: EditText
    private lateinit var backendSpinner: Spinner
    private lateinit var runButton: Button
    private lateinit var progressBar: ProgressBar
    private lateinit var progressText: TextView
    private lateinit var logText: TextView
    private lateinit var logScroll: ScrollView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_experiment)

        modelPathInput = findViewById(R.id.modelPathInput)
        backendSpinner = findViewById(R.id.backendSpinner)
        runButton      = findViewById(R.id.runButton)
        progressBar    = findViewById(R.id.progressBar)
        progressText   = findViewById(R.id.progressText)
        logText        = findViewById(R.id.logText)
        logScroll      = findViewById(R.id.logScroll)

        // Backend picker — order places dazzle-precompute first so it's the
        // default. UI tester can flip between dazzle variants and disk-backed
        // backends to compare context-injection cost/quality at runtime,
        // without rebuilding or passing EXTRA_BACKEND over adb.
        val adapter = ArrayAdapter(this,
            android.R.layout.simple_spinner_item, AVAILABLE_BACKENDS)
        adapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        backendSpinner.adapter = adapter

        // Default model path — internal storage (world-accessible to the app, no permission issues)
        // Push model with: adb push gemma-4-E2B-it.litertlm /sdcard/Android/data/dev.dazzle.experiment/files/
        // then copy to internal: adb shell "cat /sdcard/Android/data/dev.dazzle.experiment/files/gemma-4-E2B-it.litertlm | run-as dev.dazzle.experiment dd of=/data/data/dev.dazzle.experiment/files/gemma-4-E2B-it.litertlm bs=1048576"
        val defaultPath = filesDir.absolutePath + "/gemma-4-E2B-it.litertlm"
        modelPathInput.setText(defaultPath)

        runButton.setOnClickListener {
            val backend = (backendSpinner.selectedItem as? String) ?: DEFAULT_BACKEND
            startExperiment(runCount = 1, finishWhenDone = false, backendName = backend)
        }

        // ── Automation hook ───────────────────────────────────────────────────
        // Launch with:
        //   adb shell am start -n dev.dazzle.experiment/.ExperimentActivity \
        //     --ez auto_run true --ei run_count 5 --es backend valkey
        // Supported backends: valkey (default), sqlite, rocksdb, objectbox
        val autoRun  = intent.getBooleanExtra(EXTRA_AUTO_RUN, false)
        val runCount = intent.getIntExtra(EXTRA_RUN_COUNT, 1).coerceAtLeast(1)
        val backend  = intent.getStringExtra(EXTRA_BACKEND) ?: DEFAULT_BACKEND
        // Mirror the picker state so any UI run after auto-run exits picks up
        // the same backend the driver script selected.
        AVAILABLE_BACKENDS.indexOf(backend).takeIf { it >= 0 }?.let { idx ->
            backendSpinner.setSelection(idx)
        }
        val storageOnly = intent.getBooleanExtra(EXTRA_STORAGE_ONLY, false)
        val scaleBenchmark = intent.getBooleanExtra(EXTRA_SCALE_BENCHMARK, false)
        val scaleCounts = intent.getStringExtra(EXTRA_SCALE_COUNTS)
        if (scaleBenchmark) {
            val counts = scaleCounts?.split(",")?.mapNotNull { it.trim().toIntOrNull() }
                ?: ScaleBenchmark.DEFAULT_COUNTS
            log("[scale-benchmark] backend=$backend counts=$counts")
            Thread {
                try {
                    ScaleBenchmark(applicationContext).run(backend, counts)
                    writeCompletionMarker(ok = true, message = "scale ok")
                } catch (e: Exception) {
                    android.util.Log.e("ScaleBench", "Failed", e)
                    writeCompletionMarker(ok = false, message = e.message ?: e.toString())
                }
                runOnUiThread { finish() }
                android.os.Process.killProcess(android.os.Process.myPid())
            }.start()
        } else if (storageOnly) {
            log("[storage-only] backend=$backend — testing without Gemma")
            Thread {
                try {
                    StorageOnlyTest.run(applicationContext, backend)
                    writeCompletionMarker(ok = true, message = "storage-only ok")
                } catch (e: Exception) {
                    android.util.Log.e("StorageTest", "Failed", e)
                    writeCompletionMarker(ok = false, message = e.message ?: e.toString())
                }
                runOnUiThread { finish() }
                android.os.Process.killProcess(android.os.Process.myPid())
            }.start()
        } else if (autoRun) {
            log("[auto-run] backend=$backend runs=$runCount — activity will finish when done")
            startExperiment(runCount = runCount, finishWhenDone = true, backendName = backend)
        }
    }

    private fun startExperiment(runCount: Int, finishWhenDone: Boolean, backendName: String = DEFAULT_BACKEND) {
        val modelPath = modelPathInput.text.toString().trim()
        if (modelPath.isEmpty()) {
            log("ERROR: enter model path first")
            writeCompletionMarker(ok = false, message = "empty model path")
            if (finishWhenDone) finish()
            return
        }
        if (!File(modelPath).exists()) {
            log("ERROR: model file not found at $modelPath")
            log("Download the Gemma model and push it with:")
            log("  adb push gemma-4-E2B-it.litertlm /sdcard/Android/data/dev.dazzle.experiment/files/")
            writeCompletionMarker(ok = false, message = "model missing at $modelPath")
            if (finishWhenDone) finish()
            return
        }

        runButton.isEnabled = false
        progressBar.visibility = View.VISIBLE
        logText.text = ""

        Thread {
            var failed: String? = null
            try {
                for (runIndex in 1..runCount) {
                    runOnUiThread { log("\n══════════ RUN $runIndex / $runCount ══════════") }
                    val pipeline = ExperimentPipelineIoTPaper2(
                        context     = applicationContext,
                        modelPath   = modelPath,
                        backendName = backendName,
                        onProgress  = { current, total, message ->
                            runOnUiThread {
                                log(message)
                                if (total > 0) {
                                    progressBar.max      = total
                                    progressBar.progress = current
                                    progressText.text    = "run $runIndex/$runCount — $current / $total"
                                }
                            }
                        }
                    )
                    pipeline.run()
                }
            } catch (e: Exception) {
                failed = e.message ?: e.toString()
                runOnUiThread { log("ERROR: $failed\n${e.stackTraceToString()}") }
            } finally {
                runOnUiThread {
                    runButton.isEnabled = true
                    progressBar.visibility = View.GONE
                }
                writeCompletionMarker(
                    ok = failed == null,
                    message = failed ?: "ok ($runCount run(s))",
                )
                if (finishWhenDone) {
                    runOnUiThread {
                        finishAndRemoveTask()
                        // LiteRT-LM's native Engine does NOT support re-init in
                        // the same process: the second ctor call segfaults
                        // (SIGSEGV in memtest_preserving_test, observed on Moto
                        // G35 4/15). Kill the whole process so the next
                        // `am start` from the driver script gets a clean slate.
                        android.os.Process.killProcess(android.os.Process.myPid())
                    }
                }
            }
        }.start()
    }

    /**
     * Drop a marker file into /sdcard/Documents so the driver script can poll
     * for completion without parsing logcat. The payload is a single line with
     * timestamp, status, and message — cheap to tail.
     */
    private fun writeCompletionMarker(ok: Boolean, message: String) {
        val line = "${System.currentTimeMillis()} ${if (ok) "ok" else "error"} $message\n"
        // Three-level fallback — same strategy as saveResults, so the driver
        // script can poll at either location on any Android version.
        val dir = try {
            val docs = android.os.Environment.getExternalStoragePublicDirectory(
                android.os.Environment.DIRECTORY_DOCUMENTS
            )
            docs.mkdirs()
            if (docs.canWrite()) docs
            else getExternalFilesDir(android.os.Environment.DIRECTORY_DOCUMENTS)?.also { it.mkdirs() }
                ?: filesDir
        } catch (_: Exception) {
            getExternalFilesDir(android.os.Environment.DIRECTORY_DOCUMENTS)?.also { it.mkdirs() }
                ?: filesDir
        }
        try {
            File(dir, "experiment_android_complete.marker").writeText(line)
        } catch (_: Exception) {
            try { File(filesDir, "experiment_android_complete.marker").writeText(line) } catch (_: Exception) {}
        }
    }

    private fun log(msg: String) {
        logText.append("$msg\n")
        logScroll.post { logScroll.fullScroll(ScrollView.FOCUS_DOWN) }
    }

    companion object {
        const val EXTRA_AUTO_RUN         = "auto_run"
        const val EXTRA_RUN_COUNT        = "run_count"
        const val EXTRA_BACKEND          = "backend"
        const val EXTRA_STORAGE_ONLY     = "test_storage_only"
        const val EXTRA_SCALE_BENCHMARK  = "scale_benchmark"
        const val EXTRA_SCALE_COUNTS     = "scale_counts"

        // Default retrieval technique. Plan-01 measurements show precompute
        // is the fastest path (≈36 µs on iPhone 12 Pro / ≈520 µs on Moto G35),
        // so it's the baseline users should see unless they explicitly pick
        // something else to compare.
        const val DEFAULT_BACKEND = "dazzle-precompute"

        // Order mirrors the iOS Picker so both platforms show the same
        // options in the same sequence.
        val AVAILABLE_BACKENDS: List<String> = listOf(
            "dazzle-precompute",
            "dazzle-vector",
            "dazzle",
            "dazzle-pipeline",
            "dazzle-hfe",
            "dazzle-hll",
            "dazzle-lua",
            "valkey",
            "sqlite",
            "objectbox",
            "lmdb",
            "rocksdb",
            "inmemory",
        )
    }
}
