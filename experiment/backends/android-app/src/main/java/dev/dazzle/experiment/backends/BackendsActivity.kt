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

package dev.dazzle.experiment.backends

import android.os.Bundle
import android.view.View
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.dazzle.experiment.StorageOnlyTest
import java.io.File

/**
 * BackendsActivity — interactive runner for individual backend tests.
 *
 * Mirrors `BackendsView.swift` on iOS: lets the user pick any single backend
 * and execute StorageOnlyTest against it. Useful for developing/validating
 * a backend in isolation without the LLM or the full multi-backend sweep
 * that the storage app drives via adb.
 */
class BackendsActivity : AppCompatActivity() {

    private lateinit var backendSpinner: Spinner
    private lateinit var runButton: Button
    private lateinit var logText: TextView
    private lateinit var logScroll: ScrollView

    private val backends = listOf(
        "dazzle", "dazzle-lua", "dazzle-pipeline",
        "dazzle-hfe", "dazzle-hll", "dazzle-precompute", "dazzle-incremental",
        "dazzle-vector",
        "valkey", "sqlite", "sqlite-optimized", "sqlite-precompute", "inmemory",
        "lmdb", "rocksdb", "objectbox",
    )

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_backends)

        backendSpinner = findViewById(R.id.backendSpinner)
        runButton      = findViewById(R.id.runButton)
        logText        = findViewById(R.id.logText)
        logScroll      = findViewById(R.id.logScroll)

        backendSpinner.adapter = ArrayAdapter(
            this,
            android.R.layout.simple_spinner_dropdown_item,
            backends,
        )

        runButton.setOnClickListener {
            val backend = backendSpinner.selectedItem as String
            startBackendTest(backend)
        }

        // Auto-start if launched via adb with --es backend <name>
        intent.getStringExtra("backend")?.let { backend ->
            val idx = backends.indexOf(backend.lowercase())
            if (idx >= 0) backendSpinner.setSelection(idx)
            startBackendTest(backend.lowercase())
        }
    }

    private fun startBackendTest(backend: String) {
        runButton.isEnabled = false
        logText.text = ""
        log("Running $backend…")
        Thread {
            try {
                StorageOnlyTest.run(applicationContext, backend)
                runOnUiThread {
                    log("Done. Check Documents/ for JSON results.")
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

    private fun writeCompletionMarker(ok: Boolean, message: String) {
        try {
            val docs = android.os.Environment.getExternalStoragePublicDirectory(
                android.os.Environment.DIRECTORY_DOCUMENTS
            )
            docs.mkdirs()
            File(docs, "experiment_backends_complete.marker").writeText(
                "${System.currentTimeMillis()} ${if (ok) "ok" else "error"} $message\n"
            )
        } catch (_: Exception) { /* best-effort */ }
    }

    private fun log(msg: String) {
        logText.append("$msg\n")
        logScroll.post { logScroll.fullScroll(ScrollView.FOCUS_DOWN) }
    }
}
