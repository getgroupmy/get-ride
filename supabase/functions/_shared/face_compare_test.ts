import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import {
  base64,
  type CheckRow,
  type FaceCompareDeps,
  faceSetting,
  handleFaceCompare,
  providerPlan,
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
}, {
  id: "face_match",
  services: [{ id: "server", keys: [{ id: "f1", value: "https://face.getride.my:0123456789abcdef0123" }] }],
}];

function deps(over: Partial<FaceCompareDeps> = {}) {
  const saved: string[] = [];
  const d: FaceCompareDeps = {
    canReview: (a) => Promise.resolve(a === "Bearer admin" ? true : a === "Bearer rider" ? false : null),
    check: (id) => Promise.resolve(id === ID ? selfie : null),
    counterpart: () => Promise.resolve(card),
    apiProviders: () => Promise.resolve(providers),
    verifySettings: () => Promise.resolve(null),
    download: () => Promise.resolve(new Uint8Array([1, 2, 3])),
    compare: () => Promise.resolve({ status: 200, body: { FaceMatches: [{ Similarity: 97.123 }] } }),
    compareSelfHosted: () => Promise.resolve({ status: 200, body: { similarity: 0.82, model: "SFace" } }),
    save: (id, state, score, provider, reason) => {
      saved.push(`${id} ${state} ${score} ${provider} ${reason}`);
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
  assertEquals(r, { status: 200, body: { state: "match", score: 97.12, provider: "aws" } });
  assertEquals(saved, [`${ID} match 97.12 aws null`, "id-row match 97.12 aws null"]);
  assertEquals(sent.length, 1);
});

Deno.test("without a key, or a pair, it is not checked", async () => {
  const none = deps({ apiProviders: () => Promise.resolve([]) });
  assertEquals((await handleFaceCompare({ check_id: ID }, "Bearer admin", none.d)).body, {
    state: "not_checked",
    reason: "no_aws_key",
  });
  assertEquals(none.saved, [`${ID} not_checked null null no_aws_key`]);
  const alone = deps({ counterpart: () => Promise.resolve(null) });
  assertEquals((await handleFaceCompare({ check_id: ID }, "Bearer admin", alone.d)).body.reason, "no_pair");
});

Deno.test("base64 of a large photo", () => {
  const bytes = new Uint8Array(100000).map((_, i) => i % 251);
  const s = base64(bytes);
  assert(s.length > 100000);
  assertEquals(Uint8Array.from(atob(s), (c) => c.charCodeAt(0)), bytes);
});

Deno.test("the admin's choice, AWS when unset", () => {
  assertEquals(faceSetting(null), "aws");
  assertEquals(faceSetting({ faceProvider: "self_hosted_aws" }), "self_hosted_aws");
  assertEquals(faceSetting({ faceProvider: "elsewhere" }), "aws");
});

Deno.test("who is asked, in order, or why nobody", () => {
  assertEquals(providerPlan("off", true, true), { order: [], reason: "off" });
  assertEquals(providerPlan("aws", true, true), { order: ["aws"] });
  assertEquals(providerPlan("aws", false, true), { order: [], reason: "no_aws_key" });
  assertEquals(providerPlan("self_hosted", true, false), { order: [], reason: "no_server" });
  assertEquals(providerPlan("self_hosted", false, true), { order: ["self_hosted"] });
  assertEquals(providerPlan("self_hosted_aws", true, true), { order: ["self_hosted", "aws"] });
  assertEquals(providerPlan("self_hosted_aws", true, false), { order: ["aws"] });
  assertEquals(providerPlan("self_hosted_aws", false, false), { order: [], reason: "no_provider" });
});

function counting(setting: string, over: Partial<FaceCompareDeps> = {}) {
  const calls: string[] = [];
  const x = deps({
    verifySettings: () => Promise.resolve({ faceProvider: setting }),
    compare: () => {
      calls.push("aws");
      return Promise.resolve({ status: 200, body: { FaceMatches: [{ Similarity: 91 }] } });
    },
    compareSelfHosted: () => {
      calls.push("self_hosted");
      return Promise.resolve({ status: 200, body: { similarity: 0.82, model: "SFace" } });
    },
    ...over,
  });
  return { ...x, calls };
}

Deno.test("off asks nobody and says so", async () => {
  const { d, calls, saved } = counting("off");
  assertEquals((await handleFaceCompare({ check_id: ID }, "Bearer admin", d)).body, { state: "not_checked", reason: "off" });
  assertEquals(calls, []);
  assertEquals(saved, [`${ID} not_checked null null off`]);
});

Deno.test("the self-hosted server's score is kept as self-hosted", async () => {
  const { d, calls, saved } = counting("self_hosted");
  const r = await handleFaceCompare({ check_id: ID }, "Bearer admin", d);
  assertEquals(r.body, { state: "match", score: 82, provider: "self_hosted" });
  assertEquals(calls, ["self_hosted"]);
  assertEquals(saved[0], `${ID} match 82 self_hosted null`);
});

Deno.test("self-hosted, then AWS: AWS only when the server fails", async () => {
  const fine = counting("self_hosted_aws");
  assertEquals((await handleFaceCompare({ check_id: ID }, "Bearer admin", fine.d)).body.provider, "self_hosted");
  assertEquals(fine.calls, ["self_hosted"]);

  const down = counting("self_hosted_aws", {
    compareSelfHosted: () => {
      down.calls.push("self_hosted");
      return Promise.reject(new DOMException("timed out", "TimeoutError"));
    },
  });
  const r = await handleFaceCompare({ check_id: ID }, "Bearer admin", down.d);
  assertEquals(r.body, { state: "match", score: 91, provider: "aws", fell_back: true });
  assertEquals(down.calls, ["self_hosted", "aws"]);
  assertEquals(down.saved[0], `${ID} match 91 aws null`);

  const refused = counting("self_hosted_aws", {
    compareSelfHosted: () => {
      refused.calls.push("self_hosted");
      return Promise.resolve({ status: 401, body: { error: "bad_key" } });
    },
  });
  assertEquals((await handleFaceCompare({ check_id: ID }, "Bearer admin", refused.d)).body.provider, "aws");
  assertEquals(refused.calls, ["self_hosted", "aws"]);

  // No face is an answer, not a failure: AWS isn't asked.
  const noFace = counting("self_hosted_aws", {
    compareSelfHosted: () => {
      noFace.calls.push("self_hosted");
      return Promise.resolve({ status: 422, body: { error: "no_face" } });
    },
  });
  assertEquals((await handleFaceCompare({ check_id: ID }, "Bearer admin", noFace.d)).body, {
    state: "no_face",
    score: null,
    provider: "self_hosted",
  });
  assertEquals(noFace.calls, ["self_hosted"]);
});

Deno.test("self-hosted only: a server that fails is an error, not AWS", async () => {
  const x = counting("self_hosted", {
    compareSelfHosted: () => {
      x.calls.push("self_hosted");
      return Promise.reject(new TypeError("connection refused"));
    },
  });
  const r = await handleFaceCompare({ check_id: ID }, "Bearer admin", x.d);
  assertEquals(r.body, {
    state: "error",
    score: null,
    provider: "self_hosted",
    detail: "Self-hosted server: couldn't reach it",
  });
  assertEquals(x.calls, ["self_hosted"]);
});

Deno.test("self-hosted without its key: not set up", async () => {
  const x = counting("self_hosted", { apiProviders: () => Promise.resolve(providers.slice(0, 1)) });
  assertEquals((await handleFaceCompare({ check_id: ID }, "Bearer admin", x.d)).body.reason, "no_server");
  assertEquals(x.calls, []);
});
