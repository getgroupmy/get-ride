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
