import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import type { Profile } from "./geo.ts";
import { type GeoDeps, handleGeo } from "./geo_handler.ts";
import {
  NAS_HEADER,
  nasDistanceRequest,
  type NasLink,
  nasReverseRequest,
  nasRouteRequest,
  nasSearchRequest,
  nasTileSource,
  parseNasDistances,
  parseNasLink,
  parseNasReverse,
  parseNasRoute,
  parseNasSearch,
  profileUsesNas,
  withNas,
} from "./geo_nas.ts";

const SECRET = "s".repeat(64);
const LINK: NasLink = {
  url: "https://maps.example.my",
  tilesUrl: "https://tiles.example.my",
  secret: SECRET,
  online: true,
  routes: true,
  search: true,
  tiles: true,
  timeoutMs: 1500,
};

Deno.test("the link: only an https NAS with its secret; parts only while online", () => {
  assertEquals(parseNasLink(null), null);
  assertEquals(parseNasLink({ url: "http://maps.example.my", secret: SECRET }), null);
  assertEquals(parseNasLink({ url: "https://maps.example.my", secret: "short" }), null);
  assertEquals(parseNasLink({ ...LINK, timeoutMs: 99999 })?.timeoutMs, 5000);
  assertEquals(parseNasLink({ ...LINK, timeoutMs: "x" })?.timeoutMs, 1500);
  const off = parseNasLink({ ...LINK, online: false })!;
  assertEquals([off.routes, off.search, off.tiles], [false, false, false]);
  assertEquals(parseNasLink({ ...LINK, tilesUrl: "nope" })?.tiles, false, "no tile address, no map");
});

const P: Profile = {
  tiles: { light: "nas", dark: "nas", satellite: "app", traffic: "app" },
  search: ["nas", "google"],
  reverse: ["nas"],
  routing: ["nas", "google"],
  distance: ["nas"],
  locate: ["nas", "nominatim"],
};

Deno.test("a profile keeps the NAS only while each part is on", () => {
  assertEquals(profileUsesNas(P), true);
  assertEquals(withNas(P, LINK), P);
  const none = withNas(P, null);
  assertEquals(none.routing, ["google"]);
  assertEquals(none.search, ["google"]);
  assertEquals(none.reverse, ["nominatim"], "an emptied list gets the free default");
  assertEquals(none.distance, ["osrm"]);
  assertEquals(none.tiles.light, "app");
  assertEquals(profileUsesNas(none), false);
  const routesOnly = withNas(P, { ...LINK, search: false, tiles: false });
  assertEquals(routesOnly.routing, ["nas", "google"]);
  assertEquals(routesOnly.search, ["google"]);
  assertEquals(routesOnly.tiles.dark, "app");
});

Deno.test("the NAS map: a keyless MapLibre style, light and dark, no imagery", () => {
  const light = nasTileSource("light", LINK)!;
  assertEquals(light.engine, "maplibre");
  assertEquals(light.style, "https://tiles.example.my/styles/light.json");
  assertEquals(light.keyless, true);
  assertEquals(nasTileSource("dark", LINK)?.style, "https://tiles.example.my/styles/dark.json");
  assertEquals(nasTileSource("satellite", LINK), null);
  assertEquals(nasTileSource("light", { ...LINK, tiles: false }), null);
});

Deno.test("requests carry the secret header and the NAS's timeout", () => {
  const r = nasRouteRequest(LINK, [[3.139, 101.6869], [3.1579, 101.7123]]);
  assertEquals(r.url, "https://maps.example.my/route/v1/driving/101.686900,3.139000;101.712300,3.157900?overview=full&geometries=geojson");
  assertEquals(r.headers?.[NAS_HEADER], SECRET);
  assertEquals(r.timeoutMs, 1500);
  assertStringIncludes(nasDistanceRequest(LINK, [3, 101], [[3.1, 101.1]]).url, "/table/v1/driving/101.000000,3.000000;101.100000,3.100000?sources=0");
  assertEquals(nasSearchRequest(LINK, "klcc & co", "ms", 3.1, 101.6).url,
    "https://maps.example.my/api?q=klcc%20%26%20co&limit=8&lang=ms&lat=3.10000&lon=101.60000");
  assertStringIncludes(nasSearchRequest(LINK, "klcc", "th").url, "lang=en");
  assertStringIncludes(nasReverseRequest(LINK, 3.1, 101.6, "en").url, "/reverse?lat=3.100000&lon=101.600000&limit=1");
});

const OSRM_ROUTE = {
  code: "Ok",
  routes: [{ distance: 4200, duration: 600, geometry: { coordinates: [[101.68, 3.13], [101.71, 3.15]] } }],
};
const PHOTON = {
  features: [
    {
      geometry: { coordinates: [101.7119, 3.1579] },
      properties: { name: "Suria KLCC", street: "Jalan Ampang", city: "Kuala Lumpur", postcode: "50088",
        state: "Kuala Lumpur", country: "Malaysia", district: "KLCC" },
    },
    { geometry: { coordinates: [101.7, 3.1] }, properties: { housenumber: "12", street: "Jalan Ipoh", city: "Kuala Lumpur" } },
    { geometry: { coordinates: [] }, properties: { name: "nowhere" } },
  ],
};

Deno.test("answers are read like any provider's", () => {
  assertEquals(parseNasRoute(OSRM_ROUTE), { distanceKm: 4.2, durationMin: 10, points: [[3.13, 101.68], [3.15, 101.71]] });
  assertEquals(parseNasRoute({ code: "NoRoute" }), null);
  assertEquals(parseNasDistances({ code: "Ok", distances: [[0, 1500, null]] }, 2), [1.5, null]);
  assertEquals(parseNasDistances({ code: "Ok", distances: [[0]] }, 2), null);
  const places = parseNasSearch(PHOTON);
  assertEquals(places.length, 2);
  assertEquals(places[0].name, "Suria KLCC");
  assertEquals(places[0].address, "Suria KLCC, Jalan Ampang, KLCC, Kuala Lumpur, 50088 Kuala Lumpur, Malaysia");
  assertEquals(places[1].name, "12 Jalan Ipoh");
  const area = parseNasReverse(PHOTON, 3.158, 101.712)!;
  assertEquals([area.lat, area.country, area.city, area.suburb], [3.158, "Malaysia", "Kuala Lumpur", "KLCC"]);
  assertEquals(parseNasReverse({ features: [] }, 3, 101), null);
});

// ---- Through handleGeo -----------------------------------------------------------------------

const config = {
  profiles: {
    "rider.web": {
      tiles: { light: "nas", dark: "nas", satellite: "app", traffic: "app" },
      search: ["nas", "google"],
      reverse: ["nas", "nominatim"],
      routing: ["nas", "google"],
      distance: ["nas", "osrm"],
      locate: ["nominatim"],
    },
    "rider.android": {
      tiles: { light: "app", dark: "app", satellite: "app", traffic: "app" },
      search: ["google"],
      reverse: ["nominatim"],
      routing: ["google"],
      distance: ["osrm"],
      locate: ["nominatim"],
    },
  },
  keys: { google_places: "google/places" },
};

function deps(link: NasLink | null, answer: (url: string) => Promise<unknown>) {
  const log: string[] = [];
  const asked: Array<[number, number] | null> = [];
  const d: GeoDeps = {
    settings: () => Promise.resolve({ config, apiProviders: [] }),
    call: (req) => {
      log.push(`call ${new URL(req.url).host} ${req.headers?.[NAS_HEADER] === SECRET ? "secret" : "-"} ${req.timeoutMs}`);
      return answer(req.url);
    },
    take: () => Promise.resolve(true),
    caller: () => Promise.resolve("u1"),
    count: (p, k, ok, cached, detail) => {
      log.push(`count ${p} ${k} ${ok} ${cached}${detail ? ` ${detail}` : ""}`);
      return Promise.resolve();
    },
    cacheGet: () => Promise.resolve(null),
    cachePut: () => Promise.resolve(),
    googleSession: () => Promise.resolve(null),
    iso3: () => null,
    nas: (point) => {
      asked.push(point);
      return Promise.resolve(link);
    },
    nasCount: (kind, ok, _ms, timedOut) => {
      log.push(`nas ${kind} ${ok} ${timedOut}`);
      return Promise.resolve();
    },
    background: (p) => void p,
  };
  return { d, log, asked };
}

const q = (s: string) => new URLSearchParams(s);
const settle = () => new Promise((r) => setTimeout(r, 0));

Deno.test("profile: the NAS first while it is on, left out while it is off", async () => {
  const on = deps(LINK, () => Promise.reject(new Error("unused")));
  // deno-lint-ignore no-explicit-any
  const p = ((await handleGeo(q("action=profile&role=rider&device=web"), "ip", on.d)).body as any).profile;
  assertEquals(p.routing, ["nas", "google"]);
  assertEquals(p.search, ["nas", "google"]);
  assertEquals(p.tiles.light.style, "https://tiles.example.my/styles/light.json");
  assertEquals(on.asked, [null], "the profile asks for the Default rule");

  const offline = deps({ ...LINK, online: false, routes: false, search: false, tiles: false }, () => Promise.reject(new Error("x")));
  // deno-lint-ignore no-explicit-any
  const o = ((await handleGeo(q("action=profile&role=rider&device=web"), "ip", offline.d)).body as any).profile;
  assertEquals(o.routing, ["google"]);
  assertEquals(o.reverse, ["nominatim"]);
  assertEquals(o.distance, ["osrm"]);
  assertEquals(o.tiles.light, null, "the app's own map");
  // deno-lint-ignore no-explicit-any
  assertEquals(((await handleGeo(q("action=profile&role=rider&device=web"), "ip", offline.d)).body as any).profile.refused,
    { light: "The office NAS is offline", dark: "The office NAS is offline" });

  const unused = deps(LINK, () => Promise.reject(new Error("x")));
  await handleGeo(q("action=profile&role=rider&device=android"), "ip", unused.d);
  assertEquals(unused.asked, [], "a profile without the NAS never asks for it");
});

Deno.test("a route from the NAS: its secret, its timeout, counted as served", async () => {
  const { d, log, asked } = deps(LINK, () => Promise.resolve(OSRM_ROUTE));
  const r = await handleGeo(q("action=route&provider=nas&role=rider&device=web&points=3.139,101.6869;3.1579,101.7123"), "ip", d);
  await settle();
  assertEquals(r.status, 200);
  // deno-lint-ignore no-explicit-any
  assertEquals((r.body as any).route.distanceKm, 4.2);
  assertEquals(asked, [[3.139, 101.6869]], "the rule where the trip starts");
  assertEquals(log.filter((l) => l.startsWith("call")), ["call maps.example.my secret 1500"]);
  assertEquals(log.includes("count nas routing true false"), true);
  assertEquals(log.includes("nas routing true false"), true);
});

Deno.test("search and address lookup from the NAS", async () => {
  const { d } = deps(LINK, () => Promise.resolve(PHOTON));
  // deno-lint-ignore no-explicit-any
  const s = (await handleGeo(q("action=search&provider=nas&role=rider&device=web&q=klcc&lat=3.1&lng=101.6"), "ip", d)).body as any;
  assertEquals(s.places.length, 2);
  // deno-lint-ignore no-explicit-any
  const r = (await handleGeo(q("action=reverse&provider=nas&role=rider&device=web&lat=3.158&lng=101.712"), "ip", d)).body as any;
  assertEquals(r.place.suburb, "KLCC");
  const dist = await handleGeo(q("action=distance&provider=nas&role=rider&device=web&from=3.1,101.6&to=3.2,101.7"), "ip",
    deps(LINK, () => Promise.resolve({ code: "Ok", distances: [[0, 12345]] })).d);
  // deno-lint-ignore no-explicit-any
  assertEquals((dist.body as any).distances, [12.345]);
});

Deno.test("slow, offline or off here: the app moves on at once", async () => {
  const slow = deps(LINK, () => Promise.reject(Object.assign(new Error("signal timed out"), { name: "TimeoutError" })));
  const r = await handleGeo(q("action=route&provider=nas&role=rider&device=web&points=3.1,101.6;3.2,101.7"), "ip", slow.d);
  await settle();
  assertEquals(r.status, 502);
  assertEquals(slow.log.includes("count nas routing false false No answer within 1.5 s"), true);
  assertEquals(slow.log.includes("nas routing false true"), true, "counted as timed out");

  const offline = deps({ ...LINK, online: false }, () => Promise.resolve(OSRM_ROUTE));
  const o = await handleGeo(q("action=route&provider=nas&role=rider&device=web&points=3.1,101.6;3.2,101.7"), "ip", offline.d);
  assertEquals(o.status, 503);
  assertEquals(offline.log.some((l) => l.startsWith("call")), false, "nothing sent to an offline NAS");

  const offHere = deps({ ...LINK, search: false }, () => Promise.resolve(PHOTON));
  assertEquals((await handleGeo(q("action=search&provider=nas&role=rider&device=web&q=klcc"), "ip", offHere.d)).status, 403);

  const notListed = deps(LINK, () => Promise.resolve(OSRM_ROUTE));
  assertEquals(
    (await handleGeo(q("action=route&provider=nas&role=rider&device=android&points=3.1,101.6;3.2,101.7"), "ip", notListed.d)).status,
    403,
    "only where the profile lists it",
  );
  const noUser = deps(LINK, () => Promise.resolve(OSRM_ROUTE));
  noUser.d.caller = () => Promise.resolve(null);
  assertEquals(
    (await handleGeo(q("action=route&provider=nas&role=rider&device=web&points=3.1,101.6;3.2,101.7"), "ip", noUser.d)).status,
    401,
    "a signed-in user, as for any provider",
  );
});
