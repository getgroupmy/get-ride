import { assertEquals } from "jsr:@std/assert@1.0.19";

import {
  isMyKadNumber,
  isOcrReader,
  mykadFromExtract,
  ocrExtractRequest,
  ocrRequest,
  ocrServer,
  readOcr,
  readOcrExtract,
  readTypedExtract,
  serverReaders,
  typedExtractRequest,
} from "./doc_ocr.ts";

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

Deno.test("ocrServer: the address and key from Admin → API Keys → GET.ocr", () => {
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
    error: "GET.ocr: invalid or missing X-API-Key",
  });
  assertEquals(readOcr(503, null), { error: "GET.ocr: HTTP 503" });
});

Deno.test("isOcrReader: only when the reader is getOcr", () => {
  assertEquals(isOcrReader({ file_url: "x", purpose: "registration", reader: "getOcr" }), true);
  assertEquals(isOcrReader({ file_url: "x", purpose: "registration" }), false, "the Vision registration read");
  assertEquals(isOcrReader({ reader: "cloud" }), false);
  assertEquals(isOcrReader(null), false);
});

Deno.test("serverReaders: the on server readers in order, get.ocr first by default", () => {
  // An absent or unreadable config falls back to get.ocr first, then Vision.
  assertEquals(serverReaders(null), ["getOcr", "cloud"]);
  assertEquals(serverReaders({}), ["getOcr", "cloud"]);
  assertEquals(serverReaders({ readers: "x" }), ["getOcr", "cloud"]);
  // The full default chain: only get.ocr and the cloud read a stored image here.
  assertEquals(
    serverReaders({
      readers: [
        { id: "getOcr", on: true },
        { id: "phone", on: true },
        { id: "nas", on: true },
        { id: "gpu", on: true },
        { id: "cloud", on: true },
      ],
    }),
    ["getOcr", "cloud"],
  );
  assertEquals(
    serverReaders({ readers: [{ id: "getOcr", on: false }, { id: "cloud", on: true }] }),
    ["cloud"],
    "get.ocr off: Vision only",
  );
  assertEquals(
    serverReaders({ readers: [{ id: "cloud", on: true }, { id: "getOcr", on: true }] }),
    ["cloud", "getOcr"],
    "the admin's order is kept",
  );
  assertEquals(serverReaders({ readers: [{ id: "getOcr", on: false }, { id: "cloud", on: false }] }), []);
});

Deno.test("ocrExtractRequest: POST /v1/extract, type=custom, fields as JSON", () => {
  const r = ocrExtractRequest({ url: "https://ocr.getcdn.link", secret: OCR_SECRET }, "YWJj", {
    plate: "string",
    seats: "number",
  });
  assertEquals(r.url, "https://ocr.getcdn.link/v1/extract");
  assertEquals(r.method, "POST");
  assertEquals(r.headers["X-API-Key"], OCR_SECRET);
  const body = JSON.parse(r.body);
  assertEquals(body.file, "YWJj");
  assertEquals(body.type, "custom");
  assertEquals(JSON.parse(body.fields), { plate: "string", seats: "number" });
});

Deno.test("readOcrExtract: the fields map, from the top level or the first document", () => {
  assertEquals(readOcrExtract(200, { fields: { plate: "WXY 1234", make: "Perodua" }, pages: [] }), {
    fields: { plate: "WXY 1234", make: "Perodua" },
  });
  assertEquals(readOcrExtract(200, { documents: [{ fields: { plate: "ABC 1" } }, { fields: {} }] }), {
    fields: { plate: "ABC 1" },
  }, "the first of several documents");
  assertEquals(readOcrExtract(200, { pages: [] }), { fields: {} }, "nothing extracted");
  assertEquals(readOcrExtract(401, { error: "unauthorized", message: "invalid or missing X-API-Key" }), {
    error: "GET.ocr: invalid or missing X-API-Key",
  });
  assertEquals(readOcrExtract(503, null), { error: "GET.ocr: HTTP 503" });
});

Deno.test("typedExtractRequest: POST /v1/extract naming a built-in type, no field spec", () => {
  const r = typedExtractRequest({ url: "https://ocr.getcdn.link", secret: OCR_SECRET }, "YWJj", "mykad");
  assertEquals(r.url, "https://ocr.getcdn.link/v1/extract");
  assertEquals(r.method, "POST");
  assertEquals(r.headers["X-API-Key"], OCR_SECRET);
  assertEquals(JSON.parse(r.body), { file: "YWJj", type: "mykad" });
});

Deno.test("readTypedExtract: the fields and read_by, or a short reason", () => {
  assertEquals(
    readTypedExtract(200, { document_type: "mykad", read_by: "labels", model_calls: 0, fields: { name: "AHMAD" } }),
    { fields: { name: "AHMAD" }, readBy: "labels" },
  );
  assertEquals(readTypedExtract(200, { read_by: "model", fields: {} }), { fields: {}, readBy: "model" });
  assertEquals(readTypedExtract(200, { fields: "x" }), { fields: {}, readBy: "" }, "no usable fields or read_by");
  assertEquals(readTypedExtract(503, null), { error: "GET.ocr: HTTP 503" });
});

Deno.test("isMyKadNumber: 12 digits, dashes optional", () => {
  assertEquals(isMyKadNumber("850412-10-5759"), true);
  assertEquals(isMyKadNumber("850412105759"), true);
  assertEquals(isMyKadNumber("A1234567"), false, "a passport number");
  assertEquals(isMyKadNumber("85041210575"), false, "11 digits");
  assertEquals(isMyKadNumber(null), false);
  assertEquals(isMyKadNumber(123), false, "not a string");
});

Deno.test("mykadFromExtract: GET.ocr's position read mapped to id-read's answer", () => {
  assertEquals(
    mykadFromExtract("labels", {
      id_number: "850412-10-5759",
      name: "RAVI A/L MUTHUSAMY",
      address: "NO 70 LADANG, TANJUNG BARU, JALAN SINTOK, 06010 CHANGLUN, KEDAH",
      date_of_birth: "1985-04-12",
      gender: "male",
      citizenship: "WARGANEGARA",
      religion: "HINDU",
    }),
    {
      name: "RAVI A/L MUTHUSAMY",
      ic: "850412-10-5759",
      birth: "1985-04-12",
      gender: "male",
      nationality: "MYS",
      address: "NO 70 LADANG, TANJUNG BARU, JALAN SINTOK, 06010 CHANGLUN, KEDAH",
      expiry: null,
    },
  );
});

Deno.test("mykadFromExtract: null (falls back to text) unless the reader followed the card", () => {
  const ok = { id_number: "850412105759", name: "AHMAD BIN ALI" };
  assertEquals(mykadFromExtract("model", ok), null, "GET.ocr used its model");
  assertEquals(mykadFromExtract("", ok), null, "no read_by");
  assertEquals(mykadFromExtract("labels", { name: "AHMAD BIN ALI" }), null, "no number");
  assertEquals(mykadFromExtract("labels", { id_number: "850412105759" }), null, "no name");
  assertEquals(mykadFromExtract("labels", { id_number: "8504", name: "AHMAD" }), null, "not a MyKad number");
});

Deno.test("mykadFromExtract: a non-citizen has no MYS nationality; gender letters and bad dates", () => {
  const base = { id_number: "900101105678", name: "TAN MEI LING" };
  assertEquals(mykadFromExtract("labels", { ...base, citizenship: "BUKAN WARGANEGARA" })?.nationality, null);
  assertEquals(mykadFromExtract("labels", { ...base, gender: "female" })?.gender, "female");
  assertEquals(mykadFromExtract("labels", { ...base, gender: "F" })?.gender, "female");
  assertEquals(mykadFromExtract("labels", { ...base, gender: "M" })?.gender, "male");
  assertEquals(mykadFromExtract("labels", { ...base, date_of_birth: "12 Apr 1985" })?.birth, null, "a non-ISO date");
});
