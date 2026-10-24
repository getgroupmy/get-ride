import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import {
  compareRequest,
  faceServerKey,
  healthRequest,
  parseFaceServer,
  readServerCompare,
} from "./face_server.ts";

const SECRET = "0123456789abcdef0123";

Deno.test("the stored key: address and secret", () => {
  assertEquals(parseFaceServer(`https://face.getride.my:${SECRET}`), { url: "https://face.getride.my", secret: SECRET });
  assertEquals(parseFaceServer(`https://face.getride.my/:${SECRET}`), { url: "https://face.getride.my", secret: SECRET });
  assertEquals(parseFaceServer(`https://nas.local:8443/face:${SECRET}`), { url: "https://nas.local:8443/face", secret: SECRET });
  assertEquals(parseFaceServer(`  https://face.getride.my  ${SECRET} `), { url: "https://face.getride.my", secret: SECRET });
  assertEquals(parseFaceServer(`http://face.getride.my:${SECRET}`), null, "https only");
  assertEquals(parseFaceServer("https://face.getride.my:short"), null, "a secret too short");
  assertEquals(parseFaceServer("https://face.getride.my"), null, "no secret");
  assertEquals(parseFaceServer(""), null);
});

Deno.test("the first active Face match server key", () => {
  const list = [{
    id: "face_match",
    services: [{
      id: "server",
      keys: [
        { id: "a", value: `https://off.example:${SECRET}`, disabled: true },
        { id: "b", value: "not a server" },
        { id: "c", value: `https://face.getride.my:${SECRET}` },
      ],
    }],
  }];
  assertEquals(faceServerKey(list)?.url, "https://face.getride.my");
  assertEquals(faceServerKey({ providers: list })?.url, "https://face.getride.my");
  assertEquals(faceServerKey([]), null);
  assertEquals(faceServerKey(null), null);
});

Deno.test("the requests carry the key in x-api-key, the photos as base64", () => {
  const server = { url: "https://face.getride.my", secret: SECRET };
  const r = compareRequest(server, new Uint8Array([1, 2, 3]), new Uint8Array([4, 5]));
  assertEquals(r.url, "https://face.getride.my/compare");
  assertEquals(r.method, "POST");
  assertEquals(r.headers["x-api-key"], SECRET);
  assertEquals(JSON.parse(r.body!), { image1: "AQID", image2: "BAU=" });
  assert(!r.url.includes(SECRET));
  const h = healthRequest(server);
  assertEquals([h.url, h.method, h.headers["x-api-key"]], ["https://face.getride.my/health", "GET", SECRET]);
});

Deno.test("the server's answers in face-compare's words", () => {
  assertEquals(readServerCompare(200, { similarity: 0.8234, model: "SFace" }), { state: "match", score: 82.34, failed: false });
  assertEquals(readServerCompare(200, { similarity: 0.31, model: "SFace" }), { state: "no_match", score: 31, failed: false });
  assertEquals(readServerCompare(200, { similarity: 0.9, verified: false }).state, "no_match", "the server's verdict wins");
  assertEquals(readServerCompare(422, { error: "no_face" }), { state: "no_face", score: null, failed: false });
  assertEquals(readServerCompare(401, { error: "bad_key" }), {
    state: "error",
    score: null,
    failed: true,
    detail: "Self-hosted server: key refused",
  });
  assertEquals(readServerCompare(502, null).failed, true);
  assertEquals(readServerCompare(200, { similarity: "high" }).failed, true);
  assertEquals(readServerCompare(200, { similarity: 7 }).failed, true);
});
