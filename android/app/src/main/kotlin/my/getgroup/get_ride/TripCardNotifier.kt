package my.getgroup.get_ride

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * The trip card on Android (lib/src/core/trip_card.dart): the trip's progress
 * as a pinned notification on its own "Trip progress" channel, with the
 * stage's headline, the driver's car and plate, a progress bar and up to
 * three buttons (Call, Chat, Share trip, SOS, Rate). Each button opens the
 * app on a getride://trip/<ride>?do=<button> link that the router turns into
 * the trip page running that button (tripCardLinkLocation).
 *
 * On Android 16 the card is a progress-style notification asking to be
 * promoted to a Live Update (the status bar chip shows its minutes or
 * arrival time); before that, a plain notification with a progress bar.
 * Android 16's calls are made by name so the app builds against any SDK.
 *
 * The app starts, moves and ends the card over the MethodChannel
 * `getride/trip_card` (lib/src/data/trip_card_platform.dart). The last card
 * is kept, so a `trip_card` push to a closed app (TripCardPushReceiver) can
 * move it on.
 */
object TripCardNotifier {
    const val CHANNEL_ID = "trip_progress"
    private const val PREFS = "get_ride.trip_card"
    private const val KEY_RIDE = "ride"
    private const val KEY_CARD = "card"
    private const val DEFAULT_ACCENT = 0xFF2DABE2

    /** Whether the app is on screen: it keeps the card itself then. */
    @Volatile
    var appVisible = false

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, "getride/trip_card").setMethodCallHandler { call, result ->
            when (call.method) {
                "start", "update" -> {
                    val args = call.arguments as? Map<*, *>
                    result.success(args != null && show(app, toJson(args)))
                }
                "end" -> {
                    val ride = (call.arguments as? Map<*, *>)?.get("rideId") as? String
                    if (ride != null) end(app, ride)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun toJson(map: Map<*, *>): JSONObject = JSONObject(map as Map<Any?, Any?>)

    private fun JSONObject.str(name: String): String? =
        if (isNull(name)) null else optString(name).takeIf { it.isNotBlank() }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun notificationId(rideId: String) = 0x7C000000 or (rideId.hashCode() and 0xFFFFFF)

    /** Shows (or redraws) [card]; false when notifications are off. */
    fun show(context: Context, card: JSONObject): Boolean {
        val rideId = card.str("rideId") ?: return false
        val manager = context.getSystemService(NotificationManager::class.java) ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        if (!manager.areNotificationsEnabled()) return false
        val ongoing = card.optBoolean("ongoing", true)
        if (!ongoing && card.optLong("clearAfterMs", 1L) <= 0L) {
            end(context, rideId)
            return true
        }
        ensureChannel(manager)
        val store = prefs(context)
        val previous = store.getString(KEY_RIDE, null)
        if (previous != null && previous != rideId) manager.cancel(notificationId(previous))
        return try {
            manager.notify(notificationId(rideId), build(context, card, ongoing))
            store.edit().putString(KEY_RIDE, rideId).putString(KEY_CARD, card.toString()).apply()
            true
        } catch (e: Exception) {
            false
        }
    }

    fun end(context: Context, rideId: String) {
        context.getSystemService(NotificationManager::class.java)?.cancel(notificationId(rideId))
        val store = prefs(context)
        if (store.getString(KEY_RIDE, null) == rideId) store.edit().remove(KEY_RIDE).remove(KEY_CARD).apply()
    }

    /**
     * A `trip_card` push: [patch] (JSON, any of the card's keys) moves the
     * card the app started for [rideId] on; [ended] takes it down. A push
     * for a ride with no card on this phone is ignored, so the admin's
     * switches and colours (applied when the app started it) still hold.
     */
    fun fromPush(context: Context, rideId: String, ended: Boolean, patch: String?) {
        if (prefs(context).getString(KEY_RIDE, null) != rideId) return
        if (ended) {
            end(context, rideId)
            return
        }
        val stored = prefs(context).getString(KEY_CARD, null) ?: return
        try {
            val card = JSONObject(stored)
            val next = JSONObject(patch ?: return)
            val keys = next.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                if (key == "rideId" || key == "role" || key == "colors") continue
                card.put(key, next.get(key))
            }
            show(context, card)
        } catch (e: Exception) {
            // A malformed push leaves the card as it was.
        }
    }

    private fun ensureChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(CHANNEL_ID, "Trip progress", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "Your trip while it is on: the driver on the way, the arrival time and the end of the trip"
            // The ride's own notifications already sound; the card only moves.
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    @Suppress("DEPRECATION")
    private fun newBuilder(context: Context): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context)
        }

    private fun open(context: Context, uri: String?, code: Int): PendingIntent {
        val intent = Intent(Intent.ACTION_VIEW)
            .setClass(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (uri != null) intent.data = Uri.parse(uri)
        return PendingIntent.getActivity(
            context,
            code,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun build(context: Context, card: JSONObject, ongoing: Boolean): Notification {
        val rideId = card.str("rideId") ?: ""
        val night = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES
        val colors = card.optJSONObject("colors")?.optJSONObject(if (night) "dark" else "light")
        val accent = (colors?.optLong("accent", DEFAULT_ACCENT) ?: DEFAULT_ACCENT).toInt()
        val progress = (card.optDouble("progress", 0.0).coerceIn(0.0, 1.0) * 100).toInt()
        val text = listOfNotNull(card.str("subline"), card.str("plate")).joinToString(" · ")
        val foot = listOfNotNull(card.str("footTitle"), card.str("footText")).joinToString(" · ")
        val builder = newBuilder(context)
            .setSmallIcon(R.drawable.ic_trip_card)
            .setContentTitle(card.str("headline") ?: "GET.ride")
            .setContentText(text.ifEmpty { foot })
            .setSubText(card.str("chip"))
            .setColor(accent)
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(if (ongoing) Notification.CATEGORY_PROGRESS else Notification.CATEGORY_STATUS)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(open(context, card.str("openUri"), notificationId(rideId)))
        if (!ongoing && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val clear = card.optLong("clearAfterMs", 0L)
            if (clear > 0L) builder.setTimeoutAfter(clear)
        }
        val actions = card.optJSONArray("actions")
        if (actions != null) {
            for (i in 0 until minOf(actions.length(), 3)) {
                val a = actions.optJSONObject(i) ?: continue
                val uri = a.str("uri") ?: continue
                val label = a.str("label") ?: continue
                val action = Notification.Action.Builder(
                    Icon.createWithResource(context, R.drawable.ic_trip_card),
                    label,
                    open(context, uri, (rideId + uri).hashCode()),
                ).build()
                builder.addAction(action)
            }
        }
        if (!ongoing) {
            // The done card: what the trip cost and "How was your ride?".
            builder.setStyle(Notification.BigTextStyle().bigText(listOf(text, foot).filter { it.isNotEmpty() }.joinToString("\n")))
        } else if (!liveUpdate(context, builder, progress, accent, card.str("compact"))) {
            builder.setProgress(100, progress, false)
            if (foot.isNotEmpty()) builder.setStyle(Notification.BigTextStyle().bigText(listOf(text, foot).filter { it.isNotEmpty() }.joinToString("\n")))
        }
        return builder.build()
    }

    /** The first public method of [target]'s class called [name] taking one argument. */
    private fun invokeOne(target: Any, name: String, arg: Any?) {
        val method = target.javaClass.methods.first { it.name == name && it.parameterTypes.size == 1 }
        method.invoke(target, arg)
    }

    /**
     * Android 16: a progress-style card with the car moving along the bar
     * to the drop pin, asking to be shown as a Live Update. False where the
     * phone has no such style (the caller draws a plain progress bar).
     */
    private fun liveUpdate(context: Context, builder: Notification.Builder, progress: Int, accent: Int, compact: String?): Boolean {
        if (Build.VERSION.SDK_INT < 36) return false
        try {
            val styleClass = Class.forName("android.app.Notification\$ProgressStyle")
            val segmentClass = Class.forName("android.app.Notification\$ProgressStyle\$Segment")
            val segment = segmentClass.getConstructor(Int::class.javaPrimitiveType).newInstance(100)
            invokeOne(segment, "setColor", accent)
            val style = styleClass.getConstructor().newInstance()
            invokeOne(style, "setStyledByProgress", true)
            invokeOne(style, "setProgress", progress)
            invokeOne(style, "setProgressSegments", listOf(segment))
            invokeOne(style, "setProgressTrackerIcon", Icon.createWithResource(context, R.drawable.ic_trip_card))
            invokeOne(style, "setProgressEndIcon", Icon.createWithResource(context, R.drawable.ic_trip_card_pin))
            builder.setStyle(style as Notification.Style)
        } catch (e: Throwable) {
            return false
        }
        // Asks to be a Live Update: the extra Android 16 reads (what
        // NotificationCompat's setRequestPromotedOngoing writes), and the
        // builder's own call where a later SDK has it.
        builder.extras.putBoolean("android.requestPromotedOngoing", true)
        try {
            invokeOne(builder, "setRequestPromotedOngoing", true)
        } catch (e: Throwable) {
            // Android 16.0: the extra above does it.
        }
        try {
            // The status bar chip: the minutes or the arrival time.
            if (compact != null) invokeOne(builder, "setShortCriticalText", compact)
        } catch (e: Throwable) {
            // Shown without the chip text.
        }
        return true
    }
}
