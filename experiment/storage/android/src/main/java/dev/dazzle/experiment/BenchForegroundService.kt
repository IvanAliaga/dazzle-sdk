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

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        return START_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val ch = NotificationChannel(
            CHANNEL_ID,
            "Dazzle bench",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Long-running storage bench in progress"
            setShowBadge(false)
        }
        nm.createNotificationChannel(ch)
    }

    private fun buildNotification(): Notification {
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Dazzle bench in progress")
            .setContentText("Running vector / storage benchmark")
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
        return builder.build()
    }

    companion object {
        private const val CHANNEL_ID = "dazzle.bench.fg"
        private const val NOTIFICATION_ID = 0xDA22 /* DAZZ */
    }
}
