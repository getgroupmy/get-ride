/**
 * What turn-credentials hands a caller.
 *
 *     deno test supabase/functions/_shared/turn_test.ts
 */
import { assertEquals } from "jsr:@std/assert@1.0.19";

import { DEFAULT_STUN_URLS, iceServersFor, splitUrls, turnPassword, turnUsername } from "./turn.ts";

Deno.test("relay URLs are a trimmed comma list", () => {
  assertEquals(splitUrls(" turn:a.example:3478 , turns:a.example:5349,, "), [
    "turn:a.example:3478",
    "turns:a.example:5349",
  ]);
  assertEquals(splitUrls(undefined), []);
});

Deno.test("credentials follow the TURN REST API", async () => {
  assertEquals(turnUsername("user-1", 1700000000.9, 3600), "1700003600:user-1");
  // python: base64(hmac.new(b'shh-secret', b'1700003600:user-1', sha1).digest())
  assertEquals(await turnPassword("shh-secret", "1700003600:user-1"), "B53GzZgzcOyrc9vPCv8tzBSRP9I=");
});

Deno.test("TURN is offered only with both URLs and a secret", async () => {
  const both = await iceServersFor({
    userId: "user-1",
    nowSeconds: 1700000000,
    turnUrls: ["turn:a.example:3478"],
    turnSecret: "shh-secret",
    ttl: 3600,
  });
  assertEquals(both.relay, true);
  assertEquals(both.iceServers, [
    { urls: DEFAULT_STUN_URLS },
    { urls: ["turn:a.example:3478"], username: "1700003600:user-1", credential: "B53GzZgzcOyrc9vPCv8tzBSRP9I=" },
  ]);

  const noSecret = await iceServersFor({ userId: "u", nowSeconds: 0, turnUrls: ["turn:a.example"], turnSecret: " " });
  assertEquals(noSecret.relay, false);
  assertEquals(noSecret.iceServers, [{ urls: DEFAULT_STUN_URLS }]);

  const ownStun = await iceServersFor({ userId: "u", nowSeconds: 0, turnUrls: [], stunUrls: ["stun:mine:3478"] });
  assertEquals(ownStun.iceServers, [{ urls: ["stun:mine:3478"] }]);
});
