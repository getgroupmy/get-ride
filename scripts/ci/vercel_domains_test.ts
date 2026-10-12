/**
 * What `vercel_domains.ts` does against a fake Vercel API.
 *
 *     deno test scripts/ci/vercel_domains_test.ts
 *
 * The real API cannot be called from a test, and the first real run is a
 * production deploy. What can be pinned is every decision: when a domain is
 * added, when a record is created, when an existing record is left alone,
 * what a warning tells somebody to do, and that the token never leaves the
 * Authorization header.
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import {
  Cloudflare,
  cnameTarget,
  DEFAULT_CNAME,
  ensureCloudflareRecord,
  ensureDomain,
  isTransient,
  isVercelDns,
  parseDomainList,
  recordName,
  teamOf,
  Vercel,
  zoneCandidates,
} from "./vercel_domains.ts";

const TOKEN = "secret-token-value";
const PROJECT = "prj_123";
const TEAM = "team_abc";

type Handler = (method: string, path: string, body: unknown) => [number, unknown];

/** A fake API: routes "METHOD /path" (query stripped) to a handler. */
function fakeApi(routes: Record<string, Handler | [number, unknown]>) {
  const calls: { method: string; url: string; path: string; body: unknown; auth: string | null }[] = [];
  const fetcher = (url: string, init: RequestInit): Promise<Response> => {
    const u = new URL(url);
    const method = init.method ?? "GET";
    const body = init.body ? JSON.parse(String(init.body)) : undefined;
    const auth = new Headers(init.headers).get("authorization");
    calls.push({ method, url, path: u.pathname, body, auth });
    const key = `${method} ${u.pathname}`;
    const route = routes[key];
    const [status, json] = route === undefined
      ? [404, { error: { code: "not_found", message: `${key} not found` } }]
      : typeof route === "function"
      ? route(method, u.pathname, body)
      : route;
    return Promise.resolve(new Response(JSON.stringify(json), { status }));
  };
  return { api: new Vercel(TOKEN, TEAM, fetcher, 3, 0), calls };
}

const D = "qr.getride.my";
const P = `/v9/projects/${PROJECT}/domains/${D}`;
const misconfigured = { misconfigured: true, recommendedCNAME: [{ rank: 1, value: "abc123.vercel-dns-017.com." }] };
const vercelZone = {
  domain: { name: "getride.my", serviceType: "zeit.world", nameservers: ["ns1.vercel-dns.com", "ns2.vercel-dns.com"] },
};

Deno.test("domains.txt: comments, case, repeats and nonsense", () => {
  const { domains, rejected } = parseDomainList(
    "# what the web project must serve\nqr.getride.my\nQR.getride.my.  # again\n\nnot a domain\nfoo.getride.my\n",
  );
  assertEquals(domains, ["qr.getride.my", "foo.getride.my"]);
  assertEquals(rejected, ["not a domain"]);
});

Deno.test("zones and record names", () => {
  assertEquals(zoneCandidates("qr.getride.my"), ["getride.my"]);
  assertEquals(zoneCandidates("a.qr.getride.my"), ["qr.getride.my", "getride.my"]);
  assertEquals(zoneCandidates("getride.my"), []);
  assertEquals(recordName("qr.getride.my", "getride.my"), "qr");
  assertEquals(recordName("a.qr.getride.my", "getride.my"), "a.qr");
});

Deno.test("the CNAME Vercel recommends, else its default", () => {
  assertEquals(cnameTarget(misconfigured), "abc123.vercel-dns-017.com");
  assertEquals(
    cnameTarget({ recommendedCNAME: [{ rank: 2, value: "b.example" }, { rank: 1, value: "a.example" }] }),
    "a.example",
  );
  assertEquals(cnameTarget({}), DEFAULT_CNAME);
  assertEquals(cnameTarget(null), DEFAULT_CNAME);
});

Deno.test("Vercel DNS is the zeit.world service or Vercel's own nameservers", () => {
  assert(isVercelDns(vercelZone));
  assert(isVercelDns({ domain: { nameservers: ["NS1.vercel-dns.com."], intendedNameservers: ["ns1.vercel-dns.com"] } }));
  assert(!isVercelDns({ domain: { serviceType: "external", nameservers: ["ns1.cloudflare.com"], intendedNameservers: ["ns1.vercel-dns.com"] } }));
  assert(!isVercelDns({ domain: { serviceType: "na" } }));
  assert(!isVercelDns(null));
});

Deno.test("only a team id is a team", () => {
  assertEquals(teamOf("team_EBG91"), "team_EBG91");
  assertEquals(teamOf("someuser"), null);
  assertEquals(teamOf(undefined), null);
});

Deno.test("429 and 5xx are worth a retry, 4xx is not", () => {
  assert(isTransient(429));
  assert(isTransient(503));
  assert(!isTransient(404));
  assert(!isTransient(409));
});

Deno.test("a missing domain is added; its DNS on Vercel gets the CNAME", async () => {
  let added = false;
  const { api, calls } = fakeApi({
    [`GET ${P}`]: () => (added ? [200, { name: D, verified: true }] : [404, { error: { code: "not_found" } }]),
    [`POST /v10/projects/${PROJECT}/domains`]: () => {
      added = true;
      return [200, { name: D, verified: true }];
    },
    [`GET /v6/domains/${D}/config`]: [200, misconfigured],
    [`GET /v5/domains/getride.my`]: [200, vercelZone],
    [`GET /v4/domains/getride.my/records`]: [200, { records: [{ name: "", type: "A", value: "76.76.21.21" }] }],
    [`POST /v2/domains/getride.my/records`]: [200, { uid: "rec_1" }],
  });
  const r = await ensureDomain(api, PROJECT, D);
  assertEquals(r.warnings, []);
  assertStringIncludes(r.notes.join("\n"), "added to the project");
  assertStringIncludes(r.notes.join("\n"), "created qr CNAME abc123.vercel-dns-017.com");
  const create = calls.find((c) => c.method === "POST" && c.path.endsWith("/records"))!;
  assertEquals(create.body, {
    name: "qr",
    type: "CNAME",
    value: "abc123.vercel-dns-017.com",
    ttl: 60,
    comment: "GET.ride web app (deploy/domains.txt)",
  });
  const add = calls.find((c) => c.path === `/v10/projects/${PROJECT}/domains`)!;
  assertEquals(add.body, { name: D });
  for (const c of calls) {
    assertEquals(new URL(c.url).searchParams.get("teamId"), TEAM);
    assertEquals(c.auth, `Bearer ${TOKEN}`);
    assert(!c.url.includes(TOKEN), "the token is never in a URL");
  }
});

Deno.test("already there and configured: nothing is written", async () => {
  const { api, calls } = fakeApi({
    [`GET ${P}`]: [200, { name: D, verified: true }],
    [`GET /v6/domains/${D}/config`]: [200, { misconfigured: false, configuredBy: "CNAME" }],
  });
  const r = await ensureDomain(api, PROJECT, D);
  assertEquals(r.warnings, []);
  assertEquals(calls.filter((c) => c.method !== "GET"), []);
});

Deno.test("an existing record of that name is never overwritten", async () => {
  const { api, calls } = fakeApi({
    [`GET ${P}`]: [200, { name: D, verified: true }],
    [`GET /v6/domains/${D}/config`]: [200, misconfigured],
    [`GET /v5/domains/getride.my`]: [200, vercelZone],
    [`GET /v4/domains/getride.my/records`]: [200, { records: [{ name: "qr", type: "A", value: "1.2.3.4" }] }],
  });
  const r = await ensureDomain(api, PROJECT, D);
  assertEquals(calls.filter((c) => c.method === "POST"), []);
  assertStringIncludes(r.warnings[0], 'already has a record named "qr" (A 1.2.3.4)');
});

Deno.test("our CNAME already there is DNS settling, not a warning", async () => {
  const { api } = fakeApi({
    [`GET ${P}`]: [200, { name: D, verified: true }],
    [`GET /v6/domains/${D}/config`]: [200, misconfigured],
    [`GET /v5/domains/getride.my`]: [200, vercelZone],
    [`GET /v4/domains/getride.my/records`]: [200, {
      records: [{ name: "qr", type: "CNAME", value: "abc123.vercel-dns-017.com." }],
    }],
  });
  const r = await ensureDomain(api, PROJECT, D);
  assertEquals(r.warnings, []);
  assertStringIncludes(r.notes.join(), "settling");
});

Deno.test("DNS elsewhere: a warning with the exact record", async () => {
  const { api, calls } = fakeApi({
    [`GET ${P}`]: [200, { name: D, verified: true }],
    [`GET /v6/domains/${D}/config`]: [200, misconfigured],
    [`GET /v5/domains/getride.my`]: [200, {
      domain: { serviceType: "external", nameservers: ["ns1.example-dns.com"], intendedNameservers: ["ns1.vercel-dns.com"] },
    }],
  });
  const r = await ensureDomain(api, PROJECT, D);
  assertEquals(calls.filter((c) => c.method === "POST"), []);
  assertStringIncludes(r.warnings[0], "qr CNAME abc123.vercel-dns-017.com (in the getride.my zone");
  assertStringIncludes(r.warnings[0], "at your DNS provider");
});

Deno.test("a zone not in the team: the record named in full", async () => {
  const { api } = fakeApi({
    [`GET ${P}`]: [200, { name: D, verified: true }],
    [`GET /v6/domains/${D}/config`]: [200, { misconfigured: true }],
  });
  const r = await ensureDomain(api, PROJECT, D);
  assertStringIncludes(r.warnings[0], `${D} CNAME ${DEFAULT_CNAME}`);
});

Deno.test("a 409 that turns out to be ours already is fine", async () => {
  let gets = 0;
  const { api } = fakeApi({
    [`GET ${P}`]: () => (++gets === 1 ? [404, {}] : [200, { name: D, verified: true }]),
    [`POST /v10/projects/${PROJECT}/domains`]: [409, { error: { code: "domain_already_in_use", message: "in use" } }],
    [`GET /v6/domains/${D}/config`]: [200, { misconfigured: false }],
  });
  const r = await ensureDomain(api, PROJECT, D);
  assertEquals(r.warnings, []);
});

Deno.test("on another project: a warning, and nothing else is tried", async () => {
  const { api, calls } = fakeApi({
    [`POST /v10/projects/${PROJECT}/domains`]: [409, {
      error: { code: "domain_already_in_use", message: "Cannot add qr.getride.my since it's already in use by your account." },
    }],
  });
  const r = await ensureDomain(api, PROJECT, D);
  assertStringIncludes(r.warnings[0], "could not add it to the Vercel project (HTTP 409 domain_already_in_use");
  assert(!calls.some((c) => c.path.includes("/config")));
});

Deno.test("unverified: verify is tried, then the TXT record is named", async () => {
  const unverified = {
    name: D,
    verified: false,
    verification: [{ type: "TXT", domain: "_vercel.getride.my", value: "vc-domain-verify=qr.getride.my,abc" }],
  };
  const { api } = fakeApi({
    [`GET ${P}`]: [200, unverified],
    [`POST ${P}/verify`]: [400, { error: { code: "missing_txt_record" } }],
    [`GET /v6/domains/${D}/config`]: [200, { misconfigured: false }],
  });
  const r = await ensureDomain(api, PROJECT, D);
  assertStringIncludes(r.warnings[0], 'TXT _vercel.getride.my "vc-domain-verify=qr.getride.my,abc"');
});

Deno.test("transient errors are retried; a lasting one becomes a warning", async () => {
  let configCalls = 0;
  const { api } = fakeApi({
    [`GET ${P}`]: [200, { name: D, verified: true }],
    [`GET /v6/domains/${D}/config`]: () => (++configCalls < 3 ? [503, {}] : [200, { misconfigured: false }]),
  });
  const r = await ensureDomain(api, PROJECT, D);
  assertEquals(configCalls, 3);
  assertEquals(r.warnings, []);

  const down = fakeApi({ [`GET ${P}`]: [500, { error: { message: "down" } }] });
  const r2 = await ensureDomain(down.api, PROJECT, D);
  assertEquals(down.calls.length, 3, "bounded");
  assertStringIncludes(r2.warnings[0], "HTTP 500");
});

Deno.test("a dropped connection is retried, then reported without the token", async () => {
  let n = 0;
  const api = new Vercel(TOKEN, null, () => {
    n++;
    return Promise.reject(new Error("connection reset"));
  }, 2, 0);
  const r = await ensureDomain(api, PROJECT, D);
  assertEquals(n, 2);
  assertStringIncludes(r.warnings[0], "connection reset");
  assert(!r.warnings.join().includes(TOKEN));
});

Deno.test("no team: no teamId parameter", () => {
  const api = new Vercel(TOKEN, null);
  assertEquals(api.url("/v6/domains/x/config"), "https://api.vercel.com/v6/domains/x/config");
  const team = new Vercel(TOKEN, TEAM);
  assertEquals(team.url("/v4/domains/x/records?limit=100"), `https://api.vercel.com/v4/domains/x/records?limit=100&teamId=${TEAM}`);
});

// ---- Cloudflare ----------------------------------------------------------

const CF_TOKEN = "cf-secret-token";
const ZONE_ID = "zone123";
const externalZone = {
  domain: { serviceType: "external", nameservers: ["ana.ns.cloudflare.com"], intendedNameservers: ["ns1.vercel-dns.com"] },
};

/** A fake Cloudflare API: "METHOD /path" (after /client/v4, query kept in `url`). */
function fakeCf(routes: Record<string, (url: URL, body: unknown) => [number, unknown]>) {
  const calls: { method: string; url: URL; body: unknown; auth: string | null }[] = [];
  const fetcher = (raw: string, init: RequestInit): Promise<Response> => {
    const url = new URL(raw);
    const method = init.method ?? "GET";
    const body = init.body ? JSON.parse(String(init.body)) : undefined;
    calls.push({ method, url, body, auth: new Headers(init.headers).get("authorization") });
    const key = `${method} ${url.pathname.replace("/client/v4", "")}`;
    const route = routes[key];
    const [status, json] = route ? route(url, body) : [404, { success: false, errors: [{ code: 7003, message: "no route" }] }];
    return Promise.resolve(new Response(JSON.stringify(json), { status }));
  };
  return { cf: new Cloudflare(CF_TOKEN, fetcher, 3, 0), calls };
}

const zones = (url: URL): [number, unknown] =>
  url.searchParams.get("name") === "getride.my"
    ? [200, { success: true, result: [{ id: ZONE_ID, name: "getride.my" }] }]
    : [200, { success: true, result: [] }];

Deno.test("Cloudflare: the CNAME is created there, DNS only", async () => {
  const { api } = fakeApi({
    [`GET ${P}`]: [200, { name: D, verified: true }],
    [`GET /v6/domains/${D}/config`]: [200, misconfigured],
    [`GET /v5/domains/getride.my`]: [200, externalZone],
  });
  const { cf, calls } = fakeCf({
    "GET /zones": zones,
    [`GET /zones/${ZONE_ID}/dns_records`]: () => [200, { success: true, result: [] }],
    [`POST /zones/${ZONE_ID}/dns_records`]: () => [200, { success: true, result: { id: "rec1" } }],
  });
  const r = await ensureDomain(api, PROJECT, D, cf);
  assertEquals(r.warnings, []);
  assertStringIncludes(r.notes.join("\n"), "created CNAME abc123.vercel-dns-017.com in Cloudflare");
  const post = calls.find((c) => c.method === "POST");
  assertEquals(post?.body, {
    type: "CNAME",
    name: D,
    content: "abc123.vercel-dns-017.com",
    ttl: 1,
    proxied: false,
    comment: "GET.ride web app (deploy/domains.txt)",
  });
  // Each token in its own header only.
  for (const c of calls) {
    assertEquals(c.auth, `Bearer ${CF_TOKEN}`);
    assert(!c.url.toString().includes(CF_TOKEN));
    assert(!JSON.stringify(c.body ?? {}).includes(CF_TOKEN));
  }
});

Deno.test("Cloudflare: an existing record of that name is left alone", async () => {
  const { cf, calls } = fakeCf({
    "GET /zones": zones,
    [`GET /zones/${ZONE_ID}/dns_records`]: () => [200, {
      success: true,
      result: [{ type: "A", name: D, content: "192.0.2.1", proxied: true }],
    }],
  });
  const r = await ensureCloudflareRecord(cf, D, "abc123.vercel-dns-017.com");
  assertEquals(calls.filter((c) => c.method === "POST"), []);
  assertStringIncludes(r!.warnings[0], "left as it is");
});

Deno.test("Cloudflare: our CNAME proxied is a warning to turn the proxy off", async () => {
  const { cf } = fakeCf({
    "GET /zones": zones,
    [`GET /zones/${ZONE_ID}/dns_records`]: () => [200, {
      success: true,
      result: [{ type: "CNAME", name: D, content: "abc123.vercel-dns-017.com", proxied: true }],
    }],
  });
  const r = await ensureCloudflareRecord(cf, D, "abc123.vercel-dns-017.com");
  assertStringIncludes(r!.warnings[0], "DNS only");
});

Deno.test("Cloudflare: our CNAME, DNS only, is settling", async () => {
  const { cf } = fakeCf({
    "GET /zones": zones,
    [`GET /zones/${ZONE_ID}/dns_records`]: () => [200, {
      success: true,
      result: [{ type: "CNAME", name: D, content: "abc123.vercel-dns-017.com.", proxied: false }],
    }],
  });
  const r = await ensureCloudflareRecord(cf, D, "abc123.vercel-dns-017.com");
  assertEquals(r!.warnings, []);
  assertStringIncludes(r!.notes[0], "settling");
});

Deno.test("Cloudflare: a zone not on this account falls back to naming the record", async () => {
  const { api } = fakeApi({
    [`GET ${P}`]: [200, { name: D, verified: true }],
    [`GET /v6/domains/${D}/config`]: [200, misconfigured],
    [`GET /v5/domains/getride.my`]: [200, externalZone],
  });
  const { cf } = fakeCf({ "GET /zones": () => [200, { success: true, result: [] }] });
  const r = await ensureDomain(api, PROJECT, D, cf);
  assertStringIncludes(r.warnings[0], "at your DNS provider");
});

Deno.test("Cloudflare: a refused token is a warning, not a crash", async () => {
  const { cf } = fakeCf({
    "GET /zones": () => [403, { success: false, errors: [{ code: 10000, message: "Authentication error" }] }],
  });
  const r = await ensureCloudflareRecord(cf, D, "abc123.vercel-dns-017.com");
  assertStringIncludes(r!.warnings[0], "Authentication error");
});

Deno.test("Cloudflare: a failed create names the record to add", async () => {
  const { cf } = fakeCf({
    "GET /zones": zones,
    [`GET /zones/${ZONE_ID}/dns_records`]: () => [200, { success: true, result: [] }],
    [`POST /zones/${ZONE_ID}/dns_records`]: () => [400, { success: false, errors: [{ code: 81053, message: "record exists" }] }],
  });
  const r = await ensureCloudflareRecord(cf, D, "abc123.vercel-dns-017.com");
  assertStringIncludes(r!.warnings[0], `Add: ${D} CNAME abc123.vercel-dns-017.com, DNS only.`);
});
