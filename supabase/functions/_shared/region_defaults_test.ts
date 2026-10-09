/**
 * Fill defaults: reading the public APIs' answers.
 *
 *     deno test supabase/functions/_shared/region_defaults_test.ts
 */
import { assertEquals } from "jsr:@std/assert@1.0.19";

import {
  dateFormatFor,
  languageCodeFor,
  mergeDefaults,
  parseEmergency,
  capitalQueries,
  parseOpenMeteo,
  parseRestCountry,
  zoneNamingCapital,
} from "./region_defaults.ts";

// Abridged from https://restcountries.com/v3.1/name/malaysia?fullText=true
const malaysia = [
  {
    name: { common: "Malaysia", official: "Malaysia" },
    cca2: "MY",
    currencies: { MYR: { name: "Malaysian ringgit", symbol: "RM" } },
    idd: { root: "+6", suffixes: ["0"] },
    languages: { eng: "English", msa: "Malay" },
    capital: ["Kuala Lumpur"],
    latlng: [2.5, 112.5],
    capitalInfo: { latlng: [3.17, 101.7] },
  },
];

Deno.test("REST Countries: currency code and symbol, calling code, languages, the capital", () => {
  const f = parseRestCountry(malaysia)!;
  assertEquals(f.iso2, "MY");
  assertEquals([f.currencyName, f.currencySymbol, f.callingCode], ["MYR", "RM", "+60"]);
  assertEquals(f.languages, ["en", "ms"]);
  assertEquals([f.lat, f.lng], [3.17, 101.7]);
  assertEquals(f.capital, "Kuala Lumpur");
  assertEquals(languageCodeFor(f), "ms-MY");
});

Deno.test("several dialling suffixes are area codes: only the root is the country code", () => {
  const us = parseRestCountry([{ cca2: "US", idd: { root: "+1", suffixes: ["201", "202"] }, languages: { eng: "English" } }])!;
  assertEquals(us.callingCode, "+1");
  assertEquals(languageCodeFor(us), "en-US");
  assertEquals(parseRestCountry([]), null);
  assertEquals(parseRestCountry({ status: 404, message: "Not Found" }), null);
});

Deno.test("emergency number: dispatch, else police; empty entries skipped", () => {
  assertEquals(
    parseEmergency({ data: { Dispatch: { All: [null] }, Police: { All: ["999"] }, Ambulance: { All: ["999"] } } }),
    "999",
  );
  assertEquals(parseEmergency({ data: { Dispatch: { All: ["112"] }, Police: { All: ["110"] } } }), "112");
  assertEquals(parseEmergency({ error: "x" }), null);
});

Deno.test("date format from the locale", () => {
  assertEquals(dateFormatFor("en-GB"), "DD/MM/YYYY");
  assertEquals(dateFormatFor("en-US"), "MM/DD/YYYY");
  assertEquals(dateFormatFor("ja-JP"), "YYYY/MM/DD");
  assertEquals(dateFormatFor("ar-AE"), "DD/MM/YYYY", "no right-to-left marks");
});

Deno.test("merged defaults", () => {
  const d = mergeDefaults(parseRestCountry(malaysia)!, { timezone: "Asia/Kuala_Lumpur", emergencyNumber: "999" });
  assertEquals(d.currencyName, "MYR");
  assertEquals(d.languageCode, "ms-MY");
  assertEquals(d.dateFormat, "DD/MM/YYYY");
  assertEquals(d.timezone, "Asia/Kuala_Lumpur");
});

Deno.test("the capital's zone: named in the list, or looked up", () => {
  assertEquals(zoneNamingCapital(["Asia/Jakarta", "Asia/Jayapura", "Asia/Makassar"], "Jakarta"), "Asia/Jakarta");
  assertEquals(zoneNamingCapital(["America/Bogota"], "Bogotá"), "America/Bogota");
  assertEquals(zoneNamingCapital(["Europe/Madrid", "Atlantic/Canary"], "Madrid"), "Europe/Madrid");
  // Malaysia's list has no Kuala Lumpur entry: the caller asks where it is.
  assertEquals(zoneNamingCapital(["Asia/Kuching", "Asia/Singapore"], "Kuala Lumpur"), null);
  // Abridged from geocoding-api.open-meteo.com/v1/search?name=Kuala%20Lumpur&countryCode=MY
  assertEquals(
    parseOpenMeteo({ results: [{ name: "Kuala Lumpur", latitude: 3.1412, longitude: 101.68653, timezone: "Asia/Kuala_Lumpur" }] }),
    { timezone: "Asia/Kuala_Lumpur", lat: 3.1412, lng: 101.68653 },
  );
  assertEquals(parseOpenMeteo({ generationtime_ms: 0.3 }), null);
  assertEquals(capitalQueries("Washington D.C."), ["Washington D.C.", "Washington"]);
  assertEquals(capitalQueries("Kuala Lumpur"), ["Kuala Lumpur"]);
});
