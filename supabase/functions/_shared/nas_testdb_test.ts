import { assertEquals, assertRejects } from "jsr:@std/assert@1.0.19";

import { handleTestDb, POLL_BUSY_SECONDS, POLL_IDLE_SECONDS, runFiles } from "./nas_testdb.ts";

const KEY = "b".repeat(64);
const RUN = "6c34f865-fff1-409f-992a-186a1d813c35";

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
  const ok = fake({ testdb_pair: { key: KEY, runner: "r1", label: "DS224+" } });
  const r = await handleTestDb({ action: "pair", code: " abcd-efgh ", device_id: "nas-1", version: "1.0.0" }, null, ok.deps);
  assertEquals(r.status, 200);
  assertEquals(r.body.key, KEY);
  assertEquals(ok.calls[0], ["testdb_pair", {
    p_code: "abcd-efgh",
    p_device_id: "nas-1",
    p_label: null,
    p_model: null,
    p_app_version: "1.0.0",
  }]);
  const wrong = fake({ testdb_pair: { error: "TESTDB_PAIR_CODE" } });
  assertEquals((await handleTestDb({ action: "pair", code: "x", device_id: "d" }, null, wrong.deps)).status, 400);
  const busy = fake({ testdb_pair: { error: "TESTDB_PAIR_BUSY" } });
  assertEquals((await handleTestDb({ action: "pair", code: "x", device_id: "d" }, null, busy.deps)).status, 429);
  assertEquals((await handleTestDb({ action: "pair", code: "x" }, null, ok.deps)).status, 400, "no device id");
});

Deno.test("every other call needs the key", async () => {
  const f = fake();
  assertEquals((await handleTestDb({ action: "claim" }, null, f.deps)).status, 401);
  assertEquals((await handleTestDb({ action: "claim" }, "short", f.deps)).status, 401);
  assertEquals((await handleTestDb({ action: "drop" }, KEY, f.deps)).status, 400);
  assertEquals(f.calls.length, 0);
});

Deno.test("check-in passes the state on, small objects only", async () => {
  const f = fake({ testdb_heartbeat: { settings: { refreshAt: "02:30", scramble: true }, waiting: 1 } });
  const r = await handleTestDb(
    { action: "heartbeat", version: "1.0.0", state: { refreshed_at: "2026-10-28T02:41:00Z", scrambled: true } },
    KEY,
    f.deps,
  );
  assertEquals(r.status, 200);
  assertEquals(r.body.pollAfter, POLL_IDLE_SECONDS);
  assertEquals(f.calls[0][1].p_state, { refreshed_at: "2026-10-28T02:41:00Z", scrambled: true });
  await handleTestDb({ action: "heartbeat", state: { big: "x".repeat(5000) } }, KEY, f.deps);
  assertEquals(f.calls[1][1].p_state, null);
  await handleTestDb({ action: "heartbeat", state: [1, 2] }, KEY, f.deps);
  assertEquals(f.calls[2][1].p_state, null);
});

Deno.test("claim: a run means ask again soon", async () => {
  const busy = fake({ testdb_claim: { id: RUN, kind: "migration", pr_number: 554 } });
  const r = await handleTestDb({ action: "claim" }, KEY, busy.deps);
  assertEquals((r.body.run as { pr_number: number }).pr_number, 554);
  assertEquals(r.body.pollAfter, POLL_BUSY_SECONDS);
  const idle = await handleTestDb({ action: "claim" }, KEY, fake().deps);
  assertEquals(idle.body, { run: null, pollAfter: POLL_IDLE_SECONDS });
});

Deno.test("report: what is sent on, cleaned", async () => {
  const f = fake({ testdb_report: { id: RUN, status: "failed" } });
  const r = await handleTestDb({
    action: "report",
    id: RUN,
    kind: "migration",
    ok: false,
    error: "ERROR: relation \"x\" does not exist",
    ms: 4210.6,
    detail: { rerun: "skipped" },
    head_sha: "ABC1234",
    files: ["supabase/migrations/0321_x.sql", "../etc/passwd", 7, "lib/x.dart"],
  }, KEY, f.deps);
  assertEquals(r.status, 200);
  assertEquals(f.calls[0], ["testdb_report", {
    p_key: KEY,
    p_id: RUN,
    p_kind: "migration",
    p_ok: false,
    p_error: "ERROR: relation \"x\" does not exist",
    p_ms: 4211,
    p_detail: { rerun: "skipped" },
    p_head_sha: "ABC1234",
    p_files: ["supabase/migrations/0321_x.sql"],
  }]);
  // The nightly refresh has no run id; a migration result always has one.
  await handleTestDb({ action: "report", kind: "refresh", ok: true, head_sha: "zzz" }, KEY, f.deps);
  assertEquals(f.calls[1][1].p_id, null);
  assertEquals(f.calls[1][1].p_head_sha, null, "not a commit");
  assertEquals(f.calls[1][1].p_files, null);
  assertEquals((await handleTestDb({ action: "report", kind: "migration", ok: true }, KEY, f.deps)).status, 400);
  assertEquals((await handleTestDb({ action: "report", kind: "drop", ok: true }, KEY, f.deps)).status, 400);
  assertEquals((await handleTestDb({ action: "report", kind: "refresh", id: "1; x", ok: true }, KEY, f.deps)).status, 400);
});

Deno.test("a removed key says so; other errors are the function's", async () => {
  const gone = fake({}, new Error("TESTDB_KEY_INVALID"));
  assertEquals((await handleTestDb({ action: "claim" }, KEY, gone.deps)).status, 401);
  const notYours = fake({}, new Error("TESTDB_NOT_YOURS"));
  const r = await handleTestDb({ action: "report", id: RUN, kind: "migration", ok: true }, KEY, notYours.deps);
  assertEquals([r.status, r.body.error], [400, "TESTDB_NOT_YOURS"]);
  await assertRejects(() => handleTestDb({ action: "claim" }, KEY, fake({}, new Error("db down")).deps));
});

Deno.test("only migration files are listed", () => {
  assertEquals(runFiles(["supabase/migrations/0321_nas_testdb_stats.sql", "supabase/migrations/a/b.sql", "x.sql"]), [
    "supabase/migrations/0321_nas_testdb_stats.sql",
  ]);
  assertEquals(runFiles("nope"), null);
  assertEquals(runFiles(Array.from({ length: 60 }, (_, i) => `supabase/migrations/${i}.sql`))?.length, 50);
});
