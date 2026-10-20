import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import {
  fromBase64Url,
  fromHex,
  hmacSha256,
  hmacSha256Base64,
  hmacSha256Hex,
  md5Hex,
  safeEqual,
  sha256Hex,
  toBase64Url,
} from "./crypto.ts";

Deno.test("md5: RFC 1321 appendix A.5 test suite", () => {
  assertEquals(md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e");
  assertEquals(md5Hex("a"), "0cc175b9c0f1b6a831c399e269772661");
  assertEquals(md5Hex("abc"), "900150983cd24fb0d6963f7d28e17f72");
  assertEquals(md5Hex("message digest"), "f96b697d7cb7938d525a2f31aaf161d0");
  assertEquals(md5Hex("abcdefghijklmnopqrstuvwxyz"), "c3fcd3d76192e4007dfb496cca67e13b");
  assertEquals(
    md5Hex("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"),
    "d174ab98d277d9f5a5611c2c9f419d9f",
  );
  assertEquals(
    md5Hex("12345678901234567890123456789012345678901234567890123456789012345678901234567890"),
    "57edf4a22be3c955ac49da2e2107b67a",
  );
});

Deno.test("sha256: FIPS 180-2 'abc'", async () => {
  assertEquals(await sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
});

Deno.test("hmac-sha256: RFC 4231 test case 2", async () => {
  assertEquals(
    await hmacSha256Hex("Jefe", "what do ya want for nothing?"),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
  );
});

Deno.test("hmac-sha256 with a binary key, base64: Adyen's documented HMAC example", async () => {
  // https://docs.adyen.com/development-resources/webhooks/verify-hmac-signatures
  assertEquals(
    await hmacSha256Base64(
      fromHex("44782DEF547AAA06C910C43932B1EB0C71FC68D9D0C057550C48EC2ACF6BA056"),
      "7914073381342284::TestMerchant:TestPayment-1407325143704:1130:EUR:AUTHORISATION:true",
    ),
    "coqCmt/IZ4E3CzPvMY8zTjQVL5hYJUiBRg8UU+iCWo0=",
  );
});

Deno.test("HS256 JWS: RFC 7515 appendix A.1", async () => {
  const key = fromBase64Url("AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow");
  const input = "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9" +
    ".eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ";
  assertEquals(toBase64Url(await hmacSha256(key, input)), "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk");
});

Deno.test("safeEqual", () => {
  assert(safeEqual("abc", "abc"));
  assert(!safeEqual("abc", "abd"));
  assert(!safeEqual("abc", "abcd"));
  assert(!safeEqual("", "a"));
});
