import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import { hmacSha256Hex } from "./payments/crypto.ts";
import { applyPayload, createBody, docTypeOf, ekycServer, ekycWebhookSecrets, webhookSignatureValid } from "./ekyc.ts";

const providers = [
  { id: "face_match", services: [{ id: "server", keys: [{ value: "https://face.example:abcdefghijklmnop1" }] }] },
  {
    id: "ekyc",
    services: [
      { id: "server", keys: [{ value: "https://old.example:ek_disabledkey12345678", disabled: true }, { value: "https://ekyc.getcdn.link:ek_abcdefghijklmnopqrstuv" }] },
      { id: "webhook", keys: [{ value: "short" }, { value: "whsec-0123456789abcdef" }] },
    ],
  },
];

Deno.test("the server key and webhook secrets come from Admin → API Keys", () => {
  assertEquals(ekycServer(providers), { url: "https://ekyc.getcdn.link", secret: "ek_abcdefghijklmnopqrstuv" });
  assertEquals(ekycServer({ providers }), ekycServer(providers));
  assertEquals(ekycServer([]), null);
  assertEquals(ekycWebhookSecrets(providers), ["whsec-0123456789abcdef"]);
});

Deno.test("webhook signatures: right secret, fresh, untampered", async () => {
  const body = '{"event":"verification.completed","id":"ver_1"}';
  const ts = "1764000000";
  const sig = "sha256=" + await hmacSha256Hex("whsec-0123456789abcdef", `${ts}.${body}`);
  const secrets = ["other-secret-000000000", "whsec-0123456789abcdef"];
  assert(await webhookSignatureValid(body, ts, sig, secrets, 1764000100));
  assert(!await webhookSignatureValid(body + " ", ts, sig, secrets, 1764000100), "body changed");
  assert(!await webhookSignatureValid(body, ts, sig, ["nope-nope-nope-nope"], 1764000100), "wrong secret");
  assert(!await webhookSignatureValid(body, ts, sig, secrets, 1764000000 + 301), "too old");
  assert(!await webhookSignatureValid(body, null, sig, secrets, 1764000100), "no timestamp");
  assert(!await webhookSignatureValid(body, ts, "sha256=zz", secrets, 1764000100), "garbage signature");
});

Deno.test("what get.ekyc is asked for", () => {
  const b = createBody("user-1", "rider_gate", false);
  assertEquals(b.external_ref, "user-1");
  assertEquals(b.document_type, "auto");
  assertEquals(b.require_liveness, true);
  assertEquals(b.redirect_url, "getride://ekyc/rider");
  assertEquals(createBody("u", "first", true).test, true);
});

Deno.test("every identity document keeps its own type (0441)", () => {
  assertEquals(docTypeOf({ document_type: "national_id", country: "MYS", document_subtype: "MyKAS" }), "mykas");
  assertEquals(docTypeOf({ document_type: "national_id", country: "MYS", document_subtype: "MyTentera" }), "mytentera");
  assertEquals(docTypeOf({ document_type: "national_id", country: "SGP", document_subtype: "NRIC/FIN" }), "id_card");
  assertEquals(docTypeOf({ document_type: "foreign_worker_card" }), "ikad");
  assertEquals(docTypeOf({ document_type: "refugee_card" }), "unhcr");
  assertEquals(docTypeOf({ document_type: "residence_permit" }), "residence_permit");
  assertEquals(docTypeOf({ document_type: "vehicle_registration" }), null);
  const lic = applyPayload({ status: "approved", result: { extracted: {
    document_type: "driving_licence", country: "MYS", full_name: "AHMAD BIN ALI", id_number: "900514-10-5231",
    date_of_birth: "1990-05-14", sex: "M", expiry_date: "2029-05-11" } } }, { front: "u/f.jpg" });
  assertEquals([lic.doc_type, (lic.read as Record<string, unknown>).ic, (lic.read as Record<string, unknown>).name],
    ["driving_licence", "900514-10-5231", "AHMAD BIN ALI"]);
  const ikad = applyPayload({ status: "review", result: { extracted: {
    document_type: "foreign_worker_card", full_name: "RAHUL KUMAR", document_number: "N1234567", nationality: "IND" } } },
    { front: "u/f.jpg" });
  const r = ikad.read as Record<string, unknown>;
  assertEquals([ikad.doc_type, r.passport, r.ic, r.nationality], ["ikad", "N1234567", null, "IND"]);
});

Deno.test("document types map to the check's doc_type", () => {
  assertEquals(docTypeOf({ document_type: "national_id", country: "MYS", document_subtype: "MyKad" }), "mykad");
  assertEquals(docTypeOf({ document_type: "national_id", country: "MYS", document_subtype: "MyPR" }), "mypr");
  assertEquals(docTypeOf({ document_type: "national_id", country: "IDN" }), "id_card");
  assertEquals(docTypeOf({ document_type: "passport", country: "GBR" }), "passport");
  assertEquals(docTypeOf({ document_type: "driving_licence" }), "driving_licence");
});

Deno.test("a MyKad result becomes the check's fields", () => {
  const p = applyPayload({
    status: "approved",
    reasons: [],
    result: {
      extracted: {
        document_type: "national_id", country: "MYS", document_subtype: "MyKad", citizenship: "citizen",
        full_name: "KABEER SINGH MAAND A/L GESWANT SINGH", id_number: "830825-08-6367", date_of_birth: "1983-08-25",
        sex: "M", address: "12 JALAN MAWAR, 30000 IPOH, PERAK",
      },
      checks: [{ name: "face_match", status: "pass" }, { name: "liveness", status: "pass" }],
      scores: { face_match: 0.71, face_score: 92 },
    },
  }, { front: "u/signin/ekyc_front.jpg", back: "u/signin/ekyc_back.jpg", selfie: "u/signin/ekyc_selfie.jpg" });
  assertEquals(p.status, "approved");
  assertEquals(p.doc_type, "mykad");
  assertEquals(p.read, {
    name: "KABEER SINGH MAAND A/L GESWANT SINGH", ic: "830825-08-6367", passport: null, birth: "1983-08-25",
    expiry: null, nationality: "MYS", gender: "male", address: "12 JALAN MAWAR, 30000 IPOH, PERAK",
  });
  assertEquals(p.face, { score: 92, state: "match" });
  assertEquals(p.liveness, "passed");
  assertEquals(p.back, "u/signin/ekyc_back.jpg");
});

// ---- 0447: GET.ocr reads a MyKad's fields, GET.eKYC keeps the verdict -----------------------------

Deno.test("GET.ocr's MyKad read replaces GET.eKYC's fields; the verdict stays GET.eKYC's", () => {
  const p = applyPayload({
    status: "approved",
    reasons: [],
    result: {
      extracted: {
        document_type: "national_id", country: "MYS", document_subtype: "MyKad", citizenship: "citizen",
        // GET.eKYC's own extraction cut the two-line name and dropped the address.
        full_name: "KABEER SINGH MAAND A/L", id_number: "830825-08-6367", date_of_birth: "1983-08-25", sex: "M",
      },
      checks: [{ name: "face_match", status: "pass" }, { name: "liveness", status: "pass" }],
      scores: { face_score: 92 },
    },
  }, { front: "u/signin/ekyc_front.jpg", selfie: "u/signin/ekyc_selfie.jpg" }, {
    // GET.ocr read the card by position: the full name and the address intact.
    name: "KABEER SINGH MAAND A/L GESWANT SINGH", ic: "830825-08-6367", birth: "1983-08-25",
    gender: "male", nationality: "MYS", address: "12 JALAN MAWAR, 30000 IPOH, PERAK",
  });
  assertEquals(p.read, {
    name: "KABEER SINGH MAAND A/L GESWANT SINGH", ic: "830825-08-6367", passport: null, birth: "1983-08-25",
    expiry: null, nationality: "MYS", gender: "male", address: "12 JALAN MAWAR, 30000 IPOH, PERAK",
  });
  // The verdict, face match and liveness are untouched — GET.eKYC still decides.
  assertEquals([p.status, p.doc_type], ["approved", "mykad"]);
  assertEquals(p.face, { score: 92, state: "match" });
  assertEquals(p.liveness, "passed");
});

Deno.test("no MyKad override → GET.eKYC's own fields, exactly as before", () => {
  const base = {
    status: "approved",
    result: {
      extracted: {
        document_type: "national_id", country: "MYS", document_subtype: "MyKad", citizenship: "citizen",
        full_name: "SITI BINTI YUSOF", id_number: "900101-14-5678", date_of_birth: "1990-01-01", sex: "F",
        address: "1 JALAN A",
      },
    },
  };
  const absent = applyPayload(base, { front: "u/f.jpg" });
  const asNull = applyPayload(base, { front: "u/f.jpg" }, null);
  assertEquals(absent.read, asNull.read, "a null override is the same as none");
  assertEquals((absent.read as Record<string, unknown>).name, "SITI BINTI YUSOF");
  assertEquals((absent.read as Record<string, unknown>).gender, "female");
});

Deno.test("a passport in review, face uncertain, liveness failed", () => {
  const p = applyPayload({
    status: "review",
    reasons: ["face_match_uncertain", "liveness_challenge_failed", 7],
    result: {
      extracted: { document_type: "passport", document_number: "A12345678", nationality: "GBR", sex: "F", expiry_date: "2031-01-31" },
      checks: [{ name: "face_match", status: "review" }, { name: "liveness", status: "fail" }],
      scores: { face_score: 74 },
    },
  }, { front: "u/f.jpg" });
  assertEquals(p.reasons, ["face_match_uncertain", "liveness_challenge_failed"]);
  const read = p.read as Record<string, unknown>;
  assertEquals([read.ic, read.passport, read.nationality, read.gender, read.expiry], [null, "A12345678", "GBR", "female", "2031-01-31"]);
  assertEquals(p.face, { score: 74, state: "no_match" });
  assertEquals(p.liveness, "not_checked");
  assertEquals(p.selfie, null);
});

Deno.test("no face found on the card", () => {
  const p = applyPayload({ status: "review", result: { checks: [{ name: "face_match", status: "skipped", code: "face_missing" }] } }, { front: "u/f.jpg" });
  assertEquals(p.face, { score: null, state: "no_face" });
});
