// deno-lint-ignore-file no-explicit-any -- provider JSON is read field by field.
/**
 * HitPay (Singapore / Malaysia): payment requests
 * (https://docs.hitpayapp.com/apis/guide/online-payments) — POST
 * /v1/payment-requests with the X-BUSINESS-API-KEY header gives the hosted
 * page's url. Webhooks are signed with the account's salt, two ways:
 *   * the form-encoded webhook: `hmac` = HMAC-SHA256(salt, every other
 *     field as key + value, sorted by key, joined with nothing);
 *   * the JSON event webhook: `Hitpay-Signature` = HMAC-SHA256(salt, raw body).
 * Either way the payment request is then looked up before it counts as paid.
 */
import { hmacSha256Hex, sameHex } from "./crypto.ts";
import {
  type Account,
  type Adapter,
  formBody,
  type Incoming,
  jsonOrThrow,
  num,
  ok,
  type Outcome,
  pairs,
  requireFields,
  secret,
  twoDp,
  type Verified,
} from "./types.ts";

const base = (a: Account) =>
  a.values.mode === "Sandbox" ? "https://api.sandbox.hit-pay.com/v1" : "https://api.hit-pay.com/v1";
const headers = (a: Account) => ({
  "X-BUSINESS-API-KEY": secret(a, "apiKey"),
  "X-Requested-With": "XMLHttpRequest",
});

/** The legacy webhook's signed string: key+value of every field but hmac, by key. */
export function hitpaySource(fields: [string, string][]): string {
  return fields
    .filter(([k]) => k !== "hmac")
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([k, v]) => `${k}${v}`)
    .join("");
}

const statusOf = (s: unknown): Outcome["status"] => {
  const v = String(s ?? "").toLowerCase();
  if (v === "completed" || v === "succeeded") return "paid";
  if (v === "failed") return "failed";
  if (v === "expired") return "expired";
  if (v === "canceled" || v === "cancelled") return "cancelled";
  return "pending";
};

export const hitpay: Adapter = {
  id: "hitpay",
  name: "HitPay",
  ready: true,
  verified: true,
  // Two webhook formats, and the newer one's fields were not confirmed: ask HitPay.
  confirmPaid: true,
  notes: [
    "Without the salt, every webhook is checked by asking HitPay for the payment request.",
    "MYR must be enabled on the HitPay business account.",
  ],
  requiredPublic: [],
  requiredSecrets: ["apiKey"],
  secretFields: ["apiKey", "salt"],

  async createCheckout(account, input, http) {
    requireFields(this, account);
    const res = await http(`${base(account)}/payment-requests`, {
      method: "POST",
      headers: { ...headers(account), "Content-Type": "application/x-www-form-urlencoded" },
      body: formBody({
        amount: twoDp(input.amount),
        currency: input.currency,
        email: input.customer.email || undefined,
        name: input.customer.name || undefined,
        phone: input.customer.phone || undefined,
        purpose: input.description.slice(0, 255),
        reference_number: input.reference,
        redirect_url: input.returnUrl,
        webhook: input.webhookUrl,
      }),
    });
    const r = await jsonOrThrow(res, "HitPay payment request");
    return { url: r.url, providerRef: r.id };
  },

  async verify(account, req: Incoming): Promise<Verified> {
    const salt = secret(account, "salt");
    const signed = req.headers.get("hitpay-signature");
    let outcome: Outcome;
    if (signed !== null) {
      if (salt && !sameHex(signed, await hmacSha256Hex(salt, req.rawBody))) return { ok: false, reason: "bad_signature" };
      let body: any;
      try {
        body = JSON.parse(req.rawBody);
      } catch {
        return { ok: false, reason: "not_json" };
      }
      outcome = {
        providerRef: body?.payment_request_id ?? body?.payment_request?.id ?? body?.id,
        reference: body?.reference_number ?? body?.payment_request?.reference_number,
        status: statusOf(body?.status),
        amount: num(body?.amount),
        currency: body?.currency ? String(body.currency).toUpperCase() : undefined,
      };
    } else {
      const fields = pairs(req.rawBody);
      const f = Object.fromEntries(fields);
      if (!f.payment_request_id) return { ok: false, reason: "no_payment_request" };
      if (salt && !sameHex(f.hmac ?? "", await hmacSha256Hex(salt, hitpaySource(fields)))) {
        return { ok: false, reason: "bad_signature" };
      }
      outcome = {
        providerRef: f.payment_request_id,
        reference: f.reference_number,
        status: statusOf(f.status),
        amount: num(f.amount),
        currency: f.currency?.toUpperCase(),
      };
    }
    return { ok: true, outcomes: [outcome], ack: ok(), lookupOnly: !salt };
  },

  async lookup(account, intent, http) {
    if (!intent.providerRef) return null;
    const res = await http(`${base(account)}/payment-requests/${encodeURIComponent(intent.providerRef)}`, {
      headers: headers(account),
    });
    const r = await jsonOrThrow(res, "HitPay payment request");
    return {
      providerRef: r.id,
      reference: r.reference_number,
      status: statusOf(r.status),
      amount: num(r.amount),
      currency: r.currency ? String(r.currency).toUpperCase() : undefined,
    };
  },

  async test(account, http) {
    if (!secret(account, "apiKey")) return { result: "fail", title: "API key not set", detail: "Set the API key." };
    // A payment request that doesn't exist: 404 means the key was accepted.
    const res = await http(`${base(account)}/payment-requests/00000000-0000-0000-0000-000000000000`, {
      headers: headers(account),
    });
    await res.body?.cancel();
    if (res.status === 401 || res.status === 403) {
      return { result: "fail", title: "Credentials not accepted", detail: `HTTP ${res.status}` };
    }
    if (res.ok || res.status === 404) return { result: "ok", title: "Connected", detail: "HitPay accepted the API key." };
    return { result: "fail", title: `HTTP ${res.status}`, detail: "HitPay did not answer as expected." };
  },
};
