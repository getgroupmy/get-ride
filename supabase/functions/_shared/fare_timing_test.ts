import { assertEquals } from "jsr:@std/assert@1.0.19";
import {
  appTimingOf,
  DEFAULT_APP_TIMING,
  DEFAULT_SERVER_TIMING,
  deviceChain,
  deviceReportOf,
  fetchWithin,
  resumeSteps,
  serverTimingOf,
} from "./fare_timing.ts";

Deno.test("serverTimingOf: Waze and Google Maps 2 s each, Apple 1.5 s, AI 5 s, OSRM 3 s; seconds in, bounded", () => {
  assertEquals(serverTimingOf(null), DEFAULT_SERVER_TIMING);
  assertEquals(serverTimingOf({ timing: { wazeSeconds: 2.5, gmapSeconds: 1, appleSeconds: 1, aiSeconds: 4, osrmSeconds: 2.5 } }), {
    wazeMs: 2_500, gmapMs: 1_000, appleMs: 1_000, aiMs: 4_000, osrmMs: 2_500,
  });
  assertEquals(serverTimingOf({ timing: { wazeSeconds: 0, gmapSeconds: 99, aiSeconds: 999, osrmSeconds: "x" } }), {
    wazeMs: 500, gmapMs: 15_000, appleMs: 1_500, aiMs: 30_000, osrmMs: 3_000,
  });
});

Deno.test("appTimingOf: the app waits 5 s, iPhones ask Apple Maps for 1.5 s, unless set", () => {
  assertEquals(appTimingOf(undefined), DEFAULT_APP_TIMING);
  assertEquals(appTimingOf({ appWaitSeconds: 8, deviceApple: false, deviceAppleSeconds: 3 }), {
    appWaitMs: 8_000, deviceApple: false, deviceAppleMs: 3_000,
  });
  assertEquals(appTimingOf({ appWaitSeconds: 1 }).appWaitMs, 2_000);
});

Deno.test("deviceChain: Apple Maps' place, or right after Waze / Google Maps", () => {
  assertEquals(deviceChain(["waze", "gmap", "apple", "ai", "osrm"]), ["waze", "gmap", "apple", "ai", "osrm"]);
  assertEquals(deviceChain(["waze", "gmap", "ai", "osrm"]), ["waze", "gmap", "apple", "ai", "osrm"]);
  assertEquals(deviceChain(["waze", "ai", "gmap", "osrm"]), ["waze", "ai", "gmap", "apple", "osrm"]);
  assertEquals(deviceChain(["ai", "osrm"]), ["apple", "ai", "osrm"]);
  assertEquals(deviceChain([]), []);
});

Deno.test("resumeSteps: only steps of the order, once, no Apple, OSRM last", () => {
  const chain = ["waze", "gmap", "apple", "ai", "osrm"] as const;
  assertEquals(resumeSteps(chain, ["ai", "osrm"]), ["ai", "osrm"]);
  assertEquals(resumeSteps(chain, ["osrm", "gmap", "apple", "ai", "ai", "nonsense"]), ["gmap", "ai", "osrm"]);
  assertEquals(resumeSteps(["waze", "osrm"], ["ai", "osrm"]), ["osrm"], "the AI is not in the order");
  assertEquals(resumeSteps(chain, "ai"), []);
});

Deno.test("deviceReportOf: a sensible answer, or a failure with its reason", () => {
  assertEquals(deviceReportOf({ success: true, distance_km: 41.43, duration_min: 47.2, latency_ms: 640 }), {
    success: true, distance_km: 41.4, duration_min: 48, latency_ms: 640, error: null,
  });
  assertEquals(deviceReportOf({ success: false, error: "MKErrorLoadingThrottled", latency_ms: 2000 }), {
    success: false, distance_km: null, duration_min: null, latency_ms: 2000, error: "MKErrorLoadingThrottled",
  });
  assertEquals(deviceReportOf({ success: true, distance_km: -1, duration_min: 5 })?.success, false);
  assertEquals(deviceReportOf("x"), null);
});

Deno.test("fetchWithin: passes a time limit to every call", async () => {
  let signal: AbortSignal | null | undefined;
  const f = fetchWithin(1234, ((_: unknown, init?: RequestInit) => {
    signal = init?.signal;
    return Promise.resolve(new Response("{}"));
  }) as typeof fetch);
  await f("https://example.invalid", { method: "POST" });
  assertEquals(signal instanceof AbortSignal, true);
});
