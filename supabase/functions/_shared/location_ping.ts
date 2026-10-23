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
 *   POST { tokenIds: uuid[], reason?: "scheduled" | "manual" | "live" }  ->  { sent, failed, pruned }
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

/** At most this many tokens a call (location_ping_due claims 500 a run). */
export const MAX_TOKENS = 1000;

/** FCM sends at once, so a run of 500 does not open 500 connections. */
export const SEND_CONCURRENCY = 20;

export interface PingTarget {
  id?: string | null;
  token: string;
  platform?: string | null;
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

export interface LocationPingDeps {
  auth: PushAuthDeps;
  /** location_ping_targets: the claimed rows that may still be pinged. */
  targets(ids: string[]): Promise<PingTarget[]>;
  /** Sends one FCM message; "unregistered" when FCM says the token is gone. */
  send(message: LocationPingMessage): Promise<"sent" | "unregistered" | "failed">;
  prune(tokens: string[]): Promise<void>;
  now(): Date;
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

  let body: { tokenIds?: unknown; reason?: unknown };
  try {
    body = await req.json();
  } catch {
    return reply({ error: "Invalid JSON body" }, 400);
  }
  const ids = tokenIdsOf(body?.tokenIds);
  if (ids.length === 0) return reply({ error: "tokenIds is required" }, 400);

  const type = pingTypeOf(body?.reason);
  const targets = await deps.targets(ids);
  const now = deps.now();
  const seen = new Set<string>();
  const messages: LocationPingMessage[] = [];
  for (const t of targets) {
    if (seen.has(t.token)) continue;
    const m = locationPingMessage(t, now, type);
    if (!m) continue;
    seen.add(t.token);
    messages.push(m);
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
  return reply({ sent, failed, pruned: dead.length });
}
