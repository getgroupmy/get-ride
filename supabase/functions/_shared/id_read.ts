/**
 * id-read (migration 0283): Google Cloud Vision reads a MyKad's or
 * passport's front, for a sign-in check, when the phone can't (web, desktop,
 * a photo ML Kit can't read) or the admin asks for it always. What was read
 * is kept on the check and checked against the profile again
 * (identity_check_store_read → identity_read_mismatch).
 *
 * Who may ask:
 *   the person, for their own ID waiting for review, once, and only when
 *     the admin's ID card reading setting isn't "On the phone only";
 *   an admin who edits a Documents page, for anyone's ID, any time ("Read
 *     card again" in Sign-in checks).
 *
 * The key is Admin → API Keys → Google → Cloud Vision (ID reading)
 * (provider "google", service "vision"), sent in X-Goog-Api-Key and never
 * returned. The photo is read from storage with the service role, sent and
 * dropped.
 *
 * The card's text is read with the phone's rules (readCard in
 * lib/src/core/signin_checks.dart); both are held to id_card_cases.json
 * (id_read_test.ts, test/id_card_cases_test.dart).
 *
 *     deno test --allow-read=supabase supabase/functions/_shared/id_read_test.ts
 */

import { DOCUMENT_PAGES, storageObject } from "./face_compare.ts";
import { base64 } from "./face_server.ts";

export { DOCUMENT_PAGES };
export const VISION_PROVIDER = "google";
export const VISION_SERVICE = "vision";
export const VISION_URL = "https://vision.googleapis.com/v1/images:annotate";
/** Vision takes up to 10 MB of JSON per request: a photo up to 7 MB as base64. */
export const MAX_IMAGE_BYTES = 7 * 1024 * 1024;

export type IdReadMode = "phone" | "phone_vision" | "vision";
const MODES: IdReadMode[] = ["phone", "phone_vision", "vision"];

/** The admin's choice from app_settings 'dispatch_verify'; the phone only when unset. */
export function idReadMode(dispatchVerify: unknown): IdReadMode {
  const v = (dispatchVerify as { idRead?: unknown } | null)?.idRead;
  return MODES.includes(v as IdReadMode) ? v as IdReadMode : "phone";
}

// ---- Reading the text (the phone's rules) -------------------------------------------------------

export interface CardRead {
  name: string | null;
  /** As printed: 880202-10-1234. */
  ic: string | null;
  /** A passport's number, from its machine lines. */
  passport: string | null;
  /** yyyy-mm-dd. */
  expiry: string | null;
}

const NOT_NAMES = new Set([
  "KAD", "PENGENALAN", "MALAYSIA", "MYKAD", "IDENTITY", "CARD", "WARGANEGARA", "LELAKI", "PEREMPUAN", "ISLAM",
  "PASPORT", "PASSPORT", "JALAN", "TAMAN", "LORONG", "KAMPUNG", "NO", "KUALA", "LUMPUR", "SELANGOR", "JOHOR",
  "PULAU", "PINANG", "PERAK", "KEDAH", "KELANTAN", "TERENGGANU", "PAHANG", "MELAKA", "SABAH", "SARAWAK",
  "NEGERI", "SEMBILAN", "PERLIS", "LABUAN", "PUTRAJAYA", "BANDAR", "MYS", "TYPE", "JENIS",
]);

const IC = /\b(\d{6})\s*-?\s*(\d{2})\s*-?\s*(\d{4})\b/;

/**
 * A MyKad's IC number as printed (YYMMDD-PB-###G) and the name under it; a
 * passport's name, number, expiry and (a Malaysian one's) IC from its
 * machine lines. Nulls for what can't be read.
 */
export function readCardText(text: string): CardRead {
  const lines = text.split(/[\r\n]+/).map((l) => l.trim()).filter((l) => l.length > 0);
  const mrz = readMrz(lines);
  if (mrz) return mrz;
  let ic: string | null = null;
  let icLine = -1;
  for (let i = 0; i < lines.length && ic === null; i++) {
    const m = IC.exec(lines[i]);
    if (m) {
      ic = `${m[1]}-${m[2]}-${m[3]}`;
      icLine = i;
    }
  }
  let name: string | null = null;
  for (let i = icLine + 1; i < lines.length && name === null; i++) {
    const l = lines[i];
    if (!/^[A-Z][A-Z '@./-]+$/.test(l)) continue;
    const words = l.split(/\s+/);
    if (words.length < 2 || words.some((w) => NOT_NAMES.has(w.replace(/[^A-Z]/g, "")))) continue;
    name = l.replace(/\s+/g, " ");
  }
  return { name, ic, passport: null, expiry: null };
}

/** The two machine lines of a passport (ICAO 9303, 44 characters each). */
function readMrz(lines: string[]): CardRead | null {
  const clean = lines.map((l) => l.replaceAll(" ", "").toUpperCase());
  for (let i = 0; i + 1 < clean.length; i++) {
    const a = clean[i], b = clean[i + 1];
    if (!a.startsWith("P") || a.length < 40 || b.length < 40 || !/^[A-Z0-9<]+$/.test(b)) continue;
    const names = a.substring(5).split("<<");
    const surname = names[0].replaceAll("<", " ").trim();
    const given = names.length > 1 ? names[1].replaceAll("<", " ").trim() : "";
    const name = [given, surname].filter((s) => s.length > 0).join(" ");
    const expiry = mrzDate(b.substring(21, 27));
    const personal = b.length >= 42 ? b.substring(28, 42).replaceAll("<", "") : "";
    const ic = /^\d{12}$/.test(personal)
      ? `${personal.substring(0, 6)}-${personal.substring(6, 8)}-${personal.substring(8)}`
      : null;
    const number = b.substring(0, 9).replaceAll("<", "");
    return {
      name: name.length ? name : null,
      ic,
      passport: /^[A-Z0-9]{5,9}$/.test(number) ? number : null,
      expiry,
    };
  }
  return null;
}

/** An expiry's YYMMDD: this century (a passport lasts ten years at most). */
function mrzDate(yymmdd: string): string | null {
  if (!/^\d{6}$/.test(yymmdd)) return null;
  const yy = Number(yymmdd.substring(0, 2)), mm = Number(yymmdd.substring(2, 4)), dd = Number(yymmdd.substring(4, 6));
  if (mm < 1 || mm > 12 || dd < 1 || dd > 31) return null;
  return new Date(Date.UTC(2000 + yy, mm - 1, dd)).toISOString().slice(0, 10);
}

// ---- Google Cloud Vision -------------------------------------------------------------------------

interface KeyEntry {
  value?: unknown;
  disabled?: unknown;
}

/** The first usable Cloud Vision key in Admin → API Keys, or null. */
export function visionKey(apiProviders: unknown): string | null {
  const list = Array.isArray(apiProviders) ? apiProviders : (apiProviders as { providers?: unknown })?.providers;
  if (!Array.isArray(list)) return null;
  const p = list.find((x) => x?.id === VISION_PROVIDER);
  const s = (p?.services ?? []).find((x: { id?: string }) => x?.id === VISION_SERVICE);
  for (const k of (Array.isArray(s?.keys) ? s.keys as KeyEntry[] : [])) {
    if (k?.disabled === true || typeof k?.value !== "string" || !k.value.trim()) continue;
    return k.value.trim();
  }
  return null;
}

/** One images:annotate TEXT_DETECTION request for [image]. */
export function visionRequest(key: string, image: Uint8Array) {
  return {
    url: VISION_URL,
    method: "POST" as const,
    headers: { "Content-Type": "application/json", "X-Goog-Api-Key": key },
    body: JSON.stringify({ requests: [{ image: { content: base64(image) }, features: [{ type: "TEXT_DETECTION" }] }] }),
  };
}

/** Vision's answer: the text, or what went wrong in a few words. */
export function readVision(status: number, body: unknown): { text: string } | { error: string } {
  // deno-lint-ignore no-explicit-any
  const b = (body ?? {}) as any;
  const err = b.error ?? b.responses?.[0]?.error;
  if (err || status < 200 || status >= 300) {
    const reasons: string[] = [err?.status, ...(Array.isArray(err?.details) ? err.details.map((d: { reason?: string }) => d?.reason) : [])]
      .filter((r): r is string => typeof r === "string");
    if (reasons.includes("SERVICE_DISABLED") || /has not been used|is disabled/i.test(String(err?.message ?? ""))) {
      return { error: "The Cloud Vision API isn't enabled for the key's project" };
    }
    if (reasons.includes("API_KEY_INVALID")) return { error: "Google doesn't know the Vision key" };
    if (reasons.includes("API_KEY_SERVICE_BLOCKED")) return { error: "The key isn't allowed to use Cloud Vision" };
    if (reasons.includes("BILLING_DISABLED")) return { error: "Billing is off for the key's project" };
    return { error: `Google Vision: ${String(err?.message ?? `HTTP ${status}`).slice(0, 160)}` };
  }
  const r = b.responses?.[0] ?? {};
  const text = r.fullTextAnnotation?.text ?? r.textAnnotations?.[0]?.description ?? "";
  return { text: typeof text === "string" ? text : "" };
}

// ---- The handler ---------------------------------------------------------------------------------

export interface IdCheckRow {
  id: string;
  user_id: string;
  kind: "selfie" | "id";
  file_url: string;
  status: string | null;
  read_source: string | null;
}

export interface IdReadDeps {
  /** The signed-in user's id; null when the token is missing or not accepted. */
  caller(authorization: string | null): Promise<string | null>;
  /** Whether the caller edits a Documents page. */
  canReview(authorization: string | null): Promise<boolean | null>;
  check(id: string): Promise<IdCheckRow | null>;
  /** app_settings 'dispatch_verify' (idRead). */
  verifySettings(): Promise<unknown>;
  apiProviders(): Promise<unknown>;
  download(bucket: string, path: string): Promise<Uint8Array | null>;
  annotate(key: string, image: Uint8Array): Promise<{ status: number; body: unknown }>;
  /** identity_check_store_read: { mismatch, ... }. */
  store(id: string, read: CardRead): Promise<Record<string, unknown>>;
}

export interface Result {
  status: number;
  body: Record<string, unknown>;
}

export async function handleIdRead(input: unknown, authorization: string | null, deps: IdReadDeps): Promise<Result> {
  const id = (input as { check_id?: unknown } | null)?.check_id;
  if (typeof id !== "string" || !/^[0-9a-f-]{36}$/i.test(id)) return { status: 400, body: { error: "bad_request" } };
  try {
    const uid = await deps.caller(authorization);
    if (!uid) return { status: 401, body: { error: "not_signed_in" } };
    const row = await deps.check(id);
    const own = row !== null && row.user_id === uid;
    if (!own) {
      // Someone else's check (or none): an admin's only. Nothing said about which.
      if ((await deps.canReview(authorization)) !== true) return { status: 403, body: { error: "not_authorized" } };
      if (!row) return { status: 404, body: { error: "not_found" } };
    }
    if (row!.kind !== "id") return { status: 400, body: { error: "not_an_id" } };
    const [apiProviders, verify] = await Promise.all([deps.apiProviders(), deps.verifySettings()]);
    if (own) {
      if (idReadMode(verify) === "phone") return { status: 403, body: { error: "vision_off" } };
      if (row!.status !== "Pending Review") return { status: 409, body: { error: "not_waiting" } };
      if (row!.read_source === "vision") return { status: 409, body: { error: "already_read" } };
    }
    const key = visionKey(apiProviders);
    if (!key) return { status: 200, body: { state: "not_read", reason: "no_key" } };
    const where = storageObject(row!.file_url);
    const image = where ? await deps.download(where.bucket, where.path) : null;
    if (!image) return { status: 200, body: { state: "not_read", reason: "no_photo" } };
    if (image.length > MAX_IMAGE_BYTES) return { status: 200, body: { state: "not_read", reason: "too_big" } };
    const answer = await deps.annotate(key, image);
    const v = readVision(answer.status, answer.body);
    if ("error" in v) return { status: 200, body: { state: "error", detail: v.error } };
    const read = readCardText(v.text);
    // Kept even when nothing was found, so the person's one read is spent.
    const stored = await deps.store(row!.id, read);
    const found = read.name !== null || read.ic !== null || read.passport !== null || read.expiry !== null;
    return {
      status: 200,
      body: {
        state: found ? "read" : "not_read",
        ...(found ? {} : { reason: "nothing_found" }),
        name: read.name,
        ic: read.ic,
        passport: read.passport,
        expiry: read.expiry,
        mismatch: Array.isArray(stored?.mismatch) ? stored.mismatch : [],
      },
    };
  } catch {
    return { status: 503, body: { error: "unavailable" } };
  }
}

// ---- Partner registration documents (migration 0288) -------------------------------------------
//
// The National ID, the SSM company document, the Kad Pemandu and the vehicle
// grant read for partner registration, when the phone couldn't read them
// (web, desktop, an unreadable photo) and the admin's ID card reading
// setting isn't "On the phone only". Only the person's own file (their
// ID_Image folder, their partner's provider-documents folder, their
// vehicle's vehicle-documents folder), at most REGISTRATION_READS_PER_DAY a
// day. The text comes back as read: the app's readers turn it into fields
// (lib/src/core/document_text.dart). Nothing is kept but the count.
//
// Request:  POST { file_url, purpose: "registration" }
// Response: 200 { state: "read" | "not_read" | "error", text?, reason?, detail? }
//           400 bad_request · 401 not_signed_in · 403 not_authorized · vision_off
//           429 too_many · 503 unavailable

export const REGISTRATION_READS_PER_DAY = 30;

export interface RegistrationReadDeps {
  caller(authorization: string | null): Promise<string | null>;
  /** registration_file_owned(uid, bucket, path). */
  owns(uid: string, bucket: string, path: string): Promise<boolean>;
  /** registration_text_read_spend(uid, limit): false once the day's reads are spent. */
  spend(uid: string, limit: number): Promise<boolean>;
  verifySettings(): Promise<unknown>;
  apiProviders(): Promise<unknown>;
  download(bucket: string, path: string): Promise<Uint8Array | null>;
  annotate(key: string, image: Uint8Array): Promise<{ status: number; body: unknown }>;
}

export function isRegistrationRead(input: unknown): boolean {
  return (input as { purpose?: unknown } | null)?.purpose === "registration";
}

export async function handleRegistrationRead(
  input: unknown,
  authorization: string | null,
  deps: RegistrationReadDeps,
): Promise<Result> {
  const url = (input as { file_url?: unknown } | null)?.file_url;
  const where = typeof url === "string" && url.length <= 1000 ? storageObject(url) : null;
  if (!where) return { status: 400, body: { error: "bad_request" } };
  try {
    const uid = await deps.caller(authorization);
    if (!uid) return { status: 401, body: { error: "not_signed_in" } };
    if (!(await deps.owns(uid, where.bucket, where.path))) return { status: 403, body: { error: "not_authorized" } };
    const [apiProviders, verify] = await Promise.all([deps.apiProviders(), deps.verifySettings()]);
    if (idReadMode(verify) === "phone") return { status: 403, body: { error: "vision_off" } };
    const key = visionKey(apiProviders);
    if (!key) return { status: 200, body: { state: "not_read", reason: "no_key" } };
    if (!(await deps.spend(uid, REGISTRATION_READS_PER_DAY))) return { status: 429, body: { error: "too_many" } };
    const image = await deps.download(where.bucket, where.path);
    if (!image) return { status: 200, body: { state: "not_read", reason: "no_photo" } };
    if (image.length > MAX_IMAGE_BYTES) return { status: 200, body: { state: "not_read", reason: "too_big" } };
    const answer = await deps.annotate(key, image);
    const v = readVision(answer.status, answer.body);
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
