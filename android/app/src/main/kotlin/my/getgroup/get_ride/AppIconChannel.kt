package my.getgroup.get_ride

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The home-screen icon, for lib/src/core/app_icons.dart.
 *
 * Each icon is an activity-alias of MainActivity named AppIcon_<id>
 * (AndroidManifest.xml), holding the launcher entry; exactly one is enabled.
 * `current` names the enabled one, `set` enables another. The launcher may
 * close the app when the enabled alias changes, so a change asked for while
 * the app is on screen waits until it leaves the screen ([applyPending]).
 */
class AppIconChannel(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "get_ride/app_icon")
    private var pending: String? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "current" -> result.success(pending ?: current())
            "set" -> {
                val id = call.argument<String>("id")
                if (id == null || aliases()[id] == null) {
                    result.error("unknown_icon", "No icon $id", null)
                } else {
                    pending = id
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    /** Called when the app leaves the screen. */
    fun applyPending() {
        val id = pending ?: return
        pending = null
        val all = aliases()
        val target = all[id] ?: return
        val pm = context.packageManager
        // The new one first, so the app always has a launcher entry.
        pm.setComponentEnabledSetting(target, PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
        for ((other, component) in all) {
            if (other != id) {
                pm.setComponentEnabledSetting(
                    component,
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    private fun current(): String? {
        val pm = context.packageManager
        return aliases().entries.firstOrNull { (_, component) ->
            when (pm.getComponentEnabledSetting(component)) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> enabledInManifest(component)
                else -> false
            }
        }?.key
    }

    private fun enabledInManifest(component: ComponentName): Boolean = try {
        val flags = PackageManager.MATCH_DISABLED_COMPONENTS
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getActivityInfo(component, PackageManager.ComponentInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getActivityInfo(component, flags)
        }
        info.enabled
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    /** id → alias, read from the installed package. */
    private fun aliases(): Map<String, ComponentName> {
        val flags = PackageManager.GET_ACTIVITIES or PackageManager.MATCH_DISABLED_COMPONENTS
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(flags.toLong()))
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(context.packageName, flags)
        }
        val prefix = "${MainActivity::class.java.`package`!!.name}.AppIcon_"
        return info.activities.orEmpty()
            .filter { it.name.startsWith(prefix) }
            .associate { it.name.removePrefix(prefix) to ComponentName(context.packageName, it.name) }
    }
}
