/**
 * trip-card-push: keeps an Android phone's trip card moving while the app is
 * closed (migration 0274). The database calls it for a ride whose status
 * changed, and for the driver's position at most every 30 seconds; it
 * builds the card here (trip_card.ts) for the ride's rider and its driver
 * and sends each of their Android phones an FCM data message:
 *
 *   { type: "trip_card", ride_id, card: "<JSON of the card's keys>" }
 *   { type: "trip_card", ride_id, end: "1" }
 *
 * Data only (no `notification` block) and high priority, so Android wakes
 * the app's TripCardPushReceiver even when its process is dead; it moves the
 * card the app started (and does nothing while the app is on screen, where
 * the app keeps its card itself).
 *
 * As the app does (lib/src/data/trip_card_controller.dart):
 *   * Admin -> Display Settings -> Trip card's switches: a service switched
 *     off, or drivers' cards switched off, ends the card;
 *   * the done card stays its minutes after the trip ended, then goes
 *     (0 ends it at once); a cancelled or expired ride's card ends at once;
 *   * the rider's phones in passenger mode, the driver's in driver mode
 *     (push_tokens.mode; a phone that never said gets both);
 *   * never the trip code or a courier's delivery code: the snapshot the
 *     database hands over has neither.
 *
 * Callers: the database (`x-push-secret`, the push webhook's Vault secret)
 * or the service role. Nobody else.
 *
 *     deno test supabase/functions/_shared/trip_card_push_test.ts
 */
import { authorizePush, type PushAuthDeps } from "./push_auth.ts";
import { inMode, isExpoToken } from "./push.ts";
import {
  allows,
  serviceOf,
  stageOf,
  tripCardFor,
  type TripCardKeys,
  tripCardSettings,
  type TripRide,
} from "./trip_card.ts";

export const TRIP_CARD_PUSH = "trip_card";

/** What trip_card_push_snapshot answers: the ride and the admin's switches. */
export interface TripCardSnapshot {
  ride: TripRide | null;
  /** admin_display_settings.settings.tripCard */
  settings?: unknown;
}

export interface TokenRow {
  token: string;
  platform?: string | null;
  profile_id?: string | null;
  mode?: string | null;
}

export interface TripCardPushBody {
  rideId?: unknown;
  /** The driver who had the ride before it was reopened or handed over: their card ends. */
  formerPartnerId?: unknown;
}

export interface TripCardDelivery {
  token: string;
  role: "rider" | "driver";
  data: Record<string, string>;
  ttl: string;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function uuidOf(v: unknown): string | null {
  return typeof v === "string" && UUID.test(v.trim()) ? v.trim().toLowerCase() : null;
}

/** A move within a stage is worth little a minute later; an end or a done card is worth delivering late. */
export const MOVE_TTL = "60s";
export const END_TTL = "3600s";

/**
 * What one person's phones are sent for [ride] at [now]: the card, or an
 * end. Null when there is nothing to tell them.
 */
export function cardMessage(
  ride: TripRide,
  asDriver: boolean,
  settingsRaw: unknown,
  now: Date,
): { data: Record<string, string>; ttl: string } | null {
  const end = { data: { type: TRIP_CARD_PUSH, ride_id: ride.id, end: "1" }, ttl: END_TTL };
  const settings = tripCardSettings(settingsRaw);
  if (!allows(settings, serviceOf(ride), asDriver)) return end;
  const stage = stageOf(ride.status);
  if (stage === null) return end;
  const card = tripCardFor(ride, asDriver, now);
  if (card === null) return asDriver ? null : end;
  const doneMs = settings.doneMinutes * 60000;
  let clearAfterMs = doneMs;
  if (stage === "done") {
    const ended = Date.parse(ride.completed_at ?? "");
    const from = Number.isNaN(ended) ? now.getTime() : ended;
    clearAfterMs = from + doneMs - now.getTime();
    if (settings.doneMinutes === 0 || clearAfterMs <= 0) return end;
  }
  const keys: TripCardKeys & { clearAfterMs: number; pushedAtMs: number } = {
    ...card,
    clearAfterMs,
    // The receiver drops a push older than the one it last applied (FCM
    // does not promise order).
    pushedAtMs: now.getTime(),
  };
  return {
    data: { type: TRIP_CARD_PUSH, ride_id: ride.id, card: JSON.stringify(keys) },
    ttl: stage === "done" ? END_TTL : MOVE_TTL,
  };
}

/** The Android phones of [profileId] in [mode] (a phone that never said is in both). */
export function androidTokens(rows: TokenRow[], profileId: string, mode: "rider" | "partner"): string[] {
  const mine = rows.filter((r) =>
    r.profile_id === profileId && r.platform === "android" && typeof r.token === "string" && r.token !== "" &&
    !isExpoToken(r.token)
  );
  return inMode(mine, mode).map((r) => r.token);
}

/** Every message to send for one call: the rider's, the driver's, a former driver's end. */
export function planTripCardPushes(
  snapshot: TripCardSnapshot,
  tokens: TokenRow[],
  now: Date,
  formerPartnerId: string | null = null,
): TripCardDelivery[] {
  const ride = snapshot.ride;
  if (!ride?.id) return [];
  const out: TripCardDelivery[] = [];
  const seen = new Set<string>();
  const add = (role: "rider" | "driver", list: string[], msg: { data: Record<string, string>; ttl: string } | null) => {
    if (!msg) return;
    for (const token of list) {
      if (seen.has(token)) continue;
      seen.add(token);
      out.push({ token, role, data: msg.data, ttl: msg.ttl });
    }
  };
  const rider = uuidOf(ride.rider_id);
  const partner = uuidOf(ride.partner_id);
  const status = ride.status ?? "open";
  if (rider) add("rider", androidTokens(tokens, rider, "rider"), cardMessage(ride, false, snapshot.settings, now));
  // An open request's partner is at most a bidder, who has no card for it.
  if (partner && partner !== rider && status !== "open") {
    add("driver", androidTokens(tokens, partner, "partner"), cardMessage(ride, true, snapshot.settings, now));
  }
  const former = uuidOf(formerPartnerId);
  if (former && former !== partner && former !== rider) {
    add("driver", androidTokens(tokens, former, "partner"), {
      data: { type: TRIP_CARD_PUSH, ride_id: ride.id, end: "1" },
      ttl: END_TTL,
    });
  }
  return out;
}

/**
 * The FCM v1 message: data only, so the OS shows nothing itself and the
 * app's receiver runs even with its process dead; high priority, so it is
 * delivered at once (Doze included); one collapse key per ride, so a phone
 * that was offline gets only the newest.
 */
export function tripCardFcmMessage(d: TripCardDelivery) {
  return {
    message: {
      token: d.token,
      data: d.data,
      android: {
        priority: "HIGH",
        ttl: d.ttl,
        collapse_key: `trip_card_${d.data.ride_id}`.slice(0, 64),
      },
    },
  };
}

// ---- The request ------------------------------------------------------------

export interface TripCardPushDeps {
  auth: PushAuthDeps;
  snapshot(rideId: string): Promise<TripCardSnapshot | null>;
  tokens(profileIds: string[]): Promise<TokenRow[]>;
  /** Sends one FCM message; "unregistered" when FCM says the token is gone. */
  send(message: ReturnType<typeof tripCardFcmMessage>): Promise<"sent" | "unregistered" | "failed">;
  prune(tokens: string[]): Promise<void>;
  now(): Date;
}

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

export async function handleTripCardPush(req: Request, deps: TripCardPushDeps): Promise<Response> {
  if (req.method !== "POST") return reply({ error: "POST only" }, 405);
  // The database's secret or the service role; an admin's token is no use here.
  const auth = await authorizePush(req, { ...deps.auth, callerCanPush: () => Promise.resolve(null) });
  if (!auth.ok) return reply({ error: auth.error }, auth.status);

  let body: TripCardPushBody;
  try {
    body = await req.json();
  } catch {
    return reply({ error: "Invalid JSON body" }, 400);
  }
  const rideId = uuidOf(body?.rideId);
  if (!rideId) return reply({ error: "rideId is required" }, 400);

  const snapshot = await deps.snapshot(rideId);
  if (!snapshot?.ride) return reply({ sent: 0, failed: 0, reason: "no such ride" });
  const former = uuidOf(body.formerPartnerId);
  const people = [snapshot.ride.rider_id, snapshot.ride.partner_id, former]
    .map(uuidOf)
    .filter((v): v is string => v !== null);
  if (people.length === 0) return reply({ sent: 0, failed: 0 });
  const tokens = await deps.tokens([...new Set(people)]);
  const deliveries = planTripCardPushes(snapshot, tokens, deps.now(), former);

  let sent = 0, failed = 0;
  const dead: string[] = [];
  await Promise.all(deliveries.map(async (d) => {
    try {
      const outcome = await deps.send(tripCardFcmMessage(d));
      if (outcome === "sent") {
        sent += 1;
      } else {
        failed += 1;
        if (outcome === "unregistered") dead.push(d.token);
      }
    } catch {
      failed += 1;
    }
  }));
  if (dead.length > 0) await deps.prune(dead);
  return reply({ sent, failed, pruned: dead.length });
}
