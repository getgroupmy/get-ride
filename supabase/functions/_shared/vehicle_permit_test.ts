/**
 * vehicle-permit-read shaping: the prompt names the fields, the answer is
 * cleaned, dates are normalised, and plate comparison is tolerant.
 *
 *     deno test supabase/functions/_shared/vehicle_permit_test.ts
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import { hasAnyField, normalizePermit, permitDate, PERMIT_PROMPT, platesMatch } from "./vehicle_permit.ts";

Deno.test("prompt asks for the permit fields", () => {
  assertStringIncludes(PERMIT_PROMPT, '"document_number"');
  assertStringIncludes(PERMIT_PROMPT, '"plate"');
  assertStringIncludes(PERMIT_PROMPT, '"expiry_date"');
});

Deno.test("normalize cleans the fields and parses the date", () => {
  const f = normalizePermit({
    document_number: " APAD-123456 ",
    expiry_date: "valid until 31/12/2026",
    plate: "wxy 1234",
    authority: "APAD",
  });
  assertEquals(f.document_number, "APAD-123456");
  assertEquals(f.expiry_date, "2026-12-31");
  assertEquals(f.plate, "wxy 1234");
  assertEquals(f.authority, "APAD");
  assert(hasAnyField(f));
});

Deno.test("null / junk become null; a non-object yields all-null", () => {
  const f = normalizePermit({ document_number: "", expiry_date: "n/a", plate: "-", authority: "null" });
  assertEquals(f.document_number, null);
  assertEquals(f.expiry_date, null);
  assertEquals(f.plate, null);
  assertEquals(f.authority, null);
  assert(!hasAnyField(f));
  assert(!hasAnyField(normalizePermit("nope")));
});

Deno.test("permitDate: several spellings, else null", () => {
  assertEquals(permitDate("2026-01-05"), "2026-01-05");
  assertEquals(permitDate("5/1/2026"), "2026-01-05");
  assertEquals(permitDate("05-01-2026"), "2026-01-05");
  assertEquals(permitDate("12 Jan 2026"), "2026-01-12");
  assertEquals(permitDate("13/13/2026"), null); // no month 13
  assertEquals(permitDate("sometime"), null);
});

Deno.test("platesMatch ignores case and separators", () => {
  assert(platesMatch("WXY 1234", "wxy-1234"));
  assert(platesMatch("ABC1234", "A B C 1 2 3 4"));
  assert(!platesMatch("WXY 1234", "WXY 1235"));
  assert(!platesMatch("", "WXY 1234"));
  assert(!platesMatch(null, null));
});
