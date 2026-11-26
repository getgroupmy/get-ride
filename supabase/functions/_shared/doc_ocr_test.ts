import { assertEquals } from "jsr:@std/assert@1.0.19";

import { isOcrReader, ocrRequest, ocrServer, readOcr } from "./doc_ocr.ts";

const OCR_SECRET = "ocr_live_0123456789abcdef";
const providers = [
  { id: "face_match", services: [{ id: "server", keys: [{ value: "https://face.example:abcdefghijklmnop1" }] }] },
  {
    id: "ocr",
    services: [
      {
        id: "server",
        keys: [
          { value: "https://old.example:ocr_disabledkey12345678", disabled: true },
          { value: `https://ocr.getcdn.link:${OCR_SECRET}` },
        ],
      },
    ],
  },
];

Deno.test("ocrServer: the address and key from Admin → API Keys → GET OCR", () => {
  assertEquals(ocrServer(providers), { url: "https://ocr.getcdn.link", secret: OCR_SECRET });
  assertEquals(ocrServer({ providers }), ocrServer(providers));
  assertEquals(ocrServer([]), null);
  assertEquals(ocrServer([{ id: "ocr", services: [{ id: "server", keys: [{ value: "AIzaNotAServerKey" }] }] }]), null);
  assertEquals(ocrServer(null), null);
});

Deno.test("ocrRequest: POST /v1/ocr, base64 JSON, detail text, X-API-Key", () => {
  const r = ocrRequest({ url: "https://ocr.getcdn.link", secret: OCR_SECRET }, new Uint8Array([1, 2, 3, 4]));
  assertEquals(r.url, "https://ocr.getcdn.link/v1/ocr");
  assertEquals(r.method, "POST");
  assertEquals(r.headers["X-API-Key"], OCR_SECRET);
  assertEquals(r.headers["Content-Type"], "application/json");
  const body = JSON.parse(r.body);
  assertEquals(body.detail, "text");
  assertEquals(body.file, "AQIDBA==");
});

Deno.test("readOcr: the full text on success, a short reason on failure", () => {
  assertEquals(readOcr(200, { text: "KAD PENGENALAN\n\nAHMAD BIN ALI", pages: [], duration_ms: 7 }), {
    text: "KAD PENGENALAN\n\nAHMAD BIN ALI",
  });
  assertEquals(readOcr(200, { pages: [] }), { text: "" }, "no text in the answer");
  assertEquals(readOcr(401, { error: "unauthorized", message: "invalid or missing X-API-Key" }), {
    error: "GET OCR: invalid or missing X-API-Key",
  });
  assertEquals(readOcr(503, null), { error: "GET OCR: HTTP 503" });
});

Deno.test("isOcrReader: only when the reader is getOcr", () => {
  assertEquals(isOcrReader({ file_url: "x", purpose: "registration", reader: "getOcr" }), true);
  assertEquals(isOcrReader({ file_url: "x", purpose: "registration" }), false, "the Vision registration read");
  assertEquals(isOcrReader({ reader: "cloud" }), false);
  assertEquals(isOcrReader(null), false);
});
