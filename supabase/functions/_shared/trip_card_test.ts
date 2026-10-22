// The server's trip card (trip_card.ts) against the cases the phone's
// builder is held to too (trip_card_cases.json, test/trip_card_cases_test.dart),
// plus what only the server does: the ride's own time zone, the admin's
// switches, and never a trip code or a delivery code.
//
//     deno test --allow-read=lib,supabase supabase/functions/_shared/trip_card_test.ts
import { assert, assertAlmostEquals, assertEquals } from "jsr:@std/assert@1.0.19";

import {
  allows,
  buildTripCard,
  formatMoney,
  formatTime,
  km,
  tripCardFor,
  tripCardLink,
  tripCardSettings,
  type TripRide,
} from "./trip_card.ts";

const cases = JSON.parse(
  await Deno.readTextFile(new URL("./trip_card_cases.json", import.meta.url)),
) as {
  now: string;
  base: TripRide;
  cases: { name: string; asDriver?: boolean; extra: Partial<TripRide>; expect: Record<string, unknown> | null }[];
};

const now = new Date(cases.now);
const ride = (extra: Partial<TripRide>): TripRide => ({ ...cases.base, ...extra });

for (const c of cases.cases) {
  Deno.test(`same card as the phone: ${c.name}`, () => {
    const card = tripCardFor(ride(c.extra), c.asDriver === true, now);
    if (c.expect === null) {
      assertEquals(card, null);
      return;
    }
    assert(card !== null, "a card");
    const got = card as unknown as Record<string, unknown>;
    // The phone leaves unset keys out; the server sends them as null so a
    // patch clears what the last stage showed.
    for (const [key, value] of Object.entries(got)) {
      if (value === null) {
        assert(!(key in c.expect), `${key} is null here but ${JSON.stringify(c.expect[key])} on the phone`);
      } else if (key === "progress") {
        assertAlmostEquals(value as number, c.expect.progress as number, 1e-9);
      } else {
        assertEquals(value, c.expect[key], key);
      }
    }
    for (const key of Object.keys(c.expect)) assert(key in got, `${key} is missing`);
  });
}

Deno.test("the trip code and the delivery code are never on the card", () => {
  const secret = { otp: "4719", delivery_code: "4719", trip_code: "4719" } as Partial<TripRide>;
  for (const status of ["open", "accepted", "arrived", "on_trip", "completed"]) {
    for (const extra of [{}, { parcel_size: "S", cargo_description: "Documents" }, { cargo_description: "Sofa" }]) {
      for (const asDriver of [false, true]) {
        const card = tripCardFor(ride({ ...secret, ...extra, status }), asDriver, now);
        if (card === null) continue;
        const sent = JSON.stringify(card);
        assert(!sent.includes("4719"), `${status} ${asDriver}`);
        assert(!sent.includes("→"));
      }
    }
  }
});

Deno.test("clock times are the ride's own time zone, else Kuala Lumpur's", () => {
  const t = new Date("2026-10-22T07:48:00Z");
  assertEquals(formatTime(t, "UTC"), "7:48 AM");
  assertEquals(formatTime(t, "Asia/Kuala_Lumpur"), "3:48 PM");
  assertEquals(formatTime(t, "Not/AZone"), "3:48 PM");
  const card = tripCardFor(ride({ status: "on_trip", timezone: null }), false, now)!;
  assertEquals(card.headline, "You will arrive at 4:10 PM");
  assertEquals(card.compact, "4:10");
  assertEquals(card.etaMs, now.getTime() + 22 * 60000);
});

Deno.test("money as the phone writes it", () => {
  assertEquals(formatMoney(18.5, "MYR"), "RM18.50");
  assertEquals(formatMoney(1234567.891, "usd"), "$1,234,567.89");
  assertEquals(formatMoney(85000, "VND"), "85,000₫");
  assertEquals(formatMoney(1200, "JPY"), "¥1,200");
  assertEquals(formatMoney(12, "XYZ"), "XYZ 12.00");
});

Deno.test("distances as latlong2 counts them (Vincenty, whole metres)", () => {
  // Mid Valley to KLCC.
  assertEquals(km({ lat: 3.118, lng: 101.677 }, { lat: 3.1579, lng: 101.7116 }), 5.853);
  assertEquals(km({ lat: 3.1, lng: 101.6 }, { lat: 3.1, lng: 101.6 }), 0);
});

Deno.test("progress: each stage on its stretch of the bar", () => {
  const at = (status: string, extra: Partial<TripRide> = {}) => tripCardFor(ride({ status, ...extra }), false, now)!.progress;
  assertAlmostEquals(at("open"), 0.04, 1e-9);
  assert(at("accepted") > 0.05 && at("accepted") < 0.45);
  assertAlmostEquals(at("arrived"), 0.45, 1e-9);
  assertAlmostEquals(at("on_trip", { partner_live_lat: 3.1579, partner_live_lng: 101.7116 }), 1, 1e-9);
  assertEquals(at("completed"), 1);
});

Deno.test("the done card is not ongoing; the others are", () => {
  assertEquals(tripCardFor(ride({ status: "completed" }), false, now)!.ongoing, false);
  assertEquals(tripCardFor(ride({ status: "on_trip" }), false, now)!.ongoing, true);
});

Deno.test("links: the trip, each button, the driver's own", () => {
  assertEquals(tripCardLink("ride-1", false), "getride://trip/ride-1");
  assertEquals(tripCardLink("ride-1", false, "call"), "getride://trip/ride-1?do=call");
  assertEquals(tripCardLink("ride-1", true, "chat"), "getride://trip/ride-1?do=chat&as=driver");
  assertEquals(tripCardLink("ride-1", true), "getride://trip/ride-1?as=driver");
});

Deno.test("a driver's card waits for the driver to take the ride", () => {
  assertEquals(buildTripCard(ride({ status: "open" }), { asDriver: true, now }), null);
});

Deno.test("admin switches: missing is on with 5 minutes, per service and for drivers", () => {
  const d = tripCardSettings(undefined);
  assertEquals(d, { ride: true, courier: true, freight: true, driver: true, doneMinutes: 5 });
  const s = tripCardSettings({ ride: true, courier: false, freight: "no", driver: false, doneMinutes: 999 });
  assertEquals(s.freight, true, "only a boolean switches it");
  assertEquals(s.doneMinutes, 60);
  assertEquals(tripCardSettings({ doneMinutes: -3 }).doneMinutes, 0);
  assertEquals(tripCardSettings({ doneMinutes: 2.4 }).doneMinutes, 2);
  assert(allows(s, "ride", false));
  assert(!allows(s, "courier", false));
  assert(!allows(s, "ride", true));
  assert(allows({ ...s, driver: true }, "freight", true));
});
