/**
 * What send-push decides before touching the network.
 *
 *     deno test supabase/functions/_shared/push_test.ts
 */
import { assertEquals } from "jsr:@std/assert@1.0.19";

import {
  ANDROID_CHANNEL_ID,
  fallbackAlerts,
  fcmCallMessage,
  fcmData,
  collapseIdFor,
  fcmMessage,
  fcmOutcome,
  fcmSendUrl,
  isExpoToken,
  parseServiceAccount,
  distanceKm,
  inArea,
  inboxRows,
  inMode,
  notificationMode,
  parseArea,
  pickRecipients,
  planDeliveries,
  profileIdList,
  readAllPages,
  resolveAudience,
  splitTokens,
  voipFallbacks,
} from "./push.ts";

Deno.test("Expo tokens are told apart from FCM tokens", () => {
  assertEquals(isExpoToken("ExponentPushToken[abc]"), true);
  assertEquals(isExpoToken("ExpoPushToken[abc]"), true);
  assertEquals(isExpoToken("dGVzdDpBUEE5MWJ..."), false);
});

Deno.test("tokens are split by service, deduplicated and cleaned", () => {
  const { expo, fcm } = splitTokens([
    "ExponentPushToken[a]",
    "fcm-1",
    " fcm-1 ",
    "",
    null,
    42,
    "ExponentPushToken[a]",
    "fcm-2",
  ]);
  assertEquals(expo, ["ExponentPushToken[a]"]);
  assertEquals(fcm, ["fcm-1", "fcm-2"]);
});

Deno.test("FCM data is a string map", () => {
  assertEquals(
    fcmData({ type: "ride_request", n: 3, ok: true, obj: { a: 1 }, gone: null, missing: undefined }),
    { type: "ride_request", n: "3", ok: "true", obj: '{"a":1}' },
  );
  assertEquals(fcmData(undefined), {});
});

Deno.test("the service account needs a project, an email and a key", () => {
  const full = { project_id: "p", client_email: "e", private_key: "k" };
  assertEquals(parseServiceAccount(JSON.stringify(full))?.project_id, "p");
  assertEquals(parseServiceAccount(JSON.stringify({ ...full, project_id: "" })), null);
  assertEquals(parseServiceAccount("not json"), null);
  assertEquals(parseServiceAccount(""), null);
  assertEquals(parseServiceAccount(undefined), null);
});

Deno.test("the message is loud on both platforms", () => {
  const { message } = fcmMessage("tok", "New ride request", "Pickup at KLCC", {
    type: "ride_request",
    ride_request_id: "r1",
  });
  assertEquals(message.token, "tok");
  assertEquals(message.notification, { title: "New ride request", body: "Pickup at KLCC" });
  assertEquals(message.data, { type: "ride_request", ride_request_id: "r1" });
  assertEquals(message.android.priority, "HIGH");
  assertEquals(message.android.notification.channel_id, ANDROID_CHANNEL_ID);
  assertEquals(message.apns.payload.aps.sound, "default");
  assertEquals(fcmSendUrl("my-proj"), "https://fcm.googleapis.com/v1/projects/my-proj/messages:send");
});

Deno.test("a retried event replaces the notification instead of stacking", () => {
  const { message } = fcmMessage("tok", "Your driver has arrived", "ABC1234 is waiting.", {
    type: "ride_status",
    event_id: "r1:arrived:r",
  });
  assertEquals(message.android.notification.tag, "r1:arrived:r");
  assertEquals(message.apns.headers["apns-collapse-id"], "r1:arrived:r");
  const plain = fcmMessage("tok", "t", "b", { type: "ride_request" }).message;
  assertEquals("tag" in plain.android.notification, false);
  assertEquals("apns-collapse-id" in plain.apns.headers, false);
  assertEquals(collapseIdFor({ event_id: "x".repeat(80) })?.length, 64);
  assertEquals(collapseIdFor({ event_id: " " }), null);
  assertEquals(collapseIdFor(null), null);
});

Deno.test("only tokens FCM says are gone get pruned", () => {
  assertEquals(fcmOutcome(200, { name: "projects/p/messages/1" }), "sent");
  assertEquals(
    fcmOutcome(404, {
      error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] },
    }),
    "unregistered",
  );
  assertEquals(
    fcmOutcome(400, {
      error: {
        status: "INVALID_ARGUMENT",
        message: "The registration token is not a valid FCM registration token",
        details: [{ errorCode: "INVALID_ARGUMENT" }],
      },
    }),
    "unregistered",
  );
  // A malformed message is our fault, not the token's.
  assertEquals(
    fcmOutcome(400, {
      error: { status: "INVALID_ARGUMENT", message: "Invalid value at 'message.data'" },
    }),
    "failed",
  );
  assertEquals(fcmOutcome(401, { error: { status: "UNAUTHENTICATED" } }), "failed");
  assertEquals(fcmOutcome(429, { error: { details: [{ errorCode: "QUOTA_EXCEEDED" }] } }), "failed");
  assertEquals(fcmOutcome(503, null), "failed");
});

Deno.test("a ride call rings a capable Android build with a data message, an older one with a notification", () => {
  const rows = [
    { token: "new-android", platform: "android", profile_id: "p", capabilities: ["call_ui"] },
    { token: "old-android", platform: "android", profile_id: "p", capabilities: [] },
    { token: "ExponentPushToken[x]", platform: "android", profile_id: "p" },
  ];
  assertEquals(planDeliveries(rows, "ride_call", false), [
    { via: "fcm", token: "new-android", style: "call" },
    { via: "fcm", token: "old-android", style: "alert" },
    { via: "expo", token: "ExponentPushToken[x]" },
  ]);
  assertEquals(planDeliveries(rows, "ride_call_end", false)[0], { via: "fcm", token: "new-android", style: "call" });
  // Anything else is a notification, whatever the build can do.
  assertEquals(planDeliveries(rows, "ride_message", false)[0], { via: "fcm", token: "new-android", style: "alert" });
});

Deno.test("VoIP tokens get ride calls only, and only with the APNs key", () => {
  const rows = [
    { token: "voip", platform: "ios_voip", profile_id: "p" },
    { token: "iphone", platform: "ios", profile_id: "p", capabilities: ["call_ui"] },
    { token: "other-iphone", platform: "ios", profile_id: "q" },
  ];
  // Without the key: the iPhone is told by notification, the VoIP token is left alone.
  assertEquals(planDeliveries(rows, "ride_call", false), [
    { via: "fcm", token: "iphone", style: "alert" },
    { via: "fcm", token: "other-iphone", style: "alert" },
  ]);
  // With it: CallKit rings, so that account's iPhone is not told twice.
  assertEquals(planDeliveries(rows, "ride_call", true), [
    { via: "voip", token: "voip" },
    { via: "fcm", token: "other-iphone", style: "alert" },
  ]);
  // A missed call is a notification; no VoIP push ever carries anything but a call.
  assertEquals(planDeliveries(rows, "ride_call_end", true), [
    { via: "fcm", token: "iphone", style: "alert" },
    { via: "fcm", token: "other-iphone", style: "alert" },
  ]);
  assertEquals(planDeliveries(rows, "ride_request", true).some((d) => d.via === "voip"), false);
});

Deno.test("an iPhone whose VoIP push did not reach Apple is sent the notification instead", () => {
  const rows = [
    { token: "voip-p", platform: "ios_voip", profile_id: "p" },
    { token: "iphone-p", platform: "ios", profile_id: "p", capabilities: ["call_ui"] },
    { token: "voip-q", platform: "ios_voip", profile_id: "q" },
    { token: "iphone-q", platform: "ios", profile_id: "q" },
    { token: "android-q", platform: "android", profile_id: "q", capabilities: ["call_ui"] },
    { token: "voip-only", platform: "ios_voip", profile_id: "r" },
  ];
  const fallbacks = voipFallbacks(rows, "ride_call", true);
  assertEquals(fallbacks, [
    { voip: ["voip-p"], iphones: ["iphone-p"] },
    { voip: ["voip-q"], iphones: ["iphone-q"] },
  ]);
  // p's CallKit rang; q's VoIP push was refused, so q's iPhone is told the ordinary way.
  assertEquals(fallbackAlerts(fallbacks, new Set(["voip-p"])), [{ via: "fcm", token: "iphone-q", style: "alert" }]);
  // Nothing reached Apple (a bad key): every withheld iPhone is told.
  assertEquals(fallbackAlerts(fallbacks, new Set()).map((d) => d.token), ["iphone-p", "iphone-q"]);
  // Only ride calls with the key withhold anything.
  assertEquals(voipFallbacks(rows, "ride_call", false), []);
  assertEquals(voipFallbacks(rows, "ride_call_end", true), []);
  // What is owed is exactly what planDeliveries withheld.
  const planned = planDeliveries(rows, "ride_call", true).map((d) => d.token);
  for (const f of fallbacks) for (const t of f.iphones) assertEquals(planned.includes(t), false);
});

Deno.test("devices are deduplicated and blanks dropped", () => {
  assertEquals(
    planDeliveries([{ token: " a " }, { token: "a" }, { token: "" }, { token: null as unknown as string }], undefined, true),
    [{ via: "fcm", token: "a", style: "alert" }],
  );
});

Deno.test("the Android call push is data only, urgent and short-lived", () => {
  const { message } = fcmCallMessage("tok", "Aina is calling", "Voice call about your ride.", {
    type: "ride_call",
    call_id: "c1",
  });
  assertEquals("notification" in message, false);
  assertEquals(message.data, {
    type: "ride_call",
    call_id: "c1",
    title: "Aina is calling",
    body: "Voice call about your ride.",
  });
  assertEquals(message.android, { priority: "HIGH", ttl: "45s" });
  assertEquals(fcmCallMessage("tok", "Missed call", "b", { type: "ride_call_end" }).message.android.ttl, "120s");
});

Deno.test("audiences: legacy names, approved partners, everyone by default", () => {
  assertEquals(resolveAudience("drivers"), "partners");
  assertEquals(resolveAudience(" Partners "), "partners");
  assertEquals(resolveAudience("active_partners"), "active_partners");
  assertEquals(resolveAudience("users"), "users");
  assertEquals(resolveAudience(undefined), "all");
  assertEquals(resolveAudience("nonsense"), "all");
});

Deno.test("recipients: the rider is never told about their own request", () => {
  const rows = [
    { token: "a", profile_id: "rider" },
    { token: "b", profile_id: "driver" },
    { token: "c", profile_id: null },
  ];
  const exclude = new Set(profileIdList(["rider", "", 7]));
  assertEquals(pickRecipients(rows, null, exclude).map((r) => r.token), ["b", "c"]);
  assertEquals(pickRecipients(rows, new Set(["rider", "driver"]), exclude).map((r) => r.token), ["b"]);
  assertEquals(pickRecipients(rows, new Set(["driver"]), new Set()).map((r) => r.token), ["b"]);
});

Deno.test("a whole table is read past the row cap", async () => {
  const table = Array.from({ length: 2500 }, (_, i) => i);
  const calls: [number, number][] = [];
  const { data, error } = await readAllPages<number>((from, to) => {
    calls.push([from, to]);
    return Promise.resolve({ data: table.slice(from, to + 1), error: null });
  });
  assertEquals(error, null);
  assertEquals(data.length, 2500);
  assertEquals(calls, [[0, 999], [1000, 1999], [2000, 2999]]);

  const failed = await readAllPages<number>((from) =>
    Promise.resolve(from === 0 ? { data: [1], error: null } : { data: null, error: { message: "x" } }), 1);
  assertEquals(failed.error?.message, "x");
});

Deno.test("mode: ride offers are driver business, the account's own news is not", () => {
  assertEquals(notificationMode("all", { type: "ride_request" }, true), "partner");
  assertEquals(notificationMode("partners", { type: "ride_request_fare_raised" }, false), "partner");
  assertEquals(notificationMode("all", { type: "ride_status" }, true), null);
  assertEquals(notificationMode("all", { type: "wallet_transfer_request" }, true), null);
  assertEquals(notificationMode("all", { type: "partner_status" }, true), null);
  assertEquals(notificationMode("partners", { audience: "partners" }, false), "partner");
  assertEquals(notificationMode("users", { audience: "users" }, false), "rider");
  assertEquals(notificationMode("all", { audience: "all" }, false), null);
  assertEquals(notificationMode("users", undefined, true), null);
});

Deno.test("mode: phones in the other mode are skipped, silent ones are not", () => {
  const rows = [
    { token: "d", mode: "partner" },
    { token: "p", mode: "rider" },
    { token: "old", mode: null },
    { token: "older" },
  ];
  assertEquals(inMode(rows, "partner").map((r) => r.token), ["d", "old", "older"]);
  assertEquals(inMode(rows, "rider").map((r) => r.token), ["p", "old", "older"]);
  assertEquals(inMode(rows, null).length, 4);
});

Deno.test("page rows: one per account, not for calls, offers or chat", () => {
  const rows = inboxRows(["a", "b", "a", ""], "Ride confirmed", "Pick up at X.", {
    type: "ride_status",
    request_id: "r1",
    event_id: "r1:accepted:r",
    attempt: 3,
  }, null);
  assertEquals(rows.map((r) => r.profile_id), ["a", "b"]);
  assertEquals(rows[0].data, { type: "ride_status", request_id: "r1", event_id: "r1:accepted:r" });
  assertEquals(rows[0].event_id, "r1:accepted:r");
  assertEquals(rows[0].kind, "ride_status");

  for (const type of ["ride_call", "ride_request", "ride_request_fare_raised", "ride_message"]) {
    assertEquals(inboxRows(["a"], "t", "b", { type }, null), []);
  }

  // A City to City reminder sent with the Notifications page off (0309).
  assertEquals(inboxRows(["a"], "t", "b", { type: "c2c_reminder", inbox: false }, null), []);
  assertEquals(inboxRows(["a"], "t", "b", { type: "c2c_reminder", inbox: true }, null)[0].data, { type: "c2c_reminder" });

  const broadcast = inboxRows(["a"], "Promo", "Hello", { audience: "users" }, "rider");
  assertEquals(broadcast[0].mode, "rider");
  assertEquals(broadcast[0].kind, null);
  assertEquals(broadcast[0].event_id, null);
});

Deno.test("area: a region needs a country; a radius must be on the globe and sane", () => {
  assertEquals(parseArea(null), null);
  assertEquals(parseArea({ state: "Selangor" }), null);
  assertEquals(parseArea({ country: " Malaysia ", state: "Selangor", city: "" }), {
    kind: "region",
    country: "Malaysia",
    state: "Selangor",
  });
  assertEquals(parseArea({ lat: 3.1, lng: 101.7, radiusKm: 5 }), { kind: "radius", lat: 3.1, lng: 101.7, radiusKm: 5 });
  assertEquals(parseArea({ lat: 3.1, lng: 101.7, radiusKm: 0 }), null);
  assertEquals(parseArea({ lat: 3.1, lng: 101.7, radiusKm: 900 }), null);
  assertEquals(parseArea({ lat: 99, lng: 101.7, radiusKm: 5 }), null);
});

Deno.test("area: who is inside", () => {
  const now = new Date("2026-10-13T08:00:00Z");
  const klcc = {
    last_lat: 3.1579,
    last_lng: 101.7116,
    area_country: "Malaysia",
    area_state: "Kuala Lumpur",
    area_city: "Kuala Lumpur",
    area_suburb: null,
    located_at: "2026-10-12T08:00:00Z",
  };
  const region = parseArea({ country: "malaysia", state: "KUALA LUMPUR " })!;
  assertEquals(inArea(klcc, region, now), true);
  assertEquals(inArea(klcc, parseArea({ country: "Malaysia", state: "Selangor" })!, now), false);
  assertEquals(inArea(klcc, parseArea({ country: "Malaysia", suburb: "Bangsar" })!, now), false);

  // ~5.6 km from KLCC to Mid Valley.
  const midValley = parseArea({ lat: 3.1186, lng: 101.6774, radiusKm: 6 })!;
  assertEquals(inArea(klcc, midValley, now), true);
  assertEquals(inArea(klcc, { ...midValley, radiusKm: 5 } as typeof midValley, now), false);

  // Unknown or stale places are left out.
  assertEquals(inArea({ ...klcc, located_at: null }, region, now), false);
  assertEquals(inArea({ ...klcc, located_at: "2026-08-01T00:00:00Z" }, region, now), false);
  assertEquals(inArea({ ...klcc, last_lat: null }, midValley, now), false);
});

Deno.test("distance: a known pair", () => {
  const km = distanceKm(3.1579, 101.7116, 3.1186, 101.6774);
  assertEquals(km > 5.5 && km < 5.9, true);
});
