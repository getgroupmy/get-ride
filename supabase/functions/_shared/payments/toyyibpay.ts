// deno-lint-ignore-file no-explicit-any -- provider JSON is read field by field.
/**
 * toyyibPay (Malaysia): createBill (form POST, user secret key + category
 * code) → [{"BillCode": "…"}]; the payer pays at https://toyyibpay.com/<BillCode>
 * (dev.toyyibpay.com in sandbox). The callback isn't trusted on its own: the
 * bill's transactions are read back with getBillTransactions
 * (billpaymentStatus "1" = paid) before anything counts.
 */
import {
  type Account,
  type Adapter,
  formBody,
  type Incoming,
  jsonOrThrow,
  minor,
  msisdn,
  num,
  ok,
  pairs,
  PaymentError,
  plainText,
  pub,
  requireFields,
  secret,
  type Verified,
} from "./types.ts";

const host = (a: Account) => (a.values.mode === "Sandbox" ? "https://dev.toyyibpay.com" : "https://toyyibpay.com");

export const toyyibpay: Adapter = {
  id: "toyyibpay",
  name: "toyyibPay",
  ready: true,
  verified: false,
  notes: [
    "createBill and getBillTransactions are as toyyibPay's published SDKs use them; toyyibPay's own API reference was " +
    "not reachable to confirm them. The callback's own hash is not checked (its formula could not be confirmed): " +
    "every callback is checked by reading the bill's transactions back from toyyibPay.",
  ],
  requiredPublic: ["categoryCode"],
  requiredSecrets: ["userSecretKey"],
  secretFields: ["userSecretKey"],

  async createCheckout(account, input, http) {
    requireFields(this, account);
    const res = await http(`${host(account)}/index.php/api/createBill`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: formBody({
        userSecretKey: secret(account, "userSecretKey"),
        categoryCode: pub(account, "toyyibpay", "categoryCode"),
        billName: plainText(input.description, 30) || "GET ride",
        billDescription: plainText(input.description, 100) || "GET ride",
        billPriceSetting: 1,
        billPayorInfo: 1,
        billAmount: minor(input.amount),
        billReturnUrl: input.returnUrl,
        billCallbackUrl: input.webhookUrl,
        billExternalReferenceNo: input.reference,
        billTo: input.customer.name || "GET.ride customer",
        billEmail: input.customer.email,
        billPhone: msisdn(input.customer.phone),
        billPaymentChannel: 2,
        billChargeToCustomer: "",
      }),
    });
    const body = await jsonOrThrow(res, "toyyibPay createBill");
    const code = Array.isArray(body) ? body[0]?.BillCode : undefined;
    if (!code) throw new PaymentError("provider_error", `toyyibPay createBill: ${JSON.stringify(body).slice(0, 200)}`, 502);
    return { url: `${host(account)}/${code}`, providerRef: code };
  },

  verify(_account, req: Incoming): Promise<Verified> {
    const f = Object.fromEntries(req.rawBody ? pairs(req.rawBody) : [...req.query.entries()]);
    const billCode = f.billcode ?? f.billCode ?? f.BillCode;
    if (!billCode) return Promise.resolve({ ok: false, reason: "no_bill" });
    return Promise.resolve({
      ok: true,
      outcomes: [{ providerRef: billCode, reference: f.order_id || undefined, status: "pending" }],
      ack: ok(),
      lookupOnly: true,
    });
  },

  async lookup(account, intent, http) {
    if (!intent.providerRef) return null;
    const res = await http(`${host(account)}/index.php/api/getBillTransactions`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: formBody({ billCode: intent.providerRef }),
    });
    const rows = await jsonOrThrow(res, "toyyibPay getBillTransactions");
    const list: any[] = Array.isArray(rows) ? rows : [];
    const paid = list.find((r) => String(r?.billpaymentStatus) === "1");
    return {
      providerRef: intent.providerRef,
      reference: paid?.billExternalReferenceNo ?? undefined,
      status: paid ? "paid" : "pending",
      amount: num(paid?.billpaymentAmount),
      currency: "MYR",
    };
  },

  async test(account, http) {
    if (!secret(account, "userSecretKey") || !pub(account, "toyyibpay", "categoryCode")) {
      return { result: "fail", title: "Credentials missing", detail: "Set the user secret key and the category code." };
    }
    const res = await http(`${host(account)}/index.php/api/getCategoryDetails`, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: formBody({
        userSecretKey: secret(account, "userSecretKey"),
        categoryCode: pub(account, "toyyibpay", "categoryCode"),
      }),
    });
    const text = (await res.text()).slice(0, 300);
    if (res.ok && /categoryName/i.test(text)) {
      return { result: "ok", title: "Connected", detail: "toyyibPay found the category for this secret key." };
    }
    return { result: "fail", title: "Not accepted", detail: `HTTP ${res.status}. ${text}` };
  },
};
