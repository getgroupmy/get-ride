/**
 * What every payment gateway adapter does, and the helpers they share.
 *
 * An adapter knows one provider's API: how to open a hosted checkout for a
 * payment intent, how to tell a genuine callback from a forged one, how to
 * ask the provider what became of a payment, and a harmless call that shows
 * the account's credentials are accepted. It never touches the database;
 * the `payments` function (handler.ts) does, with the service role.
 *
 * `verified` says whether the adapter was checked against the provider's
 * published documentation or official SDK. An unverified adapter is marked in
 * Admin → Payment Gateways, lists what was not confirmed in `notes`, and has
 * a "paid" it isn't sure of confirmed by a status lookup where the provider
 * has one (`confirmPaid`), so a wrong guess leaves a payment pending (for an
 * admin to see), never credits money that wasn't paid. A request that isn't
 * signed (or an account without the secret to check it) is never believed:
 * only the lookup decides (`lookupOnly`).
 */

/** A gateway account (settings_entries 'payment-gateway') with its Vault secrets. */
export interface Account {
  id: string;
  active: boolean;
  values: Record<string, unknown>;
  secrets: Record<string, string>;
}

export interface Customer {
  name: string;
  email: string;
  phone: string;
}

export interface CheckoutInput {
  reference: string;
  amount: number;
  currency: string;
  description: string;
  customer: Customer;
  /** Where the payer's browser goes back to when done (the function's /return page). */
  returnUrl: string;
  /** Where it goes back to when the payer cancels. */
  cancelUrl: string;
  /** Where the provider sends its server-to-server notification. */
  webhookUrl: string;
  testMode: boolean;
  /** The payer's address, for providers that ask for it (eGHL). */
  ip?: string;
}

/** A hosted page to open, or (iPay88) a form the payer's browser posts. */
export type Checkout =
  | { url: string; providerRef?: string }
  | { form: { action: string; fields: Record<string, string> }; providerRef?: string };

export type PayStatus = "pending" | "paid" | "failed" | "expired" | "cancelled";

/** What a callback or a lookup says about one payment. */
export interface Outcome {
  reference?: string;
  providerRef?: string;
  status: PayStatus;
  /** In major units (RM), as the intent stores it. */
  amount?: number;
  currency?: string;
  event?: string;
}

/** A request the provider (or the payer's browser) sent to the function. */
export interface Incoming {
  method: string;
  headers: Headers;
  query: URLSearchParams;
  rawBody: string;
  /** Seconds since the epoch, for timestamped signatures. */
  now: number;
}

export interface Ack {
  status?: number;
  body: string;
  type?: string;
}

export type Verified =
  | {
    ok: true;
    outcomes: Outcome[];
    /** What the provider expects back. Default 200 "OK". */
    ack?: Ack;
    /**
     * The request wasn't signed (or the account has no secret to check it):
     * only a status lookup decides what happened.
     */
    lookupOnly?: boolean;
  }
  | { ok: false; reason: string; ack?: Ack };

export interface TestResult {
  result: "ok" | "warn" | "fail";
  title: string;
  detail: string;
}

/** What the adapter knows of the intent when it looks a payment up. */
export interface IntentRef {
  reference: string;
  providerRef?: string | null;
  amount: number;
  currency: string;
}

export type Http = (url: string, init?: RequestInit) => Promise<Response>;

export interface Adapter {
  id: string;
  name: string;
  /** Can take a payment. False: credentials are kept, nothing is charged. */
  ready: boolean;
  /** Checked against the provider's documentation or official SDK. */
  verified: boolean;
  /** What was not confirmed, and anything the owner must set at the provider. */
  notes: string[];
  /** Public fields a checkout needs (stored as `<provider>_<field>` on the account). */
  requiredPublic: string[];
  /** Secret fields a checkout needs. */
  requiredSecrets: string[];
  /** Every secret field the admin form offers (payment_gateway_secret_fields in SQL). */
  secretFields: string[];
  /** A signed "paid" is still checked with [lookup] before it counts (a scheme not fully confirmed). */
  confirmPaid?: boolean;
  /** The provider can't take a return / callback address per payment: the admin sets ours there. */
  dashboardUrls?: boolean;
  createCheckout(account: Account, input: CheckoutInput, http: Http): Promise<Checkout>;
  verify(account: Account, req: Incoming, http: Http): Promise<Verified>;
  /** Asks the provider what became of a payment (captures an approved PayPal order). */
  lookup?(account: Account, intent: IntentRef, http: Http): Promise<Outcome | null>;
  test(account: Account, http: Http): Promise<TestResult>;
}

/** A refusal with a code the app shows in words. */
export class PaymentError extends Error {
  constructor(public code: string, message?: string, public status = 400) {
    super(message ?? code);
  }
}

// ---- Helpers ---------------------------------------------------------------------------------------

const str = (v: unknown): string => (v === null || v === undefined ? "" : String(v)).trim();

/** A public field (`<provider>_<field>`). */
export function pub(account: Account, provider: string, field: string): string {
  return str(account.values[`${provider}_${field}`]);
}

export function secret(account: Account, field: string): string {
  return str(account.secrets[field]);
}

/** The fields a checkout needs, or a PaymentError naming the missing ones. */
export function requireFields(adapter: Adapter, account: Account): void {
  const missing = [
    ...adapter.requiredPublic.filter((f) => !pub(account, adapter.id, f)),
    ...adapter.requiredSecrets.filter((f) => !secret(account, f)),
  ];
  if (missing.length) {
    throw new PaymentError("missing_credentials", `${adapter.name}: not set: ${missing.join(", ")}`, 409);
  }
}

/** Sandbox mode of the account. */
export const isTest = (account: Account): boolean => str(account.values.mode) === "Sandbox";

/** RM 12.30 → 1230. */
export const minor = (amount: number): number => Math.round(amount * 100);

/** 1230 → 12.3. */
export const major = (minorUnits: unknown): number | undefined => {
  const n = Number(minorUnits);
  return Number.isFinite(n) ? Math.round(n) / 100 : undefined;
};

/** RM 12.3 → "12.30". */
export const twoDp = (amount: number): string => amount.toFixed(2);

export const num = (v: unknown): number | undefined => {
  if (v === null || v === undefined || v === "") return undefined;
  const n = Number(String(v).replace(/,/g, ""));
  return Number.isFinite(n) ? n : undefined;
};

export const formBody = (fields: Record<string, string | number | undefined>): string => {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(fields)) if (v !== undefined) p.set(k, String(v));
  return p.toString();
};

/** A form-encoded or query body as an ordered list of pairs. */
export const pairs = (s: string): [string, string][] => [...new URLSearchParams(s).entries()];

export const basic = (user: string, pass: string): string => `Basic ${btoa(`${user}:${pass}`)}`;

/** The first 300 characters of an error answer, for the admin. */
export async function errorText(res: Response): Promise<string> {
  const t = await res.text().catch(() => "");
  return t.replace(/\s+/g, " ").slice(0, 300);
}

/** JSON from a provider, or a PaymentError with what it said. */
// deno-lint-ignore no-explicit-any
export async function jsonOrThrow(res: Response, what: string): Promise<any> {
  if (!res.ok) {
    throw new PaymentError("provider_error", `${what}: HTTP ${res.status} ${await errorText(res)}`, 502);
  }
  return await res.json();
}

/** A plain-text reply for a provider. */
export const ok = (body = "OK"): Ack => ({ status: 200, body, type: "text/plain" });

/** Description text a provider accepts: letters, digits, spaces and . , - _ only. */
export const plainText = (s: string, max: number): string =>
  s.replace(/[^A-Za-z0-9 .,\-_]/g, " ").replace(/\s+/g, " ").trim().slice(0, max);

/** Malaysian mobile number without "+" (60123456789), or "". */
export const msisdn = (phone: string): string => phone.replace(/[^0-9]/g, "");

/** A test that only checks the fields are there (providers with no harmless API call). */
export function fieldsOnlyTest(adapter: Adapter, account: Account, why: string): TestResult {
  try {
    requireFields(adapter, account);
  } catch (e) {
    return { result: "fail", title: "Credentials missing", detail: (e as Error).message };
  }
  return { result: "warn", title: "Credentials are set", detail: why };
}

/** The answer for an HTTP status from a credentials check. */
export async function testFromStatus(res: Response, okDetail: string): Promise<TestResult> {
  if (res.ok) {
    await res.body?.cancel();
    return { result: "ok", title: "Connected", detail: okDetail };
  }
  const text = await errorText(res);
  if (res.status === 401 || res.status === 403) {
    return { result: "fail", title: "Credentials not accepted", detail: `HTTP ${res.status}. ${text}` };
  }
  return { result: "fail", title: `HTTP ${res.status}`, detail: text };
}
