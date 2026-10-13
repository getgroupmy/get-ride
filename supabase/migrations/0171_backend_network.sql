-- ============================================================================
-- 0171: Admin -> App Settings -> Backend network
--
-- Extra addresses the app may reach the backend on, and the DNS-over-HTTPS
-- resolvers it asks when the phone's own DNS cannot look any of them up
-- (lib/src/core/backend_network.dart):
--
--   {"backends": ["https://api2.getride.my"], "doh": ["https://1.1.1.1/dns-query"]}
--
-- It lives on the app_branding row, which every app already reads (signed
-- in or not) and caches for the next launch -- the point, since a phone that
-- cannot reach the backend cannot read new settings. It is no secret: a
-- list of public addresses. Writes stay admin-only like the rest of the row,
-- and the app itself refuses any backend address outside getride.my or the
-- project's own host, whatever the row says.
-- ============================================================================

alter table public.app_branding
  add column if not exists network jsonb not null default '{}'::jsonb;

do $$
begin
  alter table public.app_branding
    add constraint app_branding_network_shape check (
      jsonb_typeof(network) = 'object'
      and (not network ? 'backends' or jsonb_typeof(network->'backends') = 'array')
      and (not network ? 'doh' or jsonb_typeof(network->'doh') = 'array')
    );
exception when duplicate_object then null;
end $$;
