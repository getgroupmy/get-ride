/**
 * face-compare (migrations 0281, 0283): how alike the face in someone's
 * selfie is to the face on their ID photo, as a score for the admin who
 * reviews them. Never a decision: the admin approves or rejects.
 *
 * Who scores it is the admin's choice (Admin → Dispatch → Accounts, kept in
 * app_settings 'dispatch_verify': 0320's faceOrder below, else 0283's
 * faceProvider):
 *   off              nobody;
 *   aws (default)    AWS Rekognition CompareFaces, with the key from Admin →
 *                    API Keys (provider "aws", service "rekognition", the
 *                    first active key, "ACCESS_KEY_ID:SECRET_ACCESS_KEY" or
 *                    "...:region");
 *   self_hosted      the self-hosted face server (_shared/face_server.ts);
 *   self_hosted_aws  the self-hosted server, and AWS when it can't answer.
 * Without a usable one the answer is "not_checked" with the reason (off,
 * no_aws_key, no_server, no_provider), kept on the check for the queue. The
 * score is kept with who gave it (face_provider). The photos are read from
 * storage with the service role, sent and dropped: nothing is kept but the
 * score.
 *
 * The pure half, tested with stand-ins; face-compare/index.ts does the I/O.
 *
 *     deno test supabase/functions/_shared/face_compare_test.ts
 */

import { type AwsKey, parseAwsKey } from "./aws_sigv4.ts";
import { base64, type FaceServer, faceServerKey, readServerCompare } from "./face_server.ts";

export { base64 };

export const DOCUMENT_PAGES = ["admin-documents", "admin-documents-users", "admin-documents-partners"];
export const AWS_PROVIDER = "aws";
export const REKOGNITION_SERVICE = "rekognition";
/** Rekognition's own limit for an image sent as bytes. */
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;

export type FaceState = "match" | "no_match" | "no_face" | "not_checked" | "error";
export type FaceProvider = "aws" | "self_hosted";
export type FaceSetting = "off" | "aws" | "self_hosted" | "self_hosted_aws";
const SETTINGS: FaceSetting[] = ["off", "aws", "self_hosted", "self_hosted_aws"];

/** The admin's choice from app_settings 'dispatch_verify'; AWS when unset. */
export function faceSetting(dispatchVerify: unknown): FaceSetting {
  const v = (dispatchVerify as { faceProvider?: unknown } | null)?.faceProvider;
  return SETTINGS.includes(v as FaceSetting) ? v as FaceSetting : "aws";
}

// ---- The face match order (migration 0320) ---------------------------------------------------------
//
// Admin › Dispatch › Accounts (and Settings › Office NAS › ID and face) keeps
// an ordered list with a switch each in 'dispatch_verify'.faceOrder:
//   aws      AWS Rekognition;
//   nas      the self-hosted face server on the office NAS (deploy/face-server);
//   browser  the in-browser check (vladmandic/human) in the admin web app,
//            while an admin has the Sign-in checks queue open: never here.
// Without a saved list, 0283's faceProvider gives it (as the database's
// identity_face_order does); unset, AWS, then NAS, then in-browser.

export type FaceOrderId = "aws" | "nas" | "browser";
export interface FaceOrderItem {
  id: FaceOrderId;
  on: boolean;
}
const ORDER_IDS: FaceOrderId[] = ["aws", "nas", "browser"];

function legacyOrder(setting: unknown): FaceOrderItem[] {
  const o = (id: FaceOrderId, on: boolean) => ({ id, on });
  switch (setting) {
    case "off":
      return [o("aws", false), o("nas", false), o("browser", false)];
    case "aws":
      return [o("aws", true), o("nas", false), o("browser", true)];
    case "self_hosted":
      return [o("nas", true), o("aws", false), o("browser", true)];
    case "self_hosted_aws":
      return [o("nas", true), o("aws", true), o("browser", true)];
    default:
      return [o("aws", true), o("nas", true), o("browser", true)];
  }
}

/** The face match order from app_settings 'dispatch_verify': each known id once. */
export function faceOrder(dispatchVerify: unknown): FaceOrderItem[] {
  const v = (dispatchVerify ?? {}) as { faceOrder?: unknown; faceProvider?: unknown };
  const fallback = legacyOrder(v.faceProvider);
  const out: FaceOrderItem[] = [];
  for (const r of Array.isArray(v.faceOrder) ? v.faceOrder : []) {
    const id = (r as { id?: unknown })?.id as FaceOrderId;
    if (!ORDER_IDS.includes(id) || out.some((x) => x.id === id)) continue;
    const on = (r as { on?: unknown }).on;
    out.push({ id, on: typeof on === "boolean" ? on : true });
  }
  for (const f of fallback) if (!out.some((x) => x.id === f.id)) out.push(f);
  return out;
}

/**
 * Who to ask, in order, with what is set up; or why nobody. [browser] is
 * whether the in-browser check is on after them (it scores what they
 * couldn't, in the admin's browser).
 */
export function planFor(dispatchVerify: unknown, hasAws: boolean, hasServer: boolean): {
  order: FaceProvider[];
  reason?: "off" | "no_aws_key" | "no_server" | "no_provider";
  browser: boolean;
} {
  const items = faceOrder(dispatchVerify);
  const browser = items.some((x) => x.id === "browser" && x.on);
  const on = items.filter((x) => x.on && x.id !== "browser").map((x) => x.id);
  const order: FaceProvider[] = [];
  for (const id of on) {
    if (id === "aws" && hasAws) order.push("aws");
    if (id === "nas" && hasServer) order.push("self_hosted");
  }
  if (order.length) return { order, browser };
  const reason = on.length === 0
    ? "off"
    : on.length === 2
    ? "no_provider"
    : on[0] === "aws"
    ? "no_aws_key"
    : "no_server";
  return { order, reason, browser };
}

/** Who to ask, in order, with what is set up; or why nobody (0283's choice). */
export function providerPlan(setting: FaceSetting, hasAws: boolean, hasServer: boolean): {
  order: FaceProvider[];
  reason?: "off" | "no_aws_key" | "no_server" | "no_provider";
} {
  switch (setting) {
    case "off":
      return { order: [], reason: "off" };
    case "self_hosted":
      return hasServer ? { order: ["self_hosted"] } : { order: [], reason: "no_server" };
    case "self_hosted_aws": {
      const order: FaceProvider[] = [...(hasServer ? ["self_hosted" as const] : []), ...(hasAws ? ["aws" as const] : [])];
      return order.length ? { order } : { order: [], reason: "no_provider" };
    }
    default:
      return hasAws ? { order: ["aws"] } : { order: [], reason: "no_aws_key" };
  }
}

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

export interface FaceCompareDeps {
  /** Whether the caller's token is an admin who edits a Documents page; null when not signed in. */
  canReview(authorization: string | null): Promise<boolean | null>;
  check(id: string): Promise<CheckRow | null>;
  /** The selfie / ID front to compare [row] with: the newest of the other kind. */
  counterpart(row: CheckRow): Promise<CheckRow | null>;
  apiProviders(): Promise<unknown>;
  /** app_settings 'dispatch_verify' (faceProvider). */
  verifySettings(): Promise<unknown>;
  download(bucket: string, path: string): Promise<Uint8Array | null>;
  /** AWS Rekognition CompareFaces. */
  compare(key: AwsKey, source: Uint8Array, target: Uint8Array): Promise<{ status: number; body: unknown }>;
  /** The self-hosted server's /compare (throws when it can't be reached in time). */
  compareSelfHosted(server: FaceServer, selfie: Uint8Array, card: Uint8Array): Promise<{ status: number; body: unknown }>;
  save(id: string, state: FaceState, score: number | null, provider: FaceProvider | null, reason: string | null): Promise<void>;
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
    const [apiProviders, verify] = await Promise.all([deps.apiProviders(), deps.verifySettings()]);
    const key = rekognitionKey(apiProviders);
    const server = faceServerKey(apiProviders);
    const plan = planFor(verify, key !== null, server !== null);
    if (plan.reason) {
      // No server to ask: the in-browser check scores it, when it is on,
      // while an admin has the queue open.
      await deps.save(row.id, "not_checked", null, null, plan.reason);
      return {
        status: 200,
        body: { state: "not_checked", reason: plan.reason, ...(plan.browser ? { browser: true } : {}) },
      };
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
    let r: { state: FaceState; score: number | null; detail?: string } = { state: "error", score: null };
    let used: FaceProvider = plan.order[0];
    let fellBack = false;
    for (const provider of plan.order) {
      if (provider !== used) fellBack = true;
      used = provider;
      if (provider === "self_hosted") {
        const answer = await deps.compareSelfHosted(server!, src, dst)
          .then((x) => readServerCompare(x.status, x.body))
          .catch((e) => ({
            state: "error" as const,
            score: null,
            failed: true,
            detail: e instanceof Error && e.name === "TimeoutError"
              ? "Self-hosted server: no answer within 15 s"
              : "Self-hosted server: couldn't reach it",
          }));
        r = { state: answer.state, score: answer.score, ...(answer.detail ? { detail: answer.detail } : {}) };
        if (answer.failed) continue;
        break;
      }
      const answer = await deps.compare(key!, src, dst)
        .then((x) => readCompare(x.status, x.body))
        .catch(() => ({ state: "error" as const, score: null, detail: "AWS: couldn't reach it" }));
      r = answer;
      // AWS failing goes on to the NAS when it is next.
      if (answer.state === "error") continue;
      break;
    }
    await deps.save(row.id, r.state, r.score, used, null);
    if (other.id !== row.id) await deps.save(other.id, r.state, r.score, used, null);
    return {
      status: 200,
      body: {
        state: r.state,
        score: r.score,
        provider: used,
        ...(fellBack ? { fell_back: true } : {}),
        ...(r.detail ? { detail: r.detail } : {}),
      },
    };
  } catch {
    return { status: 503, body: { error: "unavailable" } };
  }
}

// ---- One document against the live selfie (migration 0288) ---------------------------------------
//
// Every document with the person's photo on it (the National ID, the Kad
// Pemandu, Required Documents marked "Has the person's photo") is compared
// with their newest live selfie when it is added: the database asks
// (document_face_check_kick, x-push-secret) and an admin may ask again.
// The score is kept per document (document_face_check_store); a low one
// marks the partner "Needs a closer look". Never a decision.
//
// Request:  POST { document: { kind, id } }
// Response: 200 { state, score?, provider?, reason?, detail? }
//           400 bad_request · 401 not_signed_in · 403 not_authorized
//           404 not_found · 503 unavailable

export const DOCUMENT_KINDS = ["national_id", "driver_permit", "provider_document", "vehicle_document"] as const;
export type DocumentKind = typeof DOCUMENT_KINDS[number];

/** Admin pages that may ask again: the Documents pages and the partner's. */
export const DOCUMENT_FACE_PAGES = [...DOCUMENT_PAGES, "admin-partners", "admin-partner-edit"];

export interface DocumentSource {
  user_id: string;
  file_url: string | null;
  selfie_url: string | null;
}

export interface DocumentFaceDeps {
  /** Whether the x-push-secret header is the database's webhook secret. */
  webhookSecretOk(secret: string): Promise<boolean>;
  /** Whether the caller's token is an admin who may ask; null when not signed in. */
  canReview(authorization: string | null): Promise<boolean | null>;
  source(kind: DocumentKind, id: string): Promise<DocumentSource | null>;
  apiProviders(): Promise<unknown>;
  verifySettings(): Promise<unknown>;
  download(bucket: string, path: string): Promise<Uint8Array | null>;
  compare(key: AwsKey, source: Uint8Array, target: Uint8Array): Promise<{ status: number; body: unknown }>;
  compareSelfHosted(server: FaceServer, selfie: Uint8Array, card: Uint8Array): Promise<{ status: number; body: unknown }>;
  store(
    kind: DocumentKind,
    id: string,
    state: FaceState,
    score: number | null,
    provider: FaceProvider | null,
    reason: string | null,
    selfieUrl: string | null,
  ): Promise<void>;
}

export function documentRequest(input: unknown): { kind: DocumentKind; id: string } | null {
  const d = (input as { document?: { kind?: unknown; id?: unknown } } | null)?.document;
  if (!d || typeof d.kind !== "string" || typeof d.id !== "string") return null;
  if (!(DOCUMENT_KINDS as readonly string[]).includes(d.kind)) return null;
  if (!/^[0-9a-f-]{36}$/i.test(d.id)) return null;
  return { kind: d.kind as DocumentKind, id: d.id };
}

export async function handleDocumentFaceCompare(
  input: unknown,
  headers: { authorization: string | null; secret: string | null },
  deps: DocumentFaceDeps,
): Promise<Result> {
  const req = documentRequest(input);
  if (!req) return { status: 400, body: { error: "bad_request" } };
  try {
    const secret = (headers.secret ?? "").trim();
    let allowed = secret ? await deps.webhookSecretOk(secret) : false;
    if (!allowed) {
      const admin = await deps.canReview(headers.authorization);
      if (admin === null && !secret) return { status: 401, body: { error: "not_signed_in" } };
      allowed = admin === true;
    }
    if (!allowed) return { status: 403, body: { error: "not_authorized" } };
    const src = await deps.source(req.kind, req.id);
    if (!src) return { status: 404, body: { error: "not_found" } };
    const done = async (state: FaceState, score: number | null, provider: FaceProvider | null, reason: string | null) => {
      await deps.store(req.kind, req.id, state, score, provider, reason, src.selfie_url);
      return {
        status: 200,
        body: { state, score, ...(provider ? { provider } : {}), ...(reason ? { reason } : {}) },
      };
    };
    if (!src.selfie_url) return await done("not_checked", null, null, "no_live_selfie");
    const [apiProviders, verify] = await Promise.all([deps.apiProviders(), deps.verifySettings()]);
    const key = rekognitionKey(apiProviders);
    const server = faceServerKey(apiProviders);
    const plan = planFor(verify, key !== null, server !== null);
    if (plan.reason) return await done("not_checked", null, null, plan.reason);
    const a = storageObject(src.selfie_url), b = storageObject(src.file_url);
    const [selfie, card] = await Promise.all([
      a ? deps.download(a.bucket, a.path) : null,
      b ? deps.download(b.bucket, b.path) : null,
    ]);
    if (!selfie || !card) return await done("not_checked", null, null, "no_photo");
    if (selfie.length > MAX_IMAGE_BYTES || card.length > MAX_IMAGE_BYTES) {
      return await done("not_checked", null, null, "too_big");
    }
    let r: { state: FaceState; score: number | null; detail?: string } = { state: "error", score: null };
    let used: FaceProvider = plan.order[0];
    for (const provider of plan.order) {
      used = provider;
      if (provider === "self_hosted") {
        const answer = await deps.compareSelfHosted(server!, selfie, card)
          .then((x) => readServerCompare(x.status, x.body))
          .catch(() => ({ state: "error" as const, score: null, failed: true, detail: "Self-hosted server: no answer" }));
        r = { state: answer.state, score: answer.score, ...(answer.detail ? { detail: answer.detail } : {}) };
        if (answer.failed) continue;
        break;
      }
      const answer = await deps.compare(key!, selfie, card)
        .then((x) => readCompare(x.status, x.body))
        .catch(() => ({ state: "error" as const, score: null, detail: "AWS: no answer" }));
      r = answer;
      if (answer.state === "error") continue;
      break;
    }
    return await done(r.state, r.score, used, r.state === "error" ? (r.detail ?? "error") : null);
  } catch {
    return { status: 503, body: { error: "unavailable" } };
  }
}

// ---- The selfie when going online (migration 0290) ------------------------------------------------
//
// A partner's live selfie taken on Go online is compared with their approved
// profile photo and their ID photo. The database asks when the selfie is in
// (online_selfie_face_kick, x-push-secret); an admin may ask again. The
// match is the better of the two, kept with each (online_selfie_check_store),
// and a low one alerts the admin's chosen recipients there. Never a
// decision: the partner is online either way.
//
// Request:  POST { online_check: { id } }
// Response: 200 { state, score?, provider?, reason?, photo?, id? }
//           400 bad_request · 401 not_signed_in · 403 not_authorized
//           404 not_found · 503 unavailable

/** Admin pages that may ask again: Documents, Partners and Dispatch › Partner selfie checks. */
export const ONLINE_FACE_PAGES = [...DOCUMENT_PAGES, "admin-partners", "admin-partner-edit", "admin-dispatch-selfie-checks"];

export interface OnlineSource {
  user_id: string;
  selfie_url: string | null;
  photo_url: string | null;
  id_url: string | null;
}

export interface OneComparison {
  state: FaceState;
  score: number | null;
}

export interface OnlineResult {
  state: FaceState;
  score: number | null;
  provider: FaceProvider | null;
  reason: string | null;
  photo?: OneComparison;
  id?: OneComparison;
}

export interface OnlineFaceDeps {
  webhookSecretOk(secret: string): Promise<boolean>;
  canReview(authorization: string | null): Promise<boolean | null>;
  source(id: string): Promise<OnlineSource | null>;
  apiProviders(): Promise<unknown>;
  verifySettings(): Promise<unknown>;
  download(bucket: string, path: string): Promise<Uint8Array | null>;
  compare(key: AwsKey, source: Uint8Array, target: Uint8Array): Promise<{ status: number; body: unknown }>;
  compareSelfHosted(server: FaceServer, selfie: Uint8Array, card: Uint8Array): Promise<{ status: number; body: unknown }>;
  store(id: string, result: OnlineResult): Promise<void>;
}

export function onlineCheckRequest(input: unknown): { id: string } | null {
  const o = (input as { online_check?: { id?: unknown } } | null)?.online_check;
  if (!o || typeof o.id !== "string" || !/^[0-9a-f-]{36}$/i.test(o.id)) return null;
  return { id: o.id };
}

/** The better of two comparisons: a score beats none, the higher score wins. */
export function betterComparison(a: OneComparison | undefined, b: OneComparison | undefined): OneComparison | undefined {
  if (!a) return b;
  if (!b) return a;
  if (a.score === null) return b.score === null ? (a.state === "error" ? b : a) : b;
  if (b.score === null) return a;
  return b.score > a.score ? b : a;
}

export async function handleOnlineFaceCompare(
  input: unknown,
  headers: { authorization: string | null; secret: string | null },
  deps: OnlineFaceDeps,
): Promise<Result> {
  const req = onlineCheckRequest(input);
  if (!req) return { status: 400, body: { error: "bad_request" } };
  try {
    const secret = (headers.secret ?? "").trim();
    let allowed = secret ? await deps.webhookSecretOk(secret) : false;
    if (!allowed) {
      const admin = await deps.canReview(headers.authorization);
      if (admin === null && !secret) return { status: 401, body: { error: "not_signed_in" } };
      allowed = admin === true;
    }
    if (!allowed) return { status: 403, body: { error: "not_authorized" } };
    const src = await deps.source(req.id);
    if (!src) return { status: 404, body: { error: "not_found" } };
    const done = async (r: OnlineResult) => {
      await deps.store(req.id, r);
      return {
        status: 200,
        body: {
          state: r.state,
          score: r.score,
          ...(r.provider ? { provider: r.provider } : {}),
          ...(r.reason ? { reason: r.reason } : {}),
          ...(r.photo ? { photo: r.photo } : {}),
          ...(r.id ? { id: r.id } : {}),
        },
      };
    };
    const notChecked = (reason: string) => done({ state: "not_checked", score: null, provider: null, reason });
    if (!src.selfie_url) return await notChecked("no_selfie");
    if (!src.photo_url && !src.id_url) return await notChecked("no_pair");
    const [apiProviders, verify] = await Promise.all([deps.apiProviders(), deps.verifySettings()]);
    const key = rekognitionKey(apiProviders);
    const server = faceServerKey(apiProviders);
    const plan = planFor(verify, key !== null, server !== null);
    if (plan.reason) return await notChecked(plan.reason);
    const at = (url: string | null) => {
      const o = storageObject(url);
      return o ? deps.download(o.bucket, o.path) : Promise.resolve(null);
    };
    const [selfie, photo, card] = await Promise.all([at(src.selfie_url), at(src.photo_url), at(src.id_url)]);
    if (!selfie || (!photo && !card)) return await notChecked("no_photo");
    if (selfie.length > MAX_IMAGE_BYTES) return await notChecked("too_big");

    let used: FaceProvider = plan.order[0];
    let detail: string | undefined;
    const one = async (other: Uint8Array | null): Promise<OneComparison | undefined> => {
      if (!other || other.length > MAX_IMAGE_BYTES) return undefined;
      let r: OneComparison = { state: "error", score: null };
      for (const provider of plan.order) {
        used = provider;
        if (provider === "self_hosted") {
          const answer = await deps.compareSelfHosted(server!, selfie, other)
            .then((x) => readServerCompare(x.status, x.body))
            .catch(() => ({ state: "error" as const, score: null, failed: true, detail: "Self-hosted server: no answer" }));
          r = { state: answer.state, score: answer.score };
          if (answer.detail) detail = answer.detail;
          if (answer.failed) continue;
          break;
        }
        const answer = await deps.compare(key!, selfie, other)
          .then((res) => readCompare(res.status, res.body))
          .catch(() => ({ state: "error" as const, score: null, detail: "AWS: no answer" }));
        r = { state: answer.state, score: answer.score };
        if (answer.detail) detail = answer.detail;
        if (answer.state === "error") continue;
        break;
      }
      return r;
    };
    const photoResult = await one(photo);
    const idResult = await one(card);
    const best = betterComparison(photoResult, idResult);
    if (!best) return await notChecked("too_big");
    return await done({
      state: best.state,
      score: best.score,
      provider: used,
      reason: best.state === "error" ? (detail ?? "error").slice(0, 160) : null,
      ...(photoResult ? { photo: photoResult } : {}),
      ...(idResult ? { id: idResult } : {}),
    });
  } catch {
    return { status: 503, body: { error: "unavailable" } };
  }
}
