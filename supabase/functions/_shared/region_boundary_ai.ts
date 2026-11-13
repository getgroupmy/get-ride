// What the AI is asked for a region's map boundary, and how its answer is
// turned into the `BoundaryShape` JSON the rest of the app already speaks
// (admin `parseBoundary`, the coverage guard's `region_boundary_polygons`).
// Pure, so the `region-boundary-ai` edge function and its tests share one copy.
//
//   deno test supabase/functions/_shared/region_boundary_ai_test.ts
//
// The provider/model/key come from Admin → Fare AI / API Keys (app setting
// `fare_ai_provider`) via `_shared/ai_providers.ts`, so the AI used here is
// whichever one the admin has switched on (Gemini by default) — this module
// only shapes the question and the answer.

export interface LngLat {
  latitude: number;
  longitude: number;
}

export interface BBox {
  north: number;
  south: number;
  east: number;
  west: number;
}

/** The `BoundaryShape` object stored under `geofence.boundary` (as a string). */
export interface BoundaryShapeObj {
  coords: LngLat[];
  polygons: LngLat[][];
  bbox: BBox;
  source: string;
}

/** Bounds on what we accept back, so a runaway answer can't be stored. */
export const MAX_RINGS = 60;
export const MAX_POINTS_PER_RING = 400;
export const MAX_POINTS_TOTAL = 1500;

export const BOUNDARY_SYSTEM =
  "You are a GIS assistant. You return only a single valid JSON object and never wrap it in " +
  "markdown fences or add any prose. You describe administrative boundaries as polygons of " +
  "WGS84 latitude/longitude points.";

/** The question for one region, e.g. "Selangor, Malaysia". */
export function buildBoundaryPrompt(query: string): string {
  const q = query.trim();
  return [
    `Give the approximate geographic boundary of "${q}".`,
    "",
    "Answer with a JSON object of exactly this shape:",
    '{ "polygons": [ [ { "latitude": <number>, "longitude": <number> }, ... ], ... ] }',
    "",
    "Rules:",
    "- Each inner array is one closed ring, ordered around the outline.",
    "- Use 20 to 80 points for the main outline; add a separate ring for each sizeable island or exclave.",
    "- Outer rings only — do not describe holes.",
    "- Latitude is -90..90, longitude is -180..180, and the first and last point of a ring should match.",
    "- Return only the JSON object, nothing else.",
  ].join("\n");
}

function finiteNum(v: unknown): number | null {
  const n = typeof v === "number" ? v : typeof v === "string" ? Number(v) : NaN;
  return Number.isFinite(n) ? n : null;
}

/** One point from the various shapes a model might emit:
 *  {latitude,longitude}, {lat,lng|lon|long}, or a [lng, lat] GeoJSON pair. */
function pointOf(p: unknown): LngLat | null {
  if (Array.isArray(p) && p.length >= 2) {
    const lng = finiteNum(p[0]);
    const lat = finiteNum(p[1]);
    if (lat === null || lng === null) return null;
    return inRange(lat, lng) ? { latitude: lat, longitude: lng } : null;
  }
  if (p && typeof p === "object") {
    const o = p as Record<string, unknown>;
    const lat = finiteNum(o.latitude ?? o.lat);
    const lng = finiteNum(o.longitude ?? o.lng ?? o.lon ?? o.long);
    if (lat === null || lng === null) return null;
    return inRange(lat, lng) ? { latitude: lat, longitude: lng } : null;
  }
  return null;
}

function inRange(lat: number, lng: number): boolean {
  return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
}

function ringOf(raw: unknown): LngLat[] | null {
  if (!Array.isArray(raw)) return null;
  const pts: LngLat[] = [];
  for (const p of raw) {
    const pt = pointOf(p);
    if (pt) pts.push(pt);
    if (pts.length >= MAX_POINTS_PER_RING) break;
  }
  return pts.length >= 3 ? pts : null;
}

/** Pull the list of rings out of whatever the model returned: our own
 *  `polygons`, or a GeoJSON Polygon/MultiPolygon under `coordinates` /
 *  `geometry.coordinates` / a Feature. Deeply nested coordinate arrays are
 *  flattened to the ring level (a ring is an array of points). */
function ringsFrom(obj: Record<string, unknown>): unknown[] {
  if (Array.isArray(obj.polygons)) return obj.polygons;
  const geom = (obj.geometry && typeof obj.geometry === "object"
    ? (obj.geometry as Record<string, unknown>)
    : obj) as Record<string, unknown>;
  const coords = geom.coordinates;
  if (!Array.isArray(coords)) return [];
  // A ring is an array whose first element is a point (array[0] is a number,
  // or an object). Walk down until we reach that level.
  const out: unknown[] = [];
  const visit = (node: unknown, depth: number) => {
    if (!Array.isArray(node) || depth > 6) return;
    const first = node[0];
    const isPoint = (Array.isArray(first) && typeof first[0] === "number") ||
      (first && typeof first === "object" && !Array.isArray(first));
    if (isPoint) {
      out.push(node);
      return;
    }
    for (const child of node) visit(child, depth + 1);
  };
  visit(coords, 0);
  return out;
}

/** The AI's answer as a `BoundaryShape`, or null when it has no usable ring.
 *  `coords` is the largest ring (what the editor draws/edits), `polygons`
 *  every ring, `bbox` their extent, `source` always "ai". */
export function normalizeAiBoundary(obj: unknown, source = "ai"): BoundaryShapeObj | null {
  if (!obj || typeof obj !== "object") return null;
  const rawRings = ringsFrom(obj as Record<string, unknown>);
  const polygons: LngLat[][] = [];
  let total = 0;
  for (const r of rawRings) {
    if (polygons.length >= MAX_RINGS || total >= MAX_POINTS_TOTAL) break;
    const ring = ringOf(r);
    if (!ring) continue;
    polygons.push(ring);
    total += ring.length;
  }
  if (polygons.length === 0) return null;
  const all = polygons.flat();
  const lats = all.map((p) => p.latitude);
  const lngs = all.map((p) => p.longitude);
  const bbox: BBox = {
    north: Math.max(...lats),
    south: Math.min(...lats),
    east: Math.max(...lngs),
    west: Math.min(...lngs),
  };
  const coords = polygons.reduce((a, b) => (b.length > a.length ? b : a), polygons[0]);
  return { coords, polygons, bbox, source };
}
