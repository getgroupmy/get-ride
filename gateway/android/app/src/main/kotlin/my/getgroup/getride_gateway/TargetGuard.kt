package my.getgroup.getride_gateway

import java.net.InetAddress
import java.net.Proxy
import java.net.UnknownHostException
import okhttp3.Dns
import okhttp3.OkHttpClient

/**
 * What a shared request may reach: the public internet, nothing else.
 *
 * A session key that may use this phone's internet must not reach the
 * phone itself (127.0.0.1, an app listening on localhost), the Wi-Fi it
 * sits on (the office router, a printer, an internal service) or the
 * carrier's own network. The relay refuses the obvious cases up front
 * (cloudflare/session-proxy/worker.js `checkTarget`), but it cannot see
 * what a name resolves to here, so ProxyClient checks again on the phone:
 *
 *   - [urlRefusal] before the request is built (scheme, user info, names
 *     and IP literals that are never public);
 *   - [checkResolved] on every address the phone's DNS returns, inside the
 *     client's Dns, so the connection only ever goes to an address that
 *     was checked (a name that resolves to a public address for the check
 *     and to a private one for the connect cannot slip between the two);
 *   - [isPublic] once more on the address actually connected to, before a
 *     byte of the request is written.
 *
 * Plain Kotlin on java.net and OkHttp, nothing from Android, so it is unit
 * tested on the JVM (src/test/.../TargetGuardTest.kt).
 */
object TargetGuard {
    /** Raised when a target is refused; its message is what the session is told. */
    class Refused(message: String) : UnknownHostException(message)

    /** Name suffixes that only ever mean a local network. */
    private val LOCAL_SUFFIXES = listOf(
        ".localhost", ".local", ".localdomain", ".internal", ".intranet", ".lan", ".home", ".corp",
        ".home.arpa", ".in-addr.arpa", ".ip6.arpa",
    )

    /**
     * Why a request to this URL is refused before anything is resolved, or
     * null when it may go on to the DNS check. [host] is the URL's host as
     * the HTTP client parsed it (an IPv6 literal with or without brackets).
     */
    fun urlRefusal(scheme: String, username: String, password: String, host: String): String? {
        val s = scheme.lowercase()
        if (s != "http" && s != "https") return "Only http and https targets are relayed."
        if (username.isNotEmpty() || password.isNotEmpty()) return "A target URL may not carry a user name or password."
        val h = host.lowercase().removePrefix("[").removeSuffix("]").removeSuffix(".")
        if (h.isEmpty()) return "The target has no host."
        if (h.contains(':')) {
            // An IPv6 literal.
            val addr = parseIpv6(h) ?: return "The target's IPv6 address could not be read."
            return if (isPublic(addr)) null else notPublic(h)
        }
        val labels = h.split('.')
        if (labels.all { NUMERIC_LABEL.matches(it) }) {
            // Every label a number: an IPv4 literal. Only the plain dotted
            // quad is accepted; 2130706433, 0x7f.1, 0177.0.0.1 and the like
            // are read differently by different resolvers, so never relayed.
            val addr = dottedQuad(h) ?: return "The target's IP address is not a plain dotted quad (a.b.c.d)."
            return if (isPublic(addr)) null else notPublic(h)
        }
        if (h == "localhost" || LOCAL_SUFFIXES.any { h.endsWith(it) }) return notPublic(h)
        // One label ("router", "nas"): only a local search domain resolves it.
        if (!h.contains('.')) return notPublic(h)
        return null
    }

    /**
     * The addresses [host] resolved to, when every one is public; otherwise
     * throws [Refused]. All of them must be: a name that answers with one
     * public and one private address is refused rather than trimmed, since
     * nothing good is served from such a name.
     */
    fun checkResolved(host: String, addresses: List<InetAddress>): List<InetAddress> {
        if (addresses.isEmpty()) throw UnknownHostException("$host did not resolve.")
        val bad = addresses.firstOrNull { !isPublic(it) }
        if (bad != null) throw Refused(notPublic("$host (${bad.hostAddress})"))
        return addresses
    }

    /**
     * Why a request may not go out at all right now: mobile data only is on
     * and this phone has no mobile network. Never falls back to Wi-Fi.
     */
    fun networkRefusal(mobileDataOnly: Boolean, cellularUp: Boolean): String? =
        if (mobileDataOnly && !cellularUp) {
            "Mobile data only is on, but this phone has no mobile data right now, so the request was not sent " +
                "(it would have gone out over Wi-Fi). Turn mobile data on, or turn off \"Mobile data only\"."
        } else {
            null
        }

    /**
     * Sets up [b] so it only reaches public addresses: its Dns hands OkHttp
     * only addresses [checkResolved] passed (so the connection goes to what
     * was checked, a DNS answer that changes between two lookups included),
     * no proxy (which would resolve the name itself), no redirects (each hop
     * comes back to the session, and through these checks again), and the
     * address actually connected to is checked before the request is written,
     * which also covers an IP literal, for which OkHttp skips the Dns.
     * [resolve] is the network's own lookup (the mobile network's, or the
     * system's).
     */
    fun guard(b: OkHttpClient.Builder, resolve: (String) -> List<InetAddress>): OkHttpClient.Builder = b
        .followRedirects(false)
        .followSslRedirects(false)
        .proxy(Proxy.NO_PROXY)
        .dns(object : Dns {
            override fun lookup(hostname: String) = checkResolved(hostname, resolve(hostname))
        })
        .addNetworkInterceptor { chain ->
            val addr = chain.connection()?.route()?.socketAddress?.address
            if (addr == null || !isPublic(addr)) {
                throw Refused(notPublic(addr?.hostAddress ?: chain.request().url.host))
            }
            chain.proceed(chain.request())
        }

    fun notPublic(what: String) =
        "$what is not a public internet address: the relay only reaches the public internet " +
            "(never this phone, its Wi-Fi network or the carrier's)."

    /** Whether [addr] is a public unicast address. */
    fun isPublic(addr: InetAddress): Boolean = isPublic(addr.address)

    /** Whether these 4 (IPv4) or 16 (IPv6) address bytes are a public unicast address. */
    fun isPublic(b: ByteArray): Boolean = when (b.size) {
        4 -> isPublicV4(b)
        16 -> isPublicV6(b)
        else -> false
    }

    private fun u(b: ByteArray, i: Int) = b[i].toInt() and 0xff

    private fun isPublicV4(b: ByteArray): Boolean {
        val a0 = u(b, 0)
        val a1 = u(b, 1)
        val a2 = u(b, 2)
        return when {
            a0 == 0 -> false // 0.0.0.0/8: "this network", 0.0.0.0 itself
            a0 == 10 -> false // 10/8 private
            a0 == 100 && a1 in 64..127 -> false // 100.64/10 carrier-grade NAT
            a0 == 127 -> false // loopback
            a0 == 169 && a1 == 254 -> false // link-local (and cloud metadata)
            a0 == 172 && a1 in 16..31 -> false // 172.16/12 private
            a0 == 192 && a1 == 0 && a2 == 0 -> false // 192.0.0/24 protocol assignments
            a0 == 192 && a1 == 0 && a2 == 2 -> false // TEST-NET-1
            a0 == 192 && a1 == 88 && a2 == 99 -> false // 6to4 relay anycast (deprecated)
            a0 == 192 && a1 == 168 -> false // 192.168/16 private
            a0 == 198 && (a1 == 18 || a1 == 19) -> false // 198.18/15 benchmarking
            a0 == 198 && a1 == 51 && a2 == 100 -> false // TEST-NET-2
            a0 == 203 && a1 == 0 && a2 == 113 -> false // TEST-NET-3
            a0 >= 224 -> false // multicast 224/4, reserved 240/4, broadcast
            else -> true
        }
    }

    private fun isPublicV6(b: ByteArray): Boolean {
        fun zero(from: Int, to: Int) = (from until to).all { b[it].toInt() == 0 }
        fun v4At(i: Int) = byteArrayOf(b[i], b[i + 1], b[i + 2], b[i + 3])
        // ::ffff:a.b.c.d (IPv4-mapped) and ::a.b.c.d (IPv4-compatible, which
        // also covers :: and ::1): what the embedded IPv4 address is.
        if (zero(0, 10) && u(b, 10) == 0xff && u(b, 11) == 0xff) return isPublicV4(v4At(12))
        if (zero(0, 12)) return isPublicV4(v4At(12))
        // 64:ff9b::/96, NAT64: an IPv6-only carrier's way to the IPv4 internet.
        if (u(b, 0) == 0x00 && u(b, 1) == 0x64 && u(b, 2) == 0xff && u(b, 3) == 0x9b && zero(4, 12)) {
            return isPublicV4(v4At(12))
        }
        // Everything else public lives in 2000::/3 (global unicast); that
        // leaves out fe80::/10 link-local, fc00::/7 unique local, fec0::/10,
        // ff00::/8 multicast, 64:ff9b:1::/48 local NAT64, 100::/64 and the rest.
        if (u(b, 0) and 0xe0 != 0x20) return false
        // 2001:db8::/32 documentation, 2001::/32 Teredo (an IPv4 address in disguise).
        if (u(b, 0) == 0x20 && u(b, 1) == 0x01 && u(b, 2) == 0x0d && u(b, 3) == 0xb8) return false
        if (u(b, 0) == 0x20 && u(b, 1) == 0x01 && u(b, 2) == 0x00 && u(b, 3) == 0x00) return false
        // 2002::/16 6to4: the IPv4 address it carries.
        if (u(b, 0) == 0x20 && u(b, 1) == 0x02) return isPublicV4(v4At(2))
        return true
    }

    private val NUMERIC_LABEL = Regex("^(0x[0-9a-f]*|[0-9]+)$")
    private val DECIMAL_OCTET = Regex("^(0|[1-9][0-9]{0,2})$")

    /** a.b.c.d with each part a plain decimal 0-255 (no leading zeros), else null. */
    fun dottedQuad(host: String): ByteArray? {
        val parts = host.split('.')
        if (parts.size != 4) return null
        val out = ByteArray(4)
        for ((i, p) in parts.withIndex()) {
            if (!DECIMAL_OCTET.matches(p)) return null
            val n = p.toInt()
            if (n > 255) return null
            out[i] = n.toByte()
        }
        return out
    }

    /** An IPv6 literal's 16 bytes (with a trailing dotted quad allowed), else null. Never resolves anything. */
    fun parseIpv6(text: String): ByteArray? {
        var s = text.lowercase().removePrefix("[").removeSuffix("]")
        if (s.contains('%')) return null // a zone id: only meaningful on this phone's own links
        val words = ArrayList<Int>()
        // A trailing IPv4 part.
        var tail: ByteArray? = null
        val lastColon = s.lastIndexOf(':')
        if (lastColon >= 0 && s.substring(lastColon + 1).contains('.')) {
            tail = dottedQuad(s.substring(lastColon + 1)) ?: return null
            s = s.substring(0, lastColon + 1) + "0:0"
        }
        val halves = s.split("::")
        if (halves.size > 2) return null
        fun parseWords(part: String): List<Int>? {
            if (part.isEmpty()) return emptyList()
            return part.split(':').map { w ->
                if (w.isEmpty() || w.length > 4 || !w.all { it in '0'..'9' || it in 'a'..'f' }) return null
                w.toInt(16)
            }
        }
        val head = parseWords(halves[0]) ?: return null
        if (halves.size == 2) {
            val back = parseWords(halves[1]) ?: return null
            if (head.size + back.size > 7) return null
            words += head
            repeat(8 - head.size - back.size) { words += 0 }
            words += back
        } else {
            if (head.size != 8) return null
            words += head
        }
        val out = ByteArray(16)
        for (i in 0 until 8) {
            out[2 * i] = (words[i] shr 8).toByte()
            out[2 * i + 1] = (words[i] and 0xff).toByte()
        }
        if (tail != null) System.arraycopy(tail, 0, out, 12, 4)
        return out
    }
}
