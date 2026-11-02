import { assertEquals } from "jsr:@std/assert@1.0.19";

import { isNewsBroadcast, newsLeftOut, newsRecipients } from "./news_offers.ts";

Deno.test("an admin's or a scheduled broadcast is News and offers", () => {
  assertEquals(isNewsBroadcast({}, "admin"), true);
  assertEquals(isNewsBroadcast({ scheduleId: "s1" }, "webhook"), true);
  assertEquals(isNewsBroadcast({ news: true }, "service"), true);
});

Deno.test("trip, money, safety and account pushes never are", () => {
  assertEquals(isNewsBroadcast({}, "webhook"), false, "a ride request to drivers");
  assertEquals(isNewsBroadcast({ data: { type: "ride_request" } }, "admin"), false);
  assertEquals(isNewsBroadcast({ data: { type: "safety_incident" } }, "service"), false);
  assertEquals(isNewsBroadcast({ profileId: "u1" }, "admin"), false, "God View's push to one person");
  assertEquals(isNewsBroadcast({ profileId: "u1", scheduleId: "s1" }, "webhook"), false);
});

Deno.test("a broadcast reaches opted-in accounts only, never a signed-out phone", () => {
  const rows = [{ profile_id: "a" }, { profile_id: "b" }, { profile_id: null }, { profile_id: "a" }, { profile_id: "c" }];
  const optedIn = new Set(["a", "z"]);
  assertEquals(newsRecipients(rows, optedIn).map((r) => r.profile_id), ["a", "a"]);
  assertEquals(newsLeftOut(rows, optedIn), 2);
});
