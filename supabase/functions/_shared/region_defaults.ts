/**
 * Country defaults for Admin → Country / States / Cities → Fill defaults:
 *
 *   world-countries       currency code + symbol, calling code, languages,
 *   (npm, the data REST   capital (bundled with the function: REST Countries
 *   Countries is built on) v3 is retired and v5 needs a key)
 *   countries-and-timezones the country's IANA zones (bundled)
 *   Open-Meteo geocoding    the capital's zone and position, when the
 *                           zone list does not name it
 *   emergencynumberapi      the emergency number (dispatch, else police)
 *
 * The date format comes from the runtime's own locale data (Intl). Pure:
 * the fetching is in region-defaults/index.ts.
 */

export interface CountryFacts {
  iso2: string;
  name: string;
  currencyName: string | null;
  currencySymbol: string | null;
  callingCode: string | null;
  /** ISO 639-1 codes of the official languages, in the API's order. */
  languages: string[];
  capital: string | null;
  /** Where to ask the time zone of: the capital, else the country's centre. */
  lat: number | null;
  lng: number | null;
}

export interface RegionDefaults {
  iso2: string;
  country: string;
  currencyName: string | null;
  currencySymbol: string | null;
  callingCode: string | null;
  languageCode: string | null;
  dateFormat: string | null;
  timezone: string | null;
  emergencyNumber: string | null;
  lat: number | null;
  lng: number | null;
}

/** REST Countries' ISO 639-3 language keys → ISO 639-1. */
const ISO639_1: Record<string, string> = {
  msa: "ms", zsm: "ms", eng: "en", zho: "zh", cmn: "zh", ind: "id", tha: "th", vie: "vi", jpn: "ja",
  kor: "ko", hin: "hi", urd: "ur", ben: "bn", ara: "ar", fra: "fr", deu: "de", spa: "es", por: "pt",
  ita: "it", rus: "ru", tur: "tr", nld: "nl", swe: "sv", nor: "nb", nob: "nb", dan: "da", fin: "fi",
  pol: "pl", ces: "cs", hun: "hu", ron: "ro", bul: "bg", ell: "el", heb: "he", fil: "fil", tgl: "tl",
  tam: "ta", sin: "si", nep: "ne", swa: "sw", amh: "am", ukr: "uk", fas: "fa", khm: "km", mya: "my",
  lao: "lo", kaz: "kk", uzb: "uz", aze: "az", kat: "ka", hye: "hy", srp: "sr", hrv: "hr", slk: "sk",
  slv: "sl", lit: "lt", lav: "lv", est: "et", isl: "is", gle: "ga", mlt: "mt", afr: "af", zul: "zu",
  xho: "xh", som: "so", hau: "ha", yor: "yo", ibo: "ig", mon: "mn", pus: "ps", div: "dv", dzo: "dz",
};

const str = (v: unknown): string | null => (typeof v === "string" && v.trim() !== "" ? v.trim() : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

/** One world-countries / REST Countries entry (or the first of an array), or null. */
export function parseRestCountry(body: unknown): CountryFacts | null {
  const c = Array.isArray(body) ? body[0] : body;
  if (!c || typeof c !== "object") return null;
  const o = c as Record<string, unknown>;
  const iso2 = str(o.cca2);
  if (!iso2) return null;
  const name = str((o.name as Record<string, unknown> | undefined)?.common) ?? iso2;

  const currencies = (o.currencies ?? {}) as Record<string, Record<string, unknown>>;
  const [code, cur] = Object.entries(currencies)[0] ?? [];

  const idd = (o.idd ?? {}) as { root?: unknown; suffixes?: unknown };
  const root = str(idd.root);
  const suffixes = Array.isArray(idd.suffixes) ? idd.suffixes.filter((s) => typeof s === "string") : [];
  // A single suffix is part of the code (+6 + 0 = +60); many are area codes (+1 201, …).
  const callingCode = root ? (suffixes.length === 1 ? `${root}${suffixes[0]}` : root) : null;

  const languages = Object.keys((o.languages ?? {}) as Record<string, unknown>)
    .map((k) => ISO639_1[k.toLowerCase()])
    .filter((k): k is string => !!k);

  const capital = ((o.capitalInfo ?? {}) as { latlng?: unknown }).latlng;
  const centre = o.latlng;
  const pair = (p: unknown): [number, number] | null =>
    Array.isArray(p) && num(p[0]) !== null && num(p[1]) !== null ? [p[0] as number, p[1] as number] : null;
  const at = pair(capital) ?? pair(centre);

  return {
    iso2: iso2.toUpperCase(),
    name,
    currencyName: str(code),
    currencySymbol: str(cur?.symbol),
    callingCode,
    languages,
    capital: Array.isArray(o.capital) ? str(o.capital[0]) : str(o.capital),
    lat: at?.[0] ?? null,
    lng: at?.[1] ?? null,
  };
}

/** The emergency number from emergencynumberapi.com: dispatch, else police, else ambulance. */
export function parseEmergency(body: unknown): string | null {
  const data = (body as { data?: unknown } | null)?.data;
  if (!data || typeof data !== "object") return null;
  const lower = Object.fromEntries(Object.entries(data as Record<string, unknown>).map(([k, v]) => [k.toLowerCase(), v]));
  for (const service of ["dispatch", "police", "ambulance"]) {
    const s = lower[service] as Record<string, unknown> | undefined;
    if (!s) continue;
    const all = (s.All ?? s.all) as unknown;
    if (Array.isArray(all)) {
      const n = all.map(str).find((x) => x !== null);
      if (n) return n;
    }
  }
  return null;
}

/**
 * The country's zone for the capital, when the zone list names it
 * (`Asia/Jakarta` for Jakarta); null when it does not, so the caller asks
 * where the capital is. A country with one zone has that one.
 */
export function zoneNamingCapital(zones: string[], capital: string | null): string | null {
  if (zones.length === 1) return zones[0];
  if (!capital) return null;
  const want = capital.normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/\s+/g, "_").toLowerCase();
  return zones.find((z) => z.split("/").pop()!.toLowerCase() === want) ?? null;
}

/** The first hit of an Open-Meteo geocoding search: its IANA zone and position. */
export function parseOpenMeteo(body: unknown): { timezone: string | null; lat: number; lng: number } | null {
  const results = (body as { results?: unknown } | null)?.results;
  const first = Array.isArray(results) ? (results[0] as Record<string, unknown> | undefined) : undefined;
  const lat = num(first?.latitude), lng = num(first?.longitude);
  if (!first || lat === null || lng === null) return null;
  const z = str(first.timezone);
  return { timezone: z && z.includes("/") ? z : null, lat, lng };
}

/** Names to search the capital by: as written, then without "D.C." and the like. */
export function capitalQueries(capital: string): string[] {
  const plain = capital.split(/[,(]/)[0].replace(/\s+[A-Z]\.([A-Z]\.)*$/, "").trim();
  return plain && plain !== capital ? [capital, plain] : [capital];
}

/** The language code the app uses: the first non-English official language, else English (`ms-MY`). */
export function languageCodeFor(facts: CountryFacts): string {
  const lang = facts.languages.find((l) => l !== "en") ?? facts.languages[0] ?? "en";
  return `${lang}-${facts.iso2}`;
}

/** The locale's short date pattern as the admin page writes it (`DD/MM/YYYY`). */
export function dateFormatFor(locale: string): string | null {
  try {
    const parts = new Intl.DateTimeFormat(locale, { day: "2-digit", month: "2-digit", year: "numeric" })
      .formatToParts(new Date(Date.UTC(2024, 11, 31)));
    const out = parts
      .map((p) => {
        switch (p.type) {
          case "day":
            return "DD";
          case "month":
            return "MM";
          case "year":
            return "YYYY";
          case "literal":
            return p.value;
          default:
            return "";
        }
      })
      .join("")
      // Bidi marks some locales put around the separators (ar-AE).
      .replace(/[\u200e\u200f\u061c]/g, "")
      .trim();
    return /DD/.test(out) && /MM/.test(out) && /YYYY/.test(out) ? out : null;
  } catch {
    return null;
  }
}

export function mergeDefaults(
  facts: CountryFacts,
  extra: { timezone: string | null; emergencyNumber: string | null; lat?: number | null; lng?: number | null },
): RegionDefaults {
  const languageCode = languageCodeFor(facts);
  return {
    iso2: facts.iso2,
    country: facts.name,
    currencyName: facts.currencyName,
    currencySymbol: facts.currencySymbol,
    callingCode: facts.callingCode,
    languageCode,
    dateFormat: dateFormatFor(languageCode),
    timezone: extra.timezone,
    emergencyNumber: extra.emergencyNumber,
    lat: extra.lat ?? facts.lat,
    lng: extra.lng ?? facts.lng,
  };
}
