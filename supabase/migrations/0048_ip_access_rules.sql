-- ============================================================================
-- IP access rules: admin-managed whitelist / blacklist
-- ----------------------------------------------------------------------------
-- Each row pins a single IP address to either a whitelist or a blacklist.
--   * whitelist → the device is trusted; admins on that IP can enter the admin
--     dashboard without a PIN / credentials.
--   * blacklist → the device is blocked; the user is stopped at the login page
--     and cannot place a ride request ("Service Not Available").
--
-- RLS is permissive to match the rest of this project (admin uses a non-RLS
-- super session; the app uses the anon/auth client). Safe to re-run.
-- ============================================================================

create table if not exists public.ip_access_rules (
  id uuid primary key default gen_random_uuid(),
  ip_address text not null,
  list_type  text not null default 'blacklist'
    check (list_type in ('whitelist','blacklist')),
  label      text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (ip_address, list_type)
);

create index if not exists ip_access_rules_type_idx on public.ip_access_rules(list_type);
create index if not exists ip_access_rules_ip_idx   on public.ip_access_rules(ip_address);

-- updated_at trigger ---------------------------------------------------------
do $$
begin
  drop trigger if exists trg_ip_access_rules_updated_at on public.ip_access_rules;
  create trigger trg_ip_access_rules_updated_at before update on public.ip_access_rules
    for each row execute function public.set_updated_at();
end$$;

-- RLS (permissive) -----------------------------------------------------------
alter table public.ip_access_rules enable row level security;

drop policy if exists "ip_access_rules read"   on public.ip_access_rules;
drop policy if exists "ip_access_rules insert" on public.ip_access_rules;
drop policy if exists "ip_access_rules update" on public.ip_access_rules;
drop policy if exists "ip_access_rules delete" on public.ip_access_rules;

create policy "ip_access_rules read"   on public.ip_access_rules for select using (true);
create policy "ip_access_rules insert" on public.ip_access_rules for insert to public with check (true);
create policy "ip_access_rules update" on public.ip_access_rules for update to public using (true) with check (true);
create policy "ip_access_rules delete" on public.ip_access_rules for delete to public using (true);

grant select, insert, update, delete on public.ip_access_rules to anon, authenticated;
