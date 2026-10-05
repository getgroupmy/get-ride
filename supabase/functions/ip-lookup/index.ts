// ============================================================================
// ip-lookup — Supabase Edge Function
// ----------------------------------------------------------------------------
// Resolves the CALLER'S public IP address and its ISP / geolocation.
//
// The mobile client can only read its LAN/local IP (e.g. 192.168.x.x), which
// reveals nothing about the ISP. This function reads the public/egress IP from
// the request headers (set by Supabase's edge proxy) and resolves the ISP via a
// free, no-key IP geolocation provider (ipwho.is, with ip-api.com as fallback).
//
// Request:  POST (no body needed). An explicit IP can be passed as { ip }.
// Response: { public_ip, isp_provider, isp_org, ip_city, ip_region, ip_country }
//
// Deploy:
//   supabase functions deploy ip-lookup --no-verify-jwt
// ============================================================================

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
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

/** Extract the first public IP from proxy headers. */
function resolveCallerIp(req: Request): string | null {
  const candidates = [
    req.headers.get("x-forwarded-for"),
    req.headers.get("x-real-ip"),
    req.headers.get("cf-connecting-ip"),
    req.headers.get("fly-client-ip"),
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

/** Fallback provider: ip-api.com (free, HTTP only — used as best-effort). */
async function lookupIpApi(ip: string): Promise<IpInfo | null> {
  try {
    const res = await fetch(
      `http://ip-api.com/json/${encodeURIComponent(
        ip
      )}?fields=status,country,regionName,city,isp,org,query`
    );
    if (!res.ok) return null;
    const d = await res.json();
    if (d?.status !== "success") return null;
    return {
      public_ip: typeof d?.query === "string" ? d.query : ip,
      isp_provider: d?.isp ?? null,
      isp_org: d?.org ?? null,
      ip_city: d?.city ?? null,
      ip_region: d?.regionName ?? null,
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

  // Allow an explicit IP override in the body, else resolve from headers.
  let bodyIp: string | null = null;
  if (req.method === "POST") {
    try {
      const body = await req.json();
      if (typeof body?.ip === "string" && body.ip.trim()) {
        bodyIp = body.ip.trim();
      }
    } catch {
      // no body — fine
    }
  }

  const ip = bodyIp ?? resolveCallerIp(req);

  if (!ip) {
    return json({ ...EMPTY }, 200);
  }
  if (isPrivateIp(ip)) {
    // Can't resolve ISP for a private/loopback address.
    return json({ ...EMPTY, public_ip: ip }, 200);
  }

  const info = (await lookupIpWhoIs(ip)) ?? (await lookupIpApi(ip));
  if (!info) {
    return json({ ...EMPTY, public_ip: ip }, 200);
  }

  return json(info, 200);
});
