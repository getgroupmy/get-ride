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
// Request:  POST { "ip_only": true } (or ?ip_only=1)
// Response: { public_ip }  from the headers only: no rate check, no provider.
//
// Everything else is in _shared/ip_lookup.ts (the per-instance answer cache,
// the 2.5 s provider timeout) and tested there.
//
// Deploy (the gateway checks for the project's key or a session):
//   supabase functions deploy ip-lookup
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleIpLookup, IpInfoCache, lookupIpWhoIs } from "../_shared/ip_lookup.ts";

const db = createClient(Deno.env.get("SUPABASE_URL") ?? "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "", {
  auth: { persistSession: false, autoRefreshToken: false },
});

const cache = new IpInfoCache();

async function rateTake(ip: string): Promise<boolean> {
  const { data: wait, error } = await db.rpc("auth_rate_take", {
    p_bucket: "ip_lookup",
    p_key: ip,
    p_limit: 30,
    p_window: "10 minutes",
  });
  return !error && typeof wait === "number" && wait <= 0;
}

Deno.serve((req: Request) =>
  handleIpLookup(req, {
    rateTake,
    lookup: (ip) => lookupIpWhoIs(ip),
    cache,
    now: () => Date.now(),
  })
);
