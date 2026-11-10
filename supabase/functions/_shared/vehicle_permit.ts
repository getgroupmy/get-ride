// Pure helpers for vehicle-permit-read: the prompt that asks the model to read a
// vehicle operating permit (Malaysia: the APAD / EVP e-hailing permit; named
// differently per country), and the normalisation of what it returns. The
// permit's plate matters most — it lets the approver catch a permit issued for a
// different car. No IO here, so it is unit-tested.

export interface PermitFields {
  document_number: string | null;
  expiry_date: string | null; // yyyy-mm-dd
  plate: string | null;
  authority: string | null;
}

export const PERMIT_SYSTEM =
  "You read a vehicle operating / e-hailing permit (e.g. Malaysia's APAD e-hailing " +
  "vehicle permit, 'EVP'; the document is named differently in each country). Answer " +
  "only with JSON. Transcribe exactly what the document shows; never guess a value " +
  "that is not printed.";

export const PERMIT_PROMPT = [
  "Read this vehicle permit and return JSON:",
  '{"document_number","expiry_date","plate","authority"}.',
  '"document_number" is the permit / licence number;',
  '"expiry_date" is the expiry / valid-until date as yyyy-mm-dd;',
  '"plate" is the vehicle registration/number plate the permit is issued for;',
  '"authority" is the issuing authority or body.',
  "Use null for any field not clearly printed on the document. Do not invent values.",
].join("\n");

function str(v: unknown, max = 120): string | null {
  const t = `${v ?? ""}`.trim();
  if (!t || t === "0" || t.toLowerCase() === "null" || t === "-") return null;
  return t.slice(0, max);
}

/** The uppercased alphanumerics of a plate, for a tolerant comparison. */
export function platesMatch(a: string | null | undefined, b: string | null | undefined): boolean {
  const norm = (s: string | null | undefined) => `${s ?? ""}`.toUpperCase().replace(/[^A-Z0-9]/g, "");
  const x = norm(a), y = norm(b);
  return x.length > 0 && x === y;
}

/** A yyyy-mm-dd date from common spellings (yyyy-mm-dd, dd/mm/yyyy, dd-mm-yyyy,
 *  "12 Jan 2026"); null when nothing parses to a real date. */
export function permitDate(v: unknown): string | null {
  const t = `${v ?? ""}`.trim();
  if (!t) return null;
  const iso = t.match(/\b(\d{4})-(\d{2})-(\d{2})\b/);
  if (iso) return `${iso[1]}-${iso[2]}-${iso[3]}`;
  const dmy = t.match(/\b(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{4})\b/);
  if (dmy) {
    const d = dmy[1].padStart(2, "0"), m = dmy[2].padStart(2, "0");
    if (+m >= 1 && +m <= 12 && +d >= 1 && +d <= 31) return `${dmy[3]}-${m}-${d}`;
  }
  const months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
  const txt = t.toLowerCase().match(/\b(\d{1,2})\s+([a-z]{3,})\s+(\d{4})\b/);
  if (txt) {
    const mi = months.indexOf(txt[2].slice(0, 3));
    if (mi >= 0) return `${txt[3]}-${`${mi + 1}`.padStart(2, "0")}-${txt[1].padStart(2, "0")}`;
  }
  return null;
}

/** Validate the model's answer into clean permit fields. */
export function normalizePermit(raw: unknown): PermitFields {
  const r = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  return {
    document_number: str(r.document_number, 60),
    expiry_date: permitDate(r.expiry_date),
    plate: str(r.plate, 24),
    authority: str(r.authority, 80),
  };
}

/** True when at least one field was read. */
export function hasAnyField(f: PermitFields): boolean {
  return Object.values(f).some((v) => v !== null);
}
