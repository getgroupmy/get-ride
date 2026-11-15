import { assertEquals } from "jsr:@std/assert@1.0.19";
import { chainOf, osrmEstimate } from "./fare_chain.ts";

Deno.test("chainOf: the saved chain, known steps once, OSRM last", () => {
  assertEquals(chainOf({ chain: ["waze", "ai", "osrm"] }), ["waze", "ai", "osrm"]);
  assertEquals(chainOf({ chain: ["osrm", "waze"] }), ["waze", "osrm"]);
  assertEquals(chainOf({ chain: ["ai", "ai", "google", "bogus", 3] }), ["ai"]);
  assertEquals(chainOf({ chain: [] }), []);
});

Deno.test("chainOf: Google Maps (gmap) is a step like the others", () => {
  assertEquals(chainOf({ chain: ["waze", "gmap", "ai", "osrm"] }), ["waze", "gmap", "ai", "osrm"]);
  assertEquals(chainOf({ chain: ["gmap", "osrm", "ai"] }), ["gmap", "ai", "osrm"]);
  assertEquals(chainOf({ chain: ["gmap", "gmap"] }), ["gmap"]);
  // configs saved before the step existed don't gain it
  assertEquals(chainOf({ source: "waze" }), ["waze", "ai"]);
});

Deno.test("chainOf: a config from before chains behaves as it did", () => {
  assertEquals(chainOf(null), ["ai"]);
  assertEquals(chainOf({ source: "ai" }), ["ai"]);
  assertEquals(chainOf({ source: "waze" }), ["waze", "ai"]);
  assertEquals(chainOf({ source: "waze", wazeFallback: "none" }), ["waze"]);
  assertEquals(chainOf({ source: "none" }), []);
  assertEquals(chainOf({ serviceEnabled: false }), []);
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
