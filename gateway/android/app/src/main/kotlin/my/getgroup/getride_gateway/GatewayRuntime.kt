package my.getgroup.getride_gateway

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * The gateway's one Flutter engine, owned by the process rather than the
 * screen: the service starts it when the app was not open (after a reboot,
 * an update, or Android killing the app), and the screen only attaches to
 * it, so closing or swiping the app away leaves the gateway loop running.
 *
 * The Dart side's view of the phone (lib/src/sms_platform.dart):
 * `getride.gateway/sms` for sending, the received-SMS queue, SIMs, the
 * foreground service, battery settings and sharing the phone's internet
 * (`startProxy` / `stopProxy`, [ProxyClient]); `getride.gateway/sms_in` for
 * SMS as they arrive. Native calls Dart's `resume` when the service is
 * (re)started, so the gateway turns itself back on if it was left on, and
 * `proxy` with each change in the shared internet's state.
 */
object GatewayRuntime {
    private const val ENGINE_ID = "gateway"
    private const val METHODS = "getride.gateway/sms"
    private const val EVENTS = "getride.gateway/sms_in"

    private var methods: MethodChannel? = null
    private var proxy: ProxyClient? = null

    /** The engine, started (running the app's main()) on first use. Main thread only. */
    fun engine(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app)
        attach(engine, app)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    /**
     * The service came up: a new engine turns the gateway on from main();
     * a running one is asked to, in case it stopped.
     */
    fun resume(context: Context) {
        if (FlutterEngineCache.getInstance().get(ENGINE_ID) == null) {
            engine(context)
        } else {
            methods?.invokeMethod("resume", null)
        }
    }

    private fun attach(engine: FlutterEngine, app: Context) {
        val messenger = engine.dartExecutor.binaryMessenger
        val sender = SmsSender(app)
        // Shares the phone's internet with a test session (ProxyClient);
        // its events reach Dart as `proxy` calls on the method channel.
        val proxy = ProxyClient(app) { event -> methods?.invokeMethod("proxy", event) }
        this.proxy = proxy

        methods = MethodChannel(messenger, METHODS).apply {
            setMethodCallHandler { call, result ->
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
                        proxy.stop()
                        GatewayService.stop(app)
                        result.success(null)
                    }
                    "startProxy" -> {
                        val url = call.argument<String>("url")
                        val key = call.argument<String>("key")
                        if (url.isNullOrBlank() || key.isNullOrBlank()) {
                            result.error("proxy", "No relay address or key.", null)
                        } else {
                            proxy.start(
                                url,
                                key,
                                call.argument<String>("label") ?: "",
                                call.argument<Boolean>("mobileDataOnly") ?: true,
                            )
                            result.success(null)
                        }
                    }
                    "stopProxy" -> {
                        proxy.stop()
                        result.success(null)
                    }
                    "batteryOptimized" -> {
                        val pm = app.getSystemService(PowerManager::class.java)
                        result.success(pm != null && !pm.isIgnoringBatteryOptimizations(app.packageName))
                    }
                    "requestBatteryExemption" -> {
                        try {
                            app.startActivity(
                                Intent(
                                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                    Uri.parse("package:${app.packageName}"),
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                        } catch (e: Exception) {
                            app.startActivity(
                                Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        EventChannel(messenger, EVENTS).setStreamHandler(
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
