/**
 * Each adapter: the request it sends to open a checkout, and the callbacks
 * it accepts and refuses. Signature fixtures were computed independently
 * with Python's hashlib / hmac from the formulas in each adapter's header
 * (Adyen's and the JOSE ones in crypto_test.ts are the providers' own
 * published examples).
 *
 *     deno test supabase/functions/_shared/payments/adapters_test.ts
 */
import { assert, assertEquals, assertRejects, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import { adyen, adyenSource } from "./adyen.ts";
import { airwallex } from "./airwallex.ts";
import { billplz, billplzSource } from "./billplz.ts";
import { curlec } from "./curlec.ts";
import { eghl, eghlRequestHash } from "./eghl.ts";
import { fiuu, fiuuSkey, fiuuVcode } from "./fiuu.ts";
import { hitpay, hitpaySource } from "./hitpay.ts";
import { ipay88, ipay88Amount, ipay88RequestSignature, ipay88ResponseSignature } from "./ipay88.ts";
import { paydibs } from "./not_ready.ts";
import { paypal } from "./paypal.ts";
import { senangpay, senangpayRequestHash, senangpayResponseHash } from "./senangpay.ts";
import { stripe, stripeSignatureValid } from "./stripe.ts";
import { toyyibpay } from "./toyyibpay.ts";
import { readJwt, signJwt, twoc2p } from "./twoc2p.ts";
import type { Account, CheckoutInput, Http, Incoming } from "./types.ts";
import { xendit } from "./xendit.ts";

const REF = "GR2610200000000001";

function account(provider: string, pub: Record<string, string>, secrets: Record<string, string>, mode = "Live"): Account {
  return {
    id: "11111111-1111-1111-1111-111111111111",
    active: true,
    values: {
      providerId: provider,
      mode,
      ...Object.fromEntries(Object.entries(pub).map(([k, v]) => [`${provider}_${k}`, v])),
    },
    secrets,
  };
}

const input: CheckoutInput = {
  reference: REF,
  amount: 50,
  currency: "MYR",
  description: "GET.wallet top up",
  customer: { name: "Aminah", email: "a@example.com", phone: "+60123456789" },
  returnUrl: "https://x/r",
  cancelUrl: "https://x/r?cancel=1",
  webhookUrl: "https://x/w",
  testMode: false,
  ip: "1.2.3.4",
};

interface Seen {
  url: string;
  init?: RequestInit;
}

/** A fake network: answers in order, records what was sent. */
function net(...answers: Array<[number, unknown]>): { http: Http; seen: Seen[] } {
  const seen: Seen[] = [];
  const http: Http = (url, init) => {
    seen.push({ url, init });
    const [status, body] = answers.shift() ?? [500, { error: "unexpected" }];
    return Promise.resolve(
      new Response(typeof body === "string" ? body : JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
      }),
    );
  };
  return { http, seen };
}

function req(rawBody: string, headers: Record<string, string> = {}, query = "", now = 1700000000): Incoming {
  return {
    method: rawBody ? "POST" : "GET",
    headers: new Headers(headers),
    query: new URLSearchParams(query),
    rawBody,
    now,
  };
}

const formOf = (init?: RequestInit) => new URLSearchParams(String(init?.body ?? ""));
const header = (init: RequestInit | undefined, name: string) => new Headers(init?.headers).get(name);

// ---- Stripe ------------------------------------------------------------------------------------------

Deno.test("stripe: checkout session request", async () => {
  const { http, seen } = net([200, { id: "cs_1", url: "https://checkout.stripe.com/c/cs_1" }]);
  const a = account("stripe", {}, { secretKey: "sk_test_x" });
  const c = await stripe.createCheckout(a, input, http);
  assertEquals(c, { url: "https://checkout.stripe.com/c/cs_1", providerRef: "cs_1" });
  assertEquals(seen[0].url, "https://api.stripe.com/v1/checkout/sessions");
  assertEquals(header(seen[0].init, "authorization"), "Bearer sk_test_x");
  const f = formOf(seen[0].init);
  assertEquals(f.get("line_items[0][price_data][unit_amount]"), "5000");
  assertEquals(f.get("line_items[0][price_data][currency]"), "myr");
  assertEquals(f.get("client_reference_id"), REF);
  assertEquals(f.get("success_url"), "https://x/r");
  assertEquals(f.get("mode"), "payment");
});

Deno.test("stripe: webhook signature", async () => {
  const body = '{"id":"evt_1","type":"checkout.session.completed"}';
  const sig = "a13d4b1f9003bc2fb6c06224e878b6056185eaa50d40e1e7dc05517f8af41d7b";
  assert(await stripeSignatureValid(body, `t=1700000000,v1=${sig}`, "whsec_test_secret", 1700000000));
  assert(await stripeSignatureValid(body, `t=1700000000,v1=00,v1=${sig}`, "whsec_test_secret", 1700000100));
  assert(!(await stripeSignatureValid(body, `t=1700000000,v1=${sig}`, "whsec_other", 1700000000)));
  assert(!(await stripeSignatureValid(body + " ", `t=1700000000,v1=${sig}`, "whsec_test_secret", 1700000000)));
  // Older than the five-minute tolerance.
  assert(!(await stripeSignatureValid(body, `t=1700000000,v1=${sig}`, "whsec_test_secret", 1700000301)));
});

Deno.test("stripe: a signed completed session is paid; an unsigned one needs a lookup", async () => {
  const event = {
    type: "checkout.session.completed",
    data: { object: { id: "cs_1", client_reference_id: REF, payment_status: "paid", amount_total: 5000, currency: "myr" } },
  };
  const body = JSON.stringify(event);
  const { hmacSha256Hex } = await import("./crypto.ts");
  const sig = await hmacSha256Hex("whsec_s", `1700000000.${body}`);
  const a = account("stripe", {}, { secretKey: "sk", webhookSecret: "whsec_s" });
  const v = await stripe.verify(a, req(body, { "stripe-signature": `t=1700000000,v1=${sig}` }), net().http);
  assert(v.ok);
  assertEquals(v.outcomes, [{
    reference: REF,
    providerRef: "cs_1",
    status: "paid",
    amount: 50,
    currency: "MYR",
    event: "checkout.session.completed",
  }]);
  assert(!v.lookupOnly);
  const bad = await stripe.verify(a, req(body, { "stripe-signature": "t=1700000000,v1=00" }), net().http);
  assert(!bad.ok);
  const unsigned = await stripe.verify(account("stripe", {}, { secretKey: "sk" }), req(body), net().http);
  assert(unsigned.ok && unsigned.lookupOnly);
});

// ---- Billplz -----------------------------------------------------------------------------------------

const BILLPLZ_KEY = "S-0Sq67GFD9Y5iXmi5iXMKsA";
const billplzCallback: [string, string][] = [
  ["id", "W_79pJDk"],
  ["collection_id", "599"],
  ["paid", "true"],
  ["state", "paid"],
  ["amount", "200"],
  ["paid_amount", "200"],
  ["due_at", "2020-12-31"],
  ["email", "api@billplz.com"],
  ["mobile", ""],
  ["name", "MICHAEL API"],
  ["url", "http://billplz.dev/bills/W_79pJDk"],
  ["paid_at", "2015-03-09 16:23:59 +0800"],
];

Deno.test("billplz: X-Signature source string and callback", async () => {
  assertEquals(
    billplzSource(billplzCallback),
    "amount200|collection_id599|due_at2020-12-31|emailapi@billplz.com|idW_79pJDk|mobile|nameMICHAEL API|" +
      "paid_amount200|paid_at2015-03-09 16:23:59 +0800|paidtrue|statepaid|urlhttp://billplz.dev/bills/W_79pJDk",
  );
  const sig = "feef4d66128fa356af688c06edf86b50d555fa230ce25e2c067a8215c8d39863";
  const body = new URLSearchParams([...billplzCallback, ["x_signature", sig]]).toString();
  const a = account("billplz", { collectionId: "599" }, { apiKey: "k", xSignatureKey: BILLPLZ_KEY });
  const v = await billplz.verify(a, req(body), net().http);
  assert(v.ok);
  assertEquals(v.outcomes[0].status, "paid");
  assertEquals(v.outcomes[0].providerRef, "W_79pJDk");
  assertEquals(v.outcomes[0].amount, 2);
  const forged = body.replace("paid_amount=200", "paid_amount=900");
  assert(!(await billplz.verify(a, req(forged), net().http)).ok);
});

Deno.test("billplz: the payer's redirect (billplz[...] parameters)", async () => {
  const q = new URLSearchParams([
    ["billplz[id]", "W_79pJDk"],
    ["billplz[paid]", "true"],
    ["billplz[paid_at]", "2015-03-09 16:23:59 +0800"],
    ["billplz[x_signature]", "193ec8fb7dcb5a9552169108e2b373fc13163b6129e450aa18af2eac4decde02"],
  ]).toString();
  const a = account("billplz", { collectionId: "599" }, { apiKey: "k", xSignatureKey: BILLPLZ_KEY });
  const v = await billplz.verify(a, req("", {}, q), net().http);
  assert(v.ok);
  assertEquals(v.outcomes[0].status, "paid");
});

Deno.test("billplz: bill request (sandbox host, sen, basic auth)", async () => {
  const { http, seen } = net([200, { id: "b1", url: "https://www.billplz-sandbox.com/bills/b1" }]);
  const a = account("billplz", { collectionId: "col" }, { apiKey: "key" }, "Sandbox");
  const c = await billplz.createCheckout(a, input, http);
  assertEquals(c, { url: "https://www.billplz-sandbox.com/bills/b1", providerRef: "b1" });
  assertEquals(seen[0].url, "https://www.billplz-sandbox.com/api/v3/bills");
  assertEquals(header(seen[0].init, "authorization"), `Basic ${btoa("key:")}`);
  const f = formOf(seen[0].init);
  assertEquals(f.get("amount"), "5000");
  assertEquals(f.get("collection_id"), "col");
  assertEquals(f.get("callback_url"), "https://x/w");
  assertEquals(f.get("redirect_url"), "https://x/r");
  assertEquals(f.get("reference_1"), REF);
  assertEquals(f.get("mobile"), "60123456789");
});

// ---- HitPay ------------------------------------------------------------------------------------------

Deno.test("hitpay: legacy webhook hmac and JSON Hitpay-Signature", async () => {
  const fields: [string, string][] = [
    ["payment_id", "92965a2d-ece3-4ace-1245-494050c9a3c1"],
    ["payment_request_id", "92965a20-dae5-4d89-a452-5fdfa382dbe1"],
    ["phone", ""],
    ["amount", "50.00"],
    ["currency", "MYR"],
    ["status", "completed"],
    ["reference_number", REF],
  ];
  assertStringIncludes(hitpaySource(fields), "amount50.00currencyMYRpayment_id");
  const a = account("hitpay", {}, { apiKey: "k", salt: "salt123" });
  const signed = new URLSearchParams([
    ...fields,
    ["hmac", "2e1a71d4f910e973012a12ff6fdbb8f74593f81b330203cc2b709daa43f78c5a"],
  ]).toString();
  const v = await hitpay.verify(a, req(signed), net().http);
  assert(v.ok);
  assertEquals(v.outcomes[0].status, "paid");
  assert(!(await hitpay.verify(a, req(signed.replace("50.00", "5.00")), net().http)).ok);
  const json = '{"id":"x","status":"completed"}';
  const ok = await hitpay.verify(
    a,
    req(json, { "hitpay-signature": "5e355181b2e72035aee6a147418cdf1183f272e651f894bc7c7e0543ce8e3cf2" }),
    net().http,
  );
  assert(ok.ok);
  assert(!(await hitpay.verify(a, req(json, { "hitpay-signature": "00" }), net().http)).ok);
  assert(hitpay.confirmPaid);
});

Deno.test("hitpay: payment request", async () => {
  const { http, seen } = net([201, { id: "pr1", url: "https://securecheckout.hit-pay.com/x" }]);
  await hitpay.createCheckout(account("hitpay", {}, { apiKey: "k" }), input, http);
  assertEquals(seen[0].url, "https://api.hit-pay.com/v1/payment-requests");
  assertEquals(header(seen[0].init, "x-business-api-key"), "k");
  const f = formOf(seen[0].init);
  assertEquals(f.get("amount"), "50.00");
  assertEquals(f.get("reference_number"), REF);
  assertEquals(f.get("webhook"), "https://x/w");
});

// ---- PayPal ------------------------------------------------------------------------------------------

Deno.test("paypal: order with return / cancel, approval link; lookup captures an approved order", async () => {
  const { http, seen } = net(
    [200, { access_token: "T" }],
    [201, { id: "O1", links: [{ rel: "payer-action", href: "https://www.paypal.com/checkoutnow?token=O1" }] }],
  );
  const a = account("paypal", { clientId: "cid" }, { clientSecret: "cs" }, "Sandbox");
  const c = await paypal.createCheckout(a, input, http);
  assertEquals(c, { url: "https://www.paypal.com/checkoutnow?token=O1", providerRef: "O1" });
  assertEquals(seen[0].url, "https://api-m.sandbox.paypal.com/v1/oauth2/token");
  assertEquals(header(seen[0].init, "authorization"), `Basic ${btoa("cid:cs")}`);
  const order = JSON.parse(String(seen[1].init?.body));
  assertEquals(order.purchase_units[0].amount, { currency_code: "MYR", value: "50.00" });
  assertEquals(order.purchase_units[0].custom_id, REF);
  assertEquals(order.payment_source.paypal.experience_context.return_url, "https://x/r");

  const looked = net(
    [200, { access_token: "T" }],
    [200, { id: "O1", status: "APPROVED", purchase_units: [{ custom_id: REF, amount: { value: "50.00", currency_code: "MYR" } }] }],
    [201, {
      id: "O1",
      status: "COMPLETED",
      purchase_units: [{
        custom_id: REF,
        payments: { captures: [{ status: "COMPLETED", amount: { value: "50.00", currency_code: "MYR" } }] },
      }],
    }],
  );
  const o = await paypal.lookup!(a, { reference: REF, providerRef: "O1", amount: 50, currency: "MYR" }, looked.http);
  assertEquals(o, { providerRef: "O1", reference: REF, status: "paid", amount: 50, currency: "MYR" });
  assertEquals(looked.seen[2].url, "https://api-m.sandbox.paypal.com/v2/checkout/orders/O1/capture");
});

Deno.test("paypal: webhooks are checked by PayPal with the webhook ID", async () => {
  const event = JSON.stringify({
    event_type: "PAYMENT.CAPTURE.COMPLETED",
    resource: { custom_id: REF, amount: { value: "50.00", currency_code: "MYR" }, supplementary_data: { related_ids: { order_id: "O1" } } },
  });
  const a = account("paypal", { clientId: "cid", webhookId: "WH1" }, { clientSecret: "cs" });
  const yes = net([200, { access_token: "T" }], [200, { verification_status: "SUCCESS" }]);
  const v = await paypal.verify(a, req(event, { "paypal-transmission-id": "t1" }), yes.http);
  assert(v.ok && !v.lookupOnly);
  assertEquals(v.outcomes[0], { providerRef: "O1", reference: REF, status: "paid", amount: 50, currency: "MYR", event: "PAYMENT.CAPTURE.COMPLETED" });
  const sent = JSON.parse(String(yes.seen[1].init?.body));
  assertEquals(sent.webhook_id, "WH1");
  assertEquals(sent.transmission_id, "t1");
  assertEquals(sent.webhook_event.event_type, "PAYMENT.CAPTURE.COMPLETED");
  const no = net([200, { access_token: "T" }], [200, { verification_status: "FAILURE" }]);
  assert(!(await paypal.verify(a, req(event), no.http)).ok);
});

// ---- Curlec / Razorpay -------------------------------------------------------------------------------

Deno.test("curlec: payment link, return signature and webhook signature", async () => {
  const { http, seen } = net([200, { id: "plink_1", short_url: "https://rzp.io/i/x" }]);
  const a = account("curlec", { keyId: "rzp_test_1" }, { keySecret: "rzp_secret", webhookSecret: "whsec_rzp" });
  assertEquals(await curlec.createCheckout(a, input, http), { url: "https://rzp.io/i/x", providerRef: "plink_1" });
  const body = JSON.parse(String(seen[0].init?.body));
  assertEquals([body.amount, body.currency, body.reference_id, body.callback_url], [5000, "MYR", REF, "https://x/r"]);

  const back = new URLSearchParams({
    razorpay_payment_id: "pay_1",
    razorpay_payment_link_id: "plink_1",
    razorpay_payment_link_reference_id: REF,
    razorpay_payment_link_status: "paid",
    razorpay_signature: "8a68bb4dc66ff42147f93889efa24245eee7358d2713a4489ac8a103ac284977",
  }).toString();
  const r = await curlec.verify(a, req("", {}, back), net().http);
  assert(r.ok);
  assertEquals(r.outcomes[0].status, "paid");
  assert(!(await curlec.verify(a, req("", {}, back.replace("paid&", "paid1&")), net().http)).ok);

  const wh = '{"event":"payment_link.paid"}';
  const ok = await curlec.verify(
    a,
    req(wh, { "x-razorpay-signature": "b2cb185d798cba499fe1c7f8607b0c17ec95b7b68a56851286b97c9506ebf7c9" }),
    net().http,
  );
  assert(ok.ok);
  assert(!(await curlec.verify(a, req(wh, { "x-razorpay-signature": "bad" }), net().http)).ok);
});

// ---- Xendit ------------------------------------------------------------------------------------------

Deno.test("xendit: invoice request and callback token", async () => {
  const { http, seen } = net([200, { id: "inv1", invoice_url: "https://checkout.xendit.co/web/inv1" }]);
  const a = account("xendit", {}, { secretKey: "xnd_development_x", callbackToken: "tok" });
  await xendit.createCheckout(a, input, http);
  const body = JSON.parse(String(seen[0].init?.body));
  assertEquals([body.external_id, body.amount, body.currency], [REF, 50, "MYR"]);
  assertEquals(header(seen[0].init, "authorization"), `Basic ${btoa("xnd_development_x:")}`);
  const cb = JSON.stringify({ id: "inv1", external_id: REF, status: "PAID", paid_amount: 50, currency: "MYR" });
  const v = await xendit.verify(a, req(cb, { "x-callback-token": "tok" }), net().http);
  assert(v.ok);
  assertEquals(v.outcomes[0].status, "paid");
  assert(!(await xendit.verify(a, req(cb, { "x-callback-token": "nope" }), net().http)).ok);
});

// ---- Adyen -------------------------------------------------------------------------------------------

Deno.test("adyen: notification HMAC (Adyen's documented example) and [accepted]", async () => {
  const item = {
    pspReference: "7914073381342284",
    merchantAccountCode: "TestMerchant",
    merchantReference: "TestPayment-1407325143704",
    amount: { value: 1130, currency: "EUR" },
    eventCode: "AUTHORISATION",
    success: "true",
    additionalData: { hmacSignature: "coqCmt/IZ4E3CzPvMY8zTjQVL5hYJUiBRg8UU+iCWo0=" },
  };
  assertEquals(adyenSource(item), "7914073381342284::TestMerchant:TestPayment-1407325143704:1130:EUR:AUTHORISATION:true");
  const a = account("adyen", { merchantAccount: "TestMerchant" }, {
    apiKey: "k",
    hmacKey: "44782DEF547AAA06C910C43932B1EB0C71FC68D9D0C057550C48EC2ACF6BA056",
  });
  const v = await adyen.verify(a, req(JSON.stringify({ live: "false", notificationItems: [{ NotificationRequestItem: item }] })), net().http);
  assert(v.ok);
  assertEquals(v.ack?.body, "[accepted]");
  assertEquals(v.outcomes[0], {
    reference: "TestPayment-1407325143704",
    status: "paid",
    amount: 11.3,
    currency: "EUR",
    event: "AUTHORISATION",
  });
  const forged = { ...item, amount: { value: 1, currency: "EUR" } };
  assert(!(await adyen.verify(a, req(JSON.stringify({ notificationItems: [{ NotificationRequestItem: forged }] })), net().http)).ok);
});

Deno.test("adyen: payment link request; live needs the URL prefix", async () => {
  const { http, seen } = net([201, { id: "PL1", url: "https://test.adyen.link/PL1" }]);
  const a = account("adyen", { merchantAccount: "M" }, { apiKey: "k" }, "Sandbox");
  await adyen.createCheckout(a, input, http);
  assertEquals(seen[0].url, "https://checkout-test.adyen.com/v71/paymentLinks");
  const body = JSON.parse(String(seen[0].init?.body));
  assertEquals([body.reference, body.amount.value, body.merchantAccount], [REF, 5000, "M"]);
  await assertRejects(() => adyen.createCheckout(account("adyen", { merchantAccount: "M" }, { apiKey: "k" }), input, net().http));
});

// ---- 2C2P --------------------------------------------------------------------------------------------

Deno.test("2c2p: payment token request and signed backend notification", async () => {
  const key = "2c2p_secret";
  const answer = await signJwt({ webPaymentUrl: "https://sandbox-pgw-ui.2c2p.com/x", paymentToken: "PT", respCode: "0000" }, key);
  const { http, seen } = net([200, { payload: answer }]);
  const a = account("2c2p", { merchantId: "JT01" }, { secretKey: key }, "Sandbox");
  assertEquals(await twoc2p.createCheckout(a, input, http), { url: "https://sandbox-pgw-ui.2c2p.com/x", providerRef: "PT" });
  assertEquals(seen[0].url, "https://sandbox-pgw.2c2p.com/payment/4.3/paymentToken");
  const sent = await readJwt(JSON.parse(String(seen[0].init?.body)).payload, key);
  assertEquals([sent.merchantID, sent.invoiceNo, sent.amount, sent.currencyCode], ["JT01", REF, 50, "MYR"]);
  assertEquals(sent.backendReturnUrl, "https://x/w");

  const note = JSON.stringify({ payload: await signJwt({ invoiceNo: REF, respCode: "0000", amount: 50, currencyCode: "MYR" }, key) });
  const v = await twoc2p.verify(a, req(note), net().http);
  assert(v.ok);
  assertEquals(v.outcomes[0].status, "paid");
  const forged = JSON.stringify({ payload: await signJwt({ invoiceNo: REF, respCode: "0000" }, "other") });
  assert(!(await twoc2p.verify(a, req(forged), net().http)).ok);
});

// ---- Fiuu --------------------------------------------------------------------------------------------

Deno.test("fiuu: vcode on the payment URL, skey on the callback", async () => {
  assertEquals(fiuuVcode("50.00", "merchant1", REF, "ver_key"), "b5fe20aef8b19853318a63a2b5d62cac");
  const a = account("fiuu", { merchantId: "merchant1" }, { verifyKey: "ver_key", secretKey: "sec_key" });
  const c = await fiuu.createCheckout(a, input, net().http);
  assert("url" in c);
  const u = new URL(c.url);
  assertEquals(u.origin + u.pathname, "https://pay.fiuu.com/RMS/pay/merchant1/");
  assertEquals(u.searchParams.get("vcode"), "b5fe20aef8b19853318a63a2b5d62cac");
  assertEquals(u.searchParams.get("callbackurl"), "https://x/w");

  const f = {
    tranID: "123456",
    orderid: REF,
    status: "00",
    domain: "merchant1",
    amount: "50.00",
    currency: "RM",
    appcode: "A1",
    paydate: "2026-10-20 10:00:00",
  };
  assertEquals(fiuuSkey(f, "sec_key"), "c827704718901896b96c0ccd184d8d21");
  const body = new URLSearchParams({ ...f, skey: "c827704718901896b96c0ccd184d8d21", nbcb: "1" }).toString();
  const v = await fiuu.verify(a, req(body), net().http);
  assert(v.ok);
  assertEquals(v.ack?.body, "CBTOKEN:MPSTATOK");
  assertEquals(v.outcomes[0], { reference: REF, providerRef: "123456", status: "paid", amount: 50, currency: "MYR" });
  assert(!(await fiuu.verify(a, req(body.replace("status=00", "status=11")), net().http)).ok);
});

// ---- iPay88 ------------------------------------------------------------------------------------------

Deno.test("ipay88: amount format, request and response signatures, form", async () => {
  assertEquals(ipay88Amount(1234.5), "1,234.50");
  assertEquals(ipay88Amount(1), "1.00");
  assertEquals(
    await ipay88RequestSignature("Apple", "M00003", "A00000001", "1.00", "MYR"),
    "0695cecb7f4189f4411960edf6ed25b5a65a384f2950ad5933878290931ca495",
  );
  const resp = { MerchantCode: "M00003", PaymentId: "2", RefNo: "A00000001", Amount: "1.00", Currency: "MYR", Status: "1" };
  assertEquals(await ipay88ResponseSignature("Apple", resp), "4ba68ba9acfa69da936a996b65055fcd6917febf4b017c89827e86474cd64107");

  const a = account("ipay88", { merchantCode: "M00003" }, { merchantKey: "Apple" });
  const c = await ipay88.createCheckout(a, { ...input, reference: "A00000001", amount: 1 }, net().http);
  assert("form" in c);
  assertEquals(c.form.action, "https://payment.ipay88.com.my/ePayment/entry.asp");
  assertEquals(c.form.fields.Signature, "0695cecb7f4189f4411960edf6ed25b5a65a384f2950ad5933878290931ca495");
  assertEquals(c.form.fields.SignatureType, "SHA256");
  assertEquals(c.form.fields.BackendURL, "https://x/w");

  const body = new URLSearchParams({ ...resp, TransId: "T1", Signature: "4ba68ba9acfa69da936a996b65055fcd6917febf4b017c89827e86474cd64107" }).toString();
  const v = await ipay88.verify(a, req(body), net().http);
  assert(v.ok);
  assertEquals(v.ack?.body, "RECEIVEOK");
  assertEquals(v.outcomes[0].status, "paid");
  assert(!(await ipay88.verify(a, req(body.replace("Status=1", "Status=0")), net().http)).ok);
});

// ---- eGHL --------------------------------------------------------------------------------------------

Deno.test("eghl: request hash on the payment URL, response hash", async () => {
  const a = account("eghl", { serviceId: "sit" }, { password: "sit12345" });
  const c = await eghl.createCheckout(a, { ...input, returnUrl: "https://x/r", webhookUrl: "https://x/w" }, net().http);
  assert("url" in c);
  const q = new URL(c.url).searchParams;
  assertEquals(q.get("HashValue"), "57363acce0fcf023088fabe135b3fabafa74f7f14ec067e77d556884150cee93");
  assertEquals(await eghlRequestHash("sit12345", Object.fromEntries(q)), q.get("HashValue"));
  const resp = {
    TxnID: "SITGR26102000",
    ServiceID: "sit",
    PaymentID: REF,
    TxnStatus: "0",
    Amount: "50.00",
    CurrencyCode: "MYR",
    AuthCode: "123456",
    OrderNumber: REF,
    HashValue2: "8b31be48f4349566d3c7c62d3cb4106ba570f7f2c76dd33b4b709fec5f4cd6d6",
  };
  const v = await eghl.verify(a, req(new URLSearchParams(resp).toString()), net().http);
  assert(v.ok);
  assertEquals(v.outcomes[0].status, "paid");
  const forged = new URLSearchParams({ ...resp, Amount: "5.00" }).toString();
  assert(!(await eghl.verify(a, req(forged), net().http)).ok);
});

// ---- SenangPay ---------------------------------------------------------------------------------------

Deno.test("senangpay: request hash and return hash", async () => {
  const k = "senang_secret";
  assertEquals(
    await senangpayRequestHash(k, "GET.wallet top up", "50.00", REF),
    "fbbaa325e152e1b45ca97b1048b342a94b619ce02389cfc62491818ff66f3b41",
  );
  const a = account("senangpay", { merchantId: "M1" }, { secretKey: k }, "Sandbox");
  const c = await senangpay.createCheckout(a, input, net().http);
  assert("url" in c);
  assertStringIncludes(c.url, "https://sandbox.senangpay.my/payment/M1?");
  assertEquals(new URL(c.url).searchParams.get("hash"), "fbbaa325e152e1b45ca97b1048b342a94b619ce02389cfc62491818ff66f3b41");
  const ret = { status_id: "1", order_id: REF, transaction_id: "16032300000001", msg: "Payment_was_successful" };
  assertEquals(await senangpayResponseHash(k, ret), "06c21aad44f165fe544ea67d6e71c050a2da32a9e68c4542782e4cf0acb0cbe6");
  const q = new URLSearchParams({ ...ret, hash: "06c21aad44f165fe544ea67d6e71c050a2da32a9e68c4542782e4cf0acb0cbe6" }).toString();
  const v = await senangpay.verify(a, req("", {}, q), net().http);
  assert(v.ok);
  assertEquals(v.outcomes[0].status, "paid");
  assert(!(await senangpay.verify(a, req("", {}, q.replace("status_id=1", "status_id=0")), net().http)).ok);
});

// ---- toyyibPay ---------------------------------------------------------------------------------------

Deno.test("toyyibpay: createBill request; callbacks only trigger a lookup", async () => {
  const { http, seen } = net([200, [{ BillCode: "abc123" }]]);
  const a = account("toyyibpay", { categoryCode: "cat" }, { userSecretKey: "usk" }, "Sandbox");
  assertEquals(await toyyibpay.createCheckout(a, input, http), { url: "https://dev.toyyibpay.com/abc123", providerRef: "abc123" });
  assertEquals(seen[0].url, "https://dev.toyyibpay.com/index.php/api/createBill");
  const f = formOf(seen[0].init);
  assertEquals([f.get("billAmount"), f.get("billExternalReferenceNo"), f.get("categoryCode")], ["5000", REF, "cat"]);
  const v = await toyyibpay.verify(a, req(new URLSearchParams({ billcode: "abc123", status: "1", order_id: REF }).toString()), net().http);
  assert(v.ok && v.lookupOnly);
  const look = net([200, [{ billpaymentStatus: "1", billpaymentAmount: "50.00" }]]);
  const o = await toyyibpay.lookup!(a, { reference: REF, providerRef: "abc123", amount: 50, currency: "MYR" }, look.http);
  assertEquals(o?.status, "paid");
  assertEquals(o?.amount, 50);
});

// ---- Airwallex ---------------------------------------------------------------------------------------

Deno.test("airwallex: webhook signature over timestamp + body, freshness", async () => {
  const a = account("airwallex", { clientId: "c" }, { apiKey: "k", webhookSecret: "awx_secret" });
  const body = '{"name":"payment_link.paid"}';
  const sig = "9b20285192e2bc68b488f8b4aed7ad09c3ba74c9a9984940477b0b3b822cb1ac";
  assert((await airwallex.verify(a, req(body, { "x-timestamp": "1700000000000", "x-signature": sig }), net().http)).ok);
  assert(!(await airwallex.verify(a, req(body, { "x-timestamp": "1700000000000", "x-signature": "00" }), net().http)).ok);
  assert(!(await airwallex.verify(a, req(body, { "x-timestamp": "1700000000000", "x-signature": sig }, "", 1700001000), net().http)).ok);
  assert(airwallex.confirmPaid);
});

// ---- Not built ---------------------------------------------------------------------------------------

Deno.test("a provider not built yet charges nothing", async () => {
  await assertRejects(() => paydibs.createCheckout(account("paydibs", {}, {}), input, net().http));
  assert(!(await paydibs.verify(account("paydibs", {}, {}), req("x=1"), net().http)).ok);
  assertEquals(paydibs.ready, false);
});

Deno.test("missing credentials are named, never sent", async () => {
  const { http, seen } = net();
  await assertRejects(() => stripe.createCheckout(account("stripe", {}, {}), input, http), Error, "secretKey");
  assertEquals(seen.length, 0);
});
