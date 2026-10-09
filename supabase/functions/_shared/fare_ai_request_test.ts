/**
 * What the fare AI is asked.
 *
 *     deno test supabase/functions/_shared/fare_ai_request_test.ts
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import {
  buildPrompt,
  decideFareTrend,
  DEFAULT_REQUEST,
  formatClause,
  hexColor,
  MAX_STOPS,
  parseStops,
  parseTrafficExtras,
  resolveRequest,
  resolveTrendSettings,
  retryPolicyMs,
  templateProblem,
} from "./fare_ai_request.ts";

const a = { latitude: 3.158, longitude: 101.712 };
const b = { latitude: 3.134, longitude: 101.686 };

// The prompt ai-route-proxy sent before the request was editable, word for word.
const LEGACY =
  `You are a driving route estimator with access to real-time traffic and toll road data. ` +
  `For the trip "3.158,101.712 to 3.134,101.686 realtime minute and distance with traffic", estimate the total driving distance, the ` +
  `current driving time including live traffic, and the toll booths/plazas along the route ` +
  `with their individual charges in local currency. ` +
  `Respond with ONLY a compact JSON object, no markdown, no extra text, of the form: ` +
  `{"distance_km": <number>, "duration_min": <number>, "summary": "<short text>", ` +
  `"toll_count": <integer>, "toll_total": <number>, "tolls": [{"name": "<booth name>", "charge": <number>, "lat": <number>, "lng": <number>}]}. ` +
  `distance_km is total kilometres (number). duration_min is total minutes with traffic (integer). ` +
  `toll_count is the number of toll booths/plazas on the route (integer, 0 if none). ` +
  `toll_total is the sum of all toll charges (number, 0 if none). ` +
  `tolls is an array of each real toll booth/plaza that physically exists on this route, in travel order, ` +
  `each with its name, charge, and exact geographic coordinates (lat and lng as decimal degrees) of the booth location. ` +
  `Use real, known toll plaza coordinates; do not invent coordinates. Empty array if none.`;

Deno.test("with nothing configured the prompt is the one sent before", () => {
  assertEquals(buildPrompt(resolveRequest(undefined), a, b), LEGACY);
  assertEquals(resolveRequest(null).systemInstruction, DEFAULT_REQUEST.systemInstruction);
});

Deno.test("placeholders fill in the trip", () => {
  const req = resolveRequest({ promptTemplate: "From {origin_lat}/{origin_lng} to {dest_lat}/{dest_lng}." });
  assertStringIncludes(buildPrompt(req, a, b), "From 3.158/101.712 to 3.134/101.686.");
});

Deno.test("stops are told to the AI in order, after the template; none changes nothing", () => {
  const req = resolveRequest(undefined);
  assertEquals(buildPrompt(req, a, b, []), LEGACY);
  const p = buildPrompt(req, a, b, [{ latitude: 3.2, longitude: 101.7 }, { latitude: 3.1, longitude: 101.6 }]);
  assertStringIncludes(p, "in this order, at: 1) 3.2,101.7; 2) 3.1,101.6.");
  assertStringIncludes(p, "whole trip from the origin through every stop");
  assert(p.indexOf("3.2,101.7") < p.indexOf("Respond with ONLY"), "the stops come before the answer format");
});

Deno.test("stops: a list of coordinates, at most five; absent is none", () => {
  assertEquals(parseStops(undefined), []);
  assertEquals(parseStops([{ latitude: 1, longitude: 2, extra: true }]), [{ latitude: 1, longitude: 2 }]);
  assertEquals(parseStops({ latitude: 1, longitude: 2 }), null);
  assertEquals(parseStops([{ latitude: 91, longitude: 2 }]), null);
  assertEquals(parseStops(Array.from({ length: MAX_STOPS + 1 }, () => ({ latitude: 1, longitude: 1 }))), null);
});

Deno.test("a template that loses the trip is refused and the default used", () => {
  assert(templateProblem("Estimate a drive.") !== null);
  assert(templateProblem("From {origin} somewhere.") !== null);
  assert(templateProblem("From {origin_lat} to {destination}.") !== null, "half a lat/lng pair is not enough");
  assertEquals(templateProblem("{origin} → {destination}"), null);
  assertEquals(resolveRequest({ promptTemplate: "Estimate a drive." }).promptTemplate, DEFAULT_REQUEST.promptTemplate);
});

Deno.test("switches shape the answer format, which always keeps distance and time", () => {
  const bare = formatClause(resolveRequest({ includeSummary: false, includeTolls: false }));
  assertStringIncludes(bare, '{"distance_km": <number>, "duration_min": <number>}');
  assert(!bare.includes("toll"));
  assert(!bare.includes("summary"));

  const noCoords = formatClause(resolveRequest({ includeTollCoords: false }));
  assertStringIncludes(noCoords, '"tolls": [{"name": "<booth name>", "charge": <number>}]');
  assert(!noCoords.includes('"lat"'));

  // No tolls means no toll coordinates either.
  assertEquals(resolveRequest({ includeTolls: false, includeTollCoords: true }).includeTollCoords, false);
});

Deno.test("temperature and the token cap stay in range", () => {
  assertEquals(resolveRequest({ temperature: 3, maxTokens: 10 }).temperature, 1);
  assertEquals(resolveRequest({ temperature: 3, maxTokens: 10 }).maxTokens, 128);
  assertEquals(resolveRequest({ temperature: "x", maxTokens: 99999 }).maxTokens, 4096);
  assertEquals(resolveRequest({ temperature: "x" }).temperature, 0);
});

Deno.test("a failed key can rest for minutes", () => {
  assertEquals(retryPolicyMs(15, "minute"), 15 * 60 * 1000);
  assertEquals(retryPolicyMs(2, "hour"), 2 * 3600 * 1000);
  assertEquals(retryPolicyMs(1, "day"), 24 * 3600 * 1000);
  assertEquals(retryPolicyMs(1, "month"), 30 * 24 * 3600 * 1000);
  assertEquals(retryPolicyMs(0, "minute"), 60 * 1000);
});

Deno.test("fare range and traffic are off unless switched on", () => {
  const req = resolveRequest(undefined);
  assertEquals([req.includeFareRange, req.includeTraffic], [false, false]);
  const clause = formatClause(req);
  assert(!clause.includes("current_duration_is"));
  assert(!clause.includes("traffic_congestion"));
});

Deno.test("switched on, they are asked for", () => {
  const clause = formatClause(resolveRequest({ includeFareRange: true, includeTraffic: true }));
  assertStringIncludes(clause, '"current_duration_is_baseline": <boolean>, "current_duration_is_low": <boolean>, "current_duration_is_heavy": <boolean>');
  assertStringIncludes(clause, '"traffic_congestion": "<none|light|moderate|heavy>"');
  assertStringIncludes(clause, '"traffic_congestion_stretch_location_details": [{"road": "<road name>"');
  assertStringIncludes(clause, "Exactly one of current_duration_is_baseline");
});

Deno.test("the answers are kept only where they make sense", () => {
  assertEquals(
    parseTrafficExtras({
      current_duration_is_baseline: false,
      current_duration_is_low: "false",
      current_duration_is_heavy: true,
      traffic_congestion: " Heavy ",
      traffic_congestion_stretch_location_details: [
        { road: "MEX", from: "Seri Kembangan", to: "Putrajaya", delay_min: 7.6 },
        { road: "", from: "x" },
        "junk",
        { road: "ELITE", delay_min: -3 },
      ],
    }),
    {
      current_duration_is_baseline: false,
      current_duration_is_low: false,
      current_duration_is_heavy: true,
      traffic_congestion: "heavy",
      traffic_congestion_stretch_location_details: [
        { road: "MEX", from: "Seri Kembangan", to: "Putrajaya", delay_min: 8 },
        { road: "ELITE" },
      ],
    },
  );
  // Two flags at once, or an unknown level: dropped, not guessed.
  assertEquals(
    parseTrafficExtras({
      current_duration_is_baseline: true,
      current_duration_is_low: true,
      current_duration_is_heavy: false,
      traffic_congestion: "gridlock",
    }),
    {},
  );
});

Deno.test("fare trend: settings off unless a positive percent", () => {
  const none = { upColorLight: null, upColorDark: null, downColorLight: null, downColorDark: null };
  assertEquals(resolveTrendSettings(undefined), { upPct: null, downPct: null, ...none });
  assertEquals(resolveTrendSettings({ upPct: "25", downPct: 0 }), { upPct: 25, downPct: null, ...none });
  assertEquals(resolveTrendSettings({ upPct: -5, downPct: 10 }), { upPct: null, downPct: 10, ...none });
});

Deno.test("fare trend: minutes against the standard route, by the thresholds", () => {
  const s = { upPct: 25, downPct: 10, upColorLight: null, upColorDark: null, downColorLight: null, downColorDark: null };
  assertEquals(decideFareTrend(30, 20, {}, s, false)?.direction, "up"); // +50%
  assertEquals(decideFareTrend(24, 20, {}, s, false)?.direction, null); // +20%
  assertEquals(decideFareTrend(18, 20, {}, s, false)?.direction, "down"); // -10%
  assertEquals(decideFareTrend(19, 20, {}, s, false)?.direction, null); // -5%
  const t = decideFareTrend(25, 20, {}, s, false)!;
  assertEquals([t.source, t.pct, t.standard_min], ["minutes", 25, 20]);
  assertEquals(decideFareTrend(40, 20, {}, { ...s, upPct: null, downPct: null }, false)?.direction, null);
  assertEquals(decideFareTrend(30, null, {}, s, false), null, "no standard, nothing to compare");
});

Deno.test("fare trend: the fare-range verdict overrides the minutes when asked for", () => {
  const s = { upPct: 25, downPct: 10, upColorLight: null, upColorDark: null, downColorLight: null, downColorDark: null };
  const heavy = { current_duration_is_baseline: false, current_duration_is_low: false, current_duration_is_heavy: true };
  const low = { current_duration_is_baseline: false, current_duration_is_low: true, current_duration_is_heavy: false };
  const base = { current_duration_is_baseline: true, current_duration_is_low: false, current_duration_is_heavy: false };
  assertEquals(decideFareTrend(18, 20, heavy, s, true)?.direction, "up");
  assertEquals(decideFareTrend(30, 20, low, s, true)?.direction, "down");
  assertEquals(decideFareTrend(30, 20, base, s, true)?.direction, null);
  assertEquals(decideFareTrend(30, 20, base, s, true)?.source, "fare_range");
  // Fare range on but not answered: the minutes decide.
  assertEquals(decideFareTrend(30, 20, {}, s, true)?.source, "minutes");
  // Fare range off: its flags are ignored.
  assertEquals(decideFareTrend(30, 20, low, s, false)?.direction, "up");
});

Deno.test("fare trend: the admin's colours ride with the arrows they belong to", () => {
  assertEquals(hexColor("#e02424"), "#E02424");
  assertEquals(hexColor("0f0"), "#00FF00");
  assertEquals(hexColor("red"), null);
  assertEquals(hexColor("#12345"), null);
  const s = resolveTrendSettings({ upPct: 25, downPct: 10, upColorLight: "#ff0000", upColorDark: "ff6666", downColorLight: "#0a0" });
  const up = decideFareTrend(30, 20, {}, s, false)!;
  assertEquals([up.color_light, up.color_dark], ["#FF0000", "#FF6666"]);
  const down = decideFareTrend(17, 20, {}, s, false)!;
  assertEquals([down.color_light, down.color_dark], ["#00AA00", undefined]);
  assertEquals(decideFareTrend(21, 20, {}, s, false)!.color_light, undefined, "no arrows, no colour");
});
