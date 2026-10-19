package my.getgroup.getride_gateway

import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * What a shared request may reach (TargetGuard): the public internet and
 * nothing on the phone, its Wi-Fi or the carrier's network, whatever the
 * URL or the DNS says.
 */
class TargetGuardTest {
    private fun ip(text: String): InetAddress = InetAddress.getByAddress(TargetGuard.dottedQuad(text) ?: TargetGuard.parseIpv6(text)!!)

    private fun refusal(url: String): String? {
        val m = Regex("^([a-z]+)://(?:([^:@/]*)(?::([^@/]*))?@)?(\\[[^]]+]|[^:/]+)").find(url)!!
        return TargetGuard.urlRefusal(m.groupValues[1], m.groupValues[2], m.groupValues[3], m.groupValues[4])
    }

    @Test
    fun publicAddressesPass() {
        for (a in listOf("8.8.8.8", "1.1.1.1", "203.106.0.1", "172.15.255.255", "172.32.0.1", "100.63.255.255",
            "100.128.0.1", "198.17.0.1", "198.20.0.1", "169.253.1.1", "2001:4860:4860::8888", "2606:4700::1111",
            "64:ff9b::808:808", "::ffff:8.8.8.8", "2002:808:808::1")) {
            assertTrue(a, TargetGuard.isPublic(ip(a)))
        }
    }

    @Test
    fun nonPublicAddressesAreRefused() {
        for (a in listOf(
            "127.0.0.1", "127.255.0.9", "0.0.0.0", "0.1.2.3", "10.0.0.1", "10.255.255.255", "172.16.0.1",
            "172.31.255.255", "192.168.1.1", "100.64.0.1", "100.127.255.255", "169.254.169.254", "198.18.0.1",
            "198.19.255.255", "192.0.0.8", "192.0.2.1", "198.51.100.1", "203.0.113.5", "224.0.0.1", "239.1.2.3",
            "240.0.0.1", "255.255.255.255",
            "::", "::1", "fe80::1", "febf::1", "fc00::1", "fd12:3456::1", "fec0::1", "ff02::1", "100::1",
            "2001:db8::1", "2001:0:4136:e378::1", "64:ff9b:1::1",
            // Mapped, compatible, NAT64 and 6to4 forms of private IPv4.
            "::ffff:127.0.0.1", "::ffff:7f00:1", "::127.0.0.1", "::ffff:192.168.0.1", "::ffff:10.1.2.3",
            "64:ff9b::7f00:1", "64:ff9b::a00:1", "2002:c0a8:101::1", "2002:7f00:1::1",
        )) {
            assertFalse(a, TargetGuard.isPublic(ip(a)))
        }
    }

    @Test
    fun ipv6LiteralsAreReadWithoutResolving() {
        assertEquals(16, TargetGuard.parseIpv6("[::1]")!!.size)
        assertNull(TargetGuard.parseIpv6("fe80::1%wlan0"))
        assertNull(TargetGuard.parseIpv6("1:2:3:4:5:6:7:8:9"))
        assertNull(TargetGuard.parseIpv6("1::2::3"))
        assertNull(TargetGuard.parseIpv6("::g"))
        assertEquals(ip("::ffff:127.0.0.1").hostAddress, ip("::ffff:7f00:1").hostAddress)
    }

    @Test
    fun urlsThatNeverReachThePublicInternetAreRefused() {
        for (u in listOf(
            "http://127.0.0.1/", "http://localhost:8080/", "http://LOCALHOST/", "http://foo.localhost/",
            "http://printer.local/", "http://db.internal/", "http://router.lan/", "http://nas.home.arpa/",
            "http://router/", "http://192.168.0.1/admin", "http://10.0.0.5:9000/", "http://169.254.169.254/latest/",
            "http://[::1]/", "http://[fe80::1]/", "http://[fd00::1]/", "http://[::ffff:127.0.0.1]/",
            "http://[::ffff:7f00:1]/", "http://0.0.0.0/",
            // Numeric tricks: decimal, octal, hex and short forms of an IPv4 address.
            "http://2130706433/", "http://017700000001/", "http://0x7f000001/", "http://0x7f.0.0.1/",
            "http://0177.0.0.1/", "http://127.1/", "http://127.0.1/", "http://08.8.8.8/", "http://8.8.8.08/",
            "http://256.1.1.1/",
            // Not http(s), or carrying credentials.
            "ftp://example.com/", "file://example.com/etc/passwd", "gopher://example.com/",
            "https://user:pw@example.com/", "https://user@example.com/",
        )) {
            assertNotNull(u, refusal(u))
        }
    }

    @Test
    fun publicUrlsPass() {
        for (u in listOf("https://example.com/", "http://8.8.8.8/", "https://api.example.co.my:8443/x",
            "https://[2606:4700::1111]/", "https://bad.cafe/", "https://1password.com/", "https://123.example/")) {
            assertNull(u, refusal(u))
        }
    }

    @Test
    fun everyResolvedAddressMustBePublic() {
        assertEquals(listOf(ip("8.8.8.8")), TargetGuard.checkResolved("dns.google", listOf(ip("8.8.8.8"))))
        for (answer in listOf(listOf(ip("127.0.0.1")), listOf(ip("8.8.8.8"), ip("192.168.1.1")), listOf(ip("::1")))) {
            try {
                TargetGuard.checkResolved("rebind.example", answer)
                fail("$answer passed")
            } catch (e: TargetGuard.Refused) {
                assertTrue(e.message!!.contains("not a public internet address"))
            }
        }
        try {
            TargetGuard.checkResolved("nothing.example", emptyList())
            fail("an empty answer passed")
        } catch (_: java.net.UnknownHostException) {
        }
    }

    @Test
    fun mobileDataOnlyNeverFallsBackToWifi() {
        assertNotNull(TargetGuard.networkRefusal(mobileDataOnly = true, cellularUp = false))
        assertNull(TargetGuard.networkRefusal(mobileDataOnly = true, cellularUp = true))
        assertNull(TargetGuard.networkRefusal(mobileDataOnly = false, cellularUp = false))
        assertNull(TargetGuard.networkRefusal(mobileDataOnly = false, cellularUp = true))
    }

    /** A local server that counts the requests that reach it. */
    private fun withServer(block: (port: Int, requests: AtomicInteger) -> Unit) {
        ServerSocket(0, 50, InetAddress.getByName("127.0.0.1")).use { server ->
            val requests = AtomicInteger()
            val t = Thread {
                try {
                    while (true) {
                        server.accept().use { s ->
                            s.soTimeout = 2000
                            // Only a written request line counts; a bare connect does not.
                            if (s.getInputStream().read() >= 0) {
                                requests.incrementAndGet()
                                s.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".toByteArray())
                            }
                        }
                    }
                } catch (_: Exception) {
                }
            }
            t.isDaemon = true
            t.start()
            block(server.localPort, requests)
        }
    }

    private fun guarded(resolve: (String) -> List<InetAddress>) =
        TargetGuard.guard(OkHttpClient.Builder().connectTimeout(2, TimeUnit.SECONDS), resolve).build()

    @Test
    fun aNameThatResolvesToLoopbackIsNeverConnectedTo() {
        withServer { port, requests ->
            val client = guarded { listOf(InetAddress.getByName("127.0.0.1")) }
            try {
                client.newCall(Request.Builder().url("http://public.example:$port/").build()).execute().close()
                fail("reached loopback through DNS")
            } catch (e: TargetGuard.Refused) {
                assertTrue(e.message!!.contains("127.0.0.1"))
            }
            assertEquals(0, requests.get())
        }
    }

    @Test
    fun anIpLiteralThatSkipsTheDnsIsStoppedBeforeTheRequestIsWritten() {
        withServer { port, requests ->
            // OkHttp connects to an IP literal without asking the Dns: the
            // check on the connected address is what stops it.
            val client = guarded { fail("the Dns was asked about $it"); emptyList() }
            try {
                client.newCall(Request.Builder().url("http://127.0.0.1:$port/").build()).execute().close()
                fail("reached loopback by IP literal")
            } catch (e: TargetGuard.Refused) {
                assertTrue(e.message!!.contains("127.0.0.1"))
            }
            Thread.sleep(200)
            assertEquals(0, requests.get())
        }
    }

    @Test
    fun theGuardDoesNotFollowRedirectsOrUseAProxy() {
        val client = guarded { emptyList() }
        assertFalse(client.followRedirects)
        assertFalse(client.followSslRedirects)
        assertEquals(java.net.Proxy.NO_PROXY, client.proxy)
    }
}
