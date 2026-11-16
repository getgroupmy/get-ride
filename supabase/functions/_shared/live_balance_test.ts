import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import {
  appleBalanceApplies,
  appleBalanceOf,
  liveFirstOf,
  nextAppleShare,
  orderForFirst,
  pickLiveFirst,
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

Deno.test("orderFor: the Waze / Google Maps balance leaves Apple Maps where it stands", () => {
  assertEquals(orderFor(["waze", "gmap", "apple", "ai", "osrm"], true), ["gmap", "waze", "apple", "ai", "osrm"]);
  assertEquals(orderFor(["waze", "apple", "gmap", "osrm"], true), ["gmap", "apple", "waze", "osrm"]);
  assertEquals(orderFor(["waze", "apple", "ai", "osrm"], true), ["waze", "apple", "ai", "osrm"]);
  assert(!balanceApplies(["waze", "apple", "ai", "osrm"]));
});

Deno.test("appleBalanceOf: off by default (Apple keeps its place); tolerant of bad fields", () => {
  assertEquals(appleBalanceOf(null), { mode: "fixed", firstPct: 0, minPct: 0, maxPct: 30 });
  assertEquals(appleBalanceOf({ liveBalance: { mode: "auto" } }).mode, "fixed", "the Google Maps mode is not Apple's");
  assertEquals(appleBalanceOf({ liveBalance: { apple: { mode: "auto", minPct: 40, maxPct: 10 } } }), {
    mode: "auto", firstPct: 0, minPct: 10, maxPct: 40,
  });
  assertEquals(appleBalanceOf({ liveBalance: { apple: { firstPct: 250 } } }).firstPct, 100);
  assert(appleBalanceApplies(["waze", "apple", "osrm"]));
  assert(appleBalanceApplies(["gmap", "apple"]));
  assert(!appleBalanceApplies(["apple", "ai", "osrm"]));
});

Deno.test("pickLiveFirst: Google Maps' share as before, Apple's taken from Waze's part", () => {
  // Google Maps 20 %, Apple Maps 15 %: 0-20 Google, 20-35 Apple, the rest Waze.
  assertEquals(pickLiveFirst(20, 15, 0.1), "gmap");
  assertEquals(pickLiveFirst(20, 15, 0.25), "apple");
  assertEquals(pickLiveFirst(20, 15, 0.5), "waze");
  // Without an Apple share it is exactly pickGmapFirst.
  for (const r of [0, 0.19, 0.2, 0.99]) assertEquals(pickLiveFirst(20, 0, r) === "gmap", pickGmapFirst(20, r));
  // Apple never takes Google Maps' part.
  assertEquals(pickLiveFirst(80, 50, 0.85), "apple");
  assertEquals(pickLiveFirst(80, 50, 0.1), "gmap");
  assertEquals(pickLiveFirst(0, 100, 0.99), "apple");
});

Deno.test("orderForFirst: Apple first moves in front of the live steps; Waze / Google as orderFor", () => {
  const chain = ["waze", "gmap", "apple", "ai", "osrm"] as const;
  assertEquals(orderForFirst(chain, "apple"), ["apple", "waze", "gmap", "ai", "osrm"]);
  assertEquals(orderForFirst(chain, "gmap"), orderFor(chain, true));
  assertEquals(orderForFirst(chain, "waze"), orderFor(chain, false));
  assertEquals(orderForFirst(["ai", "waze", "apple", "osrm"], "apple"), ["ai", "apple", "waze", "osrm"]);
  assertEquals(orderForFirst(["gmap", "waze", "apple"], "apple"), ["apple", "waze", "gmap"]);
  assertEquals(liveFirstOf(["ai", "apple", "waze"]), "apple");
  assertEquals(liveFirstOf(["ai", "osrm"]), undefined);
});

const appleRange = { mode: "auto" as const, firstPct: 0, minPct: 5, maxPct: 30 };
const st = (attempts: number, successes: number, medianMs: number | null = 500, offline = false) => ({ attempts, successes, medianMs, offline });

Deno.test("nextAppleShare: offline or quota refusals to the bottom, Waze offline to the top", () => {
  assertEquals(nextAppleShare(20, st(10, 9), { ...st(0, 0, null, true), quotaRefusals: 0 }, appleRange).pct, 5);
  const q = nextAppleShare(20, st(10, 9), { ...st(10, 9), quotaRefusals: 3 }, appleRange);
  assertEquals(q.pct, 5);
  assert(q.reason.includes("quota"));
  assertEquals(nextAppleShare(10, st(0, 0, null, true), { ...st(10, 9), quotaRefusals: 0 }, appleRange).pct, 30);
});

Deno.test("nextAppleShare: moves toward the one that answers more often; slow Apple backs off", () => {
  assertEquals(nextAppleShare(12, st(2, 2), { ...st(2, 2), quotaRefusals: 0 }, appleRange).pct, 12, "too few lookups");
  assertEquals(nextAppleShare(50, st(2, 2), { ...st(2, 2), quotaRefusals: 0 }, appleRange).pct, 30, "kept in range");
  assertEquals(nextAppleShare(10, st(20, 10), { ...st(20, 20), quotaRefusals: 0 }, appleRange).pct, 15);
  assertEquals(nextAppleShare(10, st(20, 20), { ...st(20, 10), quotaRefusals: 0 }, appleRange).pct, 5);
  const slow = nextAppleShare(10, st(20, 20), { ...st(20, 20, 1400), quotaRefusals: 0 }, appleRange);
  assertEquals(slow.pct, 8);
  assert(slow.reason.startsWith("Apple Maps is slow"));
});
