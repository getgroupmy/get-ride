/**
 * The `ip-lookup` function: the address-only answer, the answer cache, the
 * rate check and the provider timeout.
 *
 *     deno test supabase/functions/_shared/ip_lookup_test.ts
 */
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import {
  EMPTY,
  handleIpLookup,
  type IpInfo,
  IpInfoCache,
  type IpLookupDeps,
  lookupIpWhoIs,
  wantsIpOnly,
} from "./ip_lookup.ts";

const INFO: IpInfo = {
  public_ip: "203.0.113.7",
  isp_provider: "TM Net",
  isp_org: "Telekom Malaysia",
  ip_city: "Kuala Lumpur",
  ip_region: "Kuala Lumpur",
  ip_country: "Malaysia",
};

function fakeDeps(over: Partial<IpLookupDeps> = {}) {
  const calls = { rate: 0, lookup: 0 };
  let clock = 1_000_000;
  const deps: IpLookupDeps = {
    rateTake: async () => {
      calls.rate++;
      return true;
    },
    lookup: async () => {
      calls.lookup++;
      return INFO;
    },
    cache: new IpInfoCache(),
    now: () => clock,
    ...over,
  };
  return { deps, calls, tick: (ms: number) => (clock += ms) };
}

function request(
  { ip = "203.0.113.7", body, query = "", method = "POST" }: {
    ip?: string | null;
    body?: string;
    query?: string;
    method?: string;
  } = {},
): Request {
  const headers = new Headers({ "content-type": "application/json" });
  if (ip) headers.set("x-forwarded-for", `${ip}, 10.0.0.1`);
  return new Request(`https://x.supabase.co/functions/v1/ip-lookup${query}`, { method, headers, body });
}

Deno.test("ip_only in the body answers the address with no rate check and no provider", async () => {
  const { deps, calls } = fakeDeps();
  const res = await handleIpLookup(request({ body: JSON.stringify({ ip_only: true }) }), deps);
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { public_ip: "203.0.113.7" });
  assertEquals(calls, { rate: 0, lookup: 0 });
});

Deno.test("ip_only in the query answers the address, GET or POST", async () => {
  const { deps, calls } = fakeDeps();
  for (const method of ["GET", "POST"]) {
    const res = await handleIpLookup(request({ method, query: "?ip_only=1" }), deps);
    assertEquals(await res.json(), { public_ip: "203.0.113.7" });
  }
  assertEquals(calls, { rate: 0, lookup: 0 });
});

Deno.test("ip_only for a private address or none still makes no call", async () => {
  const { deps, calls } = fakeDeps();
  const priv = await handleIpLookup(request({ ip: "192.168.1.4", body: '{"ip_only":true}' }), deps);
  assertEquals(await priv.json(), { public_ip: "192.168.1.4" });
  const none = await handleIpLookup(request({ ip: null, body: '{"ip_only":true}' }), deps);
  assertEquals(await none.json(), { public_ip: null });
  assertEquals(calls, { rate: 0, lookup: 0 });
});

Deno.test("an old build's call (empty body) gets the full answer, as before", async () => {
  const { deps, calls } = fakeDeps();
  const res = await handleIpLookup(request({ body: "{}" }), deps);
  assertEquals(await res.json(), INFO);
  assertEquals(calls, { rate: 1, lookup: 1 });

  const noBody = await handleIpLookup(request({ ip: "198.51.100.2", method: "GET" }), deps);
  assertEquals(await noBody.json(), INFO);
  const notOnly = await handleIpLookup(request({ ip: "198.51.100.3", body: '{"ip_only":false}' }), deps);
  assertEquals(await notOnly.json(), INFO);
});

Deno.test("a kept answer is given before the rate check: no rate call, no provider", async () => {
  const { deps, calls } = fakeDeps();
  await handleIpLookup(request({ body: "{}" }), deps);
  assertEquals(calls, { rate: 1, lookup: 1 });
  for (let i = 0; i < 3; i++) {
    const res = await handleIpLookup(request({ body: "{}" }), deps);
    assertEquals(await res.json(), INFO);
  }
  assertEquals(calls, { rate: 1, lookup: 1 });
});

Deno.test("a kept answer expires after 24 h and is looked up again", async () => {
  const { deps, calls, tick } = fakeDeps();
  await handleIpLookup(request(), deps);
  tick(24 * 60 * 60 * 1000 - 1);
  await handleIpLookup(request(), deps);
  assertEquals(calls, { rate: 1, lookup: 1 });
  tick(1);
  await handleIpLookup(request(), deps);
  assertEquals(calls, { rate: 2, lookup: 2 });
});

Deno.test("a failed lookup or a refused rate check is not kept", async () => {
  let answer: IpInfo | null = null;
  const { deps, calls } = fakeDeps({
    lookup: async () => {
      calls.lookup++;
      return answer;
    },
  });
  assertEquals(await (await handleIpLookup(request(), deps)).json(), { ...EMPTY, public_ip: "203.0.113.7" });
  answer = INFO;
  assertEquals(await (await handleIpLookup(request(), deps)).json(), INFO);
  assertEquals(calls.lookup, 2);
});

Deno.test("fails closed: over the limit, or the rate check failing, looks nothing up", async () => {
  for (
    const rateTake of [
      async () => false,
      async () => {
        throw new Error("db down");
      },
    ]
  ) {
    const { deps, calls } = fakeDeps({ rateTake });
    const res = await handleIpLookup(request(), deps);
    assertEquals(res.status, 200);
    assertEquals(await res.json(), { ...EMPTY, public_ip: "203.0.113.7" });
    assertEquals(calls.lookup, 0);
  }
});

Deno.test("a private address or none is answered without any call", async () => {
  const { deps, calls } = fakeDeps();
  assertEquals(await (await handleIpLookup(request({ ip: "10.1.2.3" }), deps)).json(), {
    ...EMPTY,
    public_ip: "10.1.2.3",
  });
  assertEquals(await (await handleIpLookup(request({ ip: "172.20.0.1" }), deps)).json(), {
    ...EMPTY,
    public_ip: "172.20.0.1",
  });
  assertEquals(await (await handleIpLookup(request({ ip: null }), deps)).json(), EMPTY);
  assertEquals(calls, { rate: 0, lookup: 0 });
});

Deno.test("OPTIONS and other methods", async () => {
  const { deps } = fakeDeps();
  assertEquals((await handleIpLookup(request({ method: "OPTIONS" }), deps)).status, 200);
  const put = await handleIpLookup(request({ method: "PUT", body: "{}" }), deps);
  assertEquals(put.status, 405);
  await put.body?.cancel();
});

Deno.test("a provider slower than the timeout gives up: the caller gets EMPTY plus the address", async () => {
  let aborted = false;
  const hanging = ((_url: string, init?: RequestInit) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => {
        aborted = true;
        reject(init.signal!.reason);
      });
    })) as typeof fetch;

  assertEquals(await lookupIpWhoIs("203.0.113.7", hanging, 20), null);
  assert(aborted);

  const { deps } = fakeDeps({ lookup: (ip) => lookupIpWhoIs(ip, hanging, 20) });
  const res = await handleIpLookup(request(), deps);
  assertEquals(await res.json(), { ...EMPTY, public_ip: "203.0.113.7" });
  assertEquals(deps.cache.size, 0);
});

Deno.test("lookupIpWhoIs reads ipwho.is and passes a timeout signal", async () => {
  let signal: AbortSignal | null | undefined;
  const ok = ((_url: string, init?: RequestInit) => {
    signal = init?.signal;
    return Promise.resolve(
      Response.json({
        success: true,
        ip: "203.0.113.7",
        city: "Kuala Lumpur",
        region: "Kuala Lumpur",
        country: "Malaysia",
        connection: { isp: "TM Net", org: "Telekom Malaysia" },
      }),
    );
  }) as typeof fetch;
  assertEquals(await lookupIpWhoIs("203.0.113.7", ok), INFO);
  assert(signal instanceof AbortSignal);

  const refused = (() => Promise.resolve(Response.json({ success: false }))) as typeof fetch;
  assertEquals(await lookupIpWhoIs("203.0.113.7", refused), null);
  const down = (() => Promise.resolve(new Response("x", { status: 503 }))) as typeof fetch;
  assertEquals(await lookupIpWhoIs("203.0.113.7", down), null);
});

Deno.test("the cache holds at most max addresses, dropping the oldest", () => {
  const cache = new IpInfoCache(3, 1000);
  for (const ip of ["a", "b", "c"]) cache.set(ip, INFO, 0);
  cache.set("b", INFO, 1); // re-kept: now the newest
  cache.set("d", INFO, 2);
  assertEquals(cache.size, 3);
  assertEquals(cache.get("a", 2), null);
  assert(cache.get("b", 2));
  assert(cache.get("c", 2));
  assert(cache.get("d", 2));
});

Deno.test("wantsIpOnly ignores large or broken bodies", async () => {
  assertEquals(await wantsIpOnly(request({ body: "not json" })), false);
  assertEquals(await wantsIpOnly(request({ body: JSON.stringify({ ip_only: true, pad: "x".repeat(5000) }) })), false);
  assertEquals(await wantsIpOnly(request({ query: "?ip_only=0" })), false);
  assertEquals(await wantsIpOnly(request({ query: "?ip_only=true" })), true);
});
