-- ============================================================================
-- Region ride-display rules (migration 0411)
--
-- Two switches an admin sets per region, scoped exactly like a commission rate
-- (migration 0216): Country / State / City / Suburb, plus one master default,
-- resolved narrowest-first.
--
--   * ai_fare_off        -- turn the AI fare off here: the ride home prices on
--                           the plain route and drops the "AI" estimate badge.
--   * distance_time_off  -- hide the "12 km · 24 min" distance/time line here.
--
-- One winning rule carries both switches. Riders read the rules on the device
-- (so the gate works with no signal to the server); admins alone may write.
-- The store degrades to showing everything where this table isn't applied yet.
-- ============================================================================

create table if not exists public.ride_display_rules (
  id                uuid primary key default gen_random_uuid(),
  level             text not null check (level in ('master', 'country', 'state', 'city', 'suburb')),
  country           text check (country is null or char_length(btrim(country)) between 1 and 120),
  state             text check (state is null or char_length(btrim(state)) between 1 and 120),
  city              text check (city is null or char_length(btrim(city)) between 1 and 120),
  suburb            text check (suburb is null or char_length(btrim(suburb)) between 1 and 120),
  ai_fare_off       boolean not null default false,
  distance_time_off boolean not null default false,
  active            boolean not null default true,
  priority          integer not null default 0,
  note              text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint ride_display_rules_names check (
    (level = 'master' and country is null and state is null and city is null and suburb is null)
    or (level = 'country' and country is not null and state is null and city is null and suburb is null)
    or (level = 'state' and country is not null and state is not null and city is null and suburb is null)
    or (level = 'city' and country is not null and state is not null and city is not null and suburb is null)
    or (level = 'suburb' and country is not null and state is not null and city is not null and suburb is not null))
);

comment on table public.ride_display_rules is
  'Region ride-display rules (0411): per Country/State/City/Suburb (+ one master), '
  'turn off the AI fare and/or the distance-time line. Resolved narrowest-first like commission_rates.';

drop trigger if exists trg_ride_display_rules_updated_at on public.ride_display_rules;
create trigger trg_ride_display_rules_updated_at before update on public.ride_display_rules
  for each row execute function public.set_updated_at();

alter table public.ride_display_rules enable row level security;
revoke all on public.ride_display_rules from anon;
grant select, insert, update, delete on public.ride_display_rules to authenticated;

drop policy if exists "ride_display_rules read" on public.ride_display_rules;
drop policy if exists "ride_display_rules admin insert" on public.ride_display_rules;
drop policy if exists "ride_display_rules admin update" on public.ride_display_rules;
drop policy if exists "ride_display_rules admin delete" on public.ride_display_rules;

-- Every signed-in rider reads the rules (the gate runs on the device).
create policy "ride_display_rules read"
  on public.ride_display_rules for select to authenticated
  using (true);
-- Admins alone write.
create policy "ride_display_rules admin insert"
  on public.ride_display_rules for insert to authenticated
  with check ((select public.caller_is_admin()));
create policy "ride_display_rules admin update"
  on public.ride_display_rules for update to authenticated
  using ((select public.caller_is_admin()))
  with check ((select public.caller_is_admin()));
create policy "ride_display_rules admin delete"
  on public.ride_display_rules for delete to authenticated
  using ((select public.caller_is_admin()));

-- Live: the ride home refetches the moment an admin saves (live_tables.dart).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'ride_display_rules'
  ) then
    alter publication supabase_realtime add table public.ride_display_rules;
  end if;
end $$;
