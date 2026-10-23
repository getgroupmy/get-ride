package my.getgroup.get_ride

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.location.LocationRequest
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * God View's "Live now" (migration 0282, lib/src/core/god_view_live.dart):
 * while an admin streams this person, the phone sends its position every 5
 * seconds to push_live_location with the install's key (BackgroundLocation.kt),
 * until the share ends or the server answers that it is over (stopped early).
 * A foreground service of type location, so it keeps going with the app
 * closed when location is allowed all the time; its notification is the
 * person's notice ("Shared live with support", the time left counting
 * down). Started by a `location_live` push (LocationPingReceiver) or by the
 * open app that found a share on (lib/src/data/live_share.dart).
 */
object LiveLocation {
    const val CHANNEL_ID = "live_share"
    const val NOTIFICATION_ID = 7315
    internal const val EXTRA_UNTIL = "until"

    /** The longest share (the server's own limit is an hour). */
    internal const val MAX_MS = 61 * 60 * 1000L

    /** How often a position goes, as the server takes them (one in 4 s). */
    internal const val EVERY_MS = 5_000L

    /**
     * Starts the service, or tells a running one the end ([untilMs], epoch
     * ms; 0 when not known yet). False when Android refuses it (no "all the
     * time", or a start from the background it does not allow).
     */
    fun start(context: Context, untilMs: Long): Boolean {
        if (!BackgroundLocation.ready(context)) return false
        val intent = Intent(context, LiveLocationService::class.java).putExtra(EXTRA_UNTIL, untilMs)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            true
        } catch (e: Exception) {
            false
        }
    }
}

class LiveLocationService : Service(), LocationListener {
    private val main = Handler(Looper.getMainLooper())
    private var until = 0L
    private var posting = false
    private var listening = false
    private var detailsSent = false
    private var latest: Location? = null
    private var lastSent = 0L

    // A phone standing still may get no new fix: the last one goes again.
    private val tick = object : Runnable {
        override fun run() {
            if (System.currentTimeMillis() >= until) {
                stopSelf()
                return
            }
            val fix = latest
            if (fix != null && System.currentTimeMillis() - lastSent >= LiveLocation.EVERY_MS + 2_000L) send(fix)
            main.postDelayed(this, LiveLocation.EVERY_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val now = System.currentTimeMillis()
        val asked = intent?.getLongExtra(LiveLocation.EXTRA_UNTIL, 0L) ?: 0L
        // The push carries no end: an hour at most, until the server says.
        if (asked > now) {
            until = minOf(asked, now + LiveLocation.MAX_MS)
        } else if (until == 0L) {
            until = now + LiveLocation.MAX_MS
        }
        if (!BackgroundLocation.ready(applicationContext) || !inForeground()) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (!listening) listen()
        if (!detailsSent) {
            detailsSent = true
            PhoneDetailsReport.send(applicationContext) {}
        }
        main.removeCallbacks(tick)
        main.postDelayed(tick, LiveLocation.EVERY_MS)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        main.removeCallbacks(tick)
        try {
            (getSystemService(Context.LOCATION_SERVICE) as? LocationManager)?.removeUpdates(this)
        } catch (e: Exception) {
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    private fun listen() {
        val manager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && manager.hasProvider(LocationManager.FUSED_PROVIDER)) {
                val request = LocationRequest.Builder(LiveLocation.EVERY_MS)
                    .setQuality(LocationRequest.QUALITY_HIGH_ACCURACY)
                    .setMinUpdateIntervalMillis(LiveLocation.EVERY_MS - 1_000L)
                    .build()
                manager.requestLocationUpdates(LocationManager.FUSED_PROVIDER, request, mainExecutor, this)
            } else {
                for (p in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
                    if (manager.allProviders.contains(p) && manager.isProviderEnabled(p)) {
                        manager.requestLocationUpdates(p, LiveLocation.EVERY_MS, 0f, this, Looper.getMainLooper())
                    }
                }
            }
            listening = true
        } catch (e: SecurityException) {
            stopSelf()
        } catch (e: IllegalArgumentException) {
            stopSelf()
        }
    }

    override fun onLocationChanged(location: Location) {
        latest = location
        send(location)
    }

    @Deprecated("Deprecated in Java")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

    override fun onProviderEnabled(provider: String) {}

    override fun onProviderDisabled(provider: String) {}

    /** One position; the answer says how long is left, or that it is over. */
    private fun send(fix: Location) {
        if (posting) return
        val key = BackgroundLocation.key(applicationContext) ?: run {
            stopSelf()
            return
        }
        posting = true
        val app = applicationContext
        thread(name = "live-location") {
            val body = JSONObject()
                .put("p_key", key)
                .put("p_lat", fix.latitude)
                .put("p_lng", fix.longitude)
            if (fix.hasSpeed()) body.put("p_speed", fix.speed.toDouble())
            if (fix.hasAccuracy()) body.put("p_accuracy", fix.accuracy.toDouble())
            val answer = try {
                BackgroundLocation.rpc(app, "push_live_location", body)?.let { JSONObject(it) }
            } catch (e: Exception) {
                null
            }
            main.post {
                posting = false
                lastSent = System.currentTimeMillis()
                // No answer (no signal): keep trying until the end.
                if (answer == null) return@post
                if (!answer.optBoolean("live", false)) {
                    stopSelf()
                    return@post
                }
                val left = answer.optLong("ends_in", -1L)
                if (left >= 0) {
                    val next = System.currentTimeMillis() + left * 1000L
                    if (kotlin.math.abs(next - until) > 2_000L) {
                        until = next
                        inForeground()
                    }
                }
            }
        }
    }

    /** The notification, shown (or updated); false when Android refuses it. */
    private fun inForeground(): Boolean {
        val n = notification()
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(LiveLocation.NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
            } else {
                startForeground(LiveLocation.NOTIFICATION_ID, n)
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager?.getNotificationChannel(LiveLocation.CHANNEL_ID) == null) {
            val channel = NotificationChannel(LiveLocation.CHANNEL_ID, "Shared live with support", NotificationManager.IMPORTANCE_LOW).apply {
                description = "While get.ride support sees where you are, live"
                setShowBadge(false)
            }
            manager?.createNotificationChannel(channel)
        }
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, LiveLocation.CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        val open = PendingIntent.getActivity(
            this,
            LiveLocation.NOTIFICATION_ID,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        b.setSmallIcon(R.drawable.ic_live_share)
            .setContentTitle("Shared live with support")
            .setContentText("get.ride support sees where you are, every 5 s, until the time is up.")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(open)
        // The time left, counting down on its own.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            b.setWhen(until).setShowWhen(true).setUsesChronometer(true).setChronometerCountDown(true)
        }
        return b.build()
    }
}

/**
 * The phone's details for Admin's Phone card (migration 0282): battery,
 * network, storage, app version and permissions, read without asking
 * anything (NetworkInfoChannel), sent with the install's key to
 * push_background_details after a ping's fix or as a live share starts.
 * The server takes them only when it asked.
 */
object PhoneDetailsReport {
    fun send(context: Context, done: () -> Unit) {
        val key = BackgroundLocation.key(context)
        if (key == null) {
            done()
            return
        }
        thread(name = "phone-details") {
            try {
                BackgroundLocation.rpc(
                    context,
                    "push_background_details",
                    JSONObject().put("p_key", key).put("p_details", details(context)),
                )
            } catch (e: Exception) {
                // Best effort: the next ping asks again.
            } finally {
                Handler(Looper.getMainLooper()).post(done)
            }
        }
    }

    /** The Phone card's keys (lib/src/core/phone_details.dart, PhoneExtra and the session columns). */
    private fun details(context: Context): JSONObject {
        val net = NetworkInfoChannel(context, null).info()
        val out = JSONObject()
        fun put(k: String, v: Any?) {
            if (v != null && !(v is String && v.isBlank())) out.put(k, v)
        }
        fun text(k: String): String? = (net[k] as? String)?.takeIf { it.isNotBlank() }
        put("network_type", net["type"])
        put("network_is_connected", net["connected"])
        put("network_is_internet_reachable", net["internet"])
        put("network_operator", text("networkOperatorName") ?: text("carrierName"))
        put("mobile_operator_name", text("simOperatorName") ?: text("carrierName"))
        put("battery_pct", net["batteryPct"])
        put("battery_charging", net["batteryCharging"])
        put("storage_free_bytes", net["storageFree"])
        put("storage_total_bytes", net["storageTotal"])
        put("os_version", "Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})")
        try {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            put("app_version", info.versionName)
            @Suppress("DEPRECATION")
            put("app_build_version", if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode.toString() else info.versionCode.toString())
        } catch (e: Exception) {
        }
        // Only sent while location is allowed all the time (BackgroundLocation.ready).
        put("perm_location", "always")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            put("location_service_on", (context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager)?.isLocationEnabled)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            put("perm_notifications", context.getSystemService(NotificationManager::class.java)?.areNotificationsEnabled())
        }
        return out
    }
}
