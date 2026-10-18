/**
 * The partner statement's look (migration 0217), set in Admin → Partner
 * statements → Layout: which fields show and what they are called (English
 * and Malay), the order of the partner lines and of the sections, the font
 * and its sizes, the colours, and the logo (uploaded to `app-branding`) with
 * where it sits. Blank or missing values keep the built-in look, so a
 * statement with no layout saved is drawn exactly as before.
 *
 * The app keeps the same catalog in lib/src/core/statement_layout.dart;
 * test/statement_layout_test.dart checks the two match.
 */

export type FieldGroup =
  | "header" | "partner" | "earnings" | "deductions" | "net" | "passThrough" | "howPaid" | "activity"
  | "lists" | "breakdown" | "footer";

/** Every field an admin may hide or rename: its id, where it sits, and the word it renames. */
export const LAYOUT_FIELDS: { id: string; group: FieldGroup; word?: string }[] = [
  { id: "companyName", group: "header" },
  { id: "companySsm", group: "header", word: "ssm" },
  { id: "supportContact", group: "header", word: "support" },
  { id: "title", group: "header", word: "title" },
  { id: "period", group: "header" },
  { id: "statementNo", group: "header", word: "statementNo" },
  { id: "status", group: "header" },
  { id: "issued", group: "header", word: "issued" },
  { id: "partner", group: "partner", word: "partner" },
  { id: "partnerId", group: "partner", word: "partnerId" },
  { id: "ic", group: "partner", word: "ic" },
  { id: "plate", group: "partner", word: "plate" },
  { id: "bank", group: "partner", word: "bank" },
  { id: "earnings", group: "earnings", word: "earnings" },
  { id: "fares", group: "earnings", word: "fares" },
  { id: "surcharges", group: "earnings", word: "surcharges" },
  { id: "feesCollected", group: "earnings", word: "feesCollected" },
  { id: "incentives", group: "earnings", word: "incentives" },
  { id: "handoverIn", group: "earnings", word: "handoverIn" },
  { id: "totalEarnings", group: "earnings", word: "totalEarnings" },
  { id: "deductions", group: "deductions", word: "deductions" },
  { id: "commission", group: "deductions", word: "commission" },
  { id: "platformFees", group: "deductions", word: "platformFees" },
  { id: "handoverOut", group: "deductions", word: "handoverOut" },
  { id: "totalDeductions", group: "deductions", word: "totalDeductions" },
  { id: "adjustments", group: "net", word: "adjustments" },
  { id: "net", group: "net", word: "net" },
  { id: "passThrough", group: "passThrough", word: "passThrough" },
  { id: "taxes", group: "passThrough", word: "taxes" },
  { id: "tolls", group: "passThrough", word: "tolls" },
  { id: "otherCharges", group: "passThrough", word: "otherCharges" },
  { id: "otherSurcharges", group: "passThrough", word: "otherSurcharges" },
  { id: "total", group: "passThrough", word: "total" },
  { id: "howPaid", group: "howPaid", word: "howPaid" },
  { id: "cash", group: "howPaid", word: "cash" },
  { id: "coins", group: "howPaid", word: "coins" },
  { id: "activity", group: "activity", word: "activity" },
  { id: "trips", group: "activity", word: "trips" },
  { id: "meterTrips", group: "activity", word: "meterTrips" },
  { id: "onlineHours", group: "activity", word: "onlineHours" },
  { id: "distance", group: "activity", word: "distance" },
  { id: "incentivesList", group: "lists", word: "incentivesList" },
  { id: "adjustmentsList", group: "lists", word: "adjustmentsList" },
  { id: "daily", group: "breakdown", word: "daily" },
  { id: "weeklyBreakdown", group: "breakdown", word: "weeklyBreakdown" },
  { id: "monthlyBreakdown", group: "breakdown", word: "monthlyBreakdown" },
  { id: "tripList", group: "breakdown", word: "tripList" },
  { id: "verify", group: "footer", word: "verify" },
  { id: "footer", group: "footer", word: "footer" },
  { id: "pageNumbers", group: "footer" },
  { id: "watermark", group: "footer", word: "provisional" },
];

/** The blocks under the partner lines, in their built-in order. */
export const SECTIONS = [
  "earnings", "deductions", "net", "passThrough", "howPaid", "activity",
  "incentivesList", "adjustmentsList", "breakdown", "tripList",
] as const;
export type Section = typeof SECTIONS[number];

export const PARTNER_LINES = ["partner", "partnerId", "ic", "plate", "bank"] as const;

export type FontFamily = "helvetica" | "times" | "courier";

export const FONT_SIZES = {
  company: 12, title: 12, heading: 10, body: 9, total: 10, table: 8, small: 7,
} as const;
export type FontSizeKey = keyof typeof FONT_SIZES;
export const FONT_MIN = 6;
export const FONT_MAX = 24;

export const COLORS = {
  brand: "#007859", ink: "#1A1A1F", muted: "#6B7080", rule: "#D9DBE0", badge: "#007859", watermark: "#E6E6EB",
} as const;
export type ColorKey = keyof typeof COLORS;

export type LogoPosition = "left" | "center" | "right";

export interface StatementLayout {
  fields: Record<string, { show?: boolean; en?: string; ms?: string }>;
  sections: Section[];
  partnerOrder: string[];
  fontFamily: FontFamily;
  fonts: Record<FontSizeKey, number>;
  colors: Record<ColorKey, string>;
  logo: { path: string; position: LogoPosition; width: number; dx: number; dy: number };
  companySide: "left" | "right";
}

export const LOGO_WIDTH = { min: 20, max: 220, initial: 70 };
export const LOGO_SHIFT = 200;

const HEX = /^#[0-9a-fA-F]{6}$/;
const LOGO_PATH = /^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$/;

const clamp = (v: unknown, lo: number, hi: number, d: number) => {
  const n = typeof v === "number" && Number.isFinite(v) ? v : d;
  return Math.min(hi, Math.max(lo, n));
};
const text = (v: unknown) => (typeof v === "string" ? v.trim().slice(0, 80) : "");
const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {});

/** An order holding every item once: the known ones given first, the rest in their built-in place. */
function ordered<T extends string>(given: unknown, all: readonly T[]): T[] {
  const seen = Array.isArray(given) ? given.filter((x): x is T => all.includes(x as T)) : [];
  const out = [...new Set(seen)];
  for (const x of all) if (!out.includes(x)) out.push(x);
  return out;
}

/** What was saved, with anything unknown or out of range dropped back to the built-in look. */
export function cleanLayout(raw: unknown): StatementLayout {
  const r = obj(raw);
  const fields: StatementLayout["fields"] = {};
  const given = obj(r.fields);
  // In catalog order, so the same layout always hashes the same.
  for (const { id } of LAYOUT_FIELDS) {
    const f = obj(given[id]);
    const out: { show?: boolean; en?: string; ms?: string } = {};
    if (f.show === false) out.show = false;
    if (text(f.en)) out.en = text(f.en);
    if (text(f.ms)) out.ms = text(f.ms);
    if (Object.keys(out).length) fields[id] = out;
  }
  const fonts = obj(r.fonts);
  const colors = obj(r.colors);
  const logo = obj(r.logo);
  return {
    fields,
    sections: ordered(r.sections, SECTIONS),
    partnerOrder: ordered(r.partnerOrder, PARTNER_LINES),
    fontFamily: r.fontFamily === "times" || r.fontFamily === "courier" ? r.fontFamily : "helvetica",
    fonts: Object.fromEntries(
      (Object.keys(FONT_SIZES) as FontSizeKey[]).map((k) => [k, Math.round(clamp(fonts[k], FONT_MIN, FONT_MAX, FONT_SIZES[k]) * 2) / 2]),
    ) as Record<FontSizeKey, number>,
    colors: Object.fromEntries(
      (Object.keys(COLORS) as ColorKey[]).map((k) => [k, typeof colors[k] === "string" && HEX.test(colors[k] as string) ? (colors[k] as string).toUpperCase() : COLORS[k]]),
    ) as Record<ColorKey, string>,
    logo: {
      path: typeof logo.path === "string" && LOGO_PATH.test(logo.path) ? logo.path : "",
      position: logo.position === "center" || logo.position === "right" ? logo.position : "left",
      width: Math.round(clamp(logo.width, LOGO_WIDTH.min, LOGO_WIDTH.max, LOGO_WIDTH.initial)),
      dx: Math.round(clamp(logo.dx, -LOGO_SHIFT, LOGO_SHIFT, 0)),
      dy: Math.round(clamp(logo.dy, -LOGO_SHIFT, LOGO_SHIFT, 0)),
    },
    companySide: r.companySide === "right" ? "right" : "left",
  };
}

export const shows = (l: StatementLayout, id: string) => l.fields[id]?.show !== false;

/** The words with the admin's names put in, for one language. */
export function renamed<W extends Record<string, unknown>>(w: W, l: StatementLayout, lang: "en" | "ms"): W {
  const out: Record<string, unknown> = { ...w };
  for (const f of LAYOUT_FIELDS) {
    const name = l.fields[f.id]?.[lang];
    if (f.word && name && typeof out[f.word] === "string") out[f.word] = name;
  }
  return out as W;
}

/** "#007859" → [0, 0.47, 0.35]. */
export function rgbOf(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255];
}

/** The layout as a hash, so a kept final statement is redrawn (not revised) when it changes. */
export async function layoutHash(l: StatementLayout): Promise<string> {
  const bytes = new TextEncoder().encode(JSON.stringify(l));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
