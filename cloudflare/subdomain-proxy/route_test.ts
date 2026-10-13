/**
 * What the subdomain proxy does with a request.
 *
 *     deno test cloudflare/subdomain-proxy/route_test.ts
 *
 * No permission flags: `worker.js` reads no environment, opens no socket
 * and touches no disk on its own; the transfer is a fake passed in.
 *
 * The failures worth catching are quiet ones. Proxying the target host
 * to itself is a loop that answers an error after burning the subrequest
 * budget; proxying a subdomain the owner serves elsewhere takes it down
 * with no error at all; a redirect on `/.well-known/` makes iOS decide
 * the app does not handle the link; and a Location left pointing at the
 * target walks the visitor off the host they came on.
 */
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import {
  ALWAYS_PASS,
  configFrom,
  DEFAULT_TARGET,
  handle,
  parsePassThrough,
  rewriteLocation,
  upstream,
  ZONE,
} from "./worker.js";

const config = configFrom({});

// ---------------------------------------------------------------------------
// upstream(): every decision branch

Deno.test("a subdomain is proxied to the target, path and query kept", () => {
  assertEquals(upstream("https://qr.getride.my/", config), {
    target: "https://www.getride.my/",
  });
  assertEquals(upstream("https://qr.getride.my/ref/AbC123?x=1&y=2", config), {
    target: "https://www.getride.my/ref/AbC123?x=1&y=2",
  });
});

Deno.test("any new single-label subdomain is proxied too", () => {
  assertEquals(upstream("https://promo.getride.my/now/t", config), {
    target: "https://www.getride.my/now/t",
  });
});

Deno.test("the well-known files are proxied, not redirected", () => {
  for (const f of ["apple-app-site-association", "assetlinks.json"]) {
    assertEquals(upstream(`https://qr.getride.my/.well-known/${f}`, config), {
      target: `https://www.getride.my/.well-known/${f}`,
    });
  }
});

Deno.test("the apex is passed through", () => {
  assertEquals(upstream("https://getride.my/", config), null);
  assertEquals(upstream("https://getride.my/anything?q=1", config), null);
});

Deno.test("www is always passed through", () => {
  assertEquals(upstream("https://www.getride.my/", config), null);
  const elsewhere = configFrom({ TARGET_HOST: "get-ride.vercel.app" });
  assertEquals(upstream("https://www.getride.my/x", elsewhere), null);
});

Deno.test("loop guard: the target host itself is never proxied", () => {
  const c = configFrom({ TARGET_HOST: "app.getride.my" });
  assertEquals(upstream("https://app.getride.my/", c), null);
  assertEquals(upstream("https://app.getride.my/.well-known/assetlinks.json", c), null);
  // ...while every other subdomain goes to it.
  assertEquals(upstream("https://qr.getride.my/me/t", c), {
    target: "https://app.getride.my/me/t",
  });
});

Deno.test("loop guard: no subdomain is ever proxied onto itself", () => {
  for (const target of ["www.getride.my", "qr.getride.my", "a.getride.my"]) {
    const c = configFrom({ TARGET_HOST: target });
    for (const host of ["www", "qr", "a", "b", "api"]) {
      const d = upstream(`https://${host}.${ZONE}/p`, c);
      if (d && "target" in d) assert(new URL(d.target).host !== `${host}.${ZONE}`, `${host} -> ${target}`);
    }
  }
});

Deno.test("PASS_THROUGH subdomains are left alone", () => {
  const c = configFrom({ PASS_THROUGH: "api, mail.getride.my" });
  assertEquals(upstream("https://api.getride.my/v1", c), null);
  assertEquals(upstream("https://mail.getride.my/", c), null);
  assertEquals(upstream("https://qr.getride.my/", c), { target: "https://www.getride.my/" });
});

Deno.test("two labels deep is redirected to the apex", () => {
  assertEquals(upstream("https://a.b.getride.my/x?y=1", config), {
    redirect: "https://getride.my/x?y=1",
  });
});

Deno.test("a multi-label host can be passed through explicitly", () => {
  const c = configFrom({ PASS_THROUGH: "a.b" });
  assertEquals(upstream("https://a.b.getride.my/", c), null);
});

Deno.test("hosts outside the zone are left alone", () => {
  assertEquals(upstream("https://example.com/", config), null);
  assertEquals(upstream("https://evilgetride.my/", config), null);
  assertEquals(upstream("https://getride.my.evil.test/", config), null);
});

Deno.test("the host is read case-insensitively and without its port", () => {
  assertEquals(upstream("https://QR.GetRide.MY:443/ref/T", config), {
    target: "https://www.getride.my/ref/T",
  });
  assertEquals(upstream("https://qr.getride.my:8443/", config), {
    target: "https://www.getride.my/",
  });
});

// ---------------------------------------------------------------------------
// configuration

Deno.test("the default target is the Vercel production alias", () => {
  assertEquals(DEFAULT_TARGET, "www.getride.my");
  assertEquals(configFrom({}).target, DEFAULT_TARGET);
  assertEquals(configFrom(undefined).target, DEFAULT_TARGET);
});

Deno.test("TARGET_HOST is normalised, and nonsense falls back to the default", () => {
  assertEquals(configFrom({ TARGET_HOST: " Get-Ride.Vercel.App. " }).target, "get-ride.vercel.app");
  for (const bad of ["", "   ", "https://x.vercel.app", "x.vercel.app/path", "not a host", "localhost"]) {
    assertEquals(configFrom({ TARGET_HOST: bad }).target, DEFAULT_TARGET, bad);
  }
});

Deno.test("PASS_THROUGH parsing: commas, spaces, case, full hosts, the apex", () => {
  assertEquals(parsePassThrough(undefined), new Set(ALWAYS_PASS));
  assertEquals(parsePassThrough(""), new Set(["www"]));
  assertEquals(
    parsePassThrough(" API,mail.getride.my. ,, status\nmx  getride.my "),
    new Set(["www", "api", "mail", "status", "mx"]),
  );
});

// ---------------------------------------------------------------------------
// rewriteLocation()

const T = "www.getride.my";

Deno.test("an absolute redirect onto the target comes back to the visitor's host", () => {
  assertEquals(
    rewriteLocation("https://www.getride.my/ref/x?y=1#z", "qr.getride.my", T),
    "https://qr.getride.my/ref/x?y=1#z",
  );
  assertEquals(rewriteLocation("//www.getride.my/a", "qr.getride.my", T), "https://qr.getride.my/a");
  assertEquals(rewriteLocation("https://WWW.getride.my/a", "qr.getride.my", T), "https://qr.getride.my/a");
});

Deno.test("a relative redirect is already right", () => {
  assertEquals(rewriteLocation("/login", "qr.getride.my", T), "/login");
  assertEquals(rewriteLocation("dashboard", "qr.getride.my", T), "dashboard");
  assertEquals(rewriteLocation("?a=1", "qr.getride.my", T), "?a=1");
});

Deno.test("a redirect somewhere else is somebody else's", () => {
  for (const l of [
    "https://xyz.supabase.co/auth/v1/authorize?x=1",
    "https://accounts.google.com/o/oauth2/auth",
    "https://getride.my/",
    "https://evil.test/www.getride.my",
  ]) {
    assertEquals(rewriteLocation(l, "qr.getride.my", T), l);
  }
});

// ---------------------------------------------------------------------------
// handle(): the transfer

type Call = { url: string; method: string; init?: RequestInit; body: string; headers: Headers };

function fakeOrigin(respond: (req: Request) => Response) {
  const calls: Call[] = [];
  const fetcher = async (input: Request, init?: RequestInit): Promise<Response> => {
    const body = input.body ? await input.clone().text() : "";
    calls.push({ url: input.url, method: input.method, init, body, headers: input.headers });
    return respond(input);
  };
  return { fetcher, calls };
}

Deno.test("well-known: the upstream's 200 JSON comes back as it is, no redirect", async () => {
  const json = '{"applinks":{"details":[]}}';
  const { fetcher, calls } = fakeOrigin(() =>
    new Response(json, { status: 200, headers: { "content-type": "application/json" } })
  );
  const res = await handle(
    new Request("https://qr.getride.my/.well-known/apple-app-site-association"),
    {},
    fetcher,
  );
  assertEquals(res.status, 200);
  assertEquals(res.headers.get("content-type"), "application/json");
  assertEquals(res.headers.get("location"), null);
  assertEquals(await res.text(), json);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].url, "https://www.getride.my/.well-known/apple-app-site-association");
  assertEquals(calls[0].init?.redirect, "manual");
});

Deno.test("method, headers and body are carried to the target", async () => {
  const { fetcher, calls } = fakeOrigin(() => new Response("ok"));
  await handle(
    new Request("https://qr.getride.my/api/x?a=1", {
      method: "POST",
      headers: { "content-type": "text/plain", "x-test": "1" },
      body: "hello",
    }),
    {},
    fetcher,
  );
  assertEquals(calls[0].url, "https://www.getride.my/api/x?a=1");
  assertEquals(calls[0].method, "POST");
  assertEquals(calls[0].headers.get("x-test"), "1");
  assertEquals(calls[0].body, "hello");
});

Deno.test("a passed-through request goes to its own origin untouched", async () => {
  const { fetcher, calls } = fakeOrigin(() => new Response("origin"));
  const req = new Request("https://api.getride.my/v1");
  const res = await handle(req, { PASS_THROUGH: "api" }, fetcher);
  assertEquals(await res.text(), "origin");
  assertEquals(calls[0].url, "https://api.getride.my/v1");
  assertEquals(calls[0].init, undefined);
});

Deno.test("loop guard end to end: a request for the target is not proxied", async () => {
  const { fetcher, calls } = fakeOrigin(() => new Response("vercel"));
  await handle(new Request("https://www.getride.my/x"), {}, fetcher);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].url, "https://www.getride.my/x");
  assertEquals(calls[0].init, undefined);
});

Deno.test("a nested subdomain gets a 308 to the apex without touching the origin", async () => {
  const { fetcher, calls } = fakeOrigin(() => new Response("never"));
  const res = await handle(new Request("https://a.b.getride.my/q?x=1"), {}, fetcher);
  assertEquals(res.status, 308);
  assertEquals(res.headers.get("location"), "https://getride.my/q?x=1");
  assertEquals(calls.length, 0);
});

Deno.test("an upstream redirect onto the target is moved; status and statusText survive", async () => {
  const { fetcher } = fakeOrigin(() =>
    new Response(null, {
      status: 307,
      statusText: "Temporary Redirect",
      headers: { location: "https://www.getride.my/login", "x-kept": "yes" },
    })
  );
  const res = await handle(new Request("https://qr.getride.my/me/t"), {}, fetcher);
  assertEquals(res.status, 307);
  assertEquals(res.statusText, "Temporary Redirect");
  assertEquals(res.headers.get("location"), "https://qr.getride.my/login");
  assertEquals(res.headers.get("x-kept"), "yes");
});

Deno.test("a third-party or relative Location is returned untouched", async () => {
  for (const location of ["https://accounts.google.com/x", "/relative"]) {
    const { fetcher } = fakeOrigin(() => new Response(null, { status: 302, headers: { location } }));
    const res = await handle(new Request("https://qr.getride.my/"), {}, fetcher);
    assertEquals(res.status, 302);
    assertEquals(res.headers.get("location"), location);
  }
});

Deno.test("an error status from the upstream is passed on as it is", async () => {
  const { fetcher } = fakeOrigin(() => new Response("nope", { status: 404, statusText: "Not Found" }));
  const res = await handle(new Request("https://qr.getride.my/.well-known/assetlinks.json"), {}, fetcher);
  assertEquals(res.status, 404);
  assertEquals(res.statusText, "Not Found");
});

Deno.test("TARGET_HOST from the environment is where the request goes", async () => {
  const { fetcher, calls } = fakeOrigin(() => new Response("ok"));
  await handle(new Request("https://qr.getride.my/ref/t"), { TARGET_HOST: "get-ride.vercel.app" }, fetcher);
  assertEquals(calls[0].url, "https://get-ride.vercel.app/ref/t");
});

// ---------------------------------------------------------------------------
// api.getride.my: the backend's second address

Deno.test("api goes straight to the Supabase project, path and query kept", () => {
  assertEquals(upstream("https://api.getride.my/rest/v1/profiles?select=id", config), {
    target: "https://rqlavogkgywxspuxgiwk.supabase.co/rest/v1/profiles?select=id",
    api: true,
  });
  assertEquals(upstream("https://api.getride.my/realtime/v1/websocket?vsn=1.0.0", config), {
    target: "https://rqlavogkgywxspuxgiwk.supabase.co/realtime/v1/websocket?vsn=1.0.0",
    api: true,
  });
});

Deno.test("api can be renamed, repointed, or switched off with PASS_THROUGH", () => {
  const moved = configFrom({ API_LABEL: "backend", API_TARGET: "abc.supabase.co" });
  assertEquals(upstream("https://backend.getride.my/auth/v1/health", moved), {
    target: "https://abc.supabase.co/auth/v1/health",
    api: true,
  });
  // A bad value falls back rather than taking the worker down.
  assertEquals(configFrom({ API_LABEL: "no good", API_TARGET: "not a host" }).apiTarget, "rqlavogkgywxspuxgiwk.supabase.co");
  assertEquals(upstream("https://api.getride.my/x", configFrom({ PASS_THROUGH: "api" })), null);
});

Deno.test("the backend's answer is returned as it is, redirects and upgrades included", async () => {
  const seen: Request[] = [];
  const upstreamRedirect = new Response(null, {
    status: 303,
    headers: { location: "https://accounts.google.com/o/oauth2/auth?x=1" },
  });
  const res = await handle(
    new Request("https://api.getride.my/auth/v1/authorize?provider=google", { headers: { apikey: "k" } }),
    {},
    (req) => {
      seen.push(req);
      return Promise.resolve(upstreamRedirect);
    },
  );
  assertEquals(seen[0].url, "https://rqlavogkgywxspuxgiwk.supabase.co/auth/v1/authorize?provider=google");
  assertEquals(seen[0].headers.get("apikey"), "k");
  assertEquals(res, upstreamRedirect);
});
