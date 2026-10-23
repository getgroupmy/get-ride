import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import {
  base64,
  type CheckRow,
  type FaceCompareDeps,
  handleFaceCompare,
  readCompare,
  rekognitionKey,
  storageObject,
} from "./face_compare.ts";

const ID = "00000000-0000-0000-0000-000000000281";
const URL = "https://x.supabase.co/storage/v1/object/public/ID_Image";
const selfie: CheckRow = { id: ID, user_id: "u1", kind: "selfie", file_url: `${URL}/u1/signin/selfie_1.jpg` };
const card: CheckRow = { id: "id-row", user_id: "u1", kind: "id", file_url: `${URL}/u1/signin/id_front_1.jpg` };
const providers = [{
  id: "aws",
  services: [{
    id: "rekognition",
    keys: [
      { id: "k1", value: "AKIAOFF0000000000000:off-secret-0000000000000", disabled: true },
      { id: "k2", value: "AKIAIOSFODNN7EXAMPLE:wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" },
    ],
  }],
}];

function deps(over: Partial<FaceCompareDeps> = {}) {
  const saved: string[] = [];
  const d: FaceCompareDeps = {
    canReview: (a) => Promise.resolve(a === "Bearer admin" ? true : a === "Bearer rider" ? false : null),
    check: (id) => Promise.resolve(id === ID ? selfie : null),
    counterpart: () => Promise.resolve(card),
    apiProviders: () => Promise.resolve(providers),
    download: () => Promise.resolve(new Uint8Array([1, 2, 3])),
    compare: () => Promise.resolve({ status: 200, body: { FaceMatches: [{ Similarity: 97.123 }] } }),
    save: (id, state, score) => {
      saved.push(`${id} ${state} ${score}`);
      return Promise.resolve();
    },
    ...over,
  };
  return { d, saved };
}

Deno.test("a storage URL names its bucket and path", () => {
  assertEquals(storageObject(`${URL}/u1/signin/a%20b.jpg?t=1`), { bucket: "ID_Image", path: "u1/signin/a b.jpg" });
  assertEquals(storageObject("https://elsewhere.example/a.jpg"), null);
  assertEquals(storageObject(`${URL}/../secret`), null);
});

Deno.test("the first active Rekognition key", () => {
  assertEquals(rekognitionKey(providers)?.accessKeyId, "AKIAIOSFODNN7EXAMPLE");
  assertEquals(rekognitionKey({ providers }), rekognitionKey(providers));
  assertEquals(rekognitionKey([{ id: "aws", services: [] }]), null);
  assertEquals(rekognitionKey(null), null);
});

Deno.test("CompareFaces' answers in a word", () => {
  assertEquals(readCompare(200, { FaceMatches: [{ Similarity: 91.555 }, { Similarity: 40 }] }), { state: "match", score: 91.56 });
  assertEquals(readCompare(200, { FaceMatches: [{ Similarity: 62 }] }), { state: "no_match", score: 62 });
  assertEquals(readCompare(200, { FaceMatches: [], UnmatchedFaces: [{}] }), { state: "no_match", score: 0 });
  assertEquals(readCompare(200, {}), { state: "no_face", score: null });
  assertEquals(readCompare(400, { __type: "InvalidParameterException" }), { state: "no_face", score: null });
  assertEquals(readCompare(403, { __type: "AccessDeniedException" }).state, "error");
});

Deno.test("only an admin with a Documents page", async () => {
  const { d } = deps();
  assertEquals((await handleFaceCompare({ check_id: ID }, null, d)).status, 401);
  assertEquals((await handleFaceCompare({ check_id: ID }, "Bearer rider", d)).status, 403);
  assertEquals((await handleFaceCompare({ check_id: "nope" }, "Bearer admin", d)).status, 400);
  assertEquals((await handleFaceCompare({ check_id: "00000000-0000-0000-0000-000000000000" }, "Bearer admin", d)).status, 404);
});

Deno.test("compares the selfie with the ID and keeps the score on both", async () => {
  const sent: number[][] = [];
  const { d, saved } = deps({
    compare: (_k, a, b) => {
      sent.push([a.length, b.length]);
      return Promise.resolve({ status: 200, body: { FaceMatches: [{ Similarity: 97.123 }] } });
    },
  });
  const r = await handleFaceCompare({ check_id: ID }, "Bearer admin", d);
  assertEquals(r, { status: 200, body: { state: "match", score: 97.12 } });
  assertEquals(saved, [`${ID} match 97.12`, "id-row match 97.12"]);
  assertEquals(sent.length, 1);
});

Deno.test("without a key, or a pair, it is not checked", async () => {
  const none = deps({ apiProviders: () => Promise.resolve([]) });
  assertEquals((await handleFaceCompare({ check_id: ID }, "Bearer admin", none.d)).body, { state: "not_checked", reason: "no_key" });
  assertEquals(none.saved, [`${ID} not_checked null`]);
  const alone = deps({ counterpart: () => Promise.resolve(null) });
  assertEquals((await handleFaceCompare({ check_id: ID }, "Bearer admin", alone.d)).body.reason, "no_pair");
});

Deno.test("base64 of a large photo", () => {
  const bytes = new Uint8Array(100000).map((_, i) => i % 251);
  const s = base64(bytes);
  assert(s.length > 100000);
  assertEquals(Uint8Array.from(atob(s), (c) => c.charCodeAt(0)), bytes);
});
