/**
 * AI document check — the pure half of the `document-ai-verify` function.
 *
 * Builds the vision request for whichever provider the admin configured
 * (Admin → Settings → Fare AI provider, row `fare_ai_provider`), reads the
 * answer back and normalises it into the same `DocumentAiVerificationResult`
 * the Expo client used to build for itself (expo/utils/documentAiVerify.ts),
 * so stored `ai_verification` values look the same whichever app wrote them.
 *
 * Nothing here touches the network; see doc_ai_test.ts.
 */

export type VisionProvider =
  | "gemini"
  | "chatgpt"
  | "grok"
  | "claude"
  | "openrouter"
  | "mistral"
  | "together"
  | "fireworks";

/** Providers the admin can pick that have no image input: the check is skipped. */
const VISION: readonly VisionProvider[] = [
  "gemini",
  "chatgpt",
  "grok",
  "claude",
  "openrouter",
  "mistral",
  "together",
  "fireworks",
];

export function isVisionProvider(p: unknown): p is VisionProvider {
  return typeof p === "string" && (VISION as readonly string[]).includes(p);
}

/**
 * Vision-capable defaults. The fare-AI defaults are text models (several
 * cannot see an image at all), so a document check never borrows them: an
 * admin who wants another model sets `documentModels.<provider>`.
 */
export const DEFAULT_VISION_MODELS: Record<VisionProvider, string> = {
  gemini: "gemini-2.5-flash",
  chatgpt: "gpt-4o-mini",
  grok: "grok-2-vision-1212",
  claude: "claude-haiku-4-5-20251001",
  openrouter: "openai/gpt-4o-mini",
  mistral: "pixtral-12b-2409",
  together: "meta-llama/Llama-3.2-11B-Vision-Instruct-Turbo",
  fireworks: "accounts/fireworks/models/llama-v3p2-11b-vision-instruct",
};

const OPENAI_COMPATIBLE: Partial<Record<VisionProvider, string>> = {
  chatgpt: "https://api.openai.com/v1/chat/completions",
  grok: "https://api.x.ai/v1/chat/completions",
  openrouter: "https://openrouter.ai/api/v1/chat/completions",
  mistral: "https://api.mistral.ai/v1/chat/completions",
  together: "https://api.together.xyz/v1/chat/completions",
  fireworks: "https://api.fireworks.ai/inference/v1/chat/completions",
};

/** Largest image accepted, after base64 decoding. */
export const MAX_IMAGE_BYTES = 4 * 1024 * 1024;

const IMAGE_TYPES = ["image/jpeg", "image/png", "image/webp"];

export interface InlineImage {
  mime: string;
  base64: string;
}

/**
 * Accepts a `data:image/...;base64,...` URL (what the apps send) and answers
 * the parts, or an error string. Remote URLs are refused: the function must
 * never be talked into fetching an arbitrary address.
 */
export function parseImage(input: unknown): InlineImage | string {
  if (typeof input !== "string" || input.length === 0) return "image missing";
  const m = /^data:([a-z/+.-]+);base64,([A-Za-z0-9+/=\s]+)$/i.exec(input.trim());
  if (!m) return "image must be a base64 data URL";
  const mime = m[1].toLowerCase();
  if (!IMAGE_TYPES.includes(mime)) return `unsupported image type ${mime}`;
  const base64 = m[2].replace(/\s+/g, "");
  const bytes = Math.floor((base64.length * 3) / 4) - (base64.endsWith("==") ? 2 : base64.endsWith("=") ? 1 : 0);
  if (bytes <= 0) return "image is empty";
  if (bytes > MAX_IMAGE_BYTES) return "image is too large";
  return { mime, base64 };
}

export interface DocumentAiContext {
  docName: string;
  documentNumber?: string | null;
  insuranceProviderName?: string | null;
  isPwd?: boolean;
  startDate?: string | null;
  expiryDate?: string | null;
  isTaxiPermit?: boolean;
}

const clip = (v: unknown, n = 120): string | null =>
  typeof v === "string" && v.trim() ? v.trim().slice(0, n) : null;

/** Only the fields the prompt uses, trimmed — never trusted for anything else. */
export function parseContext(input: unknown): DocumentAiContext | null {
  if (!input || typeof input !== "object") return null;
  const o = input as Record<string, unknown>;
  const docName = clip(o.docName);
  if (!docName) return null;
  return {
    docName,
    documentNumber: clip(o.documentNumber),
    insuranceProviderName: clip(o.insuranceProviderName),
    isPwd: o.isPwd === true,
    startDate: clip(o.startDate, 20),
    expiryDate: clip(o.expiryDate, 20),
    isTaxiPermit: o.isTaxiPermit === true,
  };
}

export const SYSTEM_PROMPT = `You are a strict document verifier for a partner onboarding flow.
You receive one or two images of a single identity / compliance document and a target document title.
Decide ONLY from the visual evidence — do not assume.

Reject (isReal=false) when ANY of these is true:
- The image is a screenshot of a screen, a photocopy of a photocopy, a drawing, a sketch, or AI generated.
- The image is blank, blurred beyond readability, or clearly not a document (selfie, landscape, random object, meme).
- The document is obviously tampered (mismatched fonts, cut-and-paste artefacts, photoshop seams).

Set isRelevant=false when the document is real but is NOT the requested type (e.g. user uploaded a passport when the title says "Driver's License").

matchesTitle is the AND of "looks like a real official document" and "matches the requested title".
detectedTitle is your best short label for what the document actually is (e.g. "Philippine Driver's License", "Vehicle Insurance Certificate", "National ID").
confidence is 0..1.
reason is one short sentence in plain English explaining the decision.

ALSO extract the following fields directly from the visible document text — only when clearly legible. Use null (not empty string) when you cannot read the field. Do NOT invent values.
- documentNumber: the SINGLE most prominent number / ID / policy / license number printed on the document.
- documentNumbers: an ARRAY of EVERY distinct number-like identifier visible on the document (license no., policy no., serial no., reference no., barcode digits, etc.). Include the primary one too. Trim whitespace. Use [] if none are legible.
- startDate: issue / effective / valid-from date as ISO yyyy-mm-dd (convert any other format).
- expiryDate: expiry / valid-until date as ISO yyyy-mm-dd.
- insuranceProviderName: name of the insurance company/issuer if this is an insurance document, else null.
- isPwd: true if the document explicitly references PWD / Person With Disability status, else false.
- issuanceCountry: the country that issued the document, spelled out in English (e.g. "Philippines", "United States"), null if not determinable.
- documentName: the OFFICIAL name printed on the document itself (e.g. "Non-Professional Driver's License", "Certificate of Cover"), null if not legible.

Respond ONLY with compact JSON of the exact shape:
{"isReal":boolean,"isRelevant":boolean,"matchesTitle":boolean,"detectedTitle":string,"confidence":number,"reason":string,"extracted":{"documentNumber":string|null,"documentNumbers":string[],"startDate":string|null,"expiryDate":string|null,"insuranceProviderName":string|null,"isPwd":boolean|null,"issuanceCountry":string|null,"documentName":string|null}}`;

export const TAXI_PERMIT_INSTRUCTIONS = `This document is a TAXI DRIVER PERMIT. In addition to the base fields, also read these permit fields directly from the visible text and add them under "extracted.taxiPermit". Use null when a field is not clearly legible and never invent values:
- name: the driver's full name printed on the permit.
- idNumber: the driver's ID / IC / national identity number printed on the permit.
- validityFrom: validity start / valid-from date as ISO yyyy-mm-dd.
- validityTo: validity end / valid-until date as ISO yyyy-mm-dd.
- driverType: the driver type / category text (e.g. "Taxi", "e-Hailing").
- licenceReferenceNumber: the licence reference / permit number.
- vehicleNumber: the vehicle registration / plate number on the permit.
- licenceClass: the licence class text.
- companyName: the operator / company name printed on the permit.
- address: the address printed on the permit.
- hasImageOnPermit: true if a portrait photo of the driver (a person's face/headshot) is visible on the permit, else false.
- photoBox: when hasImageOnPermit is true, the bounding box of the driver's portrait photo on image 1 (the FRONT), expressed as fractions of the image size: {"x":number,"y":number,"width":number,"height":number} where x,y is the TOP-LEFT corner (0..1) and width,height are fractions (0..1). Make the box tight around the face/headshot. Use null when no portrait photo is visible.
- hasQrCode: true if a QR code is visible on the permit, else false.
When this instruction is present, append "taxiPermit" to the "extracted" object with the exact keys: {"name":string|null,"idNumber":string|null,"validityFrom":string|null,"validityTo":string|null,"driverType":string|null,"licenceReferenceNumber":string|null,"vehicleNumber":string|null,"licenceClass":string|null,"companyName":string|null,"address":string|null,"hasImageOnPermit":boolean|null,"photoBox":{"x":number,"y":number,"width":number,"height":number}|null,"hasQrCode":boolean|null}`;

/** The text that goes with the images (Expo `buildUserParts`). */
export function buildUserText(ctx: DocumentAiContext, hasBack: boolean): string {
  const meta: string[] = [`Target document title: "${ctx.docName}".`];
  if (ctx.documentNumber) meta.push(`Partner says the document number is "${ctx.documentNumber}".`);
  if (ctx.insuranceProviderName) meta.push(`Partner says the insurer is "${ctx.insuranceProviderName}".`);
  if (ctx.startDate) meta.push(`Stated start date: ${ctx.startDate}.`);
  if (ctx.expiryDate) meta.push(`Stated expiry date: ${ctx.expiryDate}.`);
  if (ctx.isPwd) meta.push("Partner claims this is a PWD (disability) document.");
  if (ctx.isTaxiPermit) meta.push(TAXI_PERMIT_INSTRUCTIONS);
  meta.push(hasBack ? "Image 1 is the FRONT, image 2 is the BACK." : "Only the FRONT side was provided.");
  meta.push("Return ONLY the JSON object specified by the system message.");
  return meta.join(" ");
}

export interface ProviderRequest {
  url: string;
  headers: Record<string, string>;
  body: unknown;
}

/** The HTTP request for one vision call. */
export function visionRequest(
  provider: VisionProvider,
  model: string,
  apiKey: string,
  userText: string,
  images: InlineImage[],
): ProviderRequest {
  if (provider === "gemini") {
    return {
      url: `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`,
      headers: { "Content-Type": "application/json" },
      body: {
        systemInstruction: { parts: [{ text: SYSTEM_PROMPT }] },
        contents: [{
          role: "user",
          parts: [
            { text: userText },
            ...images.map((i) => ({ inline_data: { mime_type: i.mime, data: i.base64 } })),
          ],
        }],
        generationConfig: { temperature: 0, responseMimeType: "application/json" },
      },
    };
  }
  if (provider === "claude") {
    return {
      url: "https://api.anthropic.com/v1/messages",
      headers: { "Content-Type": "application/json", "x-api-key": apiKey, "anthropic-version": "2023-06-01" },
      body: {
        model,
        max_tokens: 1024,
        temperature: 0,
        system: SYSTEM_PROMPT,
        messages: [{
          role: "user",
          content: [
            ...images.map((i) => ({ type: "image", source: { type: "base64", media_type: i.mime, data: i.base64 } })),
            { type: "text", text: userText },
          ],
        }],
      },
    };
  }
  return {
    url: OPENAI_COMPATIBLE[provider]!,
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
    body: {
      model,
      temperature: 0,
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        {
          role: "user",
          content: [
            { type: "text", text: userText },
            ...images.map((i) => ({ type: "image_url", image_url: { url: `data:${i.mime};base64,${i.base64}` } })),
          ],
        },
      ],
    },
  };
}

/** The model's text out of a provider response. */
export function responseText(provider: VisionProvider, data: unknown): string | null {
  // deno-lint-ignore no-explicit-any
  const d = data as any;
  const text = provider === "gemini"
    ? d?.candidates?.[0]?.content?.parts?.map((p: { text?: string }) => p?.text ?? "").join("")
    : provider === "claude"
    ? d?.content?.find?.((c: { type?: string }) => c?.type === "text")?.text
    : d?.choices?.[0]?.message?.content;
  return typeof text === "string" && text.trim() ? text : null;
}

export interface PhotoBox {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface TaxiPermitFields {
  name: string | null;
  idNumber: string | null;
  validityFrom: string | null;
  validityTo: string | null;
  driverType: string | null;
  licenceReferenceNumber: string | null;
  vehicleNumber: string | null;
  licenceClass: string | null;
  companyName: string | null;
  address: string | null;
  hasImageOnPermit: boolean | null;
  photoBox: PhotoBox | null;
  hasQrCode: boolean | null;
  photoUrl: string | null;
}

export interface DocumentAiVerificationResult {
  isReal: boolean;
  isRelevant: boolean;
  matchesTitle: boolean;
  detectedTitle: string;
  confidence: number;
  reason: string;
  extracted: {
    documentNumber: string | null;
    documentNumbers: string[];
    startDate: string | null;
    expiryDate: string | null;
    insuranceProviderName: string | null;
    isPwd: boolean | null;
    issuanceCountry: string | null;
    documentName: string | null;
    taxiPermit: TaxiPermitFields | null;
  };
  rawText: string;
  verifiedAt: string;
}

const pad2 = (n: number) => String(n).padStart(2, "0");

/** ISO yyyy-mm-dd, or null (Expo `normDate`, in UTC so the server's zone never shifts a day). */
export function normDate(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const s = v.trim();
  if (!s) return null;
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
  const t = Date.parse(s);
  if (Number.isNaN(t)) return null;
  const d = new Date(t);
  return `${d.getUTCFullYear()}-${pad2(d.getUTCMonth() + 1)}-${pad2(d.getUTCDate())}`;
}

function normBox(v: unknown): PhotoBox | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  const num = (k: unknown): number | null => {
    const n = Number(k);
    return Number.isFinite(n) ? Math.max(0, Math.min(1, n)) : null;
  };
  const x = num(o.x), y = num(o.y), width = num(o.width), height = num(o.height);
  if (x == null || y == null || width == null || height == null) return null;
  if (width <= 0 || height <= 0) return null;
  return { x, y, width, height };
}

function normTaxiPermit(v: unknown): TaxiPermitFields | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  return {
    name: clip(o.name),
    idNumber: clip(o.idNumber),
    validityFrom: normDate(o.validityFrom),
    validityTo: normDate(o.validityTo),
    driverType: clip(o.driverType),
    licenceReferenceNumber: clip(o.licenceReferenceNumber),
    vehicleNumber: clip(o.vehicleNumber),
    licenceClass: clip(o.licenceClass),
    companyName: clip(o.companyName),
    address: clip(o.address),
    hasImageOnPermit: typeof o.hasImageOnPermit === "boolean" ? o.hasImageOnPermit : null,
    photoBox: normBox(o.photoBox),
    hasQrCode: typeof o.hasQrCode === "boolean" ? o.hasQrCode : null,
    photoUrl: null,
  };
}

/**
 * The model's answer as the stored result, or null when it is not JSON.
 * Same normalisation as Expo: bounded strings, clamped confidence, ISO dates,
 * at most 12 distinct candidate numbers.
 */
export function normalizeResult(raw: string, ctx: DocumentAiContext, now: Date): DocumentAiVerificationResult | null {
  const match = raw.replace(/```json/gi, "").replace(/```/g, "").trim().match(/\{[\s\S]*\}/);
  if (!match) return null;
  // deno-lint-ignore no-explicit-any
  let p: any;
  try {
    p = JSON.parse(match[0]);
  } catch {
    return null;
  }
  if (!p || typeof p !== "object") return null;
  const ex = (p.extracted && typeof p.extracted === "object") ? p.extracted : {};
  const numbers = Array.isArray(ex.documentNumbers)
    ? [...new Set((ex.documentNumbers as unknown[]).map((v) => clip(v)).filter((v): v is string => !!v))].slice(0, 12)
    : [];
  const confidence = Number(p.confidence ?? 0);
  return {
    isReal: Boolean(p.isReal),
    isRelevant: Boolean(p.isRelevant),
    matchesTitle: Boolean(p.matchesTitle ?? (p.isReal && p.isRelevant)),
    detectedTitle: String(p.detectedTitle ?? "").slice(0, 120),
    confidence: Number.isFinite(confidence) ? Math.max(0, Math.min(1, confidence)) : 0,
    reason: String(p.reason ?? "").slice(0, 400),
    extracted: {
      documentNumber: clip(ex.documentNumber),
      documentNumbers: numbers,
      startDate: normDate(ex.startDate),
      expiryDate: normDate(ex.expiryDate),
      insuranceProviderName: clip(ex.insuranceProviderName),
      isPwd: typeof ex.isPwd === "boolean" ? ex.isPwd : null,
      issuanceCountry: clip(ex.issuanceCountry),
      documentName: clip(ex.documentName),
      taxiPermit: ctx.isTaxiPermit ? normTaxiPermit(ex.taxiPermit) : null,
    },
    rawText: raw.trim().slice(0, 1000),
    verifiedAt: now.toISOString(),
  };
}

/** The bearer token out of an Authorization header, or null. */
export function bearerToken(header: string | null): string | null {
  const m = /^Bearer\s+(\S+)$/i.exec(header ?? "");
  return m ? m[1] : null;
}
