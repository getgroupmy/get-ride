package my.getgroup.get_ride

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build

/**
 * Edit Partner › Change status (migration 0286): a `partner_remote_action`
 * data push (FCM, high priority) asks the partner's phone to go online, go
 * offline, link or unlink a vehicle. The open app runs it itself
 * (lib/src/features/partner/remote_action.dart). With the app in the
 * background or closed there is no Flutter screen to run the driver's own
 * checks, so this shows the push's words ("Support asked you to go online",
 * "Tap to confirm"); the tap opens getride://remote/<id>, the Drive page that
 * runs it. Nothing is done without the tap: the request waits, and expires
 * after 2 minutes.
 *
 * Firebase hands every push to each receiver of this action; this one reads
 * only its own type.
 */
class PartnerRemoteActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val extras = intent.extras ?: return
        if (extras.getString("type") != "partner_remote_action") return
        if (TripCardNotifier.appVisible) return
        val id = extras.getString("id") ?: return
        if (!ID.matches(id)) return
        PartnerRemoteActionNotifier.show(
            context.applicationContext,
            id,
            extras.getString("title")?.take(120) ?: "Support sent you a request",
            extras.getString("body")?.take(120) ?: "Tap to confirm",
        )
    }

    private companion object {
        val ID = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    }
}

/** The notification for [PartnerRemoteActionReceiver], on its own channel. */
object PartnerRemoteActionNotifier {
    private const val CHANNEL_ID = "support_requests"
    private const val NOTIFICATION_ID = 7314

    fun show(context: Context, id: String, title: String, body: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (!manager.areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Support requests", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "Support asking you to go online or offline, or to use or hand back a vehicle"
                },
            )
        }
        val open = Intent(Intent.ACTION_VIEW)
            .setClass(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .setData(Uri.parse("getride://remote/$id"))
        val tap = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            Notification.Builder(context).setPriority(Notification.PRIORITY_HIGH)
        }
        builder
            .setSmallIcon(R.drawable.ic_trip_card)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(tap)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
        // A request lives 2 minutes (0286); the notification no longer.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) builder.setTimeoutAfter(120_000L)
        val notification = builder.build()
        try {
            manager.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            // Best effort: the open app asks again when it comes back.
        }
    }
}
