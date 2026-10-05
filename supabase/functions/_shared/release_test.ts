/**
 * What the release functions decide before touching the network.
 *
 *     deno test supabase/functions/_shared/release_test.ts
 */
import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "jsr:@std/assert@1.0.19";

import {
  ANDROID,
  choiceOf,
  defaultBranchOf,
  dispatchBody,
  dispatchRefusal,
  IOS,
  noteOf,
  refToBuild,
  RELEASE_PAGE,
  runsFrom,
} from "./release.ts";

Deno.test("destinations are an allow-list per platform", () => {
  assertEquals(choiceOf(IOS, "testflight"), "testflight");
  assertEquals(choiceOf(IOS, "appstore"), "appstore");
  assertEquals(choiceOf(IOS, "production"), null);
  assertEquals(choiceOf(ANDROID, "production"), "production");
  assertEquals(choiceOf(ANDROID, "testflight"), null);
  assertEquals(choiceOf(ANDROID, ["internal"]), null);
  assertEquals(choiceOf(ANDROID, undefined), null);
});

Deno.test("the choices match the workflows in get-ride", () => {
  // .github/workflows/{ios,android}-release.yml in getgroupmy/get-ride.
  assertEquals([...IOS.choices], ["testflight", "appstore"]);
  assertEquals([...ANDROID.choices], ["internal", "alpha", "beta", "production"]);
  assertEquals(IOS.input, "lane");
  assertEquals(ANDROID.input, "track");
});

Deno.test("notes are one bounded line", () => {
  assertEquals(noteOf("  fix\r\nmeter  "), "fix meter");
  assertEquals(noteOf(42), "");
  assertEquals(noteOf("x".repeat(500)).length, 200);
});

Deno.test("the dispatch body carries the input and only a real note", () => {
  assertEquals(dispatchBody(IOS, "main", "testflight", ""), {
    ref: "main",
    inputs: { lane: "testflight" },
  });
  assertEquals(dispatchBody(ANDROID, "main", "internal", "hi"), {
    ref: "main",
    inputs: { track: "internal", notes: "hi" },
  });
});

Deno.test("the ref is the override, else the default branch, else nothing", () => {
  assertEquals(refToBuild("release", "main"), "release");
  assertEquals(refToBuild("  ", "main"), "main");
  assertEquals(refToBuild(undefined, null), null);
  assertEquals(defaultBranchOf({ default_branch: "main" }), "main");
  assertEquals(defaultBranchOf({}), null);
});

Deno.test("runs are trimmed to what a console shows", () => {
  const [run] = runsFrom({
    workflow_runs: [{
      id: 7,
      run_number: 3,
      status: "completed",
      conclusion: "success",
      run_started_at: "2026-10-04T10:00:00Z",
      html_url: "https://github.com/x",
      head_commit: { message: "secret-ish" },
    }],
  });
  assertEquals(run, {
    id: 7,
    number: 3,
    status: "completed",
    conclusion: "success",
    startedAt: "2026-10-04T10:00:00Z",
    url: "https://github.com/x",
  });
  assertEquals(runsFrom({}), []);
});

Deno.test("a 422 about workflow_dispatch points at the ref, not the trigger", () => {
  const said = dispatchRefusal(
    IOS,
    422,
    `{"message":"Workflow does not have 'workflow_dispatch' trigger"}`,
  );
  assertStringIncludes(said, "not on the branch");
  assertStringIncludes(said, "GITHUB_RELEASE_REF");
});

Deno.test("a refused token says so", () => {
  assertStringIncludes(dispatchRefusal(ANDROID, 401, ""), "token");
  assert(dispatchRefusal(ANDROID, 500, "boom").includes("(500)"));
});

Deno.test("release access is checked against the App Release page", () => {
  assertEquals(RELEASE_PAGE, "admin-settings-app-release");
});
