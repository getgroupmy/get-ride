/**
 * Admin → Settings → Maps: profiles, keys, each provider's request and
 * answer, and the `geo` function's handling (migration 0200).
 *
 *     deno test supabase/functions/_shared/geo_test.ts
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import {
  addressValidationRequest,
  amazonRegionOf,
  cacheSeconds,
  decodeFlexiblePolyline,
  decodePolyline,
  distanceRequest,
  FALLBACK_SECRETS,
  fallbackKey,
  googleAutocompleteRequest,
  googleDetailsRequest,
  googleDirectionsRequest,
  googleDistanceMatrixRequest,
  googleLegacyAutocompleteRequest,
  googleLegacyRefusal,
  googleLegacySearchRequest,
  isShortMapLink,
  keySlot,
  nextMapHop,
  parseAddressValidation,
  parseAutocomplete,
  parseDetails,
  parseDistances,
  parseReverse,
  parseRoute,
  parseSearch,
  profileOf,
  resolveKey,
  reverseRequest,
  routeRequest,
  searchRequest,
  googleLookOf,
  googleMapType,
  googleSessionBody,
  tileSource,
  trafficTileUrl,
  tokenCacheKey,
} from "./geo.ts";
import {
  type GeoDeps,
  googleApiOf,
  googleSearchOf,
  handleGeo,
  parseGoogleSession,
  RefusedSessions,
  smartAddressOf,
} from "./geo_handler.ts";

const apiProviders = [
  {
    id: "google",
    services: [
      { id: "maps", keys: [{ id: "g1", value: "GTILES" }] },
      { id: "places", keys: [{ id: "p0", value: "OLD", disabled: true }, { id: "p1", value: "GPLACES" }] },
      { id: "geocoding", keys: [] },
    ],
  },
  { id: "here", services: [{ id: "api", keys: [{ id: "h1", value: "HKEY" }, { id: "h2", value: "HKEY2" }] }] },
  { id: "tomtom", services: [{ id: "api", keys: [{ id: "t1", value: "TKEY" }] }] },
  { id: "openstreetmap", services: [{ id: "nominatim", keys: [{ id: "n1", value: "https://geo.example.my/" }] }] },
];

Deno.test("keys: the service's first active key, or the one named", () => {
  assertEquals(resolveKey(apiProviders, "google/places"), "GPLACES");
  assertEquals(resolveKey(apiProviders, "here/api#h2"), "HKEY2");
  assertEquals(resolveKey(apiProviders, "here/api#nope"), null);
  assertEquals(resolveKey(apiProviders, "google/geocoding"), null);
  assertEquals(resolveKey(apiProviders, "mapbox/tiles"), null);
  assertEquals(resolveKey(null, "here/api"), null);
});

Deno.test("a missing profile is the app's own", () => {
  const p = profileOf({}, "rider", "web");
  assertEquals(p.tiles.light, "app");
  assertEquals(p.search, ["nominatim"]);
  assertEquals(p.routing, ["osrm"]);
});

Deno.test("tiles per provider and style", () => {
  assertEquals(tileSource("osm", "dark", null)?.darken, true);
  assertEquals(tileSource("osm", "satellite", null), null);
  assertStringIncludes(tileSource("esri", "satellite", null)!.url, "World_Imagery");
  assertEquals(tileSource("mapbox", "light", null), null, "a keyed provider without its key");
  assertStringIncludes(tileSource("mapbox", "dark", "MB")!.url, "dark-v11");
  assertStringIncludes(tileSource("here", "satellite", "H")!.url, "satellite.day");
  assertStringIncludes(tileSource("tomtom", "dark", "T")!.url, "/basic/night/");
  assertStringIncludes(tileSource("maptiler", "light", "M")!.url, "streets-v2/");
  assertEquals(tileSource("google", "light", "G"), null, "Google needs a session");
  assertStringIncludes(tileSource("google", "light", "G", "S1")!.url, "session=S1&key=G");
  assertEquals(tileSource("google_js", "dark", "GJS"), {
    url: "",
    darken: false,
    attribution: "Map data © Google",
    engine: "google_js",
    key: "GJS",
    mapType: "roadmap",
  }, "Google's JavaScript map: no tiles, the browser key");
  assertEquals(tileSource("google_js", "satellite", "GJS")!.mapType, "satellite");
  assertEquals(tileSource("google_js", "light", null), null, "needs its key");
  assertEquals(keySlot("google_js", "tiles"), "google_js");
  for (const p of ["mapbox", "here", "tomtom", "maptiler"]) {
    const u = tileSource(p, "light", "K")!.url;
    assert(u.includes("{z}") && u.includes("{x}") && u.includes("{y}"), p);
  }
  assertStringIncludes(trafficTileUrl("tomtom", "T")!, "traffic/map/4/tile/flow");
  assertEquals(trafficTileUrl("here", null), null);
});

const sp = { q: "klcc", lat: 3.15, lng: 101.71, countries: ["my"], countries3: ["MYS"], lang: "en" };

Deno.test("search: each provider's request carries the key, the country and where the rider is", () => {
  const g = searchRequest("google", sp, "GK")!;
  assertEquals(g.method, "POST");
  assertEquals(g.headers!["X-Goog-Api-Key"], "GK");
  assertEquals(JSON.parse(g.body!).regionCode, "my");
  assertStringIncludes(searchRequest("mapbox", sp, "K")!.url, "proximity=101.71,3.15");
  assertStringIncludes(searchRequest("here", sp, "K")!.url, "in=countryCode:MYS");
  assertStringIncludes(searchRequest("here", { ...sp, lat: undefined, lng: undefined }, "K")!.url, "geocode.search");
  assertStringIncludes(searchRequest("tomtom", sp, "K")!.url, "countrySet=MY");
  assertStringIncludes(searchRequest("locationiq", sp, "K")!.url, "countrycodes=my");
  assertStringIncludes(searchRequest("maptiler", sp, "K")!.url, "/geocoding/klcc.json");
  assertEquals(searchRequest("nominatim", sp, "K"), null);
});

Deno.test("search: answers read the same way", () => {
  const want = [{ name: "KLCC", address: "Jalan Ampang, KL", lat: 3.15, lng: 101.71 }];
  assertEquals(
    parseSearch("google", {
      places: [{ displayName: { text: "KLCC" }, formattedAddress: "Jalan Ampang, KL", location: { latitude: 3.15, longitude: 101.71 } }],
    }),
    want,
  );
  assertEquals(
    parseSearch("mapbox", {
      features: [{ properties: { name: "KLCC", full_address: "Jalan Ampang, KL", coordinates: { latitude: 3.15, longitude: 101.71 } } }],
    }),
    want,
  );
  assertEquals(
    parseSearch("here", { items: [{ title: "KLCC", address: { label: "Jalan Ampang, KL" }, position: { lat: 3.15, lng: 101.71 } }] }),
    want,
  );
  assertEquals(
    parseSearch("tomtom", {
      results: [{ poi: { name: "KLCC" }, address: { freeformAddress: "Jalan Ampang, KL" }, position: { lat: 3.15, lon: 101.71 } }],
    }),
    want,
  );
  assertEquals(
    parseSearch("locationiq", [{ display_place: "KLCC", display_name: "Jalan Ampang, KL", lat: "3.15", lon: "101.71" }]),
    want,
  );
  assertEquals(
    parseSearch("maptiler", { features: [{ text: "KLCC", place_name: "Jalan Ampang, KL", center: [101.71, 3.15] }] }),
    want,
  );
  assertEquals(parseSearch("here", { items: [{ title: "No position" }] }), []);
  assertEquals(parseSearch("google", null), []);
});

Deno.test("reverse: the area, from each provider", () => {
  const g = parseReverse("google", {
    results: [{
      formatted_address: "Jalan Ampang, 50450 Kuala Lumpur, Malaysia",
      address_components: [
        { long_name: "Jalan Ampang", types: ["route"] },
        { long_name: "Kampung Baru", types: ["sublocality", "political"] },
        { long_name: "Kuala Lumpur", types: ["locality"] },
        { long_name: "Wilayah Persekutuan Kuala Lumpur", types: ["administrative_area_level_1"] },
        { long_name: "Malaysia", types: ["country"] },
      ],
    }],
  }, 3.15, 101.71)!;
  assertEquals([g.name, g.city, g.state, g.country, g.suburb], [
    "Jalan Ampang",
    "Kuala Lumpur",
    "Wilayah Persekutuan Kuala Lumpur",
    "Malaysia",
    "Kampung Baru",
  ]);
  const h = parseReverse("here", {
    items: [{ title: "Jalan Ampang", address: { label: "Jalan Ampang, KL", countryName: "Malaysia", state: "KL", city: "KL", district: "KLCC" } }],
  }, 3.15, 101.71)!;
  assertEquals([h.country, h.suburb], ["Malaysia", "KLCC"]);
  const t = parseReverse("tomtom", {
    addresses: [{ address: { streetName: "Jalan Ampang", freeformAddress: "Jalan Ampang, KL", country: "Malaysia", countrySubdivisionName: "KL", municipality: "KL" } }],
  }, 3.15, 101.71)!;
  assertEquals([t.name, t.state], ["Jalan Ampang", "KL"]);
  const l = parseReverse("locationiq", {
    display_name: "Menara, Jalan Ampang, KL",
    address: { country: "Malaysia", state: "KL", city: "Kuala Lumpur", suburb: "KLCC" },
  }, 3.15, 101.71)!;
  assertEquals([l.name, l.city], ["Menara", "Kuala Lumpur"]);
  assertEquals(parseReverse("mapbox", { features: [] }, 3.15, 101.71), null);
  assertStringIncludes(reverseRequest("google", 3.15, 101.71, "en", "K")!.url, "latlng=3.15,101.71");
  assertStringIncludes(reverseRequest("maptiler", 3.15, 101.71, "en", "K")!.url, "/geocoding/101.71,3.15.json");
});

Deno.test("routes: requests with stops, and answers in km and minutes", () => {
  const pts: [number, number][] = [[3.1, 101.6], [3.12, 101.65], [3.15, 101.71]];
  const g = routeRequest("google", pts, "K")!;
  assertEquals(JSON.parse(g.body!).intermediates.length, 1);
  assertStringIncludes(routeRequest("here", pts, "K")!.url, "&via=3.12,101.65");
  assertStringIncludes(routeRequest("tomtom", pts, "K")!.url, "3.1,101.6:3.12,101.65:3.15,101.71");
  assertStringIncludes(routeRequest("mapbox", pts, "K")!.url, "101.6,3.1;101.65,3.12;101.71,3.15");
  assertEquals(routeRequest("google", [[3.1, 101.6]], "K"), null);

  const r = parseRoute("google", {
    routes: [{ distanceMeters: 12000, duration: "900s", polyline: { encodedPolyline: "_p~iF~ps|U_ulLnnqC_mqNvxq`@" } }],
  })!;
  assertEquals([r.distanceKm, r.durationMin], [12, 15]);
  assertEquals(r.points[0], [38.5, -120.2]);
  const m = parseRoute("mapbox", { routes: [{ distance: 5000, duration: 600, geometry: { coordinates: [[101.6, 3.1], [101.7, 3.2]] } }] })!;
  assertEquals(m.points, [[3.1, 101.6], [3.2, 101.7]]);
  const t = parseRoute("tomtom", {
    routes: [{ summary: { lengthInMeters: 3000, travelTimeInSeconds: 300 }, legs: [{ points: [{ latitude: 3.1, longitude: 101.6 }] }] }],
  })!;
  assertEquals([t.distanceKm, t.durationMin, t.points.length], [3, 5, 1]);
  assertEquals(parseRoute("here", { routes: [] }), null);
});

Deno.test("Google's older APIs: Text Search and Directions, and their refusals", () => {
  const ts = googleLegacySearchRequest(sp, "GK");
  assertStringIncludes(ts.url, "maps.googleapis.com/maps/api/place/textsearch/json?query=klcc");
  assertStringIncludes(ts.url, "&region=my&location=3.15,101.71&radius=50000&key=GK");
  assertEquals(
    parseSearch("google", {
      status: "OK",
      results: [{ name: "KLCC", formatted_address: "Jalan Ampang, KL", geometry: { location: { lat: 3.15, lng: 101.71 } } }],
    }),
    [{ name: "KLCC", address: "Jalan Ampang, KL", lat: 3.15, lng: 101.71 }],
  );
  const pts: [number, number][] = [[3.1, 101.6], [3.12, 101.65], [3.15, 101.71]];
  const dr = googleDirectionsRequest(pts, "K")!;
  assertStringIncludes(dr.url, "directions/json?origin=3.1,101.6&destination=3.15,101.71");
  assertStringIncludes(dr.url, "&waypoints=via%3A3.12%2C101.65");
  assertEquals(googleDirectionsRequest([[3.1, 101.6]], "K"), null);
  const r = parseRoute("google", {
    status: "OK",
    routes: [{
      legs: [
        { distance: { value: 7000 }, duration: { value: 600 }, duration_in_traffic: { value: 720 } },
        { distance: { value: 5000 }, duration: { value: 180 } },
      ],
      overview_polyline: { points: "_p~iF~ps|U_ulLnnqC_mqNvxq`@" },
    }],
  })!;
  assertEquals([r.distanceKm, r.durationMin, r.points.length], [12, 15, 3], "traffic time when Google gives it");
  assertEquals(googleLegacyRefusal({ status: "REQUEST_DENIED" }), "REQUEST_DENIED");
  assertEquals(googleLegacyRefusal({ status: "ZERO_RESULTS" }), null);
  assertEquals(googleLegacyRefusal({ places: [] }), null, "the newer APIs have no status");
});

Deno.test("polylines: Google's and HERE's", () => {
  assertEquals(decodePolyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@"), [[38.5, -120.2], [40.7, -120.95], [43.252, -126.453]]);
  // HERE's documented example.
  const pts = decodeFlexiblePolyline("BFoz5xJ67i1B1B7PzIhaxL7Y");
  assertEquals(pts, [[50.10228, 8.69821], [50.10201, 8.69567], [50.10063, 8.6915], [50.09878, 8.68752]]);
});

Deno.test("Google answers are never cached", () => {
  assertEquals(cacheSeconds("google", "search"), 0);
  assert(cacheSeconds("here", "reverse") > 0);
});

Deno.test("Google's tile session answer", () => {
  assertEquals(parseGoogleSession({ session: "S", expiry: "1700000000" }), { session: "S", expiresAt: 1700000000000 });
  assertEquals(parseGoogleSession({}), null);
});

// ---- The handler -------------------------------------------------------------------------------

const config = {
  profiles: {
    "rider.android": {
      tiles: { light: "google", dark: "google", satellite: "esri", traffic: "tomtom" },
      search: ["google", "nominatim"],
      reverse: ["here"],
      routing: ["osrm"],
    },
    "partner.web": {
      tiles: { light: "app", dark: "osm", satellite: "app", traffic: "none" },
      search: ["here"],
      reverse: ["nominatim"],
      routing: ["tomtom", "osrm"],
    },
  },
  keys: { google_tiles: "google/maps", google_places: "google/places", here: "here/api", tomtom: "tomtom/api", nominatim: "openstreetmap/nominatim" },
};

function deps(over: Partial<GeoDeps> = {}) {
  const log: string[] = [];
  const cache = new Map<string, unknown>();
  const d: GeoDeps = {
    settings: () => Promise.resolve({ config, apiProviders }),
    call: (req) => {
      log.push(`call ${new URL(req.url).host}`);
      if (req.url.includes("places.googleapis")) {
        return Promise.resolve({ places: [{ displayName: { text: "KLCC" }, formattedAddress: "KL", location: { latitude: 3, longitude: 101 } }] });
      }
      if (req.url.includes("revgeocode")) {
        return Promise.resolve({ items: [{ title: "Jalan", address: { label: "Jalan, KL", countryName: "Malaysia" } }] });
      }
      return Promise.reject(new Error("down"));
    },
    take: () => Promise.resolve(true),
    caller: () => Promise.resolve("u1"),
    count: (p, k, ok, cached) => {
      log.push(`count ${p} ${k} ${ok} ${cached}`);
      return Promise.resolve();
    },
    cacheGet: (k) => Promise.resolve(cache.get(k) ?? null),
    cachePut: (k, v) => {
      cache.set(k, v);
      return Promise.resolve();
    },
    googleSession: (slot) => Promise.resolve(`S-${slot}`),
    iso3: (cc) => (cc === "my" ? "MYS" : null),
    ...over,
  };
  return { d, log };
}

const q = (s: string) => new URLSearchParams(s);

Deno.test("profile: tiles resolved with keys, the app's own where unset", async () => {
  const { d } = deps();
  // deno-lint-ignore no-explicit-any
  const a = (await handleGeo(q("action=profile&role=rider&device=android"), "1.1.1.1", d)).body as any;
  assertStringIncludes(a.profile.tiles.light.url, "session=S-light&key=GTILES");
  assertStringIncludes(a.profile.tiles.dark.url, "session=S-dark");
  assertStringIncludes(a.profile.tiles.satellite.url, "World_Imagery");
  assertStringIncludes(a.profile.tiles.traffic.url, "key=TKEY");
  assertStringIncludes(a.profile.tiles.traffic.fallback, "apiKey=HKEY");
  assertEquals(a.profile.search, ["google", "nominatim"]);
  assertEquals(a.profile.direct.nominatim, "https://geo.example.my");
  // deno-lint-ignore no-explicit-any
  const w = (await handleGeo(q("action=profile&role=partner&device=web"), "1.1.1.1", d)).body as any;
  assertEquals(w.profile.tiles.light, null);
  assertEquals(w.profile.tiles.dark.darken, true);
  assertEquals(w.profile.tiles.traffic, { off: true });
  // deno-lint-ignore no-explicit-any
  const ios = (await handleGeo(q("action=profile&role=rider&device=ios"), "1.1.1.1", d)).body as any;
  assertEquals(ios.profile.tiles, { light: null, dark: null, satellite: null, traffic: null }, "not configured");
});

Deno.test("lookups: only providers the profile lists, Google never cached, others cached", async () => {
  const { d, log } = deps();
  assertEquals((await handleGeo(q("action=search&provider=here&role=rider&device=android&q=klcc"), "ip", d)).status, 403);
  assertEquals((await handleGeo(q("action=search&provider=nominatim&role=rider&device=android&q=klcc"), "ip", d)).status, 403);
  assertEquals((await handleGeo(q("action=profile&role=admin&device=android"), "ip", d)).status, 400);

  const s = await handleGeo(q("action=search&provider=google&role=rider&device=android&q=klcc&lat=3.1&lng=101.6"), "ip", d);
  // deno-lint-ignore no-explicit-any
  assertEquals((s.body as any).places[0].name, "KLCC");
  await handleGeo(q("action=search&provider=google&role=rider&device=android&q=klcc&lat=3.1&lng=101.6"), "ip", d);
  assertEquals(log.filter((l) => l.startsWith("call places")).length, 2, "asked Google each time");

  const r1 = await handleGeo(q("action=reverse&provider=here&role=rider&device=android&lat=3.1&lng=101.6"), "ip", d);
  // deno-lint-ignore no-explicit-any
  assertEquals((r1.body as any).place.country, "Malaysia");
  await handleGeo(q("action=reverse&provider=here&role=rider&device=android&lat=3.1&lng=101.6"), "ip", d);
  assertEquals(log.filter((l) => l.startsWith("call revgeocode")).length, 1, "HERE's answer came from the cache");
  assert(log.includes("count here reverse true true"));
});

Deno.test("lookups: a reverse lookup a few metres away is the same cached answer", async () => {
  const { d, log } = deps();
  const at = (lat: string, lng: string) =>
    handleGeo(q(`action=reverse&provider=here&role=rider&device=android&lat=${lat}&lng=${lng}`), "ip", d);
  await at("3.10001", "101.60002");
  // GPS jitter of a metre or two: the same ~11 m cell.
  await at("3.10003", "101.60004");
  assertEquals(log.filter((l) => l.startsWith("call revgeocode")).length, 1, "jitter came from the cache");
  // Some 100 m away is a new lookup.
  await at("3.1010", "101.6000");
  assertEquals(log.filter((l) => l.startsWith("call revgeocode")).length, 2, "a new spot asks again");
});

Deno.test("lookups: a provider down, a missing key, the rate limit, bad input", async () => {
  const { d, log } = deps();
  const r = await handleGeo(q("action=route&provider=tomtom&role=partner&device=web&points=3.1,101.6;3.2,101.7"), "ip", d);
  assertEquals(r.status, 502);
  assert(log.includes("count tomtom routing false false"));
  assertEquals((await handleGeo(q("action=route&provider=tomtom&role=partner&device=web&points=3.1,101.6"), "ip", d)).status, 400);
  assertEquals((await handleGeo(q("action=reverse&provider=here&role=rider&device=android&lat=99&lng=1"), "ip", d)).status, 400);

  const noKeys = deps({ settings: () => Promise.resolve({ config, apiProviders: [] }) }).d;
  assertEquals((await handleGeo(q("action=search&provider=here&role=partner&device=web&q=klcc"), "ip", noKeys)).status, 503);

  const limited = deps({ take: () => Promise.resolve(false) }).d;
  assertEquals((await handleGeo(q("action=search&provider=here&role=partner&device=web&q=klcc"), "ip", limited)).status, 429);
  // 0220 review: a key is spent for a signed-in user only, each held to their own limit.
  const anon = deps({ caller: () => Promise.resolve(null) });
  for (const a of [
    "action=search&provider=here&role=partner&device=web&q=klcc",
    "action=reverse&provider=here&role=rider&device=android&lat=3.1&lng=101.6",
  ]) {
    const r = await handleGeo(q(a), "ip", anon.d);
    assertEquals(r.status, 401);
    assertEquals(r.body, { error: "sign_in_required" });
  }
  assertEquals(anon.log.filter((l) => l.startsWith("call")), [], "nothing was asked of a provider");
  assertEquals((await handleGeo(q("action=profile&role=rider&device=web"), "ip", anon.d)).status, 200,
    "the map's tiles need no sign-in");
  const buckets: string[] = [];
  const perUser = deps({ take: (b) => { buckets.push(b); return Promise.resolve(!b.startsWith("user:")); } }).d;
  assertEquals((await handleGeo(q("action=search&provider=here&role=partner&device=web&q=klcc"), "ip", perUser)).status, 429);
  assertEquals(buckets, ["user:u1"]);
});

Deno.test("Google API choice: newer then older (default), newer only, older only", async () => {
  const older = { status: "OK", results: [{ name: "Old KLCC", formatted_address: "KL", geometry: { location: { lat: 3, lng: 101 } } }] };
  const run = async (googleApi: string | undefined, newer: "ok" | "refuses", oldStatus = "OK") => {
    const asked: string[] = [];
    const { d } = deps({
      settings: () => Promise.resolve({ config: { ...config, ...(googleApi ? { googleApi } : {}) }, apiProviders }),
      call: (req) => {
        asked.push(new URL(req.url).host);
        if (req.url.includes("places.googleapis")) {
          return newer === "ok"
            ? Promise.resolve({ places: [{ displayName: { text: "New KLCC" }, formattedAddress: "KL", location: { latitude: 3, longitude: 101 } }] })
            : Promise.reject(new Error("403 from places.googleapis.com (PERMISSION_DENIED)"));
        }
        return Promise.resolve({ ...older, status: oldStatus });
      },
    });
    const a = await handleGeo(q("action=search&provider=google&role=rider&device=android&q=klcc"), "ip", d);
    // deno-lint-ignore no-explicit-any
    return { status: a.status, name: (a.body as any).places?.[0]?.name, asked };
  };
  assertEquals(await run(undefined, "ok"), { status: 200, name: "New KLCC", asked: ["places.googleapis.com"] });
  assertEquals(await run(undefined, "refuses"), {
    status: 200,
    name: "Old KLCC",
    asked: ["places.googleapis.com", "maps.googleapis.com"],
  });
  assertEquals((await run("new", "refuses")).status, 502, "newer only: no older try");
  assertEquals((await run("new", "refuses")).asked, ["places.googleapis.com"]);
  assertEquals(await run("old", "ok"), { status: 200, name: "Old KLCC", asked: ["maps.googleapis.com"] });
  assertEquals((await run("old", "ok", "REQUEST_DENIED")).status, 502, "an older API's refusal is a failure, not an empty answer");
  assertEquals(googleApiOf({ googleApi: "bogus" }), "new_old");

  // Routes the same way.
  const { d } = deps({
    settings: () =>
      Promise.resolve({
        config: { ...config, profiles: { "rider.android": { ...config.profiles["rider.android"], routing: ["google"] } } },
        apiProviders,
      }),
    fallbackKey: () => "GMAP",
    call: (req) =>
      req.url.includes("routes.googleapis")
        ? Promise.reject(new Error("403 from routes.googleapis.com"))
        : Promise.resolve({ status: "OK", routes: [{ legs: [{ distance: { value: 1000 }, duration: { value: 60 } }], overview_polyline: { points: "" } }] }),
  });
  const rt = await handleGeo(q("action=route&provider=google&role=rider&device=android&points=3.1,101.6;3.2,101.7"), "ip", d);
  // deno-lint-ignore no-explicit-any
  assertEquals((rt.body as any).route.distanceKm, 1, "the older Directions API answered");
});

Deno.test("Google's JavaScript map and its traffic, on the web", async () => {
  const web = {
    ...config,
    profiles: {
      "rider.web": {
        tiles: { light: "google_js", dark: "google_js", satellite: "google_js", traffic: "google" },
        search: ["google"],
        reverse: ["nominatim"],
        routing: ["osrm"],
      },
    },
  };
  const sessions: string[] = [];
  const { d } = deps({
    settings: () => Promise.resolve({ config: web, apiProviders: [] }),
    fallbackKey: (slot) => fallbackKey(slot, (n) => ({ GOOGLE_MAPS_JS_API_KEY: "BROWSER", GOOGLE_MAP_API_KEY: "SERVER" })[n]),
    googleSession: (slot) => {
      sessions.push(slot);
      return Promise.resolve("S");
    },
  });
  // deno-lint-ignore no-explicit-any
  const a = (await handleGeo(q("action=profile&role=rider&device=web"), "ip", d)).body as any;
  assertEquals(a.profile.tiles.light, {
    url: "",
    darken: false,
    attribution: "Map data © Google",
    engine: "google_js",
    key: "BROWSER",
    mapType: "roadmap",
  });
  assertEquals(a.profile.tiles.satellite.mapType, "satellite");
  assertEquals(a.profile.tiles.traffic, { google: true });
  assertEquals(sessions, [], "no Map Tiles session for the JavaScript map");
  assertEquals(fallbackKey("google_js", (n) => ({ GOOGLE_MAP_API_KEY: "SERVER" })[n]), "SERVER", "the Maps key when no browser key");
});

Deno.test("share links: followed only through Google's own hosts", async () => {
  assert(isShortMapLink("https://maps.app.goo.gl/AbC123"));
  assert(isShortMapLink("https://goo.gl/maps/XyZ"));
  assert(!isShortMapLink("https://goo.gl/other"));
  assert(!isShortMapLink("http://maps.app.goo.gl/AbC123"), "https only");
  assert(!isShortMapLink("https://evil.example/maps"));
  assertEquals(nextMapHop("/maps/place/x", "https://www.google.com/a"), "https://www.google.com/maps/place/x");
  assertEquals(nextMapHop("https://169.254.169.254/latest", "https://maps.app.goo.gl/a"), null);
  assertEquals(
    nextMapHop(
      "https://consent.google.com/m?continue=https%3A%2F%2Fwww.google.com%2Fmaps%2Fplace%2FKLIA",
      "https://maps.app.goo.gl/a",
    ),
    "https://www.google.com/maps/place/KLIA",
  );

  const hops: Record<string, string> = {
    "https://maps.app.goo.gl/AbC123": "https://www.google.com/maps/place/KLIA/@2.7,101.7,15z/data=!3d2.7456!4d101.7072",
    "https://maps.app.goo.gl/Away": "https://example.com/phish",
  };
  const asked: string[] = [];
  const { d } = deps({
    redirect: (url) => {
      asked.push(url);
      return Promise.resolve(hops[url] ?? null);
    },
  });
  const ok = await handleGeo(q("action=expand&url=https://maps.app.goo.gl/AbC123"), "ip", d);
  assertEquals(ok, {
    status: 200,
    body: { url: "https://www.google.com/maps/place/KLIA/@2.7,101.7,15z/data=!3d2.7456!4d101.7072" },
  });
  assertEquals((await handleGeo(q("action=expand&url=https://maps.app.goo.gl/Away"), "ip", d)).status, 422);
  assertEquals((await handleGeo(q("action=expand&url=https://example.com/x"), "ip", d)).status, 400);
  assert(!asked.includes("https://example.com/x"), "never fetched");
  assert(!asked.includes("https://example.com/phish"), "never followed");
  const limited = deps({ take: () => Promise.resolve(false), redirect: () => Promise.resolve(null) }).d;
  assertEquals((await handleGeo(q("action=expand&url=https://maps.app.goo.gl/AbC123"), "ip", limited)).status, 429);
});

Deno.test("fallback: the function's own Google secrets when Admin → API Keys has none", async () => {
  const env: Record<string, string> = { GOOGLE_MAP_API_KEY: " GMAP ", GOOGLE_PLACES_API_KEY: "GPLACES-ENV" };
  const get = (n: string) => env[n];
  assertEquals(fallbackKey("google_tiles", get), "GMAP");
  assertEquals(fallbackKey("google_routes", get), "GMAP", "routes use the Maps key without a Directions key");
  assertEquals(fallbackKey("google_routes", (n) => ({ ...env, GOOGLE_DIRECTIONS_API_KEY: "GDIR" })[n]), "GDIR");
  assertEquals(fallbackKey("google_geocoding", get), null);
  assertEquals(fallbackKey("here", get), null, "only Google has fallbacks");

  // Admin → API Keys still wins: its Places key is used, not the secret.
  const asked: string[] = [];
  const { d } = deps({
    fallbackKey: (slot) => fallbackKey(slot, get),
    call: (req) => {
      asked.push(req.url + JSON.stringify(req.headers ?? {}));
      return Promise.resolve({ places: [] });
    },
  });
  await handleGeo(q("action=search&provider=google&role=rider&device=android&q=klcc"), "ip", d);
  assert(asked[0].includes("GPLACES") && !asked[0].includes("GPLACES-ENV"));

  // With Admin → API Keys empty, the secret is used.
  asked.length = 0;
  const { d: d2 } = deps({
    settings: () => Promise.resolve({ config, apiProviders: [] }),
    fallbackKey: (slot) => fallbackKey(slot, get),
    call: (req) => {
      asked.push(req.url + JSON.stringify(req.headers ?? {}));
      return Promise.resolve({ places: [] });
    },
  });
  assertEquals((await handleGeo(q("action=search&provider=google&role=rider&device=android&q=klcc"), "ip", d2)).status, 200);
  assert(asked[0].includes("GPLACES-ENV"));

  // The admin page asks which slots have one: names only.
  const slots = await handleGeo(q("action=fallbacks"), "ip", d2);
  assertEquals(slots.body, { slots: ["google_tiles", "google_js", "google_places", "google_address", "google_routes"] });
  assert(!JSON.stringify(slots.body).includes("GMAP"));
  assertEquals((await handleGeo(q("action=fallbacks"), "ip", deps().d)).body, { slots: [] });

  // Neither: Google isn't available.
  const { d: d3 } = deps({ settings: () => Promise.resolve({ config, apiProviders: [] }) });
  assert((await handleGeo(q("action=search&provider=google&role=rider&device=android&q=klcc"), "ip", d3)).status !== 200);
});

Deno.test("distances: one origin to each result, from every provider", () => {
  const from: [number, number] = [3.1, 101.6];
  const to: [number, number][] = [[3.2, 101.7], [2.75, 101.71]];
  assertEquals(profileOf({}, "rider", "web").distance, ["osrm"], "OpenStreetMap by default");
  assertEquals(keySlot("google", "distance"), "google_routes");
  assertEquals(keySlot("tomtom", "distance"), "tomtom");

  const g = distanceRequest("google", from, to, "GK")!;
  assertStringIncludes(g.url, "computeRouteMatrix");
  assertEquals(g.headers?.["X-Goog-Api-Key"], "GK");
  assertEquals(JSON.parse(g.body!).destinations.length, 2);
  assertStringIncludes(googleDistanceMatrixRequest(from, to, "GK").url, "destinations=3.2%2C101.7%7C2.75%2C101.71");
  assertStringIncludes(distanceRequest("mapbox", from, to, "MK")!.url, "driving/101.6,3.1;101.7,3.2;101.71,2.75?sources=0");
  assertStringIncludes(distanceRequest("locationiq", from, to, "LK")!.url, "matrix/driving/101.6,3.1;");
  assertEquals(JSON.parse(distanceRequest("here", from, to, "HK")!.body!).origins, [{ lat: 3.1, lng: 101.6 }]);
  assertEquals(JSON.parse(distanceRequest("tomtom", from, to, "TK")!.body!).destinations[1], {
    point: { latitude: 2.75, longitude: 101.71 },
  });
  assertEquals(distanceRequest("nominatim", from, to, "x"), null);
  assertEquals(distanceRequest("here", from, [], "x"), null);

  // Answers: kilometres in order, null where there's no road.
  assertEquals(
    parseDistances("google", [
      { originIndex: 0, destinationIndex: 1, distanceMeters: 8590, condition: "ROUTE_EXISTS" },
      { originIndex: 0, destinationIndex: 0, condition: "ROUTE_NOT_FOUND" },
    ], 2),
    [null, 8.59],
  );
  assertEquals(parseDistances("google", [{ destinationIndex: 0, condition: "ROUTE_EXISTS" }], 1), [0], "zero is left out");
  assertEquals(
    parseDistances("google", {
      status: "OK",
      rows: [{ elements: [{ status: "OK", distance: { value: 29400 } }, { status: "ZERO_RESULTS" }] }],
    }, 2),
    [29.4, null],
  );
  assertEquals(parseDistances("osrm", { code: "Ok", distances: [[0, 850, null]] }, 2), [0.85, null]);
  assertEquals(parseDistances("mapbox", { distances: [[0, 1200.4, 5000]] }, 2), [1.2, 5]);
  assertEquals(parseDistances("here", { matrix: { distances: [1000, 2000], errorCodes: [0, 3] } }, 2), [1, null]);
  assertEquals(
    parseDistances("tomtom", { data: [{ originIndex: 0, destinationIndex: 1, routeSummary: { lengthInMeters: 3000 } }] }, 2),
    [null, 3],
  );
  assertEquals(parseDistances("tomtom", { error: "x" }, 2), null, "not a matrix");
  assertEquals(cacheSeconds("google", "distance"), 0);
  assertEquals(cacheSeconds("here", "distance"), 3600);
});

Deno.test("distance action: listed providers only, cached, Google's older API when the newer refuses", async () => {
  const cfg = {
    ...config,
    profiles: {
      ...config.profiles,
      "rider.android": { ...config.profiles["rider.android"], distance: ["here", "google", "straight"] },
    },
  };
  const asked: string[] = [];
  const { d, log } = deps({
    settings: () => Promise.resolve({ config: cfg, apiProviders }),
    fallbackKey: (slot) => (slot === "google_routes" ? "GMAP" : null),
    call: (req) => {
      asked.push(new URL(req.url).host);
      if (req.url.includes("matrix.router.hereapi")) return Promise.resolve({ matrix: { distances: [8590, 29000] } });
      if (req.url.includes("routes.googleapis")) return Promise.reject(new Error("403 from routes.googleapis.com"));
      return Promise.resolve({ status: "OK", rows: [{ elements: [{ status: "OK", distance: { value: 1500 } }] }] });
    },
  });
  const url = "action=distance&role=rider&device=android&from=3.1,101.6&to=3.2,101.7;2.75,101.71&provider=";
  const h = await handleGeo(q(url + "here"), "ip", d);
  assertEquals(h.body, { distances: [8.59, 29] });
  await handleGeo(q(url + "here"), "ip", d);
  assertEquals(asked.filter((a) => a.startsWith("matrix")).length, 1, "the second from the cache");
  assert(log.includes("count here distance true true"));

  const g = await handleGeo(q("action=distance&role=rider&device=android&from=3.1,101.6&to=3.2,101.7&provider=google"), "ip", d);
  assertEquals(g.body, { distances: [1.5] });
  assertEquals(asked.slice(-2), ["routes.googleapis.com", "maps.googleapis.com"]);

  assertEquals((await handleGeo(q(url + "straight"), "ip", d)).status, 403, "worked out on the device");
  assertEquals((await handleGeo(q(url + "tomtom"), "ip", d)).status, 403, "not listed");
  assertEquals((await handleGeo(q(url.replace("from=3.1,101.6", "from=99,1") + "here"), "ip", d)).status, 400);
  assertEquals((await handleGeo(q(url.replace(/to=[^&]*/, "to=") + "here"), "ip", d)).status, 400);
  // deno-lint-ignore no-explicit-any
  const prof = (await handleGeo(q("action=profile&role=rider&device=android"), "ip", d)).body as any;
  assertEquals(prof.profile.distance, ["here", "google", "straight"]);
});

Deno.test("Amazon Location (GrabMaps): requests in its region, answers read like the others", () => {
  assertEquals(amazonRegionOf({}), "ap-southeast-5", "Malaysia by default");
  assertEquals(amazonRegionOf({ amazonRegion: "ap-southeast-1" }), "ap-southeast-1");
  assertEquals(amazonRegionOf({ amazonRegion: "us-east-1" }), "ap-southeast-5", "GrabMaps regions only");
  assertEquals(keySlot("amazon", "search"), "amazon");
  assertEquals(keySlot("amazon_js", "tiles"), "amazon_maps");
  assertEquals(cacheSeconds("amazon", "routing"), 0, "never kept");

  const sp = { q: "klcc", countries: ["my"], countries3: ["MYS"], lang: "en-GB" };
  const s = searchRequest("amazon", { ...sp, lat: 3.1, lng: 101.6, amazonRegion: "ap-southeast-1" }, "AK")!;
  assertEquals(s.url, "https://places.geo.ap-southeast-1.amazonaws.com/v2/search-text?key=AK");
  assertEquals(JSON.parse(s.body!), {
    QueryText: "klcc",
    MaxResults: 8,
    Language: "en",
    BiasPosition: [101.6, 3.1],
    Filter: { IncludeCountries: ["MYS"] },
  });
  assertEquals(JSON.parse(searchRequest("amazon", sp, "AK")!.body!).BiasPosition, [101.6869, 3.139], "KL without a fix");
  assertStringIncludes(searchRequest("amazon", sp, "AK")!.url, "ap-southeast-5");
  assertEquals(parseSearch("amazon", {
    ResultItems: [{ Title: "Suria KLCC", Address: { Label: "Jalan Ampang, KL" }, Position: [101.7116, 3.1579] }],
  }), [{ name: "Suria KLCC", address: "Jalan Ampang, KL", lat: 3.1579, lng: 101.7116 }]);

  assertEquals(JSON.parse(reverseRequest("amazon", 3.1, 101.6, "ms", "AK")!.body!), { QueryPosition: [101.6, 3.1], Language: "ms" });
  assertEquals(
    parseReverse("amazon", {
      ResultItems: [{
        Title: "Jalan Ampang",
        Address: {
          Label: "Jalan Ampang, 50450 Kuala Lumpur",
          Country: { Name: "Malaysia" },
          Region: { Name: "Kuala Lumpur" },
          Locality: "Kuala Lumpur",
          District: "KLCC",
        },
      }],
    }, 3.1, 101.6),
    {
      name: "Jalan Ampang",
      address: "Jalan Ampang, 50450 Kuala Lumpur",
      lat: 3.1,
      lng: 101.6,
      country: "Malaysia",
      state: "Kuala Lumpur",
      city: "Kuala Lumpur",
      suburb: "KLCC",
    },
  );

  const r = routeRequest("amazon", [[3.1, 101.6], [3.15, 101.65], [3.2, 101.7]], "AK")!;
  assertEquals(r.url, "https://routes.geo.ap-southeast-5.amazonaws.com/v2/routes?key=AK");
  assertEquals(JSON.parse(r.body!), {
    Origin: [101.6, 3.1],
    Destination: [101.7, 3.2],
    Waypoints: [{ Position: [101.65, 3.15] }],
    TravelMode: "Car",
    LegGeometryFormat: "Simple",
  });
  assertEquals(
    parseRoute("amazon", {
      Routes: [{
        Summary: { Distance: 12500, Duration: 1200 },
        Legs: [{ Geometry: { LineString: [[101.6, 3.1], [101.7, 3.2]] } }],
      }],
    }),
    { distanceKm: 12.5, durationMin: 20, points: [[3.1, 101.6], [3.2, 101.7]] },
  );

  const m = distanceRequest("amazon", [3.1, 101.6], [[3.2, 101.7], [2.75, 101.71]], "AK", "ap-southeast-1")!;
  assertStringIncludes(m.url, "routes.geo.ap-southeast-1.amazonaws.com/v2/route-matrix");
  assertEquals(JSON.parse(m.body!).RoutingBoundary, { Unbounded: true });
  assertEquals(JSON.parse(m.body!).Destinations[1], { Position: [101.71, 2.75] });
  assertEquals(parseDistances("amazon", { RouteMatrix: [[{ Distance: 8590 }, { Error: "NoRoute" }]] }, 2), [8.59, null]);

  // Its map: a MapLibre style, light and dark, no imagery.
  const t = tileSource("amazon_js", "dark", "MAPKEY", null, "ap-southeast-5")!;
  assertEquals(t.engine, "maplibre");
  assertEquals(t.style, "https://maps.geo.ap-southeast-5.amazonaws.com/v2/styles/Standard/descriptor?color-scheme=Dark&key=MAPKEY");
  assertStringIncludes(t.attribution, "Grab");
  assertStringIncludes(tileSource("amazon_js", "light", "K")!.style!, "color-scheme=Light");
  assertEquals(tileSource("amazon_js", "satellite", "K"), null);
  assertEquals(tileSource("amazon_js", "light", null), null, "needs its key");
});

Deno.test("Amazon through geo: the configured region and its own key slots", async () => {
  const cfg = {
    ...config,
    amazonRegion: "ap-southeast-1",
    keys: { ...config.keys, amazon: "amazon/location", amazon_maps: "amazon/maps" },
    profiles: {
      ...config.profiles,
      "partner.web": {
        ...config.profiles["partner.web"],
        tiles: { light: "amazon_js", dark: "amazon_js", satellite: "app", traffic: "app" },
        search: ["amazon"],
      },
    },
  };
  const providers = [
    ...apiProviders,
    { id: "amazon", services: [{ id: "location", keys: [{ id: "a1", value: "SERVERKEY" }] }, { id: "maps", keys: [{ id: "m1", value: "BROWSERKEY" }] }] },
  ];
  const asked: string[] = [];
  const { d } = deps({
    settings: () => Promise.resolve({ config: cfg, apiProviders: providers }),
    call: (req) => {
      asked.push(req.url);
      return Promise.resolve({ ResultItems: [{ Title: "Changi", Address: { Label: "Singapore" }, Position: [103.99, 1.36] }] });
    },
  });
  // deno-lint-ignore no-explicit-any
  const prof = (await handleGeo(q("action=profile&role=partner&device=web"), "ip", d)).body as any;
  assertEquals(prof.profile.tiles.light.engine, "maplibre");
  assertStringIncludes(prof.profile.tiles.light.style, "maps.geo.ap-southeast-1.amazonaws.com");
  assertStringIncludes(prof.profile.tiles.dark.style, "key=BROWSERKEY", "the map's own key");
  const s = await handleGeo(q("action=search&provider=amazon&role=partner&device=web&q=changi"), "ip", d);
  // deno-lint-ignore no-explicit-any
  assertEquals((s.body as any).places[0].name, "Changi");
  assertEquals(asked, ["https://places.geo.ap-southeast-1.amazonaws.com/v2/search-text?key=SERVERKEY"]);
});

Deno.test("Google Autocomplete: suggestions without a position, the pick looked up with the same session", () => {
  const sp = { q: "klia", lat: 3.1, lng: 101.6, countries: ["my"], countries3: ["MYS"], lang: "en" };
  const r = googleAutocompleteRequest(sp, "PK", "sess-12345678");
  assertEquals(r.url, "https://places.googleapis.com/v1/places:autocomplete");
  assertEquals(JSON.parse(r.body!), {
    input: "klia",
    languageCode: "en",
    includedRegionCodes: ["my"],
    locationBias: { circle: { center: { latitude: 3.1, longitude: 101.6 }, radius: 50000 } },
    origin: { latitude: 3.1, longitude: 101.6 },
    sessionToken: "sess-12345678",
  });
  assertStringIncludes(googleLegacyAutocompleteRequest(sp, "PK", "sess-12345678").url, "components=country:my");
  assertStringIncludes(googleLegacyAutocompleteRequest(sp, "PK", null).url, "&origin=3.1,101.6&key=PK");

  assertEquals(
    parseAutocomplete({
      suggestions: [{
        placePrediction: {
          placeId: "ChIJ-klia",
          text: { text: "KLIA Terminal 1, Sepang, Selangor, Malaysia" },
          structuredFormat: { mainText: { text: "KLIA Terminal 1" }, secondaryText: { text: "Sepang, Selangor, Malaysia" } },
          types: ["airport", "establishment"],
          distanceMeters: 38000,
        },
      }, { queryPrediction: { text: { text: "klia express" } } }],
    }),
    [{
      name: "KLIA Terminal 1",
      address: "Sepang, Selangor, Malaysia",
      lat: null,
      lng: null,
      id: "ChIJ-klia",
      types: ["airport", "establishment"],
      km: 38,
    }],
  );
  assertEquals(parseAutocomplete({
    status: "OK",
    predictions: [{ place_id: "ChIJ-2", description: "KLIA2, Sepang", types: ["airport"] }],
  })[0], { name: "KLIA2", address: "KLIA2, Sepang", lat: null, lng: null, id: "ChIJ-2", types: ["airport"], km: null });

  const d = googleDetailsRequest("ChIJ-klia", "en", "PK", "sess-12345678");
  assertEquals(d.url, "https://places.googleapis.com/v1/places/ChIJ-klia?languageCode=en&sessionToken=sess-12345678");
  assertEquals(
    parseDetails({ displayName: { text: "KLIA" }, formattedAddress: "Sepang", location: { latitude: 2.74, longitude: 101.7 }, types: ["airport"] }),
    { name: "KLIA", address: "Sepang", lat: 2.74, lng: 101.7, types: ["airport"] },
  );
  assertEquals(
    parseDetails({ result: { name: "KLIA2", formatted_address: "Sepang", geometry: { location: { lat: 2.74, lng: 101.68 } } } }),
    { name: "KLIA2", address: "Sepang", lat: 2.74, lng: 101.68 },
  );

  const v = addressValidationRequest("12 Jalan Eco Majestic 1/2D", "my", "AV");
  assertEquals(JSON.parse(v.body!), { address: { regionCode: "MY", addressLines: ["12 Jalan Eco Majestic 1/2D"] } });
  assertEquals(
    parseAddressValidation({
      result: {
        verdict: { addressComplete: true },
        address: { formattedAddress: "12, Jalan Eco Majestic 1/2D, Eco Majestic, 43500 Semenyih, Selangor, Malaysia" },
        geocode: { location: { latitude: 2.94, longitude: 101.84 } },
      },
    }),
    { address: "12, Jalan Eco Majestic 1/2D, Eco Majestic, 43500 Semenyih, Selangor, Malaysia", lat: 2.94, lng: 101.84, complete: true },
  );
  assertEquals(parseAddressValidation({}), null);
  assertEquals(googleSearchOf({ googleSearch: "autocomplete" }), "autocomplete");
  assertEquals(googleSearchOf({}), "text");
  assertEquals(smartAddressOf({ smartAddress: "all" }), "all");
  assertEquals(smartAddressOf({ smartAddress: "x" }), "normal");
  assertEquals(FALLBACK_SECRETS.google_tiles, ["GOOGLE_MAP_TILES_API_KEY", "GOOGLE_MAP_API_KEY"], "a tiles key of its own first");
});

Deno.test("Autocomplete, details and validate through geo", async () => {
  const cfg = { ...config, googleSearch: "autocomplete", smartAddress: "all", keys: { ...config.keys, google_address: "google/address_validation" } };
  const providers = [
    ...apiProviders.filter((p) => p.id !== "google"),
    { id: "google", services: [...apiProviders[0].services, { id: "address_validation", keys: [{ id: "v1", value: "AVKEY" }] }] },
  ];
  const asked: string[] = [];
  const { d } = deps({
    settings: () => Promise.resolve({ config: cfg, apiProviders: providers }),
    call: (req) => {
      asked.push(req.url.replace(/key=[^&]+/, "key=…"));
      if (req.url.includes("places:autocomplete")) {
        return Promise.resolve({ suggestions: [{ placePrediction: { placeId: "ChIJ-klia1", text: { text: "KLIA, Sepang" } } }] });
      }
      if (req.url.includes("/v1/places/")) {
        return Promise.resolve({ displayName: { text: "KLIA" }, formattedAddress: "Sepang", location: { latitude: 2.74, longitude: 101.7 } });
      }
      return Promise.resolve({ result: { address: { formattedAddress: "12, Jalan X, 43500 Semenyih" }, verdict: {} } });
    },
  });
  // deno-lint-ignore no-explicit-any
  const prof = (await handleGeo(q("action=profile&role=rider&device=android"), "ip", d)).body as any;
  assertEquals([prof.profile.googleSearch, prof.profile.smartAddress], ["autocomplete", "all"]);
  // deno-lint-ignore no-explicit-any
  const s = (await handleGeo(q("action=search&provider=google&role=rider&device=android&q=klia&session=sess-12345678"), "ip", d)).body as any;
  assertEquals(s.places[0].id, "ChIJ-klia1");
  assertEquals(s.places[0].lat, null);
  // deno-lint-ignore no-explicit-any
  const p = (await handleGeo(q("action=details&provider=google&role=rider&device=android&id=ChIJ-klia1&session=sess-12345678"), "ip", d)).body as any;
  assertEquals(p.place, { name: "KLIA", address: "Sepang", lat: 2.74, lng: 101.7 });
  assertStringIncludes(asked[1], "sessionToken=sess-12345678");
  assertEquals((await handleGeo(q("action=details&role=partner&device=web&id=ChIJ-klia1"), "ip", d)).status, 403, "Google not listed");
  assertEquals((await handleGeo(q("action=details&role=rider&device=android&id=bad id"), "ip", d)).status, 400);
  // deno-lint-ignore no-explicit-any
  const v = (await handleGeo(q("action=validate&role=rider&device=android&address=12 Jalan X Semenyih"), "ip", d)).body as any;
  assertEquals(v.checked, { address: "12, Jalan X, 43500 Semenyih", lat: null, lng: null, complete: false });
  assertStringIncludes(asked[2], "addressvalidation.googleapis.com");

  const off = deps({ settings: () => Promise.resolve({ config, apiProviders }) }).d;
  assertEquals((await handleGeo(q("action=validate&role=rider&device=android&address=12 Jalan X"), "ip", off)).status, 403, "C off");
});

Deno.test("locate: by the profile's locate list, Google's Text Search even when search is Autocomplete", async () => {
  const cfg = {
    ...config,
    googleSearch: "autocomplete",
    profiles: { ...config.profiles, "rider.android": { ...config.profiles["rider.android"], locate: ["google"] } },
  };
  const asked: string[] = [];
  const { d, log } = deps({
    settings: () => Promise.resolve({ config: cfg, apiProviders }),
    call: (req) => {
      asked.push(req.url);
      return Promise.resolve({ places: [{ displayName: { text: "KLIA T2" }, formattedAddress: "Sepang", location: { latitude: 2.74, longitude: 101.68 } }] });
    },
  });
  // deno-lint-ignore no-explicit-any
  const prof = (await handleGeo(q("action=profile&role=rider&device=android"), "ip", d)).body as any;
  assertEquals(prof.profile.locate, ["google"]);
  // deno-lint-ignore no-explicit-any
  const r = (await handleGeo(q("action=locate&provider=google&role=rider&device=android&q=KLIA T2, Selangor&lat=3.1&lng=101.6"), "ip", d)).body as any;
  assertEquals(r.places[0], { name: "KLIA T2", address: "Sepang", lat: 2.74, lng: 101.68 });
  assertStringIncludes(asked[0], "places:searchText");
  assertEquals(log.at(-1), "count google search true false");
  assertEquals((await handleGeo(q("action=locate&provider=here&role=rider&device=android&q=klia"), "ip", d)).status, 403, "not on the locate list");
  const plain = deps().d;
  // deno-lint-ignore no-explicit-any
  const p = (await handleGeo(q("action=profile&role=rider&device=android"), "ip", plain)).body as any;
  assertEquals(p.profile.locate, ["nominatim"], "OpenStreetMap by default");
});

Deno.test("profile: why a set map slot fell back, for Admin → Maps → Test", async () => {
  const cfg = {
    ...config,
    profiles: {
      ...config.profiles,
      "rider.android": { ...config.profiles["rider.android"], tiles: { light: "google", dark: "mapbox", satellite: "app", traffic: "app" } },
    },
  };
  const { d } = deps({
    settings: () => Promise.resolve({ config: cfg, apiProviders }),
    googleSession: () => Promise.reject(new Error("403 from tile.googleapis.com (PERMISSION_DENIED, SERVICE_DISABLED)")),
  });
  // deno-lint-ignore no-explicit-any
  const p = ((await handleGeo(q("action=profile&role=rider&device=android"), "ip", d)).body as any).profile;
  assertEquals(p.tiles.light, null, "the app's own map instead");
  assertStringIncludes(p.refused.light, "SERVICE_DISABLED");
  assertEquals(p.refused.dark, "No key");
  assertEquals(p.refused.satellite, undefined, "built in by choice");
});

const allGoogle = {
  ...config,
  profiles: {
    ...config.profiles,
    "rider.android": { ...config.profiles["rider.android"], tiles: { light: "google", dark: "google", satellite: "google", traffic: "app" } },
  },
};

Deno.test("profile: the three tile sessions are asked at once, the answer as before", async () => {
  const asked: string[] = [];
  const answers: Record<string, (v: string | null) => void> = {};
  const fail: Record<string, (e: Error) => void> = {};
  const { d } = deps({
    settings: () => Promise.resolve({ config: allGoogle, apiProviders }),
    googleSession: (slot) => {
      asked.push(slot);
      return new Promise((resolve, reject) => {
        answers[slot] = resolve;
        fail[slot] = reject;
      });
    },
  });
  const pending = handleGeo(q("action=profile&role=rider&device=android"), "ip", d);
  // Let the handler reach the sessions: all three are asked before any answers.
  for (let i = 0; i < 20 && asked.length < 3; i++) await new Promise((r) => setTimeout(r, 0));
  assertEquals(asked.sort(), ["dark", "light", "satellite"]);
  // Answered out of order; the refusals still read in slot order.
  fail.satellite(new Error("403 satellite"));
  answers.dark("S-dark");
  fail.light(new Error("403 light"));
  // deno-lint-ignore no-explicit-any
  const p = ((await pending).body as any).profile;
  assertEquals(p.tiles.light, null);
  assertStringIncludes(p.tiles.dark.url, "session=S-dark&key=GTILES");
  assertEquals(p.tiles.satellite, null);
  assertEquals(p.refused, { light: "403 light", satellite: "403 satellite" });
  assertEquals(Object.keys(p.refused), ["light", "satellite"]);
  assertEquals(Object.keys(p).slice(0, 10), [
    "tiles", "refused", "search", "reverse", "routing", "distance", "locate", "googleSearch", "smartAddress", "direct",
  ], "same fields, same order");
  assertEquals(Object.keys(p.tiles), ["light", "dark", "satellite", "traffic"]);
});

Deno.test("profile: a refused Google session is not asked again for 10 minutes", async () => {
  let now = 1_000_000;
  const refusedSessions = new RefusedSessions(10 * 60_000, () => now);
  let up = false;
  const asked: string[] = [];
  const { d } = deps({
    settings: () => Promise.resolve({ config: allGoogle, apiProviders }),
    refusedSessions,
    googleSession: (slot) => {
      asked.push(slot);
      return up || slot === "dark"
        ? Promise.resolve(`S-${slot}`)
        : Promise.reject(new Error("403 from tile.googleapis.com (PERMISSION_DENIED, SERVICE_DISABLED)"));
    },
  });
  const profile = async () =>
    // deno-lint-ignore no-explicit-any
    ((await handleGeo(q("action=profile&role=rider&device=android"), "ip", d)).body as any).profile;

  const first = await profile();
  assertEquals(asked.sort(), ["dark", "light", "satellite"]);
  assertStringIncludes(first.refused.light, "SERVICE_DISABLED");

  asked.length = 0;
  now += 9 * 60_000;
  const again = await profile();
  assertEquals(asked, ["dark"], "the refused slots answer at once");
  assertEquals(again.refused, first.refused, "and still say why");
  assertEquals(again.tiles, first.tiles);

  asked.length = 0;
  up = true;
  now += 2 * 60_000;
  const later = await profile();
  assertEquals(asked.sort(), ["dark", "light", "satellite"], "asked again after 10 minutes");
  assertEquals(later.refused, {});
  assertStringIncludes(later.tiles.light.url, "session=S-light");
});

Deno.test("refused sessions: per slot, map type, region and key", () => {
  let now = 0;
  const r = new RefusedSessions(600_000, () => now);
  const look = { satellite: "satellite", map: "roadmap" } as const;
  r.remember(RefusedSessions.id("light", "K", "my", look), "403");
  assertEquals(r.reason(RefusedSessions.id("light", "K", "my", look)), "403");
  assertEquals(r.reason(RefusedSessions.id("dark", "K", "my", look)), null);
  assertEquals(r.reason(RefusedSessions.id("light", "K", "sg", look)), null);
  assertEquals(r.reason(RefusedSessions.id("light", "K2", "my", look)), null, "a new key is tried");
  assertEquals(r.reason(RefusedSessions.id("light", "K", "my", { ...look, map: "terrain" })), null);
  now = 600_000;
  assertEquals(r.reason(RefusedSessions.id("light", "K", "my", look)), null);
});

Deno.test("Google's own map on phones: no key sent, the build carries it (0210)", async () => {
  const cfg = {
    ...config,
    profiles: {
      ...config.profiles,
      "rider.android": {
        ...config.profiles["rider.android"],
        tiles: { light: "google_native", dark: "google_native", satellite: "google_native", traffic: "google" },
      },
    },
  };
  const { d } = deps({ settings: () => Promise.resolve({ config: cfg, apiProviders }) });
  // deno-lint-ignore no-explicit-any
  const p = ((await handleGeo(q("action=profile&role=rider&device=android"), "ip", d)).body as any).profile;
  assertEquals(p.tiles.light, { url: "", darken: false, attribution: "Map data © Google", engine: "google_native", mapType: "roadmap" });
  assertEquals(p.tiles.satellite.mapType, "satellite");
  assertEquals(p.tiles.traffic, { google: true });
  assertEquals(p.refused, {});
});

Deno.test("Apple's own map on iPhones: no key, its standard map and the chosen imagery (0214)", async () => {
  const cfg = {
    ...config,
    profiles: {
      ...config.profiles,
      "rider.ios": {
        ...config.profiles["rider.android"],
        tiles: { light: "apple_native", dark: "apple_native", satellite: "apple_native", traffic: "app" },
      },
    },
  };
  const { d } = deps({ settings: () => Promise.resolve({ config: cfg, apiProviders }) });
  // deno-lint-ignore no-explicit-any
  const p = ((await handleGeo(q("action=profile&role=rider&device=ios"), "ip", d)).body as any).profile;
  assertEquals(p.tiles.light, { url: "", darken: false, attribution: "Apple Maps", engine: "apple_native", mapType: "roadmap" });
  assertEquals(p.tiles.satellite.mapType, "satellite");
  const look = googleLookOf({ googleSatellite: "hybrid", googleMap: "terrain" });
  assertEquals(tileSource("apple_native", "light", null, null, undefined, look)!.mapType, "roadmap", "no terrain");
  assertEquals(tileSource("apple_native", "satellite", null, null, undefined, look)!.mapType, "hybrid");
});

Deno.test("Google's look (0211): hybrid satellite and terrain, the dark map the night roadmap", () => {
  const look = googleLookOf({ googleSatellite: "hybrid", googleMap: "terrain" });
  assertEquals(look, { satellite: "hybrid", map: "terrain" });
  assertEquals(googleLookOf(null), { satellite: "satellite", map: "roadmap" });
  assertEquals(googleLookOf({ googleSatellite: "train", googleMap: "m" }), { satellite: "satellite", map: "roadmap" });
  assertEquals([googleMapType("light", look), googleMapType("dark", look), googleMapType("satellite", look)],
    ["terrain", "roadmap", "hybrid"]);
  assertEquals(tileSource("google_native", "satellite", null, null, undefined, look)!.mapType, "hybrid");
  assertEquals(tileSource("google_js", "light", "K", null, undefined, look)!.mapType, "terrain");
  assertEquals(tileSource("google_js", "dark", "K", null, undefined, look)!.mapType, "roadmap");

  assertEquals(googleSessionBody("satellite", "my", "en-US", look), {
    mapType: "satellite",
    language: "en-US",
    region: "MY",
    layerTypes: ["layerRoadmap"],
  });
  assertEquals(googleSessionBody("light", "my", "en-US", look).mapType, "terrain");
  assertEquals(googleSessionBody("light", "my", "en-US", look).layerTypes, ["layerRoadmap"]);
  const dark = googleSessionBody("dark", "my", "en-US", look);
  assertEquals([dark.mapType, "layerTypes" in dark, "styles" in dark], ["roadmap", false, true]);
  assertEquals("layerTypes" in googleSessionBody("satellite", "my"), false, "imagery only by default");
});

Deno.test("the profile asks Map Tiles for the look set", async () => {
  const cfg = {
    ...config,
    googleSatellite: "hybrid",
    googleMap: "terrain",
    profiles: {
      ...config.profiles,
      "rider.android": {
        ...config.profiles["rider.android"],
        tiles: { light: "google", dark: "google", satellite: "google", traffic: "app" },
      },
    },
  };
  const asked: string[] = [];
  const { d } = deps({
    settings: () => Promise.resolve({ config: cfg, apiProviders }),
    googleSession: (slot, _key, _region, look) => {
      asked.push(`${slot}:${googleMapType(slot, look)}`);
      return Promise.resolve(`S-${slot}`);
    },
  });
  await handleGeo(q("action=profile&role=rider&device=android"), "ip", d);
  assertEquals(asked.sort(), ["dark:roadmap", "light:terrain", "satellite:hybrid"]);
});

Deno.test("Google's unofficial tiles for testing (0211): no key, the look set, dark darkened", () => {
  const plain = tileSource("google_xyz", "light", null)!;
  assertEquals(plain, {
    url: "https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}",
    darken: false,
    attribution: "Map data © Google",
  });
  assertEquals(tileSource("google_xyz", "dark", null)!.darken, true);
  assertEquals(tileSource("google_xyz", "satellite", null)!.url, "https://mt1.google.com/vt/lyrs=s&x={x}&y={y}&z={z}");
  const look = { satellite: "hybrid" as const, map: "terrain" as const };
  assertStringIncludes(tileSource("google_xyz", "satellite", null, null, undefined, look)!.url, "lyrs=y&");
  assertStringIncludes(tileSource("google_xyz", "light", null, null, undefined, look)!.url, "lyrs=p&");
  assertStringIncludes(tileSource("google_xyz", "dark", null, null, undefined, look)!.url, "lyrs=m&");
});

Deno.test("the caller cache keys a token by its SHA-256, never the token", async () => {
  const key = await tokenCacheKey("abc");
  assertEquals(key, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  assertEquals(await tokenCacheKey("abc"), key);
  assert(!key.includes("abc"));
  assert(await tokenCacheKey("abd") !== key);
});
