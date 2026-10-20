// deno-lint-ignore-file no-explicit-any -- provider JSON is read field by field.
/**
 * Xendit: Invoices (https://developers.xendit.co/api-reference/#create-invoice)
 * — POST /v2/invoices with Basic secret_key: gives `invoice_url`. Callbacks
 * carry the account's verification token in the `x-callback-token` header.
 * Test or live follows the key (xnd_development_ / xnd_production_).
 */
import { safeEqual } from "./crypto.ts";
import {
  type Account,
  type Adapter,
  basic,
  type Incoming,
  jsonOrThrow,
  num,
  type Outcome,
  requireFields,
  secret,
  testFromStatus,
  type Verified,
} from "./types.ts";

const API = "https://api.xendit.co";
const auth = (a: Account) => ({ Authorization: basic(secret(a, "secretKey"), "") });

const statusOf = (s: unknown): Outcome["status"] => {
  const v = String(s ?? "").toUpperCase();
  return v === "PAID" || v === "SETTLED" ? "paid" : v === "EXPIRED" ? "expired" : "pending";
};

const invoiceOutcome = (i: any): Outcome => ({
  providerRef: i?.id,
  reference: i?.external_id,
  status: statusOf(i?.status),
  amount: num(i?.paid_amount ?? i?.amount),
  currency: i?.currency,
});

export const xendit: Adapter = {
  id: "xendit",
  name: "Xendit",
  ready: true,
  verified: true,
  notes: [
    "Invoices in MYR need a Xendit Malaysia account with MYR enabled.",
    "Without the callback verification token, every callback is checked by asking Xendit for the invoice.",
  ],
  requiredPublic: [],
  requiredSecrets: ["secretKey"],
  secretFields: ["secretKey", "callbackToken"],

  async createCheckout(account, input, http) {
    requireFields(this, account);
    const res = await http(`${API}/v2/invoices`, {
      method: "POST",
      headers: { ...auth(account), "Content-Type": "application/json" },
      body: JSON.stringify({
        external_id: input.reference,
        amount: input.amount,
        currency: input.currency,
        description: input.description,
        payer_email: input.customer.email || undefined,
        customer: {
          given_names: input.customer.name || undefined,
          email: input.customer.email || undefined,
          mobile_number: input.customer.phone || undefined,
        },
        success_redirect_url: input.returnUrl,
        failure_redirect_url: input.cancelUrl,
      }),
    });
    const i = await jsonOrThrow(res, "Xendit invoice");
    return { url: i.invoice_url, providerRef: i.id };
  },

  // deno-lint-ignore require-await
  async verify(account, req: Incoming): Promise<Verified> {
    const token = secret(account, "callbackToken");
    if (token && !safeEqual(req.headers.get("x-callback-token") ?? "", token)) return { ok: false, reason: "bad_token" };
    let body: any;
    try {
      body = JSON.parse(req.rawBody);
    } catch {
      return { ok: false, reason: "not_json" };
    }
    return { ok: true, outcomes: body?.external_id ? [invoiceOutcome(body)] : [], lookupOnly: !token };
  },

  async lookup(account, intent, http) {
    if (!intent.providerRef) return null;
    const res = await http(`${API}/v2/invoices/${encodeURIComponent(intent.providerRef)}`, { headers: auth(account) });
    return invoiceOutcome(await jsonOrThrow(res, "Xendit invoice"));
  },

  async test(account, http) {
    if (!secret(account, "secretKey")) return { result: "fail", title: "Secret key not set", detail: "Set the secret key." };
    return await testFromStatus(await http(`${API}/balance`, { headers: auth(account) }), "Xendit accepted the secret key.");
  },
};
