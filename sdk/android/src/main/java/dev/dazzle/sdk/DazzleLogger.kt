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

import android.util.Log

/**
 * Injection point for Dazzle diagnostic output.
 *
 * The library emits log lines at four levels for startup events, config
 * decisions (port fallback, module resolution, wipe actions), transient
 * transport errors, and unexpected failures. By default those lines go to
 * `android.util.Log` under the tag Dazzle; swap the default out
 * in [DazzleConfig.logger] to route them to Timber, SLF4J, Crashlytics,
 * or whatever your app already uses.
 *
 * Methods are intentionally called on whichever thread the library
 * happens to be on. Implementations MUST be thread-safe.
 */
interface DazzleLogger {

    fun debug(tag: String, msg: String)
    fun info(tag: String, msg: String)
    fun warn(tag: String, msg: String)
    fun error(tag: String, msg: String, t: Throwable? = null)

    companion object {
        /** The logger used when [DazzleConfig.logger] is not overridden. */
        val DEFAULT: DazzleLogger = AndroidLogger
    }
}

/**
 * Default implementation that forwards to `android.util.Log`. All lines
 * go to a single tag so users can filter with `logcat -s dazzle`.
 */
internal object AndroidLogger : DazzleLogger {
    private const val TAG = "dazzle"
    override fun debug(tag: String, msg: String) { Log.d(TAG, "[$tag] $msg") }
    override fun info(tag: String, msg: String)  { Log.i(TAG, "[$tag] $msg") }
    override fun warn(tag: String, msg: String)  { Log.w(TAG, "[$tag] $msg") }
    override fun error(tag: String, msg: String, t: Throwable?) {
        Log.e(TAG, "[$tag] $msg", t)
    }
}
