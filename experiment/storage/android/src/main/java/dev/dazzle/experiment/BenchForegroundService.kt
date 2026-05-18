// Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
// SPDX-License-Identifier: Apache-2.0
package dev.dazzle.experiment

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Persistent foreground service for the bench thread.
 *
 * EMUI (Huawei P20 Lite, Y9 2019, etc.) and increasingly stock Android
 * 12+ aggressively background-kill apps that don't run a foreground
 * service, even when they hold a partial wakelock and have
 * `FLAG_KEEP_SCREEN_ON` on the foreground activity. The bench thread
 * spends 5-15 minutes in native ObjectBox / Dazzle ingest at N=20 000
 * with no Java logging during that stretch, and the system marks the
 * activity as "idle" + reaps the process ("app died, no saved state").
 *
 * This service exists for the sole purpose of running with
 * `START_STICKY` and a persistent notification so EMUI / iAware /
 * standard Doze treat the process as foreground for the entire bench
 * duration. The bench logic itself stays in `VectorBenchmark.run` /
 * `StorageOnlyTest.run`; this service is a noisy bag-holder.
 *
 * Usage from Activity:
 *   ContextCompat.startForegroundService(ctx, Intent(ctx, BenchForegroundService::class.java))
 *   // ...run bench...
 *   ctx.stopService(Intent(ctx, BenchForegroundService::class.java))
 */
class BenchForegroundService : Service() {

    @Volatile private var heartbeatRunning = false
    private var heartbeatThread: Thread? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        startHeartbeat()
        return START_STICKY
    }

    override fun onDestroy() {
        heartbeatRunning = false
        heartbeatThread?.interrupt()
        super.onDestroy()
    }

    /**
     * Update the foreground notification every 4 seconds with a tick
     * counter. EMUI 9 iAware on Kirin 659 demotes our process to
     * `WORKINGSET_BACKGROUND` (subCmd 352) within ~10 s of foreground
     * grant if no system events fire in that window — even with the
     * activity resumed, screen on, wakelock held and the app on the
     * battery whitelist. Re-issuing the notification from a system
     * call (`NotificationManager.notify`) counts as activity, keeps
     * iAware's foreground-tracking timer fresh, and stops it from
     * pausing the bench thread mid-run.
     */
    private fun startHeartbeat() {
        if (heartbeatRunning) return
        heartbeatRunning = true
        heartbeatThread = Thread {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val t0 = System.currentTimeMillis()
            var tick = 0
            while (heartbeatRunning) {
                try {
                    Thread.sleep(4_000)
                } catch (_: InterruptedException) { break }
                if (!heartbeatRunning) break
                tick += 1
                val elapsedSec = (System.currentTimeMillis() - t0) / 1000
                try {
                    nm.notify(NOTIFICATION_ID, buildNotification(elapsedSec, tick))
                } catch (_: Throwable) { /* best-effort */ }
            }
        }.apply {
            name = "dazzle-bench-heartbeat"
            isDaemon = true
            start()
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        // EMUI 9 iAware (Kirin 659 / Helio G80) ignores low-importance
        // foreground notifications and pauses the process via
        // WorkingsetProcessCommand subCmd=357 (REVOKE) within ~1 s of
        // bench start. HIGH importance is the lowest tier where iAware
        // accepts that we genuinely want to run in the foreground.
        val ch = NotificationChannel(
            CHANNEL_ID,
            "Dazzle bench",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Long-running storage bench in progress"
            setShowBadge(false)
            enableVibration(false)
            enableLights(false)
            setSound(null, null)
        }
        nm.createNotificationChannel(ch)
    }

    private fun buildNotification(elapsedSec: Long = 0, tick: Int = 0): Notification {
        val text = if (tick == 0) "Running vector / storage benchmark"
                   else "Running… ${elapsedSec}s elapsed (#$tick)"
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Dazzle bench in progress")
            .setContentText(text)
            .setOngoing(true)
            // PRIORITY_HIGH is what EMUI iAware reads when deciding
            // whether to revoke working-set protection. PRIORITY_LOW
            // (the previous setting) was treated as 'best-effort' and
            // got paused mid-run on Kirin 659. The notification stays
            // silent (no sound / no vibrate / no lights via the
            // channel above) so the visual change is just a higher
            // ranking in the shade.
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            // setOnlyAlertOnce so the periodic heartbeat updates
            // don't re-show the notification's pop-up; we just want
            // the system to see "this app is alive" via the notify()
            // call, not pester the user.
            .setOnlyAlertOnce(true)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
        return builder.build()
    }

    companion object {
        // Bumped from "dazzle.bench.fg" → ".v2" so the channel is
        // recreated with IMPORTANCE_HIGH on devices that already had the
        // old IMPORTANCE_LOW channel cached (Android does not allow
        // re-creating a channel with a different importance — the
        // platform silently keeps the lower one). Existing installations
        // will end up with both channels visible in Settings; the v1
        // channel is unused and harmless.
        private const val CHANNEL_ID = "dazzle.bench.fg.v2"
        private const val NOTIFICATION_ID = 0xDA22 /* DAZZ */
    }
}
