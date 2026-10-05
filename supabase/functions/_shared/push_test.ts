/**
 * What send-push decides before touching the network.
 *
 *     deno test supabase/functions/_shared/push_test.ts
 */
import { assertEquals } from "jsr:@std/assert@1.0.19";

import {
  ANDROID_CHANNEL_ID,
  fcmData,
  fcmMessage,
  fcmOutcome,
  fcmSendUrl,
  isExpoToken,
  parseServiceAccount,
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
