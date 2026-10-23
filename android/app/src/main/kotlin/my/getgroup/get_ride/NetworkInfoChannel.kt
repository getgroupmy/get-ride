package my.getgroup.get_ride

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.telephony.TelephonyManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/// The phone's connection and SIM for the session rows Admin → Session
/// History shows (lib/src/data/device_details.dart). Only calls that need no
/// runtime permission: ACCESS_NETWORK_STATE is a normal one, and the
/// operator names and codes need no phone-state access. Nothing asks the
/// user anything. The battery (the sticky ACTION_BATTERY_CHANGED, no
/// receiver kept) and the free space on the app's storage ride along.
/// Without a [messenger] (the app closed: a ping's details, 0282) it is
/// only read, through [info].
class NetworkInfoChannel(private val context: Context, messenger: BinaryMessenger?) {
    init {
        messenger?.let {
            MethodChannel(it, "get_ride/network").setMethodCallHandler { call, result ->
                if (call.method == "info") result.success(info()) else result.notImplemented()
            }
        }
    }

    fun info(): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>()
        try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val caps = cm.activeNetwork?.let { cm.getNetworkCapabilities(it) }
            out["connected"] = caps != null
            out["internet"] = caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
            out["type"] = when {
                caps == null -> "none"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_BLUETOOTH) -> "bluetooth"
                else -> "other"
            }
            out["vpn"] = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            out["metered"] = cm.isActiveNetworkMetered
        } catch (_: Exception) {
        }
        try {
            val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
            out["networkOperatorName"] = tm.networkOperatorName
            out["networkOperator"] = tm.networkOperator
            out["networkCountry"] = tm.networkCountryIso
            out["simOperatorName"] = tm.simOperatorName
            out["simOperator"] = tm.simOperator
            out["simCountry"] = tm.simCountryIso
            out["simState"] = when (tm.simState) {
                TelephonyManager.SIM_STATE_READY -> "ready"
                TelephonyManager.SIM_STATE_ABSENT -> "absent"
                TelephonyManager.SIM_STATE_PIN_REQUIRED, TelephonyManager.SIM_STATE_PUK_REQUIRED -> "locked"
                else -> "unknown"
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) out["carrierName"] = tm.simCarrierIdName?.toString()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) out["simSlots"] = tm.activeModemCount
        } catch (_: Exception) {
        }
        try {
            val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            if (battery != null) {
                val level = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                val scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                if (level >= 0 && scale > 0) out["batteryPct"] = level * 100 / scale
                val status = battery.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                if (status != -1) {
                    out["batteryCharging"] = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                        status == BatteryManager.BATTERY_STATUS_FULL
                }
            }
        } catch (_: Exception) {
        }
        try {
            val stat = StatFs(Environment.getDataDirectory().path)
            out["storageFree"] = stat.availableBytes
            out["storageTotal"] = stat.totalBytes
        } catch (_: Exception) {
        }
        return out
    }
}
