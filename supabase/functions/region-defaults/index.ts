// ============================================================================
// region-defaults — Supabase Edge Function
// ----------------------------------------------------------------------------
// Admin → Country / States / Cities → Fill defaults: a country's currency,
// calling code, language, date format, time zone and emergency number.
//
// Country facts and zone lists come from open datasets bundled with the
// function (world-countries, countries-and-timezones), so they answer
// without a third party being up. Two things are looked up live and are
// optional (null when the source is down; the admin page then keeps its own
// fallback): the capital's time zone and position (Open-Meteo geocoding),
// and the emergency number (emergencynumberapi.com).
//
// Request:  GET ?country=<name or ISO 3166 alpha-2 code>
// Response: { iso2, country, currencyName, currencySymbol, callingCode,
//             languageCode, dateFormat, timezone, emergencyNumber, lat, lng }
//           404 { error } when no country matches.
//
// Deploy (the gateway checks for the project's key or a session):
//   supabase functions deploy region-defaults
// ============================================================================
import countries from "npm:world-countries@5.1.0";
import ct from "npm:countries-and-timezones@3.10.0";

import {
  capitalQueries,
  mergeDefaults,
  parseEmergency,
  parseOpenMeteo,
  parseRestCountry,
  zoneNamingCapital,
} from "../_shared/region_defaults.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "public, max-age=86400" },
  });
}

async function getJson(url: string, ms = 8000): Promise<unknown> {
  const res = await fetch(url, {
    signal: AbortSignal.timeout(ms),
    headers: { Accept: "application/json", "User-Agent": "GET.ride admin (getride.my)" },
  });
  if (!res.ok) throw new Error(`${res.status} from ${new URL(url).host}`);
  return await res.json();
}

async function optional<T>(f: () => Promise<T>): Promise<T | null> {
  try {
    return await f();
  } catch {
    return null;
  }
}

type Country = Record<string, unknown> & { cca2: string; name: { common: string; official: string }; altSpellings?: string[] };
const all = countries as unknown as Country[];

function find(q: string): Country | undefined {
  const k = q.trim().toLowerCase();
  return (
    all.find((c) => c.cca2.toLowerCase() === k || String(c.cca3 ?? "").toLowerCase() === k) ??
    all.find((c) => c.name.common.toLowerCase() === k || c.name.official.toLowerCase() === k) ??
    all.find((c) => (c.altSpellings ?? []).some((a) => a.toLowerCase() === k)) ??
    all.find((c) => c.name.common.toLowerCase().startsWith(k))
  );
}

/** The capital's zone and position, from Open-Meteo's geocoder; null when it cannot say. */
async function capitalPlace(iso2: string, capital: string | null) {
  if (!capital) return null;
  for (const name of capitalQueries(capital)) {
    const hit = parseOpenMeteo(
      await optional(() =>
        getJson(
          `https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(name)}&count=1&countryCode=${iso2}`,
        )
      ),
    );
    if (hit) return hit;
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const q = (new URL(req.url).searchParams.get("country") ?? "").trim();
  if (q.length < 2 || q.length > 80) return json({ error: "Give ?country=<name or code>." }, 400);

  const facts = parseRestCountry(find(q));
  if (!facts) return json({ error: `No country matches "${q}".` }, 404);

  const [place, emergency] = await Promise.all([
    capitalPlace(facts.iso2, facts.capital),
    optional(() => getJson(`https://emergencynumberapi.com/api/country/${facts.iso2}`)),
  ]);
  // The capital's own zone first; else the country's zone the capital names; else its first.
  const zones: string[] = ct.getCountry(facts.iso2)?.timezones ?? [];
  const timezone = place?.timezone ?? zoneNamingCapital(zones, facts.capital) ?? zones[0] ?? null;
  return json(
    mergeDefaults(facts, { timezone, emergencyNumber: parseEmergency(emergency), lat: place?.lat, lng: place?.lng }),
  );
});
