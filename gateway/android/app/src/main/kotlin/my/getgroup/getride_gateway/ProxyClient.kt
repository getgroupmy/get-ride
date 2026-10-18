package my.getgroup.getride_gateway

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import okhttp3.Dns
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject

/**
 * Shares this phone's internet with a test session, through the relay at
 * proxy.getride.my (cloudflare/session-proxy/worker.js, which documents the
 * frames). The phone dials in with its device key and keeps the socket
 * open; each request the relay hands it is performed here, over mobile
 * data when there is any (so a request leaves from the SIM, not the
 * office Wi-Fi), and streamed back in chunks.
 *
 * Lives as long as the gateway's service does; `start` is idempotent for
 * the same settings, so the Dart loop can call it every round.
 */
class ProxyClient(private val app: Context, private val onEvent: (Map<String, Any?>) -> Unit) {
    private class Pending(val method: String, val url: String, val headers: List<Pair<String, String>>) {
        val body = ByteArrayOutputStream()
        @Volatile var aborted = false
    }

    private val main = Handler(Looper.getMainLooper())
    private val workers = Executors.newCachedThreadPool()
    private val pending = ConcurrentHashMap<String, Pending>()

    private val relayClient = OkHttpClient.Builder()
        .pingInterval(30, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    @Volatile private var wanted = false
    private var url = ""
    private var key = ""
    private var label = ""
    private var mobileDataOnly = true
    private var socket: WebSocket? = null
    private var failures = 0
    private var reconnect: Runnable? = null

    @Volatile private var cellular: Network? = null
    private var cellularCallback: ConnectivityManager.NetworkCallback? = null

    /** Connects (or stays connected) with these settings. */
    @Synchronized
    fun start(url: String, key: String, label: String, mobileDataOnly: Boolean) {
        val same = wanted && this.url == url && this.key == key && this.mobileDataOnly == mobileDataOnly
        this.label = label
        if (same) {
            if (socket == null && reconnect == null) connect()
            return
        }
        stopSocket()
        wanted = true
        this.url = url
        this.key = key
        this.mobileDataOnly = mobileDataOnly
        failures = 0
        requestCellular()
        connect()
    }

    @Synchronized
    fun stop() {
        if (!wanted && socket == null) return
        stopSocket()
        releaseCellular()
        emit("off")
    }

    /** Whether the relay has this phone right now. */
    val connected: Boolean get() = socket != null && failures == 0

    private fun stopSocket() {
        wanted = false
        reconnect?.let { main.removeCallbacks(it) }
        reconnect = null
        socket?.close(1000, "off")
        socket = null
        for (p in pending.values) p.aborted = true
        pending.clear()
    }

    private fun connect() {
        if (!wanted) return
        emit(if (failures == 0) "connecting" else "reconnecting")
        val request = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $key")
            .header("X-Phone-Label", label.ifBlank { "Gateway phone" })
            .build()
        socket = relayClient.newWebSocket(request, listener)
    }

    private val listener = object : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            synchronized(this@ProxyClient) {
                if (socket !== webSocket) return
                failures = 0
            }
            emit("connected")
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            if (socket !== webSocket) return
            handleFrame(webSocket, text)
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            lost(webSocket, null, null)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            lost(webSocket, t, response)
        }
    }

    /** The socket went: say why and, if still wanted, try again later. */
    private fun lost(webSocket: WebSocket, t: Throwable?, response: Response?) {
        synchronized(this) {
            if (socket !== webSocket) return
            socket = null
            for (p in pending.values) p.aborted = true
            pending.clear()
            if (!wanted) return
            // Refused outright: the phone is not paired, or the relay is not there.
            val code = response?.code ?: 0
            if (code == 401 || code == 403) {
                wanted = false
                releaseCellular()
                emit("error", "reason" to "This phone is not paired any more, or its key was refused (HTTP $code).")
                return
            }
            failures++
            val delay = (5_000L shl (failures - 1).coerceIn(0, 5)).coerceAtMost(120_000L)
            val r = Runnable {
                synchronized(this) { reconnect = null }
                connect()
            }
            reconnect = r
            main.postDelayed(r, delay)
        }
        emit("reconnecting", "reason" to (t?.message ?: "Connection closed"))
    }

    // ---- Frames from the relay ----------------------------------------------------------------

    private fun handleFrame(ws: WebSocket, text: String) {
        val m = try {
            JSONObject(text)
        } catch (_: Exception) {
            return
        }
        val id = m.optString("id", "")
        if (id.isEmpty()) return
        when {
            m.has("method") -> {
                val headers = mutableListOf<Pair<String, String>>()
                val list = m.optJSONArray("headers") ?: JSONArray()
                for (i in 0 until list.length()) {
                    val pair = list.optJSONArray(i) ?: continue
                    if (pair.length() == 2) headers.add(pair.optString(0) to pair.optString(1))
                }
                pending[id] = Pending(m.optString("method", "GET").uppercase(), m.optString("url", ""), headers)
            }
            m.has("chunk") -> {
                val p = pending[id] ?: return
                try {
                    val bytes = Base64.decode(m.optString("chunk", ""), Base64.DEFAULT)
                    if (p.body.size() + bytes.size > MAX_BODY) {
                        pending.remove(id)
                        send(ws, JSONObject().put("id", id).put("error", "Request body too large"))
                    } else {
                        p.body.write(bytes)
                    }
                } catch (e: Exception) {
                    pending.remove(id)
                    send(ws, JSONObject().put("id", id).put("error", "Bad request body: ${e.message}"))
                }
            }
            m.optBoolean("abort", false) -> pending.remove(id)
            m.optBoolean("end", false) -> {
                val p = pending.remove(id) ?: return
                workers.execute { perform(ws, id, p) }
            }
        }
    }

    /** Performs one request on this phone and streams the answer back. */
    private fun perform(ws: WebSocket, id: String, p: Pending) {
        val host = try {
            java.net.URI(p.url).host ?: p.url
        } catch (_: Exception) {
            p.url
        }
        var status: Int? = null
        try {
            val builder = Request.Builder().url(p.url)
            for ((name, value) in p.headers) {
                try {
                    builder.addHeader(name, value)
                } catch (_: IllegalArgumentException) {
                    // A header OkHttp refuses (a control character): left out.
                }
            }
            val bytes = p.body.toByteArray()
            val contentType = p.headers.firstOrNull { it.first.equals("content-type", true) }?.second
            val body = when {
                bytes.isNotEmpty() -> bytes.toRequestBody(contentType?.toMediaTypeOrNull())
                p.method in setOf("POST", "PUT", "PATCH") -> ByteArray(0).toRequestBody(contentType?.toMediaTypeOrNull())
                else -> null
            }
            builder.method(p.method, body)
            val client = clientFor(cellular?.takeIf { mobileDataOnly })
            client.newCall(builder.build()).execute().use { res ->
                if (p.aborted) return
                status = res.code
                val headers = JSONArray()
                for (i in 0 until res.headers.size) {
                    headers.put(JSONArray().put(res.headers.name(i)).put(res.headers.value(i)))
                }
                send(ws, JSONObject().put("id", id).put("status", res.code).put("headers", headers))
                val stream = res.body?.byteStream()
                if (stream != null) {
                    val buffer = ByteArray(CHUNK_BYTES)
                    while (true) {
                        if (p.aborted) return
                        val n = stream.read(buffer)
                        if (n < 0) break
                        if (n == 0) continue
                        val chunk = Base64.encodeToString(buffer, 0, n, Base64.NO_WRAP)
                        // A slow uplink: wait for the socket's queue rather than growing it without end.
                        while (ws.queueSize() > QUEUE_HIGH_WATER && !p.aborted) Thread.sleep(20)
                        send(ws, JSONObject().put("id", id).put("chunk", chunk))
                    }
                }
                send(ws, JSONObject().put("id", id).put("end", true))
            }
            emit("request", "host" to host, "status" to status)
        } catch (e: Exception) {
            if (!p.aborted) send(ws, JSONObject().put("id", id).put("error", e.message ?: e.javaClass.simpleName))
            emit("request", "host" to host, "error" to (e.message ?: e.javaClass.simpleName))
        }
    }

    private fun send(ws: WebSocket, frame: JSONObject) {
        ws.send(frame.toString())
    }

    /**
     * The client a request goes out through: bound to the mobile network
     * when one is up and wanted, else the phone's default route.
     */
    private fun clientFor(network: Network?): OkHttpClient {
        val b = OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(30, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .writeTimeout(60, TimeUnit.SECONDS)
        if (network != null) {
            b.socketFactory(network.socketFactory)
            b.dns(object : Dns {
                override fun lookup(hostname: String) = network.getAllByName(hostname).toList()
            })
        }
        return b.build()
    }

    // ---- Mobile data ----------------------------------------------------------------------------

    /** Asks Android to keep the mobile network up beside Wi-Fi, so requests can use it. */
    private fun requestCellular() {
        if (cellularCallback != null) return
        val cm = app.getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                cellular = network
                emit("mobile", "available" to true)
            }

            override fun onLost(network: Network) {
                if (cellular == network) cellular = null
                emit("mobile", "available" to false)
            }
        }
        try {
            cm.requestNetwork(
                NetworkRequest.Builder()
                    .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .build(),
                callback,
            )
            cellularCallback = callback
        } catch (_: Exception) {
            // Not allowed on this phone: requests take the default route.
        }
    }

    private fun releaseCellular() {
        val cb = cellularCallback ?: return
        cellularCallback = null
        cellular = null
        try {
            app.getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(cb)
        } catch (_: Exception) {
        }
    }

    private fun emit(state: String, vararg extra: Pair<String, Any?>) {
        val event = mutableMapOf<String, Any?>("state" to state)
        for ((k, v) in extra) event[k] = v
        main.post { onEvent(event) }
    }

    companion object {
        /** Raw bytes per chunk frame (base64 of it stays under the relay's 1 MiB frame limit). */
        private const val CHUNK_BYTES = 192 * 1024

        /** The most a request body may be. */
        private const val MAX_BODY = 20 * 1024 * 1024

        /** Bytes queued on the socket before sending waits. */
        private const val QUEUE_HIGH_WATER = 4L * 1024 * 1024
    }
}
