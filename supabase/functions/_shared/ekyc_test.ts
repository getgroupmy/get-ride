import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import { hmacSha256Hex } from "./payments/crypto.ts";
import { applyPayload, createBody, docTypeOf, ekycServer, ekycWebhookSecrets, webhookSignatureValid } from "./ekyc.ts";

const providers = [
  { id: "face_match", services: [{ id: "server", keys: [{ value: "https://face.example:abcdefghijklmnop1" }] }] },
  {
    id: "ekyc",
    services: [
      { id: "server", keys: [{ value: "https://old.example:ek_disabledkey12345678", disabled: true }, { value: "https://ekyc.getride.my:ek_abcdefghijklmnopqrstuv" }] },
      { id: "webhook", keys: [{ value: "short" }, { value: "whsec-0123456789abcdef" }] },
    ],
  },
];

Deno.test("the server key and webhook secrets come from Admin → API Keys", () => {
  assertEquals(ekycServer(providers), { url: "https://ekyc.getride.my", secret: "ek_abcdefghijklmnopqrstuv" });
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

Deno.test("document types map to the check's doc_type", () => {
  assertEquals(docTypeOf({ document_type: "national_id", country: "MYS", document_subtype: "MyKad" }), "mykad");
  assertEquals(docTypeOf({ document_type: "national_id", country: "MYS", document_subtype: "MyPR" }), "id_card");
  assertEquals(docTypeOf({ document_type: "national_id", country: "IDN" }), "id_card");
  assertEquals(docTypeOf({ document_type: "passport", country: "GBR" }), "passport");
  // A driving licence is accepted as an identity document (any spelling).
  assertEquals(docTypeOf({ document_type: "driving_licence" }), "licence");
  assertEquals(docTypeOf({ document_type: "driving_license" }), "licence");
  assertEquals(docTypeOf({ document_type: "drivers_license" }), "licence");
  // Still null for something that is not an identity document.
  assertEquals(docTypeOf({ document_type: "utility_bill" }), null);
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
    name: "KABEER SINGH MAAND A/L GESWANT SINGH", ic: "830825-08-6367", passport: null, licence: null, birth: "1983-08-25",
    expiry: null, nationality: "MYS", gender: "male", address: "12 JALAN MAWAR, 30000 IPOH, PERAK",
  });
  assertEquals(p.face, { score: 92, state: "match" });
  assertEquals(p.liveness, "passed");
  assertEquals(p.back, "u/signin/ekyc_back.jpg");
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

Deno.test("a driving licence becomes the check's fields", () => {
  const p = applyPayload({
    status: "approved",
    result: {
      extracted: {
        document_type: "driving_licence", country: "MYS",
        full_name: "SITI NURHALIZA BINTI TARUDIN", id_number: "870101-10-5566",
        document_number: "870101105566", date_of_birth: "1987-01-01", sex: "F",
        expiry_date: "2027-01-01", address: "5 JALAN DAMAI, 50000 KUALA LUMPUR",
      },
      checks: [{ name: "face_match", status: "pass" }, { name: "liveness", status: "pass" }],
      scores: { face_score: 90 },
    },
  }, { front: "u/signin/ekyc_front.jpg", selfie: "u/signin/ekyc_selfie.jpg" });
  assertEquals(p.doc_type, "licence");
  const read = p.read as Record<string, unknown>;
  // The licence number is kept in its own field, the IC in ic, passport null.
  assertEquals([read.licence, read.ic, read.passport], ["870101105566", "870101-10-5566", null]);
  assertEquals([read.name, read.birth, read.expiry, read.gender], ["SITI NURHALIZA BINTI TARUDIN", "1987-01-01", "2027-01-01", "female"]);
  // A licence does not assert citizenship: nationality stays null unless the
  // document itself carries it (Part B's citizen rule relies on this).
  assertEquals(read.nationality, null);
});

Deno.test("no face found on the card", () => {
  const p = applyPayload({ status: "review", result: { checks: [{ name: "face_match", status: "skipped", code: "face_missing" }] } }, { front: "u/f.jpg" });
  assertEquals(p.face, { score: null, state: "no_face" });
});
