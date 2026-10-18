/**
 * What the session proxy does with a request, with the backend and the
 * phone's relay object faked.
 *
 *     deno test cloudflare/session-proxy/relay_test.ts
 *
 * No permission flags: `handle()` takes its backend call and its relay as
 * arguments, and the pure helpers open nothing. The quiet failures worth
 * catching: a session key reaching the phone (or the target) in a header;
 * a key the backend refused being served from the cache; a body that
 * would exceed a frame; a target that is not an absolute http(s) URL
 * being fetched as something else.
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";
import {
  bearerFrom,
  CHUNK_BYTES,
  forgetSessions,
  forwardHeaders,
  fromBase64,
  handle,
  lookupSession,
  PhoneRelay,
  responseHeaders,
  SESSION_CACHE_MS,
  targetFrom,
  toChunks,
} from "./worker.js";

// ---------------------------------------------------------------------------
// targetFrom(): the URL after the first slash

Deno.test("the target is the absolute URL after the first slash, query kept", () => {
  assertEquals(targetFrom("/https://example.com/a/b?x=1&y=2"), "https://example.com/a/b?x=1&y=2");
  assertEquals(targetFrom("/http://10.0.0.1:8080/"), "http://10.0.0.1:8080/");
  assertEquals(targetFrom("/HTTPS://Example.com"), "https://example.com/");
});

Deno.test("a client that collapsed the double slash is read the same", () => {
  assertEquals(targetFrom("/https:/example.com/path"), "https://example.com/path");
});

Deno.test("anything that is not an http(s) URL is no target", () => {
  for (const p of ["/", "/example.com", "/ftp://x/", "/https://", "/favicon.ico"]) {
    assertEquals(targetFrom(p), null, p);
  }
});

// ---------------------------------------------------------------------------
// bearerFrom(): where the key is read from

Deno.test("the key comes as a bearer token or the X-Session-Key header", () => {
  assertEquals(bearerFrom(new Headers({ authorization: "Bearer abc123" })), "abc123");
  assertEquals(bearerFrom(new Headers({ Authorization: "bearer  abc123 " })), "abc123");
  assertEquals(bearerFrom(new Headers({ "x-session-key": " k " })), "k");
  assertEquals(bearerFrom(new Headers({ authorization: "Basic abc" })), null);
  assertEquals(bearerFrom(new Headers()), null);
});

// ---------------------------------------------------------------------------
// Headers each way

Deno.test("the key, the hop and the edge's headers never reach the phone", () => {
  const h = new Headers({
    authorization: "Bearer secret",
    "x-session-key": "secret",
    host: "proxy.getride.my",
    "cf-connecting-ip": "1.2.3.4",
    "x-forwarded-for": "1.2.3.4",
    "accept-encoding": "gzip",
    connection: "keep-alive",
    "content-length": "3",
    "x-relay-target": "https://x",
    "content-type": "application/json",
    "user-agent": "curl/8",
    "x-custom": "kept",
  });
  assertEquals(forwardHeaders(h), [
    ["content-type", "application/json"],
    ["user-agent", "curl/8"],
    ["x-custom", "kept"],
  ]);
});

Deno.test("the phone's answer loses its framing and names the phone", () => {
  const h = responseHeaders(
    [
      ["Content-Type", "text/html"],
      ["Content-Length", "123"],
      ["Content-Encoding", "gzip"],
      ["Transfer-Encoding", "chunked"],
      ["Set-Cookie", "a=1"],
      ["Set-Cookie", "b=2"],
      ["bad", 7],
      "not a pair",
    ],
    "Office gateway",
  );
  assertEquals(h.get("content-type"), "text/html");
  assertEquals(h.get("content-length"), null);
  assertEquals(h.get("content-encoding"), null);
  assertEquals(h.get("transfer-encoding"), null);
  assertEquals(h.getSetCookie(), ["a=1", "b=2"]);
  assertEquals(h.get("bad"), "7");
  assertEquals(h.get("x-relay-phone"), "Office gateway");
  assertEquals(h.get("cache-control"), "no-store");
  assertEquals(responseHeaders(null, "").get("x-relay-phone"), "gateway");
});

// ---------------------------------------------------------------------------
// Chunks

Deno.test("a body is cut into frames under the limit and comes back whole", () => {
  const bytes = new Uint8Array(CHUNK_BYTES * 2 + 17);
  for (let i = 0; i < bytes.length; i++) bytes[i] = (i * 31) & 0xff;
  const chunks = toChunks(bytes);
  assertEquals(chunks.length, 3);
  for (const c of chunks) assert(c.length < 1024 * 1024);
  const back = new Uint8Array(bytes.length);
  let at = 0;
  for (const c of chunks) {
    const part = fromBase64(c);
    back.set(part, at);
    at += part.length;
  }
  assertEquals(back, bytes);
  assertEquals(toChunks(new Uint8Array(0)), []);
});

// ---------------------------------------------------------------------------
// lookupSession(): the backend's answer, cached for a short while

Deno.test("a session key's phone is asked once per cache window; a refusal is never cached", async () => {
  forgetSessions();
  const calls: unknown[] = [];
  let answer: Record<string, unknown> = { ok: true, device: "dev-1", label: "Office" };
  const call = async (name: string, params: Record<string, unknown>) => {
    calls.push([name, params]);
    return answer;
  };
  assertEquals(await lookupSession("k1", call, 1000), { device: "dev-1", label: "Office" });
  assertEquals(await lookupSession("k1", call, 1000 + SESSION_CACHE_MS - 1), { device: "dev-1", label: "Office" });
  assertEquals(calls.length, 1);
  assertEquals(calls[0], ["session_key_proxy_check", { p_key: "k1" }]);
  await lookupSession("k1", call, 1000 + SESSION_CACHE_MS);
  assertEquals(calls.length, 2);

  answer = { error: "SESSION_KEY_INVALID", hint: "removed" };
  const refused = await lookupSession("k2", call, 1000);
  assertEquals(refused, { status: 401, error: "SESSION_KEY_INVALID", hint: "removed" });
  await lookupSession("k2", call, 1000);
  assertEquals(calls.length, 4, "a refusal is asked again");

  answer = { error: "SESSION_KEY_SCOPE", hint: "no proxy" };
  assertEquals((await lookupSession("k3", call, 1000) as { status: number }).status, 403);
  answer = { ok: false, error: "NO_PROXY_PHONE", hint: "removed phone" };
  assertEquals((await lookupSession("k4", call, 1000) as { status: number }).status, 503);
  forgetSessions();
});

// ---------------------------------------------------------------------------
// handle(): the whole decision

type Relayed = { device: string; req: Request };

function deps(answers: Record<string, unknown>, relayed: Relayed[]) {
  return {
    rpc: async (name: string, params: Record<string, unknown>) => {
      const key = String(params.p_key);
      return answers[`${name}:${key}`] ?? { error: "SESSION_KEY_INVALID", hint: "unknown" };
    },
    relay: async (device: string, req: Request) => {
      relayed.push({ device, req });
      return new Response("relayed", { status: 200 });
    },
    now: () => 5000,
  };
}

const env = {};

Deno.test("the root says how to use it", async () => {
  const res = await handle(new Request("https://proxy.getride.my/"), env, deps({}, []));
  assertEquals(res.status, 200);
  assertStringIncludes(await res.text(), "Authorization: Bearer");
});

Deno.test("a session's request goes to its phone's relay, key and hop headers stripped", async () => {
  forgetSessions();
  const relayed: Relayed[] = [];
  const d = deps({ "session_key_proxy_check:sk": { ok: true, device: "dev-9", label: "Office" } }, relayed);
  const res = await handle(
    new Request("https://proxy.getride.my/https://api.example.com/v1/x?y=1", {
      method: "POST",
      headers: { authorization: "Bearer sk", "content-type": "text/plain", "accept-encoding": "gzip", "cf-ray": "r" },
      body: "hello",
    }),
    env,
    d,
  );
  assertEquals(res.status, 200);
  assertEquals(relayed.length, 1);
  const { device, req } = relayed[0];
  assertEquals(device, "dev-9");
  assertEquals(req.method, "POST");
  assertEquals(req.headers.get("x-relay-target"), "https://api.example.com/v1/x?y=1");
  assertEquals(req.headers.get("x-relay-phone-label"), "Office");
  assertEquals(req.headers.get("content-type"), "text/plain");
  assertEquals(req.headers.get("authorization"), null);
  assertEquals(req.headers.get("accept-encoding"), null);
  assertEquals(req.headers.get("cf-ray"), null);
  assertEquals(await req.text(), "hello");
  forgetSessions();
});

Deno.test("no target, no key, a refused key: told, and nothing reaches a phone", async () => {
  forgetSessions();
  const relayed: Relayed[] = [];
  const d = deps({ "session_key_proxy_check:ok": { ok: true, device: "dev-1", label: "" } }, relayed);
  const noTarget = await handle(
    new Request("https://proxy.getride.my/example.com", { headers: { authorization: "Bearer ok" } }),
    env,
    d,
  );
  assertEquals(noTarget.status, 400);
  const noKey = await handle(new Request("https://proxy.getride.my/https://example.com/"), env, d);
  assertEquals(noKey.status, 401);
  const badKey = await handle(
    new Request("https://proxy.getride.my/https://example.com/", { headers: { authorization: "Bearer nope" } }),
    env,
    d,
  );
  assertEquals(badKey.status, 401);
  assertEquals((await badKey.json()).hint, "unknown");
  assertEquals(relayed, []);
  forgetSessions();
});

Deno.test("the phone connects with its device key over a WebSocket, nothing else", async () => {
  const relayed: Relayed[] = [];
  const d = deps({ "gateway_key_check:dk": { id: "dev-1", label: "Office gateway" } }, relayed);
  const plain = await handle(
    new Request("https://proxy.getride.my/phone", { headers: { authorization: "Bearer dk" } }),
    env,
    d,
  );
  assertEquals(plain.status, 426);
  const noKey = await handle(
    new Request("https://proxy.getride.my/phone", { headers: { upgrade: "websocket" } }),
    env,
    d,
  );
  assertEquals(noKey.status, 401);
  const wrong = await handle(
    new Request("https://proxy.getride.my/phone", { headers: { upgrade: "websocket", authorization: "Bearer x" } }),
    env,
    d,
  );
  assertEquals(wrong.status, 401);
  assertEquals(relayed, []);

  const ok = await handle(
    new Request("https://proxy.getride.my/phone", { headers: { upgrade: "websocket", authorization: "Bearer dk" } }),
    env,
    d,
  );
  assertEquals(ok.status, 200);
  assertEquals(relayed.length, 1);
  assertEquals(relayed[0].device, "dev-1");
  assertEquals(new URL(relayed[0].req.url).pathname, "/phone");
  assertEquals(relayed[0].req.headers.get("x-phone-label"), "Office gateway");
  assertEquals(relayed[0].req.headers.get("upgrade"), "websocket");
});

// ---------------------------------------------------------------------------
// PhoneRelay: which socket a request goes to

/** A phone's socket as the relay sees it. */
class FakeSocket {
  sent: string[] = [];
  closed: string | null = null;
  readyState: number;
  constructor(readyState: number) {
    this.readyState = readyState;
  }
  send(frame: string) {
    if (this.readyState !== 1) throw new TypeError("Can't call WebSocket send() after close().");
    this.sent.push(frame);
  }
  close(_code: number, reason: string) {
    this.closed = reason;
    this.readyState = 3;
  }
}

function relayWith(sockets: FakeSocket[]) {
  // The runtime's class, only ever constructed.
  (globalThis as Record<string, unknown>).WebSocketRequestResponsePair ??= class {
    constructor(_a: string, _b: string) {}
  };
  const ctx = { setWebSocketAutoResponse() {}, getWebSockets: () => sockets };
  return new PhoneRelay(ctx, {});
}

const relayRequest = () =>
  new Request("https://relay/relay", {
    method: "GET",
    headers: { "x-relay-target": "https://api.ipify.org/?format=json", "x-relay-phone-label": "Office" },
  });

Deno.test("a request goes to the phone's open socket, never a dead one left in the list", async () => {
  const dead = new FakeSocket(3);
  const live = new FakeSocket(1);
  const relay = relayWith([dead, live]);
  const answer = relay.relay(relayRequest());
  assertEquals(live.sent.length, 2, "the head and the end frame");
  const head = JSON.parse(live.sent[0]);
  assertEquals(head.method, "GET");
  assertEquals(head.url, "https://api.ipify.org/?format=json");
  assertEquals(dead.closed, "stale");
  // The phone answers.
  relay.webSocketMessage(live, JSON.stringify({ id: head.id, status: 200, headers: [["content-type", "application/json"]] }));
  relay.webSocketMessage(live, JSON.stringify({ id: head.id, chunk: btoa('{"ip":"1.2.3.4"}') }));
  relay.webSocketMessage(live, JSON.stringify({ id: head.id, end: true }));
  const res = await answer;
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("x-relay-phone"), "Office");
  assertEquals(await res.text(), '{"ip":"1.2.3.4"}');
});

Deno.test("only a dead socket: the phone is offline, not a relay failure", async () => {
  const dead = new FakeSocket(3);
  const relay = relayWith([dead]);
  const res = await relay.relay(relayRequest());
  assertEquals(res.status, 503);
  assertEquals((await res.json()).error, "PHONE_OFFLINE");
  assertEquals(dead.closed, "stale");
});

Deno.test("a socket that dies on send is dropped and the session told to retry", async () => {
  const flaky = new FakeSocket(1);
  flaky.send = () => {
    throw new TypeError("Can't call WebSocket send() after close().");
  };
  const relay = relayWith([flaky]);
  const res = await relay.relay(relayRequest());
  assertEquals(res.status, 503);
  const body = await res.json();
  assertEquals(body.error, "PHONE_OFFLINE");
  assertStringIncludes(body.hint, "try again");
  assertEquals(flaky.closed, "send failed");
});

Deno.test("an old connection closing while a newer one is up does not fail its requests", async () => {
  const old = new FakeSocket(1);
  const fresh = new FakeSocket(1);
  const relay = relayWith([old, fresh]);
  const answer = relay.relay(relayRequest());
  assertEquals(fresh.sent.length, 2);
  old.readyState = 3;
  relay.webSocketClose(old);
  const head = JSON.parse(fresh.sent[0]);
  relay.webSocketMessage(fresh, JSON.stringify({ id: head.id, status: 204, headers: [] }));
  assertEquals((await answer).status, 204);
  // The last connection going does fail what is in flight.
  const again = relay.relay(relayRequest());
  fresh.readyState = 3;
  relay.webSocketClose(fresh);
  assertEquals((await again).status, 502);
});
