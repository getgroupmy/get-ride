// Pure helpers for vehicle-registration-read (migration 0388): the prompt that
// asks the model to read a vehicle ownership certificate (Malaysia: JPJ geran;
// named differently per country), and the normalisation of what it returns into
// the vehicle fields the Edit form fills. No IO here, so it is unit-tested.

export interface RegistrationFields {
  plate: string | null;
  make: string | null;
  model: string | null;
  seats: number | null;
  color: string | null;
  year: string | null;
  vin: string | null;
  engine_number: string | null;
  document_number: string | null;
}

export const REGISTRATION_SYSTEM =
  "You read a vehicle ownership / registration certificate (e.g. Malaysia's JPJ " +
  "geran; the document is named differently in each country). Answer only with JSON. " +
  "Transcribe exactly what the document shows; never guess a value that is not printed.";

export const REGISTRATION_PROMPT = [
  "Read this vehicle ownership certificate and return JSON:",
  '{"plate","make","model","seats","color","year","vin","engine_number","document_number"}.',
  '"plate" is the registration/number plate; "make" and "model" are the manufacturer and model;',
  '"seats" is the integer seating capacity; "color" the body colour; "year" the 4-digit make/manufacture year;',
  '"vin" the chassis/VIN; "engine_number" the engine number; "document_number" the certificate/registration number.',
  "Use null for any field not clearly printed on the document. Do not invent values.",
].join("\n");

function str(v: unknown, max = 120): string | null {
  const t = `${v ?? ""}`.trim();
  if (!t || t === "0" || t.toLowerCase() === "null" || t === "-") return null;
  return t.slice(0, max);
}

function year(v: unknown): string | null {
  const m = `${v ?? ""}`.match(/\b(19|20)\d{2}\b/);
  return m ? m[0] : null;
}

function seats(v: unknown): number | null {
  const n = typeof v === "number" ? v : parseInt(`${v ?? ""}`.replace(/[^0-9]/g, ""), 10);
  if (!Number.isFinite(n) || n < 1 || n > 100) return null;
  return Math.trunc(n);
}

/** Validate the model's answer into clean vehicle fields. Every field is
 *  optional; anything unreadable, junk or out of range becomes null. */
export function normalizeRegistration(raw: unknown): RegistrationFields {
  const r = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  return {
    plate: str(r.plate, 24),
    make: str(r.make, 60),
    model: str(r.model, 60),
    seats: seats(r.seats),
    color: str(r.color, 40),
    year: year(r.year),
    vin: str(r.vin, 40),
    engine_number: str(r.engine_number, 40),
    document_number: str(r.document_number, 60),
  };
}

/** True when at least one field was read, so the caller can tell a blank scan
 *  from a successful one. */
export function hasAnyField(f: RegistrationFields): boolean {
  return Object.values(f).some((v) => v !== null);
}
