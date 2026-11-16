/**
 * Waze / Google Maps balance (Admin › Settings › Fare AI provider,
 * `fare_ai_provider.liveBalance`).
 *
 * The fare order asks the two live-traffic steps one after the other within
 * one shared budget (WAZE_TRIP_BUDGET_MS). By default Waze goes first and
 * Google Maps only sees the trips Waze missed. The balance sends a share of
 * fares Google Maps first instead (Waze is then that trip's backup):
 *
 *   { mode: "fixed", gmapFirstPct: 20 }         20 % of fares ask Google Maps first
 *   { mode: "auto", minPct: 5, maxPct: 40 }     the share moves between 5 and 40 %,
 *                                               set every minute by waze-server-health
 *                                               from the last 15 minutes (nextAutoShare)
 *
 * The automatic share lives in public.fare_live_balance (migration 0414).
 * Only an order with both "waze" and "gmap" is ever changed, and only by
 * swapping those two; every other step keeps its place.
 *
 * Pure: see live_balance_test.ts.
 */

import type { FareStep } from "./fare_chain.ts";

export type BalanceMode = "fixed" | "auto";

export interface LiveBalance {
  mode: BalanceMode;
  /** Fixed mode: share of fares asking Google Maps first, 0-100. */
  gmapFirstPct: number;
  /** Auto mode: the range the share moves in. */
  minPct: number;
  maxPct: number;
}

/** A config without a balance behaves as before: Waze always first. */
export const DEFAULT_BALANCE: LiveBalance = { mode: "fixed", gmapFirstPct: 0, minPct: 5, maxPct: 40 };

const pct = (v: unknown, fallback: number) => {
  const n = Number(v);
  return Number.isFinite(n) ? Math.min(100, Math.max(0, Math.round(n))) : fallback;
};

/** The saved balance, tolerant of missing or bad fields. */
export function balanceOf(config: Record<string, unknown> | null | undefined): LiveBalance {
  const raw = config?.liveBalance;
  if (!raw || typeof raw !== "object") return { ...DEFAULT_BALANCE };
  const o = raw as Record<string, unknown>;
  let minPct = pct(o.minPct, DEFAULT_BALANCE.minPct);
  let maxPct = pct(o.maxPct, DEFAULT_BALANCE.maxPct);
  if (minPct > maxPct) [minPct, maxPct] = [maxPct, minPct];
  return {
    mode: o.mode === "auto" ? "auto" : "fixed",
    gmapFirstPct: pct(o.gmapFirstPct, DEFAULT_BALANCE.gmapFirstPct),
    minPct,
    maxPct,
  };
}

/** True when the order has both live-traffic steps, i.e. a balance applies. */
export const balanceApplies = (chain: readonly FareStep[]) => chain.includes("waze") && chain.includes("gmap");

/** The order for one fare: Google Maps first ([gmapFirst]) swaps "waze"
 * and "gmap" where they stand; every other step keeps its place. */
export function orderFor(chain: readonly FareStep[], gmapFirst: boolean): FareStep[] {
  const out = [...chain];
  if (!balanceApplies(out)) return out;
  const w = out.indexOf("waze"), g = out.indexOf("gmap");
  const wazeBefore = w < g;
  if (gmapFirst === wazeBefore) [out[w], out[g]] = [out[g], out[w]];
  return out;
}

/** Whether this fare asks Google Maps first, for a share in percent;
 * [random] is in [0, 1). */
export const pickGmapFirst = (sharePct: number, random: number) => random * 100 < sharePct;

// ---- automatic share -----------------------------------------------------------------------------

/** One provider's last 15 minutes, from fare_ai_responses. */
export interface StepStats {
  attempts: number;
  successes: number;
  /** Median latency of its attempts, ms (null when none). */
  medianMs: number | null;
  /** waze_server_health says every server of this kind is offline. */
  offline?: boolean;
}

/** Fewer attempts than this in 15 minutes is not enough to move the share. */
export const MIN_ATTEMPTS = 5;
/** Most the share moves in one minute (percentage points). */
export const MAX_STEP = 5;
/** A Google Maps median this slow is too close to the 3 s budget. */
export const SLOW_GMAP_MS = 2_700;

export interface AutoDecision {
  pct: number;
  reason: string;
}

const rate = (s: StepStats) => (s.attempts > 0 ? s.successes / s.attempts : 0);
const clamp = (v: number, b: LiveBalance) => Math.min(b.maxPct, Math.max(b.minPct, Math.round(v)));

/** The next automatic share, from the current one and the last 15 minutes:
 *  - a kind that is offline gets as little as the range allows;
 *  - with enough attempts on both, the share moves toward the one that
 *    answers more often (up to MAX_STEP points a minute), and down when
 *    Google Maps is too slow for the budget;
 *  - otherwise it stays, kept inside the range. */
export function nextAutoShare(prevPct: number, waze: StepStats, gmap: StepStats, b: LiveBalance): AutoDecision {
  if (gmap.offline && !waze.offline) {
    return { pct: b.minPct, reason: "Google Maps servers are offline: Waze first" };
  }
  if (waze.offline && !gmap.offline) {
    return { pct: b.maxPct, reason: "Waze servers are offline: Google Maps first as much as allowed" };
  }
  const prev = clamp(prevPct, b);
  if (waze.attempts < MIN_ATTEMPTS || gmap.attempts < MIN_ATTEMPTS) {
    return { pct: prev, reason: `Not enough lookups in the last 15 minutes to compare (Waze ${waze.attempts}, Google Maps ${gmap.attempts})` };
  }
  const rw = rate(waze), rg = rate(gmap);
  let step = Math.max(-MAX_STEP, Math.min(MAX_STEP, (rg - rw) * 20));
  const slow = gmap.medianMs !== null && gmap.medianMs > SLOW_GMAP_MS;
  if (slow) step = Math.min(step, -2);
  const next = clamp(prev + step, b);
  const pctTxt = (r: number) => `${Math.round(r * 100)}%`;
  const why = slow
    ? `Google Maps is slow (median ${(gmap.medianMs! / 1000).toFixed(1)} s)`
    : rg > rw ? "Google Maps answers more often" : rg < rw ? "Waze answers more often" : "both answer equally";
  return {
    pct: next,
    reason: `${why}: Waze ${pctTxt(rw)} of ${waze.attempts}, Google Maps ${pctTxt(rg)} of ${gmap.attempts} answered`,
  };
}

/** Median of a list of numbers (null when empty). */
export function median(values: number[]): number | null {
  const v = values.filter((x) => Number.isFinite(x)).sort((a, b) => a - b);
  if (v.length === 0) return null;
  const m = Math.floor(v.length / 2);
  return v.length % 2 ? v[m] : Math.round((v[m - 1] + v[m]) / 2);
}
