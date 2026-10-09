package my.getgroup.getride_gateway

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/**
 * SMS this phone received that GET.ride does not have yet. Kept on disk, so
 * a message that arrives while the app is closed, or while the connection
 * is down, is handed over later; dropped only when the gateway acknowledges
 * it (after the server accepted it).
 */
object InboxStore {
    private const val PREFS = "gateway_inbox"
    private const val KEY = "pending"

    /** The newest this many are kept if the gateway stays offline for long. */
    private const val MAX = 500

    /** Set while the app's Dart side is listening; called on the main thread. */
    @Volatile
    var listener: ((Map<String, Any>) -> Unit)? = null

    @Synchronized
    fun add(context: Context, from: String, body: String, at: Long) {
        val item = JSONObject()
            .put("id", UUID.randomUUID().toString())
            .put("from", from)
            .put("body", body)
            .put("at", at)
        val list = read(context)
        list.put(item)
        val kept = if (list.length() <= MAX) list else JSONArray().also { out ->
            for (i in list.length() - MAX until list.length()) out.put(list.get(i))
        }
        write(context, kept)
        val l = listener ?: return
        val map = toMap(item)
        Handler(Looper.getMainLooper()).post { l(map) }
    }

    @Synchronized
    fun pending(context: Context): List<Map<String, Any>> {
        val list = read(context)
        return (0 until list.length()).map { toMap(list.getJSONObject(it)) }
    }

    @Synchronized
    fun acknowledge(context: Context, ids: Collection<String>) {
        if (ids.isEmpty()) return
        val drop = ids.toSet()
        val list = read(context)
        val kept = JSONArray()
        for (i in 0 until list.length()) {
            val o = list.getJSONObject(i)
            if (o.optString("id") !in drop) kept.put(o)
        }
        write(context, kept)
    }

    private fun read(context: Context): JSONArray = try {
        JSONArray(prefs(context).getString(KEY, "[]") ?: "[]")
    } catch (e: Exception) {
        JSONArray()
    }

    // commit, not apply: a receiver's process may end right after onReceive.
    private fun write(context: Context, list: JSONArray) {
        prefs(context).edit().putString(KEY, list.toString()).commit()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun toMap(o: JSONObject): Map<String, Any> = mapOf(
        "id" to o.optString("id"),
        "from" to o.optString("from"),
        "body" to o.optString("body"),
        "at" to o.optLong("at"),
    )
}
