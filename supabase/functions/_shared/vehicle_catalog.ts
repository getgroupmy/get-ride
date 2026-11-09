// Pure helpers for the vehicle-catalog-lookup function (migration 0387): build
// the prompt that asks the model for a make/model's specs, and normalise what
// it returns against the catalogue's own vocabulary so the AI can only ever add
// clean, in-vocabulary rows. No IO here, so it is unit-tested directly.

export interface CatalogRow {
  make: string;
  model: string;
  energy_type: string | null;
  vehicle_type: string | null;
  seats: number | null;
}

const MAX_MODELS = 20;

/** The instruction given to the model. */
export const CATALOG_SYSTEM =
  "You are a precise vehicle specification database. Answer only with JSON. " +
  "Never invent a make or model that does not exist. If you are unsure, omit it.";

/** Build the user prompt for a make (and optional model), constraining the
 *  energy and body-type values to the catalogue's own vocabulary. */
export function buildCatalogPrompt(
  make: string,
  model: string | null,
  energies: string[],
  types: string[],
): string {
  const energyList = energies.length ? energies.join(", ") : "Petrol, Diesel, Hybrid, Electric";
  const typeList = types.length ? types.join(", ") : "Sedan, Hatchback, SUV, MPV, Pickup, Van";
  const scope = model && model.trim()
    ? `the single model "${model.trim()}" of make "${make.trim()}"`
    : `up to ${MAX_MODELS} of the most common models of make "${make.trim()}"`;
  return [
    `Return the real production vehicles for ${scope}.`,
    `Respond as JSON: {"entries":[{"make","model","energy_type","vehicle_type","seats"}]}.`,
    `"make" and "model" are the official names.`,
    `"energy_type" must be exactly one of: ${energyList} — or null if unknown.`,
    `"vehicle_type" must be exactly one of: ${typeList} — or null if unknown.`,
    `"seats" is the integer number of seats, or null if unknown.`,
    `Do not return a make or model that does not exist.`,
  ].join("\n");
}

function matchVocab(value: unknown, vocab: string[]): string | null {
  const t = `${value ?? ""}`.trim();
  if (!t) return null;
  const hit = vocab.find((v) => v.toLowerCase() === t.toLowerCase());
  return hit ?? null; // only a value the catalogue already uses
}

function seatsOf(value: unknown): number | null {
  const n = typeof value === "number" ? value : parseInt(`${value ?? ""}`.trim(), 10);
  if (!Number.isFinite(n) || n < 1 || n > 100) return null;
  return Math.trunc(n);
}

/** Validate the model's answer into clean catalogue rows: every row must name a
 *  make and model; energy/type are kept only when they match the catalogue's
 *  vocabulary; a make not matching [expectedMake] is dropped (the model drifted
 *  to a different brand). Duplicates (same make+model, case-insensitive) collapse. */
export function normalizeCatalogEntries(
  raw: unknown,
  opts: { expectedMake: string; allowedEnergies: string[]; allowedTypes: string[] },
): CatalogRow[] {
  const list = (raw && typeof raw === "object" ? (raw as { entries?: unknown }).entries : null);
  if (!Array.isArray(list)) return [];
  const want = opts.expectedMake.trim().toLowerCase();
  const seen = new Set<string>();
  const out: CatalogRow[] = [];
  for (const item of list) {
    if (!item || typeof item !== "object") continue;
    const r = item as Record<string, unknown>;
    const make = `${r.make ?? ""}`.trim();
    const model = `${r.model ?? ""}`.trim();
    if (!make || !model) continue;
    if (want && make.toLowerCase() !== want) continue;
    const key = `${make.toLowerCase()}|${model.toLowerCase()}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({
      make,
      model,
      energy_type: matchVocab(r.energy_type, opts.allowedEnergies),
      vehicle_type: matchVocab(r.vehicle_type, opts.allowedTypes),
      seats: seatsOf(r.seats),
    });
    if (out.length >= MAX_MODELS) break;
  }
  return out;
}
