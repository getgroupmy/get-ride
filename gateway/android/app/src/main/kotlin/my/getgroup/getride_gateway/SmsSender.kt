package my.getgroup.getride_gateway

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
import androidx.core.content.ContextCompat
import java.util.UUID

/**
 * Sends one SMS (in as many parts as it takes) and reports once the radio
 * has answered for every part: sent only if all of them went.
 */
class SmsSender(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())

    private class Job(var remaining: Int, val done: (Boolean, String?) -> Unit) {
        var error: String? = null
        var finished = false
    }

    fun send(to: String, body: String, subscriptionId: Int?, done: (Boolean, String?) -> Unit) {
        val manager = try {
            manager(subscriptionId)
        } catch (e: Exception) {
            done(false, "No SIM to send from (${e.message ?: e.javaClass.simpleName}).")
            return
        }
        val parts = manager.divideMessage(body)
        if (parts.isEmpty()) {
            done(false, "Nothing to send.")
            return
        }
        val job = Job(parts.size, done)
        val action = "my.getgroup.getride_gateway.SMS_SENT." + UUID.randomUUID().toString()
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                if (resultCode != Activity.RESULT_OK && job.error == null) job.error = describe(resultCode)
                job.remaining--
                if (job.remaining <= 0) finish(this, job)
            }
        }
        ContextCompat.registerReceiver(context, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)
        val sent = ArrayList<PendingIntent>()
        for (i in parts.indices) {
            val intent = Intent(action).setPackage(context.packageName)
            sent.add(
                PendingIntent.getBroadcast(
                    context,
                    i,
                    intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_ONE_SHOT,
                ),
            )
        }
        // A radio that never answers must not hold the gateway forever.
        main.postDelayed({
            if (!job.finished) {
                if (job.error == null) job.error = "The phone did not confirm the SMS within a minute."
                finish(receiver, job)
            }
        }, 60_000L)
        try {
            if (parts.size == 1) {
                manager.sendTextMessage(to, null, parts[0], sent[0], null)
            } else {
                manager.sendMultipartTextMessage(to, null, parts, sent, null)
            }
        } catch (e: Exception) {
            job.error = e.message ?: e.javaClass.simpleName
            finish(receiver, job)
        }
    }

    private fun finish(receiver: BroadcastReceiver, job: Job) {
        if (job.finished) return
        job.finished = true
        try {
            context.unregisterReceiver(receiver)
        } catch (_: Exception) {
        }
        job.done(job.error == null, job.error)
    }

    @Suppress("DEPRECATION")
    private fun manager(subscriptionId: Int?): SmsManager =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val base = context.getSystemService(SmsManager::class.java)
            if (subscriptionId != null) base.createForSubscriptionId(subscriptionId) else base
        } else if (subscriptionId != null) {
            SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
        } else {
            SmsManager.getDefault()
        }

    private fun describe(code: Int): String = when (code) {
        SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "The network refused it (no credit, or a barred number?)."
        SmsManager.RESULT_ERROR_NO_SERVICE -> "No mobile service."
        SmsManager.RESULT_ERROR_NULL_PDU -> "The SMS could not be encoded."
        SmsManager.RESULT_ERROR_RADIO_OFF -> "The radio is off (airplane mode?)."
        else -> "The phone could not send it (error $code)."
    }
}
