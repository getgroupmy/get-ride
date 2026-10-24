import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import {
  type CardRead,
  handleIdRead,
  handleRegistrationRead,
  type IdCheckRow,
  type IdReadDeps,
  idReadMode,
  isRegistrationRead,
  readCardText,
  readVision,
  type RegistrationReadDeps,
  visionKey,
  visionRequest,
} from "./id_read.ts";

const cases = JSON.parse(await Deno.readTextFile(new URL("./id_card_cases.json", import.meta.url))) as {
  cases: { name: string; text: string; expect: CardRead }[];
};

for (const c of cases.cases) {
  Deno.test(`the card's text: ${c.name}`, () => {
    assertEquals(readCardText(c.text), c.expect);
  });
}

const ID = "00000000-0000-0000-0000-000000000283";
const BUCKET = "https://x.supabase.co/storage/v1/object/public/ID_Image";
const card: IdCheckRow = {
  id: ID,
  user_id: "u1",
  kind: "id",
  file_url: `${BUCKET}/u1/signin/id_front_1.jpg`,
  status: "Pending Review",
  read_source: null,
};
const providers = [{
  id: "google",
  services: [
    { id: "maps", keys: [{ id: "m", value: "maps-key" }] },
    { id: "vision", keys: [{ id: "v0", value: "off-key", disabled: true }, { id: "v1", value: "vision-key-123" }] },
  ],
}];
const MYKAD = "KAD PENGENALAN\n880202-10-1234\nAINA BINTI AHMAD\nSELANGOR";

function deps(over: Partial<IdReadDeps> = {}) {
  const calls: string[] = [];
  const d: IdReadDeps = {
    caller: (a) => Promise.resolve(a === "Bearer u1" ? "u1" : a === "Bearer admin" ? "admin" : a === "Bearer u2" ? "u2" : null),
    canReview: (a) => Promise.resolve(a === "Bearer admin"),
    check: (id) => Promise.resolve(id === ID ? card : null),
    verifySettings: () => Promise.resolve({ idRead: "phone_vision" }),
    apiProviders: () => Promise.resolve(providers),
    download: () => Promise.resolve(new Uint8Array([1, 2, 3])),
    annotate: (key) => {
      calls.push(`annotate ${key}`);
      return Promise.resolve({ status: 200, body: { responses: [{ fullTextAnnotation: { text: MYKAD } }] } });
    },
    store: (id, read) => {
      calls.push(`store ${id} ${read.name} ${read.ic}`);
      return Promise.resolve({ mismatch: [] });
    },
    ...over,
  };
  return { d, calls };
}

Deno.test("the admin's setting, the phone only when unset", () => {
  assertEquals(idReadMode(null), "phone");
  assertEquals(idReadMode({ idRead: "vision" }), "vision");
  assertEquals(idReadMode({ idRead: "always" }), "phone");
});

Deno.test("the first active Cloud Vision key, never a Maps key", () => {
  assertEquals(visionKey(providers), "vision-key-123");
  assertEquals(visionKey({ providers }), "vision-key-123");
  assertEquals(visionKey([{ id: "google", services: [{ id: "maps", keys: [{ value: "maps-key" }] }] }]), null);
  assertEquals(visionKey(null), null);
});

Deno.test("one TEXT_DETECTION request, the key in a header", () => {
  const r = visionRequest("vision-key-123", new Uint8Array([1, 2, 3]));
  assertEquals(r.url, "https://vision.googleapis.com/v1/images:annotate");
  assertEquals(r.headers["X-Goog-Api-Key"], "vision-key-123");
  assert(!r.url.includes("vision-key-123"));
  assertEquals(JSON.parse(r.body), { requests: [{ image: { content: "AQID" }, features: [{ type: "TEXT_DETECTION" }] }] });
});

Deno.test("Vision's answers", () => {
  assertEquals(readVision(200, { responses: [{ fullTextAnnotation: { text: "A\nB" } }] }), { text: "A\nB" });
  assertEquals(readVision(200, { responses: [{ textAnnotations: [{ description: "C" }] }] }), { text: "C" });
  assertEquals(readVision(200, { responses: [{}] }), { text: "" });
  assertEquals(
    readVision(403, { error: { status: "PERMISSION_DENIED", message: "x", details: [{ reason: "SERVICE_DISABLED" }] } }),
    { error: "The Cloud Vision API isn't enabled for the key's project" },
  );
  assertEquals(readVision(400, { error: { status: "INVALID_ARGUMENT", details: [{ reason: "API_KEY_INVALID" }] } }), {
    error: "Google doesn't know the Vision key",
  });
  assertEquals(readVision(200, { responses: [{ error: { message: "Bad image data." } }] }), {
    error: "Google Vision: Bad image data.",
  });
});

Deno.test("the person reads their own ID, waiting for review, once", async () => {
  const { d, calls } = deps();
  const r = await handleIdRead({ check_id: ID }, "Bearer u1", d);
  assertEquals(r.status, 200);
  assertEquals(r.body, {
    state: "read",
    name: "AINA BINTI AHMAD",
    ic: "880202-10-1234",
    passport: null,
    expiry: null,
    mismatch: [],
  });
  assertEquals(calls, ["annotate vision-key-123", `store ${ID} AINA BINTI AHMAD 880202-10-1234`]);

  const again = deps({ check: () => Promise.resolve({ ...card, read_source: "vision" }) });
  assertEquals((await handleIdRead({ check_id: ID }, "Bearer u1", again.d)).body, { error: "already_read" });
  assertEquals(again.calls, []);
  const decided = deps({ check: () => Promise.resolve({ ...card, status: "Approved" }) });
  assertEquals((await handleIdRead({ check_id: ID }, "Bearer u1", decided.d)).status, 409);
});

Deno.test("on the phone only: the person can't ask Vision", async () => {
  const { d, calls } = deps({ verifySettings: () => Promise.resolve({ idRead: "phone" }) });
  assertEquals(await handleIdRead({ check_id: ID }, "Bearer u1", d), { status: 403, body: { error: "vision_off" } });
  assertEquals(calls, []);
});

Deno.test("someone else's ID: admins with Documents only", async () => {
  const other = deps();
  assertEquals(await handleIdRead({ check_id: ID }, "Bearer u2", other.d), { status: 403, body: { error: "not_authorized" } });
  assertEquals(other.calls, []);
  // A missing check reads the same to them.
  assertEquals((await handleIdRead({ check_id: "00000000-0000-0000-0000-000000000000" }, "Bearer u2", other.d)).status, 403);

  // The admin reads it again, whatever the setting and the status.
  const admin = deps({
    verifySettings: () => Promise.resolve({ idRead: "phone" }),
    check: () => Promise.resolve({ ...card, status: "Approved", read_source: "vision" }),
  });
  assertEquals((await handleIdRead({ check_id: ID }, "Bearer admin", admin.d)).body.state, "read");
  assertEquals((await handleIdRead({ check_id: "00000000-0000-0000-0000-000000000000" }, "Bearer admin", deps().d)).status, 404);
});

Deno.test("no session, a bad id, a selfie", async () => {
  const { d } = deps();
  assertEquals((await handleIdRead({ check_id: ID }, null, d)).status, 401);
  assertEquals((await handleIdRead({ check_id: "nope" }, "Bearer u1", d)).status, 400);
  const selfie = deps({ check: () => Promise.resolve({ ...card, kind: "selfie" }) });
  assertEquals((await handleIdRead({ check_id: ID }, "Bearer u1", selfie.d)).body, { error: "not_an_id" });
});

Deno.test("without a key, a photo or any text", async () => {
  const noKey = deps({ apiProviders: () => Promise.resolve([]) });
  assertEquals((await handleIdRead({ check_id: ID }, "Bearer u1", noKey.d)).body, { state: "not_read", reason: "no_key" });
  assertEquals(noKey.calls, []);
  const noPhoto = deps({ download: () => Promise.resolve(null) });
  assertEquals((await handleIdRead({ check_id: ID }, "Bearer u1", noPhoto.d)).body.reason, "no_photo");
  const blank = deps({ annotate: () => Promise.resolve({ status: 200, body: { responses: [{}] } }) });
  const r = await handleIdRead({ check_id: ID }, "Bearer u1", blank.d);
  assertEquals([r.body.state, r.body.reason], ["not_read", "nothing_found"]);
  assertEquals(blank.calls, [`store ${ID} null null`], "the read is spent even so");
  const off = deps({
    annotate: () => Promise.resolve({ status: 403, body: { error: { details: [{ reason: "SERVICE_DISABLED" }] } } }),
  });
  assertEquals((await handleIdRead({ check_id: ID }, "Bearer u1", off.d)).body, {
    state: "error",
    detail: "The Cloud Vision API isn't enabled for the key's project",
  });
});

Deno.test("a failure on the way is unavailable", async () => {
  const { d } = deps({ store: () => Promise.reject(new Error("db down")) });
  assertEquals((await handleIdRead({ check_id: ID }, "Bearer u1", d)).status, 503);
});

// ---- 0288: partner registration documents -----------------------------------------------------------

const REG_URL = "https://x.supabase.co/storage/v1/object/public/provider-documents/p1/company/front-1.jpg";
function regDeps(over: Partial<RegistrationReadDeps> = {}) {
  const spent: string[] = [];
  const d: RegistrationReadDeps = {
    caller: (a) => Promise.resolve(a === "Bearer u1" ? "u1" : null),
    owns: (uid, bucket, path) => Promise.resolve(uid === "u1" && bucket === "provider-documents" && path.startsWith("p1/")),
    spend: (uid) => {
      spent.push(uid);
      return Promise.resolve(spent.length <= 2);
    },
    verifySettings: () => Promise.resolve({ idRead: "phone_vision" }),
    apiProviders: () =>
      Promise.resolve([{ id: "google", services: [{ id: "vision", keys: [{ id: "g1", value: "AIzaTEST" }] }] }]),
    download: () => Promise.resolve(new Uint8Array([1, 2, 3])),
    annotate: () =>
      Promise.resolve({ status: 200, body: { responses: [{ fullTextAnnotation: { text: "Company Name : X SDN BHD" } }] } }),
    ...over,
  };
  return { d, spent };
}
const reg = (url = REG_URL) => ({ file_url: url, purpose: "registration" });

Deno.test("registration: the request says its purpose", () => {
  assertEquals(isRegistrationRead(reg()), true);
  assertEquals(isRegistrationRead({ check_id: "x" }), false);
});

Deno.test("registration: the person's own file, as text", async () => {
  const { d } = regDeps();
  const r = await handleRegistrationRead(reg(), "Bearer u1", d);
  assertEquals(r, { status: 200, body: { state: "read", text: "Company Name : X SDN BHD" } });
});

Deno.test("registration: someone else's file, no session, phone only, too many", async () => {
  assertEquals((await handleRegistrationRead(reg(), null, regDeps().d)).status, 401);
  const other = REG_URL.replace("/p1/", "/p2/");
  assertEquals((await handleRegistrationRead(reg(other), "Bearer u1", regDeps().d)).body, { error: "not_authorized" });
  assertEquals((await handleRegistrationRead(reg("https://elsewhere/x.jpg"), "Bearer u1", regDeps().d)).status, 400);
  const phone = regDeps({ verifySettings: () => Promise.resolve({ idRead: "phone" }) });
  assertEquals((await handleRegistrationRead(reg(), "Bearer u1", phone.d)).body, { error: "vision_off" });
  const many = regDeps();
  await handleRegistrationRead(reg(), "Bearer u1", many.d);
  await handleRegistrationRead(reg(), "Bearer u1", many.d);
  assertEquals((await handleRegistrationRead(reg(), "Bearer u1", many.d)).status, 429);
});
