/**
 * Fare time limits (Admin › Settings › Fare AI provider › Time limits) and
 * the iPhone hand-off.
 *
 * Server steps, in `fare_ai_provider.timing` (admins only):
 *
 *   wazeSeconds   Waze (default 2)
 *   gmapSeconds   Google Maps (default 2); each has its own time, so the
 *                 second one asked always gets a full try
 *   appleSeconds  the Apple Maps server step (default 1.5)
 *   aiSeconds     each AI call (default 5)
 *   osrmSeconds   the office NAS OSRM (default 3)
 *
 * The apps, in the readable `fare_timing` setting (every signed-in app reads
 * it, only admins write it):
 *
 *   appWaitSeconds      how long the rider app waits for a fare estimate in
 *                       all ("Calculating fare"), then prices the plain
 *                       route on the phone (default 5)
 *   deviceApple         iPhones ask Apple Maps themselves (MapKit, on the
 *                       phone: no server, no quota) in Apple Maps' place in
 *                       the order, or right after Waze and Google Maps when
 *                       Apple Maps isn't in it (default on)
 *   deviceAppleSeconds  how long the iPhone waits for Apple Maps (default 1.5)
 *
 * The hand-off: an iPhone sends `device: "ios_mapkit"`. When the order
 * reaches Apple Maps (deviceChain), ai-route-proxy stops and answers
 * `reason: "device_apple"` with the steps still to go (`remaining`); the
 * phone asks MapKit, and if that fails asks again with `resume: remaining`,
 * which runs only those (resumeSteps). The phone reports its MapKit answer (`report`) for the
 * response log.
 *
 * Pure: see fare_timing_test.ts.
 */

import type { FareStep } from "./fare_chain.ts";

export interface ServerTiming {
  wazeMs: number;
  gmapMs: number;
  appleMs: number;
  aiMs: number;
  osrmMs: number;
}

export const DEFAULT_SERVER_TIMING: ServerTiming = { wazeMs: 2_000, gmapMs: 2_000, appleMs: 1_500, aiMs: 5_000, osrmMs: 3_000 };

/** The bounds an admin may set, in seconds. */
export const TIMING_BOUNDS = {
  wazeSeconds: [0.5, 15],
  gmapSeconds: [0.5, 15],
  appleSeconds: [0.5, 10],
  aiSeconds: [1, 30],
  osrmSeconds: [0.5, 10],
  appWaitSeconds: [2, 30],
  deviceAppleSeconds: [0.5, 10],
} as const;

type Bound = keyof typeof TIMING_BOUNDS;

/** Seconds as milliseconds, inside the bounds; [fallbackMs] when not a number. */
function ms(v: unknown, bound: Bound, fallbackMs: number): number {
  const n = Number(v);
  if (v === null || v === undefined || v === "" || !Number.isFinite(n)) return fallbackMs;
  const [lo, hi] = TIMING_BOUNDS[bound];
  return Math.round(Math.min(hi, Math.max(lo, n)) * 1000);
}

/** The server steps' limits from `fare_ai_provider.timing`. */
export function serverTimingOf(config: Record<string, unknown> | null | undefined): ServerTiming {
  const raw = config?.timing;
  const t = raw && typeof raw === "object" ? raw as Record<string, unknown> : {};
  const d = DEFAULT_SERVER_TIMING;
  return {
    wazeMs: ms(t.wazeSeconds, "wazeSeconds", d.wazeMs),
    gmapMs: ms(t.gmapSeconds, "gmapSeconds", d.gmapMs),
    appleMs: ms(t.appleSeconds, "appleSeconds", d.appleMs),
    aiMs: ms(t.aiSeconds, "aiSeconds", d.aiMs),
    osrmMs: ms(t.osrmSeconds, "osrmSeconds", d.osrmMs),
  };
}

export interface AppTiming {
  appWaitMs: number;
  deviceApple: boolean;
  deviceAppleMs: number;
}

export const DEFAULT_APP_TIMING: AppTiming = { appWaitMs: 5_000, deviceApple: true, deviceAppleMs: 1_500 };

/** The apps' side from the `fare_timing` setting. */
export function appTimingOf(raw: unknown): AppTiming {
  const t = raw && typeof raw === "object" ? raw as Record<string, unknown> : {};
  const d = DEFAULT_APP_TIMING;
  return {
    appWaitMs: ms(t.appWaitSeconds, "appWaitSeconds", d.appWaitMs),
    deviceApple: t.deviceApple !== false,
    deviceAppleMs: ms(t.deviceAppleSeconds, "deviceAppleSeconds", d.deviceAppleMs),
  };
}

const LIVE: readonly FareStep[] = ["waze", "gmap"];

/** The order for an iPhone that asks Apple Maps itself: as it is when Apple
 * Maps is in it; otherwise with Apple Maps right after the last of Waze and
 * Google Maps (or first, when neither is in it), so the phone tries Apple
 * Maps when they miss. An empty order stays empty (no estimates at all). */
export function deviceChain(chain: readonly FareStep[]): FareStep[] {
  const out = [...chain];
  if (out.length === 0 || out.includes("apple")) return out;
  let last = -1;
  out.forEach((s, i) => {
    if (LIVE.includes(s)) last = i;
  });
  out.splice(last + 1, 0, "apple");
  return out;
}

/** The steps an iPhone asks the server to go on with after Apple Maps on
 * the phone missed: the `remaining` steps the hand-off sent it, kept only
 * where they are in the admin's order, once each, without Apple Maps (the
 * phone tried it) and with OSRM last. Not a list: none. */
export function resumeSteps(chain: readonly FareStep[], requested: unknown): FareStep[] {
  if (!Array.isArray(requested)) return [];
  const allowed = deviceChain(chain);
  const out: FareStep[] = [];
  for (const s of requested) {
    if (typeof s === "string" && s !== "apple" && allowed.includes(s as FareStep) && !out.includes(s as FareStep)) {
      out.push(s as FareStep);
    }
  }
  return out.includes("osrm") ? [...out.filter((s) => s !== "osrm"), "osrm"] : out;
}

/** A `fetch` that gives up after [timeoutMs] (the AI call's limit). */
export function fetchWithin(timeoutMs: number, fetchImpl: typeof fetch = fetch): typeof fetch {
  return (input, init) => fetchImpl(input, { ...(init ?? {}), signal: AbortSignal.timeout(timeoutMs) });
}

/** A phone's MapKit answer as a log row's fields, or null when it is not
 * one (`report` in the request). */
export function deviceReportOf(raw: unknown): {
  success: boolean;
  distance_km: number | null;
  duration_min: number | null;
  latency_ms: number | null;
  error: string | null;
} | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const num = (v: unknown, hi: number) => {
    const n = Number(v);
    return v !== null && v !== undefined && Number.isFinite(n) && n > 0 && n <= hi ? n : null;
  };
  const km = num(r.distance_km, 5_000), min = num(r.duration_min, 10_000);
  const success = r.success === true && km !== null && min !== null;
  return {
    success,
    distance_km: success ? Math.round(km! * 10) / 10 : null,
    duration_min: success ? Math.ceil(min!) : null,
    latency_ms: num(r.latency_ms, 120_000),
    error: success ? null : typeof r.error === "string" && r.error ? r.error.slice(0, 200) : "No answer from Apple Maps on the phone",
  };
}
