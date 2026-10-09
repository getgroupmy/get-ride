package my.getgroup.getride_gateway

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * The Dart side's view of the phone (lib/src/sms_platform.dart):
 * `getride.gateway/sms` for sending, the received-SMS queue, SIMs, the
 * foreground service and battery settings; `getride.gateway/sms_in` for SMS
 * as they arrive.
 */
class MainActivity : FlutterActivity() {
    private val sender by lazy { SmsSender(applicationContext) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val app = applicationContext

        MethodChannel(messenger, "getride.gateway/sms").setMethodCallHandler { call, result ->
            when (call.method) {
                "send" -> {
                    val to = call.argument<String>("to")
                    val body = call.argument<String>("body")
                    val subscriptionId = call.argument<Int>("subscriptionId")
                    when {
                        to.isNullOrBlank() || body.isNullOrEmpty() ->
                            result.success(mapOf("ok" to false, "error" to "No number or text."))
                        ContextCompat.checkSelfPermission(app, Manifest.permission.SEND_SMS)
                            != PackageManager.PERMISSION_GRANTED ->
                            result.success(mapOf("ok" to false, "error" to "The SMS permission is off."))
                        else -> sender.send(to, body, subscriptionId) { ok, error ->
                            result.success(mapOf("ok" to ok, "error" to error))
                        }
                    }
                }
                "pending" -> result.success(InboxStore.pending(app))
                "acknowledge" -> {
                    InboxStore.acknowledge(app, call.argument<List<String>>("ids") ?: emptyList())
                    result.success(null)
                }
                "sims" -> result.success(Sims.list(app))
                "startService" -> try {
                    GatewayService.start(app, call.argument<String>("text") ?: "Online")
                    result.success(null)
                } catch (e: Exception) {
                    result.error("service", e.message, null)
                }
                "stopService" -> {
                    GatewayService.stop(app)
                    result.success(null)
                }
                "batteryOptimized" -> {
                    val pm = getSystemService(PowerManager::class.java)
                    result.success(pm != null && !pm.isIgnoringBatteryOptimizations(packageName))
                }
                "requestBatteryExemption" -> {
                    try {
                        startActivity(
                            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")),
                        )
                    } catch (e: Exception) {
                        startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "getride.gateway/sms_in").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    InboxStore.listener = { events.success(it) }
                }

                override fun onCancel(arguments: Any?) {
                    InboxStore.listener = null
                }
            },
        )
    }
}
