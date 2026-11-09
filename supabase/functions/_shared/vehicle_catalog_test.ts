/**
 * The vehicle-catalog-lookup shaping (migration 0387): the prompt names the
 * catalogue's vocabulary, and the model's answer is validated into clean rows.
 *
 *     deno test supabase/functions/_shared/vehicle_catalog_test.ts
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import { buildCatalogPrompt, normalizeCatalogEntries } from "./vehicle_catalog.ts";

Deno.test("prompt scopes to one model or to common models, and lists the vocabulary", () => {
  const one = buildCatalogPrompt("Perodua", "Alza", ["Petrol", "Hybrid"], ["MPV", "SUV"]);
  assertStringIncludes(one, 'model "Alza"');
  assertStringIncludes(one, "Petrol, Hybrid");
  assertStringIncludes(one, "MPV, SUV");

  const many = buildCatalogPrompt("Perodua", null, [], []);
  assertStringIncludes(many, "most common models");
  // Falls back to sensible defaults when the catalogue has no vocabulary yet.
  assertStringIncludes(many, "Petrol, Diesel, Hybrid, Electric");
});

Deno.test("normalize keeps valid rows and drops junk", () => {
  const rows = normalizeCatalogEntries(
    {
      entries: [
        { make: "Perodua", model: "Alza", energy_type: "petrol", vehicle_type: "mpv", seats: "7" },
        { make: "Perodua", model: "", energy_type: "Petrol" }, // no model → dropped
        { make: "", model: "Myvi" }, // no make → dropped
        { make: "Toyota", model: "Vios" }, // wrong make → dropped
        { make: "Perodua", model: "Axia", energy_type: "Nuclear", vehicle_type: "Spaceship", seats: 999 },
      ],
    },
    { expectedMake: "perodua", allowedEnergies: ["Petrol", "Hybrid"], allowedTypes: ["MPV", "SUV"] },
  );
  assertEquals(rows.length, 2);
  // Case-folded vocabulary match returns the catalogue's own spelling.
  assertEquals(rows[0], { make: "Perodua", model: "Alza", energy_type: "Petrol", vehicle_type: "MPV", seats: 7 });
  // Out-of-vocabulary energy/type become null; an absurd seat count is dropped.
  assertEquals(rows[1], { make: "Perodua", model: "Axia", energy_type: null, vehicle_type: null, seats: null });
});

Deno.test("normalize collapses duplicate models and tolerates bad input", () => {
  const rows = normalizeCatalogEntries(
    { entries: [{ make: "BYD", model: "Atto 3" }, { make: "BYD", model: "ATTO 3" }] },
    { expectedMake: "BYD", allowedEnergies: [], allowedTypes: [] },
  );
  assertEquals(rows.length, 1);
  assert(normalizeCatalogEntries(null, { expectedMake: "x", allowedEnergies: [], allowedTypes: [] }).length === 0);
  assert(normalizeCatalogEntries({ entries: "nope" }, { expectedMake: "x", allowedEnergies: [], allowedTypes: [] }).length === 0);
});
