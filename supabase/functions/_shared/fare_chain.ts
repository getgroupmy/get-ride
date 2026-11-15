/**
 * The order fare estimates are asked in (Admin › Settings › Fare AI provider,
 * `fare_ai_provider.chain`), and the OSRM step. ai-route-proxy walks the
 * chain and answers with the first step that gives an estimate:
 *
 *   waze    the GET.route pool on the office NAS (_shared/waze_route.ts)
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

export type FareStep = "waze" | "ai" | "osrm";

export const FARE_STEPS: readonly FareStep[] = ["waze", "ai", "osrm"];

/** The provider an OSRM estimate and its log row carry. */
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
