/**
 * The security headers the web app is served with
 * (deploy/vercel_output_config.json, copied into the Vercel build output by
 * .github/workflows/deploy-web.yml).
 *
 *     deno test --allow-read scripts/ci/vercel_config_test.ts
 *
 * The first real run of that file is a production deploy, so what can be
 * pinned here is pinned: every response gets every header, the enforced
 * content policy never grows a host list that could break the app, and the
 * report-only policy carries what the Flutter build and the backend need.
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

const path = new URL("../../deploy/vercel_output_config.json", import.meta.url);

type Route = {
  src?: string;
  dest?: string;
  handle?: string;
  headers?: Record<string, string>;
  continue?: boolean;
};

const config = JSON.parse(await Deno.readTextFile(path)) as { version: number; routes: Route[] };

/** The catch-all header route, which must come first so nothing skips it. */
function securityRoute(): Route {
  const route = config.routes[0];
  assertEquals(route.src, "/.*");
  assertEquals(route.continue, true);
  assert(route.headers, "the first route sets headers");
  return route;
}

/** One directive of a policy, as `name -> sources`. */
function directives(policy: string): Map<string, string[]> {
  const out = new Map<string, string[]>();
  for (const part of policy.split(";")) {
    const [name, ...values] = part.trim().split(/\s+/);
    if (name) out.set(name.toLowerCase(), values);
  }
  return out;
}

Deno.test("build output API version 3", () => {
  assertEquals(config.version, 3);
});

Deno.test("every response gets every security header", () => {
  const h = securityRoute().headers!;
  for (
    const name of [
      "strict-transport-security",
      "x-content-type-options",
      "referrer-policy",
      "x-frame-options",
      "permissions-policy",
      "content-security-policy",
      "content-security-policy-report-only",
    ]
  ) {
    assert(h[name]?.trim(), `missing ${name}`);
  }
  assertEquals(h["x-content-type-options"], "nosniff");
  assertEquals(h["referrer-policy"], "strict-origin-when-cross-origin");
  assertEquals(h["x-frame-options"], "DENY");
  const maxAge = Number(/max-age=(\d+)/.exec(h["strict-transport-security"])?.[1]);
  assert(maxAge >= 31536000, "HSTS for at least a year");
});

Deno.test("the header route is ahead of every route that ends matching", () => {
  // A route without `continue` (a dest, or the filesystem handle) stops the
  // walk; the headers must already be on the response by then.
  const first = config.routes.findIndex((r) => r.headers?.["content-security-policy"]);
  const firstStop = config.routes.findIndex((r) => r.handle || r.dest || r.continue !== true);
  assertEquals(first, 0);
  assert(firstStop > first);
});

Deno.test("permissions policy: only the features the web app uses", () => {
  const policy = securityRoute().headers!["permissions-policy"];
  const features = new Map(
    policy.split(",").map((p) => {
      const [name, value] = p.trim().split("=");
      return [name, value] as const;
    }),
  );
  for (const used of ["geolocation", "camera", "microphone", "clipboard-read", "clipboard-write"]) {
    assertEquals(features.get(used), "(self)", `${used} for this site`);
  }
  // Passkeys sign-in on the web (passkey_web.dart) is WebAuthn.
  assertEquals(features.get("publickey-credentials-get"), "(self)");
  for (const unused of ["payment", "usb", "serial", "hid", "bluetooth", "display-capture"]) {
    assertEquals(features.get(unused), "()", `${unused} off`);
  }
  for (const value of features.values()) {
    assert(value === "()" || value === "(self)", "never another origin, never *");
  }
});

Deno.test("enforced policy: framing and plugins only, no host list", () => {
  const d = directives(securityRoute().headers!["content-security-policy"]);
  assertEquals(d.get("frame-ancestors"), ["'none'"]);
  assertEquals(d.get("object-src"), ["'none'"]);
  assertEquals(d.get("base-uri"), ["'self'"]);
  // The hosts the app talks to are admin-configurable (map tiles, styles,
  // geocoders): a fetch-directive here would break the app. Those live in
  // the report-only policy until it has run clean in production.
  for (const name of ["default-src", "script-src", "connect-src", "img-src", "style-src"]) {
    assert(!d.has(name), `${name} is report-only for now`);
  }
});

Deno.test("report-only policy: what the Flutter build and backend need", () => {
  const d = directives(securityRoute().headers!["content-security-policy-report-only"]);
  assertEquals(d.get("default-src"), ["'self'"]);
  assertEquals(d.get("frame-ancestors"), ["'none'"]);
  assertEquals(d.get("object-src"), ["'none'"]);

  const script = d.get("script-src") ?? [];
  // CanvasKit is WebAssembly; the Google Maps JS API evaluates code.
  for (const s of ["'self'", "'wasm-unsafe-eval'", "'unsafe-eval'", "https://maps.googleapis.com"]) {
    assert(script.includes(s), `script-src ${s}`);
  }
  // index.html has inline boot scripts, and Flutter writes inline styles.
  assert(script.includes("'unsafe-inline'"));
  assert((d.get("style-src") ?? []).includes("'unsafe-inline'"));
  assert((d.get("worker-src") ?? []).includes("blob:"), "MapLibre's workers");
  assert((d.get("font-src") ?? []).includes("https://fonts.gstatic.com"));

  const connect = d.get("connect-src") ?? [];
  for (
    const host of [
      "'self'",
      "https://*.supabase.co",
      "wss://*.supabase.co",
      // The backend's second address and admin-listed backends (#125, #130).
      "https://*.getride.my",
      "wss://*.getride.my",
      "https://fonts.gstatic.com",
      "https://tile.openstreetmap.org",
      "https://nominatim.openstreetmap.org",
      "https://api.maptiler.com",
      "https://api.tomtom.com",
      "https://*.googleapis.com",
    ]
  ) {
    assert(connect.includes(host), `connect-src ${host}`);
  }
  for (const [name, sources] of d) {
    assert(!sources.includes("*"), `${name} has no bare *`);
  }
});

Deno.test("the inline scripts in index.html are covered", async () => {
  const html = await Deno.readTextFile(new URL("../../web/index.html", import.meta.url));
  const inline = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>/g)];
  assert(inline.length > 0);
  const script = directives(securityRoute().headers!["content-security-policy-report-only"]).get("script-src");
  assertStringIncludes((script ?? []).join(" "), "'unsafe-inline'");
});
