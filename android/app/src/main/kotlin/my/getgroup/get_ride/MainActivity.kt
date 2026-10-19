package my.getgroup.get_ride

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private companion object {
        const val ALWAYS_REQUEST = 7311
    }

    private var classicPrinter: ClassicPrinterChannel? = null
    private var appIcon: AppIconChannel? = null
    private var networkInfo: NetworkInfoChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Classic Bluetooth (SPP) receipt printers for Meter Digital.
        classicPrinter = ClassicPrinterChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        // Settings → App icon and the admin's seasonal icons (lib/src/core/app_icons.dart).
        appIcon = AppIconChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        // The connection and SIM for Admin → Session History (lib/src/data/device_details.dart).
        networkInfo = NetworkInfoChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        // Settings → Permissions (lib/src/data/permission_probe.dart): where
        // the camera, microphone and Bluetooth stand, without asking.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "get_ride/permissions").setMethodCallHandler { call, result ->
            when (call.method) {
                "statuses" -> result.success(permissionStatuses())
                "requestLocationAlways" -> requestLocationAlways(result)
                "openNotificationSettings" -> result.success(openNotificationSettings())
                else -> result.notImplemented()
            }
        }
    }

    // Admin → App Settings → Permissions → "Allow all the time (Android)":
    // background location asked on its own, once "While using the app" is
    // allowed (Android 11+ ignores it asked together with the foreground
    // permission, and answers with the app's Location page instead of a
    // dialog). The Dart side reads where it stands afterwards.
    private var alwaysResult: MethodChannel.Result? = null

    private fun requestLocationAlways(result: MethodChannel.Result) {
        val background = Manifest.permission.ACCESS_BACKGROUND_LOCATION
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || checkSelfPermission(background) == PackageManager.PERMISSION_GRANTED) {
            result.success("always")
            return
        }
        alwaysResult?.success(null)
        alwaysResult = result
        requestPermissions(arrayOf(background), ALWAYS_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != ALWAYS_REQUEST) return
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        alwaysResult?.success(if (granted) "always" else "whileInUse")
        alwaysResult = null
    }

    // The app's own Notifications page (lib/src/core/permission_ask.dart):
    // where notifications refused for good are switched back on.
    private fun openNotificationSettings(): Boolean = try {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.fromParts("package", packageName, null))
        }
        startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: Exception) {
        false
    }

    private fun permissionStatuses(): Map<String, String> {
        fun of(vararg names: String) =
            if (names.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) "granted" else "denied"
        val bluetooth = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            of(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            "granted"
        }
        return mapOf(
            "camera" to of(Manifest.permission.CAMERA),
            "microphone" to of(Manifest.permission.RECORD_AUDIO),
            "bluetooth" to bluetooth,
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        classicPrinter?.dispose()
        classicPrinter = null
        appIcon?.dispose()
        appIcon = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // A new home-screen icon is switched in once the app is off screen: the
    // launcher may close an app whose icon changes under it.
    override fun onStop() {
        super.onStop()
        appIcon?.applyPending()
    }

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
