/**
 * What app-install decides about the latest published build.
 *
 *     deno test supabase/functions/_shared/app_install_test.ts
 */
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1.0.19";

import {
  abiOf,
  appBuildFrom,
  itmsServicesUrl,
  manifestPlist,
  pickApk,
  platformOf,
  releaseApiUrl,
} from "./app_install.ts";

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

const asset = (name: string, size: number) => ({
  name,
  size,
  browser_download_url: `https://github.com/getgroupmy/get-ride/releases/download/android-latest/${name}`,
  updated_at: "2026-10-18T06:00:00Z",
});
const dl = (name: string) => `https://github.com/getgroupmy/get-ride/releases/download/android-latest/${name}`;
const split = {
  assets: [
    asset("getride.apk", 154_000_000),
    asset("getride-arm64-v8a.apk", 57_000_000),
    asset("getride-armeabi-v7a.apk", 52_000_000),
    asset("build.json", 300),
  ],
};

Deno.test("an old client (no ?abi=) gets the universal APK exactly as before the split", () => {
  const b = appBuildFrom("android", split, { version: "1.5.0", build: "120", size: 154_000_000 }, MANIFEST);
  assertEquals(b.abi, "universal");
  assertEquals(b.download_url, dl("getride.apk"));
  assertEquals(b.install_url, dl("getride.apk"));
  assertEquals(b.size, 154_000_000);
  assertEquals(b.apks?.map((a) => a.abi), ["arm64-v8a", "armeabi-v7a", "universal"], "listed for new clients");
  assertEquals(b.apks?.[2], { abi: "universal", url: dl("getride.apk"), size: 154_000_000 });
  assertEquals(appBuildFrom("android", split, {}, MANIFEST, abiOf(null)).install_url, dl("getride.apk"));
  assertEquals(appBuildFrom("android", split, {}, MANIFEST, abiOf("x86")).install_url, dl("getride.apk"));
});

Deno.test("a new client gets the processor it names", () => {
  const b = appBuildFrom("android", split, { size: 154_000_000 }, MANIFEST, abiOf("arm64-v8a"));
  assertEquals(b.abi, "arm64-v8a");
  assertEquals(b.download_url, dl("getride-arm64-v8a.apk"));
  assertEquals(b.install_url, b.download_url);
  assertEquals(b.size, 57_000_000, "the split's own size, not build.json's universal one");

  const old = appBuildFrom("android", split, {}, MANIFEST, abiOf("armeabi-v7a"));
  assertEquals(old.abi, "armeabi-v7a");
  assertEquals(old.install_url, dl("getride-armeabi-v7a.apk"));
  assertEquals(old.size, 52_000_000);

  assertEquals(appBuildFrom("android", split, {}, MANIFEST, abiOf("universal")).install_url, dl("getride.apk"));
});

Deno.test("a missing split falls back to the universal APK", () => {
  const no32 = { assets: split.assets.filter((a) => a.name !== "getride-armeabi-v7a.apk") };
  const b = appBuildFrom("android", no32, { size: 154_000_000 }, MANIFEST, "armeabi-v7a");
  assertEquals(b.abi, "universal");
  assertEquals(b.install_url, dl("getride.apk"));
  assertEquals(b.size, 154_000_000);
  // A release from before the split: the universal APK, as always.
  assertEquals(appBuildFrom("android", release("getride.apk"), {}, MANIFEST, "arm64-v8a").abi, "universal");
});

Deno.test("no universal APK: the named split only; a request naming none gets what there is", () => {
  const only32 = { assets: [asset("getride-armeabi-v7a.apk", 52_000_000)] };
  assertEquals(appBuildFrom("android", only32, {}, MANIFEST).install_url, dl("getride-armeabi-v7a.apk"));
  assertEquals(appBuildFrom("android", only32, {}, MANIFEST, "armeabi-v7a").abi, "armeabi-v7a");
  assertEquals(
    appBuildFrom("android", only32, {}, MANIFEST, "arm64-v8a"),
    { available: false, platform: "android" },
    "a split is only handed to the processor that asked for it",
  );
  const only64 = { assets: [asset("getride-arm64-v8a.apk", 57_000_000)] };
  assertEquals(
    appBuildFrom("android", only64, {}, MANIFEST, "armeabi-v7a"),
    { available: false, platform: "android" },
    "a 32-bit phone is never handed a 64-bit-only APK",
  );
});

Deno.test("the abi a request names", () => {
  assertEquals(abiOf("arm64-v8a"), "arm64-v8a");
  assertEquals(abiOf("ARM64"), "arm64-v8a");
  assertEquals(abiOf("armeabi-v7a"), "armeabi-v7a");
  assertEquals(abiOf("universal"), "universal");
  assertEquals(abiOf("x86"), null);
  assertEquals(abiOf(null), null);
  assertEquals(pickApk([], null), null);
});

Deno.test("an iPhone build has no APKs", () => {
  const b = appBuildFrom("ios", { assets: [...release("getride.ipa").assets, ...split.assets] }, {}, MANIFEST, "arm64-v8a");
  assertEquals(b.apks, undefined);
  assertEquals(b.abi, undefined);
  assertStringIncludes(b.download_url!, "getride.ipa");
});
