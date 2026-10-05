/**
 * What the document-ai-verify function decides before and after the network.
 *
 *     deno test supabase/functions/_shared/doc_ai_test.ts
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import {
  bearerToken,
  buildUserText,
  DEFAULT_VISION_MODELS,
  isVisionProvider,
  MAX_IMAGE_BYTES,
  normalizeResult,
  normDate,
  parseContext,
  parseImage,
  responseText,
  TAXI_PERMIT_INSTRUCTIONS,
  visionRequest,
} from "./doc_ai.ts";

const PNG = "data:image/png;base64,iVBORw0KGgo=";
const now = new Date("2026-10-05T03:00:00Z");

Deno.test("images: only small base64 data URLs of photo types", () => {
  assertEquals(parseImage(PNG), { mime: "image/png", base64: "iVBORw0KGgo=" });
  assertEquals(parseImage("https://example.com/id.jpg"), "image must be a base64 data URL");
  assertEquals(parseImage("data:application/pdf;base64,AAAA"), "unsupported image type application/pdf");
  assertEquals(parseImage(""), "image missing");
  assertEquals(parseImage(42), "image missing");
  const big = "data:image/jpeg;base64," + "A".repeat(Math.ceil((MAX_IMAGE_BYTES + 10) * 4 / 3));
  assertEquals(parseImage(big), "image is too large");
});

Deno.test("context: needs a title, keeps only the prompt's fields, bounded", () => {
  assertEquals(parseContext(null), null);
  assertEquals(parseContext({ docName: "  " }), null);
  const c = parseContext({ docName: "Driving Licence", documentNumber: "x".repeat(500), isPwd: "yes", isTaxiPermit: true })!;
  assertEquals(c.docName, "Driving Licence");
  assertEquals(c.documentNumber!.length, 120);
  assertEquals(c.isPwd, false);
  assertEquals(c.isTaxiPermit, true);
});

Deno.test("prompt text matches Expo's", () => {
  const t = buildUserText({ docName: "Driving Licence", documentNumber: "D123", isPwd: true }, true);
  assertStringIncludes(t, 'Target document title: "Driving Licence".');
  assertStringIncludes(t, 'Partner says the document number is "D123".');
  assertStringIncludes(t, "PWD");
  assertStringIncludes(t, "Image 1 is the FRONT, image 2 is the BACK.");
  assert(!t.includes("TAXI DRIVER PERMIT"));
  const permit = buildUserText({ docName: "Permit", isTaxiPermit: true }, false);
  assertStringIncludes(permit, TAXI_PERMIT_INSTRUCTIONS);
  assertStringIncludes(permit, "Only the FRONT side was provided.");
});

Deno.test("vision providers and their request shapes", () => {
  assert(isVisionProvider("gemini"));
  assert(isVisionProvider("claude"));
  assert(!isVisionProvider("groq"));
  assert(!isVisionProvider("deepseek"));
  const img = { mime: "image/jpeg", base64: "QUJD" };

  const g = visionRequest("gemini", DEFAULT_VISION_MODELS.gemini, "k1", "hello", [img, img]);
  assertStringIncludes(g.url, "gemini-2.5-flash:generateContent?key=k1");
  // deno-lint-ignore no-explicit-any
  const gp = (g.body as any).contents[0].parts;
  assertEquals(gp[0], { text: "hello" });
  assertEquals(gp[1], { inline_data: { mime_type: "image/jpeg", data: "QUJD" } });
  assertEquals(gp.length, 3);

  const c = visionRequest("claude", "m", "k2", "hello", [img]);
  assertEquals(c.headers["x-api-key"], "k2");
  // deno-lint-ignore no-explicit-any
  assertEquals((c.body as any).messages[0].content[0].source, { type: "base64", media_type: "image/jpeg", data: "QUJD" });

  const o = visionRequest("chatgpt", "gpt-4o-mini", "k3", "hello", [img]);
  assertEquals(o.url, "https://api.openai.com/v1/chat/completions");
  assertEquals(o.headers.Authorization, "Bearer k3");
  // deno-lint-ignore no-explicit-any
  assertEquals((o.body as any).messages[1].content[1].image_url.url, "data:image/jpeg;base64,QUJD");
});

Deno.test("answer text per provider", () => {
  assertEquals(responseText("gemini", { candidates: [{ content: { parts: [{ text: "{" }, { text: "}" }] } }] }), "{}");
  assertEquals(responseText("claude", { content: [{ type: "text", text: "{}" }] }), "{}");
  assertEquals(responseText("chatgpt", { choices: [{ message: { content: "{}" } }] }), "{}");
  assertEquals(responseText("chatgpt", { choices: [] }), null);
});

Deno.test("normalises the answer like Expo did", () => {
  const raw = "```json\n" + JSON.stringify({
    isReal: true,
    isRelevant: true,
    detectedTitle: "Malaysian Driving Licence",
    confidence: 1.7,
    reason: "Looks genuine.",
    extracted: {
      documentNumber: " D1234567 ",
      documentNumbers: ["D1234567", "D1234567", "", "REF-9", 7],
      startDate: "2024-01-31",
      expiryDate: "31 Jan 2029",
      isPwd: false,
      taxiPermit: { name: "Ali" },
    },
  }) + "\n```";
  const r = normalizeResult(raw, { docName: "Driving Licence" }, now)!;
  assertEquals(r.matchesTitle, true, "defaults to real AND relevant");
  assertEquals(r.confidence, 1);
  assertEquals(r.extracted.documentNumber, "D1234567");
  assertEquals(r.extracted.documentNumbers, ["D1234567", "REF-9"]);
  assertEquals(r.extracted.startDate, "2024-01-31");
  assertEquals(r.extracted.expiryDate, "2029-01-31");
  assertEquals(r.extracted.insuranceProviderName, null);
  assertEquals(r.extracted.taxiPermit, null, "only read for a permit");
  assertEquals(r.verifiedAt, "2026-10-05T03:00:00.000Z");
  assertEquals(normalizeResult("no json here", { docName: "x" }, now), null);
  assertEquals(normalizeResult("{not json}", { docName: "x" }, now), null);
});

Deno.test("taxi permit fields and the portrait box", () => {
  const raw = JSON.stringify({
    isReal: true,
    isRelevant: true,
    matchesTitle: true,
    extracted: {
      taxiPermit: {
        name: "Ali bin Abu",
        validityTo: "2027-06-30",
        hasImageOnPermit: true,
        photoBox: { x: -0.2, y: 0.1, width: 0.3, height: 1.5 },
        hasQrCode: "yes",
      },
    },
  });
  const p = normalizeResult(raw, { docName: "Permit", isTaxiPermit: true }, now)!.extracted.taxiPermit!;
  assertEquals(p.name, "Ali bin Abu");
  assertEquals(p.validityTo, "2027-06-30");
  assertEquals(p.photoBox, { x: 0, y: 0.1, width: 0.3, height: 1 });
  assertEquals(p.hasQrCode, null);
  assertEquals(p.photoUrl, null);
});

Deno.test("dates and the bearer token", () => {
  assertEquals(normDate("2025-02-03"), "2025-02-03");
  assertEquals(normDate("not a date"), null);
  assertEquals(normDate(null), null);
  assertEquals(bearerToken("Bearer abc.def"), "abc.def");
  assertEquals(bearerToken("abc"), null);
  assertEquals(bearerToken(null), null);
});
