/**
 * Store releases: what an admin console may ask for, and what GitHub is told.
 *
 * Shared by `ios-release` and `android-release`. They differ only in which
 * workflow they dispatch, what that workflow's destination input is called,
 * and which destinations it accepts. The builds themselves run in the
 * Flutter app's repository (getgroupmy/get-ride), on GitHub Actions:
 *
 *   admin console (Expo or Flutter)
 *     -> supabase/functions/{ios,android}-release   (holds the GitHub token)
 *     -> get-ride/.github/workflows/{ios,android}-release.yml
 *     -> App Store Connect / Google Play
 *
 * This module holds the decisions and imports nothing, so it can be tested
 * without a server or supabase-js (`release_test.ts`). `release_handler.ts`
 * does the requests.
 *
 * Everything accepted from a browser is checked against a list written
 * here rather than passed through: these functions hold a token that can
 * start a workflow which signs a build and hands it to Apple or Google.
 */

/** The admin page whose edit access allows releasing (and read access, viewing). */
export const RELEASE_PAGE = "admin-settings-app-release";

/** The repository whose workflows build the store app. */
export const DEFAULT_REPOSITORY = "getgroupmy/get-ride";

/** Which workflow, and where a build may be sent. */
export interface ReleasePlatform {
  /** The edge function's name. */
  readonly fn: string;
  /** The workflow file in the app repository. */
  readonly workflow: string;
  /** What the destination input is called in that workflow. */
  readonly input: string;
  /** Every value that input accepts, in the workflow's order. */
  readonly choices: readonly string[];
}

export const IOS: ReleasePlatform = {
  fn: "ios-release",
  workflow: "ios-release.yml",
  input: "lane",
  choices: ["testflight", "appstore"],
};

export const ANDROID: ReleasePlatform = {
  fn: "android-release",
  workflow: "android-release.yml",
  input: "track",
  choices: ["internal", "alpha", "beta", "production"],
};

/** The destination, or null if it is not one this platform offers. */
export function choiceOf(
  platform: ReleasePlatform,
  raw: unknown,
): string | null {
  return typeof raw === "string" && platform.choices.includes(raw)
    ? raw
    : null;
}

/**
 * The note, trimmed and bounded. It ends up in a workflow input and a step
 * summary, so newlines are flattened and it is capped at a line's length.
 */
export function noteOf(raw: unknown): string {
  if (typeof raw !== "string") return "";
  return raw.replace(/[\r\n]+/g, " ").trim().slice(0, 200);
}

/** The body GitHub's workflow dispatch endpoint takes. */
export function dispatchBody(
  platform: ReleasePlatform,
  ref: string,
  choice: string,
  notes: string,
): Record<string, unknown> {
  return {
    ref,
    inputs: { [platform.input]: choice, ...(notes ? { notes } : {}) },
  };
}

/** The repository's own default branch out of `GET /repos/{repo}`, or null. */
export function defaultBranchOf(payload: unknown): string | null {
  const branch = (payload as { default_branch?: unknown })?.default_branch;
  return typeof branch === "string" && branch.trim() ? branch.trim() : null;
}

/**
 * Which ref to build: `GITHUB_RELEASE_REF` when set, otherwise the
 * repository's actual default branch, read from the API rather than
 * assumed. Null when neither is known, so the caller refuses rather than
 * dispatching a guess.
 */
export function refToBuild(
  configured: string | undefined | null,
  defaultBranch: string | null,
): string | null {
  const explicit = (configured ?? "").trim();
  if (explicit) return explicit;
  return defaultBranch;
}

export interface RunSummary {
  id: number;
  number: number;
  /** `queued`, `in_progress` or `completed`. */
  status: string;
  /** `success`, `failure`, `cancelled` ... or null while it runs. */
  conclusion: string | null;
  startedAt: string | null;
  url: string;
}

/**
 * The runs, trimmed to what a console needs. GitHub's run object carries
 * the head commit, the actor and a dozen URLs; none of it belongs on a
 * screen asking "did the release work".
 */
export function runsFrom(payload: unknown): RunSummary[] {
  const runs = (payload as { workflow_runs?: unknown })?.workflow_runs;
  if (!Array.isArray(runs)) return [];
  return runs.map((raw) => {
    const r = raw as Record<string, unknown>;
    return {
      id: Number(r.id ?? 0),
      number: Number(r.run_number ?? 0),
      status: typeof r.status === "string" ? r.status : "unknown",
      conclusion: typeof r.conclusion === "string" ? r.conclusion : null,
      startedAt: typeof r.run_started_at === "string" ? r.run_started_at : null,
      url: typeof r.html_url === "string" ? r.html_url : "",
    };
  });
}

/**
 * What to say when GitHub refuses to start the build.
 *
 * A 422 about `workflow_dispatch` does not mean the trigger is missing: it
 * means the workflow file is not on the REF being dispatched. That one gets
 * its own sentence because the raw message sends people to the wrong place.
 */
export function dispatchRefusal(
  platform: ReleasePlatform,
  status: number,
  said: string,
): string {
  if (status === 422 && said.includes("workflow_dispatch")) {
    return "GitHub will not start this build because " +
      `${platform.workflow} is not on the branch it was asked to build ` +
      "(the app repository's default branch, or GITHUB_RELEASE_REF when " +
      "set). Merge the workflow there, or point GITHUB_RELEASE_REF at a " +
      "branch that has it.";
  }
  if (status === 404) {
    return `GitHub cannot find ${platform.workflow}. Check ` +
      "GITHUB_RELEASE_REPOSITORY, and that the token can see that repository.";
  }
  if (status === 401 || status === 403) {
    return "GitHub refused the release token. It may have expired, or it " +
      "lacks Actions: read and write on the app repository.";
  }
  const tail = said.trim().slice(0, 300);
  return `GitHub refused to start the build (${status}).${tail ? ` ${tail}` : ""}`;
}
