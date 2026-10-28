import { assertEquals, assertRejects } from "jsr:@std/assert@1.0.19";

import { cleanResults, fillProject, handleNasOps } from "./nas_ops.ts";

const KEY = "b".repeat(64);
const PROJECT = "https://x.supabase.co";

function fake(answers: Record<string, unknown> = {}, fail?: Error) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  return {
    calls,
    deps: {
      projectUrl: PROJECT + "/",
      rpc(name: string, args: Record<string, unknown>) {
        calls.push([name, args]);
        if (fail) return Promise.reject(fail);
        return Promise.resolve(answers[name] ?? null);
      },
    },
  };
}

Deno.test("pairing trades the code for a key, and says why not", async () => {
  const ok = fake({ nas_ops_pair: { key: KEY, agent: "a1", label: "DS224+" } });
  const r = await handleNasOps({ action: "pair", code: " abcd-efgh ", device_id: "nas-1", version: "1.0.0" }, null, ok.deps);
  assertEquals(r.status, 200);
  assertEquals(r.body.key, KEY);
  assertEquals(ok.calls[0], ["nas_ops_pair", {
    p_code: "abcd-efgh",
    p_device_id: "nas-1",
    p_label: null,
    p_model: null,
    p_app_version: "1.0.0",
  }]);

  const wrong = await handleNasOps({ action: "pair", code: "x", device_id: "d" }, null,
    fake({ nas_ops_pair: { error: "NAS_PAIR_CODE", hint: "…" } }).deps);
  assertEquals(wrong.status, 400);
  const busy = await handleNasOps({ action: "pair", code: "x", device_id: "d" }, null,
    fake({ nas_ops_pair: { error: "NAS_PAIR_BUSY" } }).deps);
  assertEquals(busy.status, 429);
  assertEquals((await handleNasOps({ action: "pair", code: "x" }, null, fake().deps)).status, 400);
});

Deno.test("every other call needs the key", async () => {
  const f = fake();
  assertEquals((await handleNasOps({ action: "heartbeat" }, null, f.deps)).status, 401);
  assertEquals((await handleNasOps({ action: "heartbeat" }, "short", f.deps)).status, 401);
  assertEquals((await handleNasOps({ action: "drop_tables" }, KEY, f.deps)).status, 400);
  assertEquals(f.calls.length, 0);
});

Deno.test("heartbeat fills in {project} and says when to come back", async () => {
  const f = fake({
    nas_ops_heartbeat: {
      backup: { at: "02:00" },
      targets: [
        { id: "functions", kind: "http", url: "{project}/functions/v1/uptime-check?ping=1" },
        { id: "database", kind: "database", url: null },
      ],
      requests: [{ id: "q1", kind: "backup" }],
    },
  });
  const r = await handleNasOps({ action: "heartbeat", version: "1.0.0", services: { box: { status: "ok" } } }, KEY, f.deps);
  assertEquals(r.status, 200);
  assertEquals((r.body.targets as Array<{ url: string | null }>).map((t) => t.url), [
    "https://x.supabase.co/functions/v1/uptime-check?ping=1",
    null,
  ]);
  assertEquals(r.body.pollAfter, 60);
  assertEquals(f.calls[0][1].p_services, { box: { status: "ok" } });
});

Deno.test("runs start and finish", async () => {
  const f = fake({ nas_backup_started: "run-1", nas_backup_finished: "ok" });
  const s = await handleNasOps({ action: "backup_start", kind: "backup", trigger: "manual", request: "q1" }, KEY, f.deps);
  assertEquals(s.body, { run: "run-1" });
  assertEquals(f.calls[0][1], { p_key: KEY, p_kind: "backup", p_trigger: "manual", p_request: "q1" });
  assertEquals((await handleNasOps({ action: "backup_start", kind: "everything" }, KEY, f.deps)).status, 400);

  const d = await handleNasOps({
    action: "backup_finish",
    run: "run-1",
    ok: true,
    db_bytes: 1.8e9,
    files: 3104,
    files_bytes: -5,
    total_bytes: "lots",
    detail: { buckets: ["avatars"] },
  }, KEY, f.deps);
  assertEquals(d.body, { status: "ok" });
  const args = f.calls.at(-1)![1];
  assertEquals([args.p_db_bytes, args.p_files, args.p_files_bytes, args.p_total_bytes], [1.8e9, 3104, null, null]);
  assertEquals(args.p_detail, { buckets: ["avatars"] });
  assertEquals((await handleNasOps({ action: "backup_finish", run: "r" }, KEY, f.deps)).status, 400);
});

Deno.test("uptime results are cleaned before they are kept", async () => {
  assertEquals(cleanResults([
    { id: "website", status: "up", ms: 210.4 },
    { id: "admin", status: "maybe" },
    { status: "down" },
    "x",
    { id: "database", status: "down", detail: "Timed out", ms: -1 },
  ]), [
    { id: "website", status: "up", ms: 210, detail: null },
    { id: "database", status: "down", ms: null, detail: "Timed out" },
  ]);
  assertEquals(cleanResults(null), []);
  const f = fake({ nas_uptime_report: 1 });
  const r = await handleNasOps({ action: "uptime_report", results: [{ id: "website", status: "up" }] }, KEY, f.deps);
  assertEquals(r.body, { kept: 1 });
});

Deno.test("a removed key is a 401; other errors are thrown", async () => {
  const gone = await handleNasOps({ action: "heartbeat" }, KEY, fake({}, new Error("NAS_KEY_INVALID")).deps);
  assertEquals(gone.status, 401);
  await assertRejects(() => handleNasOps({ action: "heartbeat" }, KEY, fake({}, new Error("boom")).deps));
});

Deno.test("{project} without a trailing slash", () => {
  assertEquals(fillProject("{project}/functions/v1/x", "https://a.co//"), "https://a.co/functions/v1/x");
  assertEquals(fillProject("https://getride.my", "https://a.co"), "https://getride.my");
  assertEquals(fillProject(null, "https://a.co"), null);
});
