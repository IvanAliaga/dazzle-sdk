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

package dev.dazzle.demo.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import dev.dazzle.sdk.DazzleServer

class DazzleForegroundService : Service() {

    companion object {
        const val NOTIFICATION_ID = 1
        const val CHANNEL_ID = "valkey_service"
        const val ACTION_STOP = "dev.dazzle.demo.STOP_SERVICE"
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            DazzleServer.stop()
            stopSelf()
            return START_NOT_STICKY
        }

        // Must call startForeground within 10 seconds
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Valkey Database")
            .setContentText(when (val p = DazzleServer.getPort()) {
                0    -> "Server running in-process"
                else -> "Server running on port $p"
            })
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setShowWhen(false)
            .build()

        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                0x40000000 // FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            } else {
                0
            }
        )

        // Start Valkey if not already running
        if (!DazzleServer.isRunning()) {
            DazzleServer.start(applicationContext)
        }

        return START_STICKY
    }

    override fun onDestroy() {
        DazzleServer.stop()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Valkey Database",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Local database service"
            enableVibration(false)
            setSound(null, null)
        }
        getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
    }
}
