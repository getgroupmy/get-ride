/**
 * The ICE servers a support call is set up with (turn-credentials).
 *
 * A direct phone-to-phone connection fails on many mobile networks (carrier
 * NAT), so a call also needs a TURN relay. The relay is coturn (or any
 * server speaking the TURN REST API): it shares a secret with this function,
 * and each caller gets a username of `<expiry>:<user id>` and a password of
 * base64(HMAC-SHA1(secret, username)) that the relay can check without a
 * user table. The credentials expire, so one leaked from an app is useless
 * a few hours later.
 *
 * Pure apart from the HMAC, and tested in turn_test.ts.
 */

/** How long handed-out credentials last. A call longer than this keeps its relay. */
export const TURN_TTL_SECONDS = 6 * 60 * 60;

/** Used when no STUN server is configured. */
export const DEFAULT_STUN_URLS = ["stun:stun.l.google.com:19302"];

export type IceServer = { urls: string[]; username?: string; credential?: string };

/** A comma-separated secret value, trimmed, blanks dropped. */
export function splitUrls(raw: string | undefined | null): string[] {
  return (raw ?? "").split(",").map((s) => s.trim()).filter((s) => s.length > 0);
}

/** The TURN REST API username for [userId], valid until [nowSeconds] + [ttl]. */
export function turnUsername(userId: string, nowSeconds: number, ttl = TURN_TTL_SECONDS): string {
  return `${Math.floor(nowSeconds) + ttl}:${userId}`;
}

/** base64(HMAC-SHA1(secret, username)), the password coturn expects. */
export async function turnPassword(secret: string, username: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(username)));
  let bin = "";
  for (const b of sig) bin += String.fromCharCode(b);
  return btoa(bin);
}

/**
 * The ICE servers for [userId]: STUN always, TURN only when both relay URLs
 * and the shared secret are configured (a TURN entry without working
 * credentials would only slow every call down while it fails).
 */
export async function iceServersFor(input: {
  userId: string;
  nowSeconds: number;
  turnUrls: string[];
  turnSecret?: string | null;
  stunUrls?: string[];
  ttl?: number;
}): Promise<{ iceServers: IceServer[]; ttl: number; relay: boolean }> {
  const ttl = input.ttl ?? TURN_TTL_SECONDS;
  const stun = input.stunUrls && input.stunUrls.length > 0 ? input.stunUrls : DEFAULT_STUN_URLS;
  const servers: IceServer[] = [{ urls: stun }];
  const secret = (input.turnSecret ?? "").trim();
  const relay = input.turnUrls.length > 0 && secret.length > 0;
  if (relay) {
    const username = turnUsername(input.userId, input.nowSeconds, ttl);
    servers.push({ urls: input.turnUrls, username, credential: await turnPassword(secret, username) });
  }
  return { iceServers: servers, ttl, relay };
}
