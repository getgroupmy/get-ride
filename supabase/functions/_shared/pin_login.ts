/**
 * pin-login: PIN sign-in through the server (migration 0172).
 *
 * The PIN is checked by the database (`pin_login_check`: bcrypt hash, a
 * per-address rate limit on the address the phone called from, five wrong
 * PINs lock the account for fifteen minutes). On a match the account's Auth
 * password is replaced with a fresh random one, the function signs in with
 * it and hands the session back. The password is never stored or sent to
 * the phone, so nothing a guesser could try at Auth's password grant is
 * derived from the PIN any more.
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
  | "wrong_pin" // no account with this number and PIN (never says which)
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
  randomPassword(): string;
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

/** 32 random bytes, base64url: the throwaway Auth password. */
export function randomPassword(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export interface PinLoginResult {
  status: number;
  body: Record<string, unknown>;
}

/**
 * The whole sign-in. Two sign-ins for one account at the same moment can
 * each replace the other's password between setting and using it, so a
 * rejected sign-in is tried once more with a new password.
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
  if (!userId) return { status: 401, body: { error: "wrong_pin" } };

  try {
    const phone = await deps.authPhone(userId);
    // A profile with a PIN but no phone login in Auth: the SMS code makes one.
    if (!phone) return { status: 409, body: { error: "needs_otp" } };
    for (let attempt = 0; attempt < 2; attempt++) {
      const password = deps.randomPassword();
      await deps.setPassword(userId, password);
      const session = await deps.signIn(phone, password);
      if (session) return { status: 200, body: { session } };
    }
    return { status: 503, body: { error: "unavailable" } };
  } catch {
    return { status: 503, body: { error: "unavailable" } };
  }
}
