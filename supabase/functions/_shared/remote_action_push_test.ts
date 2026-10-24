// location-ping's "Change status" push (0286, location_ping.ts): Edit
// Partner asks the partner's phone to go online / offline or link / unlink a
// vehicle. The same silent push as a ping, `{ type: "partner_remote_action",
// id, title, body }`, to the phones partner_remote_action_targets hands
// back; the request is marked sent once one phone's FCM took it.
//
//     deno test --allow-read=lib,supabase supabase/functions/_shared/remote_action_push_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import type { PushAuthDeps } from "./push_auth.ts";
import {
  actionIdOf,
  handleLocationPing,
  type LocationPingDeps,
  PARTNER_REMOTE_ACTION,
  type RemoteActionTarget,
  remoteActionMessage,
} from "./location_ping.ts";

const now = new Date("2026-10-24T07:12:00Z");
const ACTION = "44444444-4444-4444-8444-444444444444";

const target = (token: string, platform: string): RemoteActionTarget => ({
  token,
  platform,
  title: "Support asked you to go online",
  body: "Tap to confirm",
});

Deno.test("an iPhone: a background push with the request's id and words, no alert", () => {
  const m = remoteActionMessage(target("ios-1", "ios"), ACTION, now)!;
  assertEquals(m.message.data, {
    type: PARTNER_REMOTE_ACTION,
    id: ACTION,
    title: "Support asked you to go online",
    body: "Tap to confirm",
  });
  const apns = (m.message as { apns: { headers: Record<string, string>; payload: { aps: Record<string, unknown> } } }).apns;
  assertEquals(apns.headers["apns-push-type"], "background");
  assertEquals(apns.headers["apns-priority"], "5");
  assertEquals(apns.headers["apns-expiration"], String(Math.floor(now.getTime() / 1000) + 120));
  assertEquals(apns.payload, { aps: { "content-available": 1 } });
  assert(!("notification" in m.message), "data only");
});

Deno.test("Android: data only, high priority, two minutes to live", () => {
  const m = remoteActionMessage(target("and-1", "android"), ACTION, now)!;
  assertEquals((m.message as { android: Record<string, string> }).android, {
    priority: "HIGH",
    ttl: "120s",
    collapse_key: PARTNER_REMOTE_ACTION,
  });
  assert(!("notification" in m.message));
});

Deno.test("never a PushKit, Expo or web token; the words are one plain line", () => {
  assertEquals(remoteActionMessage(target("voip", "ios_voip"), ACTION, now), null);
  assertEquals(remoteActionMessage(target("ExponentPushToken[abc]", "android"), ACTION, now), null);
  assertEquals(remoteActionMessage(target("web", "web"), ACTION, now), null);
  const m = remoteActionMessage({ token: "and-1", platform: "android", title: " Two\nlines ", body: null }, ACTION, now)!;
  assertEquals(m.message.data.title, "Two lines");
  assertEquals(m.message.data.body, "Tap to confirm");
  assertEquals(actionIdOf(` ${ACTION.toUpperCase()} `), ACTION);
  assertEquals(actionIdOf("nope"), null);
});

const SECRET = "vault-secret";
const auth: PushAuthDeps = {
  serviceKeys: ["service-role-key"],
  webhookSecretOk: (s) => Promise.resolve(s === SECRET),
  callerCanPush: () => Promise.resolve(true),
};

function deps(log: string[], outcome: (t: string) => "sent" | "unregistered" | "failed" = () => "sent"): LocationPingDeps {
  return {
    auth,
    targets: () => {
      log.push("ping-targets");
      return Promise.resolve([]);
    },
    actionTargets: (id) => {
      log.push(`targets:${id}`);
      return Promise.resolve([target("ios-a", "ios"), target("and-b", "android"), target("and-b", "android")]);
    },
    actionSent: (id, n) => {
      log.push(`sent:${id}:${n}`);
      return Promise.resolve();
    },
    send: (m) => {
      log.push(`send:${m.message.token}:${m.message.data.type}`);
      return Promise.resolve(outcome(m.message.token));
    },
    prune: (t) => {
      log.push(`prune:${t.join(",")}`);
      return Promise.resolve();
    },
    now: () => now,
  };
}

const post = (body: unknown, headers: Record<string, string>) =>
  new Request("https://x/functions/v1/location-ping", { method: "POST", headers, body: JSON.stringify(body) });

Deno.test("the database's call sends to the partner's phones once each and marks it sent", async () => {
  const log: string[] = [];
  const res = await handleLocationPing(post({ actionId: ACTION, reason: "remote_action" }, { "x-push-secret": SECRET }), deps(log));
  assertEquals(await res.json(), { sent: 2, failed: 0, pruned: 0 });
  assertEquals(log.filter((l) => l.startsWith("send:")).sort(), [
    "send:and-b:partner_remote_action",
    "send:ios-a:partner_remote_action",
  ]);
  assertEquals(log[0], `targets:${ACTION}`);
  assertEquals(log.at(-1), `sent:${ACTION}:2`);
  assert(!log.includes("ping-targets"), "never the ping's targets");
});

Deno.test("nothing sent leaves it queued; a gone token is pruned", async () => {
  const log: string[] = [];
  const res = await handleLocationPing(
    post({ actionId: ACTION, reason: "remote_action" }, { "x-push-secret": SECRET }),
    deps(log, (t) => (t === "and-b" ? "unregistered" : "failed")),
  );
  assertEquals(await res.json(), { sent: 0, failed: 2, pruned: 1 });
  assert(!log.some((l) => l.startsWith("sent:")), "not marked sent");
  assert(log.includes("prune:and-b"));
});

Deno.test("only the database or the service role; a bad id sends nothing", async () => {
  const log: string[] = [];
  const body = { actionId: ACTION, reason: "remote_action" };
  assertEquals((await handleLocationPing(post(body, {}), deps(log))).status, 401);
  assertEquals((await handleLocationPing(post(body, { Authorization: "Bearer admin.jwt" }), deps(log))).status, 401);
  assertEquals(
    (await handleLocationPing(post({ actionId: "nope", reason: "remote_action" }, { "x-push-secret": SECRET }), deps(log))).status,
    400,
  );
  assertEquals(log, []);
});
