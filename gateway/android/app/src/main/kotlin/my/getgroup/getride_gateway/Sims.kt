package my.getgroup.getride_gateway

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.SubscriptionInfo
import android.telephony.SubscriptionManager
import androidx.core.content.ContextCompat

/** The phone's active SIMs, for choosing the one that sends. */
object Sims {
    @SuppressLint("MissingPermission") // checked first
    fun list(context: Context): List<Map<String, Any?>> {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return emptyList()
        }
        val sm = context.getSystemService(SubscriptionManager::class.java) ?: return emptyList()
        val infos = try {
            sm.activeSubscriptionInfoList
        } catch (e: SecurityException) {
            null
        } ?: return emptyList()
        return infos.map { info ->
            mapOf(
                "id" to info.subscriptionId,
                "label" to (info.displayName?.toString() ?: info.carrierName?.toString() ?: "SIM"),
                "number" to number(sm, info),
                "slot" to info.simSlotIndex,
            )
        }
    }

    // Often unreadable (the carrier never wrote it, or it needs a permission
    // this app does not ask for): the person setting up types it instead.
    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    private fun number(sm: SubscriptionManager, info: SubscriptionInfo): String? = try {
        val n = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            sm.getPhoneNumber(info.subscriptionId)
        } else {
            info.number
        }
        n?.takeIf { it.isNotBlank() }
    } catch (e: Exception) {
        null
    }
}
