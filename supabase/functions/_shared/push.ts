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
  return {
    message: {
      token,
      notification: { title, body },
      data: fcmData(data),
      android: {
        priority: "HIGH",
        notification: { channel_id: ANDROID_CHANNEL_ID, sound: "default" },
      },
      apns: {
        headers: { "apns-priority": "10" },
        payload: { aps: { sound: "default" } },
      },
    },
  };
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
