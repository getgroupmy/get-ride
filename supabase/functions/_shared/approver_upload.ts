// ============================================================================
// approver-upload — shared logic (migration 0353)
// ----------------------------------------------------------------------------
// An approver with can_upload replaces the image of an in-scope document.
// Approvers cannot write the private document buckets from the app (storage
// RLS allows only the folder's owner or an admin), so this runs with the
// service role: it authorizes in SQL (approver_upload_target, which checks the
// approver grant + approver_covers and returns the current image URL),
// overwrites that storage object, then reopens the document for review
// (approver_upload_commit). It never creates a new document or storage path.
// ============================================================================

/// Buckets whose files are private and addressed by the stored public-form URL.
/// Mirrors lib/src/core/storage_links.dart `privateDocumentBuckets`.
const PRIVATE_BUCKETS = new Set([
  "ID_Image",
  "vehicle-documents",
  "provider-documents",
  "support-media",
  "airport-guides",
]);

const SOURCES = new Set(["partner", "vehicle", "identity"]);

/// 10 MB — a document scan, not a video.
export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;

export interface StorageRef {
  bucket: string;
  path: string;
}

/// The bucket and path of a Supabase Storage [url] in a private document
/// bucket; null for anything else. TS port of core/storage_links.dart
/// `privateStorageRef`.
export function parseStorageRef(url: string | null | undefined): StorageRef | null {
  if (!url) return null;
  let u: URL;
  try {
    u = new URL(url.trim());
  } catch {
    return null;
  }
  const seg = u.pathname.split("/").filter((s) => s.length > 0);
  const i = seg.indexOf("object");
  // …/storage/v1/object/<public|sign|authenticated>/<bucket>/<path…>
  if (i < 2 || seg[i - 2] !== "storage" || seg.length < i + 4) return null;
  if (!["public", "sign", "authenticated"].includes(seg[i + 1])) return null;
  const bucket = seg[i + 2];
  if (!PRIVATE_BUCKETS.has(bucket)) return null;
  const path = seg.slice(i + 3).join("/");
  if (path.length === 0) return null;
  return { bucket, path };
}

/// Decode a base64 string to bytes; null when it is not valid base64.
export function decodeBase64(data: string): Uint8Array | null {
  try {
    const bin = atob(data);
    const bytes = new Uint8Array(bin.length);
    for (let j = 0; j < bin.length; j++) bytes[j] = bin.charCodeAt(j);
    return bytes;
  } catch {
    return null;
  }
}

export interface UploadRequest {
  source: string;
  id: string;
  contentType: string;
  bytes: Uint8Array;
}

/// Validate and shape the request body; a string is the error code (400).
export function parseUploadBody(body: unknown): UploadRequest | string {
  if (typeof body !== "object" || body === null) return "bad_request";
  const b = body as Record<string, unknown>;
  const source = b.source;
  const id = b.id;
  const contentType = typeof b.contentType === "string" ? b.contentType : "";
  const data = b.data;
  if (typeof source !== "string" || !SOURCES.has(source)) return "bad_source";
  if (typeof id !== "string" || id.length < 10) return "bad_id";
  if (!contentType.startsWith("image/")) return "bad_content_type";
  if (typeof data !== "string" || data.length === 0) return "no_data";
  const bytes = decodeBase64(data);
  if (bytes === null) return "bad_data";
  if (bytes.length === 0) return "no_data";
  if (bytes.length > MAX_UPLOAD_BYTES) return "too_large";
  return { source, id, contentType, bytes };
}

export interface UploadDeps {
  /// Authorize in SQL and return the current image URL to overwrite; throws on refusal.
  target(source: string, id: string): Promise<{ file_url: string }>;
  /// Overwrite the storage object (upsert) with the new bytes.
  upload(ref: StorageRef, bytes: Uint8Array, contentType: string): Promise<void>;
  /// Reopen the document for review.
  commit(source: string, id: string): Promise<void>;
}

export interface HandlerResult {
  status: number;
  body: Record<string, unknown>;
}

/// Orchestrate a replace-image upload. [authorization] is the caller's bearer
/// header; the deps run the SQL RPCs as that caller and the storage write as
/// the service role.
export async function handleApproverUpload(
  body: unknown,
  authorization: string | null,
  deps: UploadDeps,
): Promise<HandlerResult> {
  if (!authorization || !/^Bearer\s+.+/i.test(authorization.trim())) {
    return { status: 401, body: { error: "not_signed_in" } };
  }
  const parsed = parseUploadBody(body);
  if (typeof parsed === "string") return { status: 400, body: { error: parsed } };

  let fileUrl: string;
  try {
    const t = await deps.target(parsed.source, parsed.id);
    fileUrl = t.file_url;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    // The SQL raises not_authorized for a missing grant / out of scope, and
    // APPROVER_* for a bad request; either way the caller may not do this.
    return { status: /not_authorized/.test(msg) ? 403 : 409, body: { error: msg } };
  }

  const ref = parseStorageRef(fileUrl);
  if (ref === null) return { status: 422, body: { error: "unsupported_storage_url" } };

  try {
    await deps.upload(ref, parsed.bytes, parsed.contentType);
  } catch (e) {
    return { status: 502, body: { error: "upload_failed", detail: e instanceof Error ? e.message : String(e) } };
  }

  try {
    await deps.commit(parsed.source, parsed.id);
  } catch (e) {
    return { status: 409, body: { error: e instanceof Error ? e.message : String(e) } };
  }

  return { status: 200, body: { ok: true } };
}
