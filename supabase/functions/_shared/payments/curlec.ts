// deno-lint-ignore-file no-explicit-any -- provider JSON is read field by field.
/**
 * Curlec by Razorpay (Malaysia), on Razorpay's API
 * (https://razorpay.com/docs/api/payments/payment-links/): POST
 * /v1/payment_links with Basic key_id:key_secret gives `short_url`.
 *   * Webhook: X-Razorpay-Signature = HMAC-SHA256(webhook secret, raw body).
 *   * The payer's return (callback_method get): razorpay_signature =
 *     HMAC-SHA256(key secret, link_id|reference_id|status|payment_id).
 * Test or live follows the key (rzp_test_ / rzp_live_).
 */
import { hmacSha256Hex, sameHex } from "./crypto.ts";
import {
  type Account,
  type Adapter,
  basic,
  type Incoming,
  jsonOrThrow,
  major,
  minor,
  type Outcome,
  pub,
  requireFields,
  secret,
  testFromStatus,
  type Verified,
} from "./types.ts";

const API = "https://api.razorpay.com/v1";
const auth = (a: Account) => ({ Authorization: basic(pub(a, "curlec", "keyId"), secret(a, "keySecret")) });

export const razorpayReturnSource = (q: URLSearchParams): string =>
  [
    q.get("razorpay_payment_link_id") ?? "",
    q.get("razorpay_payment_link_reference_id") ?? "",
    q.get("razorpay_payment_link_status") ?? "",
    q.get("razorpay_payment_id") ?? "",
  ].join("|");

const linkStatus = (s: unknown): Outcome["status"] =>
  s === "paid" ? "paid" : s === "cancelled" ? "cancelled" : s === "expired" ? "expired" : "pending";

function linkOutcome(l: any): Outcome {
  return {
    providerRef: l?.id,
    reference: l?.reference_id,
    status: linkStatus(l?.status),
    amount: major(l?.status === "paid" ? l?.amount_paid : l?.amount),
    currency: l?.currency,
  };
}

export const curlec: Adapter = {
  id: "curlec",
  name: "Curlec by Razorpay",
  ready: true,
  verified: true,
  notes: [
    "Uses Razorpay's Payment Links API, which Curlec (Razorpay Malaysia) accounts use; MYR must be enabled.",
    "Without the webhook secret, every webhook is checked by asking Razorpay for the payment link.",
  ],
  requiredPublic: ["keyId"],
  requiredSecrets: ["keySecret"],
  secretFields: ["keySecret", "webhookSecret"],

  async createCheckout(account, input, http) {
    requireFields(this, account);
    const res = await http(`${API}/payment_links`, {
      method: "POST",
      headers: { ...auth(account), "Content-Type": "application/json" },
      body: JSON.stringify({
        amount: minor(input.amount),
        currency: input.currency,
        accept_partial: false,
        description: input.description.slice(0, 2048),
        reference_id: input.reference,
        customer: {
          name: input.customer.name || undefined,
          email: input.customer.email || undefined,
          contact: input.customer.phone || undefined,
        },
        notify: { sms: false, email: false },
        callback_url: input.returnUrl,
        callback_method: "get",
      }),
    });
    const l = await jsonOrThrow(res, "Razorpay payment link");
    return { url: l.short_url, providerRef: l.id };
  },

  async verify(account, req: Incoming): Promise<Verified> {
    // The payer's browser coming back.
    if (req.query.get("razorpay_payment_link_id")) {
      const sig = req.query.get("razorpay_signature") ?? "";
      const expected = await hmacSha256Hex(secret(account, "keySecret"), razorpayReturnSource(req.query));
      if (!sig || !sameHex(sig, expected)) return { ok: false, reason: "bad_signature" };
      return {
        ok: true,
        outcomes: [{
          providerRef: req.query.get("razorpay_payment_link_id")!,
          reference: req.query.get("razorpay_payment_link_reference_id") ?? undefined,
          status: linkStatus(req.query.get("razorpay_payment_link_status")),
        }],
      };
    }
    const whsec = secret(account, "webhookSecret");
    if (whsec) {
      const sig = req.headers.get("x-razorpay-signature") ?? "";
      if (!sig || !sameHex(sig, await hmacSha256Hex(whsec, req.rawBody))) return { ok: false, reason: "bad_signature" };
    }
    let event: any;
    try {
      event = JSON.parse(req.rawBody);
    } catch {
      return { ok: false, reason: "not_json" };
    }
    const link = event?.payload?.payment_link?.entity;
    const outcomes = String(event?.event ?? "").startsWith("payment_link.") && link
      ? [{ ...linkOutcome(link), event: String(event.event) }]
      : [];
    return { ok: true, outcomes, lookupOnly: !whsec };
  },

  async lookup(account, intent, http) {
    if (!intent.providerRef) return null;
    const res = await http(`${API}/payment_links/${encodeURIComponent(intent.providerRef)}`, { headers: auth(account) });
    return linkOutcome(await jsonOrThrow(res, "Razorpay payment link"));
  },

  async test(account, http) {
    if (!pub(account, "curlec", "keyId") || !secret(account, "keySecret")) {
      return { result: "fail", title: "Credentials missing", detail: "Set the key ID and the key secret." };
    }
    return await testFromStatus(await http(`${API}/payments?count=1`, { headers: auth(account) }), "Razorpay accepted the key.");
  },
};
