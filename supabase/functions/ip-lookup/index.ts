// ============================================================================
// ip-lookup — Supabase Edge Function
// ----------------------------------------------------------------------------
// Resolves the CALLER'S public IP address and its ISP / geolocation.
//
// The mobile client can only read its LAN/local IP (e.g. 192.168.x.x), which
// reveals nothing about the ISP. This function reads the public/egress IP from
// the request headers (set by Supabase's edge proxy) and resolves the ISP via a
// free, no-key IP geolocation provider (ipwho.is, over HTTPS).
//
// Only the caller's own address is looked up (an address in the body is
// ignored), at most 30 times in 10 minutes per address, so it is no free
// geolocation service for anyone else.
//
// Request:  POST (no body needed).
// Response: { public_ip, isp_provider, isp_org, ip_city, ip_region, ip_country }
//
// Deploy (the gateway checks for the project's key or a session):
//   supabase functions deploy ip-lookup
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
  "Access-Control-Max-Age": "7200",
};

interface IpInfo {
  public_ip: string | null;
  isp_provider: string | null;
  isp_org: string | null;
  ip_city: string | null;
  ip_region: string | null;
  ip_country: string | null;
}

function json(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const EMPTY: IpInfo = {
  public_ip: null,
  isp_provider: null,
  isp_org: null,
  ip_city: null,
  ip_region: null,
  ip_country: null,
};

/**
 * The caller's address from the proxy headers: Cloudflare's own first (a
 * client cannot set it through Cloudflare), as request_client_ip (0137) does.
 */
function resolveCallerIp(req: Request): string | null {
  const candidates = [
    req.headers.get("cf-connecting-ip"),
    req.headers.get("x-real-ip"),
    req.headers.get("x-forwarded-for"),
  ];
  for (const raw of candidates) {
    if (!raw) continue;
    // x-forwarded-for may be a comma-separated list; the client is the first.
    const first = raw.split(",")[0]?.trim();
    if (first) return first;
  }
  return null;
}

function isPrivateIp(ip: string): boolean {
  return (
    ip.startsWith("10.") ||
    ip.startsWith("192.168.") ||
    ip.startsWith("127.") ||
    ip.startsWith("::1") ||
    ip.startsWith("fe80:") ||
    /^172\.(1[6-9]|2[0-9]|3[0-1])\./.test(ip)
  );
}

/** Primary provider: ipwho.is (free, HTTPS, no key). */
async function lookupIpWhoIs(ip: string): Promise<IpInfo | null> {
  try {
    const res = await fetch(`https://ipwho.is/${encodeURIComponent(ip)}`);
    if (!res.ok) return null;
    const d = await res.json();
    if (d?.success === false) return null;
    return {
      public_ip: typeof d?.ip === "string" ? d.ip : ip,
      isp_provider: d?.connection?.isp ?? null,
      isp_org: d?.connection?.org ?? d?.connection?.domain ?? null,
      ip_city: d?.city ?? null,
      ip_region: d?.region ?? null,
      ip_country: d?.country ?? null,
    };
  } catch {
    return null;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST" && req.method !== "GET") return json({ error: "method_not_allowed" }, 405);
  await req.body?.cancel();

  const ip = resolveCallerIp(req);

  if (!ip) {
    return json({ ...EMPTY }, 200);
  }
  if (isPrivateIp(ip)) {
    // Can't resolve ISP for a private/loopback address.
    return json({ ...EMPTY, public_ip: ip }, 200);
  }

  // Fails closed: when the limit can't be checked, nothing is looked up.
  const { data: wait, error: rateErr } = await db.rpc("auth_rate_take", {
    p_bucket: "ip_lookup",
    p_key: ip,
    p_limit: 30,
    p_window: "10 minutes",
  });
  if (rateErr || typeof wait !== "number" || wait > 0) {
    return json({ ...EMPTY, public_ip: ip }, 200);
  }

  const info = await lookupIpWhoIs(ip);
  if (!info) {
    return json({ ...EMPTY, public_ip: ip }, 200);
  }

  return json(info, 200);
});
