/**
 * What `cloudflare_wildcard.ts` does against a fake Cloudflare API.
 *
 *     deno test scripts/ci/cloudflare_wildcard_test.ts
 *
 * Pinned: the wildcard is created proxied only when no record of that name
 * exists, an existing one is never modified, a DNS-only record on a checked
 * host is called out as bypassing the worker, nothing else is ever written,
 * and the token only ever travels in the Authorization header.
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import { COMMENT, ensureWildcard } from "./cloudflare_wildcard.ts";
import { Cloudflare } from "./vercel_domains.ts";

const TOKEN = "cf-secret-token";
const ZONE = "getride.my";
const ZONE_ID = "zone123";
const REC = `/client/v4/zones/${ZONE_ID}/dns_records`;

type Handler = (url: URL, body: unknown) => [number, unknown];

function fakeCloudflare(routes: Record<string, Handler | [number, unknown]>) {
  const calls: { method: string; url: URL; body: unknown; auth: string | null }[] = [];
  const fetcher = (url: string, init: RequestInit): Promise<Response> => {
    const u = new URL(url);
    const method = init.method ?? "GET";
    const body = init.body ? JSON.parse(String(init.body)) : undefined;
    calls.push({ method, url: u, body, auth: new Headers(init.headers).get("authorization") });
    const route = routes[`${method} ${u.pathname}`];
    const [status, json] = route === undefined
      ? [404, { success: false, errors: [{ code: 7003, message: "not found" }] }]
      : typeof route === "function"
      ? route(u, body)
      : route;
    return Promise.resolve(new Response(JSON.stringify(json), { status }));
  };
  return { cf: new Cloudflare(TOKEN, fetcher, 3, 0), calls };
}

const zoneOk: [number, unknown] = [200, { success: true, result: [{ id: ZONE_ID, name: ZONE }] }];

/** dns_records listing by ?name=. */
function records(byName: Record<string, unknown[]>): Handler {
  return (u) => [200, { success: true, result: byName[u.searchParams.get("name") ?? ""] ?? [] }];
}

const created: Handler = (_u, body) => [200, { success: true, result: body }];

Deno.test("no wildcard: one is created, CNAME * -> apex, proxied, with a comment", async () => {
  const { cf, calls } = fakeCloudflare({
    "GET /client/v4/zones": zoneOk,
    [`GET ${REC}`]: records({}),
    [`POST ${REC}`]: created,
  });
  const r = await ensureWildcard(cf, ZONE);
  assertEquals(r.warnings, []);
  const posts = calls.filter((c) => c.method === "POST");
  assertEquals(posts.length, 1);
  assertEquals(posts[0].body, {
    type: "CNAME",
    name: "*.getride.my",
    content: "getride.my",
    ttl: 1,
    proxied: true,
    comment: COMMENT,
  });
  assertStringIncludes(r.notes[0], "Created *.getride.my");
});

Deno.test("a proxied wildcard is left alone", async () => {
  const { cf, calls } = fakeCloudflare({
    "GET /client/v4/zones": zoneOk,
    [`GET ${REC}`]: records({ "*.getride.my": [{ name: "*.getride.my", type: "A", content: "192.0.2.1", proxied: true }] }),
  });
  const r = await ensureWildcard(cf, ZONE);
  assertEquals(r.warnings, []);
  assertStringIncludes(r.notes[0], "proxied");
  assertEquals(calls.filter((c) => c.method !== "GET").length, 0);
});

Deno.test("a DNS-only wildcard: warned about, never modified", async () => {
  const { cf, calls } = fakeCloudflare({
    "GET /client/v4/zones": zoneOk,
    [`GET ${REC}`]: records({
      "*.getride.my": [{ name: "*.getride.my", type: "CNAME", content: "cname.vercel-dns.com", proxied: false }],
    }),
  });
  const r = await ensureWildcard(cf, ZONE);
  assertEquals(r.warnings.length, 1);
  assertStringIncludes(r.warnings[0], "DNS only");
  assertStringIncludes(r.warnings[0], "Proxied");
  assertEquals(calls.filter((c) => c.method !== "GET").length, 0);
});

Deno.test("a record merely containing the name is not the wildcard", async () => {
  const { cf, calls } = fakeCloudflare({
    "GET /client/v4/zones": zoneOk,
    // Cloudflare's filter is exact, but the script checks again.
    [`GET ${REC}`]: () => [200, { success: true, result: [{ name: "*.x.getride.my", type: "A", proxied: false }] }],
    [`POST ${REC}`]: created,
  });
  await ensureWildcard(cf, ZONE);
  assertEquals(calls.filter((c) => c.method === "POST").length, 1);
});

Deno.test("a DNS-only qr record is called out as bypassing the worker", async () => {
  const { cf, calls } = fakeCloudflare({
    "GET /client/v4/zones": zoneOk,
    [`GET ${REC}`]: records({
      "*.getride.my": [{ name: "*.getride.my", type: "CNAME", content: "getride.my", proxied: true }],
      "qr.getride.my": [{ name: "qr.getride.my", type: "CNAME", content: "cname.vercel-dns.com", proxied: false }],
    }),
  });
  const r = await ensureWildcard(cf, ZONE, ["qr.getride.my"]);
  assertEquals(r.warnings.length, 1);
  assertStringIncludes(r.warnings[0], "qr.getride.my");
  assertStringIncludes(r.warnings[0], "bypasses the worker");
  assertStringIncludes(r.warnings[0], "Vercel");
  assertEquals(calls.filter((c) => c.method !== "GET").length, 0);
});

Deno.test("a proxied qr record, or none, is fine", async () => {
  for (const qr of [[], [{ name: "qr.getride.my", type: "CNAME", content: "getride.my", proxied: true }]]) {
    const { cf } = fakeCloudflare({
      "GET /client/v4/zones": zoneOk,
      [`GET ${REC}`]: records({
        "*.getride.my": [{ name: "*.getride.my", type: "CNAME", content: "getride.my", proxied: true }],
        "qr.getride.my": qr,
      }),
    });
    const r = await ensureWildcard(cf, ZONE, ["qr.getride.my"]);
    assertEquals(r.warnings, []);
    assertEquals(r.notes.length, 2);
  }
});

Deno.test("a token that cannot see the zone: a warning naming the permissions", async () => {
  const { cf, calls } = fakeCloudflare({
    "GET /client/v4/zones": [200, { success: true, result: [] }],
  });
  const r = await ensureWildcard(cf, ZONE, ["qr.getride.my"]);
  assertEquals(r.warnings.length, 1);
  assertStringIncludes(r.warnings[0], "DNS -> Edit");
  assertEquals(calls.length, 1);
});

Deno.test("API errors are warnings, and transient ones are retried", async () => {
  let n = 0;
  const { cf } = fakeCloudflare({
    "GET /client/v4/zones": () => (++n < 3 ? [503, {}] : zoneOk),
    [`GET ${REC}`]: records({}),
    [`POST ${REC}`]: [400, { success: false, errors: [{ code: 81053, message: "record already exists" }] }],
  });
  const r = await ensureWildcard(cf, ZONE);
  assertEquals(n, 3);
  assertEquals(r.warnings.length, 1);
  assertStringIncludes(r.warnings[0], "81053");
  assertStringIncludes(r.warnings[0], "Proxied");

  const { cf: denied } = fakeCloudflare({
    "GET /client/v4/zones": [403, { success: false, errors: [{ code: 10000, message: "Authentication error" }] }],
  });
  const d = await ensureWildcard(denied, ZONE);
  assertStringIncludes(d.warnings[0], "Authentication error");
});

Deno.test("the token is only ever in the Authorization header", async () => {
  const { cf, calls } = fakeCloudflare({
    "GET /client/v4/zones": zoneOk,
    [`GET ${REC}`]: records({}),
    [`POST ${REC}`]: created,
  });
  const r = await ensureWildcard(cf, ZONE, ["qr.getride.my"]);
  assert(calls.length >= 3);
  for (const c of calls) {
    assertEquals(c.auth, `Bearer ${TOKEN}`);
    assert(!c.url.toString().includes(TOKEN));
    assert(!JSON.stringify(c.body ?? null).includes(TOKEN));
  }
  assert(![...r.notes, ...r.warnings].join("\n").includes(TOKEN));
});
