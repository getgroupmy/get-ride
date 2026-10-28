// web/stats.js (visitor stats, deploy/nas-stats): which pages are counted and
// how, and the build-time switch it reads.
//
//     deno test --allow-read=web scripts/ci/web_stats_test.ts
import { assert, assertEquals } from "jsr:@std/assert@1.0.19";

import "../../web/stats.js";

type Stats = {
  page(host: string, path: string): string | null;
  config(content: string | null): { src: string; id: string } | null;
  site(referrer: string): string;
};
const stats = (globalThis as unknown as { getrideStats: Stats }).getrideStats;

Deno.test("only the public pages are counted, without tokens", () => {
  assertEquals(stats.page("getride.my", "/"), "/");
  assertEquals(stats.page("getride.my", ""), "/");
  assertEquals(stats.page("www.getride.my", "/install/Android/"), "/install/android");
  assertEquals(stats.page("qr.getride.my", "/ref/abc123XYZ"), "/ref/:token");
  assertEquals(stats.page("qr.getride.my", "/me/t0k3n"), "/me/:token");
  assertEquals(stats.page("qr.getride.my", "/now/t0k3n"), "/now/:token");
  assertEquals(stats.page("getride.my", "/q/ref/t0k3n"), "/q/ref/:token");
  for (const p of ["/admin", "/admin/m/office-nas", "/rides", "/share/abc", "/verify/x", "/ref/a/b", "/meter"]) {
    assertEquals(stats.page("getride.my", p), null, p);
  }
});

Deno.test("the build switch: an https script and a website ID, else off", () => {
  assertEquals(stats.config("https://stats.getride.my/s.js 3F2504E0-4F89-11D3-9A0C-0305E82C3301"), {
    src: "https://stats.getride.my/s.js",
    id: "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
  });
  assertEquals(stats.config(""), null, "empty: off");
  assertEquals(stats.config(null), null);
  assertEquals(stats.config("http://stats.getride.my/s.js 3f2504e0-4f89-11d3-9a0c-0305e82c3301"), null);
  assertEquals(stats.config("https://stats.getride.my/s.js nope"), null);
  assertEquals(stats.config("javascript:alert(1).js 3f2504e0-4f89-11d3-9a0c-0305e82c3301"), null);
});

Deno.test("the referrer is cut to its site", () => {
  assertEquals(stats.site("https://wa.me/60123456789?text=hi"), "https://wa.me");
  assertEquals(stats.site(""), "");
  assertEquals(stats.site("android-app://x"), "");
});

Deno.test("index.html: off by default, loads the script async", async () => {
  const html = await Deno.readTextFile(new URL("../../web/index.html", import.meta.url));
  assert(html.includes('<meta name="getride-stats" content="">'), "empty: the stats are off until the build fills it");
  assert(/<script src="stats\.js" async><\/script>/.test(html));
});
