/**
 * GET.ocr (get.ocr on ocr.getcdn.link): our own OCR server reads a document's
 * photo and answers with its text. It is a selectable reader in the document
 * reading chain (DocReaderId.getOcr, migration 0443). The id-read function
 * calls it for a registration document when that reader is next:
 *   POST { file_url, purpose: "registration", reader: "getOcr" }.
 *
 * The server key is Admin → API Keys → GET.ocr (provider "ocr", service
 * "server"), saved as the https address, a colon, then the API key:
 * "https://ocr.getcdn.link:ocr_…" (the face / eKYC server shape).
 *
 * get.ocr is the org's own server, so there is no extra admin gate — the
 * reader's on/off switch in the chain is the gate, and the app only calls here
 * when getOcr is switched on and next in the order. The owner check and the
 * daily cap are the Vision registration read's (id_read.ts); only the key and
 * the call differ.
 *
 *     deno test supabase/functions/_shared/doc_ocr_test.ts
 */
import { base64, type FaceServer, parseFaceServer } from "./face_server.ts";
import { storageObject } from "./face_compare.ts";
import { MAX_IMAGE_BYTES, REGISTRATION_READS_PER_DAY, type Result } from "./id_read.ts";

export const OCR_PROVIDER = "ocr";
export const OCR_SERVICE = "server";
export const OCR_READER = "getOcr";
/** How long id-read waits for get.ocr before giving up (a short PDF or image). */
export const OCR_TIMEOUT_MS = 20000;

interface KeyEntry {
  value?: unknown;
  disabled?: unknown;
}

/** The get.ocr server from the first usable key: its https address and API key. */
export function ocrServer(apiProviders: unknown): FaceServer | null {
  const list = Array.isArray(apiProviders) ? apiProviders : (apiProviders as { providers?: unknown })?.providers;
  if (!Array.isArray(list)) return null;
  const p = list.find((x) => x?.id === OCR_PROVIDER);
  const s = (p?.services ?? []).find((x: { id?: string }) => x?.id === OCR_SERVICE);
  for (const k of (Array.isArray(s?.keys) ? s.keys as KeyEntry[] : [])) {
    if (k?.disabled === true || typeof k?.value !== "string") continue;
    const server = parseFaceServer(k.value);
    if (server) return server;
  }
  return null;
}

/**
 * POST /v1/ocr with the image as a base64 JSON body and detail "text" (plain
 * text, no per-line boxes — the app's field readers only need the text). The
 * key goes in X-API-Key, the header get.ocr reads on every /v1 call.
 */
export function ocrRequest(server: FaceServer, image: Uint8Array) {
  return {
    url: `${server.url}/v1/ocr`,
    method: "POST" as const,
    headers: { "Content-Type": "application/json", "X-API-Key": server.secret },
    body: JSON.stringify({ file: base64(image), detail: "text" }),
  };
}

/** get.ocr's answer: the text it read, or what went wrong in a few words. */
export function readOcr(status: number, body: unknown): { text: string } | { error: string } {
  const b = (body ?? {}) as Record<string, unknown>;
  if (status < 200 || status >= 300) {
    // get.ocr answers an error as { error, message } (app/errors.py).
    const why = typeof b.message === "string" ? b.message : typeof b.error === "string" ? b.error : `HTTP ${status}`;
    return { error: `GET.ocr: ${String(why).slice(0, 160)}` };
  }
  return { text: typeof b.text === "string" ? b.text : "" };
}

/** Whether a registration read asked for the get.ocr reader. */
export function isOcrReader(input: unknown): boolean {
  return (input as { reader?: unknown } | null)?.reader === OCR_READER;
}

/**
 * The document-reading readers that can read a stored image on the server, in
 * the admin's configured order, switched on only: "getOcr" (get.ocr) and
 * "cloud" (Google Vision). The phone, NAS and GPU readers do not read a stored
 * image here. An absent or unreadable config falls back to get.ocr first, then
 * Vision, so get.ocr is the primary reader by default (migration 0444).
 */
export function serverReaders(documentReading: unknown): ("getOcr" | "cloud")[] {
  const readers = (documentReading as { readers?: unknown } | null)?.readers;
  if (!Array.isArray(readers)) return ["getOcr", "cloud"];
  const out: ("getOcr" | "cloud")[] = [];
  for (const r of readers) {
    const id = (r as { id?: unknown })?.id;
    if ((id === "getOcr" || id === "cloud") && (r as { on?: unknown })?.on === true) {
      out.push(id);
    }
  }
  return out;
}

export interface OcrReadDeps {
  /** The signed-in user's id; null when the token is missing or not accepted. */
  caller(authorization: string | null): Promise<string | null>;
  /** registration_file_owned(uid, bucket, path): the file is the caller's own. */
  owns(uid: string, bucket: string, path: string): Promise<boolean>;
  /** registration_text_read_spend(uid, limit): false once the day's reads are spent. */
  spend(uid: string, limit: number): Promise<boolean>;
  apiProviders(): Promise<unknown>;
  download(bucket: string, path: string): Promise<Uint8Array | null>;
  /** POST the image to get.ocr's /v1/ocr. */
  ocr(server: FaceServer, image: Uint8Array): Promise<{ status: number; body: unknown }>;
}

/**
 * The person's own registration document read by get.ocr. Mirrors the Vision
 * registration read (handleRegistrationRead): same owner check and daily cap,
 * the get.ocr key in place of the Vision key, and no visionOn gate — the chain
 * switch the app follows is the gate.
 *
 * Response: 200 { state: "read" | "not_read" | "error", text?, reason?, detail? }
 *           400 bad_request · 401 not_signed_in · 403 not_authorized
 *           429 too_many · 503 unavailable
 */
export async function handleOcrRead(input: unknown, authorization: string | null, deps: OcrReadDeps): Promise<Result> {
  const url = (input as { file_url?: unknown } | null)?.file_url;
  const where = typeof url === "string" && url.length <= 1000 ? storageObject(url) : null;
  if (!where) return { status: 400, body: { error: "bad_request" } };
  try {
    const uid = await deps.caller(authorization);
    if (!uid) return { status: 401, body: { error: "not_signed_in" } };
    if (!(await deps.owns(uid, where.bucket, where.path))) return { status: 403, body: { error: "not_authorized" } };
    const server = ocrServer(await deps.apiProviders());
    if (!server) return { status: 200, body: { state: "not_read", reason: "no_key" } };
    if (!(await deps.spend(uid, REGISTRATION_READS_PER_DAY))) return { status: 429, body: { error: "too_many" } };
    const image = await deps.download(where.bucket, where.path);
    if (!image) return { status: 200, body: { state: "not_read", reason: "no_photo" } };
    if (image.length > MAX_IMAGE_BYTES) return { status: 200, body: { state: "not_read", reason: "too_big" } };
    const answer = await deps.ocr(server, image);
    const v = readOcr(answer.status, answer.body);
    if ("error" in v) return { status: 200, body: { state: "error", detail: v.error } };
    const text = v.text.trim();
    return {
      status: 200,
      body: text ? { state: "read", text: text.slice(0, 20000) } : { state: "not_read", reason: "nothing_found" },
    };
  } catch {
    return { status: 503, body: { error: "unavailable" } };
  }
}
