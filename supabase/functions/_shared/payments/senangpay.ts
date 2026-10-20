// deno-lint-ignore-file no-explicit-any -- provider JSON is read field by field.
/**
 * SenangPay (Malaysia), with the account's hash type set to SHA256 in the
 * SenangPay dashboard:
 *   * payment page https://app.senangpay.my/payment/<merchant ID> (sandbox
 *     sandbox.senangpay.my) with detail, amount, order_id, name, email,
 *     phone and hash = HMAC-SHA256(secret, secret + detail + amount + order_id);
 *   * return and callback: status_id, order_id, transaction_id, msg and
 *     hash = HMAC-SHA256(secret, secret + status_id + order_id +
 *     transaction_id + msg); status_id 1 paid, 0 failed; the callback is
 *     answered "OK";
 *   * order status: /apiv1/query_order_status?merchant_id&order_id&hash with
 *     hash = HMAC-SHA256(secret, merchant_id + secret + order_id).
 * The return and callback addresses are set once in the dashboard, not per
 * payment.
 */
import { hmacSha256Hex, sameHex } from "./crypto.ts";
import {
  type Account,
  type Adapter,
  fieldsOnlyTest,
  type Incoming,
  num,
  ok,
  type Outcome,
  pairs,
  plainText,
  pub,
  requireFields,
  secret,
  twoDp,
  type Verified,
} from "./types.ts";

const host = (a: Account) => (a.values.mode === "Sandbox" ? "https://sandbox.senangpay.my" : "https://app.senangpay.my");

export const senangpayRequestHash = (key: string, detail: string, amount: string, orderId: string) =>
  hmacSha256Hex(key, `${key}${detail}${amount}${orderId}`);

export const senangpayResponseHash = (key: string, f: Record<string, string>) =>
  hmacSha256Hex(key, `${key}${f.status_id ?? ""}${f.order_id ?? ""}${f.transaction_id ?? ""}${f.msg ?? ""}`);

export const senangpay: Adapter = {
  id: "senangpay",
  name: "SenangPay",
  ready: true,
  verified: false,
  dashboardUrls: true,
  notes: [
    "In the SenangPay dashboard set the hash type to SHA256 and paste the Return URL and Callback URL shown here.",
    "The request hash and the order-status call are as SenangPay's guide and a published integration use them; the " +
    "return hash (status_id, order_id, transaction_id, msg) and the order-status answer could not be confirmed " +
    "against SenangPay's own documentation (not reachable from here). A wrong guess refuses the return as unsigned " +
    "(the payment stays pending for an admin to see); it never credits an unpaid one.",
  ],
  requiredPublic: ["merchantId"],
  requiredSecrets: ["secretKey"],
  secretFields: ["secretKey"],

  async createCheckout(account, input) {
    requireFields(this, account);
    const key = secret(account, "secretKey");
    const detail = plainText(input.description, 100);
    const amount = twoDp(input.amount);
    const q = new URLSearchParams({
      detail,
      amount,
      order_id: input.reference,
      name: input.customer.name || "GET.ride customer",
      email: input.customer.email,
      phone: input.customer.phone,
      hash: await senangpayRequestHash(key, detail, amount, input.reference),
    });
    return { url: `${host(account)}/payment/${encodeURIComponent(pub(account, "senangpay", "merchantId"))}?${q}` };
  },

  async verify(account, req: Incoming): Promise<Verified> {
    const f = Object.fromEntries(req.rawBody ? pairs(req.rawBody) : [...req.query.entries()]);
    if (!f.order_id || !f.hash) return { ok: false, reason: "no_payment" };
    if (!sameHex(f.hash, await senangpayResponseHash(secret(account, "secretKey"), f))) {
      return { ok: false, reason: "bad_signature" };
    }
    const status: Outcome["status"] = f.status_id === "1" ? "paid" : f.status_id === "0" ? "failed" : "pending";
    return { ok: true, outcomes: [{ reference: f.order_id, providerRef: f.transaction_id, status }], ack: ok() };
  },

  async lookup(account, intent, http) {
    const key = secret(account, "secretKey");
    const merchant = pub(account, "senangpay", "merchantId");
    const q = new URLSearchParams({
      merchant_id: merchant,
      order_id: intent.reference,
      hash: await hmacSha256Hex(key, `${merchant}${key}${intent.reference}`),
    });
    const res = await http(`${host(account)}/apiv1/query_order_status?${q}`);
    if (!res.ok) throw new Error(`SenangPay order status: HTTP ${res.status}`);
    const body = await res.json().catch(() => null);
    const rows: any[] = Array.isArray(body?.data) ? body.data : [];
    const paid = rows.find((r) => String(r?.payment_info?.status ?? r?.status ?? "").toLowerCase() === "paid");
    return {
      reference: intent.reference,
      status: paid ? "paid" : "pending",
      amount: num(paid?.payment_info?.amount ?? paid?.amount),
    };
  },

  test(account) {
    return Promise.resolve(fieldsOnlyTest(
      this,
      account,
      "SenangPay has no harmless check: open the RM 1.00 test checkout below; SenangPay refuses it if the secret key is wrong.",
    ));
  },
};
