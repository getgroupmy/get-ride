// deno-lint-ignore-file no-explicit-any -- provider JSON is read field by field.
/**
 * PayPal: Orders v2 (https://developer.paypal.com/docs/api/orders/v2/).
 * An order is created with the payer's return / cancel addresses; the payer
 * approves it on PayPal; the order is then captured (here, when the browser
 * comes back, a CHECKOUT.ORDER.APPROVED webhook arrives, or the app asks).
 * Webhooks are verified by PayPal itself:
 * POST /v1/notifications/verify-webhook-signature with the transmission
 * headers, the account's webhook ID and the event → verification_status
 * "SUCCESS" (https://developer.paypal.com/api/rest/webhooks/rest/#link-verifysignature).
 */
import {
  type Account,
  type Adapter,
  basic,
  type Http,
  type Incoming,
  jsonOrThrow,
  num,
  type Outcome,
  pub,
  requireFields,
  secret,
  twoDp,
  type Verified,
} from "./types.ts";

const base = (a: Account) =>
  a.values.mode === "Sandbox" ? "https://api-m.sandbox.paypal.com" : "https://api-m.paypal.com";

export async function paypalToken(a: Account, http: Http): Promise<string> {
  const res = await http(`${base(a)}/v1/oauth2/token`, {
    method: "POST",
    headers: {
      Authorization: basic(pub(a, "paypal", "clientId"), secret(a, "clientSecret")),
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: "grant_type=client_credentials",
  });
  return (await jsonOrThrow(res, "PayPal sign-in")).access_token;
}

/** The order's state as an outcome; a capture's amount when there is one. */
export function orderOutcome(o: any): Outcome {
  const unit = o?.purchase_units?.[0];
  const capture = unit?.payments?.captures?.[0];
  const amount = capture?.amount ?? unit?.amount;
  const st = String(o?.status ?? "");
  const captureSt = String(capture?.status ?? "");
  let status: Outcome["status"] = "pending";
  if (st === "COMPLETED" && (!capture || captureSt === "COMPLETED")) status = "paid";
  else if (st === "VOIDED") status = "cancelled";
  else if (captureSt === "DECLINED" || captureSt === "FAILED") status = "failed";
  return {
    providerRef: o?.id,
    reference: unit?.custom_id ?? unit?.reference_id,
    status,
    amount: num(amount?.value),
    currency: amount?.currency_code,
  };
}

export const paypal: Adapter = {
  id: "paypal",
  name: "PayPal",
  ready: true,
  verified: true,
  notes: [
    "PayPal takes MYR only on a Malaysian PayPal business account.",
    "Without the webhook ID, every webhook is checked by asking PayPal for the order.",
  ],
  requiredPublic: ["clientId"],
  requiredSecrets: ["clientSecret"],
  secretFields: ["clientSecret"],

  async createCheckout(account, input, http) {
    requireFields(this, account);
    const token = await paypalToken(account, http);
    const res = await http(`${base(account)}/v2/checkout/orders`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        "PayPal-Request-Id": `order-${input.reference}`,
      },
      body: JSON.stringify({
        intent: "CAPTURE",
        purchase_units: [{
          reference_id: input.reference,
          custom_id: input.reference,
          invoice_id: input.reference,
          description: input.description.slice(0, 127),
          amount: { currency_code: input.currency, value: twoDp(input.amount) },
        }],
        payment_source: {
          paypal: {
            experience_context: {
              brand_name: "GET.ride",
              shipping_preference: "NO_SHIPPING",
              user_action: "PAY_NOW",
              return_url: input.returnUrl,
              cancel_url: input.cancelUrl,
            },
          },
        },
      }),
    });
    const o = await jsonOrThrow(res, "PayPal order");
    const link = (o.links ?? []).find((l: any) => l.rel === "payer-action" || l.rel === "approve");
    if (!link?.href) throw new Error("PayPal order has no approval link");
    return { url: link.href, providerRef: o.id };
  },

  async verify(account, req: Incoming, http): Promise<Verified> {
    let event: any;
    try {
      event = JSON.parse(req.rawBody);
    } catch {
      return { ok: false, reason: "not_json" };
    }
    const webhookId = pub(account, "paypal", "webhookId");
    let lookupOnly = true;
    if (webhookId) {
      const h = (n: string) => req.headers.get(n) ?? "";
      const token = await paypalToken(account, http);
      const res = await http(`${base(account)}/v1/notifications/verify-webhook-signature`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        // The event exactly as received, so PayPal checks the bytes it signed.
        body: `{"auth_algo":${JSON.stringify(h("paypal-auth-algo"))},"cert_url":${JSON.stringify(h("paypal-cert-url"))},` +
          `"transmission_id":${JSON.stringify(h("paypal-transmission-id"))},` +
          `"transmission_sig":${JSON.stringify(h("paypal-transmission-sig"))},` +
          `"transmission_time":${JSON.stringify(h("paypal-transmission-time"))},` +
          `"webhook_id":${JSON.stringify(webhookId)},"webhook_event":${req.rawBody}}`,
      });
      const v = await jsonOrThrow(res, "PayPal webhook check");
      if (v?.verification_status !== "SUCCESS") return { ok: false, reason: "bad_signature" };
      lookupOnly = false;
    }
    const type = String(event?.event_type ?? "");
    const r = event?.resource ?? {};
    const outcomes: Outcome[] = [];
    if (type === "CHECKOUT.ORDER.APPROVED" || type === "CHECKOUT.ORDER.COMPLETED") {
      // Approved still has to be captured: the lookup does that.
      outcomes.push({ ...orderOutcome(r), status: type === "CHECKOUT.ORDER.COMPLETED" ? "paid" : "pending", event: type });
    } else if (type.startsWith("PAYMENT.CAPTURE.")) {
      const status: Outcome["status"] = type === "PAYMENT.CAPTURE.COMPLETED"
        ? "paid"
        : type === "PAYMENT.CAPTURE.DENIED" || type === "PAYMENT.CAPTURE.DECLINED"
        ? "failed"
        : "pending";
      outcomes.push({
        providerRef: r?.supplementary_data?.related_ids?.order_id,
        reference: r?.custom_id ?? r?.invoice_id,
        status,
        amount: num(r?.amount?.value),
        currency: r?.amount?.currency_code,
        event: type,
      });
    }
    // An approval is always followed by a lookup (it captures).
    const approve = type === "CHECKOUT.ORDER.APPROVED";
    return { ok: true, outcomes, ack: { status: 200, body: "OK", type: "text/plain" }, lookupOnly: lookupOnly || approve };
  },

  async lookup(account, intent, http) {
    if (!intent.providerRef) return null;
    const token = await paypalToken(account, http);
    const url = `${base(account)}/v2/checkout/orders/${encodeURIComponent(intent.providerRef)}`;
    let o = await jsonOrThrow(await http(url, { headers: { Authorization: `Bearer ${token}` } }), "PayPal order");
    if (o?.status === "APPROVED") {
      const res = await http(`${url}/capture`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
          "PayPal-Request-Id": `capture-${intent.reference}`,
        },
        body: "{}",
      });
      // 422 ORDER_ALREADY_CAPTURED: read it again.
      o = res.status === 422
        ? await jsonOrThrow(await http(url, { headers: { Authorization: `Bearer ${token}` } }), "PayPal order")
        : await jsonOrThrow(res, "PayPal capture");
    }
    return orderOutcome(o);
  },

  async test(account, http) {
    if (!pub(account, "paypal", "clientId") || !secret(account, "clientSecret")) {
      return { result: "fail", title: "Credentials missing", detail: "Set the client ID and the client secret." };
    }
    try {
      await paypalToken(account, http);
      return { result: "ok", title: "Connected", detail: "PayPal accepted the client ID and secret." };
    } catch (e) {
      return { result: "fail", title: "Credentials not accepted", detail: (e as Error).message };
    }
  },
};
