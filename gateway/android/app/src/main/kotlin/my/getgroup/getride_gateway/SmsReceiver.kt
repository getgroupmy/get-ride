package my.getgroup.getride_gateway

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony

/** Queues every SMS the phone receives for the gateway (see [InboxStore]). */
class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) return
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        // A long SMS arrives in parts: join them, per sender.
        val bySender = LinkedHashMap<String, StringBuilder>()
        var at = System.currentTimeMillis()
        for (m in messages) {
            if (m == null) continue
            val from = m.originatingAddress ?: m.displayOriginatingAddress ?: continue
            bySender.getOrPut(from) { StringBuilder() }.append(m.messageBody ?: "")
            if (m.timestampMillis > 0) at = m.timestampMillis
        }
        for ((from, body) in bySender) InboxStore.add(context, from, body.toString(), at)
    }
}
