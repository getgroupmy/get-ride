/**
 * The self-hosted face match server (deploy/face-server, on the office NAS
 * behind a Cloudflare Tunnel), as face-compare and key-test call it.
 *
 * Admin → API Keys keeps it as one key of "Face match server" (provider
 * "face_match", service "server"): the server's https address and its secret
 * key, "https://face.getride.my:SECRET" (a space between them works too).
 *
 *   GET  {url}/health                       → { status: "ok", model, key? }
 *   POST {url}/compare  x-api-key: SECRET
 *        { image1: base64, image2: base64 } → { similarity: 0..1, model, verified? }
 *                                           422 { error: "no_face" }
 *
 * similarity is the server's own scale, where 0.8 is the model's threshold
 * for "same person" (see deploy/face-server/README.md); verified, when sent,
 * is the server's verdict at that threshold.
 *
 *     deno test supabase/functions/_shared/face_server_test.ts
 */

export const FACE_SERVER_PROVIDER = "face_match";
export const FACE_SERVER_SERVICE = "server";
/** How long face-compare waits for the server. */
export const FACE_SERVER_TIMEOUT_MS = 15000;

export interface FaceServer {
  /** https://host[:port][/path], no trailing slash. */
  url: string;
  secret: string;
}

/** The stored value, split into address and secret; null when it isn't one. */
export function parseFaceServer(value: string | null | undefined): FaceServer | null {
  const v = (value ?? "").trim();
  let url: string, secret: string;
  const space = /^(\S+)\s+(\S+)$/.exec(v);
  if (space) {
    [url, secret] = [space[1], space[2]];
  } else {
    // The secret follows the last colon that comes after the host.
    const m = /^(https:\/\/[^\s]+?):([^:/\s]+)$/.exec(v);
    if (!m) return null;
    [url, secret] = [m[1], m[2]];
  }
  url = url.replace(/\/+$/, "");
  if (!/^https:\/\/[^\s/:]+(:\d{1,5})?(\/[^\s]*)?$/.test(url) || secret.length < 16) return null;
  return { url, secret };
}

interface KeyEntry {
  value?: unknown;
  disabled?: unknown;
}

/** The first usable "Face match server" key in Admin → API Keys, or null. */
export function faceServerKey(apiProviders: unknown): FaceServer | null {
  const list = Array.isArray(apiProviders) ? apiProviders : (apiProviders as { providers?: unknown })?.providers;
  if (!Array.isArray(list)) return null;
  const p = list.find((x) => x?.id === FACE_SERVER_PROVIDER);
  const s = (p?.services ?? []).find((x: { id?: string }) => x?.id === FACE_SERVER_SERVICE);
  for (const k of (Array.isArray(s?.keys) ? s.keys as KeyEntry[] : [])) {
    if (k?.disabled === true || typeof k?.value !== "string") continue;
    const server = parseFaceServer(k.value);
    if (server) return server;
  }
  return null;
}

export interface ServerRequest {
  url: string;
  method: "GET" | "POST";
  headers: Record<string, string>;
  body?: string;
}

export function compareRequest(server: FaceServer, image1: Uint8Array, image2: Uint8Array): ServerRequest {
  return {
    url: `${server.url}/compare`,
    method: "POST",
    headers: { "Content-Type": "application/json", "x-api-key": server.secret },
    body: JSON.stringify({ image1: base64(image1), image2: base64(image2) }),
  };
}

export function healthRequest(server: FaceServer): ServerRequest {
  return { url: `${server.url}/health`, method: "GET", headers: { "x-api-key": server.secret } };
}

export interface ServerAnswer {
  state: "match" | "no_match" | "no_face" | "error";
  /** 0–100, as Rekognition's. */
  score: number | null;
  /** The server is down or refused us: worth asking AWS instead. */
  failed: boolean;
  detail?: string;
}

/** The server's answer to /compare, in face-compare's words. */
export function readServerCompare(status: number, body: unknown): ServerAnswer {
  const b = (body ?? {}) as Record<string, unknown>;
  if (status === 422 && b.error === "no_face") return { state: "no_face", score: null, failed: false };
  if (status < 200 || status >= 300) {
    const why = status === 401 || status === 403 ? "key refused" : `HTTP ${status}`;
    return { state: "error", score: null, failed: true, detail: `Self-hosted server: ${why}` };
  }
  const sim = typeof b.similarity === "number" ? b.similarity : Number.NaN;
  if (!Number.isFinite(sim) || sim < 0 || sim > 1) {
    return { state: "error", score: null, failed: true, detail: "Self-hosted server: no similarity in the answer" };
  }
  const score = Math.round(sim * 10000) / 100;
  const same = typeof b.verified === "boolean" ? b.verified : sim >= 0.8;
  return { state: same ? "match" : "no_match", score, failed: false };
}

/** Base64 of [bytes], in chunks (a 5 MB photo is too big for one call). */
export function base64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(s);
}
