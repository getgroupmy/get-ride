// deno-lint-ignore-file no-explicit-any -- provider JSON is read field by field.
/**
 * The `payments` function's routes against a fake database and network:
 * checkout (idempotent), webhooks (signed, forged, replayed, unsigned), the
 * payer's return and cancel, the app's status poll, and the admin's test.
 * The SQL side (settling, crediting once) is tested for real in
 * supabase/tests/payment_gateways_0252.sql.
 *
 *     deno test supabase/functions/_shared/payments/handler_test.ts
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import { hmacSha256Hex } from "./crypto.ts";
import { type Deps, handle, type IntentRow, routeOf } from "./handler.ts";
import type { Account, Http } from "./types.ts";

const BASE = "https://proj.supabase.co/functions/v1/payments";
const GW = "22222222-2222-2222-2222-222222222222";
const FIUU_GW = "33333333-3333-3333-3333-333333333333";
const USER = "44444444-4444-4444-4444-444444444444";
const OTHER = "55555555-5555-5555-5555-555555555555";
const ORDER = "77777777-7777-7777-7777-777777777777";
const SECRETS = ["sk_test_SECRETVALUE", "whsec_SECRETVALUE", "verify_SECRETVALUE", "secret_SECRETVALUE"];

interface World {
  links: Array<{ request: string; url: string; actor: string }>;
  dispatchError?: string;
  deps: Deps;
  intents: IntentRow[];
  credits: string[];
  calls: string[];
  answers: Array<[number, unknown]>;
}

function world(opts: { whsec?: boolean; admin?: boolean } = {}): World {
  const intents: IntentRow[] = [];
  const credits: string[] = [];
  const calls: string[] = [];
  const answers: Array<[number, unknown]> = [];
  const links: Array<{ request: string; url: string; actor: string }> = [];
  const w = { links } as unknown as World;
  const accounts: Record<string, Account> = {
    [GW]: {
      id: GW,
      active: true,
      values: { providerId: "stripe", mode: "Sandbox" },
      secrets: { secretKey: SECRETS[0], ...(opts.whsec === false ? {} : { webhookSecret: SECRETS[1] }) },
    },
    [FIUU_GW]: {
      id: FIUU_GW,
      active: true,
      values: { providerId: "fiuu", mode: "Sandbox", fiuu_merchantId: "m1" },
      secrets: { verifyKey: SECRETS[2], secretKey: SECRETS[3] },
    },
  };
  let n = 0;
  const http: Http = (url, init) => {
    calls.push(`${init?.method ?? "GET"} ${url}`);
    const [status, body] = answers.shift() ?? [500, {}];
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  };
  const deps: Deps = {
    base: BASE,
    http,
    now: () => 1700000000_000,
    user: (auth) => Promise.resolve(auth === "Bearer user" ? { id: USER } : auth === "Bearer admin" ? { id: OTHER } : null),
    mayLinkOrder: (auth, id) => Promise.resolve(auth === "Bearer admin" && id === ORDER),
    mayLinkMygig: (auth, id) => Promise.resolve(auth === "Bearer user" && id === ORDER),
    canEditGateways: (auth) => Promise.resolve(auth ? auth === "Bearer admin" || opts.admin === true : null),
    db: {
      rpc(fn, a: any) {
        switch (fn) {
          case "payment_gateway_account":
            return Promise.resolve(accounts[a.p_gateway] ?? null);
          case "payment_intent_create": {
            const same = intents.find((i) => a.p_idempotency_key && i.user_id === a.p_user && (i as any).key === a.p_idempotency_key);
            if (same) return Promise.resolve({ ...same });
            if (a.p_amount < 5 && a.p_purpose !== "test") return Promise.reject(new Error("payment_intent_create: invalid_amount"));
            const gw = a.p_gateway ?? GW;
            const row: any = {
              id: `00000000-0000-0000-0000-${String(++n).padStart(12, "0")}`,
              reference: `GR26102000000000${n}`,
              user_id: a.p_user,
              purpose: a.p_purpose,
              purpose_ref: null,
              gateway_id: gw,
              provider: accounts[gw].values.providerId,
              test_mode: true,
              amount: a.p_amount,
              currency: "MYR",
              status: "pending",
              provider_ref: null,
              checkout_url: null,
              applied: null,
              failure: null,
              key: a.p_idempotency_key,
            };
            intents.push(row);
            return Promise.resolve({ ...row });
          }
          case "payment_dispatch_intent": {
            if (w.dispatchError) return Promise.reject(new Error(`payment_dispatch_intent: ${w.dispatchError}`));
            let row: any = intents.find((i) => i.purpose_ref === a.p_request && i.status === "pending");
            if (!row) {
              row = {
                id: `00000000-0000-0000-0000-${String(++n).padStart(12, "0")}`,
                reference: `GR26102000000000${n}`,
                user_id: null,
                purpose: "dispatch",
                purpose_ref: a.p_request,
                gateway_id: GW,
                provider: "stripe",
                test_mode: false,
                amount: 32,
                currency: "MYR",
                status: "pending",
                provider_ref: null,
                checkout_url: null,
                applied: null,
                failure: null,
              };
              intents.push(row);
            }
            return Promise.resolve({
              ...row,
              customer: { name: "Aminah", phone: "+60123450001", email: "" },
              ticket_no: "LNK-0001",
              stand_name: "Link Mall",
            });
          }
          case "payment_mygig_intent": {
            let row: any = intents.find((i) => i.purpose_ref === a.p_request && i.status === "pending");
            if (!row) {
              row = {
                id: `00000000-0000-0000-0000-${String(++n).padStart(12, "0")}`,
                reference: `GR26103000000000${n}`,
                user_id: null,
                purpose: "ride_card",
                purpose_ref: a.p_request,
                gateway_id: GW,
                provider: "stripe",
                test_mode: false,
                amount: 18,
                currency: "MYR",
                status: "pending",
                provider_ref: null,
                checkout_url: null,
                applied: null,
                failure: null,
              };
              intents.push(row);
            }
            return Promise.resolve({ ...row, customer: { name: "Ben", phone: "+60100329099", email: "" } });
          }
          case "payment_mygig_link_by_token":
            return Promise.resolve(a.p_token === "linktoken0331abcdef" && a.p_request === ORDER);
          case "payment_mygig_link_set":
            links.push({ request: a.p_request, url: a.p_url, actor: "driver" });
            return Promise.resolve(null);
          case "payment_dispatch_link_set":
            links.push({ request: a.p_request, url: a.p_url, actor: a.p_actor });
            return Promise.resolve(null);
          case "payment_intent_set_checkout": {
            const i = intents.find((x) => x.id === a.p_id)!;
            i.provider_ref = a.p_provider_ref ?? i.provider_ref;
            i.checkout_url = a.p_url ?? i.checkout_url;
            return Promise.resolve({ ...i });
          }
          case "payment_intent_settle": {
            const i = intents.find((x) => x.reference === a.p_reference)!;
            if (i.status === "paid") return Promise.resolve({ ...i });
            if (a.p_status === "paid") {
              if (a.p_amount !== null && a.p_amount !== undefined && a.p_amount !== Number(i.amount)) {
                i.failure = "amount_mismatch";
              } else {
                i.status = "paid";
                i.applied = "wallet_credited";
                credits.push(i.reference);
              }
            } else if (i.status === "pending" && a.p_status !== "pending") {
              i.status = a.p_status;
            }
            i.provider_ref = a.p_provider_ref ?? i.provider_ref;
            return Promise.resolve({ ...i });
          }
        }
        return Promise.reject(new Error(`unexpected rpc ${fn}`));
      },
      intentById: (id) => Promise.resolve(intents.find((i) => i.id === id) ?? null),
      intentByReference: (r) => Promise.resolve(intents.find((i) => i.reference === r) ?? null),
      intentByProviderRef: (p, r) => Promise.resolve(intents.find((i) => i.provider === p && i.provider_ref === r) ?? null),
      customer: () => Promise.resolve({ name: "Aminah", email: "a@example.com", phone: "+60123456789" }),
    },
  };
  return Object.assign(w, { deps, intents, credits, calls, answers });
}

const post = (path: string, body: unknown, auth?: string, headers: Record<string, string> = {}) =>
  new Request(`${BASE}/${path}`, {
    method: "POST",
    headers: { ...(auth ? { Authorization: auth } : {}), "Content-Type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

async function stripeEvent(w: World, ref: string, amountTotal = 5000, status = "paid") {
  const body = JSON.stringify({
    type: "checkout.session.completed",
    data: { object: { id: "cs_1", client_reference_id: ref, payment_status: status, amount_total: amountTotal, currency: "myr" } },
  });
  const sig = await hmacSha256Hex(SECRETS[1], `1700000000.${body}`);
  return handle(post(`webhook/stripe/${GW}`, body, undefined, { "stripe-signature": `t=1700000000,v1=${sig}` }), w.deps);
}

async function noSecrets(res: Response): Promise<string> {
  const text = await res.text();
  for (const s of SECRETS) assert(!text.includes(s), `response leaks ${s}`);
  return text;
}

Deno.test("routeOf takes what follows /payments", () => {
  assertEquals(routeOf(new URL("https://x/payments/webhook/stripe/abc")), ["webhook", "stripe", "abc"]);
  assertEquals(routeOf(new URL("https://x/functions/v1/payments/checkout")), ["checkout"]);
});

Deno.test("checkout: a signed-in top-up opens the provider's page once per idempotency key", async () => {
  const w = world();
  w.answers.push([200, { id: "cs_1", url: "https://checkout.stripe.com/c/cs_1" }]);
  const r1 = await handle(post("checkout", { purpose: "wallet_topup", amount: 50, idempotency_key: "key-12345678" }, "Bearer user"), w.deps);
  assertEquals(r1.status, 200);
  const b1 = JSON.parse(await noSecrets(r1));
  assertEquals(b1.checkout_url, "https://checkout.stripe.com/c/cs_1");
  assertEquals(b1.status, "pending");
  assertEquals(b1.close_on, [`${BASE}/return/`, `${BASE}/back/`]);
  assertEquals(w.intents[0].provider_ref, "cs_1");
  const sent = w.calls.length;
  const r2 = await handle(post("checkout", { purpose: "wallet_topup", amount: 50, idempotency_key: "key-12345678" }, "Bearer user"), w.deps);
  assertEquals(JSON.parse(await r2.text()).checkout_url, "https://checkout.stripe.com/c/cs_1");
  assertEquals(w.calls.length, sent, "the provider is not asked twice");
  assertEquals(w.intents.length, 1);
});

Deno.test("checkout: refusals", async () => {
  const w = world();
  assertEquals((await handle(post("checkout", { purpose: "wallet_topup", amount: 50 }), w.deps)).status, 401);
  const d = await handle(post("checkout", { purpose: "dispatch", amount: 50 }, "Bearer user"), w.deps);
  assertEquals([d.status, (await d.json()).error], [409, "purpose_not_open"]);
  const small = await handle(post("checkout", { purpose: "wallet_topup", amount: 1 }, "Bearer user"), w.deps);
  assertEquals([small.status, (await small.json()).error], [400, "invalid_amount"]);
});

Deno.test("webhook: signed paid credits once; a replay changes nothing", async () => {
  const w = world();
  w.answers.push([200, { id: "cs_1", url: "https://checkout.stripe.com/c/cs_1" }]);
  await handle(post("checkout", { purpose: "wallet_topup", amount: 50 }, "Bearer user"), w.deps);
  const ref = w.intents[0].reference;
  const r = await stripeEvent(w, ref);
  assertEquals(r.status, 200);
  assertEquals(await r.text(), '{"received":true}');
  assertEquals(w.intents[0].status, "paid");
  assertEquals((await stripeEvent(w, ref)).status, 200);
  assertEquals(w.credits, [ref]);
});

Deno.test("webhook: a forged signature, or another account's address, settles nothing", async () => {
  const w = world();
  w.answers.push([200, { id: "cs_1", url: "u" }]);
  await handle(post("checkout", { purpose: "wallet_topup", amount: 50 }, "Bearer user"), w.deps);
  const body = JSON.stringify({
    type: "checkout.session.completed",
    data: { object: { id: "cs_1", client_reference_id: w.intents[0].reference, payment_status: "paid", amount_total: 5000 } },
  });
  const forged = await handle(post(`webhook/stripe/${GW}`, body, undefined, { "stripe-signature": "t=1700000000,v1=00" }), w.deps);
  assertEquals(forged.status, 400);
  const wrong = await handle(post(`webhook/stripe/${FIUU_GW}`, body), w.deps);
  assertEquals(wrong.status, 404);
  assertEquals(w.intents[0].status, "pending");
  assertEquals(w.credits, []);
});

Deno.test("webhook: a paid amount that isn't the intent's is not accepted", async () => {
  const w = world();
  w.answers.push([200, { id: "cs_1", url: "u" }]);
  await handle(post("checkout", { purpose: "wallet_topup", amount: 50 }, "Bearer user"), w.deps);
  await stripeEvent(w, w.intents[0].reference, 100);
  assertEquals(w.intents[0].status, "pending");
  assertEquals(w.intents[0].failure, "amount_mismatch");
  assertEquals(w.credits, []);
});

Deno.test("webhook without a signing secret: only Stripe's own answer counts", async () => {
  const w = world({ whsec: false });
  w.answers.push([200, { id: "cs_1", url: "u" }]);
  await handle(post("checkout", { purpose: "wallet_topup", amount: 50 }, "Bearer user"), w.deps);
  const ref = w.intents[0].reference;
  const claim = JSON.stringify({
    type: "checkout.session.completed",
    data: { object: { id: "cs_1", client_reference_id: ref, payment_status: "paid", amount_total: 5000 } },
  });
  // Stripe says it isn't paid: the unsigned claim is ignored.
  w.answers.push([200, { id: "cs_1", client_reference_id: ref, payment_status: "unpaid", status: "open" }]);
  await handle(post(`webhook/stripe/${GW}`, claim), w.deps);
  assertEquals(w.intents[0].status, "pending");
  assertStringIncludes(w.calls.at(-1)!, "GET https://api.stripe.com/v1/checkout/sessions/cs_1");
  // Stripe says it is.
  w.answers.push([200, { id: "cs_1", client_reference_id: ref, payment_status: "paid", amount_total: 5000, currency: "myr" }]);
  await handle(post(`webhook/stripe/${GW}`, claim), w.deps);
  assertEquals(w.intents[0].status, "paid");
  assertEquals(w.credits, [ref]);
});

Deno.test("return: the payer's browser asks the provider; cancel marks it cancelled", async () => {
  const w = world();
  w.answers.push([200, { id: "cs_1", url: "u" }], [200, { id: "cs_2", url: "u2" }]);
  await handle(post("checkout", { purpose: "wallet_topup", amount: 50 }, "Bearer user"), w.deps);
  await handle(post("checkout", { purpose: "wallet_topup", amount: 20 }, "Bearer user"), w.deps);
  const [a, b] = w.intents;
  w.answers.push([200, { id: "cs_1", client_reference_id: a.reference, payment_status: "paid", amount_total: 5000, currency: "myr" }]);
  const page = await handle(new Request(`${BASE}/return/${a.id}`), w.deps);
  assertEquals(page.headers.get("content-type"), "text/plain; charset=utf-8");
  assertStringIncludes(await page.text(), "Payment received: MYR 50.00");
  assertEquals(a.status, "paid");
  w.answers.push([200, { id: "cs_2", client_reference_id: b.reference, payment_status: "unpaid", status: "open" }]);
  const cancel = await handle(new Request(`${BASE}/return/${b.id}?cancel=1`), w.deps);
  assertStringIncludes(await cancel.text(), "cancelled");
  assertEquals(b.status, "cancelled");
});

Deno.test("status: the payer's poll asks the provider; others are not told", async () => {
  const w = world();
  w.answers.push([200, { id: "cs_1", url: "u" }]);
  await handle(post("checkout", { purpose: "wallet_topup", amount: 50 }, "Bearer user"), w.deps);
  const i = w.intents[0];
  w.answers.push([200, { id: "cs_1", client_reference_id: i.reference, payment_status: "paid", amount_total: 5000, currency: "myr" }]);
  const r = await handle(post("status", { id: i.id }, "Bearer user"), w.deps);
  const body = JSON.parse(await noSecrets(r));
  assertEquals([body.status, body.applied], ["paid", "wallet_credited"]);
  const stranger = world();
  stranger.intents.push(i);
  stranger.deps.user = () => Promise.resolve({ id: "66666666-6666-6666-6666-666666666666" });
  stranger.deps.canEditGateways = () => Promise.resolve(false);
  assertEquals((await handle(post("status", { id: i.id }, "Bearer x"), stranger.deps)).status, 404);
});

Deno.test("test: admins only; never returns a secret; a form provider gets an RM 1 test checkout", async () => {
  const w = world();
  assertEquals((await handle(post("test", { gateway_id: GW }, "Bearer user"), w.deps)).status, 403);
  assertEquals((await handle(post("test", { gateway_id: GW }), w.deps)).status, 401);
  w.answers.push([200, { available: [] }]);
  const ok = await handle(post("test", { gateway_id: GW }, "Bearer admin"), w.deps);
  const body = JSON.parse(await noSecrets(ok));
  assertEquals(body.result, "ok");
  assertEquals(w.calls.at(-1), "GET https://api.stripe.com/v1/balance");
  const fiuu = await handle(post("test", { gateway_id: FIUU_GW, checkout: true }, "Bearer admin"), w.deps);
  const f = JSON.parse(await noSecrets(fiuu));
  assertEquals(f.result, "warn");
  assertStringIncludes(f.checkout_url, "/RMS/pay/m1/?amount=1.00");
  assertEquals(w.intents.at(-1)!.purpose, "test");
});

Deno.test("providers: what the admin sees of each adapter", async () => {
  const w = world();
  const r = await handle(new Request(`${BASE}/providers`, { headers: { Authorization: "Bearer admin" } }), w.deps);
  const body = JSON.parse(await r.text());
  assertEquals(body.base, BASE);
  assertEquals(body.providers.find((p: any) => p.id === "stripe").verified, true);
  assertEquals(body.providers.find((p: any) => p.id === "paydibs").ready, false);
});

Deno.test("dispatch link: the operator gets the order's link, put on the order and texted; asked again, the same one", async () => {
  const w = world();
  w.answers.push([200, { id: "cs_9", url: "https://checkout.stripe.com/c/pay/cs_9" }]);
  const r = await handle(post("dispatch-link", { request_id: ORDER }, "Bearer admin"), w.deps);
  const body = JSON.parse(await noSecrets(r));
  assertEquals([r.status, body.url, body.amount], [200, "https://checkout.stripe.com/c/pay/cs_9", 32]);
  assertEquals(w.links, [{ request: ORDER, url: "https://checkout.stripe.com/c/pay/cs_9", actor: OTHER }]);
  const sent = w.calls.length;
  const again = await handle(post("dispatch-link", { request_id: ORDER }, "Bearer admin"), w.deps);
  assertEquals(JSON.parse(await again.text()).url, "https://checkout.stripe.com/c/pay/cs_9");
  assertEquals(w.calls.length, sent, "the provider is not asked twice");
  assertEquals(w.links.length, 2, "texted again");
  assertEquals(w.intents.length, 1);
});

Deno.test("dispatch link: refusals", async () => {
  const w = world();
  assertEquals((await handle(post("dispatch-link", { request_id: ORDER }), w.deps)).status, 401);
  assertEquals((await handle(post("dispatch-link", { request_id: ORDER }, "Bearer user"), w.deps)).status, 403);
  w.dispatchError = "no_gateway";
  const r = await handle(post("dispatch-link", { request_id: ORDER }, "Bearer admin"), w.deps);
  assertEquals([r.status, (await r.json()).error], [409, "no_gateway"]);
  w.dispatchError = "fare_unknown";
  const m = await handle(post("dispatch-link", { request_id: ORDER }, "Bearer admin"), w.deps);
  assertEquals((await m.json()).error, "fare_unknown");
  assertEquals(w.links, []);
});

Deno.test("myGiG link: the ride's driver gets the pay link, put on the ride and texted; nobody else", async () => {
  const w = world();
  assertEquals((await handle(post("mygig-link", { request_id: ORDER }), w.deps)).status, 401);
  assertEquals((await handle(post("mygig-link", { request_id: ORDER }, "Bearer admin"), w.deps)).status, 403);
  w.answers.push([200, { id: "cs_m", url: "https://checkout.stripe.com/c/pay/cs_m" }]);
  const r = await handle(post("mygig-link", { request_id: ORDER }, "Bearer user"), w.deps);
  const body = JSON.parse(await noSecrets(r));
  assertEquals([r.status, body.url, body.amount], [200, "https://checkout.stripe.com/c/pay/cs_m", 18]);
  assertEquals(w.links, [{ request: ORDER, url: "https://checkout.stripe.com/c/pay/cs_m", actor: "driver" }]);
  assertEquals(w.intents[0].purpose, "ride_card");
});

Deno.test("myGiG link: the passenger's trip link (signed out) with a token the database allows", async () => {
  const w = world();
  assertEquals((await handle(post("mygig-link", { request_id: ORDER, token: "wrongtoken0331abcd" }), w.deps)).status, 403);
  assertEquals((await handle(post("mygig-link", { request_id: ORDER, token: "x" }), w.deps)).status, 403);
  w.answers.push([200, { id: "cs_t", url: "https://checkout.stripe.com/c/pay/cs_t" }]);
  const r = await handle(post("mygig-link", { request_id: ORDER, token: "linktoken0331abcdef" }), w.deps);
  const body = JSON.parse(await noSecrets(r));
  assertEquals([r.status, body.url], [200, "https://checkout.stripe.com/c/pay/cs_t"]);
  assertEquals(w.links.length, 1);
});
