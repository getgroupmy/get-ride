/**
 * pin-login: PIN sign-in through the server (migration 0172).
 *
 * The PIN is checked by the database (`pin_login_check`: bcrypt hash, a
 * per-address rate limit on the address the phone called from, five wrong
 * PINs lock the account for fifteen minutes). On a match the function signs
 * in with the account's server password and hands the session back. That
 * password is derived from a server-only key and the account id
 * ([accountPassword]): never stored, never sent to the phone, and nothing a
 * guesser could try at Auth's password grant.
 *
 * It stays the same from one sign-in to the next on purpose. Auth signs an
 * account out everywhere whenever its password changes, so a password set
 * afresh on every sign-in (as before) signed out the account's other phones
 * and browsers each time. Now it is set only when signing in with it fails:
 * the first PIN sign-in after this change, or after an SMS sign-in replaced it.
 *
 * Kept free of the Supabase client so the rules are tested with stand-ins.
 */

/** What the phone sends. */
export interface PinLoginRequest {
  phone: string;
  pin: string;
}

/** What the function answers, by `error` (absent on success). */
export type PinLoginError =
  | "bad_request" // not a phone and a six-digit PIN
  | "wrong_pin" // no account with this number and PIN; attempts_left when the account has a PIN (0192)
  | "locked" // too many wrong PINs on this account; retry_after seconds
  | "rate_limited" // too many checks from this address; retry_after seconds
  | "needs_otp" // the PIN is right but there is no Auth login to give it
  | "unavailable"; // the database or Auth did not answer

export interface PinLoginSession {
  access_token: string;
  refresh_token: string;
  expires_in?: number;
  expires_at?: number;
  token_type?: string;
}

/** What pin-login needs from the outside world. */
export interface PinLoginDeps {
  /** pin_login_check: the account id, or null; throws with the database's
   * message (`PIN_LOCKED:n`, `RATE_LIMITED:n`) when it refuses. */
  check(phone: string, pin: string, ip: string): Promise<string | null>;
  /** The Auth user's phone, or null when there is no such Auth user. */
  authPhone(userId: string): Promise<string | null>;
  setPassword(userId: string, password: string): Promise<void>;
  /** Signs in; null when Auth rejects the credentials. */
  signIn(phone: string, password: string): Promise<PinLoginSession | null>;
  /** The account's server password ([accountPassword]). */
  accountPassword(userId: string): Promise<string>;
  /** pin_attempts_left (0192): tries left before the lock, or null for a
   * number with no account or no PIN, so nothing is said about it. Optional:
   * without it a wrong PIN says only that. */
  attemptsLeft?(phone: string): Promise<number | null>;
}

export const PIN_PATTERN = /^\d{6}$/;

/** The request body, or null when it is not a phone and a six-digit PIN. */
export function parsePinLoginRequest(body: unknown): PinLoginRequest | null {
  if (typeof body !== "object" || body === null) return null;
  const { phone, pin } = body as Record<string, unknown>;
  if (typeof phone !== "string" || typeof pin !== "string") return null;
  const digits = phone.replace(/\D/g, "");
  if (digits.length < 6 || digits.length > 15) return null;
  if (!PIN_PATTERN.test(pin)) return null;
  return { phone: phone.trim(), pin };
}

/**
 * The phone's address as the edge saw it. Cloudflare's header first (it
 * cannot be set by the caller through Cloudflare), then the first hop of
 * X-Forwarded-For. Never empty: with nothing to go on every such request
 * shares one bucket rather than going unlimited.
 */
export function clientIp(headers: Headers): string {
  const cf = headers.get("cf-connecting-ip")?.trim();
  if (cf) return cf.slice(0, 64);
  const real = headers.get("x-real-ip")?.trim();
  if (real) return real.slice(0, 64);
  const xff = headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  if (xff) return xff.slice(0, 64);
  return "unknown";
}

/** The database's refusal as an answer: locked, rate limited, or null. */
export function refusalOf(message: string): { error: PinLoginError; retry_after: number } | null {
  const lock = /PIN_LOCKED:?(\d+)?/.exec(message);
  if (lock) return { error: "locked", retry_after: Number(lock[1] ?? 900) };
  const rate = /RATE_LIMITED:?(\d+)?/.exec(message);
  if (rate) return { error: "rate_limited", retry_after: Number(rate[1] ?? 60) };
  return null;
}

/**
 * The account's Auth password: HMAC-SHA256 of its id under [key] (a secret
 * only this function holds), base64url. The same for every sign-in, and
 * unguessable without the key.
 */
export async function accountPassword(key: string, userId: string): Promise<string> {
  if (!key) throw new Error("pin-login has no key to derive passwords with");
  const enc = new TextEncoder();
  const hmac = await crypto.subtle.importKey("raw", enc.encode(key), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", hmac, enc.encode(`getride-pin-login:v2:${userId}`)));
  return btoa(String.fromCharCode(...mac)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export interface PinLoginResult {
  status: number;
  body: Record<string, unknown>;
}

/**
 * The whole sign-in. The password is only set when signing in with it is
 * refused, so other devices stay signed in; two sign-ins at the same moment
 * set the same password, so neither undoes the other.
 */
export async function handlePinLogin(body: unknown, ip: string, deps: PinLoginDeps): Promise<PinLoginResult> {
  const req = parsePinLoginRequest(body);
  if (!req) return { status: 400, body: { error: "bad_request" } };

  let userId: string | null;
  try {
    userId = await deps.check(req.phone, req.pin, ip);
  } catch (e) {
    const refusal = refusalOf(e instanceof Error ? e.message : String(e));
    if (refusal) return { status: refusal.error === "locked" ? 423 : 429, body: { ...refusal } };
    return { status: 503, body: { error: "unavailable" } };
  }
  if (!userId) {
    let left: number | null = null;
    try {
      left = deps.attemptsLeft ? await deps.attemptsLeft(req.phone) : null;
    } catch {
      left = null;
    }
    return { status: 401, body: left === null ? { error: "wrong_pin" } : { error: "wrong_pin", attempts_left: left } };
  }

  try {
    const phone = await deps.authPhone(userId);
    // A profile with a PIN but no phone login in Auth: the SMS code makes one.
    if (!phone) return { status: 409, body: { error: "needs_otp" } };
    const password = await deps.accountPassword(userId);
    const session = await deps.signIn(phone, password);
    if (session) return { status: 200, body: { session } };
    // Not set yet (or replaced since): set once, which signs the account out
    // elsewhere this one time, and sign in.
    await deps.setPassword(userId, password);
    const fresh = await deps.signIn(phone, password);
    if (fresh) return { status: 200, body: { session: fresh } };
    return { status: 503, body: { error: "unavailable" } };
  } catch {
    return { status: 503, body: { error: "unavailable" } };
  }
}
