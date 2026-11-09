/**
 * vehicle-registration-read shaping (migration 0388): the prompt names the
 * fields, and the model's answer is cleaned into vehicle fields.
 *
 *     deno test supabase/functions/_shared/vehicle_registration_test.ts
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import { hasAnyField, normalizeRegistration, REGISTRATION_PROMPT } from "./vehicle_registration.ts";

Deno.test("prompt asks for the certificate fields", () => {
  assertStringIncludes(REGISTRATION_PROMPT, '"plate"');
  assertStringIncludes(REGISTRATION_PROMPT, '"seats"');
  assertStringIncludes(REGISTRATION_PROMPT, '"document_number"');
});

Deno.test("normalize cleans and bounds the fields", () => {
  const f = normalizeRegistration({
    plate: " AMX9282 ", make: "Perodua", model: "Alza", seats: "7 seats",
    color: "Silver", year: "made 2023", vin: "PM2B300S003063743",
    engine_number: "2NR3A85787", document_number: "KRH80D70F",
  });
  assertEquals(f.plate, "AMX9282");
  assertEquals(f.seats, 7);
  assertEquals(f.year, "2023");
  assertEquals(f.vin, "PM2B300S003063743");
  assert(hasAnyField(f));
});

Deno.test("null / junk / out-of-range become null", () => {
  const f = normalizeRegistration({
    plate: "", make: "null", model: "-", seats: 999, color: null, year: "n/a",
    vin: undefined, engine_number: "  ", document_number: 0,
  });
  assertEquals(f.plate, null);
  assertEquals(f.make, null);
  assertEquals(f.model, null);
  assertEquals(f.seats, null); // 999 out of range
  assertEquals(f.year, null);
  assertEquals(f.engine_number, null);
  assert(!hasAnyField(f));
});

Deno.test("a non-object answer yields all-null", () => {
  assert(!hasAnyField(normalizeRegistration(null)));
  assert(!hasAnyField(normalizeRegistration("nope")));
});
