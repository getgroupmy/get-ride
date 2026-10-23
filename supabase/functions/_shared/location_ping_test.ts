// location-ping (location_ping.ts): the silent push each phone gets — an
// iPhone a background push, Android a data-only high-priority message, both
// `{ type: "location_ping" }` only — who may call it, the body it takes,
// sending to the targets the database hands back and pruning the tokens FCM
// says are gone.
//
//     deno test --allow-read=lib,supabase supabase/functions/_shared/location_ping_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import type { PushAuthDeps } from "./push_auth.ts";
import {
  eachLimited,
  handleLocationPing,
  LOCATION_LIVE,
  LOCATION_PING,
  type LocationPingDeps,
  locationPingMessage,
  type PingTarget,
  pingTypeOf,
  tokenIdsOf,
} from "./location_ping.ts";

const now = new Date("2026-10-23T09:00:00Z");
const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const C = "33333333-3333-4333-8333-333333333333";

Deno.test("an iPhone: a background push, priority 5, content-available, no alert", () => {
  const m = locationPingMessage({ token: "ios-1", platform: "ios" }, now)!;
  assertEquals(m.message.token, "ios-1");
  assertEquals(m.message.data, { type: LOCATION_PING });
  assert("apns" in m.message);
  const apns = (m.message as { apns: { headers: Record<string, string>; payload: { aps: Record<string, unknown> } } }).apns;
  assertEquals(apns.headers["apns-push-type"], "background");
  assertEquals(apns.headers["apns-priority"], "5");
  assertEquals(apns.headers["apns-expiration"], String(Math.floor(now.getTime() / 1000) + 300));
  assertEquals(apns.payload, { aps: { "content-available": 1 } });
  assert(!("notification" in m.message), "no notification block");
  assert(!("alert" in apns.payload.aps) && !("sound" in apns.payload.aps), "silent");
  assert(!("android" in m.message));
});

Deno.test("Android: data only, high priority, one collapse key", () => {
  const m = locationPingMessage({ token: "and-1", platform: "android" }, now)!;
  assertEquals(m.message.data, { type: LOCATION_PING });
  const android = (m.message as { android: Record<string, string> }).android;
  assertEquals(android, { priority: "HIGH", ttl: "300s", collapse_key: LOCATION_PING });
  assert(!("notification" in m.message));
  assert(!("apns" in m.message));
});

Deno.test("Live now (0282): location_live, the same silent push with a minute to live", () => {
  assertEquals(pingTypeOf("live"), LOCATION_LIVE);
  assertEquals(pingTypeOf("manual"), LOCATION_PING);
  assertEquals(pingTypeOf(undefined), LOCATION_PING);
  const ios = locationPingMessage({ token: "ios-1", platform: "ios" }, now, LOCATION_LIVE)!;
  assertEquals(ios.message.data, { type: LOCATION_LIVE });
  const apns = (ios.message as { apns: { headers: Record<string, string>; payload: unknown } }).apns;
  assertEquals(apns.headers["apns-push-type"], "background");
  assertEquals(apns.headers["apns-priority"], "5");
  assertEquals(apns.headers["apns-expiration"], String(Math.floor(now.getTime() / 1000) + 60));
  assertEquals(apns.headers["apns-collapse-id"], LOCATION_LIVE);
  assertEquals(apns.payload, { aps: { "content-available": 1 } });
  const and = locationPingMessage({ token: "and-1", platform: "android" }, now, LOCATION_LIVE)!;
  assertEquals((and.message as { android: Record<string, string> }).android, {
    priority: "HIGH",
    ttl: "60s",
    collapse_key: LOCATION_LIVE,
  });
  assert(!("notification" in and.message));
});

Deno.test("never a PushKit, Expo, web or empty token", () => {
  assertEquals(locationPingMessage({ token: "voip", platform: "ios_voip" }, now), null);
  assertEquals(locationPingMessage({ token: "ExponentPushToken[abc]", platform: "ios" }, now), null);
  assertEquals(locationPingMessage({ token: "web", platform: "web" }, now), null);
  assertEquals(locationPingMessage({ token: "", platform: "android" }, now), null);
});

Deno.test("the body's token ids: distinct uuids only", () => {
  assertEquals(tokenIdsOf([A, A.toUpperCase(), "nope", 3, ` ${B} `]), [A, B]);
  assertEquals(tokenIdsOf("x"), []);
  assertEquals(tokenIdsOf(null), []);
});

Deno.test("a few at a time", async () => {
  let running = 0, most = 0;
  const done: number[] = [];
  await eachLimited([1, 2, 3, 4, 5, 6, 7], 3, async (n) => {
    running += 1;
    most = Math.max(most, running);
    await new Promise((r) => setTimeout(r, 1));
    done.push(n);
    running -= 1;
  });
  assertEquals(done.sort(), [1, 2, 3, 4, 5, 6, 7]);
  assert(most <= 3);
  await eachLimited([], 3, () => Promise.resolve());
});

// ---- The request ------------------------------------------------------------

const SERVICE = "service-role-key";
const SECRET = "vault-secret";
const auth: PushAuthDeps = {
  serviceKeys: [SERVICE],
  webhookSecretOk: (s) => Promise.resolve(s === SECRET),
  callerCanPush: () => Promise.resolve(true),
};

const targets: Record<string, PingTarget> = {
  [A]: { id: A, token: "ios-a", platform: "ios" },
  [B]: { id: B, token: "and-b", platform: "android" },
  [C]: { id: C, token: "voip-c", platform: "ios_voip" },
};

function deps(
  asked: string[][],
  sent: string[],
  pruned: string[][],
  outcome: (t: string) => "sent" | "unregistered" | "failed" = () => "sent",
): LocationPingDeps {
  return {
    auth,
    targets: (ids) => {
      asked.push(ids);
      return Promise.resolve(ids.map((id) => targets[id]).filter((t): t is PingTarget => t !== undefined));
    },
    send: (m) => {
      sent.push(m.message.token);
      return Promise.resolve(outcome(m.message.token));
    },
    prune: (t) => {
      pruned.push(t);
      return Promise.resolve();
    },
    now: () => now,
  };
}

const post = (body: unknown, headers: Record<string, string>) =>
  new Request("https://x/functions/v1/location-ping", { method: "POST", headers, body: JSON.stringify(body) });

Deno.test("callers: the database's secret or the service role; not an admin, not anyone", async () => {
  const sent: string[] = [];
  const d = deps([], sent, []);
  const body = { tokenIds: [A] };
  assertEquals((await handleLocationPing(post(body, {}), d)).status, 401);
  assertEquals((await handleLocationPing(post(body, { "x-push-secret": "wrong" }), d)).status, 401);
  assertEquals((await handleLocationPing(post(body, { Authorization: "Bearer admin.jwt" }), d)).status, 401);
  assertEquals(sent.length, 0);
  assertEquals((await handleLocationPing(post(body, { "x-push-secret": SECRET }), d)).status, 200);
  assertEquals((await handleLocationPing(post(body, { Authorization: `Bearer ${SERVICE}` }), d)).status, 200);
  assertEquals((await handleLocationPing(new Request("https://x", { method: "GET" }), d)).status, 405);
});

Deno.test("sends to the targets the database hands back and prunes the ones FCM says are gone", async () => {
  const asked: string[][] = [];
  const sent: string[] = [];
  const pruned: string[][] = [];
  const d = deps(asked, sent, pruned, (t) => (t === "and-b" ? "unregistered" : "sent"));
  const res = await handleLocationPing(post({ tokenIds: [A, B, C], reason: "scheduled" }, { "x-push-secret": SECRET }), d);
  assertEquals(await res.json(), { sent: 1, failed: 1, pruned: 1 });
  assertEquals(asked, [[A, B, C]]);
  assertEquals(sent.sort(), ["and-b", "ios-a"], "never the PushKit token");
  assertEquals(pruned, [["and-b"]]);
});

Deno.test("reason live sends location_live to each target", async () => {
  const seen: string[] = [];
  const d: LocationPingDeps = {
    ...deps([], [], []),
    send: (m) => {
      seen.push(`${m.message.token}:${m.message.data.type}`);
      return Promise.resolve("sent");
    },
  };
  const res = await handleLocationPing(post({ tokenIds: [A, B], reason: "live" }, { "x-push-secret": SECRET }), d);
  assertEquals(await res.json(), { sent: 2, failed: 0, pruned: 0 });
  assertEquals(seen.sort(), ["and-b:location_live", "ios-a:location_live"]);
});

Deno.test("a bad body sends nothing", async () => {
  const asked: string[][] = [];
  const sent: string[] = [];
  const h = { "x-push-secret": SECRET };
  assertEquals((await handleLocationPing(post({ tokenIds: ["nope"] }, h), deps(asked, sent, []))).status, 400);
  assertEquals((await handleLocationPing(post({}, h), deps(asked, sent, []))).status, 400);
  const bad = new Request("https://x", { method: "POST", headers: h, body: "{" });
  assertEquals((await handleLocationPing(bad, deps(asked, sent, []))).status, 400);
  assertEquals(asked.length + sent.length, 0);
});
