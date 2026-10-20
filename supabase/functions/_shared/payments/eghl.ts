/**
 * eGHL (GHL, Malaysia), hosted payment page (TransactionType SALE).
 *   * HashValue = sha256(Password + ServiceID + PaymentID + MerchantReturnURL
 *       + MerchantApprovalURL + MerchantUnApprovalURL + MerchantCallBackURL
 *       + Amount + CurrencyCode + CustIP + PageTimeout + CardNo + Token)
 *   * Response HashValue2 = sha256(Password + TxnID + ServiceID + PaymentID
 *       + TxnStatus + Amount + CurrencyCode + AuthCode + OrderNumber
 *       + Param6 + Param7)
 *     TxnStatus 0 paid, 1 failed, 2 pending. The callback is answered "OK".
 * The field order is the one the `eghl` npm library (redapesolutions) uses.
 */
import { safeEqual, sha256Hex } from "./crypto.ts";
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

/** Not confirmed (eGHL's documentation was not reachable): set the account's Payment URL to override. */
export const EGHL_DEFAULT_URL = {
  live: "https://securepay.e-ghl.com/IPG/Payment.aspx",
  sandbox: "https://test2pay.ghl.com/IPGSG/Payment.aspx",
};

export const eghlRequestHash = (password: string, f: Record<string, string>) =>
  sha256Hex(
    password +
      ["ServiceID", "PaymentID", "MerchantReturnURL", "MerchantApprovalURL", "MerchantUnApprovalURL", "MerchantCallBackURL",
        "Amount", "CurrencyCode", "CustIP", "PageTimeout", "CardNo", "Token"].map((k) => f[k] ?? "").join(""),
  );

export const eghlResponseHash = (password: string, f: Record<string, string>) =>
  sha256Hex(
    password +
      ["TxnID", "ServiceID", "PaymentID", "TxnStatus", "Amount", "CurrencyCode", "AuthCode", "OrderNumber", "Param6",
        "Param7"].map((k) => f[k] ?? "").join(""),
  );

const statusOf = (s: string): Outcome["status"] => (s === "0" ? "paid" : s === "1" ? "failed" : "pending");

export const eghl: Adapter = {
  id: "eghl",
  name: "eGHL",
  ready: true,
  verified: false,
  notes: [
    "The hash field order follows the eGHL npm library, not eGHL's own documentation (not reachable from here); " +
    "the payment page addresses are the usual ones (live securepay.e-ghl.com, test test2pay.ghl.com): set " +
    "Payment URL on the account if eGHL gave you others.",
    "eGHL has no status lookup here: only a signed return or callback marks a payment paid.",
  ],
  requiredPublic: ["serviceId"],
  requiredSecrets: ["password"],
  secretFields: ["password"],

  async createCheckout(account: Account, input) {
    requireFields(this, account);
    const set = pub(account, "eghl", "paymentUrl");
    const action = set || (account.values.mode === "Sandbox" ? EGHL_DEFAULT_URL.sandbox : EGHL_DEFAULT_URL.live);
    const fields: Record<string, string> = {
      TransactionType: "SALE",
      PymtMethod: "ANY",
      ServiceID: pub(account, "eghl", "serviceId"),
      PaymentID: input.reference,
      OrderNumber: input.reference,
      PaymentDesc: input.description.slice(0, 100),
      MerchantReturnURL: input.returnUrl,
      MerchantCallBackURL: input.webhookUrl,
      Amount: twoDp(input.amount),
      CurrencyCode: input.currency,
      CustIP: input.ip || "127.0.0.1",
      CustName: input.customer.name || "GET.ride customer",
      CustEmail: input.customer.email,
      CustPhone: input.customer.phone,
      PageTimeout: "900",
    };
    fields.HashValue = await eghlRequestHash(secret(account, "password"), fields);
    return { url: `${action}?${new URLSearchParams(fields)}` };
  },

  async verify(account, req: Incoming): Promise<Verified> {
    const f = Object.fromEntries(req.rawBody ? pairs(req.rawBody) : [...req.query.entries()]);
    if (!f.PaymentID || !f.HashValue2) return { ok: false, reason: "no_payment" };
    if (f.ServiceID !== pub(account, "eghl", "serviceId")) return { ok: false, reason: "other_merchant" };
    const expected = await eghlResponseHash(secret(account, "password"), f);
    if (!safeEqual(f.HashValue2.toLowerCase(), expected)) return { ok: false, reason: "bad_signature" };
    return {
      ok: true,
      outcomes: [{
        reference: f.OrderNumber || f.PaymentID,
        providerRef: f.TxnID,
        status: statusOf(f.TxnStatus),
        amount: num(f.Amount),
        currency: f.CurrencyCode,
      }],
      ack: ok(),
    };
  },

  test(account) {
    return Promise.resolve(fieldsOnlyTest(
      this,
      account,
      "eGHL has no harmless check: open the RM 1.00 test checkout below; eGHL refuses it if the service ID or password is wrong.",
    ));
  },
};
