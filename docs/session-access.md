# Session access: a test session's phone

A live, real-world test of GET.ride runs somewhere without a phone: a Claude
Code cloud session, a CI job, a script on a laptop. Two things such a session
cannot do on its own are exactly the things a real test needs:

- **SMS.** Sign in by phone number and read the code that was texted; text a
  number and see the reply.
- **A real network.** Make a request that leaves from a Malaysian SIM rather
  than a data centre (carrier pages, geo-fenced APIs, the networks riders are
  on).

The GET.ride Gateway phone (`gateway/`) already does both for the platform, so
it does them for a test session too. A full admin gives the session a **key**
in **Admin → SMS / WhatsApp → Session access** (migration `0226`). The key is
scoped to one **test phone number** and to what the session may do:

| Scope | What the session may do |
| --- | --- |
| Text the test number (`sms`) | Queue a support or marketing SMS to the test number through the gateway phone; read what went out to it and what came in from it. Never a sign-in code. |
| Read sign-in codes (`codes`) | Read the sign-in codes sent to the test number in clear, so the session can sign the test account in by SMS. Without it a code shows masked. |
| Use a gateway phone's internet (`proxy`) | Make HTTP requests through the chosen gateway phone's mobile data, via `proxy.getride.my`. |

The key is shown once, when it is added. It lasts the hours the admin picks
(a day by default, 30 at most) and can be removed from the same card at any
time; a removed or expired key is refused everywhere within seconds. Only a
full admin adds or removes one, because a key with `codes` reads sign-in
codes; any admin sees the list, with when each key was last used.

## Giving a session its key

1. Admin → SMS / WhatsApp → **Session access** → **Add a session**. Name it,
   enter the test phone number with its country code (`+60123456789`), tick
   what it may do, and for internet pick the gateway phone. The gateway
   phone must be paired and online, and routed to the channels the session
   will use (`support_message` outbound for its texts; `otp` outbound for
   sign-in codes).
2. Put the key in the session's environment, one of two ways:
   - **As a network secret (preferred).** In a Claude Code cloud
     environment: the cloud environment menu in the session's title bar →
     Edit → Secrets → Add secret. Allowed websites: `proxy.getride.my` and
     the backend host (`rqlavogkgywxspuxgiwk.supabase.co`, or
     `api.getride.my`); custom header: name `X-Session-Key`, no prefix,
     value the key. The environment adds that header to every request to
     those hosts, and nothing in the session ever sees the key. The relay
     and the backend both read it (migration `0230`), so the calls below
     need no `p_key` and no `Authorization` of their own.
   - **As an environment variable** named `GETRIDE_SESSION_KEY`, which the
     session passes itself: as `p_key` to the backend, and as a bearer token
     to the relay.
3. For internet through the phone, on the gateway phone open the GET.ride
   Gateway app and turn on **Share this phone's internet** (the gateway must
   be online; "Mobile data only" keeps shared requests on the SIM even when
   the phone is on Wi-Fi).
4. The session's environment must be allowed to reach the backend and the
   relay. In a Claude Code cloud environment the network policy is set per
   environment (the cloud environment menu in the session's title bar →
   Edit → Network access): Full access, or Limited with these hosts:
   `rqlavogkgywxspuxgiwk.supabase.co` (or `api.getride.my`, the same backend)
   and `proxy.getride.my`. The relay is not a CONNECT proxy and does not
   replace that setting.

## What a session does with it

Every call takes the key as `p_key`, or from the request's `X-Session-Key`
header when `p_key` is left out (an explicit `p_key` wins), and needs no
sign-in: the session calls the backend's REST endpoint with the project's
public anon key (the one in the apps). `SUPABASE_URL` and `SUPABASE_ANON_KEY`
are the project's; `api.getride.my` serves the same backend for networks that
cannot look up `*.supabase.co`. The lines below pass the key explicitly; with
the network secret, drop the `p_key` field from each.

```bash
rpc() {  # rpc <function> '<json params>'
  curl -sS "$SUPABASE_URL/rest/v1/rpc/$1" \
    -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
    -H "Content-Type: application/json" -d "$2"
}

# What this key is: its name, number, scopes, expiry and proxy phone.
rpc session_key_info "{\"p_key\": \"$GETRIDE_SESSION_KEY\"}"

# Text the test number (support_message by default, or marketing).
rpc session_key_send_sms "{\"p_key\": \"$GETRIDE_SESSION_KEY\", \"p_body\": \"Hello from the test\"}"

# What was queued for the test number, newest first. With `codes`, a sign-in
# code's text is in clear; this is how a session reads the code after it
# asked the app to sign in with the test number.
rpc session_key_outbox "{\"p_key\": \"$GETRIDE_SESSION_KEY\", \"p_limit\": 5}"

# What the gateway received from the test number (after a time, optionally).
rpc session_key_inbox "{\"p_key\": \"$GETRIDE_SESSION_KEY\", \"p_since\": \"2026-10-18T08:00:00Z\"}"
```

A refusal is an HTTP 4xx whose JSON carries `message` (`SESSION_KEY_INVALID`,
`SESSION_KEY_SCOPE`, `SESSION_KEY_CHANNEL`, …) and a `hint` that says what to
do.

### Signing in as the test account

Ask the app (or the Auth endpoint the app uses) to sign in with the test
number as usual; the sign-in hook queues the code on the `otp` channel and
the gateway phone sends it. Then poll `session_key_outbox` until a row with
`"channel": "otp"` newer than the request appears, read the digits out of its
`body`, and hand them to the app. A code expires after the minutes set in
Sign-in SMS limits, so poll every few seconds, not every minute.

### Internet through the phone

The relay at `proxy.getride.my` (`cloudflare/session-proxy/`) is an HTTP
fetch-through: the URL to fetch goes after the first slash, the key in the
`Authorization` header or in `X-Session-Key` (what the network secret adds;
then the lines below need no `-H "Authorization: ..."`).

```bash
curl -H "Authorization: Bearer $GETRIDE_SESSION_KEY" \
     https://proxy.getride.my/https://api.example.com/v1/thing?x=1

curl -X POST -H "Authorization: Bearer $GETRIDE_SESSION_KEY" -H "Content-Type: application/json" \
     -d '{"a": 1}' https://proxy.getride.my/https://api.example.com/v1/thing
```

The method, the body and the request headers go through as they are, apart
from the key, the hop-by-hop headers and `Accept-Encoding` (the phone
negotiates compression itself and hands back plain bytes). The answer comes
back with its status and headers, plus `X-Relay-Phone` naming the phone;
redirects are not followed. The relay refuses with a JSON `error` and `hint`
when the key is wrong (401), lacks the scope (403), or the phone is not
connected (503: on the phone, the gateway must be online with "Share this
phone's internet" on). A request body may be up to 20 MB; the phone has 60 s
to start answering.

Everything the session sends through the phone leaves from that SIM, on the
phone's data plan: keep it to the test.

## How it is built

- **Backend** (`supabase/migrations/0226_session_access.sql`, tested by
  `supabase/tests/session_access.sql`): `session_keys` holds a hash of each
  key, its number, scopes, proxy phone and expiry. `admin_session_key_create`,
  `admin_session_keys` and `admin_session_key_revoke` are the card's;
  `session_key_info`, `session_key_send_sms`, `session_key_outbox`,
  `session_key_inbox` and `session_key_proxy_check` are the session's, each
  resolving the key with `session_by_key`, which counts the use and, since
  `0230`, reads the `X-Session-Key` header when no key is passed.
  `gateway_key_check` tells the relay which phone a device key is.
- **Admin** (`lib/src/admin/screens/session_access_card.dart`, rules in
  `lib/src/core/session_access.dart`): the card on Admin → SMS / WhatsApp.
- **Relay** (`cloudflare/session-proxy/worker.js`, tested by
  `relay_test.ts`): a worker on `proxy.getride.my` with one Durable Object per
  gateway phone, holding the phone's WebSocket and the requests in flight;
  the frames are documented in its header. Deployed by
  `.github/workflows/cloudflare-worker.yml` beside the subdomain proxy.
- **Phone** (`gateway/android/.../ProxyClient.kt`, driven by
  `gateway/lib/src/engine.dart`): the gateway app dials the relay with its
  device key while "Share this phone's internet" is on, performs each request
  over mobile data (OkHttp bound to the cellular network when there is one)
  and streams the answer back. The switch is on the gateway's home screen.
