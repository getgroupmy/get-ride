-- ============================================================================
-- 0266 — Places inside an airport: the place or the airport, as the admin sets.
--
-- 0258's area_at answered an airport first, then the smallest place. A mall
-- with its own boundary and doors inside an airport's (Mitsui Outlet Park,
-- inside KLIA's) was then the airport: the rider's pin went to the airport's
-- doors, kilometres away, and the mall's doors were refused
-- (AIRPORT_DOOR_INVALID).
--
-- 1. public.area_precedence_settings: one row, mode, set on Admin → Airport
--    Areas (Places inside an airport). Everyone signed in reads it; writes
--    are caller_admin_can_write('area_precedence_settings') (an EDIT grant
--    on Airport Areas). Live for running apps.
--      part_of (default)  the smallest place holding the point, unless it is
--                         "Part of" the same group as the airport (KLIA T1 /
--                         T2 (ERL), part of KLIA): those stay the airport's.
--      place              always the smallest place.
--      airport            always the airport (0258's rule).
--    "Part of" is compared trimmed, one space between words, any case, and
--    only when both have one: the airport's airport_areas.values.partOf, the
--    place's multi_gate.values.partOf.
-- 2. area_at follows it. A point in places only is the smallest of them, in
--    airports only the first by position, as before. Everything that asks
--    airport_at (the ride trigger, the fare quote, the scheduled doors, the
--    driver's state) follows. The app picks the same way
--    (lib/src/core/gate_snap.dart, gateAreaAt).
-- ============================================================================

-- ---- 1. The setting ------------------------------------------------------------------------------
create table if not exists public.area_precedence_settings (
  id         integer primary key default 1,
  mode       text not null default 'part_of',
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint area_precedence_settings_one check (id = 1),
  constraint area_precedence_settings_mode check (mode in ('part_of', 'place', 'airport'))
);
insert into public.area_precedence_settings (id) values (1) on conflict do nothing;
comment on table public.area_precedence_settings is
  'Which area a point inside both an airport and a place is at: part_of (the place unless it is Part of the airport), place or airport (0266).';

create or replace function public.area_precedence_settings_stamp()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;
revoke execute on function public.area_precedence_settings_stamp() from public, anon, authenticated;
drop trigger if exists trg_area_precedence_settings_stamp on public.area_precedence_settings;
create trigger trg_area_precedence_settings_stamp before update on public.area_precedence_settings
  for each row execute function public.area_precedence_settings_stamp();

alter table public.area_precedence_settings enable row level security;
revoke all on public.area_precedence_settings from anon;
grant select, update on public.area_precedence_settings to authenticated;
drop policy if exists "area_precedence_settings read" on public.area_precedence_settings;
create policy "area_precedence_settings read" on public.area_precedence_settings
  for select to authenticated using (true);
drop policy if exists "area_precedence_settings admin update" on public.area_precedence_settings;
create policy "area_precedence_settings admin update" on public.area_precedence_settings for update to authenticated
  using ((select public.caller_admin_can_write('area_precedence_settings')))
  with check ((select public.caller_admin_can_write('area_precedence_settings')));

insert into public.admin_table_pages (target, page) values
  ('area_precedence_settings', 'admin-settings-airport-areas')
on conflict do nothing;

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public'
                    and tablename = 'area_precedence_settings') then
    alter publication supabase_realtime add table public.area_precedence_settings;
  end if;
end $$;

-- ---- 2. Where a point is --------------------------------------------------------------------------
-- A "Part of" as compared ('' for none): lib/src/core/place_gates.dart's partOfKey.
create or replace function public.area_part_of_key(p text)
returns text
language sql
immutable
set search_path = public
as $$ select lower(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g')); $$;

-- The area holding a point (0258's, now with the setting): the smallest place
-- and the first airport holding it; where both do, the one the setting picks.
create or replace function public.area_at(p_lat float8, p_lng float8)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  with holding as (
    select a.id, a.kind, a.size_m2, a.position, a.created_at,
           public.area_part_of_key(case when a.kind = 'place' then g.values->>'partOf' else a.values->>'partOf' end) as part_of
      from public.airport_areas a
      left join public.multi_gate g on a.kind = 'place' and g.id = a.place_id
     where a.active and p_lat is not null and p_lng is not null
       and public.airport_in_rings(p_lat, p_lng,
             public.airport_rings(case when a.kind = 'place' then a.shape else a.values->'boundary' end))
  ),
  place as (
    select * from holding where kind = 'place'
     order by coalesce(size_m2, 'infinity'::float8), position, created_at
     limit 1
  ),
  airport as (
    select * from holding where kind = 'airport'
     order by position, created_at
     limit 1
  )
  select case
           when p.id is null then a.id
           when a.id is null then p.id
           when m.mode = 'airport' then a.id
           when m.mode = 'place' then p.id
           when p.part_of <> '' and p.part_of = a.part_of then a.id
           else p.id
         end
    from (select coalesce((select mode from public.area_precedence_settings where id = 1), 'part_of') as mode) m
    left join place p on true
    left join airport a on true;
$$;
revoke execute on function public.area_at(float8, float8) from public, anon;
grant execute on function public.area_at(float8, float8) to authenticated, service_role;

notify pgrst, 'reload schema';
