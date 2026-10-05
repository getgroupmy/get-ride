// ============================================================================
// ios-release — Supabase Edge Function
// ----------------------------------------------------------------------------
// Lists recent iOS store builds, and (action: "release") starts one by
// dispatching ios-release.yml in the Flutter app repository (getgroupmy/
// get-ride), which archives on a macOS runner and uploads to App Store
// Connect as com.taxxee.teksi.
//
// Request:  POST {}                                   -> { runs: [...] }
//           POST { action: "release", lane, notes? }  -> { started, lane, ref }
//           lane: "testflight" | "appstore"
//
// Everything is in _shared/release_handler.ts (shared with android-release);
// see it for the admin check and the secrets.
//
// Deploy:
//   supabase functions deploy ios-release --no-verify-jwt
// ============================================================================
import { IOS } from "../_shared/release.ts";
import { corsHeaders, handleRelease } from "../_shared/release_handler.ts";

Deno.serve(async (req) => {
  try {
    return await handleRelease(req, IOS);
  } catch (error) {
    console.error("[ios-release] failed", error);
    return new Response(JSON.stringify({ error: "Unexpected error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
