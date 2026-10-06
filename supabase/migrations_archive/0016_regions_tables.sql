-- ============================================================================
-- Migration 0016: dedicated regions tables (countries / states / cities / suburbs)
-- ----------------------------------------------------------------------------
-- Source of truth for admin-settings-country-states-cities.tsx. Previously
-- rows were stored in `settings_entries` under category 'country-states-cities'
-- with the level inferred from which of {country,state,city,suburb} were
-- populated. We now split storage by level so each row has typed columns and
-- can be queried directly.
--
-- The admin UI still treats the dataset as one logical collection; the
-- adminSync layer fans writes out to the right table by inspecting the row's
-- level fields, and fetches union all four tables back together.
--
-- Safe to re-run.
-- ============================================================================

-- Countries -----------------------------------------------------------------
create table if not exists public.countries (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (name)
);

create index if not exists countries_name_idx on public.countries(name);
create index if not exists countries_position_idx on public.countries(position);

drop trigger if exists trg_countries_updated_at on public.countries;
create trigger trg_countries_updated_at
  before update on public.countries
  for each row execute function public.set_updated_at();

alter table public.countries enable row level security;
drop policy if exists "countries read"   on public.countries;
drop policy if exists "countries insert" on public.countries;
drop policy if exists "countries update" on public.countries;
drop policy if exists "countries delete" on public.countries;
create policy "countries read"   on public.countries for select using (true);
create policy "countries insert" on public.countries for insert to public with check (true);
create policy "countries update" on public.countries for update to public using (true) with check (true);
create policy "countries delete" on public.countries for delete to public using (true);
grant select, insert, update, delete on public.countries to anon, authenticated;

alter table public.countries replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.countries;
exception when duplicate_object then null; when others then null; end $$;

-- States --------------------------------------------------------------------
create table if not exists public.states (
  id          uuid primary key default gen_random_uuid(),
  country     text not null,
  name        text not null,
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (country, name)
);

create index if not exists states_country_idx on public.states(country);
create index if not exists states_name_idx on public.states(name);
create index if not exists states_position_idx on public.states(position);

drop trigger if exists trg_states_updated_at on public.states;
create trigger trg_states_updated_at
  before update on public.states
  for each row execute function public.set_updated_at();

alter table public.states enable row level security;
drop policy if exists "states read"   on public.states;
drop policy if exists "states insert" on public.states;
drop policy if exists "states update" on public.states;
drop policy if exists "states delete" on public.states;
create policy "states read"   on public.states for select using (true);
create policy "states insert" on public.states for insert to public with check (true);
create policy "states update" on public.states for update to public using (true) with check (true);
create policy "states delete" on public.states for delete to public using (true);
grant select, insert, update, delete on public.states to anon, authenticated;

alter table public.states replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.states;
exception when duplicate_object then null; when others then null; end $$;

-- Cities --------------------------------------------------------------------
create table if not exists public.cities (
  id          uuid primary key default gen_random_uuid(),
  country     text not null,
  state       text not null,
  name        text not null,
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (country, state, name)
);

create index if not exists cities_country_idx on public.cities(country);
create index if not exists cities_state_idx on public.cities(state);
create index if not exists cities_name_idx on public.cities(name);
create index if not exists cities_position_idx on public.cities(position);

drop trigger if exists trg_cities_updated_at on public.cities;
create trigger trg_cities_updated_at
  before update on public.cities
  for each row execute function public.set_updated_at();

alter table public.cities enable row level security;
drop policy if exists "cities read"   on public.cities;
drop policy if exists "cities insert" on public.cities;
drop policy if exists "cities update" on public.cities;
drop policy if exists "cities delete" on public.cities;
create policy "cities read"   on public.cities for select using (true);
create policy "cities insert" on public.cities for insert to public with check (true);
create policy "cities update" on public.cities for update to public using (true) with check (true);
create policy "cities delete" on public.cities for delete to public using (true);
grant select, insert, update, delete on public.cities to anon, authenticated;

alter table public.cities replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.cities;
exception when duplicate_object then null; when others then null; end $$;

-- Suburbs -------------------------------------------------------------------
create table if not exists public.suburbs (
  id          uuid primary key default gen_random_uuid(),
  country     text not null,
  state       text not null,
  city        text not null,
  name        text not null,
  values      jsonb not null default '{}'::jsonb,
  position    integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (country, state, city, name)
);

create index if not exists suburbs_country_idx on public.suburbs(country);
create index if not exists suburbs_state_idx on public.suburbs(state);
create index if not exists suburbs_city_idx on public.suburbs(city);
create index if not exists suburbs_name_idx on public.suburbs(name);
create index if not exists suburbs_position_idx on public.suburbs(position);

drop trigger if exists trg_suburbs_updated_at on public.suburbs;
create trigger trg_suburbs_updated_at
  before update on public.suburbs
  for each row execute function public.set_updated_at();

alter table public.suburbs enable row level security;
drop policy if exists "suburbs read"   on public.suburbs;
drop policy if exists "suburbs insert" on public.suburbs;
drop policy if exists "suburbs update" on public.suburbs;
drop policy if exists "suburbs delete" on public.suburbs;
create policy "suburbs read"   on public.suburbs for select using (true);
create policy "suburbs insert" on public.suburbs for insert to public with check (true);
create policy "suburbs update" on public.suburbs for update to public using (true) with check (true);
create policy "suburbs delete" on public.suburbs for delete to public using (true);
grant select, insert, update, delete on public.suburbs to anon, authenticated;

alter table public.suburbs replica identity full;
do $$ begin
  alter publication supabase_realtime add table public.suburbs;
exception when duplicate_object then null; when others then null; end $$;

-- Best-effort backfill: copy any existing rows in `settings_entries` under
-- the 'country-states-cities' category into the right table, then remove
-- them from settings_entries so we don't read them twice.
do $$
declare r record;
declare c text; s text; ci text; sb text;
declare vals jsonb;
begin
  for r in
    select id, values, position from public.settings_entries
    where category = 'country-states-cities'
  loop
    vals := coalesce(r.values, '{}'::jsonb);
    c  := coalesce(nullif(trim(vals->>'country'), ''), '');
    s  := coalesce(nullif(trim(vals->>'state'),   ''), '');
    ci := coalesce(nullif(trim(vals->>'city'),    ''), '');
    sb := coalesce(nullif(trim(vals->>'suburb'),  ''), '');

    if c <> '' and s = '' and ci = '' and sb = '' then
      insert into public.countries (id, name, values, position)
      values (r.id, c, vals, coalesce(r.position, 0))
      on conflict (name) do update set values = excluded.values;
    elsif s <> '' and ci = '' and sb = '' then
      insert into public.states (id, country, name, values, position)
      values (r.id, c, s, vals, coalesce(r.position, 0))
      on conflict (country, name) do update set values = excluded.values;
    elsif ci <> '' and sb = '' then
      insert into public.cities (id, country, state, name, values, position)
      values (r.id, c, s, ci, vals, coalesce(r.position, 0))
      on conflict (country, state, name) do update set values = excluded.values;
    elsif sb <> '' then
      insert into public.suburbs (id, country, state, city, name, values, position)
      values (r.id, c, s, ci, sb, vals, coalesce(r.position, 0))
      on conflict (country, state, city, name) do update set values = excluded.values;
    end if;
  end loop;

  delete from public.settings_entries where category = 'country-states-cities';
end $$;
