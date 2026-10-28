import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import {
  base64,
  betterComparison,
  type CheckRow,
  type DocumentFaceDeps,
  documentRequest,
  type FaceCompareDeps,
  faceOrder,
  faceSetting,
  handleDocumentFaceCompare,
  handleFaceCompare,
  handleOnlineFaceCompare,
  onlineCheckRequest,
  type OnlineFaceDeps,
  type OnlineResult,
  planFor,
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
  const none = deps({
    apiProviders: () => Promise.resolve([]),
    verifySettings: () => Promise.resolve({ faceProvider: "aws" }),
  });
  assertEquals((await handleFaceCompare({ check_id: ID }, "Bearer admin", none.d)).body, {
    state: "not_checked",
    reason: "no_aws_key",
    browser: true,
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

// ---- 0288: one document against the live selfie ---------------------------------------------------

const DOC = "00000000-0000-0000-0000-000000000288";
function docDeps(over: Partial<DocumentFaceDeps> = {}) {
  const stored: string[] = [];
  const d: DocumentFaceDeps = {
    webhookSecretOk: (s) => Promise.resolve(s === "db-secret"),
    canReview: (a) => Promise.resolve(a === "Bearer admin" ? true : a === "Bearer rider" ? false : null),
    source: (_k, id) =>
      Promise.resolve(id === DOC
        ? { user_id: "u1", file_url: `${URL}/u1/id_1.jpg`, selfie_url: `${URL}/u1/signin/selfie_1.jpg` }
        : null),
    apiProviders: () => Promise.resolve(providers),
    verifySettings: () => Promise.resolve(null),
    download: () => Promise.resolve(new Uint8Array([1, 2, 3])),
    compare: () => Promise.resolve({ status: 200, body: { FaceMatches: [{ Similarity: 41.5 }] } }),
    compareSelfHosted: () => Promise.resolve({ status: 200, body: { similarity: 0.9 } }),
    store: (kind, id, state, score, provider, reason) => {
      stored.push(`${kind} ${id} ${state} ${score} ${provider} ${reason}`);
      return Promise.resolve();
    },
    ...over,
  };
  return { d, stored };
}
const body = (kind = "national_id", id = DOC) => ({ document: { kind, id } });

Deno.test("document: the request names a known kind and a row id", () => {
  assertEquals(documentRequest(body()), { kind: "national_id", id: DOC });
  assertEquals(documentRequest(body("selfie")), null);
  assertEquals(documentRequest(body("national_id", "x")), null);
  assertEquals(documentRequest(null), null);
});

Deno.test("document: only the database's secret or an admin may ask", async () => {
  const { d } = docDeps();
  assertEquals((await handleDocumentFaceCompare(body(), { authorization: null, secret: null }, d)).status, 401);
  assertEquals((await handleDocumentFaceCompare(body(), { authorization: "Bearer rider", secret: null }, d)).status, 403);
  assertEquals((await handleDocumentFaceCompare(body(), { authorization: null, secret: "wrong" }, d)).status, 403);
  assertEquals((await handleDocumentFaceCompare(body(), { authorization: "Bearer admin", secret: null }, d)).status, 200);
  assertEquals((await handleDocumentFaceCompare(body("national_id", "00000000-0000-0000-0000-000000000000"),
    { authorization: null, secret: "db-secret" }, d)).status, 404);
});

Deno.test("document: the score is kept per document", async () => {
  const { d, stored } = docDeps();
  const r = await handleDocumentFaceCompare(body("provider_document"), { authorization: null, secret: "db-secret" }, d);
  assertEquals(r.body, { state: "no_match", score: 41.5, provider: "aws" });
  assertEquals(stored, [`provider_document ${DOC} no_match 41.5 aws null`]);
});

Deno.test("document: no live selfie, or no provider, is not checked", async () => {
  const none = docDeps({
    source: () => Promise.resolve({ user_id: "u1", file_url: `${URL}/u1/id_1.jpg`, selfie_url: null }),
  });
  const r = await handleDocumentFaceCompare(body(), { authorization: null, secret: "db-secret" }, none.d);
  assertEquals(r.body, { state: "not_checked", score: null, reason: "no_live_selfie" });
  const off = docDeps({ verifySettings: () => Promise.resolve({ faceProvider: "off" }) });
  const o = await handleDocumentFaceCompare(body("driver_permit"), { authorization: null, secret: "db-secret" }, off.d);
  assertEquals(o.body, { state: "not_checked", score: null, reason: "off" });
  assert(off.stored[0].startsWith("driver_permit"));
});

// ---- 0290: the selfie when going online -----------------------------------------------------------

const ONLINE = "00000000-0000-0000-0000-000000000290";
const AVATARS = "https://x.supabase.co/storage/v1/object/public/avatars";
function onlineDeps(over: Partial<OnlineFaceDeps> = {}, scores: Record<string, number> = {}) {
  const stored: OnlineResult[] = [];
  const d: OnlineFaceDeps = {
    webhookSecretOk: (s) => Promise.resolve(s === "db-secret"),
    canReview: (a) => Promise.resolve(a === "Bearer admin" ? true : a === "Bearer rider" ? false : null),
    source: (id) =>
      Promise.resolve(id === ONLINE
        ? {
          user_id: "u1",
          selfie_url: `${URL}/u1/online/selfie_1.jpg`,
          photo_url: `${AVATARS}/u1/me.jpg`,
          id_url: `${URL}/u1/id_front.jpg`,
        }
        : null),
    apiProviders: () => Promise.resolve(providers),
    verifySettings: () => Promise.resolve(null),
    // The bytes say which photo it is: 1 the selfie, 2 the profile photo, 3 the ID.
    download: (_b, path) =>
      Promise.resolve(new Uint8Array([path.includes("selfie") ? 1 : path.includes("me.jpg") ? 2 : 3])),
    compare: (_k, _s, target) =>
      Promise.resolve({
        status: 200,
        body: { FaceMatches: [{ Similarity: target[0] === 2 ? (scores.photo ?? 41) : (scores.id ?? 30) }] },
      }),
    compareSelfHosted: () => Promise.resolve({ status: 200, body: { similarity: 0.9 } }),
    store: (_id, r) => {
      stored.push(r);
      return Promise.resolve();
    },
    ...over,
  };
  return { d, stored };
}
const onlineBody = (id = ONLINE) => ({ online_check: { id } });

Deno.test("online: the request names a check", () => {
  assertEquals(onlineCheckRequest(onlineBody()), { id: ONLINE });
  assertEquals(onlineCheckRequest(onlineBody("x")), null);
  assertEquals(onlineCheckRequest({ document: { kind: "national_id", id: ONLINE } }), null);
});

Deno.test("online: only the database's secret or an admin may ask", async () => {
  const { d } = onlineDeps();
  assertEquals((await handleOnlineFaceCompare(onlineBody(), { authorization: null, secret: null }, d)).status, 401);
  assertEquals((await handleOnlineFaceCompare(onlineBody(), { authorization: "Bearer rider", secret: null }, d)).status, 403);
  assertEquals((await handleOnlineFaceCompare(onlineBody(), { authorization: null, secret: "wrong" }, d)).status, 403);
  assertEquals((await handleOnlineFaceCompare(onlineBody(), { authorization: "Bearer admin", secret: null }, d)).status, 200);
  assertEquals((await handleOnlineFaceCompare(onlineBody("00000000-0000-0000-0000-000000000000"),
    { authorization: null, secret: "db-secret" }, d)).status, 404);
});

Deno.test("online: compared with the profile photo and the ID; the better score counts", async () => {
  const { d, stored } = onlineDeps({}, { photo: 41, id: 30 });
  const r = await handleOnlineFaceCompare(onlineBody(), { authorization: null, secret: "db-secret" }, d);
  assertEquals(r.body, {
    state: "no_match",
    score: 41,
    provider: "aws",
    photo: { state: "no_match", score: 41 },
    id: { state: "no_match", score: 30 },
  });
  assertEquals(stored.length, 1);
  const good = onlineDeps({}, { photo: 20, id: 92.5 });
  const g = await handleOnlineFaceCompare(onlineBody(), { authorization: null, secret: "db-secret" }, good.d);
  assertEquals([g.body.state, g.body.score], ["match", 92.5]);
});

Deno.test("online: only one photo to compare with", async () => {
  const { d } = onlineDeps({
    source: () => Promise.resolve({ user_id: "u1", selfie_url: `${URL}/u1/online/selfie_1.jpg`, photo_url: null, id_url: `${URL}/u1/id.jpg` }),
  }, { id: 77 });
  const r = await handleOnlineFaceCompare(onlineBody(), { authorization: null, secret: "db-secret" }, d);
  assertEquals(r.body, { state: "no_match", score: 77, provider: "aws", id: { state: "no_match", score: 77 } });
});

Deno.test("online: no provider, or nothing to compare with, is kept as not checked", async () => {
  const off = onlineDeps({ verifySettings: () => Promise.resolve({ faceProvider: "off" }) });
  const o = await handleOnlineFaceCompare(onlineBody(), { authorization: null, secret: "db-secret" }, off.d);
  assertEquals(o.body, { state: "not_checked", score: null, reason: "off" });
  assertEquals(off.stored[0].reason, "off");
  const none = onlineDeps({
    source: () => Promise.resolve({ user_id: "u1", selfie_url: `${URL}/u1/s.jpg`, photo_url: null, id_url: null }),
  });
  const n = await handleOnlineFaceCompare(onlineBody(), { authorization: null, secret: "db-secret" }, none.d);
  assertEquals(n.body, { state: "not_checked", score: null, reason: "no_pair" });
  const noKey = onlineDeps({ apiProviders: () => Promise.resolve([]) });
  const k = await handleOnlineFaceCompare(onlineBody(), { authorization: null, secret: "db-secret" }, noKey.d);
  assertEquals(k.body.reason, "no_provider", "unset: AWS, then the NAS; neither set up");
});

Deno.test("online: self-hosted, then AWS when the server fails", async () => {
  const { d } = onlineDeps({
    verifySettings: () => Promise.resolve({ faceProvider: "self_hosted_aws" }),
    compareSelfHosted: () => Promise.reject(new Error("down")),
  }, { photo: 88, id: 70 });
  const r = await handleOnlineFaceCompare(onlineBody(), { authorization: null, secret: "db-secret" }, d);
  assertEquals([r.body.state, r.body.score, r.body.provider], ["match", 88, "aws"]);
});

Deno.test("online: the better of two comparisons", () => {
  assertEquals(betterComparison(undefined, { state: "match", score: 90 }), { state: "match", score: 90 });
  assertEquals(betterComparison({ state: "no_face", score: null }, { state: "no_match", score: 12 }),
    { state: "no_match", score: 12 });
  assertEquals(betterComparison({ state: "match", score: 81 }, { state: "match", score: 95 }), { state: "match", score: 95 });
  assertEquals(betterComparison({ state: "error", score: null }, { state: "no_face", score: null }),
    { state: "no_face", score: null });
  assert(betterComparison(undefined, undefined) === undefined);
});

// ---- 0320: the face match order ------------------------------------------------------------------

Deno.test("order: saved, else 0283's choice, else NAS, then AWS, then in-browser", () => {
  const ids = (v: unknown) => faceOrder(v).map((x) => `${x.id}:${x.on}`).join(",");
  assertEquals(ids(null), "nas:true,aws:true,browser:true");
  assertEquals(ids({ faceProvider: "self_hosted_aws" }), "nas:true,aws:true,browser:true");
  assertEquals(ids({ faceProvider: "off" }), "aws:false,nas:false,browser:false");
  assertEquals(
    ids({ faceProvider: "aws", faceOrder: [{ id: "browser", on: false }, { id: "x" }, { id: "nas" }, { id: "browser" }] }),
    "browser:false,nas:true,aws:true",
    "saved order kept, unknown and repeated dropped, a missing one joins",
  );
});

Deno.test("order: who is asked, and why nobody", () => {
  const v = (order: Array<[string, boolean]>) => ({ faceOrder: order.map(([id, on]) => ({ id, on })) });
  assertEquals(planFor(v([["aws", true], ["nas", true], ["browser", true]]), true, true), {
    order: ["aws", "self_hosted"],
    browser: true,
  });
  assertEquals(planFor(v([["nas", true], ["aws", false]]), true, true).order, ["self_hosted"]);
  assertEquals(planFor(v([["aws", true], ["nas", true]]), false, false).reason, "no_provider");
  assertEquals(planFor(v([["aws", false], ["nas", true]]), true, false).reason, "no_server");
  assertEquals(planFor(v([["aws", false], ["nas", false], ["browser", true]]), true, true), {
    order: [],
    reason: "off",
    browser: true,
  });
});

Deno.test("order: AWS, then the NAS when AWS fails", async () => {
  const x = counting("aws", {
    verifySettings: () => Promise.resolve({ faceOrder: [{ id: "aws", on: true }, { id: "nas", on: true }] }),
    compare: () => {
      x.calls.push("aws");
      return Promise.resolve({ status: 500, body: { __type: "InternalServerError" } });
    },
  });
  const r = await handleFaceCompare({ check_id: ID }, "Bearer admin", x.d);
  assertEquals(r.body, { state: "match", score: 82, provider: "self_hosted", fell_back: true });
  assertEquals(x.calls, ["aws", "self_hosted"]);

  const down = counting("aws", {
    verifySettings: () => Promise.resolve({ faceOrder: [{ id: "aws", on: true }, { id: "nas", on: true }] }),
    compare: () => Promise.reject(new TypeError("network")),
  });
  assertEquals((await handleFaceCompare({ check_id: ID }, "Bearer admin", down.d)).body.provider, "self_hosted");
});

Deno.test("order: only the in-browser check on: not checked here, for the browser", async () => {
  const x = counting("aws", {
    verifySettings: () =>
      Promise.resolve({ faceOrder: [{ id: "aws", on: false }, { id: "nas", on: false }, { id: "browser", on: true }] }),
  });
  assertEquals((await handleFaceCompare({ check_id: ID }, "Bearer admin", x.d)).body, {
    state: "not_checked",
    reason: "off",
    browser: true,
  });
  assertEquals(x.calls, []);
});
