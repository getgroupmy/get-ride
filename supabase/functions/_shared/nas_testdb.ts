/**
 * The office NAS's test database (migration 0321): the pure half of the
 * `nas-testdb` function, which the runner on the NAS (deploy/nas-testdb)
 * calls. The runner only ever calls out, with the key it got for its
 * pairing code:
 *
 *   pair       { code, device_id, label?, model?, version? }  -> { key, runner, label }
 *   heartbeat  { model?, version?, state? }                   -> { settings, waiting, pollAfter }
 *   claim      {}                                             -> { run: {...} | null, pollAfter }
 *   report     { id?, kind, ok, error?, ms?, detail?, head_sha?, files? } -> { run }
 *
 * Every call but pair sends the key in the x-runner-key header. Nothing here
 * touches the network; see nas_testdb_test.ts.
 */

/** How often an idle runner asks for work, and one that just finished a run. */
export const POLL_IDLE_SECONDS = 60;
export const POLL_BUSY_SECONDS = 5;

export interface TestDbDeps {
  /** A database function, called with the service role. Throws its error. */
  rpc(name: string, args: Record<string, unknown>): Promise<unknown>;
}

export interface Reply {
  status: number;
  body: Record<string, unknown>;
}

const str = (v: unknown, max = 200): string | null =>
  typeof v === "string" && v.trim() !== "" ? v.trim().slice(0, max) : null;

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

const obj = (v: unknown): Record<string, unknown> | null =>
  v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : null;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The files a run tried: migration paths only, at most 50. */
export function runFiles(v: unknown): string[] | null {
  if (!Array.isArray(v)) return null;
  return v
    .filter((f): f is string => typeof f === "string" && /^supabase\/migrations\/[A-Za-z0-9._-]+\.sql$/.test(f))
    .slice(0, 50);
}

/** A database error's code word (TESTDB_KEY_INVALID …), when it is one of ours. */
function errorWord(e: unknown): string | null {
  const m = (e as { message?: unknown } | null)?.message;
  return typeof m === "string" && /^TESTDB_[A-Z_]+$/.test(m) ? m : null;
}

export async function handleTestDb(input: unknown, key: string | null, deps: TestDbDeps): Promise<Reply> {
  const body = obj(input) ?? {};
  const action = body.action;

  if (action === "pair") {
    const code = str(body.code, 20);
    const device = str(body.device_id);
    if (!code || !device) return { status: 400, body: { error: "bad_request", hint: "Send the code and a device id." } };
    const r = obj(
      await deps.rpc("testdb_pair", {
        p_code: code,
        p_device_id: device,
        p_label: str(body.label, 80),
        p_model: str(body.model, 120),
        p_app_version: str(body.version, 40),
      }),
    );
    if (!r || typeof r.error === "string") {
      return { status: r?.error === "TESTDB_PAIR_BUSY" ? 429 : 400, body: r ?? { error: "TESTDB_PAIR_CODE" } };
    }
    return { status: 200, body: r };
  }

  if (action !== "heartbeat" && action !== "claim" && action !== "report") {
    return { status: 400, body: { error: "bad_request", hint: "Unknown action." } };
  }
  if (!key || key.length < 32) {
    return { status: 401, body: { error: "TESTDB_KEY_INVALID", hint: "Send the runner key in x-runner-key." } };
  }

  try {
    if (action === "heartbeat") {
      const state = obj(body.state);
      const r = obj(
        await deps.rpc("testdb_heartbeat", {
          p_key: key,
          p_model: str(body.model, 120),
          p_app_version: str(body.version, 40),
          p_state: state && JSON.stringify(state).length <= 4000 ? state : null,
        }),
      ) ?? {};
      return { status: 200, body: { ...r, pollAfter: POLL_IDLE_SECONDS } };
    }

    if (action === "claim") {
      const run = obj(await deps.rpc("testdb_claim", { p_key: key }));
      return { status: 200, body: { run, pollAfter: run ? POLL_BUSY_SECONDS : POLL_IDLE_SECONDS } };
    }

    // report
    const kind = body.kind;
    const id = str(body.id, 40);
    if ((kind !== "refresh" && kind !== "migration") || typeof body.ok !== "boolean" || (id !== null && !UUID.test(id))) {
      return { status: 400, body: { error: "bad_request", hint: "Send kind, ok and the run id." } };
    }
    if (kind === "migration" && id === null) {
      return { status: 400, body: { error: "bad_request", hint: "A migration result needs its run id." } };
    }
    const detail = obj(body.detail);
    const ms = num(body.ms);
    const run = await deps.rpc("testdb_report", {
      p_key: key,
      p_id: id,
      p_kind: kind,
      p_ok: body.ok,
      p_error: str(body.error, 4000),
      p_ms: ms === null ? null : Math.max(0, Math.round(ms)),
      p_detail: detail && JSON.stringify(detail).length <= 20000 ? detail : null,
      p_head_sha: (str(body.head_sha, 64) ?? "").match(/^[0-9a-f]{7,64}$/i) ? str(body.head_sha, 64) : null,
      p_files: runFiles(body.files),
    });
    return { status: 200, body: { run } };
  } catch (e) {
    const word = errorWord(e);
    if (word === "TESTDB_KEY_INVALID") {
      return { status: 401, body: { error: word, hint: "Connect the runner again from Admin -> Settings -> Office NAS." } };
    }
    if (word) return { status: 400, body: { error: word } };
    throw e;
  }
}
