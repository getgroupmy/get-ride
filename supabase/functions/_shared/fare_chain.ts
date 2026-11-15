/**
 * The order fare estimates are asked in (Admin › Settings › Fare AI provider,
 * `fare_ai_provider.chain`), and the two steps that are not the AI or Waze:
 * Google's official Routes API and OSRM. ai-route-proxy walks the chain and
 * answers with the first step that gives an estimate:
 *
 *   waze    the GET.route pool on the office NAS (_shared/waze_route.ts)
 *   google  Google Routes API, computeRoutes with live traffic and tolls, on
 *           the Routes key Admin › Maps uses (map_config.keys.google_routes)
 *   ai      the AI provider and keys on the Fare AI page
 *   osrm    OSRM: the office NAS when it is on, else OSRM_URL. Road distance
 *           and empty-road time, no traffic or tolls. Always last.
 *
 * A config saved before chains is read as it behaved: source "ai" → [ai],
 * "waze" → [waze] + [ai] when its fallback was the AI, "none" or the old
 * switch off → [] (no estimate; the apps use their own fallback).
 *
 * Pure: see fare_chain_test.ts.
 */

export type FareStep = "waze" | "google" | "ai" | "osrm";

export const FARE_STEPS: readonly FareStep[] = ["waze", "google", "ai", "osrm"];

/** The provider a Google / OSRM estimate and its log row carry. */
export const GOOGLE_PROVIDER = "google";
export const OSRM_PROVIDER = "osrm";

/** The chain a saved config asks for. */
export function chainOf(config: Record<string, unknown> | null | undefined): FareStep[] {
  const c = config ?? {};
  if (Array.isArray(c.chain)) {
    const out: FareStep[] = [];
    for (const s of c.chain) {
      if (typeof s === "string" && (FARE_STEPS as readonly string[]).includes(s) && !out.includes(s as FareStep)) {
        out.push(s as FareStep);
      }
    }
    // OSRM answers every trip it can route, so nothing after it is ever asked.
    const osrm = out.indexOf("osrm");
    return osrm === -1 ? out : [...out.filter((s) => s !== "osrm"), "osrm"];
  }
  const source = c.source;
  if (source === "waze") return c.wazeFallback === "none" ? ["waze"] : ["waze", "ai"];
  if (source === "none" || (source !== "ai" && c.serviceEnabled === false)) return [];
  return ["ai"];
}

export interface LatLng {
  latitude: number;
  longitude: number;
}

export interface TollBooth {
  id: string;
  name?: string;
  charge: number;
}

export interface StepEstimate {
  distance_km: number;
  duration_min: number;
  summary?: string;
  toll_count: number;
  toll_total: number;
  tolls: TollBooth[];
}

// ---- Google Routes API -------------------------------------------------------------------------

export interface HttpRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: string;
}

/** computeRoutes with live traffic and Google's toll estimate, every stop in order. */
export function googleRoutesRequest(key: string, points: LatLng[]): HttpRequest {
  const loc = (p: LatLng) => ({ location: { latLng: { latitude: p.latitude, longitude: p.longitude } } });
  const via = points.slice(1, -1);
  return {
    url: "https://routes.googleapis.com/directions/v2:computeRoutes",
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": key,
      "X-Goog-FieldMask": "routes.distanceMeters,routes.duration,routes.description,routes.travelAdvisory.tollInfo",
    },
    body: JSON.stringify({
      origin: loc(points[0]),
      destination: loc(points[points.length - 1]),
      ...(via.length ? { intermediates: via.map(loc) } : {}),
      travelMode: "DRIVE",
      routingPreference: "TRAFFIC_AWARE",
      extraComputations: ["TOLLS"],
      languageCode: "en",
      units: "METRIC",
    }),
  };
}

/** Google's Money ({ currencyCode, units, nanos }) as a number. */
function money(m: unknown): number | null {
  if (!m || typeof m !== "object") return null;
  const o = m as { units?: unknown; nanos?: unknown };
  const units = Number(o.units ?? 0), nanos = Number(o.nanos ?? 0);
  if (!Number.isFinite(units) || !Number.isFinite(nanos)) return null;
  return Math.round((units + nanos / 1e9) * 100) / 100;
}

/** The first route of a computeRoutes answer as an estimate, or null.
 * Google gives one toll total for the route (no booths): it is listed as one
 * line. A route with tolls whose price Google does not know says so. */
export function parseGoogleRoute(body: unknown): StepEstimate | null {
  const r = (body as { routes?: unknown[] } | null)?.routes?.[0] as Record<string, unknown> | undefined;
  if (!r) return null;
  const meters = Number(r.distanceMeters);
  const seconds = Number(String(r.duration ?? "").replace(/s$/, ""));
  if (!Number.isFinite(meters) || meters <= 0 || !Number.isFinite(seconds) || seconds <= 0) return null;
  const toll = (r.travelAdvisory as { tollInfo?: { estimatedPrice?: unknown[] } } | undefined)?.tollInfo;
  const prices = (toll?.estimatedPrice ?? []).map(money).filter((v): v is number => v !== null);
  const total = Math.round(prices.reduce((a, b) => a + b, 0) * 100) / 100;
  const tolls: TollBooth[] = toll
    ? [{ id: "toll-0", name: prices.length ? "Tolls on this route (Google estimate)" : "Tolls on this route (price unknown)", charge: total }]
    : [];
  const via = typeof r.description === "string" && r.description.trim() ? `Via ${r.description.trim()} ` : "";
  return {
    distance_km: Math.round(meters / 100) / 10,
    duration_min: Math.ceil(seconds / 60),
    summary: `${via}(Google live traffic)`,
    toll_count: tolls.length,
    toll_total: total,
    tolls,
  };
}

/** Google's error message, for the log. */
export function googleError(status: number, body: unknown): string {
  const msg = (body as { error?: { message?: unknown } } | null)?.error?.message;
  return `HTTP ${status}${typeof msg === "string" && msg ? `: ${msg.slice(0, 200)}` : ""}`;
}

// ---- OSRM --------------------------------------------------------------------------------------

/** OSRM's road distance and empty-road time as an estimate (no tolls). */
export function osrmEstimate(route: { km: number; min: number } | null): StepEstimate | null {
  if (!route || !(route.km > 0) || !(route.min > 0)) return null;
  return {
    distance_km: Math.round(route.km * 10) / 10,
    duration_min: Math.ceil(route.min),
    summary: "Road distance and time without live traffic (OSRM)",
    toll_count: 0,
    toll_total: 0,
    tolls: [],
  };
}
