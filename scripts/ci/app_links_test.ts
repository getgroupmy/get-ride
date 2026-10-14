/**
 * What `app_links.ts` writes for qr.getride.my's /.well-known/.
 *
 *     deno test scripts/ci/app_links_test.ts
 *
 * The phone caches what these files say, so a file naming the wrong team
 * or key is worse than none. These pin the shape the platforms read and
 * the rule that a missing input skips a file rather than guessing.
 */
import { assert, assertEquals, assertStringIncludes, assertThrows } from "jsr:@std/assert@1.0.19";

import {
  apkKeyHashOrigin,
  APP_ID,
  appleAppSiteAssociation,
  assetLinks,
  dedupe,
  isTeamId,
  keytoolFingerprints,
  normalizeFingerprint,
  parseFingerprintList,
  plan,
  teamIdFromProfile,
} from "./app_links.ts";

const HEX = "ab".repeat(32);
const FP = Array(32).fill("AB").join(":");
const FP2 = Array(32).fill("01").join(":");

const PROFILE = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>AppIDName</key>
  <string>GET ride</string>
  <key>ApplicationIdentifierPrefix</key>
  <array>
    <string>ABCDE12345</string>
  </array>
  <key>Entitlements</key>
  <dict>
    <key>application-identifier</key>
    <string>ABCDE12345.com.taxxee.teksi</string>
  </dict>
  <key>TeamIdentifier</key>
  <array>
    <string>ABCDE12345</string>
  </array>
  <key>TeamName</key>
  <string>GET Group</string>
</dict>
</plist>`;

const KEYTOOL = `Alias name: upload
Creation date: Oct 1, 2026
Entry type: PrivateKeyEntry
Certificate fingerprints:
	 SHA1: 12:34:56:78:90:12:34:56:78:90:12:34:56:78:90:12:34:56:78:90
	 SHA256: ${FP.toLowerCase()}
Signature algorithm name: SHA256withRSA
`;

Deno.test("the team id comes out of a decoded profile", () => {
  assertEquals(teamIdFromProfile(PROFILE), "ABCDE12345");
  // Only the prefix, as older profiles have it.
  const prefixOnly = PROFILE.replace(/<key>TeamIdentifier<\/key>[\s\S]*?<\/array>/, "");
  assertEquals(teamIdFromProfile(prefixOnly), "ABCDE12345");
  assertEquals(teamIdFromProfile("<plist><dict></dict></plist>"), null);
  assertEquals(teamIdFromProfile(PROFILE.replaceAll("ABCDE12345", "not-a-team")), null);
});

Deno.test("team ids are ten capitals and digits", () => {
  assert(isTeamId("ABCDE12345"));
  assert(!isTeamId("abcde12345"));
  assert(!isTeamId("ABCDE1234"));
  assert(!isTeamId(undefined));
});

Deno.test("fingerprints come out upper case and colon separated", () => {
  assertEquals(normalizeFingerprint(HEX), FP);
  assertEquals(normalizeFingerprint(FP.toLowerCase()), FP);
  assertEquals(normalizeFingerprint(`SHA256: ${FP}`), FP);
  assertEquals(normalizeFingerprint(" sha-256 " + HEX + " "), FP);
  assertEquals(normalizeFingerprint("AB:CD"), null, "a SHA-1 or a fragment is not one");
  assertEquals(normalizeFingerprint("zz".repeat(32)), null);
});

Deno.test("keytool's SHA-256 lines, not its SHA-1", () => {
  assertEquals(keytoolFingerprints(KEYTOOL), [FP]);
  assertEquals(keytoolFingerprints(KEYTOOL + KEYTOOL.replace(FP.toLowerCase(), FP2)), [FP, FP2]);
  assertEquals(keytoolFingerprints("keytool error: java.io.IOException: keystore password was incorrect"), []);
});

Deno.test("the variable's list reports what it could not read", () => {
  const { fingerprints, rejected } = parseFingerprintList(` ${HEX} , ${FP2},, oops `);
  assertEquals(fingerprints, [FP, FP2]);
  assertEquals(rejected, ["oops"]);
  assertEquals(parseFingerprintList("").fingerprints, []);
});

Deno.test("dedupe keeps the first of each", () => {
  assertEquals(dedupe([FP, FP2], [FP]), [FP, FP2]);
});

Deno.test("apple-app-site-association claims the three code paths and passkeys for the app", () => {
  assertEquals(appleAppSiteAssociation("ABCDE12345"), {
    webcredentials: { apps: ["ABCDE12345.com.taxxee.teksi"] },
    applinks: {
      apps: [],
      details: [
        {
          appIDs: ["ABCDE12345.com.taxxee.teksi"],
          components: [{ "/": "/ref/*" }, { "/": "/me/*" }, { "/": "/now/*" }],
          paths: ["/ref/*", "/me/*", "/now/*"],
        },
      ],
    },
  });
  assertThrows(() => appleAppSiteAssociation("nope"));
});

Deno.test("assetlinks.json is the handle_all_urls statement for the app", () => {
  assertEquals(assetLinks([FP, FP2]), [
    {
      relation: ["delegate_permission/common.handle_all_urls", "delegate_permission/common.get_login_creds"],
      target: { namespace: "android_app", package_name: APP_ID, sha256_cert_fingerprints: [FP, FP2] },
    },
  ]);
  assertThrows(() => assetLinks([]));
});

Deno.test("everything there: both files, the passkey origins, and no notice about the Play key", () => {
  const p = plan({ profilePlist: PROFILE, keytoolOutput: KEYTOOL, sha256Var: `${FP2},${HEX}` });
  assertEquals(Object.keys(p.files).sort(), ["apple-app-site-association", "assetlinks.json"]);
  assertEquals(
    JSON.parse(p.files["assetlinks.json"])[0].target.sha256_cert_fingerprints,
    [FP, FP2],
    "upload key first, then the variable's, without the repeat",
  );
  assertEquals(p.notices.length, 1);
  assertStringIncludes(p.notices[0], `${apkKeyHashOrigin(FP)},${apkKeyHashOrigin(FP2)}`);
  assertEquals(p.warnings, []);
});

Deno.test("the profile wins over the variable; the variable stands in for it", () => {
  const fromProfile = plan({ profilePlist: PROFILE, teamIdVar: "ZZZZZ99999" });
  assertStringIncludes(fromProfile.files["apple-app-site-association"], "ABCDE12345.com.taxxee.teksi");
  const fromVar = plan({ teamIdVar: " ZZZZZ99999 " });
  assertStringIncludes(fromVar.files["apple-app-site-association"], "ZZZZZ99999.com.taxxee.teksi");
  const bad = plan({ teamIdVar: "zzz" });
  assert(!("apple-app-site-association" in bad.files));
  assertStringIncludes(bad.warnings.join(), "APPLE_TEAM_ID");
});

Deno.test("nothing to go on: no files, a notice for each", () => {
  const p = plan({});
  assertEquals(p.files, {});
  assertEquals(p.notices.length, 2);
  assertStringIncludes(p.notices[0], "apple-app-site-association not written");
  assertStringIncludes(p.notices[1], "assetlinks.json not written");
});

Deno.test("the upload key alone reminds about the Play App Signing key", () => {
  const p = plan({ keytoolOutput: KEYTOOL });
  assert("assetlinks.json" in p.files);
  assertStringIncludes(p.notices.join(" "), "ANDROID_APP_LINK_SHA256");
});

Deno.test("a passkey origin is the certificate's SHA-256, base64url, unpadded", () => {
  const origin = apkKeyHashOrigin(FP);
  assert(origin.startsWith("android:apk-key-hash:"));
  const b64 = origin.slice("android:apk-key-hash:".length);
  assertEquals(b64.length, 43);
  assert(!/[+/=]/.test(b64));
  const back = atob(b64.replace(/-/g, "+").replace(/_/g, "/") + "=");
  const hex = [...back].map((c) => c.charCodeAt(0).toString(16).padStart(2, "0").toUpperCase()).join(":");
  assertEquals(hex, FP);
});

Deno.test("the Play key alone is enough", () => {
  const p = plan({ sha256Var: HEX });
  assertEquals(JSON.parse(p.files["assetlinks.json"])[0].target.sha256_cert_fingerprints, [FP]);
  assert(!p.notices.join(" ").includes("upload key only"));
});
