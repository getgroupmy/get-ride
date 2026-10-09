/**
 * Who send-push sends for. The live caller checks run against a stand-in
 * PostgREST, so these exercise the same requests the function makes.
 *
 *     deno test supabase/functions/_shared/send_push_handler_test.ts
 */
import { assertEquals } from "jsr:@std/assert@1.0.19";

import { livePushAuthDeps, sameSecret, WEBHOOK_SECRET_HEADER } from "./push_auth.ts";
import { handleSendPush, json, type SendBody } from "./send_push_handler.ts";

const URL_ = "https://ref.supabase.co";
const ANON = "anon-key";
const SERVICE = "service-role-key";
const ADMIN_JWT = "admin.jwt.token";
const USER_JWT = "user.jwt.token";
const VAULT_SECRET = "vault-webhook-secret";

/** PostgREST as the function sees it: two RPCs, judged by the bearer. */
function fakePostgrest(calls: string[]): typeof fetch {
  const answer = (input: string | URL | Request, init?: RequestInit): Response => {
    const url = String(input);
    const headers = new Headers(init?.headers);
    const auth = headers.get("Authorization");
    calls.push(url.replace(`${URL_}/rest/v1/rpc/`, ""));
    if (url.endsWith("/rpc/caller_is_admin")) {
      if (headers.get("apikey") !== ANON) return new Response("bad apikey", { status: 401 });
      if (auth === `Bearer ${ADMIN_JWT}`) return Response.json(true);
      if (auth === `Bearer ${USER_JWT}` || auth === `Bearer ${ANON}`) return Response.json(false);
      return Response.json({ code: "PGRST301", message: "JWT invalid" }, { status: 401 });
    }
    if (url.endsWith("/rpc/push_webhook_secret_ok")) {
      if (auth !== `Bearer ${SERVICE}`) return new Response("forbidden", { status: 401 });
      const { p_secret } = JSON.parse(String(init?.body));
      return Response.json(p_secret === VAULT_SECRET);
    }
    return new Response("not found", { status: 404 });
  };
  return ((input: string | URL | Request, init?: RequestInit) =>
    Promise.resolve(answer(input, init))) as typeof fetch;
}

function setup() {
  const calls: string[] = [];
  const sent: SendBody[] = [];
  const deps = {
    auth: livePushAuthDeps({ url: URL_, anonKey: ANON, serviceKey: SERVICE }, fakePostgrest(calls)),
    dispatch: (payload: SendBody) => {
      sent.push(payload);
      return Promise.resolve(json({ recipients: 1, sent: 1, failed: 0 }));
    },
  };
  return { calls, sent, deps };
}

function post(headers: Record<string, string>, body: unknown = { title: "Hi", body: "There", audience: "all" }) {
  return new Request("https://fn.local/send-push", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

Deno.test("no credentials -> 401, nothing sent", async () => {
  const { sent, deps } = setup();
  const res = await handleSendPush(post({}), deps);
  assertEquals(res.status, 401);
  assertEquals(sent.length, 0);
});

Deno.test("a signed-in user who is not an admin -> 403, nothing sent", async () => {
  const { sent, deps, calls } = setup();
  const res = await handleSendPush(post({ Authorization: `Bearer ${USER_JWT}` }), deps);
  assertEquals(res.status, 403);
  assertEquals(sent.length, 0);
  assertEquals(calls, ["caller_is_admin"]);
});

Deno.test("the anon key alone -> 403, nothing sent", async () => {
  const { sent, deps } = setup();
  const res = await handleSendPush(post({ Authorization: `Bearer ${ANON}` }), deps);
  assertEquals(res.status, 403);
  assertEquals(sent.length, 0);
});

Deno.test("a token PostgREST rejects -> 401, nothing sent", async () => {
  const { sent, deps } = setup();
  const res = await handleSendPush(post({ Authorization: "Bearer forged.jwt" }), deps);
  assertEquals(res.status, 401);
  assertEquals(sent.length, 0);
});

Deno.test("an admin's token -> sent (200)", async () => {
  const { sent, deps } = setup();
  const res = await handleSendPush(post({ Authorization: `Bearer ${ADMIN_JWT}` }), deps);
  assertEquals(res.status, 200);
  assertEquals(sent, [{ title: "Hi", body: "There", audience: "all" }]);
});

Deno.test("the service-role key -> sent (200) without asking the database", async () => {
  const { sent, deps, calls } = setup();
  const res = await handleSendPush(post({ Authorization: `Bearer ${SERVICE}` }), deps);
  assertEquals(res.status, 200);
  assertEquals(sent.length, 1);
  assertEquals(calls, []);
});

Deno.test("the webhook secret -> sent (200); a wrong one -> 401", async () => {
  const ok = setup();
  const body = { title: "New ride request", body: "Pickup at X", audience: "partners" };
  const res = await handleSendPush(post({ [WEBHOOK_SECRET_HEADER]: VAULT_SECRET }, body), ok.deps);
  assertEquals(res.status, 200);
  assertEquals(ok.sent, [body]);
  assertEquals(ok.calls, ["push_webhook_secret_ok"]);

  const bad = setup();
  const res2 = await handleSendPush(
    post({ [WEBHOOK_SECRET_HEADER]: "guess", Authorization: `Bearer ${ADMIN_JWT}` }),
    bad.deps,
  );
  assertEquals(res2.status, 401);
  assertEquals(bad.sent.length, 0);
});

Deno.test("the check runs before the body is read", async () => {
  const { deps } = setup();
  const req = new Request("https://fn.local/send-push", { method: "POST", body: "not json" });
  assertEquals((await handleSendPush(req, deps)).status, 401);
  const req2 = new Request("https://fn.local/send-push", {
    method: "POST",
    headers: { Authorization: `Bearer ${SERVICE}` },
    body: "not json",
  });
  assertEquals((await handleSendPush(req2, deps)).status, 400);
});

Deno.test("preflight and other methods need no credentials and send nothing", async () => {
  const { sent, deps } = setup();
  const pre = await handleSendPush(new Request("https://fn.local", { method: "OPTIONS" }), deps);
  assertEquals(pre.status, 200);
  await pre.body?.cancel();
  assertEquals((await handleSendPush(new Request("https://fn.local"), deps)).status, 405);
  assertEquals(sent.length, 0);
});

Deno.test("secrets compare whole, at any length", () => {
  assertEquals(sameSecret("abc", "abc"), true);
  assertEquals(sameSecret("abc", "abd"), false);
  assertEquals(sameSecret("abc", "abcd"), false);
  assertEquals(sameSecret("", "a"), false);
});
