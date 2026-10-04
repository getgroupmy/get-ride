package my.getgroup.get_ride

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannel()
    }

    // The channel push notifications are posted to. send-push names it in
    // every FCM message ("default", the same id the Expo app used), and the
    // manifest makes it Firebase's default. High importance is what makes a
    // ride request pop up on screen and sound instead of arriving silently.
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            "default",
            "Rides and account",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Ride requests, trip updates and GET.coin transfers"
        }
        getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
    }
}
