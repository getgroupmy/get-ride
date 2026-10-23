import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import { amzDates, parseAwsKey, signedJsonPost } from "./aws_sigv4.ts";

Deno.test("the stored key: id and secret, and a region when given", () => {
  assertEquals(parseAwsKey("AKIAIOSFODNN7EXAMPLE:wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"), {
    accessKeyId: "AKIAIOSFODNN7EXAMPLE",
    secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    region: "ap-southeast-1",
  });
  assertEquals(parseAwsKey(" AKIAIOSFODNN7EXAMPLE : wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY : eu-west-1 ")?.region, "eu-west-1");
  assertEquals(parseAwsKey("AKIAIOSFODNN7EXAMPLE:wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY:nowhere")?.region, "ap-southeast-1");
  assertEquals(parseAwsKey("just-one-thing"), null);
  assertEquals(parseAwsKey("lower:case-secret-long-enough"), null);
  assertEquals(parseAwsKey(""), null);
});

Deno.test("a signed request names its target, date and scope", async () => {
  const key = parseAwsKey("AKIAIOSFODNN7EXAMPLE:wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY:ap-southeast-1")!;
  const now = new Date("2026-10-24T11:00:00.000Z");
  assertEquals(amzDates(now), { amzDate: "20261024T110000Z", day: "20261024" });
  const a = await signedJsonPost(key, "rekognition", "RekognitionService.ListCollections", "{}", now);
  const b = await signedJsonPost(key, "rekognition", "RekognitionService.ListCollections", "{}", now);
  assertEquals(a.url, "https://rekognition.ap-southeast-1.amazonaws.com/");
  assertEquals(a.headers["X-Amz-Target"], "RekognitionService.ListCollections");
  assert(a.headers.Authorization.startsWith(
    "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261024/ap-southeast-1/rekognition/aws4_request, ",
  ));
  assert(/Signature=[0-9a-f]{64}$/.test(a.headers.Authorization));
  assertEquals(a.headers.Authorization, b.headers.Authorization, "the same request signs the same");
  const c = await signedJsonPost(key, "rekognition", "RekognitionService.ListCollections", "{\"x\":1}", now);
  assert(c.headers.Authorization !== a.headers.Authorization, "the body is signed");
  assert(!JSON.stringify(a).includes(key.secretAccessKey), "the secret is never sent");
});
