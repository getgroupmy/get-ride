// deno test supabase/functions/_shared/region_boundary_ai_test.ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  BOUNDARY_SYSTEM,
  buildBoundaryPrompt,
  MAX_POINTS_PER_RING,
  MAX_RINGS,
  normalizeAiBoundary,
} from "./region_boundary_ai.ts";

const ring = (pts: [number, number][]) => pts.map(([lat, lng]) => ({ latitude: lat, longitude: lng }));
const square = ring([[1, 100], [1, 101], [2, 101], [2, 100], [1, 100]]);

Deno.test("prompt names the region and asks for the JSON shape", () => {
  const p = buildBoundaryPrompt("  Selangor, Malaysia  ");
  if (!p.includes('"Selangor, Malaysia"')) throw new Error("region not named");
  if (!p.includes('"polygons"')) throw new Error("shape not described");
  if (BOUNDARY_SYSTEM.length < 20) throw new Error("system empty");
});

Deno.test("our own polygons shape passes through with bbox + coords", () => {
  const b = normalizeAiBoundary({ polygons: [square] });
  if (!b) throw new Error("null");
  assertEquals(b.polygons.length, 1);
  assertEquals(b.coords.length, square.length);
  assertEquals(b.bbox, { north: 2, south: 1, east: 101, west: 100 });
  assertEquals(b.source, "ai");
});

Deno.test("coords is the largest ring", () => {
  const big = ring([[0, 0], [0, 5], [5, 5], [5, 0], [2, 1], [1, 1], [0, 0]]);
  const small = ring([[10, 10], [10, 11], [11, 11], [10, 10]]);
  const b = normalizeAiBoundary({ polygons: [small, big] });
  assertEquals(b!.coords.length, big.length);
  assertEquals(b!.polygons.length, 2);
});

Deno.test("GeoJSON Polygon coordinates [lng,lat] are accepted", () => {
  const b = normalizeAiBoundary({
    type: "Polygon",
    coordinates: [[[100, 1], [101, 1], [101, 2], [100, 2], [100, 1]]],
  });
  if (!b) throw new Error("null");
  assertEquals(b.polygons[0][0], { latitude: 1, longitude: 100 });
  assertEquals(b.bbox, { north: 2, south: 1, east: 101, west: 100 });
});

Deno.test("GeoJSON MultiPolygon and Feature.geometry are flattened to rings", () => {
  const poly = [[[100, 1], [101, 1], [101, 2], [100, 1]]];
  const multi = normalizeAiBoundary({ type: "MultiPolygon", coordinates: [poly, poly] });
  assertEquals(multi!.polygons.length, 2);
  const feat = normalizeAiBoundary({ type: "Feature", geometry: { type: "Polygon", coordinates: poly } });
  assertEquals(feat!.polygons.length, 1);
});

Deno.test("lat/lng key variants are read", () => {
  const b = normalizeAiBoundary({
    polygons: [[{ lat: 1, lng: 100 }, { lat: 1, lng: 101 }, { lat: 2, lon: 101 }]],
  });
  assertEquals(b!.polygons[0].length, 3);
});

Deno.test("rings under 3 points, and out-of-range points, are dropped", () => {
  assertEquals(normalizeAiBoundary({ polygons: [ring([[1, 1], [2, 2]])] }), null);
  // A ring of 3 where one point is off-earth collapses below 3 → whole thing null.
  assertEquals(
    normalizeAiBoundary({ polygons: [ring([[1, 1], [2, 2], [999, 999]])] }),
    null,
  );
});

Deno.test("garbage and empties give null, never throw", () => {
  for (const g of [null, undefined, 42, "x", {}, { polygons: [] }, { coordinates: 5 }]) {
    assertEquals(normalizeAiBoundary(g), null);
  }
});

Deno.test("ring and total caps are enforced", () => {
  const huge = Array.from({ length: MAX_POINTS_PER_RING + 50 }, (_, i) => ({ latitude: (i % 80) * 0.1, longitude: 100 + i * 0.001 }));
  const b = normalizeAiBoundary({ polygons: [huge] });
  if (b!.polygons[0].length > MAX_POINTS_PER_RING) throw new Error("ring not capped");
  const many = Array.from({ length: MAX_RINGS + 20 }, () => square);
  const b2 = normalizeAiBoundary({ polygons: many });
  if (b2!.polygons.length > MAX_RINGS) throw new Error("rings not capped");
});
