/**
 * Fiuu (formerly Razer Merchant Services / MOLPay), hosted payment page.
 *   * Request: <payment URL>/<merchant ID>/ with amount, orderid, bill_name,
 *     bill_email, bill_mobile, bill_desc, country, currency, returnurl,
 *     callbackurl, cancelurl and vcode = md5(amount + merchantID + orderid +
 *     verify key).
 *   * Return / notification / callback: skey, with
 *       key0 = md5(tranID + orderid + status + domain + amount + currency)
 *       key1 = md5(paydate + domain + key0 + appcode + secret key)
 *     and skey == key1. status "00" paid, "11" failed, "22" pending. A callback
 *     (nbcb=1) is answered "CBTOKEN:MPSTATOK".
 */
import { md5Hex, sameHex } from "./crypto.ts";
import {
  type Account,
  type Adapter,
  fieldsOnlyTest,
  type Incoming,
  num,
  ok,
  type Outcome,
  pairs,
  pub,
  requireFields,
  secret,
  twoDp,
  type Verified,
} from "./types.ts";

/** Not confirmed (Fiuu's documentation was not reachable): set the account's Payment URL to override. */
export const FIUU_DEFAULT_URL = { live: "https://pay.fiuu.com/RMS/pay", sandbox: "https://sandbox-payment.fiuu.com/RMS/pay" };

export function fiuuPayUrl(a: Account): string {
  const set = pub(a, "fiuu", "paymentUrl").replace(/\/+$/, "");
  const root = set || (a.values.mode === "Sandbox" ? FIUU_DEFAULT_URL.sandbox : FIUU_DEFAULT_URL.live);
  return `${root}/${encodeURIComponent(pub(a, "fiuu", "merchantId"))}/`;
}

export const fiuuVcode = (amount: string, merchantId: string, orderId: string, verifyKey: string): string =>
  md5Hex(`${amount}${merchantId}${orderId}${verifyKey}`);

export function fiuuSkey(f: Record<string, string>, secretKey: string): string {
  const key0 = md5Hex(`${f.tranID ?? ""}${f.orderid ?? ""}${f.status ?? ""}${f.domain ?? ""}${f.amount ?? ""}${f.currency ?? ""}`);
  return md5Hex(`${f.paydate ?? ""}${f.domain ?? ""}${key0}${f.appcode ?? ""}${secretKey}`);
}

const statusOf = (s: string): Outcome["status"] => (s === "00" ? "paid" : s === "11" ? "failed" : "pending");

export const fiuu: Adapter = {
  id: "fiuu",
  name: "Fiuu (Razer Merchant Services)",
  ready: true,
  verified: false,
  notes: [
    "The vcode and skey formulas are Fiuu's long-standing ones, but Fiuu's documentation was not reachable to " +
    "confirm them or the payment page address: the default is https://pay.fiuu.com/RMS/pay/<merchant ID>/ " +
    "(sandbox https://sandbox-payment.fiuu.com/RMS/pay/…). Set Payment URL on the account if Fiuu gave you another.",
    "In the Fiuu portal, turn on the callback (IPN) and set the Callback URL shown here.",
    "Fiuu has no status lookup here: only a signed return or callback marks a payment paid.",
  ],
  requiredPublic: ["merchantId"],
  requiredSecrets: ["verifyKey", "secretKey"],
  secretFields: ["verifyKey", "secretKey"],

  // deno-lint-ignore require-await
  async createCheckout(account, input) {
    requireFields(this, account);
    const amount = twoDp(input.amount);
    const merchantId = pub(account, "fiuu", "merchantId");
    const q = new URLSearchParams({
      amount,
      orderid: input.reference,
      bill_name: input.customer.name || "GET.ride customer",
      bill_email: input.customer.email,
      bill_mobile: input.customer.phone,
      bill_desc: input.description,
      country: "MY",
      currency: input.currency,
      returnurl: input.returnUrl,
      callbackurl: input.webhookUrl,
      cancelurl: input.cancelUrl,
      vcode: fiuuVcode(amount, merchantId, input.reference, secret(account, "verifyKey")),
    });
    return { url: `${fiuuPayUrl(account)}?${q}` };
  },

  // deno-lint-ignore require-await
  async verify(account, req: Incoming): Promise<Verified> {
    const f = Object.fromEntries(req.rawBody ? pairs(req.rawBody) : [...req.query.entries()]);
    if (!f.orderid || !f.skey) return { ok: false, reason: "no_payment" };
    if (f.domain !== pub(account, "fiuu", "merchantId")) return { ok: false, reason: "other_merchant" };
    if (!sameHex(f.skey, fiuuSkey(f, secret(account, "secretKey")))) return { ok: false, reason: "bad_signature" };
    return {
      ok: true,
      outcomes: [{
        reference: f.orderid,
        providerRef: f.tranID,
        status: statusOf(f.status),
        amount: num(f.amount),
        // Fiuu writes ringgit as "RM".
        currency: f.currency?.toUpperCase() === "RM" ? "MYR" : f.currency?.toUpperCase(),
      }],
      ack: f.nbcb === "1" ? ok("CBTOKEN:MPSTATOK") : ok(),
    };
  },

  test(account) {
    return Promise.resolve(fieldsOnlyTest(
      this,
      account,
      "Fiuu has no harmless check: open the RM 1.00 test checkout below; Fiuu's page refuses it if the verify key is wrong.",
    ));
  },
};
