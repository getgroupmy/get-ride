import { assertEquals } from "jsr:@std/assert@1.0.19";

import { BUILTIN_WATCHED, healthState, monitorTargets, serverFromKeyValue } from "./provider_health.ts";

const EKYC_SECRET = "ek_live_0123456789abcdef";
const FACE_SECRET = "0123456789abcdef0123";

Deno.test("serverFromKeyValue: a face / eKYC key gives the address and the key", () => {
  assertEquals(serverFromKeyValue(`https://ekyc.getcdn.link:${EKYC_SECRET}`), {
    url: "https://ekyc.getcdn.link",
    apiKey: EKYC_SECRET,
  });
  assertEquals(serverFromKeyValue(`https://face.getride.my:${FACE_SECRET}`), {
    url: "https://face.getride.my",
    apiKey: FACE_SECRET,
  });
});

Deno.test("serverFromKeyValue: a Umami key gives the address, no key", () => {
  assertEquals(serverFromKeyValue("https://stats.getride.my getride:PASSWORD"), { url: "https://stats.getride.my" });
});

Deno.test("serverFromKeyValue: a bare https address (a custom server)", () => {
  assertEquals(serverFromKeyValue("https://osrm.getride.my"), { url: "https://osrm.getride.my" });
  assertEquals(serverFromKeyValue("https://nas.local:8443/overpass/api"), { url: "https://nas.local:8443" });
});

Deno.test("serverFromKeyValue: not a server address", () => {
  assertEquals(serverFromKeyValue("AIzaSyExampleGoogleMapsKey"), null);
  assertEquals(serverFromKeyValue("AKIA0123456789ABCDEF:secretsecretsecret"), null);
  assertEquals(serverFromKeyValue("http://insecure.example.com"), null, "https only");
  assertEquals(serverFromKeyValue(""), null);
});

Deno.test("monitorTargets: only providers switched on, with a server, and not built-in watched", () => {
  const providers = [
    { id: "ekyc", name: "GET.eKYC", monitor: true, services: [{ id: "server", keys: [{ value: `https://ekyc.getcdn.link:${EKYC_SECRET}` }] }] },
    { id: "umami", name: "Umami", monitor: true, services: [{ id: "api", keys: [{ value: "https://stats.getride.my getride:PW" }] }] },
    { id: "google", name: "Google", monitor: true, services: [{ id: "maps", keys: [{ value: "AIzaKeyNotAServer" }] }] },
    { id: "face_match", name: "Face match server", monitor: true, services: [{ id: "server", keys: [{ value: `https://face.getride.my:${FACE_SECRET}` }] }] },
    { id: "ekyc_off", name: "Off", monitor: false, services: [{ id: "server", keys: [{ value: `https://off.getride.my:${EKYC_SECRET}` }] }] },
  ];
  const targets = monitorTargets(providers);
  assertEquals(targets.map((t) => t.id), ["ekyc", "umami"]);
  assertEquals(targets[0], { id: "ekyc", label: "GET.eKYC", url: "https://ekyc.getcdn.link", apiKey: EKYC_SECRET });
  assertEquals(targets[1], { id: "umami", label: "Umami", url: "https://stats.getride.my", apiKey: undefined });
});

Deno.test("monitorTargets: face_match is the built-in-watched one, and the first usable key wins", () => {
  assertEquals([...BUILTIN_WATCHED], ["face_match"]);
  const providers = [
    {
      id: "ekyc",
      name: "GET.eKYC",
      monitor: true,
      services: [
        { id: "webhook", keys: [{ value: "ek_webhook_secret_not_a_url" }] },
        { id: "server", keys: [{ value: `https://ekyc.getcdn.link:${EKYC_SECRET}`, disabled: true }, { value: `https://ekyc2.getride.my:${EKYC_SECRET}` }] },
      ],
    },
  ];
  assertEquals(monitorTargets(providers).map((t) => t.url), ["https://ekyc2.getride.my"]);
});

Deno.test("monitorTargets: tolerates the wrapped { providers: [...] } shape and junk", () => {
  assertEquals(monitorTargets(null), []);
  assertEquals(monitorTargets({ providers: [] }), []);
  assertEquals(monitorTargets("nonsense"), []);
  assertEquals(
    monitorTargets({ providers: [{ id: "ekyc", name: "GET.eKYC", monitor: true, services: [{ id: "s", keys: [{ value: `https://e.getride.my:${EKYC_SECRET}` }] }] }] }).map((t) => t.id),
    ["ekyc"],
  );
});

Deno.test("GET.ocr (ocr.getcdn.link) is read and watched like the eKYC server", () => {
  const OCR_SECRET = "ocr_live_0123456789abcdef";
  assertEquals(serverFromKeyValue(`https://ocr.getcdn.link:${OCR_SECRET}`), {
    url: "https://ocr.getcdn.link",
    apiKey: OCR_SECRET,
  });
  const providers = [
    { id: "ocr", name: "GET.ocr", monitor: true, services: [{ id: "server", keys: [{ value: `https://ocr.getcdn.link:${OCR_SECRET}` }] }] },
  ];
  assertEquals(monitorTargets(providers), [
    { id: "ocr", label: "GET.ocr", url: "https://ocr.getcdn.link", apiKey: OCR_SECRET },
  ]);
});

Deno.test("healthState: down only when unreachable or 5xx", () => {
  assertEquals(healthState({ status: 200 }), "ok");
  assertEquals(healthState({ status: 401 }), "ok", "answered but key refused is still up");
  assertEquals(healthState({ status: 404 }), "ok", "no /health route is still up");
  assertEquals(healthState({ status: 500 }), "down");
  assertEquals(healthState({ status: 502 }), "down");
  assertEquals(healthState({ status: 530 }), "down", "Cloudflare: tunnel/origin down");
  assertEquals(healthState({ failed: true }), "down", "timeout / connection refused");
  assertEquals(healthState({ status: 0 }), "down");
});
