/**
 * Office NAS backups and uptime (migration 0318): the pure half of the
 * `nas-ops` function, which the NAS app (deploy/nas-backup) calls. The app
 * only ever calls out, with the key it got for its pairing code:
 *
 *   pair           { code, device_id, label?, model?, version? }  -> { key, agent, label }
 *   heartbeat      { model?, version?, services? }                -> { backup, uptime, targets, requests, pollAfter }
 *   backup_start   { kind, trigger?, request? }                   -> { run }
 *   backup_finish  { run, ok, db_bytes?, files?, files_bytes?, total_bytes?, error?, detail? } -> { status }
 *   uptime_report  { results: [{ id, status, ms?, detail? }] }    -> { kept }
 *
 * Every call but pair sends the key in the x-nas-key header. The database's
 * connection string and the storage key stay on the NAS: nothing here asks
 * for them. {project} in a target's address is filled in with this backend's
 * address. Nothing here touches the network; see nas_ops_test.ts.
 */

export type NasAction = "pair" | "heartbeat" | "backup_start" | "backup_finish" | "uptime_report";

export interface NasOpsDeps {
  /** A database function, called with the service role. Throws its error. */
  rpc(name: string, args: Record<string, unknown>): Promise<unknown>;
  /** This backend's address (SUPABASE_URL), for {project} in a target. */
  projectUrl: string;
}

export interface Reply {
  status: number;
  body: Record<string, unknown>;
}

/** How often the app checks in. */
export const HEARTBEAT_SECONDS = 60;

const str = (v: unknown, max = 200): string | null =>
  typeof v === "string" && v.trim() !== "" ? v.trim().slice(0, max) : null;

const int = (v: unknown): number | null =>
  typeof v === "number" && Number.isFinite(v) && v >= 0 ? Math.round(v) : null;

const obj = (v: unknown): Record<string, unknown> | null =>
  v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : null;

/** A database error's code word (NAS_KEY_INVALID …), when it is one of ours. */
function errorWord(e: unknown): string | null {
  const m = (e as { message?: unknown } | null)?.message;
  return typeof m === "string" && /^NAS_[A-Z_]+$/.test(m) ? m : null;
}

/** {project} in a target's address, as this backend's address. */
export function fillProject(url: string | null | undefined, projectUrl: string): string | null {
  if (!url) return null;
  return url.replaceAll("{project}", projectUrl.replace(/\/+$/, ""));
}

/** At most 50 well-formed results; everything else is dropped. */
export function cleanResults(v: unknown): Array<{ id: string; status: string; ms: number | null; detail: string | null }> {
  if (!Array.isArray(v)) return [];
  const out = [];
  for (const r of v.slice(0, 50)) {
    const o = obj(r);
    const id = str(o?.id, 60);
    const status = o?.status;
    if (!id || (status !== "up" && status !== "slow" && status !== "down")) continue;
    out.push({ id, status, ms: int(o?.ms), detail: str(o?.detail, 300) });
  }
  return out;
}

export async function handleNasOps(input: unknown, key: string | null, deps: NasOpsDeps): Promise<Reply> {
  const body = obj(input) ?? {};
  const action = body.action as NasAction;

  if (action === "pair") {
    const code = str(body.code, 20);
    const device = str(body.device_id);
    if (!code || !device) return { status: 400, body: { error: "bad_request", hint: "Send the code and a device id." } };
    const r = (await deps.rpc("nas_ops_pair", {
      p_code: code,
      p_device_id: device,
      p_label: str(body.label, 80),
      p_model: str(body.model, 120),
      p_app_version: str(body.version, 40),
    })) as Record<string, unknown> | null;
    if (!r || typeof r.error === "string") {
      return { status: r?.error === "NAS_PAIR_BUSY" ? 429 : 400, body: r ?? { error: "NAS_PAIR_CODE" } };
    }
    return { status: 200, body: r };
  }

  if (!["heartbeat", "backup_start", "backup_finish", "uptime_report"].includes(action)) {
    return { status: 400, body: { error: "bad_request", hint: "Unknown action." } };
  }
  if (!key || key.length < 32) {
    return { status: 401, body: { error: "NAS_KEY_INVALID", hint: "Send the NAS key in x-nas-key." } };
  }

  try {
    if (action === "heartbeat") {
      const services = obj(body.services);
      const r = obj(await deps.rpc("nas_ops_heartbeat", {
        p_key: key,
        p_model: str(body.model, 120),
        p_app_version: str(body.version, 40),
        p_services: services,
      })) ?? {};
      const targets = Array.isArray(r.targets) ? r.targets : [];
      return {
        status: 200,
        body: {
          ...r,
          targets: targets.map((t) => ({ ...t, url: fillProject((t as { url?: string }).url, deps.projectUrl) })),
          pollAfter: HEARTBEAT_SECONDS,
        },
      };
    }

    if (action === "backup_start") {
      const kind = body.kind === "restore_test" ? "restore_test" : body.kind === "backup" ? "backup" : null;
      if (!kind) return { status: 400, body: { error: "bad_request", hint: "kind is backup or restore_test." } };
      const run = await deps.rpc("nas_backup_started", {
        p_key: key,
        p_kind: kind,
        p_trigger: body.trigger === "manual" ? "manual" : "schedule",
        p_request: str(body.request, 40),
      });
      return { status: 200, body: { run } };
    }

    if (action === "backup_finish") {
      const run = str(body.run, 40);
      if (!run || typeof body.ok !== "boolean") {
        return { status: 400, body: { error: "bad_request", hint: "Send the run and ok." } };
      }
      const detail = obj(body.detail);
      const status = await deps.rpc("nas_backup_finished", {
        p_key: key,
        p_run: run,
        p_ok: body.ok,
        p_db_bytes: int(body.db_bytes),
        p_files: int(body.files),
        p_files_bytes: int(body.files_bytes),
        p_total_bytes: int(body.total_bytes),
        p_error: str(body.error, 500),
        p_detail: detail && JSON.stringify(detail).length <= 20000 ? detail : null,
      });
      return { status: 200, body: { status } };
    }

    // uptime_report
    const kept = await deps.rpc("nas_uptime_report", { p_key: key, p_results: cleanResults(body.results) });
    return { status: 200, body: { kept } };
  } catch (e) {
    const word = errorWord(e);
    if (word === "NAS_KEY_INVALID") {
      return { status: 401, body: { error: word, hint: "Connect the NAS again from Admin -> Settings -> Office NAS." } };
    }
    if (word) return { status: 400, body: { error: word } };
    throw e;
  }
}
