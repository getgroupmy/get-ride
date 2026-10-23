import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import {
  certOf,
  defaultAs,
  type HttpRequest,
  type KeyTestDeps,
  keyValue,
  restrictionHeaders,
  runKeyTest,
  scrub,
  TESTS,
  testList,
  testsFor,
  verdictOf,
} from "./key_test.ts";

const KEY = "AIzaSyTestKey1234567890";
const providers = [
  {
    id: "google",
    services: [
      { id: "maps_android", keys: [{ id: "k1", value: KEY }] },
      { id: "places", keys: [{ id: "k2", value: ` ${KEY} ` }, { id: "k3", value: "" }] },
    ],
  },
  { id: "openstreetmap", services: [{ id: "nominatim", keys: [{ id: "n1", value: "http://not-https.example" }] }] },
];
const test = (id: string) => TESTS.find((t) => t.id === id)!;

function deps(answer: { status: number; text: string } | Error, seen: { url?: string; headers?: Record<string, string> } = {}) {
  let t = 1000;
  return {
    settings: () => Promise.resolve({ apiProviders: providers, config: { amazonRegion: "ap-southeast-1" } }),
    fetch: (r: { url: string; headers?: Record<string, string> }) => {
      seen.url = r.url;
      seen.headers = r.headers;
      return answer instanceof Error ? Promise.reject(answer) : Promise.resolve(answer);
    },
    now: () => (t += 50),
  };
}

Deno.test("every test has a unique id, and all but the browser one a request", () => {
  assertEquals(new Set(TESTS.map((t) => t.id)).size, TESTS.length);
  for (const t of TESTS) assert(t.browser ? !t.request : !!t.request, t.id);
  for (const t of testList()) assert(!("request" in t), t.id);
});

Deno.test("tests meant for a service come first; the rest of the provider's follow", () => {
  const ids = testsFor("google", "places").map((t) => t.id);
  assertEquals(ids.slice(0, 3), ["google_places_text", "google_places_autocomplete", "google_places_legacy"]);
  assert(ids.includes("google_tiles"));
  assertEquals(testsFor("google", "maps_android")[0].id, "google_key");
  assertEquals(testsFor("geocoding", "opencage")[0].id, "opencage_search");
  assertEquals(testsFor("nobody", "x"), []);
});

Deno.test("phone and browser keys are sent as their app or site", () => {
  assertEquals(defaultAs("maps_android"), "android");
  assertEquals(defaultAs("maps_ios"), "ios");
  assertEquals(defaultAs("maps_js"), "web");
  assertEquals(defaultAs("places"), "server");
  assertEquals(restrictionHeaders("ios", null), { "X-Ios-Bundle-Identifier": "com.taxxee.teksi" });
  assertEquals(restrictionHeaders("android", null), { "X-Android-Package": "com.taxxee.teksi" });
  assertEquals(restrictionHeaders("web", null).Referer, "https://getride.my/");
  assertEquals(restrictionHeaders("server", null), {});
  const sha = "AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01";
  assertEquals(certOf(sha), "ABCDEF0123456789ABCDEF0123456789ABCDEF01");
  assertEquals(certOf("nope"), null);
});

Deno.test("the key is found by provider, service and id, trimmed", () => {
  assertEquals(keyValue(providers, "google", "places", "k2"), KEY);
  assertEquals(keyValue(providers, "google", "places", "k3"), null);
  assertEquals(keyValue({ providers }, "google", "maps_android", "k1"), KEY);
  assertEquals(keyValue(providers, "google", "roads", "k1"), null);
});

Deno.test("Google's reasons read in plain words", () => {
  const err = (reason: string) => ({ error: { status: "PERMISSION_DENIED", message: "x", details: [{ reason }] } });
  assertEquals(verdictOf(test("google_tiles"), 403, err("SERVICE_DISABLED"), "").title,
    "This API is turned off in the key's project");
  assertEquals(verdictOf(test("google_places_text"), 403, err("API_KEY_SERVICE_BLOCKED"), "").result, "fail");
  assertEquals(verdictOf(test("google_places_text"), 400, { error: { status: "INVALID_ARGUMENT", details: [{ reason: "API_KEY_INVALID" }] } }, "").title,
    "Google doesn't know this key");
  assertEquals(verdictOf(test("google_places_text"), 200, { places: [] }, "").result, "ok");
});

Deno.test("the older APIs' messages: a phone key kept to the Maps SDK passes the key check", () => {
  const denied = (m: string) => ({ status: "REQUEST_DENIED", error_message: m });
  const kept = denied("This API key is not authorized to use this service or API.");
  assertEquals(verdictOf(test("google_key"), 200, kept, "").result, "ok");
  assertEquals(verdictOf(test("google_geocoding"), 200, kept, "").title, "This API isn't allowed for the key");
  const app = denied("This IP, site or mobile application is not authorized to use this API key. Request received from IP address 1.2.3.4, with empty referer");
  assertEquals(verdictOf(test("google_key"), 200, app, "").title, "The key's website list doesn't allow getride.my");
  const android = denied("Requests from this Android client application <empty> are blocked.");
  assertEquals(verdictOf(test("google_key"), 200, android, "").title, "The key's Android app list doesn't match");
  const ios = denied("Requests from this iOS client application <empty> are blocked.");
  assertEquals(verdictOf(test("google_key"), 200, ios, "").title, "The key's iOS app list doesn't match");
  assertEquals(verdictOf(test("google_key"), 200, denied("The provided API key is invalid."), "").title,
    "Google doesn't know this key");
  assertEquals(verdictOf(test("google_geocoding"), 200, { status: "OK", results: [] }, "").result, "ok");
  assertEquals(verdictOf(test("google_key"), 200, { status: "OK" }, "").result, "ok");
});

Deno.test("other providers: status, and errors inside a 200", () => {
  assertEquals(verdictOf(test("mapbox_search"), 401, { message: "Invalid Token" }, "").detail, "Invalid Token");
  assertEquals(verdictOf(test("tomtom_search"), 429, null, "").result, "warn");
  assertEquals(verdictOf(test("arcgis_geocode"), 200, { error: { code: 498, message: "Invalid token." } }, "").detail,
    "Invalid token.");
  assertEquals(verdictOf(test("ipinfo_lookup"), 200, { ip: "8.8.8.8" }, "").result, "ok");
  assertEquals(verdictOf(test("thunderforest_tile"), 200, null, "\x89PNG").result, "ok");
});

Deno.test("the key never shows in what comes back", () => {
  assertEquals(scrub(`bad url https://x?key=${KEY}`, KEY), "bad url https://x?key=••••");
  assertEquals(scrub("short", "abc"), "short");
});

Deno.test("runKeyTest sends the stored key as the app, and reads the answer", async () => {
  const seen: { url?: string; headers?: Record<string, string> } = {};
  const out = await runKeyTest(
    { provider: "google", service: "maps_android", key: "k1", test: "google_key", cert: "ab".repeat(20) },
    deps({ status: 200, text: JSON.stringify({ status: "REQUEST_DENIED", error_message: "This API key is not authorized to use this service or API." }) }, seen),
  );
  assertEquals(out.status, 200);
  const b = out.body as Record<string, unknown>;
  assertEquals([b.result, b.as, b.http, b.ms], ["ok", "android", 200, 50]);
  assert(seen.url!.includes(`key=${KEY}`));
  assertEquals(seen.headers!["X-Android-Package"], "com.taxxee.teksi");
  assertEquals(seen.headers!["X-Android-Cert"], "AB".repeat(20));
});

Deno.test("runKeyTest refuses unknown tests, the browser test and empty keys", async () => {
  const d = deps({ status: 200, text: "{}" });
  assertEquals((await runKeyTest({ provider: "google", service: "places", key: "k2", test: "nope" }, d)).status, 400);
  assertEquals((await runKeyTest({ provider: "google", service: "maps_js", key: "k1", test: "google_maps_js" }, d)).status, 400);
  assertEquals((await runKeyTest({ provider: "mapbox", service: "places", key: "k2", test: "google_tiles" }, d)).status, 400);
  assertEquals((await runKeyTest({ provider: "google", service: "places", key: "k3", test: "google_tiles" }, d)).status, 404);
});

Deno.test("runKeyTest: a network error or timeout, without the key", async () => {
  const out = await runKeyTest(
    { provider: "google", service: "places", key: "k2", test: "google_geocoding" },
    deps(new Error(`error sending request for url (https://maps.googleapis.com/x?key=${KEY})`)),
  );
  const b = out.body as Record<string, string>;
  assertEquals(b.result, "fail");
  assertEquals(b.title, "Couldn't reach the provider");
  assert(!b.detail.includes(KEY));
  const t = Object.assign(new Error("Signal timed out."), { name: "TimeoutError" });
  const timed = await runKeyTest({ provider: "google", service: "places", key: "k2", test: "google_geocoding" }, deps(t));
  assertEquals((timed.body as Record<string, string>).title, "No answer within 10 s");
});

Deno.test("a self-hosted server key must be an https address; Amazon uses the set region", async () => {
  const out = await runKeyTest({ provider: "openstreetmap", service: "nominatim", key: "n1", test: "nominatim_search" },
    deps({ status: 200, text: "[]" }));
  assertEquals((out.body as Record<string, string>).title, "Not a server address");
  const req = await test("amazon_places").request!(KEY, "ap-southeast-1");
  assert(req.url.startsWith("https://places.geo.ap-southeast-1.amazonaws.com/"));
});

Deno.test("Resend (the Reports emails): checks the key, sends nothing", () => {
  const t = test("resend_key");
  assertEquals(t.provider, "email");
  const r = t.request!("re_123", "");
  assertEquals(r.url, "https://api.resend.com/domains");
  assertEquals(r.method ?? "GET", "GET");
  assertEquals(r.headers?.Authorization, "Bearer re_123");
  assertEquals(verdictOf(t, 401, { name: "restricted_api_key" }, "").result, "ok");
  assertEquals(verdictOf(t, 200, { data: [{ name: "getride.my", status: "verified" }] }, "").result, "ok");
  assertEquals(verdictOf(t, 200, { data: [] }, "").result, "warn");
  assertEquals(verdictOf(t, 401, { name: "validation_error", message: "API key is invalid" }, "").result, "fail");
});

Deno.test("AWS: a signed Rekognition call, and a key that isn't one", async () => {
  const aws = [{
    id: "aws",
    services: [{
      id: "rekognition",
      keys: [
        { id: "a1", value: "AKIAIOSFODNN7EXAMPLE:wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY:ap-southeast-1" },
        { id: "a2", value: "not-an-aws-key" },
      ],
    }],
  }];
  const sent: HttpRequest[] = [];
  const d: KeyTestDeps = {
    settings: () => Promise.resolve({ apiProviders: aws, config: null }),
    fetch: (r) => {
      sent.push(r);
      return Promise.resolve({ status: 200, text: '{"CollectionIds":[]}' });
    },
    now: () => 0,
  };
  const ok = await runKeyTest({ provider: "aws", service: "rekognition", key: "a1", test: "aws_rekognition" }, d);
  assertEquals((ok.body as { result: string }).result, "ok");
  assertEquals(sent[0].url, "https://rekognition.ap-southeast-1.amazonaws.com/");
  assertEquals(sent[0].headers?.["X-Amz-Target"], "RekognitionService.ListCollections");
  assert(!JSON.stringify(sent[0]).includes("wJalrXUtnFEMI"), "the secret signs, it is never sent");
  const bad = await runKeyTest({ provider: "aws", service: "rekognition", key: "a2", test: "aws_rekognition" }, d);
  assertEquals((bad.body as { title: string }).title, "Not an AWS key");
});
