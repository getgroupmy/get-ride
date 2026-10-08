// What the fare AI is asked, and how long a failed key rests. Pure, so the
// edge function (ai-route-proxy) and its tests share one copy.
//
// The admin edits the wording (Admin → Fare AI → Request & format), stored as
// `request` inside the `fare_ai_provider` app_settings value. The JSON shape
// the AI must answer in is NOT editable: it is generated from the field
// switches and always asks for numeric distance_km and duration_min, because
// that is what fares are priced on and what parseEstimate reads.

export interface LatLng {
  latitude: number;
  longitude: number;
}

export interface FareAIRequest {
  systemInstruction?: string;
  promptTemplate?: string;
  includeSummary?: boolean;
  includeTolls?: boolean;
  includeTollCoords?: boolean;
  temperature?: number;
  maxTokens?: number;
}

export interface ResolvedRequest {
  systemInstruction: string;
  promptTemplate: string;
  includeSummary: boolean;
  includeTolls: boolean;
  includeTollCoords: boolean;
  temperature: number;
  maxTokens: number;
}

export const DEFAULT_SYSTEM_INSTRUCTION =
  "You return only valid JSON. Never wrap the JSON in markdown fences.";

export const DEFAULT_PROMPT_TEMPLATE =
  "You are a driving route estimator with access to real-time traffic and toll road data. " +
  'For the trip "{origin} to {destination} realtime minute and distance with traffic", ' +
  "estimate the total driving distance, the current driving time including live traffic, " +
  "and the toll booths/plazas along the route with their individual charges in local currency.";

export const DEFAULT_REQUEST: ResolvedRequest = {
  systemInstruction: DEFAULT_SYSTEM_INSTRUCTION,
  promptTemplate: DEFAULT_PROMPT_TEMPLATE,
  includeSummary: true,
  includeTolls: true,
  includeTollCoords: true,
  temperature: 0,
  maxTokens: 512,
};

/** Placeholders a template may use. */
export const PLACEHOLDERS = [
  "{origin}",
  "{destination}",
  "{origin_lat}",
  "{origin_lng}",
  "{dest_lat}",
  "{dest_lng}",
] as const;

/** Why a template cannot be used, or null. It has to say where the trip
 * starts and ends — either as {origin}/{destination} or as both lat/lng pairs. */
export function templateProblem(template: string): string | null {
  const t = template.trim();
  if (t.length === 0) return "The prompt is empty.";
  if (t.length > 4000) return "The prompt is longer than 4000 characters.";
  const hasOrigin = t.includes("{origin}") || (t.includes("{origin_lat}") && t.includes("{origin_lng}"));
  const hasDest = t.includes("{destination}") || (t.includes("{dest_lat}") && t.includes("{dest_lng}"));
  if (!hasOrigin) return "The prompt must include {origin} (or {origin_lat} and {origin_lng}).";
  if (!hasDest) return "The prompt must include {destination} (or {dest_lat} and {dest_lng}).";
  return null;
}

function clamp(n: unknown, lo: number, hi: number, fallback: number): number {
  const v = Number(n);
  if (!Number.isFinite(v)) return fallback;
  return Math.min(hi, Math.max(lo, v));
}

/** The stored request with every gap (or unusable value) filled from the default. */
export function resolveRequest(raw: unknown): ResolvedRequest {
  const r = (raw && typeof raw === "object" ? raw : {}) as FareAIRequest;
  const system = typeof r.systemInstruction === "string" && r.systemInstruction.trim()
    ? r.systemInstruction.trim()
    : DEFAULT_REQUEST.systemInstruction;
  const template = typeof r.promptTemplate === "string" && templateProblem(r.promptTemplate) === null
    ? r.promptTemplate.trim()
    : DEFAULT_REQUEST.promptTemplate;
  const includeTolls = r.includeTolls !== false;
  return {
    systemInstruction: system,
    promptTemplate: template,
    includeSummary: r.includeSummary !== false,
    includeTolls,
    includeTollCoords: includeTolls && r.includeTollCoords !== false,
    temperature: clamp(r.temperature, 0, 1, DEFAULT_REQUEST.temperature),
    maxTokens: Math.round(clamp(r.maxTokens, 128, 4096, DEFAULT_REQUEST.maxTokens)),
  };
}

const fmt = (n: number) => String(n);

/** The template with the trip filled in. */
export function fillTemplate(template: string, origin: LatLng, destination: LatLng): string {
  return template
    .replaceAll("{origin}", `${fmt(origin.latitude)},${fmt(origin.longitude)}`)
    .replaceAll("{destination}", `${fmt(destination.latitude)},${fmt(destination.longitude)}`)
    .replaceAll("{origin_lat}", fmt(origin.latitude))
    .replaceAll("{origin_lng}", fmt(origin.longitude))
    .replaceAll("{dest_lat}", fmt(destination.latitude))
    .replaceAll("{dest_lng}", fmt(destination.longitude));
}

/** The fixed answer format, built from the field switches. */
export function formatClause(req: ResolvedRequest): string {
  const fields = ['"distance_km": <number>', '"duration_min": <number>'];
  if (req.includeSummary) fields.push('"summary": "<short text>"');
  if (req.includeTolls) {
    const booth = req.includeTollCoords
      ? '{"name": "<booth name>", "charge": <number>, "lat": <number>, "lng": <number>}'
      : '{"name": "<booth name>", "charge": <number>}';
    fields.push('"toll_count": <integer>', '"toll_total": <number>', `"tolls": [${booth}]`);
  }
  let s = `Respond with ONLY a compact JSON object, no markdown, no extra text, of the form: {${fields.join(", ")}}. ` +
    "distance_km is total kilometres (number). duration_min is total minutes with traffic (integer).";
  if (req.includeTolls) {
    s += " toll_count is the number of toll booths/plazas on the route (integer, 0 if none). " +
      "toll_total is the sum of all toll charges (number, 0 if none). " +
      "tolls is an array of each real toll booth/plaza that physically exists on this route, in travel order, " +
      (req.includeTollCoords
        ? "each with its name, charge, and exact geographic coordinates (lat and lng as decimal degrees) of the booth location. " +
          "Use real, known toll plaza coordinates; do not invent coordinates. Empty array if none."
        : "each with its name and charge. Empty array if none.");
  }
  return s;
}

/** The full user prompt sent to the AI. */
export function buildPrompt(req: ResolvedRequest, origin: LatLng, destination: LatLng): string {
  return `${fillTemplate(req.promptTemplate, origin, destination).trim()} ${formatClause(req)}`;
}

/** How long a failed key rests (a month is 30 days). */
export function retryPolicyMs(value: number, unit: string): number {
  const v = Number.isFinite(value) && value > 0 ? value : 1;
  const minute = 60 * 1000;
  const hour = 60 * minute;
  switch (unit) {
    case "minute":
      return v * minute;
    case "month":
      return v * 30 * 24 * hour;
    case "day":
      return v * 24 * hour;
    default:
      return v * hour;
  }
}
