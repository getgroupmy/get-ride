package my.getgroup.get_ride

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.location.LocationRequest
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * "Always on" (migration 0272, lib/src/data/background_location.dart): a
 * phone whose location is already "Allow all the time" keeps telling the
 * server where it is while the app is in the background or closed. Never
 * asks for the permission; without it, it does nothing.
 *
 * Android's own LocationManager delivers fixes to [BackgroundLocationReceiver]
 * through a PendingIntent the system keeps after the app is closed (Android
 * throttles background apps to a few fixes an hour, which is all this needs).
 * The receiver sends one about every 15 minutes, or sooner after a move of
 * 200 m (backgroundReportDue in lib/src/core/push_logic.dart; 500 m before
 * 0276), to push_background_location with the install's random key: no
 * session and no Flutter engine. Android forgets the request on a reboot or
 * an app update; the receiver asks again then. A "Still there?" ping
 * (LocationPing.kt, migration 0276) takes one fix and sends it whatever the
 * rule says ([fixNow]). Only framework APIs: no new library.
 */
object BackgroundLocation {
    private const val PREFS = "get_ride_background_location"
    private const val ACTION_FIX = "my.getgroup.get_ride.BACKGROUND_FIX"
    private const val REQUEST_CODE = 7312

    // As backgroundReportDue (lib/src/core/push_logic.dart).
    private const val EVERY_MS = 15 * 60 * 1000L
    private const val MOVE_METRES = 200f

    // How often Android is asked for a fix; the rule above picks what is sent.
    private const val ASK_EVERY_MS = 5 * 60 * 1000L

    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, "get_ride/background_location").setMethodCallHandler { call, result ->
            when (call.method) {
                "arm" -> result.success(
                    arm(
                        context,
                        call.argument<String>("url") ?: "",
                        call.argument<String>("anonKey") ?: "",
                        call.argument<String>("key") ?: "",
                    ),
                )
                "disarm" -> {
                    disarm(context)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun granted(context: Context, permission: String) =
        context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /** Location allowed all the time (before Android 10, location at all). */
    private fun allowedAlways(context: Context): Boolean {
        val location = granted(context, Manifest.permission.ACCESS_FINE_LOCATION) ||
            granted(context, Manifest.permission.ACCESS_COARSE_LOCATION)
        val background = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            granted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        return location && background
    }

    fun arm(context: Context, url: String, anonKey: String, key: String): Boolean {
        if (url.isEmpty() || anonKey.isEmpty() || key.length < 32) return false
        prefs(context).edit()
            .putString("url", url)
            .putString("anonKey", anonKey)
            .putString("key", key)
            .putBoolean("armed", true)
            .apply()
        return request(context)
    }

    fun disarm(context: Context) {
        prefs(context).edit().clear().apply()
        try {
            (context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager)?.removeUpdates(pendingIntent(context))
        } catch (e: Exception) {
        }
    }

    /** After a reboot or an app update, when it was on. */
    fun rearm(context: Context) {
        if (prefs(context).getBoolean("armed", false)) request(context)
    }

    private fun request(context: Context): Boolean {
        if (!allowedAlways(context)) return false
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val provider = if (manager.hasProvider(LocationManager.FUSED_PROVIDER)) {
                    LocationManager.FUSED_PROVIDER
                } else {
                    legacyProvider(manager)
                }
                val request = LocationRequest.Builder(ASK_EVERY_MS)
                    .setQuality(LocationRequest.QUALITY_BALANCED_POWER_ACCURACY)
                    .setMinUpdateIntervalMillis(ASK_EVERY_MS / 2)
                    .build()
                manager.requestLocationUpdates(provider, request, pendingIntent(context))
            } else {
                manager.requestLocationUpdates(legacyProvider(manager), ASK_EVERY_MS, 0f, pendingIntent(context))
            }
            true
        } catch (e: SecurityException) {
            false
        } catch (e: IllegalArgumentException) {
            false
        }
    }

    /** The network's fix (cheap), else whatever other apps ask for: never the GPS on its own. */
    private fun legacyProvider(manager: LocationManager): String =
        if (manager.allProviders.contains(LocationManager.NETWORK_PROVIDER) &&
            manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        ) {
            LocationManager.NETWORK_PROVIDER
        } else {
            LocationManager.PASSIVE_PROVIDER
        }

    private fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, BackgroundLocationReceiver::class.java).setAction(ACTION_FIX)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        // The system adds the fix to the intent, so it must be mutable.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) flags = flags or PendingIntent.FLAG_MUTABLE
        return PendingIntent.getBroadcast(context, REQUEST_CODE, intent, flags)
    }

    /** Armed, and location still allowed all the time. */
    fun ready(context: Context): Boolean = prefs(context).getBoolean("armed", false) && allowedAlways(context)

    /**
     * One fix now, for a ping: Android's current location (Android 11+), else
     * a single update, given [waitMs]; without one, the last fix Android
     * has if it is under 5 minutes old. [done] once, on the main thread, with
     * the fix or null.
     */
    fun fixNow(context: Context, waitMs: Long, done: (Location?) -> Unit) {
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
        if (manager == null || !allowedAlways(context)) {
            done(null)
            return
        }
        val main = Handler(Looper.getMainLooper())
        var answered = false
        fun answer(fix: Location?) {
            if (answered) return
            answered = true
            done(fix)
        }
        fun lastKnown(): Location? = try {
            listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER, LocationManager.PASSIVE_PROVIDER)
                .filter { manager.allProviders.contains(it) }
                .mapNotNull { manager.getLastKnownLocation(it) }
                .maxByOrNull { it.time }
                ?.takeIf { System.currentTimeMillis() - it.time < 5 * 60 * 1000L }
        } catch (e: SecurityException) {
            null
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val provider = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    manager.hasProvider(LocationManager.FUSED_PROVIDER)
                ) {
                    LocationManager.FUSED_PROVIDER
                } else {
                    legacyProvider(manager)
                }
                val cancel = CancellationSignal()
                main.postDelayed({
                    cancel.cancel()
                    answer(lastKnown())
                }, waitMs)
                manager.getCurrentLocation(provider, cancel, context.mainExecutor) { fix -> answer(fix ?: lastKnown()) }
            } else {
                val listener = object : LocationListener {
                    override fun onLocationChanged(location: Location) {
                        answer(location)
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

                    override fun onProviderEnabled(provider: String) {}

                    override fun onProviderDisabled(provider: String) {}
                }
                main.postDelayed({
                    manager.removeUpdates(listener)
                    answer(lastKnown())
                }, waitMs)
                @Suppress("DEPRECATION")
                manager.requestSingleUpdate(legacyProvider(manager), listener, Looper.getMainLooper())
            }
        } catch (e: SecurityException) {
            answer(null)
        } catch (e: IllegalArgumentException) {
            answer(lastKnown())
        }
    }

    /** A fix arrived: sent when it is due (or [force]d, a ping), then [done]. */
    fun onFix(context: Context, fix: Location, done: () -> Unit) = onFix(context, fix, false) { done() }

    fun onFix(context: Context, fix: Location, force: Boolean, done: (Boolean) -> Unit) {
        val p = prefs(context)
        if (!p.getBoolean("armed", false)) {
            done(false)
            return
        }
        if (!allowedAlways(context)) {
            // No longer allowed all the time: stop until the app sees it again.
            disarm(context)
            done(false)
            return
        }
        val now = System.currentTimeMillis()
        val lastAt = p.getLong("lastAt", 0L)
        val moved = if (p.contains("lastLat") && p.contains("lastLng")) {
            val d = FloatArray(1)
            Location.distanceBetween(
                p.getFloat("lastLat", 0f).toDouble(), p.getFloat("lastLng", 0f).toDouble(),
                fix.latitude, fix.longitude, d,
            )
            d[0]
        } else {
            null
        }
        val due = force || lastAt == 0L || now - lastAt >= EVERY_MS || (moved ?: 0f) >= MOVE_METRES
        val url = p.getString("url", null)
        val anonKey = p.getString("anonKey", null)
        val key = p.getString("key", null)
        if (!due || url == null || anonKey == null || key == null) {
            done(false)
            return
        }
        thread(name = "background-location") {
            var sent = false
            try {
                if (post(url, anonKey, key, fix.latitude, fix.longitude)) {
                    sent = true
                    p.edit()
                        .putLong("lastAt", now)
                        .putFloat("lastLat", fix.latitude.toFloat())
                        .putFloat("lastLng", fix.longitude.toFloat())
                        .apply()
                }
            } catch (e: Exception) {
                // Best effort: the next fix tries again.
            } finally {
                done(sent)
            }
        }
    }

    private fun post(url: String, anonKey: String, key: String, lat: Double, lng: Double): Boolean {
        val conn = URL(url.trimEnd('/') + "/rest/v1/rpc/push_background_location").openConnection() as HttpURLConnection
        return try {
            conn.requestMethod = "POST"
            conn.connectTimeout = 15000
            conn.readTimeout = 15000
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("apikey", anonKey)
            // A legacy anon key is a JWT and goes as the bearer too; a
            // publishable key goes as apikey only.
            if (anonKey.startsWith("eyJ")) conn.setRequestProperty("Authorization", "Bearer $anonKey")
            val body = JSONObject().put("p_key", key).put("p_lat", lat).put("p_lng", lng).toString()
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            conn.responseCode in 200..299
        } finally {
            conn.disconnect()
        }
    }
}

/** The fixes LocationManager delivers, and the reboot / app update that makes it forget them. */
class BackgroundLocationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> BackgroundLocation.rearm(app)
            else -> {
                val fix = fixOf(intent) ?: return
                val pending = goAsync()
                BackgroundLocation.onFix(app, fix) { pending.finish() }
            }
        }
    }

    private fun fixOf(intent: Intent): Location? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(LocationManager.KEY_LOCATION_CHANGED, Location::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(LocationManager.KEY_LOCATION_CHANGED)
        }
}
