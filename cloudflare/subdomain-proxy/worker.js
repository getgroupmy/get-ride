/**
 * The worker that serves the web app on any `*.getride.my` subdomain.
 *
 * ## Why this exists
 *
 * `qr.getride.my` is the host My QR codes point at
 * (`lib/src/core/my_qr.dart`): `https://qr.getride.my/<ref|me|now>/<token>`,
 * plus the two `/.well-known/` files a phone fetches to decide that the
 * app, not the browser, opens those links. The app itself is on Vercel.
 *
 * Getting one more subdomain to answer used to take two hand-made steps
 * per name: add the host to the Vercel project (so Vercel issues it a
 * certificate) and add a DNS-only CNAME in Cloudflare pointing at
 * Vercel. A *proxied* wildcard straight at Vercel would save both and
 * does not work: Cloudflare opens its connection to Vercel with SNI
 * `qr.getride.my`, Vercel has no certificate for a host it was never
 * told about, and the visitor gets 525. Vercel only issues wildcard
 * certificates to zones on its own nameservers, and getride.my's stay
 * at Cloudflare.
 *
 * This worker removes the second leg instead. It never asks Vercel for
 * a host Vercel has not heard of: it fetches the same path from the
 * production host Vercel already holds a certificate for (`TARGET_HOST`,
 * `www.getride.my` by default) and returns that response under the
 * address the visitor typed. So any new subdomain is served the moment
 * somebody uses it — no Vercel domain, no DNS record.
 *
 * ## Why it cannot loop
 *
 * The route is `*.getride.my/*`, which also matches the target
 * `www.getride.my`. Two locks keep the worker from fetching itself:
 *
 *   1. Cloudflare does not run a route-bound Worker for a subrequest a
 *      Worker makes inside the same zone: "Custom Domains can also be
 *      invoked within the same zone via `fetch()`, unlike Routes."
 *      (developers.cloudflare.com/workers/configuration/routing/
 *      custom-domains/; the routes page adds that `fetch()` goes to the
 *      origin "as defined in the DNS settings of your Cloudflare zone").
 *      So the fetch to `www` reaches Vercel, not this worker.
 *   2. Should that ever change, or the request arrive some other way,
 *      `upstream()` passes the target host straight through (returns
 *      null → `fetch(request)` to the origin), so a request for the
 *      target is never proxied anywhere. The apex and `www` are passed
 *      through for the same reason, whatever the target is set to.
 *
 * ## Deploying it
 *
 *   npx wrangler deploy            # from this directory
 *
 * `.github/workflows/cloudflare-worker.yml` does that on every push to
 * main that touches it, then makes sure a **proxied** wildcard `*`
 * record exists — a route over a grey-clouded (DNS only) record never
 * fires. A host with its own explicit record keeps that record: if it is
 * grey, its traffic goes straight to wherever it points and skips this
 * worker entirely.
 *
 * ## What it does not do
 *
 * It does not rewrite response bodies (the app's assets are relative and
 * resolve against whichever host asked) and it does not follow
 * redirects: a redirect the origin writes is handed to the visitor, with
 * an absolute one onto the target moved back onto the visitor's host.
 * `/.well-known/*` is no exception and needs none — Vercel serves those
 * files as 200 JSON, and Apple does not follow redirects for the
 * apple-app-site-association file, so a redirect there would be a bug.
 */
export default {
  /**
   * @param {Request} request
   * @param {Record<string, string | undefined>} env
   */
  fetch(request, env) {
    return handle(request, env, fetch);
  },
};

/** The zone this worker is routed on. */
export const ZONE = "getride.my";

/**
 * The host the app is fetched from when `TARGET_HOST` is unset: the
 * Vercel production alias, which Vercel holds a certificate for.
 */
export const DEFAULT_TARGET = "www.getride.my";

/** Labels that are never proxied, whatever `PASS_THROUGH` says. */
export const ALWAYS_PASS = ["www"];

const HOSTNAME =
  /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;

/**
 * The worker's settings from its environment (`[vars]` in wrangler.toml,
 * or `--var` at deploy time). Anything unusable falls back to the
 * default rather than taking the worker down.
 *
 * @param {Record<string, string | undefined> | undefined} env
 * @returns {{ target: string, passThrough: Set<string> }}
 */
export function configFrom(env) {
  const raw = String(env?.TARGET_HOST ?? "").trim().toLowerCase()
    .replace(/\.$/, "");
  const target = HOSTNAME.test(raw) ? raw : DEFAULT_TARGET;
  return { target, passThrough: parsePassThrough(env?.PASS_THROUGH) };
}

/**
 * `PASS_THROUGH`: a comma (or whitespace) separated list of subdomains
 * the worker leaves alone, because they are served somewhere else
 * already (`api`, `mail`, ...). Each entry may be a bare label (`api`)
 * or the full host (`api.getride.my`); both mean the same. Returned as
 * labels, lowercased, without the zone.
 *
 * @param {string | undefined} raw
 * @returns {Set<string>}
 */
export function parsePassThrough(raw) {
  const out = new Set(ALWAYS_PASS);
  for (const part of String(raw ?? "").split(/[\s,]+/)) {
    let s = part.trim().toLowerCase().replace(/\.$/, "");
    if (!s) continue;
    if (s === ZONE) continue; // the apex is always passed through anyway
    if (s.endsWith(`.${ZONE}`)) s = s.slice(0, -(ZONE.length + 1));
    if (s) out.add(s);
  }
  return out;
}

/**
 * Where a request should go, from its URL and the worker's settings.
 *
 * Returns `{ target }` to proxy, `{ redirect }` to send the visitor to
 * the apex, or `null` to leave the request alone (it goes on to the
 * host's own origin, as if the worker were not there).
 *
 * Pure and separate from `fetch`, because the mistakes worth catching
 * are decisions: proxying the target to itself, proxying a subdomain the
 * owner serves elsewhere, or redirecting where a phone wants a 200.
 *
 * @param {string} rawUrl
 * @param {{ target: string, passThrough: Set<string> }} config
 * @returns {null | { target: string } | { redirect: string }}
 */
export function upstream(rawUrl, config = configFrom({})) {
  const url = new URL(rawUrl);
  const host = url.hostname.toLowerCase().replace(/\.$/, "");

  // Not our zone at all. The route should never send one here, but a
  // worker that trusts its route breaks the day somebody widens it.
  if (host !== ZONE && !host.endsWith(`.${ZONE}`)) return null;

  // The apex is not matched by the route; this is the second lock.
  if (host === ZONE) return null;

  // The loop guard: a request for the host we fetch from is never
  // proxied, so even if a subrequest re-entered this worker it would go
  // straight on to the origin.
  if (host === config.target) return null;

  const label = host.slice(0, -(ZONE.length + 1));
  if (config.passThrough.has(label)) return null;

  const rest = `${url.pathname}${url.search}`;

  // A subdomain of a subdomain is nobody's, and Cloudflare's Universal
  // SSL certificate (`getride.my`, `*.getride.my`) does not cover it.
  if (label.includes(".")) return { redirect: `https://${ZONE}${rest}` };

  return { target: `https://${config.target}${rest}` };
}

/**
 * A `Location` header, moved back onto the host the visitor is on.
 *
 * Only an absolute redirect onto the target host is touched. A relative
 * one is already right, and one pointing anywhere else — an OAuth
 * provider, Supabase, a payment page — is somebody else's and must
 * survive untouched.
 *
 * @param {string} location
 * @param {string} visitorHost
 * @param {string} targetHost
 */
export function rewriteLocation(location, visitorHost, targetHost) {
  // `//host/path` is absolute despite having no scheme.
  const absolute = /^[a-z][a-z0-9+.-]*:/i.test(location) ||
    location.startsWith("//");
  if (!absolute) return location;

  let url;
  try {
    url = new URL(location, `https://${targetHost}`);
  } catch {
    return location;
  }
  if (url.hostname.toLowerCase() !== targetHost) return location;
  url.host = visitorHost;
  return url.toString();
}

/**
 * The whole request, with the transfer injected so it can be tested.
 *
 * @param {Request} request
 * @param {Record<string, string | undefined> | undefined} env
 * @param {(input: Request, init?: RequestInit) => Promise<Response>} fetcher
 * @returns {Promise<Response>}
 */
export async function handle(request, env, fetcher) {
  const config = configFrom(env);
  const decision = upstream(request.url, config);

  if (decision === null) return fetcher(request);
  if ("redirect" in decision) {
    return Response.redirect(decision.redirect, 308);
  }

  // `new Request(url, request)` carries the method, headers and body
  // across; the Host header and the SNI follow the URL, which is the
  // point: they become the target, which Vercel holds a certificate for.
  // Manual redirects, so one the origin writes is corrected rather than
  // silently followed on the visitor's behalf.
  const response = await fetcher(new Request(decision.target, request), {
    redirect: "manual",
  });

  const location = response.headers.get("location");
  if (!location) return response;

  const visitorHost = new URL(request.url).host;
  const rewritten = rewriteLocation(location, visitorHost, config.target);
  if (rewritten === location) return response;

  const headers = new Headers(response.headers);
  headers.set("location", rewritten);
  // Status and statusText are read explicitly: they are getters on the
  // prototype, so spreading a Response copies neither, and every
  // redirect would quietly become a 200.
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}
