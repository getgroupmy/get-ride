/**
 * Admin → Settings → Maps: profiles, keys, each provider's request and
 * answer, and the `geo` function's handling (migration 0200).
 *
 *     deno test supabase/functions/_shared/geo_test.ts
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import {
  cacheSeconds,
  decodeFlexiblePolyline,
  decodePolyline,
  fallbackKey,
  googleDirectionsRequest,
  googleLegacyRefusal,
  googleLegacySearchRequest,
  keySlot,
  parseReverse,
  parseRoute,
  parseSearch,
  profileOf,
  resolveKey,
  reverseRequest,
  routeRequest,
  searchRequest,
  tileSource,
  trafficTileUrl,
} from "./geo.ts";
import { type GeoDeps, googleApiOf, handleGeo, parseGoogleSession } from "./geo_handler.ts";

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
  assertEquals(slots.body, { slots: ["google_tiles", "google_js", "google_places", "google_routes"] });
  assert(!JSON.stringify(slots.body).includes("GMAP"));
  assertEquals((await handleGeo(q("action=fallbacks"), "ip", deps().d)).body, { slots: [] });

  // Neither: Google isn't available.
  const { d: d3 } = deps({ settings: () => Promise.resolve({ config, apiProviders: [] }) });
  assert((await handleGeo(q("action=search&provider=google&role=rider&device=android&q=klcc"), "ip", d3)).status !== 200);
});
