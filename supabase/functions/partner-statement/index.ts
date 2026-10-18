// ============================================================================
// partner-statement — Supabase Edge Function
// ----------------------------------------------------------------------------
// A driver's weekly, monthly or annual earnings statement as a PDF, in
// English or Bahasa Melayu (migration 0201). The numbers come from
// partner_statement_data, read as the signed-in partner, so a partner only
// ever gets their own; the PDF is kept in the private `partner-statements`
// bucket and handed back as a link that lasts five minutes.
//
// Request:  POST { type: "weekly" | "monthly" | "annual", start: "YYYY-MM-DD", lang: "en" | "ms" }
// Answer:   { url, fileName, statementNo, status: "provisional" | "final" | "revised", revisedAt }
//
// See _shared/partner_statement.ts for the rules (kept, remade, revised).
// The look is Admin → Partner statements → Layout's (migration 0217); a kept
// final statement is redrawn, not revised, when that changes.
//
// Admins also ask for a made-up sample in a layout not yet saved:
//   POST { preview: true, type, lang, layout } → { pdf (base64), fileName }
//
// Deploy (the gateway checks for a session):
//   supabase functions deploy partner-statement
// ============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

import {
  handlePreview,
  handleStatement,
  logoKind,
  type StatementData,
} from "../_shared/partner_statement.ts";
import { cleanLayout } from "../_shared/statement_layout.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const url = Deno.env.get("SUPABASE_URL") ?? "";
const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

const BUCKET = "partner-statements";
const LOGO_BUCKET = "app-branding";

async function logo(path: string) {
  const { data, error } = await admin.storage.from(LOGO_BUCKET).download(path);
  if (error || !data) return null;
  return logoKind(new Uint8Array(await data.arrayBuffer()));
}

async function look() {
  const { data, error } = await admin.from("app_settings").select("value").eq("key", "partner_statement_layout").maybeSingle();
  if (error) throw error;
  const layout = cleanLayout(data?.value);
  return { layout, logo: layout.logo.path ? await logo(layout.logo.path) : null };
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const auth = req.headers.get("Authorization") ?? "";
  const user = createClient(url, anonKey, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  try {
    const body = await req.json().catch(() => null);
    if (body && typeof body === "object" && (body as { preview?: unknown }).preview === true) {
      const answer = await handlePreview(body, {
        isAdmin: async () => {
          const { data, error } = await user.rpc("caller_is_admin");
          return !error && data === true;
        },
        company: async () => {
          const { data, error } = await user.rpc("partner_statement_config");
          if (error) throw error;
          const c = (data ?? {}) as Record<string, string>;
          return { name: c.companyName ?? "", ssm: c.companySsm ?? "", support: c.supportContact ?? "", verifyUrl: c.verifyUrl };
        },
        logo,
      });
      return json(answer.body, answer.status);
    }
    const answer = await handleStatement(body, {
      uid: async () => {
        const jwt = auth.replace(/^Bearer\s+/i, "");
        if (!jwt) return null;
        const { data } = await admin.auth.getUser(jwt);
        return data.user?.id ?? null;
      },
      data: async (type, start, lang) => {
        const { data, error } = await user.rpc("partner_statement_data", { p_type: type, p_start: start, p_lang: lang });
        if (error) throw error;
        return data as StatementData;
      },
      find: async (uid, type, start, lang) => {
        const { data, error } = await admin.from("partner_statements")
          .select("statement_no, verify_token, is_final, data_hash, layout_hash, storage_path, revised_at")
          .eq("partner_user_id", uid).eq("period_type", type).eq("period_start", start).eq("lang", lang)
          .maybeSingle();
        if (error) throw error;
        return data;
      },
      take: async (uid) => {
        const { data, error } = await admin.rpc("statement_take", { p_uid: uid });
        if (error) throw error;
        return data === true;
      },
      nextNo: async (type) => {
        const { data, error } = await admin.rpc("statement_next_no", { p_type: type });
        if (error) throw error;
        return data as string;
      },
      upload: async (path, pdf) => {
        const { error } = await admin.storage.from(BUCKET).upload(path, pdf, {
          contentType: "application/pdf",
          upsert: true,
        });
        if (error) throw error;
      },
      save: async (row) => {
        const { error } = await admin.from("partner_statements")
          .upsert(row, { onConflict: "partner_user_id,period_type,period_start,lang" });
        if (error) throw error;
      },
      signedUrl: async (path, fileName) => {
        const { data, error } = await admin.storage.from(BUCKET).createSignedUrl(path, 300, { download: fileName });
        if (error) throw error;
        return data.signedUrl;
      },
      now: () => new Date(),
      look,
    });
    return json(answer.body, answer.status);
  } catch (e) {
    console.error("partner-statement:", e instanceof Error ? e.message : "failed");
    return json({ error: "unavailable" }, 503);
  }
});
