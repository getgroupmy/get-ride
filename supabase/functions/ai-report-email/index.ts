// ============================================================================
// ai-report-email — Supabase Edge Function
// ----------------------------------------------------------------------------
// Admin -> Reports -> a saved report's email schedule (migration 0280). The
// database decides what is due (ai_report_schedules_due every 5 minutes,
// "Send now" through ai_report_schedule_send_now) and posts the schedules'
// ids here; for each this runs the saved plan as the admin who made the
// schedule (ai_report_schedule_job), makes the files (CSV, Excel, PDF) and
// emails them, attached or as links that last 7 days (private bucket
// ai-reports). See _shared/ai_report_email.ts.
//
//   POST { ids, reason }  ->  { sent, skipped, failed }
//
// Callers: the database (x-push-secret, the push webhook's existing Vault
// secret, checked by push_webhook_secret_ok) or the service role.
//
// Email: Resend, with the key in Admin -> API Keys -> Email -> Resend (or the
// function secret RESEND_API_KEY) and the sender of Admin -> Reports.
//
// Deploy (the database carries no user JWT; every caller is checked here):
//   supabase functions deploy ai-report-email --no-verify-jwt
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import { handleReportEmail, LINK_DAYS, type ScheduleJob } from "../_shared/ai_report_email.ts";
import { emailProvider } from "../_shared/email.ts";
import { logoKind } from "../_shared/partner_statement.ts";
import { cleanLayout } from "../_shared/statement_layout.ts";

const url = Deno.env.get("SUPABASE_URL") ?? "";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? Deno.env.get("SERVICE_ROLE_KEY") ?? "";
const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

const BUCKET = "ai-reports";

Deno.serve(async (req) => {
  try {
    return await handleReportEmail(req, {
      serviceKeys: [serviceKey],
      async webhookSecretOk(secret) {
        const { data, error } = await db.rpc("push_webhook_secret_ok", { p_secret: secret });
        if (error) console.log("[ai-report-email] secret check:", error.message);
        return data === true;
      },
      async job(id) {
        const { data, error } = await db.rpc("ai_report_schedule_job", { p_id: id });
        if (error) return { ok: false, error: `The report couldn't be run: ${error.message}` };
        return data as ScheduleJob;
      },
      async provider() {
        const { data } = await db.from("app_settings").select("value").eq("key", "api_providers").maybeSingle();
        return emailProvider(data?.value ?? null, (n) => Deno.env.get(n));
      },
      async logo() {
        // The partner statements' logo (Admin -> Partner statements -> Layout).
        const { data } = await db.from("app_settings").select("value").eq("key", "partner_statement_layout").maybeSingle();
        const path = cleanLayout(data?.value).logo.path;
        if (!path) return null;
        const file = await db.storage.from("app-branding").download(path);
        if (file.error || !file.data) return null;
        return logoKind(new Uint8Array(await file.data.arrayBuffer()));
      },
      async keep(path, bytes, contentType) {
        const up = await db.storage.from(BUCKET).upload(path, bytes, { contentType, upsert: true });
        if (up.error) throw new Error(up.error.message);
        const signed = await db.storage.from(BUCKET).createSignedUrl(path, LINK_DAYS * 24 * 3600);
        if (signed.error || !signed.data?.signedUrl) throw new Error(signed.error?.message ?? "no link");
        return signed.data.signedUrl;
      },
      async log(e) {
        const { error } = await db.rpc("ai_report_send_log", {
          p_schedule: e.schedule,
          p_reason: e.reason,
          p_rows: e.rows,
          p_recipients: e.recipients,
          p_ok: e.ok,
          p_skipped: e.skipped,
          p_error: e.error,
        });
        if (error) console.log("[ai-report-email] log:", error.message);
      },
      now: () => new Date(),
    });
  } catch (e) {
    console.log("[ai-report-email] failed:", e instanceof Error ? e.message : "error");
    return new Response(JSON.stringify({ error: "unavailable" }), { status: 503, headers: { "Content-Type": "application/json" } });
  }
});
