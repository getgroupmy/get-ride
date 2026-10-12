/**
 * What app-install decides about the latest published build.
 *
 *     deno test supabase/functions/_shared/app_install_test.ts
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import { appBuildFrom, itmsServicesUrl, manifestPlist, platformOf, releaseApiUrl } from "./app_install.ts";

const MANIFEST = "https://x.supabase.co/functions/v1/app-install?platform=ios&format=manifest";

const release = (asset: string, size = 52_000_000) => ({
  assets: [
    {
      name: asset,
      size,
      browser_download_url: `https://github.com/getgroupmy/get-ride/releases/download/x/${asset}`,
      updated_at: "2026-10-12T06:00:00Z",
    },
    { name: "build.json", size: 300, browser_download_url: "https://github.com/x/build.json" },
  ],
});

Deno.test("only ios and android are platforms", () => {
  assertEquals(platformOf("ios"), "ios");
  assertEquals(platformOf("android"), "android");
  assertEquals(platformOf("windows"), null);
  assertEquals(platformOf(undefined), null);
  assertEquals(
    releaseApiUrl("getgroupmy/get-ride", "ios"),
    "https://api.github.com/repos/getgroupmy/get-ride/releases/tags/ios-latest",
  );
});

Deno.test("an Ad Hoc iPhone build installs over the air through the manifest", () => {
  const b = appBuildFrom("ios", release("getride.ipa"), { version: "1.4.3", build: "107", installable: true }, MANIFEST);
  assert(b.available);
  assertEquals(b.version, "1.4.3");
  assertEquals(b.build, "107");
  assertEquals(b.size, 52_000_000);
  assertEquals(b.install_url, itmsServicesUrl(MANIFEST));
  assertStringIncludes(b.install_url!, "itms-services://?action=download-manifest&url=https%3A%2F%2F");
  const plist = manifestPlist(b)!;
  assertStringIncludes(plist, "<string>https://github.com/getgroupmy/get-ride/releases/download/x/getride.ipa</string>");
  assertStringIncludes(plist, "<key>bundle-identifier</key><string>com.taxxee.teksi</string>");
  assertStringIncludes(plist, "<key>bundle-version</key><string>1.4.3</string>");
});

Deno.test("an App Store IPA downloads but never claims to install", () => {
  const b = appBuildFrom("ios", release("getride.ipa"), { installable: false }, MANIFEST);
  assert(b.available);
  assertEquals(b.installable, false);
  assertEquals(b.install_url, undefined);
  assertEquals(manifestPlist(b), null);
  const noInfo = appBuildFrom("ios", release("getride.ipa"), null, MANIFEST);
  assertEquals(noInfo.installable, false, "without build.json an IPA isn't assumed installable");
});

Deno.test("an APK installs from its own address", () => {
  const b = appBuildFrom("android", release("getride.apk"), { version: "1.4.3", build: "88" }, MANIFEST);
  assert(b.installable);
  assertEquals(b.install_url, b.download_url);
  assertEquals(manifestPlist(b), null, "no manifest for Android");
});

Deno.test("the Android bundle is offered for download beside the APK, never to install", () => {
  const withAab = {
    assets: [
      ...release("getride.apk").assets,
      {
        name: "getride.aab",
        size: 40_000_000,
        browser_download_url: "https://github.com/getgroupmy/get-ride/releases/download/x/getride.aab",
      },
    ],
  };
  const b = appBuildFrom("android", withAab, {}, MANIFEST);
  assertEquals(b.bundle_url, "https://github.com/getgroupmy/get-ride/releases/download/x/getride.aab");
  assertEquals(b.bundle_size, 40_000_000);
  assertEquals(b.install_url, b.download_url, "the APK still installs, not the bundle");
  assertEquals(appBuildFrom("android", release("getride.apk"), {}, MANIFEST).bundle_url, undefined, "older releases");
  const iosWithAab = { assets: [...release("getride.ipa").assets, withAab.assets[2]] };
  assertEquals(appBuildFrom("ios", iosWithAab, {}, MANIFEST).bundle_url, undefined, "iOS has no bundle");
});

Deno.test("no asset, nothing on offer; odd input never breaks", () => {
  assertEquals(appBuildFrom("android", release("getride.ipa"), {}, MANIFEST), { available: false, platform: "android" });
  assertEquals(appBuildFrom("ios", { assets: "nope" }, {}, MANIFEST).available, false);
  assertEquals(appBuildFrom("ios", null, null, MANIFEST).available, false);
  const insecure = {
    assets: [{ name: "getride.apk", size: 1, browser_download_url: "http://example.com/getride.apk" }],
  };
  assertEquals(appBuildFrom("android", insecure, {}, MANIFEST).available, false, "https only");
});

Deno.test("the manifest escapes what it is given", () => {
  const b = appBuildFrom(
    "ios",
    release("getride.ipa"),
    { version: '1.0 <"&">', installable: true, bundle_id: "com.taxxee.teksi" },
    MANIFEST,
  );
  assertStringIncludes(manifestPlist(b)!, "1.0 &lt;&quot;&amp;&quot;&gt;");
});
