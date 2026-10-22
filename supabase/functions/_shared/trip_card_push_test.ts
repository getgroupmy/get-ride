// trip-card-push: who is sent what (trip_card_push.ts) — the rider's and the
// driver's Android phones in their mode, the admin's switches, the done
// card's minutes, an end for a cancelled ride or a former driver — the FCM
// message a closed app's receiver runs for, and who may call it.
//
//     deno test --allow-read=lib,supabase supabase/functions/_shared/trip_card_push_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import type { PushAuthDeps } from "./push_auth.ts";
import type { TripRide } from "./trip_card.ts";
import {
  androidTokens,
  cardMessage,
  handleTripCardPush,
  planTripCardPushes,
  type TokenRow,
  tripCardFcmMessage,
  type TripCardPushDeps,
  type TripCardSnapshot,
} from "./trip_card_push.ts";

const RIDE = "11111111-1111-4111-8111-111111111111";
const RIDER = "22222222-2222-4222-8222-222222222222";
const DRIVER = "33333333-3333-4333-8333-333333333333";
const FORMER = "44444444-4444-4444-8444-444444444444";
const now = new Date("2026-10-22T07:48:00Z");

const ride = (extra: Partial<TripRide> = {}): TripRide => ({
  id: RIDE,
  status: "accepted",
  rider_id: RIDER,
  rider_name: "Aina Rahman",
  partner_id: DRIVER,
  partner_name: "Ali Hassan",
  partner_vehicle: "Perodua Bezza",
  partner_plate: "WXY 4821",
  pickup_name: "Mid Valley",
  pickup_lat: 3.118,
  pickup_lng: 101.677,
  drop_name: "KLCC",
  drop_lat: 3.1579,
  drop_lng: 101.7116,
  distance_km: 7.5,
  duration_min: 18,
  fare: 18.5,
  total_due: 18.5,
  currency: "MYR",
  partner_accept_lat: 3.091,
  partner_accept_lng: 101.677,
  partner_live_lat: 3.1045,
  partner_live_lng: 101.677,
  timezone: "UTC",
  ...extra,
});

const tokens: TokenRow[] = [
  { token: "rider-android", platform: "android", profile_id: RIDER, mode: "rider" },
  { token: "rider-android-unsaid", platform: "android", profile_id: RIDER, mode: null },
  { token: "rider-android-driving", platform: "android", profile_id: RIDER, mode: "partner" },
  { token: "rider-iphone", platform: "ios", profile_id: RIDER, mode: "rider" },
  { token: "ExponentPushToken[abc]", platform: "android", profile_id: RIDER, mode: "rider" },
  { token: "driver-android", platform: "android", profile_id: DRIVER, mode: "partner" },
  { token: "driver-android-riding", platform: "android", profile_id: DRIVER, mode: "rider" },
  { token: "former-android", platform: "android", profile_id: FORMER, mode: "partner" },
];

const card = (data: Record<string, string>) => JSON.parse(data.card) as Record<string, unknown>;

Deno.test("android phones only, in the right mode", () => {
  assertEquals(androidTokens(tokens, RIDER, "rider"), ["rider-android", "rider-android-unsaid"]);
  assertEquals(androidTokens(tokens, DRIVER, "partner"), ["driver-android"]);
});

Deno.test("the rider's and the driver's cards, each to their own phones", () => {
  const plan = planTripCardPushes({ ride: ride(), settings: {} }, tokens, now);
  assertEquals(plan.map((d) => `${d.role}:${d.token}`), [
    "rider:rider-android",
    "rider:rider-android-unsaid",
    "driver:driver-android",
  ]);
  const rider = card(plan[0].data);
  assertEquals(plan[0].data.type, "trip_card");
  assertEquals(plan[0].data.ride_id, RIDE);
  assertEquals(rider.role, "rider");
  assertEquals(rider.headline, "Ali is 4 min away");
  assertEquals(rider.plate, "WXY 4821");
  assertEquals(rider.ongoing, true);
  assertEquals(rider.pushedAtMs, now.getTime());
  assertEquals(rider.clearAfterMs, 5 * 60000);
  assertEquals(rider.footTitle, null, "sent as null so the last stage's line goes");
  assertEquals(plan[0].ttl, "60s");
  const driver = card(plan[2].data);
  assertEquals(driver.role, "driver");
  assertEquals(driver.headline, "Pick up Aina in 4 min");
  assertEquals(driver.openUri, `getride://trip/${RIDE}?as=driver`);
  for (const d of plan) assert(Object.values(d.data).every((v) => typeof v === "string"), "FCM data is strings");
});

Deno.test("an open request: the rider only (a bidder has no card)", () => {
  const plan = planTripCardPushes({ ride: ride({ status: "open" }), settings: {} }, tokens, now);
  assertEquals(plan.map((d) => d.role), ["rider", "rider"]);
  assertEquals(card(plan[0].data).headline, "Looking for a driver");
});

Deno.test("cancelled or expired: the cards end at once", () => {
  for (const status of ["cancelled", "expired"]) {
    const plan = planTripCardPushes({ ride: ride({ status }), settings: {} }, tokens, now);
    assertEquals(plan.length, 3);
    for (const d of plan) {
      assertEquals(d.data, { type: "trip_card", ride_id: RIDE, end: "1" });
      assertEquals(d.ttl, "3600s");
    }
  }
});

Deno.test("done: stays its minutes after the trip ended, then ends; 0 ends at once", () => {
  const done = ride({ status: "completed", completed_at: "2026-10-22T07:46:00Z" });
  const m = cardMessage(done, false, { doneMinutes: 5 }, now)!;
  const c = card(m.data);
  assertEquals(c.ongoing, false);
  assertEquals(c.headline, "You have arrived");
  assertEquals(c.clearAfterMs, 3 * 60000, "five minutes from the end, two of them gone");
  assertEquals(m.ttl, "3600s");
  assertEquals(cardMessage(done, false, { doneMinutes: 1 }, now)!.data.end, "1", "its minute is over");
  assertEquals(cardMessage(done, false, { doneMinutes: 0 }, now)!.data.end, "1");
  assertEquals(cardMessage(done, true, { doneMinutes: 5 }, now)!.data.end, undefined);
});

Deno.test("admin switches: a service off ends its cards; drivers off ends the driver's only", () => {
  const off = planTripCardPushes({ ride: ride(), settings: { ride: false } }, tokens, now);
  assert(off.every((d) => d.data.end === "1"));
  const drivers = planTripCardPushes({ ride: ride(), settings: { driver: false } }, tokens, now);
  assertEquals(drivers.find((d) => d.role === "driver")!.data.end, "1");
  assert(drivers.filter((d) => d.role === "rider").every((d) => d.data.card));
  const courier = { parcel_size: "S", cargo_description: "Documents" };
  const noCourier = planTripCardPushes({ ride: ride(courier), settings: { courier: false } }, tokens, now);
  assert(noCourier.every((d) => d.data.end === "1"));
  const noFreight = planTripCardPushes({ ride: ride(courier), settings: { freight: false } }, tokens, now);
  assert(noFreight.every((d) => d.data.card), "a courier parcel is not freight here");
});

Deno.test("a former driver's card ends when the ride moves on without them", () => {
  const plan = planTripCardPushes({ ride: ride({ status: "open", partner_id: null }), settings: {} }, tokens, now, FORMER);
  const former = plan.filter((d) => d.token === "former-android");
  assertEquals(former.length, 1);
  assertEquals(former[0].data.end, "1");
  assertEquals(planTripCardPushes({ ride: ride(), settings: {} }, tokens, now, DRIVER).length, 3, "same driver: no end");
});

Deno.test("never the trip code or the delivery code", () => {
  const secret = { otp: "4719", delivery_code: "4719", parcel_size: "S", cargo_description: "Docs" } as Partial<TripRide>;
  for (const status of ["open", "accepted", "arrived", "on_trip", "completed"]) {
    const plan = planTripCardPushes({ ride: ride({ ...secret, status, completed_at: now.toISOString() }), settings: {} }, tokens, now);
    for (const d of plan) assert(!JSON.stringify(tripCardFcmMessage(d)).includes("4719"), status);
  }
});

Deno.test("the FCM message wakes a closed app: data only, high priority, one collapse key per ride", () => {
  const [d] = planTripCardPushes({ ride: ride(), settings: {} }, tokens, now);
  const m = tripCardFcmMessage(d);
  assertEquals(m.message.token, "rider-android");
  assertEquals(m.message.android.priority, "HIGH");
  assertEquals(m.message.android.ttl, "60s");
  assertEquals(m.message.android.collapse_key, `trip_card_${RIDE}`);
  assert(!("notification" in m.message), "no notification block");
  assert(!("notification" in m.message.android));
  assert(!("apns" in m.message));
});

// ---- The request ------------------------------------------------------------

const SERVICE = "service-role-key";
const SECRET = "vault-secret";
const auth: PushAuthDeps = {
  serviceKeys: [SERVICE],
  webhookSecretOk: (s) => Promise.resolve(s === SECRET),
  callerCanPush: () => Promise.resolve(true),
};

function deps(snapshot: TripCardSnapshot | null, sent: string[], pruned: string[][], outcome: (t: string) => "sent" | "unregistered" | "failed" = () => "sent"): TripCardPushDeps {
  return {
    auth,
    snapshot: () => Promise.resolve(snapshot),
    tokens: (ids) => Promise.resolve(tokens.filter((t) => ids.includes(t.profile_id!))),
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
  new Request("https://x/functions/v1/trip-card-push", { method: "POST", headers, body: JSON.stringify(body) });

Deno.test("callers: the database's secret or the service role; not an admin, not anyone", async () => {
  const sent: string[] = [];
  const d = deps({ ride: ride(), settings: {} }, sent, []);
  assertEquals((await handleTripCardPush(post({ rideId: RIDE }, {}), d)).status, 401);
  assertEquals((await handleTripCardPush(post({ rideId: RIDE }, { "x-push-secret": "wrong" }), d)).status, 401);
  assertEquals((await handleTripCardPush(post({ rideId: RIDE }, { Authorization: "Bearer admin.jwt" }), d)).status, 401);
  assertEquals(sent.length, 0);
  assertEquals((await handleTripCardPush(post({ rideId: RIDE }, { "x-push-secret": SECRET }), d)).status, 200);
  assertEquals((await handleTripCardPush(post({ rideId: RIDE }, { Authorization: `Bearer ${SERVICE}` }), d)).status, 200);
  assertEquals((await handleTripCardPush(new Request("https://x", { method: "GET" }), d)).status, 405);
});

Deno.test("sends to each phone and prunes the ones FCM says are gone", async () => {
  const sent: string[] = [];
  const pruned: string[][] = [];
  const d = deps({ ride: ride(), settings: {} }, sent, pruned, (t) => (t === "rider-android-unsaid" ? "unregistered" : "sent"));
  const res = await handleTripCardPush(post({ rideId: RIDE }, { "x-push-secret": SECRET }), d);
  assertEquals(await res.json(), { sent: 2, failed: 1, pruned: 1 });
  assertEquals(sent.sort(), ["driver-android", "rider-android", "rider-android-unsaid"]);
  assertEquals(pruned, [["rider-android-unsaid"]]);
});

Deno.test("a bad body or a ride that is gone sends nothing", async () => {
  const sent: string[] = [];
  const h = { "x-push-secret": SECRET };
  assertEquals((await handleTripCardPush(post({ rideId: "nope" }, h), deps({ ride: ride() }, sent, []))).status, 400);
  const gone = await handleTripCardPush(post({ rideId: RIDE }, h), deps(null, sent, []));
  assertEquals((await gone.json()).sent, 0);
  assertEquals(sent.length, 0);
});
