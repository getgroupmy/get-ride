/**
 * The composer's extras in send-push (Admin -> Push Notification, 0279): the
 * picture, the full message's id, partners by type.
 *
 *     deno test supabase/functions/_shared/push_composer_test.ts
 */
import { assertEquals } from "jsr:@std/assert@1.0.19";

import {
  fcmData,
  fcmMessage,
  imageUrl,
  partnerAccounts,
  partnerTypeList,
  typesOfPartner,
  uuidOf,
  withMessage,
} from "./push.ts";

const PIC = "https://ref.supabase.co/storage/v1/object/public/media/image/bonus.jpg";

Deno.test("a picture is shown large on Android and offered to an iPhone extension", () => {
  const m = fcmMessage("tok", "Weekend bonus", "RM 30 extra", { message_id: "m1", image: PIC }, PIC).message;
  assertEquals(m.notification, { title: "Weekend bonus", body: "RM 30 extra", image: PIC });
  assertEquals(m.android.notification.image, PIC);
  assertEquals(m.apns.payload.aps, { sound: "default", "mutable-content": 1 });
  assertEquals(m.apns.fcm_options, { image: PIC });
  assertEquals(m.data, { message_id: "m1", image: PIC });
});

Deno.test("without a picture the message is as before", () => {
  const m = fcmMessage("tok", "T", "B", { audience: "all" }).message;
  assertEquals(m.notification, { title: "T", body: "B" });
  assertEquals("image" in m.android.notification, false);
  assertEquals(m.apns.payload.aps, { sound: "default" });
  assertEquals("fcm_options" in m.apns, false);
});

Deno.test("only an https picture is taken", () => {
  assertEquals(imageUrl(` ${PIC} `), PIC);
  assertEquals(imageUrl("http://x.test/a.png"), null);
  assertEquals(imageUrl("javascript:alert(1)"), null);
  assertEquals(imageUrl("https://"), null);
  assertEquals(imageUrl("https://x.test/a b.png"), null);
  assertEquals(imageUrl(42), null);
  assertEquals(imageUrl(`https://x.test/${"a".repeat(1000)}`), null);
});

Deno.test("ids are uuids, lower case", () => {
  assertEquals(uuidOf("0000000A-0000-0000-0000-000000000001"), "0000000a-0000-0000-0000-000000000001");
  assertEquals(uuidOf("m1"), null);
  assertEquals(uuidOf(null), null);
});

Deno.test("the app's data gains the message id and the picture", () => {
  assertEquals(withMessage({ audience: "partners" }, "m1", PIC), { audience: "partners", message_id: "m1", image: PIC });
  assertEquals(withMessage(undefined, "m1", null), { message_id: "m1" });
  assertEquals(withMessage(undefined, null, null), undefined);
  const base = { type: "x" };
  assertEquals(withMessage(base, null, null), base);
  // FCM data stays strings only.
  assertEquals(fcmData(withMessage({ n: 1 }, "m1", PIC)), { n: "1", message_id: "m1", image: PIC });
});

Deno.test("partner types: trimmed, each once, at most 30", () => {
  assertEquals(partnerTypeList([" eHailing ", "ehailing", "Teksi", "", 3, null]), ["eHailing", "Teksi"]);
  assertEquals(partnerTypeList("eHailing"), []);
  assertEquals(partnerTypeList(Array.from({ length: 40 }, (_, i) => `t${i}`)).length, 30);
});

Deno.test("a partner's types: the list, else the legacy column", () => {
  assertEquals(typesOfPartner({ partner_types: ["eHailing", " Teksi "] }), ["eHailing", "Teksi"]);
  assertEquals(typesOfPartner({ partner_types: [], partner_type: "Delivery" }), ["Delivery"]);
  assertEquals(typesOfPartner({ partner_types: '["Fleet"]' }), ["Fleet"]);
  assertEquals(typesOfPartner({ partner_types: null, partner_type: " " }), []);
});

Deno.test("partners of any chosen type, each once; none chosen is every partner", () => {
  const rows = [
    { auth_user_id: "u1", partner_types: ["eHailing", "Teksi"] },
    { auth_user_id: "u2", partner_types: ["Teksi"] },
    { auth_user_id: "u3", partner_types: [], partner_type: "eHailing" },
    { auth_user_id: "u4", partner_types: ["Delivery"] },
    { auth_user_id: null, partner_types: ["Teksi"] },
    // The same account twice (an older duplicate row) is still one partner.
    { auth_user_id: "u2", partner_types: ["eHailing"] },
  ];
  assertEquals([...partnerAccounts(rows, ["ehailing", "TEKSI"])].sort(), ["u1", "u2", "u3"]);
  assertEquals([...partnerAccounts(rows, ["Delivery"])], ["u4"]);
  assertEquals(partnerAccounts(rows, []).size, 4);
  assertEquals(partnerAccounts(rows, ["Fleet"]).size, 0);
});
