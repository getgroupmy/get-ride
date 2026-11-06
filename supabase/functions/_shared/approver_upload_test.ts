import { assertEquals } from "jsr:@std/assert@1.0.19";
import {
  type HandlerResult,
  type StorageRef,
  type UploadDeps,
  handleApproverUpload,
  MAX_UPLOAD_BYTES,
  parseStorageRef,
  parseUploadBody,
} from "./approver_upload.ts";

const PUB = "https://x.supabase.co/storage/v1/object/public/provider-documents/p1/front.jpg";
// a 1x1 transparent png, base64
const TINY_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

Deno.test("parseStorageRef accepts a private bucket url", () => {
  assertEquals(parseStorageRef(PUB), { bucket: "provider-documents", path: "p1/front.jpg" });
  assertEquals(parseStorageRef("https://x.supabase.co/storage/v1/object/sign/ID_Image/u1/id.jpg?token=t"),
    { bucket: "ID_Image", path: "u1/id.jpg" });
});

Deno.test("parseStorageRef rejects non-document / malformed urls", () => {
  assertEquals(parseStorageRef(null), null);
  assertEquals(parseStorageRef(""), null);
  assertEquals(parseStorageRef("not a url"), null);
  // avatars is public, not a private document bucket
  assertEquals(parseStorageRef("https://x.supabase.co/storage/v1/object/public/avatars/a.jpg"), null);
  // no path
  assertEquals(parseStorageRef("https://x.supabase.co/storage/v1/object/public/provider-documents/"), null);
});

Deno.test("parseUploadBody validates", () => {
  assertEquals(parseUploadBody(null), "bad_request");
  assertEquals(parseUploadBody({ source: "nope", id: "0000000000", contentType: "image/png", data: TINY_PNG }), "bad_source");
  assertEquals(parseUploadBody({ source: "partner", id: "short", contentType: "image/png", data: TINY_PNG }), "bad_id");
  assertEquals(parseUploadBody({ source: "partner", id: "0000000000", contentType: "application/pdf", data: TINY_PNG }), "bad_content_type");
  assertEquals(parseUploadBody({ source: "partner", id: "0000000000", contentType: "image/png", data: "" }), "no_data");
  assertEquals(parseUploadBody({ source: "partner", id: "0000000000", contentType: "image/png", data: "!!!!" }), "bad_data");
  const ok = parseUploadBody({ source: "partner", id: "0000000000", contentType: "image/png", data: TINY_PNG });
  assertEquals(typeof ok === "object" && ok.source, "partner");
});

function deps(over: Partial<UploadDeps> = {}): { d: UploadDeps; calls: string[] } {
  const calls: string[] = [];
  const d: UploadDeps = {
    target: (s, id) => {
      calls.push(`target:${s}:${id}`);
      return Promise.resolve({ file_url: PUB });
    },
    upload: (ref: StorageRef) => {
      calls.push(`upload:${ref.bucket}/${ref.path}`);
      return Promise.resolve();
    },
    commit: (s, id) => {
      calls.push(`commit:${s}:${id}`);
      return Promise.resolve();
    },
    ...over,
  };
  return { d, calls };
}

const goodBody = { source: "partner", id: "00000000-0000-0000-0000-000000000001", contentType: "image/png", data: TINY_PNG };

Deno.test("happy path uploads then commits", async () => {
  const { d, calls } = deps();
  const r: HandlerResult = await handleApproverUpload(goodBody, "Bearer good", d);
  assertEquals(r.status, 200);
  assertEquals(calls, [
    "target:partner:00000000-0000-0000-0000-000000000001",
    "upload:provider-documents/p1/front.jpg",
    "commit:partner:00000000-0000-0000-0000-000000000001",
  ]);
});

Deno.test("no bearer is 401 and never calls the RPCs", async () => {
  const { d, calls } = deps();
  const r = await handleApproverUpload(goodBody, null, d);
  assertEquals(r.status, 401);
  assertEquals(calls.length, 0);
});

Deno.test("a refused target maps not_authorized to 403 and does not upload", async () => {
  const { d, calls } = deps({ target: () => Promise.reject(new Error("not_authorized")) });
  const r = await handleApproverUpload(goodBody, "Bearer good", d);
  assertEquals(r.status, 403);
  assertEquals(calls.some((c) => c.startsWith("upload")), false);
});

Deno.test("too large is rejected before any RPC", async () => {
  const { d, calls } = deps();
  const big = "A".repeat(Math.ceil((MAX_UPLOAD_BYTES + 1024) / 3) * 4); // > MAX bytes when decoded
  const r = await handleApproverUpload({ ...goodBody, data: big }, "Bearer good", d);
  assertEquals(r.status, 400);
  assertEquals(r.body.error, "too_large");
  assertEquals(calls.length, 0);
});
