// ============================================================================
// android-release — Supabase Edge Function
// ----------------------------------------------------------------------------
// Lists recent Android store builds, and (action: "release") starts one by
// dispatching android-release.yml in the Flutter app repository (getgroupmy/
// get-ride), which builds an app bundle on Ubuntu and uploads to Google
// Play as com.taxxee.teksi.
//
// Request:  POST {}                                   -> { runs: [...] }
//           POST { action: "release", track, notes? } -> { started, track, ref }
//           track: "internal" | "alpha" | "beta" | "production"
//
// Everything is in _shared/release_handler.ts (shared with ios-release);
// see it for the admin check and the secrets.
//
// Deploy:
//   supabase functions deploy android-release --no-verify-jwt
// ============================================================================
import { ANDROID } from "../_shared/release.ts";
import { corsHeaders, handleRelease } from "../_shared/release_handler.ts";

Deno.serve(async (req) => {
  try {
    return await handleRelease(req, ANDROID);
  } catch (error) {
    console.error("[android-release] failed", error);
    return new Response(JSON.stringify({ error: "Unexpected error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
