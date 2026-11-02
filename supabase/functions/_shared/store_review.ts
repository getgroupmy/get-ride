/**
 * pin-login's `review` action: the store review login (migration 0333).
 *
 * Google Play and App Store reviewers sign in with a number the admin sets
 * (Admin › Settings › App Settings › Store review login), with no SMS code
 * and no PIN. The database decides (`store_review_sign_in`, service role
 * only): the switch must be on and the number must be the one set; tries
 * are rate limited per address and overall, and every try is logged. Then
 * this signs in to the ONE sealed demo account the migration made, the way
 * a PIN sign-in does (its server password, see pin_login.ts), and hands the
 * session back. Nothing in the request can name another account.
 *
 * Kept free of the Supabase client so the rules are tested with stand-ins.
 */
import type { PinLoginResult, PinLoginSession } from "./pin_login.ts";

/** What the phone sends. */
export interface StoreReviewRequest {
  phone: string;
  platform: string | null;
  device: string | null;
  appVersion: string | null;
}

/** store_review_sign_in's answer. */
export interface StoreReviewCheck {
  ok: boolean;
  outcome: string;
  user_id?: string | null;
  retry_after?: number | null;
}

export interface StoreReviewDeps {
  /** store_review_sign_in(phone, ip, platform, device, version, agent). */
  check(req: StoreReviewRequest, ip: string, userAgent: string | null): Promise<StoreReviewCheck>;
  /** The Auth user's phone, or null when there is no such Auth user. */
  authPhone(userId: string): Promise<string | null>;
  setPassword(userId: string, password: string): Promise<void>;
  /** Signs in; null when Auth rejects the credentials. */
  signIn(phone: string, password: string): Promise<PinLoginSession | null>;
  /** The account's server password (pin_login.ts accountPassword). */
  accountPassword(userId: string): Promise<string>;
}

function short(v: unknown, max: number): string | null {
  if (typeof v !== "string") return null;
  const s = v.trim();
  return s ? s.slice(0, max) : null;
}

/** The request body, or null when it is not a review sign-in with a number. */
export function parseStoreReviewRequest(body: unknown): StoreReviewRequest | null {
  if (typeof body !== "object" || body === null) return null;
  const b = body as Record<string, unknown>;
  if (b.action !== "review" || typeof b.phone !== "string") return null;
  const digits = b.phone.replace(/\D/g, "");
  if (digits.length < 6 || digits.length > 15) return null;
  return {
    phone: `+${digits}`,
    platform: short(b.platform, 20),
    device: short(b.device, 120),
    appVersion: short(b.app_version, 40),
  };
}

/** Whether [body] asks for the review action at all. */
export function isStoreReviewBody(body: unknown): boolean {
  return typeof body === "object" && body !== null && (body as Record<string, unknown>).action === "review";
}

/**
 * The whole review sign-in. Off, a wrong number, or no demo account all
 * answer the same `review_off`, so the route says nothing about the number.
 */
export async function handleStoreReviewLogin(
  body: unknown,
  ip: string,
  userAgent: string | null,
  deps: StoreReviewDeps,
): Promise<PinLoginResult> {
  const req = parseStoreReviewRequest(body);
  if (!req) return { status: 400, body: { error: "bad_request" } };

  let check: StoreReviewCheck;
  try {
    check = await deps.check(req, ip, userAgent);
  } catch {
    return { status: 503, body: { error: "unavailable" } };
  }
  if (check.outcome === "rate_limited") {
    return { status: 429, body: { error: "rate_limited", retry_after: Number(check.retry_after ?? 60) } };
  }
  const userId = check.ok ? check.user_id : null;
  if (!userId) return { status: 403, body: { error: "review_off" } };

  try {
    const phone = await deps.authPhone(userId);
    if (!phone) return { status: 503, body: { error: "unavailable" } };
    const password = await deps.accountPassword(userId);
    const session = await deps.signIn(phone, password);
    if (session) return { status: 200, body: { session } };
    // First review sign-in (the migration leaves no password): set it once.
    await deps.setPassword(userId, password);
    const fresh = await deps.signIn(phone, password);
    if (fresh) return { status: 200, body: { session: fresh } };
    return { status: 503, body: { error: "unavailable" } };
  } catch {
    return { status: 503, body: { error: "unavailable" } };
  }
}
