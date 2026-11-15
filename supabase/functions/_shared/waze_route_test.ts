import { assertEquals } from "jsr:@std/assert@1.0.19";
import {
  areaMatch,
  areaOf,
  askWazeServer,
  cleanServerUrl,
  estimateFromLegs,
  GMAP_KIND,
  gmapServersOf,
  healthVerdict,
  legUrl,
  orderServersFor,
  placeFromRegions,
  wazeServersOf,
} from "./waze_route.ts";

const server = { id: "s1", label: "Office NAS", url: "https://route1.getride.my", key: "k", enabled: true };
const klcc = { latitude: 3.1579, longitude: 101.7116 };
const klia = { latitude: 2.7456, longitude: 101.7099 };
const putrajaya = { latitude: 2.9264, longitude: 101.6964 };

Deno.test("cleanServerUrl: https only, no credentials or query, no trailing slash", () => {
  assertEquals(cleanServerUrl("https://route1.getride.my/"), "https://route1.getride.my");
  assertEquals(cleanServerUrl(" https://x.example/api// "), "https://x.example/api");
  assertEquals(cleanServerUrl("http://route1.getride.my"), null);
  assertEquals(cleanServerUrl("https://u:p@route1.getride.my"), null);
  assertEquals(cleanServerUrl("https://route1.getride.my/?a=1"), null);
  assertEquals(cleanServerUrl("not a url"), null);
});

Deno.test("wazeServersOf: enabled servers with a url and key, in order", () => {
  const list = wazeServersOf({
    wazeServers: [
      { id: "a", label: "One", url: "https://a.example/", key: " k1 ", enabled: true },
      { id: "b", url: "https://b.example", key: "k2", enabled: false },
      { id: "c", url: "http://c.example", key: "k3" },
      { url: "https://d.example", key: "" },
      { url: "https://e.example", key: "k5" },
      "junk",
    ],
  });
  assertEquals(list, [
    { id: "a", label: "One", url: "https://a.example", key: "k1", enabled: true },
    { id: "waze-5", label: "Waze server 5", url: "https://e.example", key: "k5", enabled: true },
  ]);
  assertEquals(wazeServersOf({}), []);
});

Deno.test("legUrl: from, to and one route", () => {
  assertEquals(
    legUrl(server, klcc, klia),
    "https://route1.getride.my/routes/search?from=3.157900%2C101.711600&to=2.745600%2C101.709900&max_routes=1",
  );
});

Deno.test("estimateFromLegs: adds legs, rounds, lists tolls", () => {
  const e = estimateFromLegs([
    { name: "Maju Expwy", distance_meters: 30_450, duration_seconds: 1_830, toll: { price: 3.799999, road_name: "MEX" } },
    { name: "ELITE", distance_meters: 25_000, duration_seconds: 1_200, toll: { price: 0 } },
  ]);
  assertEquals(e, {
    distance_km: 55.5,
    duration_min: 51,
    summary: "Via Maju Expwy, then ELITE (Waze live traffic)",
    toll_count: 1,
    toll_total: 3.8,
    tolls: [{ id: "toll-0", name: "MEX", charge: 3.8 }],
  });
  assertEquals(estimateFromLegs([{ distance_meters: 0, duration_seconds: 10 }]), null);
});

function fakeFetch(answers: { status: number; body: unknown }[], seen: { url: string; key: string | null }[]) {
  return (url: string, init: RequestInit) => {
    seen.push({ url, key: new Headers(init.headers).get("X-Route-Key") });
    const a = answers.shift()!;
    return Promise.resolve(new Response(JSON.stringify(a.body), { status: a.status }));
  };
}

Deno.test("askWazeServer: one call per leg with the key, legs added", async () => {
  const seen: { url: string; key: string | null }[] = [];
  const r = await askWazeServer(server, [klcc, putrajaya, klia], fakeFetch([
    { status: 200, body: { routes: [{ name: "A", distance_meters: 30_000, duration_seconds: 1_800 }] } },
    { status: 200, body: { routes: [{ name: "B", distance_meters: 20_000, duration_seconds: 900 }] } },
  ], seen));
  assertEquals(seen.length, 2);
  assertEquals(seen.every((s) => s.key === "k"), true);
  assertEquals(r.error, null);
  assertEquals(r.httpStatus, 200);
  assertEquals(r.estimate?.distance_km, 50);
  assertEquals(r.estimate?.duration_min, 45);
});

Deno.test("askWazeServer: an error answer fails the server with its message", async () => {
  const r = await askWazeServer(server, [klcc, klia], fakeFetch([
    { status: 401, body: { error: "missing or wrong X-Route-Key" } },
  ], []));
  assertEquals(r.estimate, null);
  assertEquals(r.httpStatus, 401);
  assertEquals(r.error, "HTTP 401: missing or wrong X-Route-Key");
});

Deno.test("askWazeServer: no routes and a thrown fetch fail cleanly", async () => {
  const empty = await askWazeServer(server, [klcc, klia], fakeFetch([{ status: 200, body: { routes: [] } }], []));
  assertEquals(empty.error, "No route in the answer");
  const thrown = await askWazeServer(server, [klcc, klia], () => Promise.reject(new TypeError("network down")));
  assertEquals(thrown.estimate, null);
  assertEquals(thrown.error, "TypeError: network down");
});

Deno.test("areaOf: names from the top down, a gap drops what is under it", () => {
  assertEquals(areaOf({ country: " Malaysia ", state: "Selangor", city: "", suburb: "Kota Damansara" }), {
    country: "Malaysia",
    state: "Selangor",
    city: "",
    suburb: "",
  });
  assertEquals(areaOf({ country: "" }), null);
  assertEquals(areaOf(null), null);
});

Deno.test("placeFromRegions: the smallest outline holding the point at each level", () => {
  assertEquals(
    placeFromRegions([
      { region_table: "countries", country: "Malaysia", inside: true, area: 300 },
      { region_table: "countries", country: "Singapore", inside: false, area: 1 },
      { region_table: "states", country: "Malaysia", state: "Selangor", inside: true, area: 8 },
      { region_table: "states", country: "Malaysia", state: "Big", inside: true, area: 90 },
      { region_table: "cities", country: "Malaysia", state: "Selangor", city: "Petaling Jaya", inside: true, area: 1 },
      { region_table: "suburbs", country: "Malaysia", state: "Selangor", city: "Petaling Jaya", suburb: "SS2", inside: null },
    ]),
    { country: "Malaysia", state: "Selangor", city: "Petaling Jaya", suburb: "" },
  );
  assertEquals(placeFromRegions(null), { country: "", state: "", city: "", suburb: "" });
});

const pj = { country: "Malaysia", state: "Selangor", city: "Petaling Jaya", suburb: "SS2" };

Deno.test("areaMatch: level of a match, 0 for any area, -1 elsewhere", () => {
  assertEquals(areaMatch(undefined, pj), 0);
  assertEquals(areaMatch({ country: "malaysia", state: "", city: "", suburb: "" }, pj), 1);
  assertEquals(areaMatch({ country: "Malaysia", state: "Selangor", city: "Petaling  Jaya", suburb: "" }, pj), 3);
  assertEquals(areaMatch({ country: "Malaysia", state: "Selangor", city: "Petaling Jaya", suburb: "SS2" }, pj), 4);
  assertEquals(areaMatch({ country: "Malaysia", state: "Johor", city: "", suburb: "" }, pj), -1);
  assertEquals(areaMatch({ country: "Malaysia", state: "", city: "", suburb: "" }, { country: "", state: "", city: "", suburb: "" }), -1);
});

Deno.test("orderServersFor: most specific match, then any area, then the rest as backup", () => {
  const mk = (id: string, area?: Partial<typeof pj>) => ({
    id,
    label: id,
    url: "https://x.example",
    key: "k",
    enabled: true,
    ...(area ? { area: { country: "", state: "", city: "", suburb: "", ...area } } : {}),
  });
  const servers = [
    mk("johor", { country: "Malaysia", state: "Johor" }),
    mk("general"),
    mk("my", { country: "Malaysia" }),
    mk("pj", { country: "Malaysia", state: "Selangor", city: "Petaling Jaya" }),
    mk("general2"),
  ];
  assertEquals(orderServersFor(servers, pj).map((s) => s.id), ["pj", "my", "general", "general2", "johor"]);
});

Deno.test("wazeServersOf keeps a server's area", () => {
  const [s] = wazeServersOf({
    wazeServers: [{ id: "a", url: "https://a.example", key: "k", area: { country: "Malaysia", state: "Selangor" } }],
  });
  assertEquals(s.area, { country: "Malaysia", state: "Selangor", city: "", suburb: "" });
});

Deno.test("healthVerdict: unreachable, HTTP errors, refused key, Waze refusing, ok", () => {
  assertEquals(healthVerdict(null, null, "Health check: no answer within 15 s.").detail, "Health check: no answer within 15 s.");
  assertEquals(healthVerdict(502, null), { state: "down", detail: "Health check: HTTP 502." });
  assertEquals(healthVerdict(200, { status: "ok" }), { state: "down", detail: "Health check: the key was refused." });
  assertEquals(healthVerdict(200, { status: "ok", waze: { last_ok_at: null, last_error_at: null } }), {
    state: "ok",
    detail: null,
  });
  assertEquals(
    healthVerdict(200, {
      status: "ok",
      waze: { last_ok_at: "2026-11-15T08:00:00Z", last_error_at: "2026-11-15T08:05:00Z", last_error: "georss: 4 reCAPTCHA tokens refused (HTTP 403)" },
    }),
    { state: "down", detail: "Waze is refusing this server: georss: 4 reCAPTCHA tokens refused (HTTP 403)" },
  );
  assertEquals(
    healthVerdict(200, {
      status: "ok",
      waze: { last_ok_at: "2026-11-15T08:06:00Z", last_error_at: "2026-11-15T08:05:00Z", last_error: "x" },
    }).state,
    "ok",
  );
});

Deno.test("askWazeServer: a slow server is given up within the trip budget", async () => {
  const slow = (_url: string, init: RequestInit) =>
    new Promise<Response>((_res, rej) => {
      init.signal?.addEventListener("abort", () => rej(new DOMException("timed out", "TimeoutError")));
    });
  const started = Date.now();
  const r = await askWazeServer(server, [klcc, klia], slow, 200);
  assertEquals(r.estimate, null);
  assertEquals(r.error, "No answer within 0.2 s");
  assertEquals(Date.now() - started < 1000, true);
});

// ---- Google Maps (Traffic Scraper, getgroupmy/get.route.backup) ----------------------------------

Deno.test("gmapServersOf: its own list, ids and labels", () => {
  const config = {
    wazeServers: [{ url: "https://route.getride.my", key: "w" }],
    gmapServers: [
      { url: "https://traffic.getride.my/", key: " k " },
      { url: "http://insecure.example", key: "k" },
      { url: "https://off.example", key: "k", enabled: false },
    ],
  };
  assertEquals(gmapServersOf(config), [
    { id: "gmap-1", label: "Google Maps server 1", url: "https://traffic.getride.my", key: "k", enabled: true },
  ]);
  assertEquals(wazeServersOf(config).map((s) => s.id), ["waze-1"]);
  assertEquals(gmapServersOf({}), []);
});

Deno.test("askWazeServer: a Traffic Scraper answer becomes a Google Maps estimate", async () => {
  // The answer the Traffic Scraper gave live (Adelaide CBD to the airport).
  const answer = {
    from: { lat: -34.9285, lng: 138.6007, place: null },
    to: { lat: -34.9462, lng: 138.5312, place: null },
    region: null, depart_at: null, arrive_at: null, count: 1,
    routes: [{
      name: "Sir Donald Bradman Dr/A6", duration_seconds: 840, distance_meters: 7800,
      is_fastest: true, is_toll: false, traffic_status: "Fastest route, the usual traffic",
      toll: null, jams: [], alerts: [], polyline: null,
    }],
    source: "google_maps",
  };
  const seen: string[] = [];
  const fake = (url: string, init: RequestInit) => {
    seen.push(`${url} ${(init.headers as Record<string, string>)["X-Route-Key"]}`);
    return Promise.resolve(new Response(JSON.stringify(answer), { status: 200 }));
  };
  const server = gmapServersOf({ gmapServers: [{ url: "https://traffic.getride.my", key: "k" }] })[0];
  const r = await askWazeServer(
    server,
    [{ latitude: -34.9285, longitude: 138.6007 }, { latitude: -34.9462, longitude: 138.5312 }],
    fake,
    3_000,
    GMAP_KIND.sourceName,
  );
  assertEquals(r.error, null);
  assertEquals(r.estimate, {
    distance_km: 7.8,
    duration_min: 14,
    summary: "Via Sir Donald Bradman Dr/A6 (Google Maps live traffic)",
    toll_count: 0,
    toll_total: 0,
    tolls: [],
  });
  assertEquals(seen, [
    "https://traffic.getride.my/routes/search?from=-34.928500%2C138.600700&to=-34.946200%2C138.531200&max_routes=1 k",
  ]);
});

Deno.test("healthVerdict: names Google Maps for its servers", () => {
  const body = {
    status: "ok",
    waze: { last_ok_at: "2026-11-15T10:00:00Z", last_error_at: "2026-11-15T10:05:00Z", last_error: "Directions panel did not load" },
  };
  assertEquals(healthVerdict(200, body, undefined, GMAP_KIND.sourceName), {
    state: "down",
    detail: "Google Maps is refusing this server: Directions panel did not load",
  });
  assertEquals(healthVerdict(200, body).detail, "Waze is refusing this server: Directions panel did not load");
});
