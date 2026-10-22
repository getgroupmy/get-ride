import { assertEquals } from "jsr:@std/assert@1.0.19";

import { callerOf, noticeText, rideIdOf, whatsappNumber, whatsappRequest } from "./freight_notify.ts";

const notice = {
  id: "n1",
  channel: "whatsapp" as const,
  to_phone: "+60 12-345 6789",
  body: "GET.ride: Mei, your delivery from Aisyah is on its way. Track it here: ",
  share_token: "11111111-2222-3333-4444-555555555555",
};

Deno.test("the text carries the share link", () => {
  assertEquals(
    noticeText(notice, "https://getride.my/"),
    "GET.ride: Mei, your delivery from Aisyah is on its way. Track it here: " +
      "https://getride.my/share/11111111-2222-3333-4444-555555555555",
  );
  assertEquals(noticeText({ ...notice, share_token: null }), notice.body.trim());
});

Deno.test("a courier notice carries the code after the link", () => {
  const courier = {
    ...notice,
    body: "GET.ride: Mei, a parcel from Aisyah is on its way to you. Track it here: ",
    delivery_code: "4817",
  };
  assertEquals(
    noticeText(courier, "https://getride.my"),
    "GET.ride: Mei, a parcel from Aisyah is on its way to you. Track it here: " +
      "https://getride.my/share/11111111-2222-3333-4444-555555555555 " +
      "Your delivery code is 4817. Give it to the courier only once you have the parcel.",
  );
  assertEquals(noticeText({ ...courier, delivery_code: "12; x" }, "https://getride.my").includes("code"), false);
  assertEquals(noticeText({ ...courier, delivery_code: null }).includes("delivery code"), false);
});

Deno.test("WhatsApp: digits only, and nothing without the secrets", () => {
  assertEquals(whatsappNumber(notice.to_phone), "60123456789");
  assertEquals(whatsappRequest(notice, "hi", {}), null);
  const r = whatsappRequest(notice, "hi", { token: "t", phoneNumberId: "99" })!;
  assertEquals(r.url, "https://graph.facebook.com/v19.0/99/messages");
  assertEquals(JSON.parse(r.init.body as string).to, "60123456789");
});

Deno.test("the ride asked about", () => {
  assertEquals(rideIdOf({ rideId: "11111111-2222-3333-4444-555555555555" }), "11111111-2222-3333-4444-555555555555");
  assertEquals(rideIdOf({ rideId: "1; drop" }), null);
  assertEquals(rideIdOf(null), null);
});

Deno.test("who is calling", async () => {
  const deps = { serviceKey: "svc", secretOk: (s: string) => Promise.resolve(s === "good") };
  const req = (h: Record<string, string>) => new Request("http://x", { method: "POST", headers: h });
  assertEquals((await callerOf(req({ "x-push-secret": "good" }), deps)).caller, "job");
  assertEquals((await callerOf(req({ "x-push-secret": "bad" }), deps)).caller, null);
  assertEquals((await callerOf(req({ authorization: "Bearer svc" }), deps)).caller, "service");
  assertEquals((await callerOf(req({ authorization: "Bearer user-jwt" }), deps)).caller, "user");
  assertEquals((await callerOf(req({}), deps)).caller, null);
});
