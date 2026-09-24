// OrecchinoWatchService.kt — "Watch in the background": a foreground service
// that keeps the process, and with it the app's one Flutter engine
// (OrecchinoApplication), running with the app closed. It does no work of
// its own; the Dart side keeps the detector link, the phone's receiver, the
// rules and the alerts going (lib/core/background/watch_service.dart).
//
// Types: connectedDevice (the detector), plus location when the location
// permission is granted and location is on (the phone's position for ranges
// and the detector's set_home); never dataSync. Started only from the app
// on screen (WatchPlugin), or where Android allows a background start for
// an associated companion device.
//
// The notification ("Orecchino watching · 2 drones · conflict watch on · T5
// connected") has Open, Pause 1 h (Dart mutes alerts and rests the phone's
// receiver for an hour) and Stop.
//
// Part of orecchino-esp32. SPDX-License-Identifier: GPL-3.0-or-later
package dev.bentley.orecchino_mobile

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.location.LocationManager
import android.os.Build
import android.os.IBinder

class OrecchinoWatchService : Service() {
    companion object {
        private const val CHANNEL = "orecchino_watch"
        private const val NOTIF_ID = 0x0A7C
        const val ACTION_START = "dev.bentley.orecchino.watch.START"
        const val ACTION_PAUSE = "dev.bentley.orecchino.watch.PAUSE"
        const val ACTION_STOP = "dev.bentley.orecchino.watch.STOP"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_LOCATION = "location"

        @Volatile
        var running = false
            private set

        /** Start it (from the app on screen). False when Android refused. */
        fun start(context: Context, text: String, location: Boolean): Boolean {
            val i = Intent(context, OrecchinoWatchService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_TEXT, text)
                .putExtra(EXTRA_LOCATION, location)
            return try {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i)
                true
            } catch (e: Exception) {
                false
            }
        }

        /** New words for the notification. */
        fun update(context: Context, text: String) {
            if (!running) return
            context.getSystemService(NotificationManager::class.java)?.notify(NOTIF_ID, notification(context, text))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, OrecchinoWatchService::class.java))
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            if (nm.getNotificationChannel(CHANNEL) != null) return
            val ch = NotificationChannel(CHANNEL, "Watching in the background", NotificationManager.IMPORTANCE_LOW)
            ch.description = "Shown while Orecchino watches with the app closed"
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }

        private fun notification(context: Context, text: String): Notification {
            ensureChannel(context)
            val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                flags,
            )
            fun service(code: Int, action: String) = PendingIntent.getService(
                context, code, Intent(context, OrecchinoWatchService::class.java).setAction(action), flags,
            )
            val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL)
            else @Suppress("DEPRECATION") Notification.Builder(context)
            return b.setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("Orecchino")
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setContentIntent(open)
                .addAction(Notification.Action.Builder(null as Icon?, "Open", open).build())
                .addAction(Notification.Action.Builder(null as Icon?, "Pause 1 h", service(1, ACTION_PAUSE)).build())
                .addAction(Notification.Action.Builder(null as Icon?, "Stop", service(2, ACTION_STOP)).build())
                .build()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        // The engine exists already when the app started us; make sure.
        OrecchinoApplication.engine(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE -> WatchPlugin.send("pause")
            ACTION_STOP -> {
                WatchPlugin.send("stop")
                running = false
                stopForegroundCompat()
                stopSelf()
            }
            else -> {
                val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Orecchino watching"
                val location = intent?.getBooleanExtra(EXTRA_LOCATION, false) ?: false
                if (!goForeground(text, location)) stopSelf()
            }
        }
        // Not restarted by itself after the process is gone: it starts again
        // when the app is opened (or the detector wakes the app).
        return START_NOT_STICKY
    }

    private fun locationAllowed(): Boolean {
        val granted = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
        if (!granted) return false
        val lm = getSystemService(LocationManager::class.java) ?: return false
        return if (Build.VERSION.SDK_INT >= 28) lm.isLocationEnabled else true
    }

    private fun goForeground(text: String, location: Boolean): Boolean {
        val n = notification(this, text)
        if (Build.VERSION.SDK_INT < 29) {
            return try {
                startForeground(NOTIF_ID, n)
                running = true
                true
            } catch (e: Exception) {
                false
            }
        }
        val device = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        val types = if (location && locationAllowed()) device or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else device
        for (t in listOf(types, device).distinct()) {
            try {
                startForeground(NOTIF_ID, n, t)
                running = true
                return true
            } catch (e: Exception) {
                // Not allowed with these types now (a permission missing):
                // try the detector link alone.
            }
        }
        return false
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        else @Suppress("DEPRECATION") stopForeground(true)
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }
}
