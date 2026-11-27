/**
 * GET.eKYC (migration 0439): our own eKYC server, get.ekyc on the office Mac
 * mini. It runs the whole ID check in its own page, which the app shows
 * inside the app, and tells us the result by a signed webhook.
 *
 * Admin → API Keys → GET.eKYC keeps two keys:
 *   server   "https://ekyc.getcdn.link:ek_…"  the address and the API key
 *   webhook  the webhook secret get.ekyc showed once for this client
 *
 * Pure: the functions ekyc-start and ekyc-webhook do the I/O.
 *
 *     deno test supabase/functions/_shared/ekyc_test.ts
 */
import { hmacSha256Hex, sameHex } from "./payments/crypto.ts";
import { type FaceServer, parseFaceServer } from "./face_server.ts";

export const EKYC_PROVIDER = "ekyc";
export const EKYC_TIMEOUT_MS = 20000;
/** How old a webhook may be (seconds) before it is refused as a replay. */
export const WEBHOOK_TOLERANCE_S = 300;

export type EkycPurpose = "rider_gate" | "first";

interface KeyEntry {
  value?: unknown;
  disabled?: unknown;
}

function keysOf(apiProviders: unknown, service: string): KeyEntry[] {
  const list = Array.isArray(apiProviders) ? apiProviders : (apiProviders as { providers?: unknown })?.providers;
  if (!Array.isArray(list)) return [];
  const p = list.find((x) => x?.id === EKYC_PROVIDER);
  const s = (p?.services ?? []).find((x: { id?: string }) => x?.id === service);
  return Array.isArray(s?.keys) ? (s.keys as KeyEntry[]).filter((k) => k?.disabled !== true) : [];
}

/** The first usable server key: the address and the API key. */
export function ekycServer(apiProviders: unknown): FaceServer | null {
  for (const k of keysOf(apiProviders, "server")) {
    const s = typeof k.value === "string" ? parseFaceServer(k.value) : null;
    if (s) return s;
  }
  return null;
}

/** Every usable webhook secret (more than one while rotating). */
export function ekycWebhookSecrets(apiProviders: unknown): string[] {
  return keysOf(apiProviders, "webhook")
    .map((k) => (typeof k.value === "string" ? k.value.trim() : ""))
    .filter((v) => v.length >= 16);
}

/**
 * get.ekyc signs "timestamp.body" with HMAC-SHA256:
 * X-EKYC-Signature: sha256=<hex>, X-EKYC-Timestamp: <unix seconds>.
 */
export async function webhookSignatureValid(
  rawBody: string,
  timestamp: string | null,
  signature: string | null,
  secrets: string[],
  nowSeconds: number,
  tolerance = WEBHOOK_TOLERANCE_S,
): Promise<boolean> {
  if (!timestamp || !signature || !/^\d{9,11}$/.test(timestamp)) return false;
  if (Math.abs(nowSeconds - Number(timestamp)) > tolerance) return false;
  const sig = signature.trim().replace(/^sha256=/, "");
  if (!/^[0-9a-f]{64}$/i.test(sig)) return false;
  for (const secret of secrets) {
    if (sameHex(await hmacSha256Hex(secret, `${timestamp}.${rawBody}`), sig)) return true;
  }
  return false;
}

/** The body get.ekyc's POST /v1/verifications gets from us. */
export function createBody(userId: string, purpose: EkycPurpose, test: boolean) {
  return {
    external_ref: userId,
    // Riders and stand staff show an identity document; get.ekyc finds which.
    document_type: "auto",
    require_liveness: true,
    test,
    // The page runs inside the app, which hears the end through the bridge;
    // this is only the way back if it is ever opened in a browser.
    redirect_url: `getride://ekyc/${purpose === "first" ? "dispatch" : "rider"}`,
  };
}

const s = (v: unknown, max: number): string | null => {
  const t = typeof v === "string" ? v.trim() : "";
  return t ? t.slice(0, max) : null;
};
const day = (v: unknown): string | null => (typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null);

interface Check {
  name?: string;
  status?: string;
  code?: string;
}

export type EkycDocType =
  | "mykad" | "mypr" | "mykas" | "mytentera" | "id_card" | "passport"
  | "driving_licence" | "ikad" | "unhcr" | "residence_permit";

/** The check's doc_type (0441) for what GET.eKYC read, or null for a document that is not an ID. */
export function docTypeOf(extracted: Record<string, unknown>): EkycDocType | null {
  switch (extracted.document_type) {
    case "passport":
      return "passport";
    case "national_id": {
      if (extracted.country !== "MYS") return "id_card";
      const sub = String(extracted.document_subtype ?? "").toLowerCase();
      if (sub === "" || sub === "mykad") return "mykad";
      return sub === "mypr" || sub === "mykas" || sub === "mytentera" ? sub : "id_card";
    }
    case "driving_licence":
      return "driving_licence";
    case "foreign_worker_card":
      return "ikad";
    case "refugee_card":
      return "unhcr";
    case "residence_permit":
      return "residence_permit";
    default:
      return null;
  }
}

/**
 * What ekyc_apply stores, from get.ekyc's GET /v1/verifications/{id} answer
 * and the ID_Image paths the photos were copied to.
 */
export function applyPayload(
  v: Record<string, unknown>,
  photos: { front: string; back?: string | null; selfie?: string | null },
): Record<string, unknown> {
  const result = (v.result ?? {}) as Record<string, unknown>;
  const ex = (result.extracted ?? {}) as Record<string, unknown>;
  const checks = (Array.isArray(result.checks) ? result.checks : []) as Check[];
  const scores = (result.scores ?? {}) as Record<string, unknown>;
  const byName = (n: string) => checks.find((c) => c?.name === n);

  const docType = docTypeOf(ex);
  // An i-Kad is numbered by the holder's passport.
  const isPassport = docType === "passport" || docType === "ikad";
  const sex = String(ex.sex ?? "").toUpperCase();
  const nat = typeof ex.nationality === "string" && /^[A-Z]{3}$/.test(ex.nationality)
    ? ex.nationality
    : ex.citizenship === "citizen" && ex.country === "MYS"
    ? "MYS"
    : null;

  const face = byName("face_match");
  const score = typeof scores.face_score === "number" ? Math.max(0, Math.min(100, scores.face_score)) : null;
  const faceState = !face || face.status === "skipped"
    ? (face?.code === "face_missing" ? "no_face" : "not_checked")
    : face.status === "pass"
    ? "match"
    : "no_match";

  return {
    status: v.status,
    reasons: Array.isArray(v.reasons) ? v.reasons.filter((r) => typeof r === "string").slice(0, 20) : [],
    doc_type: docType,
    front: photos.front,
    back: photos.back ?? null,
    selfie: photos.selfie ?? null,
    read: {
      name: s(ex.full_name, 120),
      ic: isPassport ? null : s(ex.id_number ?? ex.document_number, 40),
      passport: isPassport ? s(ex.document_number, 40) : null,
      birth: day(ex.date_of_birth),
      expiry: day(ex.expiry_date),
      nationality: nat,
      gender: sex === "M" ? "male" : sex === "F" ? "female" : null,
      address: s(ex.address, 300),
    },
    face: { score, state: faceState },
    liveness: byName("liveness")?.status === "pass" ? "passed" : "not_checked",
  };
}

/** The webhook's verdict is final only for these; anything else is ignored. */
export const FINAL = new Set(["approved", "review", "rejected"]);
