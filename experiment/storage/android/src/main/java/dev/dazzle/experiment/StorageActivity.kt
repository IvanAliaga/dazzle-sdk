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

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.PowerManager
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import java.io.File

/**
 * StorageActivity — standalone storage-benchmark app.
 *
 * Runs StorageOnlyTest or ScaleBenchmark without Gemma.
 * Mirrors the storage-only path of ExperimentActivity in the LLM app but
 * lives in its own APK so the benchmark fleet can be split: storage runs
 * need no model file and finish in seconds; LLM runs need the 2.41 GB
 * Gemma model and take minutes.
 *
 * adb automation:
 *   # storage-only (all backends, 50 samples each):
 *   adb shell am start -n dev.dazzle.experiment.storage/.StorageActivity \
 *     --es backend dazzle
 *
 *   # scale benchmark:
 *   adb shell am start -n dev.dazzle.experiment.storage/.StorageActivity \
 *     --ez scale_benchmark true --es backend dazzle-precompute \
 *     --es scale_counts "200,1000,5000,20000"
 */
class StorageActivity : AppCompatActivity() {

    private lateinit var runButton: Button
    private lateinit var logText: TextView
    private lateinit var logScroll: ScrollView
    private var benchWakeLock: PowerManager.WakeLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Honour the cross-platform-bench override BEFORE the layout is
        // inflated -- inflating activity_storage triggers no native load,
        // but defensively we set the system property as the very first
        // act of onCreate so any code path that touches DazzleServer /
        // VectorIndex / LlamaNative below picks up the forced variant.
        intent.getStringExtra(EXTRA_FORCE_NATIVE_VARIANT)?.let { forced ->
            System.setProperty("dazzle.force_native_variant", forced)
            android.util.Log.i(
                TAG,
                "force_native_variant override: $forced",
            )
        }
        // RAG E2E SDK overrides — pass-through from `am start --es ... --ez ...`
        // so a bench operator can run a Q4_0 / no-flash-attn variant on a
        // tight-RAM device without rebuilding the APK. Read by RagE2EBench
        // via System.getProperty(...). Empty / missing extras keep the
        // paper-config defaults.
        intent.getStringExtra("kv_cache")?.let {
            System.setProperty("dazzle.bench.kv_cache", it)
            android.util.Log.i(TAG, "kv_cache override: $it")
        }
        if (intent.hasExtra("flash_attn")) {
            val v = intent.getBooleanExtra("flash_attn", true).toString()
            System.setProperty("dazzle.bench.flash_attn", v)
            android.util.Log.i(TAG, "flash_attn override: $v")
        }
        if (intent.hasExtra("use_mlock")) {
            val v = intent.getBooleanExtra("use_mlock", false).toString()
            System.setProperty("dazzle.bench.use_mlock", v)
            android.util.Log.i(TAG, "use_mlock override: $v")
        }
        intent.getStringExtra("n_threads")?.toIntOrNull()?.let {
            System.setProperty("dazzle.bench.n_threads", it.toString())
            android.util.Log.i(TAG, "n_threads override: $it")
        }
        intent.getStringExtra("ef_construction")?.toIntOrNull()?.let {
            System.setProperty("dazzle.bench.ef_construction", it.toString())
            android.util.Log.i(TAG, "ef_construction override: $it")
        }
        intent.getStringExtra("batch_threads")?.toIntOrNull()?.let {
            System.setProperty("dazzle.bench.batch_threads", it.toString())
            android.util.Log.i(TAG, "batch_threads override: $it")
        }
        intent.getStringExtra("algo")?.let {
            System.setProperty("dazzle.bench.algo", it.uppercase())
            android.util.Log.i(TAG, "algo override: $it")
        }
        intent.getStringExtra("max_queries")?.toIntOrNull()?.let {
            System.setProperty("dazzle.bench.max_queries", it.toString())
            android.util.Log.i(TAG, "max_queries override: $it")
        }
        setContentView(R.layout.activity_storage)
        // Keep the screen on while a long-running bench is in flight.
        // On Huawei devices the EMUI iAware daemon will otherwise
        // freeze the bench thread within ~7 seconds of activity
        // start, and the bench JSON never gets written. Combined
        // with the partial wakelock acquired below, this is enough
        // to keep the bench alive on every Huawei + Moto device we
        // run on.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        benchWakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "dazzle:bench"
        ).apply {
            setReferenceCounted(false)
            acquire(2 * 60 * 60 * 1000L /* 2h cap */)
        }
        // Promote the process to foreground via a persistent notification.
        // EMUI 10 (Huawei FRL-L23 / Y9 2019) kills the bench process
        // during the 10-15 min ObjectBox N=20000 ingest stretch even with
        // a held wakelock + FLAG_KEEP_SCREEN_ON ("app died, no saved
        // state"); the foreground service is the only signal the OS
        // unconditionally respects. No-op on chips that didn't need it.
        ContextCompat.startForegroundService(
            this, Intent(this, BenchForegroundService::class.java))

        runButton  = findViewById(R.id.runButton)
        logText    = findViewById(R.id.logText)
        logScroll  = findViewById(R.id.logScroll)

        val backend        = intent.getStringExtra(EXTRA_BACKEND) ?: "dazzle"
        val scaleBenchmark = intent.getBooleanExtra(EXTRA_SCALE_BENCHMARK, false)
        val scaleCounts    = intent.getStringExtra(EXTRA_SCALE_COUNTS)

        runButton.setOnClickListener {
            startBenchmark(backend = "dazzle", scale = false, scaleCounts = null)
        }

        // Automation launch
        if (scaleBenchmark) {
            val counts = scaleCounts?.split(",")?.mapNotNull { it.trim().toIntOrNull() }
                ?: ScaleBenchmark.DEFAULT_COUNTS
            log("[scale-benchmark] backend=$backend counts=$counts")
            Thread {
                try {
                    ScaleBenchmark(applicationContext).run(backend, counts)
                    writeCompletionMarker(ok = true, message = "scale ok")
                } catch (e: Exception) {
                    android.util.Log.e(TAG, "Scale benchmark failed", e)
                    writeCompletionMarker(ok = false, message = e.message ?: e.toString())
                }
                runOnUiThread { finish() }
                android.os.Process.killProcess(android.os.Process.myPid())
            }.start()
        } else if (intent.hasExtra(EXTRA_BACKEND)) {
            // Any explicit backend extra triggers a storage-only run
            log("[storage-only] backend=$backend")
            Thread {
                try {
                    StorageOnlyTest.run(applicationContext, backend)
                    writeCompletionMarker(ok = true, message = "storage-only ok")
                } catch (e: Exception) {
                    android.util.Log.e(TAG, "Storage test failed", e)
                    writeCompletionMarker(ok = false, message = e.message ?: e.toString())
                }
                runOnUiThread { finish() }
                android.os.Process.killProcess(android.os.Process.myPid())
            }.start()
        }
    }

    private fun startBenchmark(backend: String, scale: Boolean, scaleCounts: List<Int>?) {
        runButton.isEnabled = false
        logText.text = ""
        Thread {
            try {
                if (scale) {
                    ScaleBenchmark(applicationContext).run(backend, scaleCounts ?: ScaleBenchmark.DEFAULT_COUNTS)
                } else {
                    StorageOnlyTest.run(applicationContext, backend)
                }
                writeCompletionMarker(ok = true, message = "ok")
            } catch (e: Exception) {
                runOnUiThread { log("ERROR: ${e.message}\n${e.stackTraceToString()}") }
                writeCompletionMarker(ok = false, message = e.message ?: e.toString())
            } finally {
                runOnUiThread { runButton.isEnabled = true }
            }
        }.start()
    }

    override fun onDestroy() {
        try { benchWakeLock?.takeIf { it.isHeld }?.release() } catch (_: Exception) {}
        benchWakeLock = null
        super.onDestroy()
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
        private const val TAG = "StorageActivity"
        const val EXTRA_BACKEND         = "backend"
        const val EXTRA_SCALE_BENCHMARK = "scale_benchmark"
        const val EXTRA_SCALE_COUNTS    = "scale_counts"
        // Cross-platform "apples-to-apples" override -- forces every chip
        // to load the same libdazzle*.so. See DazzleNativeLoader for the
        // full doc and the safety caveat (forcing v82 on a chip without
        // asimdhp/asimddp will SIGILL).
        const val EXTRA_FORCE_NATIVE_VARIANT = "force_native_variant"
    }
}
