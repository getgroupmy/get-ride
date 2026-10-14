package my.getgroup.getride_gateway

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock

/**
 * Brings the gateway back when it was left on but is not running: after the
 * phone restarts, after the app is updated, a few seconds after the app is
 * swiped away (some phones end the whole app then), and every 15 minutes
 * as a fallback. "Left on" is the switch in the app (Dart's
 * `gateway.online` setting); turning it off stops all of this.
 *
 * Android allows a background restart while the app's battery use is
 * Unrestricted; otherwise the next opening of the app brings it back.
 * Force stop in the system settings ends it until the app is opened.
 */
object GatewayWatchdog {
    const val ACTION_CHECK = "my.getgroup.getride_gateway.WATCHDOG"
    private const val EVERY_MS = 15 * 60 * 1000L
    private const val SOON_MS = 5 * 1000L

    /** The switch in the app (shared_preferences' file and key prefix). */
    fun wantOnline(context: Context): Boolean =
        context.applicationContext
            .getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean("flutter.gateway.online", false)

    /** Starts the service if the gateway was left on and it is not running. */
    fun revive(context: Context) {
        if (!wantOnline(context)) return
        schedule(context)
        if (GatewayService.running) return
        try {
            GatewayService.revive(context)
        } catch (_: Exception) {
            // Not allowed from the background right now: the next check tries again.
        }
    }

    /** The next fallback check, replacing any already set. */
    fun schedule(context: Context) = set(context, 0, EVERY_MS)

    /** A check in a few seconds, for when the app is being swiped away. */
    fun soon(context: Context) = set(context, 1, SOON_MS)

    private fun set(context: Context, code: Int, delayMs: Long) {
        val am = context.getSystemService(AlarmManager::class.java) ?: return
        val pi = PendingIntent.getBroadcast(
            context,
            code,
            Intent(context, WatchdogReceiver::class.java).setAction(ACTION_CHECK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + delayMs, pi)
    }
}

/** Phone restarted, app updated, or a watchdog check: revive the gateway if it was left on. */
class WatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            GatewayWatchdog.ACTION_CHECK,
            -> GatewayWatchdog.revive(context)
        }
    }
}
