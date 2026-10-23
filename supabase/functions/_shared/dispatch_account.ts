/**
 * dispatch-account (migration 0251): gives someone a dispatch role — stand
 * admin, stand staff or fleet owner — by phone number, making their account
 * first when the number has none. The account is a plain phone account with
 * no PIN: on first sign-in the app's usual flow sends an SMS code and has
 * them choose their own PIN.
 *
 * Who may do what is the database's (`dispatch_may_grant`, checked again by
 * `dispatch_grant`): admins with the Accounts page make stand admins and
 * fleet owners; a stand admin makes staff for their own stands. The caller is
 * the user their token names, never a value the client sent. The service
 * role stays here.
 *
 *     deno test supabase/functions/_shared/dispatch_account_test.ts
 */

export type DispatchKind = "stand_admin" | "staff" | "fleet_owner";

export interface DispatchAccountRequest {
  kind: DispatchKind;
  name: string;
  phone: string;
  stand_ids: string[];
  group_id: string | null;
  perms: Record<string, boolean>;
  /** What they do on first sign-in (0281): a selfie, their ID, and within
   * how many days (null: no deadline). Sent to dispatch_grant in p_perms. */
  verify: { verify_selfie: boolean; verify_id: boolean; verify_days: number | null };
}

export interface DispatchAccountDeps {
  /** The user the caller's token names, or null when it is not accepted. */
  caller(authorization: string | null): Promise<string | null>;
  mayGrant(caller: string, req: DispatchAccountRequest): Promise<boolean>;
  /** The account the phone signs in with, or null. */
  userByPhone(phone: string): Promise<string | null>;
  /** Makes a phone account (confirmed, no password); returns its id. */
  createUser(phone: string): Promise<string>;
  grant(caller: string, user: string, req: DispatchAccountRequest): Promise<unknown>;
}

export interface Result {
  status: number;
  body: Record<string, unknown>;
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PERMS = ["assign", "broadcast", "fixed_fare", "cancel", "reassign", "reports"];

/** "+60 12-345 6789" → "+60123456789"; null unless 8 to 15 digits. */
export function e164(phone: unknown): string | null {
  if (typeof phone !== "string") return null;
  const digits = phone.replace(/\D/g, "");
  return digits.length >= 8 && digits.length <= 15 ? `+${digits}` : null;
}

/** The request as sent, checked for shape; null when it is not one. */
export function parseRequest(body: unknown): DispatchAccountRequest | null {
  if (!body || typeof body !== "object") return null;
  const b = body as Record<string, unknown>;
  const kind = b.kind;
  if (kind !== "stand_admin" && kind !== "staff" && kind !== "fleet_owner") return null;
  const name = typeof b.name === "string" ? b.name.trim() : "";
  if (!name || name.length > 80) return null;
  const phone = e164(b.phone);
  if (!phone) return null;
  const stands = Array.isArray(b.stand_ids) ? b.stand_ids : [];
  if (stands.length > 50 || !stands.every((s) => typeof s === "string" && uuid.test(s))) return null;
  const group = typeof b.group_id === "string" && uuid.test(b.group_id) ? b.group_id : null;
  if (kind === "fleet_owner" ? !group : stands.length === 0) return null;
  const raw = b.perms && typeof b.perms === "object" ? b.perms as Record<string, unknown> : {};
  const perms: Record<string, boolean> = {};
  for (const p of PERMS) perms[p] = raw[p] === true;
  const v = b.verify && typeof b.verify === "object" ? b.verify as Record<string, unknown> : {};
  const days = typeof v.verify_days === "number" && Number.isInteger(v.verify_days) ? v.verify_days : null;
  if (days !== null && (days < 1 || days > 365)) return null;
  const verify = { verify_selfie: v.verify_selfie === true, verify_id: v.verify_id === true, verify_days: days };
  return { kind, name, phone, stand_ids: stands as string[], group_id: group, perms, verify };
}

export async function handleDispatchAccount(
  body: unknown,
  authorization: string | null,
  deps: DispatchAccountDeps,
): Promise<Result> {
  const req = parseRequest(body);
  if (!req) return { status: 400, body: { error: "bad_request" } };
  let caller: string | null;
  try {
    caller = await deps.caller(authorization);
  } catch {
    return { status: 503, body: { error: "unavailable" } };
  }
  if (!caller) return { status: 401, body: { error: "not_signed_in" } };
  try {
    if (!(await deps.mayGrant(caller, req))) return { status: 403, body: { error: "not_authorized" } };
    let user = await deps.userByPhone(req.phone);
    const created = user == null;
    if (user == null) user = await deps.createUser(req.phone);
    await deps.grant(caller, user, req);
    return { status: 200, body: { user_id: user, created } };
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    if (/not_authorized/.test(message)) return { status: 403, body: { error: "not_authorized" } };
    if (/DISPATCH_[A-Z_]+/.test(message)) {
      return { status: 409, body: { error: message.match(/DISPATCH_[A-Z_]+/)![0] } };
    }
    return { status: 503, body: { error: "unavailable" } };
  }
}
