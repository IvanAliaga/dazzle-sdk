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

package dev.dazzle.sdk

/**
 * Per-command metrics hook. Plug your own implementation into
 * [DazzleConfig.metrics] to capture every command the library sends
 * — useful for Prometheus/Firebase-Performance instrumentation
 * without touching the Dazzle source.
 *
 * The default is a no-op ([None]) so the hot path stays zero-cost
 * when metrics are not required.
 *
 * Implementations MUST be thread-safe. Methods are called inline on
 * whichever thread just issued the command; do not block.
 */
interface DazzleMetrics {

    /**
     * Called after every directCommand / commandTyped completes (including
     * failures). [latencyNanos] is measured around the native JNI call, so
     * it covers the full in-process round-trip: JNI crossing + command
     * dispatch + server execution + reply extraction.
     *
     * @param command the command name (args[0]), uppercased
     * @param argc    number of arguments including the command name
     * @param latencyNanos wall-clock duration of the native call
     * @param success false if the native layer returned null or parsing threw
     */
    fun commandExecuted(command: String, argc: Int, latencyNanos: Long, success: Boolean)

    /** No-op metrics sink. Used when [DazzleConfig.metrics] is not overridden. */
    object None : DazzleMetrics {
        override fun commandExecuted(command: String, argc: Int, latencyNanos: Long, success: Boolean) {
            // intentionally empty
        }
    }

    companion object {
        /** Convenience alias matching the DazzleLogger pattern. */
        val DEFAULT: DazzleMetrics = None
    }
}
