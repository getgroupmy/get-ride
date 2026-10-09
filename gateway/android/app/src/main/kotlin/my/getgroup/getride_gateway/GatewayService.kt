package my.getgroup.getride_gateway

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * The ongoing "GET.ride Gateway" notification. While it is up Android keeps
 * the app (and the gateway loop in it) running with the screen off, and a
 * partial wake lock keeps the loop's timers firing.
 */
class GatewayService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel(this)
        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "getride:gateway")
            .apply {
                setReferenceCounted(false)
                acquire()
            }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Online"
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification(this, text),
            if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0,
        )
        running = true
        // Not sticky: restarted without the app, the service would say
        // "online" while nothing is sending.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "gateway_status"
        private const val NOTIFICATION_ID = 1201
        private const val EXTRA_TEXT = "text"

        @Volatile
        var running = false
            private set

        /** Starts the service, or updates its notification's text when it is already up. */
        @SuppressLint("MissingPermission") // a refused notification is caught below
        fun start(context: Context, text: String) {
            if (running) {
                createChannel(context)
                try {
                    NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification(context, text))
                } catch (_: SecurityException) {
                    // Notifications not allowed: the service runs on regardless.
                }
                return
            }
            ContextCompat.startForegroundService(
                context,
                Intent(context, GatewayService::class.java).putExtra(EXTRA_TEXT, text),
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, GatewayService::class.java))
        }

        private fun createChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Gateway status", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shows that the gateway is running."
                },
            )
        }

        private fun notification(context: Context, text: String): Notification {
            val open = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE,
            )
            return NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_notify_chat)
                .setContentTitle("GET.ride Gateway")
                .setContentText(text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setContentIntent(open)
                .build()
        }
    }
}
