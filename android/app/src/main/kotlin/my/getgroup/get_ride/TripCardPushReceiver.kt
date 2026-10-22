package my.getgroup.get_ride

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * A `trip_card` data push (FCM) while the app is in the background or
 * closed: moves the trip card on (TripCardNotifier.fromPush) without
 * starting Flutter. Its data: `ride_id`, then either `card` (JSON with any of
 * the card's keys, as lib/src/core/trip_card.dart's TripCard.toPlatform
 * names them) or `end` = "1". Firebase hands every push to each receiver of
 * this action; this one reads only its own type, and leaves an open app to
 * keep its card itself.
 */
class TripCardPushReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val extras = intent.extras ?: return
        if (extras.getString("type") != "trip_card") return
        if (TripCardNotifier.appVisible) return
        val ride = extras.getString("ride_id") ?: extras.getString("request_id") ?: return
        TripCardNotifier.fromPush(context.applicationContext, ride, extras.getString("end") == "1", extras.getString("card"))
    }
}
