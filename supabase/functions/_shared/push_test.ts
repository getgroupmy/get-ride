/**
 * What send-push decides before touching the network.
 *
 *     deno test supabase/functions/_shared/push_test.ts
 */
import { assertEquals } from "jsr:@std/assert@1.0.19";

import {
  ANDROID_CHANNEL_ID,
  fcmCallMessage,
  fcmData,
  collapseIdFor,
  fcmMessage,
  fcmOutcome,
  fcmSendUrl,
  isExpoToken,
  parseServiceAccount,
  pickRecipients,
  planDeliveries,
  profileIdList,
  readAllPages,
  resolveAudience,
  splitTokens,
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
