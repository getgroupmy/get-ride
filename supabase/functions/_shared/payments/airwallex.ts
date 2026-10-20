// deno-lint-ignore-file no-explicit-any -- provider JSON is read field by field.
/**
 * Airwallex: an access token from POST /api/v1/authentication/login
 * (x-client-id + x-api-key), then a one-time payment link
 * (POST /api/v1/pa/payment_links/create) whose `url` is the hosted page.
 * Webhooks: x-signature = HMAC-SHA256 hex(webhook secret, x-timestamp + raw body).
 * Demo environment: api-demo.airwallex.com.
 */
import { hmacSha256Hex, sameHex } from "./crypto.ts";
import {
  type Account,
  type Adapter,
  type Http,
  type Incoming,
  jsonOrThrow,
  num,
  type Outcome,
  pub,
  requireFields,
  secret,
  type Verified,
} from "./types.ts";

const base = (a: Account) => (a.values.mode === "Sandbox" ? "https://api-demo.airwallex.com" : "https://api.airwallex.com");
/** A webhook older than five minutes is refused. */
export const AIRWALLEX_TOLERANCE_MS = 5 * 60 * 1000;

export async function airwallexToken(a: Account, http: Http): Promise<string> {
  const res = await http(`${base(a)}/api/v1/authentication/login`, {
    method: "POST",
    headers: { "x-client-id": pub(a, "airwallex", "clientId"), "x-api-key": secret(a, "apiKey") },
  });
  return (await jsonOrThrow(res, "Airwallex sign-in")).token;
}

export const airwallexSignature = (secretKey: string, timestamp: string, rawBody: string) =>
  hmacSha256Hex(secretKey, `${timestamp}${rawBody}`);

const linkStatus = (s: unknown): Outcome["status"] => {
  const v = String(s ?? "").toUpperCase();
  return v === "PAID" || v === "SUCCEEDED" ? "paid" : v === "EXPIRED" ? "expired" : "pending";
};

export const airwallex: Adapter = {
  id: "airwallex",
  name: "Airwallex",
  ready: true,
  verified: false,
  confirmPaid: true,
  notes: [
    "The webhook signature is Airwallex's documented one. The payment-link calls (create, the status values) could " +
    "not be checked against Airwallex's documentation from here: every payment is confirmed by reading the link " +
    "back, and one that reads wrong stays pending for an admin to see. Make a demo payment before going live.",
  ],
  requiredPublic: ["clientId"],
  requiredSecrets: ["apiKey"],
  secretFields: ["apiKey", "webhookSecret"],

  async createCheckout(account, input, http) {
    requireFields(this, account);
    const token = await airwallexToken(account, http);
    const res = await http(`${base(account)}/api/v1/pa/payment_links/create`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        amount: input.amount,
        currency: input.currency,
        title: input.description.slice(0, 100),
        reference: input.reference,
        reusable: false,
        collectable_shopper_info: { phone_number: false, shipping_address: false },
      }),
    });
    const l = await jsonOrThrow(res, "Airwallex payment link");
    return { url: l.url, providerRef: l.id };
  },

  async verify(account, req: Incoming): Promise<Verified> {
    const whsec = secret(account, "webhookSecret");
    if (whsec) {
      const ts = req.headers.get("x-timestamp") ?? "";
      if (!ts || Math.abs(req.now * 1000 - Number(ts)) > AIRWALLEX_TOLERANCE_MS) return { ok: false, reason: "stale" };
      const sig = req.headers.get("x-signature") ?? "";
      if (!sig || !sameHex(sig, await airwallexSignature(whsec, ts, req.rawBody))) return { ok: false, reason: "bad_signature" };
    }
    let event: any;
    try {
      event = JSON.parse(req.rawBody);
    } catch {
      return { ok: false, reason: "not_json" };
    }
    const o = event?.data?.object ?? {};
    const name = String(event?.name ?? "");
    const outcomes: Outcome[] = name.startsWith("payment_link.") || name.startsWith("payment_intent.")
      ? [{
        providerRef: name.startsWith("payment_link.") ? o.id : undefined,
        reference: o.reference ?? o.merchant_order_id,
        status: name.endsWith(".paid") || name.endsWith(".succeeded") ? "paid" : "pending",
        amount: num(o.amount),
        currency: o.currency,
        event: name,
      }]
      : [];
    return { ok: true, outcomes, lookupOnly: !whsec };
  },

  async lookup(account, intent, http) {
    if (!intent.providerRef) return null;
    const token = await airwallexToken(account, http);
    const res = await http(`${base(account)}/api/v1/pa/payment_links/${encodeURIComponent(intent.providerRef)}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    const l = await jsonOrThrow(res, "Airwallex payment link");
    return { providerRef: l.id, reference: l.reference, status: linkStatus(l.status), amount: num(l.amount), currency: l.currency };
  },

  async test(account, http) {
    if (!pub(account, "airwallex", "clientId") || !secret(account, "apiKey")) {
      return { result: "fail", title: "Credentials missing", detail: "Set the client ID and the API key." };
    }
    try {
      await airwallexToken(account, http);
      return { result: "ok", title: "Connected", detail: "Airwallex accepted the client ID and API key." };
    } catch (e) {
      return { result: "fail", title: "Credentials not accepted", detail: (e as Error).message };
    }
  },
};
