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
  fcmMessage,
  fcmOutcome,
  fcmSendUrl,
  isExpoToken,
  parseServiceAccount,
  planDeliveries,
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
