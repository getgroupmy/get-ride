/**
 * The VoIP half of send-push, without touching Apple.
 *
 *     deno test supabase/functions/_shared/apns_test.ts
 */
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import {
  apnsJwt,
  apnsOutcome,
  apnsRequest,
  APNS_PRODUCTION,
  DEFAULT_BUNDLE_ID,
  parseApnsKey,
  RING_MS,
  voipPayload,
} from "./apns.ts";

function b64urlDecode(s: string): Uint8Array<ArrayBuffer> {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

async function testKeyPem(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  let s = "";
  for (const b of der) s += String.fromCharCode(b);
  const body = btoa(s).match(/.{1,64}/g)!.join("\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`, publicKey: pair.publicKey };
}

Deno.test("the key is configured only when every part is set", () => {
  const env = (m: Record<string, string>) => (k: string) => m[k];
  assertEquals(parseApnsKey(env({})), null);
  assertEquals(parseApnsKey(env({ APNS_AUTH_KEY: "x", APNS_KEY_ID: "K", APNS_TEAM_ID: "T" })), null);
  const pem = "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----";
  assertEquals(parseApnsKey(env({ APNS_AUTH_KEY: pem, APNS_KEY_ID: "K" })), null);
  const key = parseApnsKey(env({ APNS_AUTH_KEY: pem, APNS_KEY_ID: " K ", APNS_TEAM_ID: "T" }));
  assertEquals(key, { p8: pem, keyId: "K", teamId: "T", bundleId: DEFAULT_BUNDLE_ID });
  assertEquals(
    parseApnsKey(env({ APNS_AUTH_KEY: pem, APNS_KEY_ID: "K", APNS_TEAM_ID: "T", APNS_BUNDLE_ID: "my.app" }))?.bundleId,
    "my.app",
  );
});

Deno.test("the provider token is an ES256 JWT from the team, verifiable with the key", async () => {
  const { pem, publicKey } = await testKeyPem();
  const jwt = await apnsJwt({ p8: pem, keyId: "KEY123", teamId: "TEAM9", bundleId: "a.b" }, 1_700_000_000.7);
  const [h, c, sig] = jwt.split(".");
  const dec = new TextDecoder();
  assertEquals(JSON.parse(dec.decode(b64urlDecode(h))), { alg: "ES256", kid: "KEY123" });
  assertEquals(JSON.parse(dec.decode(b64urlDecode(c))), { iss: "TEAM9", iat: 1_700_000_000 });
  assertEquals(b64urlDecode(sig).length, 64);
  assert(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      b64urlDecode(sig),
      new TextEncoder().encode(`${h}.${c}`),
    ),
  );
});

Deno.test("the payload is what flutter_callkit_incoming reads, keyed by the call", () => {
  const p = voipPayload(
    { type: "ride_call", call_id: "c1", request_id: "r1", role: "partner", caller_name: "Aina" },
    "Aina is calling",
  );
  assertEquals(p.id, "c1");
  assertEquals(p.nameCaller, "Aina");
  assertEquals(p.duration, RING_MS);
  assertEquals(p.type, 0);
  assertEquals(p.extra, { type: "ride_call", call_id: "c1", request_id: "r1", role: "partner", caller_name: "Aina" });
  assertEquals((p.ios as Record<string, unknown>).supportsVideo, false);
  assertEquals(p.aps, {});
  // A caller name only in the title.
  assertEquals(voipPayload({ call_id: "c2" }, "Ahmad is calling").nameCaller, "Ahmad");
  assertEquals(voipPayload({ call_id: "c3" }, " is calling").nameCaller, "GET.ride");
});

Deno.test("the request is a VoIP push to the app's .voip topic, never delivered late", () => {
  const { url, init } = apnsRequest(
    APNS_PRODUCTION,
    { p8: "", keyId: "K", teamId: "T", bundleId: "com.taxxee.teksi" },
    "jwt",
    "abcd",
    { aps: {} },
  );
  assertEquals(url, "https://api.push.apple.com/3/device/abcd");
  assertEquals(init.headers["apns-topic"], "com.taxxee.teksi.voip");
  assertEquals(init.headers["apns-push-type"], "voip");
  assertEquals(init.headers["apns-expiration"], "0");
  assertEquals(init.headers.authorization, "bearer jwt");
});

Deno.test("only a token APNs says is gone is pruned; a bad token tries the other environment", () => {
  assertEquals(apnsOutcome(200, null), "sent");
  assertEquals(apnsOutcome(410, "Unregistered"), "unregistered");
  assertEquals(apnsOutcome(400, "BadDeviceToken"), "wrong_environment");
  assertEquals(apnsOutcome(403, "InvalidProviderToken"), "failed");
  assertEquals(apnsOutcome(429, "TooManyRequests"), "failed");
});
