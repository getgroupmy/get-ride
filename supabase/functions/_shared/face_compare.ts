/**
 * face-compare (migration 0281): how alike the face in someone's selfie is
 * to the face on their ID photo, as a score for the admin who reviews them.
 * Never a decision: the admin approves or rejects.
 *
 * The service is AWS Rekognition CompareFaces, with the key from Admin → API
 * Keys (provider "aws", service "rekognition", the first active key, kept as
 * "ACCESS_KEY_ID:SECRET_ACCESS_KEY" or "...:region"). Without one the answer
 * is "not_checked". The photos are read from storage with the service role,
 * sent to the service and dropped: nothing is kept but the score.
 *
 * The pure half, tested with stand-ins; face-compare/index.ts does the I/O.
 *
 *     deno test supabase/functions/_shared/face_compare_test.ts
 */

import { type AwsKey, parseAwsKey } from "./aws_sigv4.ts";

export const DOCUMENT_PAGES = ["admin-documents", "admin-documents-users", "admin-documents-partners"];
export const AWS_PROVIDER = "aws";
export const REKOGNITION_SERVICE = "rekognition";
/** Rekognition's own limit for an image sent as bytes. */
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

export type FaceState = "match" | "no_match" | "no_face" | "not_checked" | "error";

export interface CheckRow {
  id: string;
  user_id: string;
  kind: "selfie" | "id";
  file_url: string;
}

/** Where a stored file is: bucket and path, from its storage URL. */
export function storageObject(url: string | null | undefined): { bucket: string; path: string } | null {
  const m = /\/storage\/v1\/object\/(?:public|sign|authenticated)\/([^/]+)\/([^?#]+)/.exec(url ?? "");
  if (!m) return null;
  const path = decodeURIComponent(m[2]);
  if (path.includes("..")) return null;
  return { bucket: decodeURIComponent(m[1]), path };
}

interface KeyEntry {
  value?: unknown;
  disabled?: unknown;
}

/** The first usable Rekognition key in Admin → API Keys, or null. */
export function rekognitionKey(apiProviders: unknown): AwsKey | null {
  const list = Array.isArray(apiProviders) ? apiProviders : (apiProviders as { providers?: unknown })?.providers;
  if (!Array.isArray(list)) return null;
  const p = list.find((x) => x?.id === AWS_PROVIDER);
  const s = (p?.services ?? []).find((x: { id?: string }) => x?.id === REKOGNITION_SERVICE);
  for (const k of (Array.isArray(s?.keys) ? s.keys as KeyEntry[] : [])) {
    if (k?.disabled === true || typeof k?.value !== "string") continue;
    const key = parseAwsKey(k.value);
    if (key) return key;
  }
  return null;
}

/** CompareFaces' answer → the score (0–100) and a word for it. */
export function readCompare(status: number, body: unknown): { state: FaceState; score: number | null; detail?: string } {
  const b = (body ?? {}) as Record<string, unknown>;
  if (status >= 400) {
    const type = String(b.__type ?? b.code ?? "");
    // No face found in one of the photos.
    if (/InvalidParameterException/.test(type)) return { state: "no_face", score: null };
    return { state: "error", score: null, detail: `${type || "HTTP " + status}`.slice(0, 120) };
  }
  const matches = Array.isArray(b.FaceMatches) ? b.FaceMatches as Array<{ Similarity?: unknown }> : [];
  const best = Math.max(0, ...matches.map((m) => Number(m?.Similarity) || 0));
  if (matches.length > 0) return { state: best >= 80 ? "match" : "no_match", score: round(best) };
  const unmatched = Array.isArray(b.UnmatchedFaces) ? b.UnmatchedFaces.length : 0;
  return unmatched > 0 ? { state: "no_match", score: 0 } : { state: "no_face", score: null };
}

const round = (n: number) => Math.round(n * 100) / 100;

/** Base64 of [bytes], in chunks (a 5 MB photo is too big for one call). */
export function base64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(s);
}

export interface FaceCompareDeps {
  /** Whether the caller's token is an admin who edits a Documents page; null when not signed in. */
  canReview(authorization: string | null): Promise<boolean | null>;
  check(id: string): Promise<CheckRow | null>;
  /** The selfie / ID front to compare [row] with: the newest of the other kind. */
  counterpart(row: CheckRow): Promise<CheckRow | null>;
  apiProviders(): Promise<unknown>;
  download(bucket: string, path: string): Promise<Uint8Array | null>;
  compare(key: AwsKey, source: Uint8Array, target: Uint8Array): Promise<{ status: number; body: unknown }>;
  save(id: string, state: FaceState, score: number | null): Promise<void>;
}

export interface Result {
  status: number;
  body: Record<string, unknown>;
}

export async function handleFaceCompare(input: unknown, authorization: string | null, deps: FaceCompareDeps): Promise<Result> {
  const id = (input as { check_id?: unknown } | null)?.check_id;
  if (typeof id !== "string" || !/^[0-9a-f-]{36}$/i.test(id)) return { status: 400, body: { error: "bad_request" } };
  let allowed: boolean | null;
  try {
    allowed = await deps.canReview(authorization);
  } catch {
    return { status: 503, body: { error: "unavailable" } };
  }
  if (allowed === null) return { status: 401, body: { error: "not_signed_in" } };
  if (!allowed) return { status: 403, body: { error: "not_authorized" } };
  try {
    const row = await deps.check(id);
    if (!row) return { status: 404, body: { error: "not_found" } };
    const other = await deps.counterpart(row);
    if (!other) return { status: 200, body: { state: "not_checked", reason: "no_pair" } };
    const key = rekognitionKey(await deps.apiProviders());
    if (!key) {
      await deps.save(row.id, "not_checked", null);
      return { status: 200, body: { state: "not_checked", reason: "no_key" } };
    }
    const selfie = row.kind === "selfie" ? row : other;
    const card = row.kind === "id" ? row : other;
    const a = storageObject(selfie.file_url), b = storageObject(card.file_url);
    const [src, dst] = await Promise.all([
      a ? deps.download(a.bucket, a.path) : null,
      b ? deps.download(b.bucket, b.path) : null,
    ]);
    if (!src || !dst) return { status: 200, body: { state: "not_checked", reason: "no_photo" } };
    if (src.length > MAX_IMAGE_BYTES || dst.length > MAX_IMAGE_BYTES) {
      return { status: 200, body: { state: "not_checked", reason: "too_big" } };
    }
    const answer = await deps.compare(key, src, dst);
    const r = readCompare(answer.status, answer.body);
    await deps.save(row.id, r.state, r.score);
    if (other.id !== row.id) await deps.save(other.id, r.state, r.score);
    return { status: 200, body: { state: r.state, score: r.score, ...(r.detail ? { detail: r.detail } : {}) } };
  } catch {
    return { status: 503, body: { error: "unavailable" } };
  }
}
