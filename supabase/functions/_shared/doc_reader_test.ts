import { assertEquals, assertRejects } from "jsr:@std/assert@1.0.19";

import { handleDocReader, PHOTO_LINK_SECONDS, readerPhoto } from "./doc_reader.ts";

const KEY = "a".repeat(64);
const STORE = "https://x.supabase.co/storage/v1/object/public";

function fake(answers: Record<string, unknown> = {}, fail?: Error) {
  const calls: Array<[string, Record<string, unknown>]> = [];
  const signed: string[] = [];
  return {
    calls,
    signed,
    deps: {
      rpc(name: string, args: Record<string, unknown>) {
        calls.push([name, args]);
        if (fail) return Promise.reject(fail);
        return Promise.resolve(answers[name] ?? null);
      },
      sign(bucket: string, path: string, seconds: number) {
        signed.push(`${bucket}/${path}@${seconds}`);
        return Promise.resolve(`https://signed/${bucket}/${path}`);
      },
    },
  };
}

Deno.test("photos come from the document buckets only", () => {
  assertEquals(readerPhoto(`${STORE}/provider-documents/p1/licence/front-1.jpg`), {
    bucket: "provider-documents",
    path: "p1/licence/front-1.jpg",
  });
  assertEquals(readerPhoto(`${STORE}/vehicle-documents/v1/cover/front%202.jpg`)?.path, "v1/cover/front 2.jpg");
  assertEquals(readerPhoto(`${STORE}/ID_Image/p1/ic.jpg`), null, "not the ID bucket");
  assertEquals(readerPhoto(`${STORE}/provider-documents/../secret.jpg`), null);
  assertEquals(readerPhoto("https://elsewhere.example/a.jpg"), null);
});

Deno.test("pairing trades the code for a key, and says why not", async () => {
  const ok = fake({ doc_reader_pair: { key: KEY, reader: "r1", kind: "nas", label: "DS224+" } });
  const r = await handleDocReader(
    { action: "pair", code: " abcd-efgh ", device_id: "nas-1", model: "DS224+ J4125", version: "1.0.0" },
    null,
    ok.deps,
  );
  assertEquals(r.status, 200);
  assertEquals(r.body.key, KEY);
  assertEquals(ok.calls[0], ["doc_reader_pair", {
    p_code: "abcd-efgh",
    p_device_id: "nas-1",
    p_label: null,
    p_model: "DS224+ J4125",
    p_app_version: "1.0.0",
  }]);

  const wrong = fake({ doc_reader_pair: { error: "READER_PAIR_CODE", hint: "wrong" } });
  assertEquals((await handleDocReader({ action: "pair", code: "x", device_id: "d" }, null, wrong.deps)).status, 400);
  const busy = fake({ doc_reader_pair: { error: "READER_PAIR_BUSY" } });
  assertEquals((await handleDocReader({ action: "pair", code: "x", device_id: "d" }, null, busy.deps)).status, 429);
  assertEquals((await handleDocReader({ action: "pair", code: "x" }, null, ok.deps)).status, 400, "no device id");
});

Deno.test("every other call needs the key", async () => {
  const f = fake();
  for (const action of ["heartbeat", "claim", "report"]) {
    assertEquals((await handleDocReader({ action }, null, f.deps)).status, 401);
    assertEquals((await handleDocReader({ action }, "short", f.deps)).status, 401);
  }
  assertEquals(f.calls.length, 0);
  assertEquals((await handleDocReader({ action: "delete_all" }, KEY, f.deps)).status, 400);
});

Deno.test("a removed reader is told to connect again; other errors are thrown", async () => {
  const gone = fake({}, new Error("READER_KEY_INVALID"));
  const r = await handleDocReader({ action: "heartbeat" }, KEY, gone.deps);
  assertEquals(r.status, 401);
  assertEquals(r.body.error, "READER_KEY_INVALID");
  const broken = fake({}, new Error("connection reset"));
  await assertRejects(() => handleDocReader({ action: "heartbeat" }, KEY, broken.deps));
});

Deno.test("claim gives each job a short-lived link to its photo", async () => {
  const f = fake({
    doc_reader_claim: [
      { id: "j1", doc_table: "vehicle_documents", side: "front", doc_name: "Cover note", wants: ["numbers", "plates"],
        file_url: `${STORE}/vehicle-documents/v1/cover/front-1.jpg` },
      { id: "j2", doc_table: "provider_documents", side: "back", doc_name: "Licence", wants: ["numbers"],
        file_url: `${STORE}/ID_Image/p1/ic.jpg` },
    ],
  });
  const r = await handleDocReader({ action: "claim", limit: 99 }, KEY, f.deps);
  assertEquals(f.calls[0], ["doc_reader_claim", { p_key: KEY, p_limit: 10 }]);
  const jobs = r.body.jobs as Array<Record<string, unknown>>;
  assertEquals(jobs.map((j) => j.url), ["https://signed/vehicle-documents/v1/cover/front-1.jpg", null]);
  assertEquals(f.signed, [`vehicle-documents/v1/cover/front-1.jpg@${PHOTO_LINK_SECONDS}`]);
  assertEquals(jobs[0].wants, ["numbers", "plates"]);
  assertEquals("file_url" in jobs[0], false, "the stored address isn't handed out");
  assertEquals(r.body.pollAfter, 2, "busy: ask again soon");

  const idle = fake({ doc_reader_claim: [] });
  assertEquals((await handleDocReader({ action: "claim" }, KEY, idle.deps)).body.pollAfter, 15);
});

Deno.test("report passes what was read, cleaned", async () => {
  const f = fake({ doc_reader_report: "passed_on" });
  const r = await handleDocReader(
    { action: "report", id: "j1", ok: true, result: { numbers: ["D123"] }, confidence: 72.5, ms: 1234.6 },
    KEY,
    f.deps,
  );
  assertEquals(r.body.status, "passed_on");
  assertEquals(f.calls[0], ["doc_reader_report", {
    p_key: KEY,
    p_id: "j1",
    p_ok: true,
    p_result: { numbers: ["D123"] },
    p_confidence: 72.5,
    p_ms: 1235,
    p_error: null,
  }]);
  const bad = await handleDocReader({ action: "report", id: "j1", ok: true, result: ["x"] }, KEY, f.deps);
  assertEquals(f.calls[1][1].p_result, null, "a result must be an object");
  assertEquals(bad.status, 200);
  assertEquals((await handleDocReader({ action: "report", ok: true }, KEY, f.deps)).status, 400, "no job id");
});
