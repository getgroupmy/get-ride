/**
 * Document reading (migration 0293): the pure half of the `doc-reader`
 * function, which the office NAS (or a GPU reading PC) calls. The reader
 * only ever calls out, with the key it got for its pairing code:
 *
 *   pair       { code, device_id, label?, model?, version? }  -> { key, reader, kind, label }
 *   heartbeat  { model?, version? }                           -> { on, jobs, idCards, passOnBelow, pollAfter }
 *   claim      { limit? }                                     -> { jobs: [{ id, side, doc_name, wants, url }] }
 *   report     { id, ok, result?, confidence?, ms?, error? }  -> { status }
 *
 * Every call but pair sends the key in the x-reader-key header. A job's photo
 * comes as a signed link good for 5 minutes, from the document buckets only.
 * Nothing here touches the network; see doc_reader_test.ts.
 *
 * 0320: the NAS also reads the MyKad or passport sent for a sign-in check
 * (doc_table identity_checks, wants ["id_card"]): its photo comes from the
 * ID bucket, and the reader sends back { id: { name, ic, passport, birth,
 * nationality, expiry } } and nothing else.
 */
import { storageObject } from "./face_compare.ts";

/** The buckets a reader may be given a photo from. */
export const READER_BUCKETS = ["provider-documents", "vehicle-documents"] as const;

/** How long a job's photo link stays good. */
export const PHOTO_LINK_SECONDS = 300;

/** How often an idle reader asks for work, and a busy one. */
export const POLL_IDLE_SECONDS = 15;
export const POLL_BUSY_SECONDS = 2;

export type ReaderAction = "pair" | "heartbeat" | "claim" | "report";

export interface JobRow {
  id: string;
  doc_table: string;
  side: string;
  file_url: string;
  doc_name: string | null;
  wants: string[];
}

export interface DocReaderDeps {
  /** A database function, called with the service role. Throws its error. */
  rpc(name: string, args: Record<string, unknown>): Promise<unknown>;
  /** A signed link to a stored file, or null when it can't be made. */
  sign(bucket: string, path: string, seconds: number): Promise<string | null>;
}

export interface Reply {
  status: number;
  body: Record<string, unknown>;
}

const str = (v: unknown, max = 200): string | null =>
  typeof v === "string" && v.trim() !== "" ? v.trim().slice(0, max) : null;

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

/** The bucket of the IDs sent for the sign-in checks: an ID job's only (0320). */
export const ID_BUCKET = "ID_Image";

/**
 * The photo's bucket and path, when it is in a document bucket; for an ID
 * job (doc_table identity_checks, 0320) in the ID bucket only.
 */
export function readerPhoto(url: string | null | undefined, docTable?: string): { bucket: string; path: string } | null {
  const o = storageObject(url);
  if (!o) return null;
  if (docTable === "identity_checks") return o.bucket === ID_BUCKET ? o : null;
  return (READER_BUCKETS as readonly string[]).includes(o.bucket) ? o : null;
}

/** A database error's code word (READER_KEY_INVALID …), when it is one of ours. */
function errorWord(e: unknown): string | null {
  const m = (e as { message?: unknown } | null)?.message;
  return typeof m === "string" && /^READER_[A-Z_]+$/.test(m) ? m : null;
}

export async function handleDocReader(input: unknown, key: string | null, deps: DocReaderDeps): Promise<Reply> {
  const body = (input && typeof input === "object" ? input : {}) as Record<string, unknown>;
  const action = body.action as ReaderAction;

  if (action === "pair") {
    const code = str(body.code, 20);
    const device = str(body.device_id);
    if (!code || !device) return { status: 400, body: { error: "bad_request", hint: "Send the code and a device id." } };
    const r = (await deps.rpc("doc_reader_pair", {
      p_code: code,
      p_device_id: device,
      p_label: str(body.label, 80),
      p_model: str(body.model, 120),
      p_app_version: str(body.version, 40),
    })) as Record<string, unknown> | null;
    if (!r || typeof r.error === "string") {
      return { status: r?.error === "READER_PAIR_BUSY" ? 429 : 400, body: r ?? { error: "READER_PAIR_CODE" } };
    }
    return { status: 200, body: r };
  }

  if (!["heartbeat", "claim", "report"].includes(action)) {
    return { status: 400, body: { error: "bad_request", hint: "Unknown action." } };
  }
  if (!key || key.length < 32) {
    return { status: 401, body: { error: "READER_KEY_INVALID", hint: "Send the reader key in x-reader-key." } };
  }

  try {
    if (action === "heartbeat") {
      const r = (await deps.rpc("doc_reader_heartbeat", {
        p_key: key,
        p_model: str(body.model, 120),
        p_app_version: str(body.version, 40),
      })) as Record<string, unknown>;
      return { status: 200, body: { ...r, pollAfter: POLL_IDLE_SECONDS } };
    }

    if (action === "claim") {
      const limit = Math.max(1, Math.min(10, Math.floor(num(body.limit) ?? 1)));
      const rows = ((await deps.rpc("doc_reader_claim", { p_key: key, p_limit: limit })) ?? []) as JobRow[];
      const jobs = [];
      for (const j of rows) {
        const photo = readerPhoto(j.file_url, j.doc_table);
        const url = photo ? await deps.sign(photo.bucket, photo.path, PHOTO_LINK_SECONDS) : null;
        jobs.push({ id: j.id, doc_table: j.doc_table, side: j.side, doc_name: j.doc_name, wants: j.wants, url });
      }
      return { status: 200, body: { jobs, pollAfter: jobs.length ? POLL_BUSY_SECONDS : POLL_IDLE_SECONDS } };
    }

    // report
    const id = str(body.id, 40);
    if (!id || typeof body.ok !== "boolean") {
      return { status: 400, body: { error: "bad_request", hint: "Send the job id and ok." } };
    }
    const result = body.result && typeof body.result === "object" && !Array.isArray(body.result) ? body.result : null;
    const status = await deps.rpc("doc_reader_report", {
      p_key: key,
      p_id: id,
      p_ok: body.ok,
      p_result: result,
      p_confidence: num(body.confidence),
      p_ms: num(body.ms) === null ? null : Math.round(num(body.ms)!),
      p_error: str(body.error, 500),
    });
    return { status: 200, body: { status } };
  } catch (e) {
    const word = errorWord(e);
    if (word === "READER_KEY_INVALID") {
      return { status: 401, body: { error: word, hint: "Connect the reader again from Admin -> Settings -> Document reading." } };
    }
    throw e;
  }
}
