/**
 * iPay88 (Malaysia), ePayment entry page — the payer's browser posts a form.
 *   * Request signature (SignatureType SHA256):
 *       sha256(MerchantKey + MerchantCode + RefNo + Amount digits + Currency)
 *     where "Amount digits" is the amount with "." and "," taken out
 *     ("1,234.50" → "123450").
 *   * Response (ResponseURL and BackendURL):
 *       sha256(MerchantKey + MerchantCode + PaymentId + RefNo + Amount digits
 *              + Currency + Status)
 *     Status "1" paid, "0" failed. The backend post is answered "RECEIVEOK".
 *   * Requery: GET enquiry.asp?MerchantCode&RefNo&Amount → "00" when paid.
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
  type Verified,
} from "./types.ts";

const ENTRY = "https://payment.ipay88.com.my/ePayment/entry.asp";
const ENQUIRY = "https://payment.ipay88.com.my/ePayment/enquiry.asp";

/** iPay88's amount: "1,234.50". */
export function ipay88Amount(amount: number): string {
  const [whole, cents] = amount.toFixed(2).split(".");
  return `${whole.replace(/\B(?=(\d{3})+(?!\d))/g, ",")}.${cents}`;
}

export const ipay88Digits = (amount: string): string => amount.replace(/[.,]/g, "");

export const ipay88RequestSignature = (key: string, code: string, refNo: string, amount: string, currency: string) =>
  sha256Hex(`${key}${code}${refNo}${ipay88Digits(amount)}${currency}`);

export const ipay88ResponseSignature = (key: string, f: Record<string, string>) =>
  sha256Hex(
    `${key}${f.MerchantCode ?? ""}${f.PaymentId ?? ""}${f.RefNo ?? ""}${ipay88Digits(f.Amount ?? "")}${f.Currency ?? ""}${
      f.Status ?? ""
    }`,
  );

/** The merchant code, stored under the account's provider id. */
const code = (a: Account, provider: string) => pub(a, provider, "merchantCode");

export function ipay88Like(id: string, name: string, extraNotes: string[] = []): Adapter {
  return {
    id,
    name,
    ready: true,
    verified: false,
    notes: [
      "The signature formulas are iPay88's published SHA256 ones, but iPay88's documentation was not reachable to " +
      "confirm them, and a third-party library reports iPay88 moving to HMAC-SHA512 from 2025: confirm with iPay88 " +
      "before going live (a wrong signature is refused on iPay88's page, nothing is charged).",
      "iPay88 has no separate sandbox address here: its test accounts use the live entry page.",
      ...extraNotes,
    ],
    requiredPublic: ["merchantCode"],
    requiredSecrets: ["merchantKey"],
    secretFields: ["merchantKey"],

    async createCheckout(account, input) {
      requireFields(this, account);
      const amount = ipay88Amount(input.amount);
      const merchantCode = code(account, id);
      return {
        form: {
          action: ENTRY,
          fields: {
            MerchantCode: merchantCode,
            PaymentId: "",
            RefNo: input.reference,
            Amount: amount,
            Currency: input.currency,
            ProdDesc: input.description.slice(0, 100),
            UserName: input.customer.name || "GET.ride customer",
            UserEmail: input.customer.email,
            UserContact: input.customer.phone,
            Remark: "",
            Lang: "UTF-8",
            SignatureType: "SHA256",
            Signature: await ipay88RequestSignature(
              secret(account, "merchantKey"),
              merchantCode,
              input.reference,
              amount,
              input.currency,
            ),
            ResponseURL: input.returnUrl,
            BackendURL: input.webhookUrl,
          },
        },
      };
    },

    async verify(account, req: Incoming): Promise<Verified> {
      const f = Object.fromEntries(pairs(req.rawBody));
      if (!f.RefNo || !f.Signature) return { ok: false, reason: "no_payment" };
      if (f.MerchantCode !== code(account, id)) return { ok: false, reason: "other_merchant" };
      const expected = await ipay88ResponseSignature(secret(account, "merchantKey"), f);
      if (!safeEqual(f.Signature.toLowerCase(), expected)) return { ok: false, reason: "bad_signature" };
      const status: Outcome["status"] = f.Status === "1" ? "paid" : f.Status === "0" ? "failed" : "pending";
      return {
        ok: true,
        outcomes: [{ reference: f.RefNo, providerRef: f.TransId, status, amount: num(f.Amount), currency: f.Currency }],
        ack: ok("RECEIVEOK"),
      };
    },

    async lookup(account, intent, http) {
      const q = new URLSearchParams({
        MerchantCode: code(account, id),
        RefNo: intent.reference,
        Amount: ipay88Amount(intent.amount),
      });
      const res = await http(`${ENQUIRY}?${q}`);
      if (!res.ok) throw new Error(`iPay88 requery: HTTP ${res.status}`);
      const text = (await res.text()).trim();
      return { reference: intent.reference, status: text === "00" ? "paid" : "pending" };
    },

    test(account) {
      return Promise.resolve(fieldsOnlyTest(
        this,
        account,
        "iPay88 has no harmless check: open the RM 1.00 test checkout below; iPay88 refuses it if the code or key is wrong.",
      ));
    },
  };
}

export const ipay88 = ipay88Like("ipay88", "iPay88");
