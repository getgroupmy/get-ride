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
 * Apple Maps has a share of its own (`liveBalance.apple`, the same fixed or
 * auto modes; auto set by waze-server-health into fare_live_balance's
 * apple_first_pct, migration 0416). It is taken from Waze's part: with
 * Google Maps first for 20 % and Apple Maps first for 15 %, Waze goes first
 * for the other 65 % (pickLiveFirst). The Google Maps share is never changed
 * by it. An Apple-first fare moves Apple Maps in front of the other
 * live-traffic steps, which keep their order (orderForFirst).
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

// ---- Apple Maps' share ---------------------------------------------------------------------------

/** The live-traffic steps: the balance chooses which of them goes first. */
export const LIVE_STEPS: readonly FareStep[] = ["waze", "gmap", "apple"];
export type LiveFirst = "waze" | "gmap" | "apple";

export interface AppleBalance {
  mode: BalanceMode;
  /** Fixed mode: share of fares asking Apple Maps first, 0-100. */
  firstPct: number;
  /** Auto mode: the range the share moves in. */
  minPct: number;
  maxPct: number;
}

/** A config without an Apple share: Apple Maps keeps its place in the order. */
export const DEFAULT_APPLE_BALANCE: AppleBalance = { mode: "fixed", firstPct: 0, minPct: 0, maxPct: 30 };

/** The saved Apple Maps share (`liveBalance.apple`), tolerant of bad fields. */
export function appleBalanceOf(config: Record<string, unknown> | null | undefined): AppleBalance {
  const lb = config?.liveBalance;
  const raw = lb && typeof lb === "object" ? (lb as Record<string, unknown>).apple : null;
  if (!raw || typeof raw !== "object") return { ...DEFAULT_APPLE_BALANCE };
  const o = raw as Record<string, unknown>;
  let minPct = pct(o.minPct, DEFAULT_APPLE_BALANCE.minPct);
  let maxPct = pct(o.maxPct, DEFAULT_APPLE_BALANCE.maxPct);
  if (minPct > maxPct) [minPct, maxPct] = [maxPct, minPct];
  return {
    mode: o.mode === "auto" ? "auto" : "fixed",
    firstPct: pct(o.firstPct, DEFAULT_APPLE_BALANCE.firstPct),
    minPct,
    maxPct,
  };
}

/** True when Apple Maps and another live-traffic step are in the order. */
export const appleBalanceApplies = (chain: readonly FareStep[]) =>
  chain.includes("apple") && (chain.includes("waze") || chain.includes("gmap"));

/** Which live-traffic step this fare asks first: Google Maps for [gmapPct] %
 * of fares, Apple Maps for the next [applePct] % (never more than is left),
 * Waze for the rest. [random] is in [0, 1). The Google Maps part is exactly
 * pickGmapFirst's. */
export function pickLiveFirst(gmapPct: number, applePct: number, random: number): LiveFirst {
  const r = random * 100;
  const g = Math.max(0, Math.min(100, gmapPct));
  if (r < g) return "gmap";
  if (r < g + Math.max(0, Math.min(100 - g, applePct))) return "apple";
  return "waze";
}

/** The order for one fare with [first] going first among the live-traffic
 * steps. Waze or Google Maps first is exactly orderFor. Apple Maps first
 * starts from Waze-before-Google order and moves Apple Maps in front of the
 * live-traffic steps; everything else keeps its place. */
export function orderForFirst(chain: readonly FareStep[], first: LiveFirst): FareStep[] {
  if (first !== "apple") return orderFor(chain, first === "gmap");
  const out = orderFor(chain, false);
  if (!out.includes("apple")) return out;
  const firstLive = out.findIndex((s) => LIVE_STEPS.includes(s));
  const a = out.indexOf("apple");
  if (a > firstLive) {
    out.splice(a, 1);
    out.splice(firstLive, 0, "apple");
  }
  return out;
}

/** The first live-traffic step of an order (for the log), if any. */
export const liveFirstOf = (chain: readonly FareStep[]): LiveFirst | undefined =>
  chain.find((s) => LIVE_STEPS.includes(s)) as LiveFirst | undefined;

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

/** An Apple Maps median this slow is too close to its own 1.5 s. */
export const SLOW_APPLE_MS = 1_200;

/** Apple Maps' last 15 minutes, plus how many of its answers were its quota
 * guard refusing (503 / 429: the day's or the minute's calls used up). */
export interface AppleStats extends StepStats {
  quotaRefusals: number;
}

/** The next automatic Apple Maps share, against Waze (whose part it takes):
 *  - Apple Maps offline, or refusing for its quota: the bottom of the range;
 *  - Waze offline: the top of the range;
 *  - with enough attempts on both, toward the one that answers more often
 *    (up to MAX_STEP points a minute), and down when Apple Maps is slow;
 *  - otherwise it stays, kept inside the range. */
export function nextAppleShare(prevPct: number, waze: StepStats, apple: AppleStats, b: AppleBalance): AutoDecision {
  const keep = (v: number) => Math.min(b.maxPct, Math.max(b.minPct, Math.round(v)));
  if (apple.offline && !waze.offline) {
    return { pct: b.minPct, reason: "Apple Maps servers are offline: Apple Maps first as little as allowed" };
  }
  if (apple.quotaRefusals > 0) {
    return {
      pct: b.minPct,
      reason: `Apple Maps refused ${apple.quotaRefusals} in the last 15 minutes for its quota: Apple Maps first as little as allowed`,
    };
  }
  if (waze.offline && !apple.offline) {
    return { pct: b.maxPct, reason: "Waze servers are offline: Apple Maps first as much as allowed" };
  }
  const prev = keep(prevPct);
  if (waze.attempts < MIN_ATTEMPTS || apple.attempts < MIN_ATTEMPTS) {
    return { pct: prev, reason: `Not enough lookups in the last 15 minutes to compare (Waze ${waze.attempts}, Apple Maps ${apple.attempts})` };
  }
  const rw = rate(waze), ra = rate(apple);
  let step = Math.max(-MAX_STEP, Math.min(MAX_STEP, (ra - rw) * 20));
  const slow = apple.medianMs !== null && apple.medianMs > SLOW_APPLE_MS;
  if (slow) step = Math.min(step, -2);
  const pctTxt = (r: number) => `${Math.round(r * 100)}%`;
  const why = slow
    ? `Apple Maps is slow (median ${(apple.medianMs! / 1000).toFixed(1)} s)`
    : ra > rw ? "Apple Maps answers more often" : ra < rw ? "Waze answers more often" : "both answer equally";
  return {
    pct: keep(prev + step),
    reason: `${why}: Waze ${pctTxt(rw)} of ${waze.attempts}, Apple Maps ${pctTxt(ra)} of ${apple.attempts} answered`,
  };
}

/** Median of a list of numbers (null when empty). */
export function median(values: number[]): number | null {
  const v = values.filter((x) => Number.isFinite(x)).sort((a, b) => a - b);
  if (v.length === 0) return null;
  const m = Math.floor(v.length / 2);
  return v.length % 2 ? v[m] : Math.round((v[m - 1] + v[m]) / 2);
}
