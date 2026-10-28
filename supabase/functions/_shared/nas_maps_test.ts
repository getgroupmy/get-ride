import { assertEquals, assertRejects } from "jsr:@std/assert@1.0.19";

import { cleanDetail, handleNasMaps, HEARTBEAT_SECONDS } from "./nas_maps.ts";

const KEY = "b".repeat(64);

function fake(answers: Record<string, unknown> = {}, fail?: Error) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  return {
    calls,
    deps: {
      rpc(name: string, args: Record<string, unknown>) {
        calls.push([name, args]);
        if (fail) return Promise.reject(fail);
        return Promise.resolve(answers[name] ?? null);
      },
    },
  };
}

Deno.test("pairing trades the code for a key, and says why not", async () => {
  const ok = fake({ nas_maps_pair: { key: KEY, server: "s1", label: "DS224+" } });
  const r = await handleNasMaps(
    { action: "pair", code: " abcd-efgh ", device_id: "nas-1", model: "DS224+ J4125", version: "1.0.0" },
    null,
    ok.deps,
  );
  assertEquals(r.status, 200);
  assertEquals(r.body.key, KEY);
  assertEquals(ok.calls[0], ["nas_maps_pair", {
    p_code: "abcd-efgh",
    p_device_id: "nas-1",
    p_label: null,
    p_model: "DS224+ J4125",
    p_app_version: "1.0.0",
  }]);
  const wrong = fake({ nas_maps_pair: { error: "NAS_PAIR_CODE", hint: "wrong" } });
  assertEquals((await handleNasMaps({ action: "pair", code: "x", device_id: "d" }, null, wrong.deps)).status, 400);
  const busy = fake({ nas_maps_pair: { error: "NAS_PAIR_BUSY" } });
  assertEquals((await handleNasMaps({ action: "pair", code: "x", device_id: "d" }, null, busy.deps)).status, 429);
  assertEquals((await handleNasMaps({ action: "pair", code: "x" }, null, ok.deps)).status, 400, "no device id");
});

Deno.test("the heartbeat needs the key; other actions are refused", async () => {
  const f = fake();
  assertEquals((await handleNasMaps({ action: "heartbeat" }, null, f.deps)).status, 401);
  assertEquals((await handleNasMaps({ action: "heartbeat" }, "short", f.deps)).status, 401);
  assertEquals((await handleNasMaps({ action: "claim" }, KEY, f.deps)).status, 400);
  assertEquals(f.calls.length, 0);
});

Deno.test("a heartbeat passes the health, the tunnel and the secret on", async () => {
  const f = fake({ nas_maps_heartbeat: { server: "s1", label: "DS224+", settings: { routes: true } } });
  const r = await handleNasMaps({
    action: "heartbeat",
    status: "refreshing",
    detail: { osrm: { ok: true, ms: 80 }, photon: { ok: true, ms: 60, apiKey: "nope" } },
    version: "1.0.0",
    mapsUrl: "https://maps.getride.my",
    tilesUrl: "https://tiles.getride.my",
    secret: "s".repeat(64),
  }, KEY, f.deps);
  assertEquals(r.status, 200);
  assertEquals(r.body.pollAfter, HEARTBEAT_SECONDS);
  const [name, args] = f.calls[0];
  assertEquals(name, "nas_maps_heartbeat");
  assertEquals(args.p_status, "refreshing");
  assertEquals(args.p_detail, { osrm: { ok: true, ms: 80 }, photon: { ok: true, ms: 60 } });
  assertEquals(args.p_maps_url, "https://maps.getride.my");
  assertEquals(args.p_secret, "s".repeat(64));

  await handleNasMaps({ action: "heartbeat", status: "fine" }, KEY, f.deps);
  assertEquals(f.calls[1][1].p_status, "degraded", "an unknown status is degraded");
});

Deno.test("a removed NAS is told to connect again; other errors are thrown", async () => {
  const gone = fake({}, new Error("NAS_KEY_INVALID"));
  const r = await handleNasMaps({ action: "heartbeat", status: "ok" }, KEY, gone.deps);
  assertEquals(r.status, 401);
  assertEquals(r.body.error, "NAS_KEY_INVALID");
  const broken = fake({}, new Error("connection reset"));
  await assertRejects(() => handleNasMaps({ action: "heartbeat", status: "ok" }, KEY, broken.deps));
});

Deno.test("detail: an object, no secrets, not too large", () => {
  assertEquals(cleanDetail(null), {});
  assertEquals(cleanDetail([1, 2]), {});
  assertEquals(cleanDetail({ tunnel: { token: "x", ok: true }, password: "y" }), { tunnel: { ok: true } });
  const big = Object.fromEntries(Array.from({ length: 100 }, (_, i) => [`k${i}`, "y".repeat(300)]));
  assertEquals(cleanDetail(big).error, "detail too large");
});
