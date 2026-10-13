/**
 * What send-push decides before touching the network.
 *
 * `push_tokens` holds two kinds of device token:
 *
 *   * Expo push tokens (`ExponentPushToken[...]`), from the Expo app, sent
 *     through Expo's push service;
 *   * Firebase Cloud Messaging registration tokens, from the Flutter app,
 *     sent through the FCM HTTP v1 API. FCM delivers to Android directly and
 *     to iOS through the APNs key uploaded to the Firebase project.
 *
 * Pure, so it is tested in push_test.ts.
 */

export const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

/** The Android notification channel both apps create (high importance). */
export const ANDROID_CHANNEL_ID = "default";

export function isExpoToken(token: string): boolean {
  return token.startsWith("ExponentPushToken[") || token.startsWith("ExpoPushToken[");
}

/**
 * Splits the stored tokens by the service that delivers them, dropping
 * blanks and duplicates.
 */
export function splitTokens(tokens: unknown[]): { expo: string[]; fcm: string[] } {
  const expo = new Set<string>();
  const fcm = new Set<string>();
  for (const raw of tokens) {
    if (typeof raw !== "string") continue;
    const token = raw.trim();
    if (!token) continue;
    (isExpoToken(token) ? expo : fcm).add(token);
  }
  return { expo: [...expo], fcm: [...fcm] };
}

/**
 * FCM data payloads are string-to-string maps; anything else is refused with
 * INVALID_ARGUMENT for the whole message. Objects are sent as JSON and null
 * values are left out.
 */
export function fcmData(data: Record<string, unknown> | undefined | null): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(data ?? {})) {
    if (value === null || value === undefined) continue;
    out[key] = typeof value === "string" ? value : JSON.stringify(value);
  }
  return out;
}

export interface ServiceAccountJson {
  project_id?: string;
  client_email?: string;
  private_key?: string;
  token_uri?: string;
}

/**
 * Reads the FCM_SERVICE_ACCOUNT secret. Answers null rather than throwing
 * when it is missing or unusable, so a broadcast still reaches Expo devices.
 */
export function parseServiceAccount(raw: string | undefined | null): ServiceAccountJson | null {
  if (!raw || !raw.trim()) return null;
  try {
    const sa = JSON.parse(raw) as ServiceAccountJson;
    if (!sa?.project_id || !sa.client_email || !sa.private_key) return null;
    return sa;
  } catch {
    return null;
  }
}

export function fcmSendUrl(projectId: string): string {
  return `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/messages:send`;
}

/** One FCM v1 message: shown by the OS, loud on both platforms. */
export function fcmMessage(
  token: string,
  title: string,
  body: string,
  data: Record<string, unknown> | undefined | null,
) {
  // A retried event (notification_outbox, migration 0144) carries its
  // event id: it becomes the Android tag and the iOS collapse id, so the
  // retry replaces the notification already on screen instead of stacking.
  const collapse = collapseIdFor(data);
  return {
    message: {
      token,
      notification: { title, body },
      data: fcmData(data),
      android: {
        priority: "HIGH",
        notification: {
          channel_id: ANDROID_CHANNEL_ID,
          sound: "default",
          ...(collapse ? { tag: collapse } : {}),
        },
      },
      apns: {
        headers: { "apns-priority": "10", ...(collapse ? { "apns-collapse-id": collapse } : {}) },
        payload: { aps: { sound: "default" } },
      },
    },
  };
}

/**
 * The collapse id for a push that carries an `event_id`: at most 64 bytes,
 * as APNs allows. Null for a push without one.
 */
export function collapseIdFor(data: Record<string, unknown> | undefined | null): string | null {
  const id = data?.["event_id"];
  if (typeof id !== "string" || id.trim() === "") return null;
  return id.trim().slice(0, 64);
}

export type FcmOutcome = "sent" | "unregistered" | "failed";

/**
 * What one FCM response means for the token it was sent to.
 *
 * Only a token FCM says is gone is pruned: UNREGISTERED (the app was
 * uninstalled or the token rotated), or INVALID_ARGUMENT about the token
 * itself. Anything else — quota, a server error, bad credentials — is a
 * failed send and the token is kept for next time.
 */
export function fcmOutcome(status: number, body: unknown): FcmOutcome {
  if (status >= 200 && status < 300) return "sent";
  const error = (body as { error?: { status?: string; message?: string; details?: unknown[] } })?.error;
  const codes = (error?.details ?? [])
    .map((d) => (d as { errorCode?: string })?.errorCode)
    .filter((c): c is string => typeof c === "string");
  if (codes.includes("UNREGISTERED") || status === 404) return "unregistered";
  if (
    (codes.includes("INVALID_ARGUMENT") || error?.status === "INVALID_ARGUMENT") &&
    /registration token/i.test(error?.message ?? "")
  ) {
    return "unregistered";
  }
  return "failed";
}

// ---- Calls that ring like a phone call -------------------------------------
//
// A ride call (migration 0131) should ring even when the app is closed. Two
// things make that possible, both decided per device here:
//
//   * on Android, a build that can show the native incoming-call screen
//     (it registers its token with the `call_ui` capability, migration 0134)
//     is sent a data-only, high-priority message instead of a notification:
//     the app wakes and rings. A build from before can't, so it keeps the
//     ordinary "… is calling" notification;
//   * on an iPhone, only a PushKit (VoIP) push straight to Apple can open
//     the CallKit call screen of a closed app. The app stores that token
//     with the platform `ios_voip`; it is sent nothing but ride calls, and
//     only when the APNs key is configured (apns.ts) — Apple stops waking an
//     app that is sent VoIP pushes it doesn't report as calls.

/** `push_tokens.platform` of an iPhone's PushKit (VoIP) token. */
export const VOIP_PLATFORM = "ios_voip";

/** The capability a build registers when it shows a native call screen. */
export const CALL_UI_CAPABILITY = "call_ui";

/** A new ride call, and a ride call that stopped ringing unanswered. */
export const RIDE_CALL = "ride_call";
export const RIDE_CALL_END = "ride_call_end";

/** One `push_tokens` row as send-push reads it. */
export interface DeviceRow {
  token: string;
  platform?: string | null;
  profile_id?: string | null;
  capabilities?: string[] | null;
  /** The mode the phone is in (migration 0166); null when it never said. */
  mode?: string | null;
}

export type Delivery =
  | { via: "expo"; token: string }
  | { via: "fcm"; token: string; style: "alert" | "call" }
  | { via: "voip"; token: string };

/**
 * How each device is sent one push of [kind] (`data.type`). [voipReady] is
 * whether the APNs key is configured.
 *
 *   * a VoIP token gets ride calls only, and only when [voipReady];
 *   * an Android build with the call screen gets ride calls and their end
 *     as a data message, so it rings (or stops ringing) itself;
 *   * an iPhone whose account has a VoIP token is not also sent the "is
 *     calling" notification while [voipReady]: CallKit is already ringing;
 *   * everything else is an ordinary notification, as before.
 */
export function planDeliveries(rows: DeviceRow[], kind: unknown, voipReady: boolean): Delivery[] {
  const seen = new Set<string>();
  const unique: DeviceRow[] = [];
  for (const row of rows) {
    const token = typeof row?.token === "string" ? row.token.trim() : "";
    if (!token || seen.has(token)) continue;
    seen.add(token);
    unique.push({ ...row, token });
  }
  const ringsByVoip = new Set(
    unique
      .filter((r) => r.platform === VOIP_PLATFORM && r.profile_id)
      .map((r) => r.profile_id as string),
  );
  const isCall = kind === RIDE_CALL || kind === RIDE_CALL_END;

  const out: Delivery[] = [];
  for (const row of unique) {
    const { token } = row;
    if (row.platform === VOIP_PLATFORM) {
      if (kind === RIDE_CALL && voipReady) out.push({ via: "voip", token });
      continue;
    }
    if (isExpoToken(token)) {
      out.push({ via: "expo", token });
      continue;
    }
    const callUi = (row.capabilities ?? []).includes(CALL_UI_CAPABILITY);
    if (isCall && callUi && row.platform === "android") {
      out.push({ via: "fcm", token, style: "call" });
      continue;
    }
    if (kind === RIDE_CALL && voipReady && row.platform === "ios" && row.profile_id && ringsByVoip.has(row.profile_id)) {
      continue;
    }
    out.push({ via: "fcm", token, style: "alert" });
  }
  return out;
}

/**
 * The Android call push: data only (no notification for the OS to show, so
 * the app's own handler runs and rings), high priority, and short-lived — a
 * call that rang out is not worth delivering late. The title and body ride
 * in the data, where the handler reads the caller's name.
 */
export function fcmCallMessage(
  token: string,
  title: string,
  body: string,
  data: Record<string, unknown> | undefined | null,
) {
  const kind = (data ?? {}).type;
  return {
    message: {
      token,
      data: fcmData({ ...(data ?? {}), title, body }),
      android: {
        priority: "HIGH",
        ttl: kind === RIDE_CALL ? "45s" : "120s",
      },
    },
  };
}

// ---- Who a broadcast reaches ----------------------------------------------

/**
 * A broadcast's audience. `partners` is every partner account (Admin → Push
 * Notification); `active_partners` only the approved ones, the drivers a new
 * ride request can actually be taken by. "drivers" is the legacy name for
 * `partners`; anything unknown is everyone.
 */
export type Audience = "all" | "users" | "partners" | "active_partners";

export function resolveAudience(raw: unknown): Audience {
  const v = typeof raw === "string" ? raw.trim().toLowerCase() : "";
  if (v === "partners" || v === "drivers") return "partners";
  if (v === "active_partners") return "active_partners";
  if (v === "users") return "users";
  return "all";
}

/** The profile ids in [raw] (`excludeProfileIds`), cleaned. */
export function profileIdList(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  return Array.from(new Set(raw.filter((v): v is string => typeof v === "string" && v.trim() !== "").map((v) => v.trim())));
}

/**
 * The device rows a send goes to: those of [only] when it is set (a
 * targeted send or a partner audience), never those of [exclude] (the rider
 * a ride request is about, who may be a partner too).
 */
export function pickRecipients<T extends { profile_id?: string | null }>(
  rows: T[],
  only: Set<string> | null,
  exclude: Set<string>,
): T[] {
  return rows.filter((r) => {
    const id = r.profile_id ?? null;
    if (id !== null && exclude.has(id)) return false;
    return only === null || (id !== null && only.has(id));
  });
}

/** Rows per request when reading a whole table (PostgREST caps a read at 1000). */
export const READ_PAGE = 1000;

/**
 * Every row [page] has to give, a page at a time: without this a read stops
 * at the API's row cap and a broadcast silently misses everyone past it.
 */
export async function readAllPages<T>(
  page: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message?: string } | null }>,
  size = READ_PAGE,
): Promise<{ data: T[]; error: { message?: string } | null }> {
  const out: T[] = [];
  for (let from = 0; ; from += size) {
    const { data, error } = await page(from, from + size - 1);
    if (error) return { data: out, error };
    const rows = data ?? [];
    out.push(...rows);
    if (rows.length < size) return { data: out, error: null };
  }
}

// ---- Which mode a notification belongs to ----------------------------------

/** The two modes a phone can be in (push_tokens.mode, migration 0166). */
export type AppMode = "rider" | "partner";

/** Ride offers for drivers: only a phone in driver mode is told. */
const PARTNER_TYPES = new Set(["ride_request", "ride_request_fare_raised"]);

/**
 * The mode a notification belongs to, or null when it belongs to the account
 * whatever mode its phone is in. New ride requests and broadcasts to
 * partners are driver-mode business, broadcasts to users passenger-mode
 * business. Everything about the account's own rides, coins and approvals
 * returns null: it is theirs in either mode.
 */
export function notificationMode(
  audience: Audience,
  data: Record<string, unknown> | undefined | null,
  targeted: boolean,
): AppMode | null {
  const type = typeof data?.type === "string" ? data.type : null;
  if (type !== null && PARTNER_TYPES.has(type)) return "partner";
  if (type !== null || targeted) return null;
  if (audience === "partners" || audience === "active_partners") return "partner";
  if (audience === "users") return "rider";
  return null;
}

/**
 * Drops the phones in the other mode. A phone that has never said (an
 * older build) is told everything, as before.
 */
export function inMode<T extends { mode?: string | null }>(rows: T[], mode: AppMode | null): T[] {
  if (mode === null) return rows;
  return rows.filter((r) => r.mode !== (mode === "partner" ? "rider" : "partner"));
}

// ---- The notifications page (user_notifications, migration 0167) ---------

/**
 * Not kept on the page: a ringing call, a ride offer and a chat message
 * each have a screen of their own and are stale within minutes.
 */
const NOT_KEPT = new Set(["ride_call", "ride_request", "ride_request_fare_raised", "ride_message"]);

export interface InboxRow {
  profile_id: string;
  title: string;
  body: string;
  data: Record<string, unknown>;
  kind: string | null;
  mode: AppMode | null;
  event_id: string | null;
}

/**
 * The page rows for one send: one per recipient account, or none for the
 * kinds that are not kept. The retry counter of an outbox event is left
 * out, so a retry stores the same row (and the event id keeps it once).
 */
export function inboxRows(
  profileIds: Iterable<string>,
  title: string,
  body: string,
  data: Record<string, unknown> | undefined | null,
  mode: AppMode | null,
): InboxRow[] {
  const kind = typeof data?.type === "string" ? data.type : null;
  if (kind !== null && NOT_KEPT.has(kind)) return [];
  const { attempt: _attempt, ...kept } = data ?? {};
  const event = typeof kept.event_id === "string" && kept.event_id.trim() !== "" ? kept.event_id.trim() : null;
  return Array.from(new Set(profileIds))
    .filter((id) => typeof id === "string" && id !== "")
    .map((profile_id) => ({ profile_id, title, body, data: kept, kind, mode, event_id: event }));
}

// ---- Who is in an area (Admin -> Push Notification, migration 0168) -------

/**
 * Where a broadcast goes: the people in a region (country, then optionally
 * state, city, suburb), or within [radiusKm] of a point.
 */
export type PushArea =
  | { kind: "region"; country: string; state?: string; city?: string; suburb?: string }
  | { kind: "radius"; lat: number; lng: number; radiusKm: number };

/** A phone's last known place (push_tokens, migration 0168). */
export interface LocatedRow {
  last_lat?: number | null;
  last_lng?: number | null;
  area_country?: string | null;
  area_state?: string | null;
  area_city?: string | null;
  area_suburb?: string | null;
  located_at?: string | null;
}

/** The push_tokens columns [inArea] reads. */
export const LOCATED_COLUMNS = "last_lat, last_lng, area_country, area_state, area_city, area_suburb, located_at";

/** A place older than this is not where the phone is any more. */
export const AREA_MAX_AGE_DAYS = 30;

/** The largest radius an area broadcast may use. */
export const AREA_MAX_RADIUS_KM = 500;

const text = (v: unknown) => (typeof v === "string" ? v.trim() : "");
const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);

/**
 * The area in a request body, or null when there is none or it is not
 * usable (no country; a radius out of range or off the globe).
 */
export function parseArea(raw: unknown): PushArea | null {
  if (!raw || typeof raw !== "object") return null;
  const a = raw as Record<string, unknown>;
  const lat = num(a.lat), lng = num(a.lng), radius = num(a.radiusKm);
  if (lat !== null && lng !== null && radius !== null) {
    if (Math.abs(lat) > 90 || Math.abs(lng) > 180 || radius <= 0 || radius > AREA_MAX_RADIUS_KM) return null;
    return { kind: "radius", lat, lng, radiusKm: radius };
  }
  const country = text(a.country);
  if (!country) return null;
  const area: PushArea = { kind: "region", country };
  for (const k of ["state", "city", "suburb"] as const) {
    const v = text(a[k]);
    if (v) area[k] = v;
  }
  return area;
}

/** Great-circle distance in km. Pure. */
export function distanceKm(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const r = (d: number) => (d * Math.PI) / 180;
  const dLat = r(lat2 - lat1), dLng = r(lng2 - lng1);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(r(lat1)) * Math.cos(r(lat2)) * Math.sin(dLng / 2) ** 2;
  return 6371 * 2 * Math.asin(Math.min(1, Math.sqrt(h)));
}

const same = (a: unknown, b: string) => text(a).toLowerCase() === b.trim().toLowerCase();

/**
 * Whether the phone in [row] is in [area]: its place is known, no older than
 * [AREA_MAX_AGE_DAYS], and inside the radius or carrying every name the
 * region names (case and surrounding space ignored, as the app matches
 * region names).
 */
export function inArea(row: LocatedRow, area: PushArea, now: Date): boolean {
  const at = row.located_at ? Date.parse(row.located_at) : NaN;
  if (!Number.isFinite(at) || now.getTime() - at > AREA_MAX_AGE_DAYS * 86_400_000) return false;
  if (area.kind === "radius") {
    const lat = num(row.last_lat), lng = num(row.last_lng);
    return lat !== null && lng !== null && distanceKm(lat, lng, area.lat, area.lng) <= area.radiusKm;
  }
  if (!same(row.area_country, area.country)) return false;
  if (area.state && !same(row.area_state, area.state)) return false;
  if (area.city && !same(row.area_city, area.city)) return false;
  if (area.suburb && !same(row.area_suburb, area.suburb)) return false;
  return true;
}
