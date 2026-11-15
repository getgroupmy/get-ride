import { assertEquals } from "jsr:@std/assert@1.0.19";
import { chainOf, googleError, googleRoutesRequest, osrmEstimate, parseGoogleRoute } from "./fare_chain.ts";

Deno.test("chainOf: the saved chain, known steps once, OSRM last", () => {
  assertEquals(chainOf({ chain: ["waze", "google", "ai", "osrm"] }), ["waze", "google", "ai", "osrm"]);
  assertEquals(chainOf({ chain: ["google", "osrm", "waze"] }), ["google", "waze", "osrm"]);
  assertEquals(chainOf({ chain: ["google", "google", "bogus", 3] }), ["google"]);
  assertEquals(chainOf({ chain: [] }), []);
});

Deno.test("chainOf: a config from before chains behaves as it did", () => {
  assertEquals(chainOf(null), ["ai"]);
  assertEquals(chainOf({ source: "ai" }), ["ai"]);
  assertEquals(chainOf({ source: "waze" }), ["waze", "ai"]);
  assertEquals(chainOf({ source: "waze", wazeFallback: "none" }), ["waze"]);
  assertEquals(chainOf({ source: "none" }), []);
  assertEquals(chainOf({ serviceEnabled: false }), []);
});

const kl = { latitude: 3.158, longitude: 101.712 };
const sentral = { latitude: 3.134, longitude: 101.686 };
const pj = { latitude: 3.107, longitude: 101.606 };

Deno.test("googleRoutesRequest: traffic-aware with tolls, stops as intermediates, key in a header", () => {
  const r = googleRoutesRequest("AIzaKEY", [kl, pj, sentral]);
  assertEquals(r.url, "https://routes.googleapis.com/directions/v2:computeRoutes");
  assertEquals(r.headers["X-Goog-Api-Key"], "AIzaKEY");
  assertEquals(r.headers["X-Goog-FieldMask"].includes("routes.travelAdvisory.tollInfo"), true);
  const b = JSON.parse(r.body);
  assertEquals(b.routingPreference, "TRAFFIC_AWARE");
  assertEquals(b.extraComputations, ["TOLLS"]);
  assertEquals(b.intermediates.length, 1);
  assertEquals(b.destination.location.latLng.latitude, 3.134);
  assertEquals(r.url.includes("AIzaKEY"), false, "the key never goes in the URL");
});

Deno.test("parseGoogleRoute: distance, live time, the toll total as one line", () => {
  assertEquals(
    parseGoogleRoute({
      routes: [{
        distanceMeters: 24130,
        duration: "1530s",
        description: "MEX",
        travelAdvisory: { tollInfo: { estimatedPrice: [{ currencyCode: "MYR", units: "3", nanos: 800000000 }] } },
      }],
    }),
    {
      distance_km: 24.1,
      duration_min: 26,
      summary: "Via MEX (Google live traffic)",
      toll_count: 1,
      toll_total: 3.8,
      tolls: [{ id: "toll-0", name: "Tolls on this route (Google estimate)", charge: 3.8 }],
    },
  );
});

Deno.test("parseGoogleRoute: no tolls, unknown toll price, nothing usable", () => {
  const free = parseGoogleRoute({ routes: [{ distanceMeters: 4600, duration: "840s" }] });
  assertEquals([free?.duration_min, free?.toll_count, free?.toll_total], [14, 0, 0]);
  const unknown = parseGoogleRoute({ routes: [{ distanceMeters: 4600, duration: "840s", travelAdvisory: { tollInfo: {} } }] });
  assertEquals(unknown?.tolls[0].name, "Tolls on this route (price unknown)");
  assertEquals(parseGoogleRoute({ routes: [] }), null);
  assertEquals(parseGoogleRoute({ routes: [{ distanceMeters: 0, duration: "10s" }] }), null);
  assertEquals(parseGoogleRoute(null), null);
});

Deno.test("googleError: Google's message when there is one", () => {
  assertEquals(googleError(403, { error: { message: "API key not valid." } }), "HTTP 403: API key not valid.");
  assertEquals(googleError(500, null), "HTTP 500");
});

Deno.test("osrmEstimate: road distance and time, no tolls", () => {
  assertEquals(osrmEstimate({ km: 12.34, min: 18.2 }), {
    distance_km: 12.3,
    duration_min: 19,
    summary: "Road distance and time without live traffic (OSRM)",
    toll_count: 0,
    toll_total: 0,
    tolls: [],
  });
  assertEquals(osrmEstimate(null), null);
  assertEquals(osrmEstimate({ km: 0, min: 3 }), null);
});
