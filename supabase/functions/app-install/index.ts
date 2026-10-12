// ============================================================================
// app-install — Supabase Edge Function
// ----------------------------------------------------------------------------
// The latest build of the app, for downloading and installing directly
// (Admin → App Release, and the public getride.my/install/<platform> page).
//
// Request:  GET ?platform=ios|android                  -> AppBuild (JSON)
//           GET ?platform=ios&format=manifest          -> itms-services manifest
//
// Reads the rolling GitHub release `ios-latest` / `android-latest` that the
// release workflows publish (scripts/ci/publish_build.sh). Those builds are
// public release assets of a public repository already, so this answers
// anybody: it adds nothing that isn't on GitHub, only the manifest an
// iPhone needs, which GitHub can't serve. An Ad Hoc IPA installs only on
// the iPhones registered in its profile.
//
// Optional secrets: GITHUB_RELEASE_TOKEN (higher GitHub rate limit; the same
// one ios-release uses), GITHUB_BUILDS_REPOSITORY (default getgroupmy/get-ride).
//
// Deploy:
//   supabase functions deploy app-install --no-verify-jwt
// ============================================================================
import {
  appBuildFrom,
  BUILD_ASSETS,
  DEFAULT_BUILDS_REPOSITORY,
  manifestPlist,
  platformOf,
  releaseApiUrl,
} from "../_shared/app_install.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "public, max-age=60" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "GET") return json({ error: "Use GET" }, 405);
  try {
    const params = new URL(req.url).searchParams;
    const platform = platformOf(params.get("platform"));
    if (!platform) return json({ error: "platform must be ios or android" }, 400);

    const repo = Deno.env.get("GITHUB_BUILDS_REPOSITORY") || DEFAULT_BUILDS_REPOSITORY;
    const token = Deno.env.get("GITHUB_RELEASE_TOKEN");
    const headers: Record<string, string> = {
      accept: "application/vnd.github+json",
      "x-github-api-version": "2022-11-28",
      "user-agent": "get-ride-app-install",
    };
    if (token) headers.authorization = `Bearer ${token}`;

    const res = await fetch(releaseApiUrl(repo, platform), { headers });
    if (res.status === 404) return json({ available: false, platform });
    if (!res.ok) return json({ error: `GitHub answered ${res.status}` }, 502);
    const release = await res.json();

    // build.json says what the build is; without it the file is still offered.
    let info: unknown = null;
    const infoAsset = (release?.assets ?? []).find((a: { name?: string }) => a?.name === "build.json");
    if (infoAsset?.browser_download_url) {
      const r = await fetch(infoAsset.browser_download_url, { headers: { "user-agent": headers["user-agent"] } });
      if (r.ok) info = await r.json().catch(() => null);
    }

    const self = `${Deno.env.get("SUPABASE_URL") ?? ""}/functions/v1/app-install`;
    const build = appBuildFrom(platform, release, info, `${self}?platform=ios&format=manifest`);

    if (params.get("format") === "manifest") {
      const plist = manifestPlist(build);
      if (!plist) {
        return json({ error: `No installable ${BUILD_ASSETS[platform].asset} is published.` }, 404);
      }
      return new Response(plist, {
        headers: { ...corsHeaders, "Content-Type": "application/xml", "Cache-Control": "public, max-age=60" },
      });
    }
    return json(build);
  } catch (error) {
    console.error("[app-install] failed", error);
    return json({ error: "Unexpected error" }, 500);
  }
});
