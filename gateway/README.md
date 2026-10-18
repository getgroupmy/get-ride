# GET.ride Gateway

An Android app that turns a phone with a SIM into GET.ride's SMS gateway: it
sends the SMS the server routes to it (sign-in codes, marketing, support
messages) and hands every SMS the phone receives to the server.

It is its own app, not part of GET.ride, because Google Play only lets the
default SMS app send SMS in the background. The gateway is installed from
its APK instead:
<https://github.com/getgroupmy/get-ride/releases/download/gateway-latest/getride-gateway.apk>
(published by `.github/workflows/gateway.yml` on every change to `main`, and
linked from Admin → SMS / WhatsApp).

## Setting up a gateway phone

1. Install the APK (allow "install unknown apps" for the browser once).
2. Pair it: a full admin opens Admin → SMS / WhatsApp → **Pair a gateway
   phone** in the GET.ride app and types the code shown into the gateway
   (once; the code lasts 10 minutes). The phone keeps a device key of its own
   and never needs a sign-in; removing it from Devices disconnects it.
3. Allow SMS, SIM cards and notifications; allow unrestricted battery use, or
   Android pauses the gateway while the screen is off.
4. On a dual-SIM phone pick the sending SIM; type the SIM's number and a
   name, as the admin page will show them.
5. Turn the gateway on. In Admin → SMS / WhatsApp, pick this phone for the
   channels it should carry.

While online it shows an ongoing notification. It turns itself back on when
the app is opened, but not after a restart of the phone: open the app once.

## Sharing the phone's internet with a test session

A test session (a Claude Code cloud session, a CI job) given this phone in
Admin → SMS / WhatsApp → Session access can make its HTTP requests through
it, so they leave from this SIM's network (docs/session-access.md). Turn on
**Share this phone's internet** on the gateway's screen; it works while the
gateway is online. "Mobile data only" keeps those requests on the SIM even
when the phone is on Wi-Fi. The phone dials the relay at proxy.getride.my
with its device key (`ProxyClient.kt`); nothing is open for incoming
connections.

## How it works

- `lib/src/engine.dart`: the loop. A heartbeat every minute
  (`messaging_heartbeat`), then every 5 s it hands over received SMS
  (`gateway_receive_sms`), claims the jobs routed to it
  (`gateway_claim_sms`), sends each and reports it (`gateway_report_sms`).
  A lost connection backs off and retries; a refusal (the account is not an
  admin) stops it with the reason. A received SMS leaves the phone's queue
  only once the server has it; a sent SMS is never sent twice because its
  report was lost.
- `android/app/src/main/kotlin/…`: sending (`SmsSender`, multipart, one
  answer per SMS), receiving (`SmsReceiver` → `InboxStore`, on disk), SIMs,
  the foreground service (`GatewayService`), and the shared internet
  (`ProxyClient`: the relay's WebSocket and the requests it hands over,
  performed over mobile data).
- The server side is migrations `0120` (devices, routes, queue, RPCs),
  `0121` (a gateway must be an admin's), `0190` (pairing and device keys)
  and `0223` (session access: the keys and the relay's checks).

```bash
flutter test            # core, engine and screen tests
flutter build apk --release
```
