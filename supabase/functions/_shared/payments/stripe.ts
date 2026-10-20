// deno-lint-ignore-file no-explicit-any -- provider JSON is read field by field.
/**
 * Stripe: Checkout Sessions (https://docs.stripe.com/api/checkout/sessions)
 * and signed webhooks (https://docs.stripe.com/webhooks#verify-manually):
 * `Stripe-Signature: t=<unix>,v1=<hex>` where v1 = HMAC-SHA256(whsec, "t.body").
 * Test or live is the key's (sk_test_ / sk_live_).
 */
import { hmacSha256Hex, sameHex } from "./crypto.ts";
import {
  type Account,
  type Adapter,
  formBody,
  type Http,
  type Incoming,
  jsonOrThrow,
  major,
  minor,
  type Outcome,
  requireFields,
  secret,
  testFromStatus,
  type Verified,
} from "./types.ts";

const API = "https://api.stripe.com/v1";
/** Stripe's default: a signature older than five minutes is refused. */
export const STRIPE_TOLERANCE_S = 300;

/** Stripe-Signature header → its time and v1 signatures. */
export function parseStripeSignature(header: string): { t: number; v1: string[] } {
  let t = NaN;
  const v1: string[] = [];
  for (const part of header.split(",")) {
    const [k, v] = part.split("=", 2).map((s) => s?.trim() ?? "");
    if (k === "t") t = Number(v);
    if (k === "v1" && v) v1.push(v);
  }
  return { t, v1 };
}

export async function stripeSignatureValid(
  rawBody: string,
  header: string,
  whsec: string,
  now: number,
  tolerance = STRIPE_TOLERANCE_S,
): Promise<boolean> {
  const { t, v1 } = parseStripeSignature(header);
  if (!Number.isFinite(t) || !v1.length) return false;
  if (Math.abs(now - t) > tolerance) return false;
  const expected = await hmacSha256Hex(whsec, `${t}.${rawBody}`);
  return v1.some((s) => sameHex(s, expected));
}

function sessionOutcome(s: any, event?: string): Outcome {
  const paid = s?.payment_status === "paid" || s?.payment_status === "no_payment_required";
  let status: Outcome["status"] = paid ? "paid" : "pending";
  if (event === "checkout.session.async_payment_failed") status = "failed";
  if (s?.status === "expired" || event === "checkout.session.expired") status = "expired";
  return {
    reference: s?.client_reference_id ?? s?.metadata?.reference ?? undefined,
    providerRef: s?.id,
    status,
    amount: major(s?.amount_total),
    currency: typeof s?.currency === "string" ? s.currency.toUpperCase() : undefined,
    event,
  };
}

const auth = (a: Account) => ({ Authorization: `Bearer ${secret(a, "secretKey")}` });

export const stripe: Adapter = {
  id: "stripe",
  name: "Stripe",
  ready: true,
  verified: true,
  notes: [
    "Sandbox or Live follows the secret key (sk_test_ / sk_live_); keep the account's mode the same.",
    "Without the webhook signing secret, every notification is checked by asking Stripe for the session.",
  ],
  requiredPublic: [],
  requiredSecrets: ["secretKey"],
  secretFields: ["secretKey", "webhookSecret"],

  async createCheckout(account, input, http) {
    requireFields(this, account);
    const res = await http(`${API}/checkout/sessions`, {
      method: "POST",
      headers: {
        ...auth(account),
        "Content-Type": "application/x-www-form-urlencoded",
        "Idempotency-Key": `checkout-${input.reference}`,
      },
      body: formBody({
        mode: "payment",
        success_url: input.returnUrl,
        cancel_url: input.cancelUrl,
        client_reference_id: input.reference,
        "metadata[reference]": input.reference,
        "payment_intent_data[metadata][reference]": input.reference,
        "line_items[0][quantity]": 1,
        "line_items[0][price_data][currency]": input.currency.toLowerCase(),
        "line_items[0][price_data][unit_amount]": minor(input.amount),
        "line_items[0][price_data][product_data][name]": input.description,
        customer_email: input.customer.email || undefined,
      }),
    });
    const s = await jsonOrThrow(res, "Stripe checkout");
    return { url: s.url, providerRef: s.id };
  },

  async verify(account: Account, req: Incoming): Promise<Verified> {
    let event: any;
    try {
      event = JSON.parse(req.rawBody);
    } catch {
      return { ok: false, reason: "not_json" };
    }
    const whsec = secret(account, "webhookSecret");
    let lookupOnly = false;
    if (whsec) {
      const header = req.headers.get("stripe-signature") ?? "";
      if (!(await stripeSignatureValid(req.rawBody, header, whsec, req.now))) {
        return { ok: false, reason: "bad_signature" };
      }
    } else {
      lookupOnly = true;
    }
    const type = String(event?.type ?? "");
    const ack = { status: 200, body: '{"received":true}', type: "application/json" };
    if (!type.startsWith("checkout.session.")) return { ok: true, outcomes: [], ack };
    return { ok: true, outcomes: [sessionOutcome(event?.data?.object, type)], ack, lookupOnly };
  },

  async lookup(account, intent, http: Http) {
    if (!intent.providerRef) return null;
    const res = await http(`${API}/checkout/sessions/${encodeURIComponent(intent.providerRef)}`, {
      headers: auth(account),
    });
    return sessionOutcome(await jsonOrThrow(res, "Stripe session"));
  },

  async test(account, http) {
    const key = secret(account, "secretKey");
    if (!key) return { result: "fail", title: "Secret key not set", detail: "Set the secret key (sk_...)." };
    const r = await testFromStatus(await http(`${API}/balance`, { headers: auth(account) }), "Stripe accepted the secret key.");
    const sandbox = account.values.mode === "Sandbox";
    if (r.result === "ok" && sandbox !== key.startsWith("sk_test_") && !key.startsWith("rk_")) {
      return {
        result: "warn",
        title: "Key and mode differ",
        detail: `The account is in ${sandbox ? "Sandbox" : "Live"} mode but the key is a ${
          key.startsWith("sk_test_") ? "test" : "live"
        } key.`,
      };
    }
    return r;
  },
};
