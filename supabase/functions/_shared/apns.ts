/**
 * PushKit (VoIP) pushes straight to Apple, for ride calls that ring on a
 * closed iPhone app (see planDeliveries in push.ts).
 *
 * FCM cannot send these: a VoIP push goes to APNs with the app's own key.
 * The key is configured with four function secrets, and until all of them
 * are set nothing here runs and iPhones keep the ordinary notification:
 *
 *   APNS_AUTH_KEY   the .p8 key's contents (Apple Developer → Keys, with
 *                   Apple Push Notifications service enabled)
 *   APNS_KEY_ID     its Key ID
 *   APNS_TEAM_ID    the developer Team ID
 *   APNS_BUNDLE_ID  optional; the app's bundle id (default com.taxxee.teksi)
 *
 * A token belongs to one APNs environment (an Xcode build is "development",
 * TestFlight and the App Store "production") and nothing records which, so
 * a send tries production and falls back to development on BadDeviceToken.
 *
 *     deno test supabase/functions/_shared/apns_test.ts
 */

export const DEFAULT_BUNDLE_ID = "com.taxxee.teksi";

export const APNS_PRODUCTION = "https://api.push.apple.com";
export const APNS_DEVELOPMENT = "https://api.sandbox.push.apple.com";

/** How long a ride call rings before it is missed (0131's 45 seconds). */
export const RING_MS = 45_000;

export interface ApnsKey {
  p8: string;
  keyId: string;
  teamId: string;
  bundleId: string;
}

/** The configured key, or null when any part of it is missing. */
export function parseApnsKey(get: (name: string) => string | undefined): ApnsKey | null {
  const p8 = (get("APNS_AUTH_KEY") ?? "").trim();
  const keyId = (get("APNS_KEY_ID") ?? "").trim();
  const teamId = (get("APNS_TEAM_ID") ?? "").trim();
  const bundleId = (get("APNS_BUNDLE_ID") ?? "").trim() || DEFAULT_BUNDLE_ID;
  if (!p8.includes("PRIVATE KEY") || !keyId || !teamId) return null;
  return { p8, keyId, teamId, bundleId };
}

function base64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemBody(pem: string): Uint8Array<ArrayBuffer> {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

/**
 * The provider token APNs takes as `authorization: bearer …`: an ES256 JWT
 * from the team, signed with the .p8 key. Valid for an hour; one is made per
 * send-push run.
 */
export async function apnsJwt(key: ApnsKey, nowSeconds: number): Promise<string> {
  const enc = new TextEncoder();
  const header = base64url(enc.encode(JSON.stringify({ alg: "ES256", kid: key.keyId })));
  const claims = base64url(enc.encode(JSON.stringify({ iss: key.teamId, iat: Math.floor(nowSeconds) })));
  const signingKey = await crypto.subtle.importKey(
    "pkcs8",
    pemBody(key.p8),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  // WebCrypto signs ECDSA as r‖s, which is the form a JWT wants.
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    signingKey,
    enc.encode(`${header}.${claims}`),
  );
  return `${header}.${claims}.${base64url(new Uint8Array(sig))}`;
}

/** "Aina is calling" → "Aina". */
function callerFrom(title: string): string {
  const name = title.replace(/\s+is calling\s*$/i, "").trim();
  return name || "GET.ride";
}

/**
 * The VoIP payload, in the shape the app's AppDelegate hands straight to
 * flutter_callkit_incoming (`Data(args:)`): the call's id is the CallKit
 * UUID, and `extra` carries what the app needs to open the call.
 */
export function voipPayload(data: Record<string, unknown>, title: string): Record<string, unknown> {
  const str = (v: unknown) => (typeof v === "string" ? v : "");
  const callId = str(data.call_id);
  const caller = str(data.caller_name) || callerFrom(title);
  return {
    aps: {},
    id: callId,
    nameCaller: caller,
    appName: "GET.ride",
    handle: "Ride call",
    type: 0,
    duration: RING_MS,
    extra: {
      type: "ride_call",
      call_id: callId,
      request_id: str(data.request_id),
      role: str(data.role),
      caller_name: caller,
    },
    ios: {
      handleType: "generic",
      supportsVideo: false,
      supportsDTMF: false,
      supportsHolding: false,
      supportsGrouping: false,
      supportsUngrouping: false,
      maximumCallGroups: 1,
      includesCallsInRecents: false,
    },
  };
}

export function apnsRequest(host: string, key: ApnsKey, jwt: string, token: string, payload: unknown) {
  return {
    url: `${host}/3/device/${encodeURIComponent(token)}`,
    init: {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": `${key.bundleId}.voip`,
        "apns-push-type": "voip",
        "apns-priority": "10",
        // A call that rang out is not worth delivering late.
        "apns-expiration": "0",
        "content-type": "application/json",
      },
      body: JSON.stringify(payload),
    },
  };
}

export type ApnsOutcome = "sent" | "unregistered" | "wrong_environment" | "failed";

/**
 * What APNs said about one token. Only a token APNs says is gone is pruned;
 * BadDeviceToken from one environment means try the other one.
 */
export function apnsOutcome(status: number, reason: string | null | undefined): ApnsOutcome {
  if (status >= 200 && status < 300) return "sent";
  if (status === 410 || reason === "Unregistered") return "unregistered";
  if (reason === "BadDeviceToken") return "wrong_environment";
  return "failed";
}
