import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import { apiKeyFrom, base64, emailProvider, resendProvider, senderOk } from "./email.ts";

const KEY = "re_test_123456789";
const providers = [
  { id: "email", services: [{ id: "resend", keys: [{ id: "a", value: "re_off", disabled: true }, { id: "b", value: ` ${KEY} ` }] }] },
];

Deno.test("the key: API Keys first (the first one on), else the function secret", () => {
  assertEquals(apiKeyFrom(providers, "email", "resend"), KEY);
  assertEquals(apiKeyFrom({ providers }, "email", "resend"), KEY);
  assertEquals(apiKeyFrom([], "email", "resend"), null);
  assert(emailProvider(providers, () => undefined) !== null);
  assert(emailProvider(null, (n) => (n === "RESEND_API_KEY" ? "re_env" : undefined)) !== null);
  assertEquals(emailProvider(null, () => "  "), null);
});

Deno.test("Resend: the request, and a refusal without the key in it", async () => {
  let seen: { url?: string; init?: RequestInit } = {};
  const ok = resendProvider(KEY, (url, init) => {
    seen = { url: String(url), init };
    return Promise.resolve(new Response(JSON.stringify({ id: "em_1" }), { status: 200 }));
  });
  const sent = await ok.send({
    from: "GET.ride Reports <reports@getride.my>",
    to: ["a@example.com"],
    subject: "S",
    text: "T",
    html: "<p>T</p>",
    attachments: [{ filename: "r.csv", content: "YQ==" }],
  });
  assertEquals(sent, { ok: true, id: "em_1" });
  assertEquals(seen.url, "https://api.resend.com/emails");
  assertEquals((seen.init?.headers as Record<string, string>).Authorization, `Bearer ${KEY}`);
  const body = JSON.parse(String(seen.init?.body));
  assertEquals(body.attachments, [{ filename: "r.csv", content: "YQ==" }]);

  const bad = resendProvider(KEY, () =>
    Promise.resolve(new Response(JSON.stringify({ message: `invalid key ${KEY}` }), { status: 403 })));
  const out = await bad.send({ from: "a@b.co", to: ["x@y.co"], subject: "", text: "", html: "" });
  assert(!out.ok && out.error.includes("403") && !out.error.includes(KEY));
});

Deno.test("senders and base64", () => {
  assert(senderOk("GET.ride Reports <reports@getride.my>"));
  assert(senderOk("reports@getride.my"));
  assert(!senderOk("reports"));
  assert(!senderOk(null));
  const bytes = new Uint8Array(70000).map((_, i) => i * 7);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  assertEquals(base64(bytes), btoa(bin));
  assertEquals(base64(new Uint8Array([1, 2])), btoa("\x01\x02"));
});
