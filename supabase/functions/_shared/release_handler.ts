/**
 * The half of a release function that talks to something. `release.ts`
 * holds the decisions and is unit tested; this does the requests.
 *
 * Why the token lives here and not in a console: a token that can dispatch
 * a workflow can start any workflow in the repository, and a browser is not
 * a place to keep one. Consoles call with the admin's own session; this
 * verifies the session, checks the admin's access to the App Release page
 * (`admin_can_edit` to release, `admin_can_read` to view runs, so a '*'
 * admin passes both), and only then uses the token.
 *
 * Function secrets:
 *
 *   GITHUB_RELEASE_TOKEN       fine-grained PAT, Actions: read and write on
 *                              the app repository and nothing else
 *   GITHUB_RELEASE_REPOSITORY  optional "owner/name"; default getgroupmy/get-ride
 *   GITHUB_RELEASE_REF         optional ref to build; unset, the repository's
 *                              own default branch (asked, not assumed)
 *
 * SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided
 * by the platform.
 */
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  choiceOf,
  DEFAULT_REPOSITORY,
  defaultBranchOf,
  dispatchBody,
  dispatchRefusal,
  noteOf,
  refToBuild,
  RELEASE_PAGE,
  type ReleasePlatform,
  runsFrom,
} from "./release.ts";

const GITHUB = "https://api.github.com";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function fail(error: string, status: number): Response {
  return json({ error }, status);
}

export async function handleRelease(
  req: Request,
  platform: ReleasePlatform,
): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return fail("Use POST", 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return fail("Missing Authorization header", 401);

  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

  const userClient = createClient(url, anon, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: user } = await userClient.auth.getUser();
  const uid = user?.user?.id;
  if (!uid) return fail("Not signed in", 401);

  const body = (await req.json().catch(() => ({}))) as Record<string, unknown>;
  const releasing = body.action === "release";

  // Checked with the service role against the caller's verified id, so a
  // forged body cannot name somebody else.
  const admin = createClient(url, service);
  const { data: allowed, error: accessError } = await admin.rpc(
    releasing ? "admin_can_edit" : "admin_can_read",
    { p_profile: uid, p_page: RELEASE_PAGE },
  );
  if (accessError) return fail("Could not check admin access", 500);
  if (allowed !== true) {
    return fail(
      releasing
        ? "You need edit access to App Release to start a store build."
        : "You need access to App Release to see store builds.",
      403,
    );
  }

  const token = Deno.env.get("GITHUB_RELEASE_TOKEN");
  const repo = Deno.env.get("GITHUB_RELEASE_REPOSITORY") || DEFAULT_REPOSITORY;
  if (!token) {
    // 503 and a sentence: not set up yet is different from broken.
    return fail(
      "Store releases are not set up yet. Add GITHUB_RELEASE_TOKEN to the " +
        "Supabase function secrets (see docs/store-release.md in get-ride).",
      503,
    );
  }

  const headers = {
    authorization: `Bearer ${token}`,
    accept: "application/vnd.github+json",
    "x-github-api-version": "2022-11-28",
    "user-agent": "get-ride-admin",
  };

  // Reading is the default; starting a build has to be asked for by name.
  if (!releasing) {
    const res = await fetch(
      `${GITHUB}/repos/${repo}/actions/workflows/${platform.workflow}/runs?per_page=5`,
      { headers },
    );
    if (!res.ok) {
      return fail(
        res.status === 401 || res.status === 403
          ? "GitHub refused the release token. It may have expired."
          : `GitHub answered ${res.status} for the run list.`,
        502,
      );
    }
    return json({ runs: runsFrom(await res.json()) });
  }

  const choice = choiceOf(platform, body[platform.input]);
  if (!choice) {
    return fail(`${platform.input} must be one of ${platform.choices.join(", ")}`, 400);
  }

  let defaultBranch: string | null = null;
  if (!Deno.env.get("GITHUB_RELEASE_REF")) {
    const repoRes = await fetch(`${GITHUB}/repos/${repo}`, { headers });
    if (repoRes.ok) defaultBranch = defaultBranchOf(await repoRes.json());
  }
  const ref = refToBuild(Deno.env.get("GITHUB_RELEASE_REF"), defaultBranch);
  if (!ref) {
    return fail(
      "Could not read the app repository's default branch from GitHub, so " +
        "there is no safe ref to build. Set GITHUB_RELEASE_REF to release anyway.",
      502,
    );
  }

  const res = await fetch(
    `${GITHUB}/repos/${repo}/actions/workflows/${platform.workflow}/dispatches`,
    {
      method: "POST",
      headers: { ...headers, "content-type": "application/json" },
      body: JSON.stringify(dispatchBody(platform, ref, choice, noteOf(body.notes))),
    },
  );
  // 204 and nothing else; GitHub does not return the run it created, so
  // consoles refresh the run list afterwards.
  if (res.status !== 204) {
    const said = await res.text().catch(() => "");
    return fail(dispatchRefusal(platform, res.status, said), 502);
  }

  console.log(`[${platform.fn}] ${uid} started ${choice} from ${repo}@${ref}`);
  return json({ started: true, [platform.input]: choice, ref });
}
