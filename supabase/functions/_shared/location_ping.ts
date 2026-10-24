/**
 * location-ping: "Still there?" (migration 0276). Sends a silent push to
 * "Always on" phones whose last report is getting old, or to one person's
 * phones from God View's "Ping now"; the app's native code answers it with
 * one location fix through push_background_location (the install's
 * background key), with the app closed and no Flutter engine:
 *
 *   * iPhone: a background push (`apns-push-type: background`, priority 5,
 *     `content-available: 1`, no alert), handled in AppDelegate.swift's
 *     didReceiveRemoteNotification;
 *   * Android: a data-only, high-priority FCM message, handled by
 *     LocationPingReceiver.kt.
 *
 * Both carry `{ type: "location_ping" }` and nothing else. The phone answers
 * with its details too (battery, network, app; push_background_details,
 * migration 0282). God View's "Live now" (reason "live", 0282) sends
 * `{ type: "location_live" }` the same way, with a shorter life: the phone
 * answers it as a ping, then sends its position every 5 seconds
 * (push_live_location) until the share ends.
 *
 * Edit Partner's "Change status" (0286, reason "remote_action") sends
 * `{ type: "partner_remote_action", id, title, body }` the same way to the
 * partner's phones (partner_remote_action_targets): the open app runs the
 * request through the driver's own code; a closed one shows title / body
 * ("Support asked you to go online", "Tap to confirm") natively
 * (PartnerRemoteActionReceiver.kt, AppDelegate.swift). Once one phone has
 * it, partner_remote_action_sent marks the request sent.
 *
 *   POST { tokenIds: uuid[], reason?: "scheduled" | "manual" | "live" }  ->  { sent, failed, pruned }
 *   POST { actionId: uuid, reason: "remote_action" }                       ->  { sent, failed, pruned }
 *
 * The database decides who is due and claims the rows (location_ping_due,
 * god_view_ping: the admin's minutes, the 2-minute limit, God View's access
 * rule and the audit log); this only sends to the rows
 * location_ping_targets hands back, which re-checks them (key, location
 * always, FCM token, live account, claimed in the last 10 minutes).
 *
 * Callers: the database (`x-push-secret`, the push webhook's Vault secret)
 * or the service role. Never an admin's token: "Ping now" goes through
 * god_view_ping.
 *
 *     deno test --allow-read=lib,supabase supabase/functions/_shared/location_ping_test.ts
 */
import { authorizePush, type PushAuthDeps } from "./push_auth.ts";
import { isExpoToken } from "./push.ts";

export const LOCATION_PING = "location_ping";

/** "Live now" (0282): stream the position until the share ends. */
export const LOCATION_LIVE = "location_live";

/** A ping older than this is worth nothing: the next one is on its way. */
export const PING_TTL_SECONDS = 300;

/** A live share that has not started in a minute is shown as not answered. */
export const LIVE_TTL_SECONDS = 60;

/** Edit Partner's "Change status" (0286): ask the partner's phone. */
export const PARTNER_REMOTE_ACTION = "partner_remote_action";

/** A request expires in 2 minutes; the push is worth nothing after. */
export const REMOTE_ACTION_TTL_SECONDS = 120;

/** At most this many tokens a call (location_ping_due claims 500 a run). */
export const MAX_TOKENS = 1000;

/** FCM sends at once, so a run of 500 does not open 500 connections. */
export const SEND_CONCURRENCY = 20;

export interface PingTarget {
  id?: string | null;
  token: string;
  platform?: string | null;
}

/** A phone of the partner a "Change status" request is for, with what its notification says. */
export interface RemoteActionTarget extends PingTarget {
  title?: string | null;
  body?: string | null;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The body's token ids: distinct uuids, at most [MAX_TOKENS]. */
export function tokenIdsOf(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const out = new Set<string>();
  for (const v of raw) {
    if (typeof v === "string" && UUID.test(v.trim())) out.add(v.trim().toLowerCase());
    if (out.size >= MAX_TOKENS) break;
  }
  return [...out];
}

/** The push type for the body's reason: a live share, else a ping. */
export function pingTypeOf(reason: unknown): typeof LOCATION_PING | typeof LOCATION_LIVE {
  return reason === "live" ? LOCATION_LIVE : LOCATION_PING;
}

/** The FCM v1 message for one phone; null for a token FCM cannot reach this way. */
export function locationPingMessage(
  t: PingTarget,
  now: Date,
  type: typeof LOCATION_PING | typeof LOCATION_LIVE = LOCATION_PING,
) {
  if (typeof t.token !== "string" || t.token === "" || isExpoToken(t.token)) return null;
  const data = { type };
  const ttl = type === LOCATION_LIVE ? LIVE_TTL_SECONDS : PING_TTL_SECONDS;
  if (t.platform === "ios") {
    return {
      message: {
        token: t.token,
        data,
        apns: {
          headers: {
            "apns-push-type": "background",
            // Background pushes must be priority 5; iOS rations them.
            "apns-priority": "5",
            "apns-expiration": String(Math.floor(now.getTime() / 1000) + ttl),
            "apns-collapse-id": type,
          },
          payload: { aps: { "content-available": 1 } },
        },
      },
    };
  }
  if (t.platform === "android") {
    return {
      message: {
        token: t.token,
        data,
        android: { priority: "HIGH", ttl: `${ttl}s`, collapse_key: type },
      },
    };
  }
  return null;
}

export type LocationPingMessage = NonNullable<ReturnType<typeof locationPingMessage>>;

/** The body's request id (0286), or null. */
export function actionIdOf(raw: unknown): string | null {
  return typeof raw === "string" && UUID.test(raw.trim()) ? raw.trim().toLowerCase() : null;
}

/** Plain one-line text for a data field, at most [max] characters. */
function line(v: unknown, fallback: string, max = 120): string {
  const s = typeof v === "string" ? v.replace(/\s+/g, " ").trim() : "";
  return (s || fallback).slice(0, max);
}

/**
 * The FCM v1 message asking one phone to run a "Change status" request:
 * data only, as a ping (an iPhone a background push, Android high priority),
 * with the request's id and the words the phone shows if it must ask the
 * driver. Null for a token FCM cannot reach this way.
 */
export function remoteActionMessage(t: RemoteActionTarget, actionId: string, now: Date) {
  if (typeof t.token !== "string" || t.token === "" || isExpoToken(t.token)) return null;
  const data = {
    type: PARTNER_REMOTE_ACTION,
    id: actionId,
    title: line(t.title, "Support sent you a request"),
    body: line(t.body, "Tap to confirm"),
  };
  if (t.platform === "ios") {
    return {
      message: {
        token: t.token,
        data,
        apns: {
          headers: {
            "apns-push-type": "background",
            "apns-priority": "5",
            "apns-expiration": String(Math.floor(now.getTime() / 1000) + REMOTE_ACTION_TTL_SECONDS),
            "apns-collapse-id": PARTNER_REMOTE_ACTION,
          },
          payload: { aps: { "content-available": 1 } },
        },
      },
    };
  }
  if (t.platform === "android") {
    return {
      message: {
        token: t.token,
        data,
        android: { priority: "HIGH", ttl: `${REMOTE_ACTION_TTL_SECONDS}s`, collapse_key: PARTNER_REMOTE_ACTION },
      },
    };
  }
  return null;
}

export type RemoteActionMessage = NonNullable<ReturnType<typeof remoteActionMessage>>;

export interface LocationPingDeps {
  auth: PushAuthDeps;
  /** location_ping_targets: the claimed rows that may still be pinged. */
  targets(ids: string[]): Promise<PingTarget[]>;
  /** Sends one FCM message; "unregistered" when FCM says the token is gone. */
  send(message: LocationPingMessage | RemoteActionMessage): Promise<"sent" | "unregistered" | "failed">;
  prune(tokens: string[]): Promise<void>;
  now(): Date;
  /** partner_remote_action_targets (0286): the phones of an open request. */
  actionTargets?(actionId: string): Promise<RemoteActionTarget[]>;
  /** partner_remote_action_sent (0286): the push reached [sent] phones' FCM. */
  actionSent?(actionId: string, sent: number): Promise<void>;
}

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

/** Runs [work] over [items], [limit] at a time. */
export async function eachLimited<T>(items: T[], limit: number, work: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  const lanes = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
    while (next < items.length) {
      const item = items[next];
      next += 1;
      await work(item);
    }
  });
  await Promise.all(lanes);
}

export async function handleLocationPing(req: Request, deps: LocationPingDeps): Promise<Response> {
  if (req.method !== "POST") return reply({ error: "POST only" }, 405);
  // The database's secret or the service role; an admin's token is no use here.
  const auth = await authorizePush(req, { ...deps.auth, callerCanPush: () => Promise.resolve(null) });
  if (!auth.ok) return reply({ error: auth.error }, auth.status);

  let body: { tokenIds?: unknown; reason?: unknown; actionId?: unknown };
  try {
    body = await req.json();
  } catch {
    return reply({ error: "Invalid JSON body" }, 400);
  }
  const now = deps.now();
  const seen = new Set<string>();
  const messages: Array<LocationPingMessage | RemoteActionMessage> = [];
  let actionId: string | null = null;
  if (body?.reason === "remote_action") {
    actionId = actionIdOf(body?.actionId);
    if (!actionId || !deps.actionTargets) return reply({ error: "actionId is required" }, 400);
    for (const t of await deps.actionTargets(actionId)) {
      if (seen.has(t.token)) continue;
      const m = remoteActionMessage(t, actionId, now);
      if (!m) continue;
      seen.add(t.token);
      messages.push(m);
    }
  } else {
    const ids = tokenIdsOf(body?.tokenIds);
    if (ids.length === 0) return reply({ error: "tokenIds is required" }, 400);
    const type = pingTypeOf(body?.reason);
    for (const t of await deps.targets(ids)) {
      if (seen.has(t.token)) continue;
      const m = locationPingMessage(t, now, type);
      if (!m) continue;
      seen.add(t.token);
      messages.push(m);
    }
  }

  let sent = 0, failed = 0;
  const dead: string[] = [];
  await eachLimited(messages, SEND_CONCURRENCY, async (m) => {
    try {
      const outcome = await deps.send(m);
      if (outcome === "sent") {
        sent += 1;
      } else {
        failed += 1;
        if (outcome === "unregistered") dead.push(m.message.token);
      }
    } catch {
      failed += 1;
    }
  });
  if (dead.length > 0) await deps.prune(dead);
  if (actionId && sent > 0 && deps.actionSent) await deps.actionSent(actionId, sent);
  return reply({ sent, failed, pruned: dead.length });
}
