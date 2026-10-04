/**
 * What `play_upload.ts` decides before it touches the network.
 *
 *     deno test scripts/play_upload_test.ts
 *
 * The upload itself cannot be asserted here -- it needs a real Play
 * account and a real bundle, and the first time it runs will be in
 * anger. What CAN be asserted is everything that decides what gets sent
 * and what a refusal means.
 */
import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "jsr:@std/assert@1.0.19";

import {
  isPermanent,
  LANGUAGE,
  messageOf,
  PERMANENT_EXIT,
  SCOPE,
  trackBody,
  trackOf,
  uploadRefusal,
} from "./play_upload.ts";

Deno.test("a disabled API names the switch, not the workflow", () => {
  // The first real upload. The Cloud project had the service account
  // and not the API, which are separate switches in separate parts of
  // the console, and creating one does not turn on the other.
  const said = uploadRefusal(
    403,
    "Google Play Android Developer API has not been used in project " +
      "1234567890 before or it is disabled.",
  );
  assertStringIncludes(said, "separate switch");
  assertStringIncludes(said, "Enable");
});

Deno.test("4xx is permanent and 5xx is not", () => {
  // What decides whether retry.sh tries again. The first real upload
  // spent seventy seconds and four identical stack traces on a
  // disabled API, which no amount of backoff could have fixed.
  assert(isPermanent(400), "a bad request will be bad next time too");
  assert(isPermanent(403), "a missing permission does not heal");
  assert(isPermanent(404));

  assert(!isPermanent(500), "Google having a bad moment is worth a retry");
  assert(!isPermanent(503));
  // 429 is the one 4xx that means "try again", which is the whole
  // reason this is not just `status < 500`.
  assert(!isPermanent(429), "being asked to slow down is a reason to wait");
  assert(!isPermanent(200));
});

Deno.test("the permanent exit code is the one the workflow passes", () => {
  // `RETRY_NEVER_ON=3` in android-release.yml. If this number moves
  // and that does not, every permanent refusal is retried four times
  // again, silently.
  assertEquals(PERMANENT_EXIT, 3);
});

Deno.test("the track is an allow-list, not a cast", () => {
  assertEquals(trackOf("internal"), "internal");
  assertEquals(trackOf("production"), "production");

  // It is interpolated into a URL path. A value nobody checked would
  // be a request to whatever it spelled -- including one that climbed
  // out of the edit with `../`.
  assertEquals(trackOf("../../apps"), null);
  assertEquals(trackOf("Internal"), null);
  assertEquals(trackOf(""), null);
  assertEquals(trackOf(null), null);
  assertEquals(trackOf(42), null);
});

Deno.test("the scope is what makes the token a Play token", () => {
  // googleAccessToken is shared with Document AI and FCM and is
  // scope-driven; the wrong constant here is a 403 that reads like a
  // permissions problem in the Play Console.
  assertEquals(SCOPE, "https://www.googleapis.com/auth/androidpublisher");
});

Deno.test("a release goes out completed, not draft", () => {
  const body = trackBody(7, "") as {
    releases: { status: string; versionCodes: string[] }[];
  };
  // A draft sits in the console waiting for somebody to press a
  // button. On an automated release that is an upload that succeeded
  // and reached nobody, which is the failure mode worth guarding.
  assertEquals(body.releases[0].status, "completed");
  // Strings, not numbers: Play's int64s are JSON strings, and a number
  // here is accepted for small values and silently wrong for large.
  assertEquals(body.releases[0].versionCodes, ["7"]);
});

Deno.test("release notes are sent only when there are some", () => {
  const without = trackBody(7, "   ") as {
    releases: Record<string, unknown>[];
  };
  // An empty releaseNotes array is not the same as no key: it shows
  // testers a blank change list rather than the previous one.
  assert(!("releaseNotes" in without.releases[0]));

  const with_ = trackBody(7, "  pods signing fix  ") as {
    releases: { releaseNotes: { language: string; text: string }[] }[];
  };
  assertEquals(with_.releases[0].releaseNotes, [
    { language: LANGUAGE, text: "pods signing fix" },
  ]);
});

Deno.test("the first-upload refusal names the console, not the workflow", () => {
  // The one that will happen to whoever sets this up, and the one
  // where the raw message is least helpful.
  const said = uploadRefusal(
    403,
    "Only releases with status draft may be created on draft app.",
  );
  assertStringIncludes(said, "by hand");
  assertStringIncludes(said, "Play Console");
  // It must not read as a bug in the workflow, because it is not one
  // and the next step is in a browser.
  assert(!said.includes("retry"));
});

Deno.test("a 403 about permission names the invitation, not the IAM role", () => {
  const said = uploadRefusal(403, "The caller does not have permission");
  // Granting the service account in Google Cloud is the obvious half
  // and the insufficient one; the Play Console invitation is a
  // different screen and is what is actually missing.
  assertStringIncludes(said, "Play Console");
  assertStringIncludes(said, "Users and permissions");
});

Deno.test("a duplicate version code points away from the workflow", () => {
  const said = uploadRefusal(
    400,
    "APK specifies a version code that has already been used.",
  );
  assertStringIncludes(said, "run number");
  // The run number never repeats, so the cause is a build uploaded some
  // other way (the Expo app's EAS builds), and the fix is the offset.
  assertStringIncludes(said, "ANDROID_VERSION_CODE_OFFSET");
});

Deno.test("a signature refusal names the debug key", () => {
  const said = uploadRefusal(403, "Package not signed by expected certificate");
  // The build falls back to the debug key when key.properties is
  // missing, and that is overwhelmingly the cause.
  assertStringIncludes(said, "debug key");
});

Deno.test("anything else is passed through, within reason", () => {
  assertEquals(uploadRefusal(400, "Something specific went wrong"),
    "Something specific went wrong");

  // A page of HTML from a proxy is not a sentence anybody wants in a
  // job summary -- the same guard `releaseRefusalLine` has on the
  // Dart side.
  const huge = "x".repeat(500);
  assertEquals(uploadRefusal(500, huge), "Play answered 500");
});

Deno.test("the message is dug out of Google's error envelope", () => {
  assertEquals(
    messageOf(JSON.stringify({ error: { code: 403, message: "nope" } })),
    "nope",
  );
  // Google serves plenty of non-JSON 4xx pages, and losing the body
  // entirely would leave a refusal with nothing in it.
  assertEquals(messageOf("<html>no</html>"), "<html>no</html>");
  assertEquals(messageOf(""), "");
});
