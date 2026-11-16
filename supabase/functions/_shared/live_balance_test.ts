import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import {
  balanceApplies,
  balanceOf,
  DEFAULT_BALANCE,
  median,
  nextAutoShare,
  orderFor,
  pickGmapFirst,
  type StepStats,
} from "./live_balance.ts";

Deno.test("balanceOf: defaults to Waze always first; tolerant of bad fields", () => {
  assertEquals(balanceOf(null), DEFAULT_BALANCE);
  assertEquals(balanceOf({}), DEFAULT_BALANCE);
  assertEquals(balanceOf({ liveBalance: { mode: "fixed", gmapFirstPct: 20 } }).gmapFirstPct, 20);
  assertEquals(balanceOf({ liveBalance: { mode: "auto", minPct: 50, maxPct: 10 } }), {
    mode: "auto", gmapFirstPct: 0, minPct: 10, maxPct: 50,
  });
  assertEquals(balanceOf({ liveBalance: { mode: "nonsense", gmapFirstPct: 250 } }).mode, "fixed");
  assertEquals(balanceOf({ liveBalance: { gmapFirstPct: 250 } }).gmapFirstPct, 100);
  assertEquals(balanceOf({ liveBalance: { gmapFirstPct: "x" } }).gmapFirstPct, 0);
});

Deno.test("orderFor: swaps only Waze and Google Maps, in place", () => {
  assertEquals(orderFor(["waze", "gmap", "ai", "osrm"], true), ["gmap", "waze", "ai", "osrm"]);
  assertEquals(orderFor(["waze", "gmap", "ai", "osrm"], false), ["waze", "gmap", "ai", "osrm"]);
  assertEquals(orderFor(["gmap", "waze", "osrm"], false), ["waze", "gmap", "osrm"]);
  assertEquals(orderFor(["gmap", "waze", "osrm"], true), ["gmap", "waze", "osrm"]);
  // Not both: nothing to balance.
  assertEquals(orderFor(["gmap", "ai", "osrm"], false), ["gmap", "ai", "osrm"]);
  assertEquals(orderFor(["waze", "ai"], true), ["waze", "ai"]);
  assert(balanceApplies(["waze", "ai", "gmap"]));
  assert(!balanceApplies(["waze", "ai"]));
});

Deno.test("pickGmapFirst: the share in percent", () => {
  assert(!pickGmapFirst(0, 0));
  assert(pickGmapFirst(100, 0.999));
  assert(pickGmapFirst(20, 0.19));
  assert(!pickGmapFirst(20, 0.2));
  let n = 0;
  for (let i = 0; i < 1000; i++) if (pickGmapFirst(25, i / 1000)) n++;
  assertEquals(n, 250);
});

const s = (attempts: number, successes: number, medianMs: number | null = 1500, offline = false): StepStats =>
  ({ attempts, successes, medianMs, offline });
const range = { mode: "auto" as const, gmapFirstPct: 0, minPct: 5, maxPct: 40 };

Deno.test("nextAutoShare: offline kinds go to the edge of the range", () => {
  assertEquals(nextAutoShare(20, s(50, 50), s(0, 0, null, true), range).pct, 5);
  assertEquals(nextAutoShare(20, s(0, 0, null, true), s(50, 50), range).pct, 40);
});

Deno.test("nextAutoShare: too few lookups keeps the share (inside the range)", () => {
  const d = nextAutoShare(20, s(4, 4), s(50, 10), range);
  assertEquals(d.pct, 20);
  assert(d.reason.startsWith("Not enough lookups"));
  assertEquals(nextAutoShare(80, s(1, 1), s(1, 1), range).pct, 40, "clamped into a new, narrower range");
});

Deno.test("nextAutoShare: moves toward the one that answers more often, at most 5 points", () => {
  // Google Maps 100 %, Waze 50 %: +5 (capped).
  assertEquals(nextAutoShare(20, s(20, 10), s(20, 20), range).pct, 25);
  // Waze 100 %, Google Maps 50 %: -5.
  assertEquals(nextAutoShare(20, s(20, 20), s(20, 10), range).pct, 15);
  // Small difference: small step (90 % vs 100 % -> -2).
  assertEquals(nextAutoShare(20, s(20, 20), s(20, 18), range).pct, 18);
  // Equal: stays.
  assertEquals(nextAutoShare(20, s(20, 20), s(20, 20), range).pct, 20);
  // Never past the range.
  assertEquals(nextAutoShare(39, s(20, 10), s(20, 20), range).pct, 40);
  assertEquals(nextAutoShare(6, s(20, 20), s(20, 10), range).pct, 5);
});

Deno.test("nextAutoShare: a slow Google Maps backs off even when it answers", () => {
  const d = nextAutoShare(20, s(20, 20), s(20, 20, 2900), range);
  assertEquals(d.pct, 18);
  assert(d.reason.startsWith("Google Maps is slow (median 2.9 s)"));
});

Deno.test("median", () => {
  assertEquals(median([]), null);
  assertEquals(median([3]), 3);
  assertEquals(median([5, 1, 3]), 3);
  assertEquals(median([1, 2, 3, 4]), 3);
});
