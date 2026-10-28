-- ============================================================================
-- 0322 — Rider live map ("God View" in the rider app): what a rider may see
-- on the home map besides their own trip, every part decided here on the
-- server. The app only draws what these functions return.
--
-- Version 20261028150000 (0322_rider_live_map). Re-runnable: tables, columns
-- and indexes "if not exists", functions "create or replace", policies and
-- triggers dropped first, the Default rule only where missing.
--
-- Privacy (owner's rules, binding):
--   * People are seen only through Family's disclosed options (0317): the
--     member's app says "Shared with family" and who can see, and they can
--     stop at once (rider_live_map_stop_sharing, or leaving the family).
--   * Team shows only company-paid trips (business accounts, 0313), only
--     while they run (and the admin's minutes after), only to the roles the
--     admin allows. The member's trip screen says "Company trip" and who can
--     see it. Personal trips never show.
--   * Strangers are never identified. Cars near me returns no name, plate,
--     photo, rating or id; each car is moved by a random distance (between
--     half and all of the admin's) in a random direction, kept for the hour
--     so averaging polls doesn't find the real spot; only online drivers who
--     are free.
--   * Busy areas returns no counts and no trip ids: a hexagon only once it
--     holds the admin's minimum of bookings, with its level 0-4.
--
-- 1. rider_live_map_rules: a Default rule (country '') and rules per region
--    (country / state / city / suburb). The most specific matching rule
--    wins and a region rule only overrides what it sets (null follows the
--    rule above it): rider_live_map_settings_at(place). Per mode:
--      Cars near me  cars_on, cars_may_hide (riders may hide it in
--                    Settings), cars_fields (car, bike, van, count,
--                    pickup_time), cars_offset_m (0-1000, 150),
--                    cars_every_s (5-120, 10), cars_radius_m (500-10000).
--      Busy areas    busy_on, busy_who (all | plus | nobody), busy_fields
--                    (level, fare, wait, next_hour, tip), busy_hex_m
--                    (100-2000, 350 across), busy_min (1-100, 5),
--                    busy_every_s (15-600, 60), busy_window_min (5-240, 30),
--                    busy_colours (4 colours, pale yellow to deep red),
--                    busy_opacity (10-90 %, 55).
--      My people     people_on, people_who (hosts | members | nobody),
--                    people_fields (spot, status, eta, dropoff, driver),
--                    people_history_min (0-120, 0 = none), people_after_min
--                    (0-60, 5), people_every_s (5-120, 10).
--      Team          team_on, team_who (admins | staff | nobody),
--                    team_fields (spot, purpose, eta, cost), team_after_min
--                    (0-60, 0), team_log_days (1-365, 30), team_every_s.
--    Every mode starts OFF in the seeded Default, so nothing changes until
--    an admin turns it on. Admins with EDIT on Admin › Settings › Rider live
--    map ('admin-settings-rider-live-map') write the rules; every write is
--    in admin_audit_log (trg_rider_live_map_rules_audit).
-- 2. The rider's functions, each signed-in only, each answering at most once
--    per the rule's update interval (a call sooner gets the last answer,
--    rider_live_map_calls):
--      rider_live_map_config(place)       which overlays this rider may use;
--      rider_live_map_cars(lat, lng, place)
--      rider_live_map_busy(south, west, north, east, place)
--      rider_live_map_people(place)       (the family's region decides)
--      rider_live_map_team(place)         (the company's region decides)
--      rider_live_map_trip_note(trip)     the member's "Company trip" chip;
--      rider_live_map_stop_sharing(trip)  the member stops at once.
--    family_trip_status (0317) also names "your family members" when the
--    rule lets members see each other.
-- 3. Busy hexagons are worked out here from open and recent requests
--    (ride_requests' pickups): pointy-top hexagons busy_hex_m across, on a
--    Web Mercator grid scaled at the box's latitude (whole degrees, returned
--    as latRef) so the app draws the same cells (lib/src/core/rider_live_map.dart
--    is the twin). The fare level is the same comparison the fare trend
--    arrows make (0115): the AI's traffic-aware time over the standard
--    route's, from fare_ai_responses starting in the cell; the pickup wait
--    is accepted to arrived; the next hour compares the window's two halves;
--    the tip names a quieter cell nearby.
-- 4. Family is one shared layer for booking modules (CLAUDE.md, "Every
--    booking module works with Family"); the live map books nothing, so it is
--    not a booking module. It plugs in through Family's own functions:
--    family_can_view_location, family_location_rule, family_shared_trip and
--    the per-module live_share switch on each trip.
-- ============================================================================

-- ---- 1. The rules --------------------------------------------------------------------------------
create table if not exists public.rider_live_map_rules (
  id                 uuid primary key default gen_random_uuid(),
  -- '' at every level: the Default rule. A state needs its country, a city its state, a suburb its city.
  country            text not null default '' check (length(country) <= 80),
  state              text not null default '' check (length(state) <= 80),
  city               text not null default '' check (length(city) <= 80),
  suburb             text not null default '' check (length(suburb) <= 80),
  -- Cars near me.
  cars_on            boolean,
  cars_may_hide      boolean,
  cars_fields        text[] check (cars_fields is null or cars_fields <@ array['car', 'bike', 'van', 'count', 'pickup_time']::text[]),
  cars_offset_m      integer check (cars_offset_m is null or cars_offset_m between 0 and 1000),
  cars_every_s       integer check (cars_every_s is null or cars_every_s between 5 and 120),
  cars_radius_m      integer check (cars_radius_m is null or cars_radius_m between 500 and 10000),
  -- Busy areas.
  busy_on            boolean,
  busy_who           text check (busy_who is null or busy_who in ('all', 'plus', 'nobody')),
  busy_fields        text[] check (busy_fields is null or busy_fields <@ array['level', 'fare', 'wait', 'next_hour', 'tip']::text[]),
  busy_hex_m         integer check (busy_hex_m is null or busy_hex_m between 100 and 2000),
  busy_min           integer check (busy_min is null or busy_min between 1 and 100),
  busy_every_s       integer check (busy_every_s is null or busy_every_s between 15 and 600),
  busy_window_min    integer check (busy_window_min is null or busy_window_min between 5 and 240),
  busy_colours       text[] check (busy_colours is null or (array_length(busy_colours, 1) = 4
                                   and array_to_string(busy_colours, ',') ~ '^#[0-9A-Fa-f]{6}(,#[0-9A-Fa-f]{6}){3}$')),
  busy_opacity       integer check (busy_opacity is null or busy_opacity between 10 and 90),
  -- My people (Family).
  people_on          boolean,
  people_who         text check (people_who is null or people_who in ('hosts', 'members', 'nobody')),
  people_fields      text[] check (people_fields is null or people_fields <@ array['spot', 'status', 'eta', 'dropoff', 'driver']::text[]),
  people_history_min integer check (people_history_min is null or people_history_min between 0 and 120),
  people_after_min   integer check (people_after_min is null or people_after_min between 0 and 60),
  people_every_s     integer check (people_every_s is null or people_every_s between 5 and 120),
  -- Team (business accounts).
  team_on            boolean,
  team_who           text check (team_who is null or team_who in ('admins', 'staff', 'nobody')),
  team_fields        text[] check (team_fields is null or team_fields <@ array['spot', 'purpose', 'eta', 'cost']::text[]),
  team_after_min     integer check (team_after_min is null or team_after_min between 0 and 60),
  team_log_days      integer check (team_log_days is null or team_log_days between 1 and 365),
  team_every_s       integer check (team_every_s is null or team_every_s between 5 and 120),
  active             boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  check (state = '' or country <> ''),
  check (city = '' or state <> ''),
  check (suburb = '' or city <> ''),
  -- The Default rule sets every value and is always in force.
  check (country <> '' or (active and cars_on is not null and cars_may_hide is not null and cars_fields is not null
                           and cars_offset_m is not null and cars_every_s is not null and cars_radius_m is not null
                           and busy_on is not null and busy_who is not null and busy_fields is not null
                           and busy_hex_m is not null and busy_min is not null and busy_every_s is not null
                           and busy_window_min is not null and busy_colours is not null and busy_opacity is not null
                           and people_on is not null and people_who is not null and people_fields is not null
                           and people_history_min is not null and people_after_min is not null
                           and people_every_s is not null and team_on is not null and team_who is not null
                           and team_fields is not null and team_after_min is not null and team_log_days is not null
                           and team_every_s is not null))
);
create unique index if not exists rider_live_map_rules_place_key
  on public.rider_live_map_rules (lower(country), lower(state), lower(city), lower(suburb));
comment on table public.rider_live_map_rules is
  'Rider live map (0322): the Default rule (country '''') and rules per region. Null values follow the rule above. Admin › Settings › Rider live map.';

-- The Default: every mode off.
insert into public.rider_live_map_rules
  (id, cars_on, cars_may_hide, cars_fields, cars_offset_m, cars_every_s, cars_radius_m,
   busy_on, busy_who, busy_fields, busy_hex_m, busy_min, busy_every_s, busy_window_min, busy_colours, busy_opacity,
   people_on, people_who, people_fields, people_history_min, people_after_min, people_every_s,
   team_on, team_who, team_fields, team_after_min, team_log_days, team_every_s)
values
  ('b0510322-0000-4000-8000-000000000000', false, true, array['car', 'bike', 'van', 'count', 'pickup_time'], 150, 10, 3000,
   false, 'all', array['level', 'fare', 'wait', 'next_hour', 'tip'], 350, 5, 60, 30,
   array['#FFEDA0', '#FEB24C', '#F03B20', '#99000D'], 55,
   false, 'hosts', array['spot', 'status', 'eta', 'dropoff', 'driver'], 0, 5, 10,
   false, 'admins', array['spot', 'purpose', 'eta', 'cost'], 0, 30, 10)
on conflict do nothing;

create or replace function public.rider_live_map_rules_stamp()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.country := btrim(new.country);
  new.state := btrim(new.state);
  new.city := btrim(new.city);
  new.suburb := btrim(new.suburb);
  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  return new;
end;
$$;
revoke execute on function public.rider_live_map_rules_stamp() from public, anon, authenticated;
drop trigger if exists trg_rider_live_map_rules_stamp on public.rider_live_map_rules;
create trigger trg_rider_live_map_rules_stamp
  before insert or update on public.rider_live_map_rules
  for each row execute function public.rider_live_map_rules_stamp();

-- Every admin write, in admin_audit_log: the region and what changed.
create or replace function public.rider_live_map_rules_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_row jsonb := coalesce(v_new, v_old);
  v_changed jsonb := '{}'::jsonb;
  k text;
begin
  for k in select jsonb_object_keys(coalesce(v_new, v_old)) loop
    if k in ('updated_at', 'updated_by', 'created_at') then
      continue;
    end if;
    if v_old is null or v_new is null or (v_old->k) is distinct from (v_new->k) then
      v_changed := v_changed || jsonb_build_object(k, jsonb_build_object('from', v_old->k, 'to', v_new->k));
    end if;
  end loop;
  if tg_op = 'UPDATE' and v_changed = '{}'::jsonb then
    return null;
  end if;
  insert into public.admin_audit_log (actor_id, action, detail)
  values (auth.uid(), 'rider_live_map.' || lower(tg_op),
          jsonb_build_object('rule', v_row->'id',
                             'region', jsonb_build_object('country', v_row->'country', 'state', v_row->'state',
                                                          'city', v_row->'city', 'suburb', v_row->'suburb'),
                             'changed', v_changed));
  return null;
end;
$$;
revoke execute on function public.rider_live_map_rules_audit() from public, anon, authenticated;
drop trigger if exists trg_rider_live_map_rules_audit on public.rider_live_map_rules;
create trigger trg_rider_live_map_rules_audit
  after insert or update or delete on public.rider_live_map_rules
  for each row execute function public.rider_live_map_rules_audit();

-- Who writes: admins with EDIT on the page; every admin reads.
insert into public.admin_table_pages (target, page) values
  ('rider_live_map_rules', 'admin-settings-rider-live-map')
on conflict do nothing;

alter table public.rider_live_map_rules enable row level security;
revoke all on public.rider_live_map_rules from anon;
grant select, insert, update, delete on public.rider_live_map_rules to authenticated;
drop policy if exists "rider_live_map_rules admin read" on public.rider_live_map_rules;
create policy "rider_live_map_rules admin read" on public.rider_live_map_rules
  for select to authenticated using ((select public.caller_is_admin()));
drop policy if exists "rider_live_map_rules admin insert" on public.rider_live_map_rules;
create policy "rider_live_map_rules admin insert" on public.rider_live_map_rules
  for insert to authenticated with check ((select public.caller_admin_can_write('rider_live_map_rules')));
drop policy if exists "rider_live_map_rules admin update" on public.rider_live_map_rules;
create policy "rider_live_map_rules admin update" on public.rider_live_map_rules
  for update to authenticated using ((select public.caller_admin_can_write('rider_live_map_rules')))
  with check ((select public.caller_admin_can_write('rider_live_map_rules')));
drop policy if exists "rider_live_map_rules admin delete" on public.rider_live_map_rules;
create policy "rider_live_map_rules admin delete" on public.rider_live_map_rules
  for delete to authenticated using (country <> '' and (select public.caller_admin_can_write('rider_live_map_rules')));

-- The rules in force at [p_place] ({country, state, city, suburb}): the
-- Default, then each matching region from the broadest, each only what it sets.
create or replace function public.rider_live_map_settings_at(p_place jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c  text := lower(btrim(coalesce(p_place->>'country', '')));
  s  text := lower(btrim(coalesce(p_place->>'state', '')));
  ci text := lower(btrim(coalesce(p_place->>'city', '')));
  su text := lower(btrim(coalesce(p_place->>'suburb', '')));
  v  jsonb := '{}'::jsonb;
  r  record;
begin
  for r in
    select to_jsonb(x) - array['id', 'country', 'state', 'city', 'suburb', 'active', 'created_at', 'updated_at', 'updated_by'] as j,
           (x.country <> '')::int + (x.state <> '')::int + (x.city <> '')::int + (x.suburb <> '')::int as rank
      from public.rider_live_map_rules x
     where x.active
       and (x.country = '' or lower(x.country) = c)
       and (x.state = '' or lower(x.state) = s)
       and (x.city = '' or lower(x.city) = ci)
       and (x.suburb = '' or lower(x.suburb) = su)
     order by rank
  loop
    v := v || jsonb_strip_nulls(r.j);
  end loop;
  return v;
end;
$$;
revoke execute on function public.rider_live_map_settings_at(jsonb) from public, anon, authenticated;

-- ---- 2. Pure helpers -----------------------------------------------------------------------------
-- A field list of the rules as text[].
create or replace function public.rider_live_map_fields(p jsonb)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array(select jsonb_array_elements_text(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end)), '{}');
$$;

-- Metres between two points (equirectangular: plenty for a few km).
create or replace function public.rider_live_map_metres(p_lat1 float8, p_lng1 float8, p_lat2 float8, p_lng2 float8)
returns float8
language sql
immutable
set search_path = ''
as $$
  select 6371000 * sqrt(power(radians(p_lat2 - p_lat1), 2)
                        + power(radians(p_lng2 - p_lng1) * cos(radians((p_lat1 + p_lat2) / 2)), 2));
$$;

-- The hexagon of a point: pointy-top cells [p_hex_m] across (flat side to
-- flat side) on the Web Mercator plane, scaled at latitude [p_lat_ref].
-- Axial (q, r), rounded through cube coordinates.
create or replace function public.rider_live_map_hex_of(p_lat float8, p_lng float8, p_hex_m float8, p_lat_ref float8,
                                                        out q integer, out r integer)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_size float8 := p_hex_m / cos(radians(p_lat_ref)) / sqrt(3.0);
  x  float8 := radians(p_lng) * 6378137;
  y  float8 := 6378137 * ln(tan(pi() / 4 + radians(greatest(-85, least(85, p_lat))) / 2));
  fq float8 := (sqrt(3.0) / 3 * x - y / 3) / v_size;
  fr float8 := (2.0 / 3 * y) / v_size;
  fs float8 := -fq - fr;
  rq float8 := round(fq);
  rr float8 := round(fr);
  rs float8 := round(fs);
  dq float8 := abs(rq - fq);
  dr float8 := abs(rr - fr);
  ds float8 := abs(rs - fs);
begin
  if dq > dr and dq > ds then
    rq := -rr - rs;
  elsif dr > ds then
    rr := -rq - rs;
  end if;
  q := rq::integer;
  r := rr::integer;
end;
$$;

-- The centre of hexagon (q, r), as above.
create or replace function public.rider_live_map_hex_centre(p_q integer, p_r integer, p_hex_m float8, p_lat_ref float8,
                                                            out lat float8, out lng float8)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_size float8 := p_hex_m / cos(radians(p_lat_ref)) / sqrt(3.0);
  x float8 := v_size * sqrt(3.0) * (p_q + p_r / 2.0);
  y float8 := v_size * 1.5 * p_r;
begin
  lng := degrees(x / 6378137);
  lat := degrees(2 * atan(exp(y / 6378137)) - pi() / 2);
end;
$$;

-- A cell's busy level 0-4 from its bookings and the admin's minimum (the
-- app's busyLevel). Below the minimum: null (not shown).
create or replace function public.rider_live_map_level(p_count integer, p_min integer)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case when p_count is null or p_count < greatest(p_min, 1) then null
              when p_count < 1.5 * greatest(p_min, 1) then 0
              when p_count < 2 * greatest(p_min, 1) then 1
              when p_count < 3 * greatest(p_min, 1) then 2
              when p_count < 5 * greatest(p_min, 1) then 3
              else 4 end;
$$;

-- The eight compass words for the way from one cell to another.
create or replace function public.rider_live_map_direction(p_dx float8, p_dy float8)
returns text
language sql
immutable
set search_path = ''
as $$
  select (array['north', 'north-east', 'east', 'south-east', 'south', 'south-west', 'west', 'north-west'])
           [((round(((degrees(atan2(p_dx, p_dy)) + 360)::numeric % 360) / 45)::integer % 8) + 1)];
$$;

-- Car, bike or van, by the words of the partner's vehicle type (as God View's
-- godViewServiceOf, lib/src/core/god_view.dart).
create or replace function public.rider_live_map_vehicle_kind(p_service text, p_vehicle text default null)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when lower(coalesce(p_service, '') || ' ' || coalesce(p_vehicle, '')) ~ '(moto|bike|scooter|two.?wheel|\mkapcai\M)' then 'bike'
    when lower(coalesce(p_service, '') || ' ' || coalesce(p_vehicle, '')) ~ '(freight|lorry|truck|\mvan\M|cargo|tonne|courier)' then 'van'
    else 'car' end;
$$;

-- A first name only.
create or replace function public.rider_live_map_first_name(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(split_part(btrim(coalesce(p, '')), ' ', 1), '');
$$;

-- ---- 3. The rate limit ---------------------------------------------------------------------------
-- The last answer each rider had from each function; a call within the
-- update interval gets it again rather than a new one.
create table if not exists public.rider_live_map_calls (
  profile_id uuid not null,
  mode       text not null check (mode in ('cars', 'busy', 'people', 'team')),
  at         timestamptz not null default now(),
  result     jsonb not null default '{}'::jsonb,
  primary key (profile_id, mode)
);
alter table public.rider_live_map_calls enable row level security;
revoke all on public.rider_live_map_calls from public, anon, authenticated;

create or replace function public.rider_live_map_cached(p_mode text, p_every integer)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select c.result || jsonb_build_object('cached', true)
    from public.rider_live_map_calls c
   where c.profile_id = auth.uid() and c.mode = p_mode
     and c.at > now() - make_interval(secs => greatest(coalesce(p_every, 10), 1));
$$;
revoke execute on function public.rider_live_map_cached(text, integer) from public, anon, authenticated;

create or replace function public.rider_live_map_keep(p_mode text, p_result jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.rider_live_map_calls (profile_id, mode, at, result)
  values (auth.uid(), p_mode, now(), p_result)
  on conflict (profile_id, mode) do update set at = excluded.at, result = excluded.result;
  return p_result;
end;
$$;
revoke execute on function public.rider_live_map_keep(text, jsonb) from public, anon, authenticated;

-- The hour's secret for moving the cars: a new one every hour, never read
-- by anyone, so where a car is shown says nothing about where it is.
create table if not exists public.rider_live_map_salt (
  id   smallint primary key default 1 check (id = 1),
  salt text not null,
  at   timestamptz not null default now()
);
alter table public.rider_live_map_salt enable row level security;
revoke all on public.rider_live_map_salt from public, anon, authenticated;

create or replace function public.rider_live_map_hour_salt()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v text;
begin
  select salt into v from public.rider_live_map_salt where id = 1 and at > date_trunc('hour', now());
  if v is null then
    insert into public.rider_live_map_salt (id, salt, at)
    values (1, gen_random_uuid()::text || gen_random_uuid()::text, now())
    on conflict (id) do update set salt = excluded.salt, at = excluded.at
    returning salt into v;
  end if;
  return v;
end;
$$;
revoke execute on function public.rider_live_map_hour_salt() from public, anon, authenticated;

-- GET.Plus is not built yet: "GET.Plus" members are nobody until it is.
create or replace function public.rider_live_map_is_plus(p_uid uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v boolean;
begin
  if to_regprocedure('public.get_plus_active(uuid)') is null then
    return false;
  end if;
  execute 'select public.get_plus_active($1)' into v using p_uid;
  return coalesce(v, false);
end;
$$;
revoke execute on function public.rider_live_map_is_plus(uuid) from public, anon, authenticated;

-- ---- 4. Who may use what -------------------------------------------------------------------------
-- The caller's family and whether they host it (null: in none).
create or replace function public.rider_live_map_family(p_uid uuid, out family_id uuid, out host boolean, out place jsonb)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  f public.families;
begin
  select * into f from public.families where host_id = p_uid;
  if found then
    host := true;
  else
    select fam.* into f from public.families fam
      join public.family_members fm on fm.family_id = fam.id
     where fm.profile_id = p_uid and fm.status = 'active' and fm.kind = 'member'
     limit 1;
    if not found then
      return;
    end if;
    host := false;
  end if;
  family_id := f.id;
  place := jsonb_build_object('country', f.country, 'state', f.state, 'city', f.city, 'suburb', f.suburb);
end;
$$;
revoke execute on function public.rider_live_map_family(uuid) from public, anon, authenticated;

-- My people is on for this viewer: the rule at the family's region, and the
-- viewer the host (or a member, where the rule says all members).
create or replace function public.rider_live_map_people_allowed(p_uid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  fam record;
  cfg jsonb;
begin
  select * into fam from public.rider_live_map_family(p_uid);
  if fam.family_id is null then
    return null;
  end if;
  cfg := public.rider_live_map_settings_at(fam.place);
  if not coalesce((cfg->>'people_on')::boolean, false) or cfg->>'people_who' = 'nobody'
     or (cfg->>'people_who' = 'hosts' and not fam.host) then
    return null;
  end if;
  return cfg || jsonb_build_object('_family', fam.family_id, '_host', fam.host);
end;
$$;
revoke execute on function public.rider_live_map_people_allowed(uuid) from public, anon, authenticated;

-- Whether members of [p_family] see each other's shared trips on the map
-- (the rule at the family's region says all members): for the disclosure.
create or replace function public.rider_live_map_members_see(p_family uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select (s->>'people_on')::boolean and s->>'people_who' = 'members'
      from (select public.rider_live_map_settings_at(
                     jsonb_build_object('country', f.country, 'state', f.state, 'city', f.city, 'suburb', f.suburb)) s
              from public.families f where f.id = p_family) x), false);
$$;
revoke execute on function public.rider_live_map_members_see(uuid) from public, anon, authenticated;

-- The business accounts whose company trips the viewer may see, each with
-- the rule at the company's region.
create or replace function public.rider_live_map_team_accounts(p_uid uuid)
returns table (account_id uuid, account_name text, cfg jsonb)
language sql
stable
security definer
set search_path = public
as $$
  select a.id, a.name, x.cfg
    from public.business_members m
    join public.business_accounts a on a.id = m.account_id and a.status = 'active'
    cross join lateral (select public.rider_live_map_settings_at(
                          jsonb_build_object('country', a.country, 'state', a.state, 'city', a.city)) as cfg) x
   where m.profile_id = p_uid and m.status = 'active'
     and coalesce((x.cfg->>'team_on')::boolean, false)
     and (x.cfg->>'team_who' = 'staff' or (x.cfg->>'team_who' = 'admins' and m.role = 'admin'));
$$;
revoke execute on function public.rider_live_map_team_accounts(uuid) from public, anon, authenticated;

-- Which overlays the caller may use here ([p_place]: where they are), and
-- each one's update interval and look. The app shows the overlays button
-- only when one of busy, people or team is on.
create or replace function public.rider_live_map_config(p_place jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  cfg jsonb;
  ppl jsonb;
  v_busy boolean;
  v_team record;
begin
  if v_uid is null then
    return jsonb_build_object('cars', jsonb_build_object('on', false), 'busy', jsonb_build_object('on', false),
                              'people', jsonb_build_object('on', false), 'team', jsonb_build_object('on', false));
  end if;
  cfg := public.rider_live_map_settings_at(coalesce(p_place, '{}'::jsonb));
  v_busy := coalesce((cfg->>'busy_on')::boolean, false)
            and (cfg->>'busy_who' = 'all' or (cfg->>'busy_who' = 'plus' and public.rider_live_map_is_plus(v_uid)));
  ppl := public.rider_live_map_people_allowed(v_uid);
  select count(*) as n, min((t.cfg->>'team_every_s')::int) as every into v_team
    from public.rider_live_map_team_accounts(v_uid) t;
  return jsonb_build_object(
    'cars', jsonb_build_object('on', coalesce((cfg->>'cars_on')::boolean, false),
                               'mayHide', coalesce((cfg->>'cars_may_hide')::boolean, true),
                               'every', (cfg->>'cars_every_s')::int,
                               'fields', cfg->'cars_fields'),
    'busy', case when v_busy then jsonb_build_object('on', true, 'every', (cfg->>'busy_every_s')::int,
                                                     'fields', cfg->'busy_fields', 'colours', cfg->'busy_colours',
                                                     'opacity', (cfg->>'busy_opacity')::int,
                                                     'hexM', (cfg->>'busy_hex_m')::int)
                 else jsonb_build_object('on', false) end,
    'people', case when ppl is not null then jsonb_build_object('on', true, 'every', (ppl->>'people_every_s')::int,
                                                                'host', ppl->'_host', 'fields', ppl->'people_fields')
                   else jsonb_build_object('on', false) end,
    'team', case when v_team.n > 0 then jsonb_build_object('on', true, 'every', v_team.every)
                 else jsonb_build_object('on', false) end);
end;
$$;
revoke execute on function public.rider_live_map_config(jsonb) from public, anon;
grant execute on function public.rider_live_map_config(jsonb) to authenticated;

-- ---- 5. Cars near me -----------------------------------------------------------------------------
-- Free cars around [p_lat, p_lng]: online, heard from in the last 3 minutes,
-- not on a job; each moved for the hour; no name, plate, photo, rating or id.
create or replace function public.rider_live_map_cars(p_lat float8, p_lng float8, p_place jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  cfg jsonb;
  v_cached jsonb;
  v_fields text[];
  v_radius float8;
  v_offset float8;
  v_salt text;
  v_dlat float8;
  v_dlng float8;
  v_cars jsonb;
  v_count integer;
  v_near float8;
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'RLM_SIGN_IN' using errcode = '42501', hint = 'Sign in to see the map.';
  end if;
  if p_lat is null or p_lng is null or abs(p_lat) > 85 or abs(p_lng) > 180 then
    return jsonb_build_object('on', false);
  end if;
  cfg := public.rider_live_map_settings_at(coalesce(p_place, '{}'::jsonb));
  if not coalesce((cfg->>'cars_on')::boolean, false) then
    return jsonb_build_object('on', false);
  end if;
  v_cached := public.rider_live_map_cached('cars', (cfg->>'cars_every_s')::int);
  if v_cached is not null then
    return v_cached;
  end if;
  v_fields := public.rider_live_map_fields(cfg->'cars_fields');
  v_radius := coalesce((cfg->>'cars_radius_m')::float8, 3000);
  v_offset := coalesce((cfg->>'cars_offset_m')::float8, 150);
  v_salt := public.rider_live_map_hour_salt();
  v_dlat := v_radius / 111320.0;
  v_dlng := v_radius / (111320.0 * greatest(cos(radians(p_lat)), 0.05));
  with free as (
    select d.profile_id, d.lat, d.lng,
           public.rider_live_map_vehicle_kind(p.vehicle_type, p.partner_type) as kind,
           md5(v_salt || d.profile_id::text) as h
      from public.driver_presence d
      join public.partners p on p.auth_user_id = d.profile_id and p.status::text = 'approved'
     where d.online and d.updated_at > now() - interval '3 minutes'
       and d.lat between p_lat - v_dlat and p_lat + v_dlat
       and d.lng between p_lng - v_dlng and p_lng + v_dlng
       and d.profile_id <> v_uid
       and not exists (select 1 from public.ride_requests r
                        where r.partner_id = d.profile_id and r.status in ('accepted', 'arrived', 'on_trip'))
  ),
  near as (
    select f.*, public.rider_live_map_metres(p_lat, p_lng, f.lat, f.lng) as m
      from free f
     where f.kind = any (v_fields)
       and public.rider_live_map_metres(p_lat, p_lng, f.lat, f.lng) <= v_radius
  ),
  moved as (
    select n.kind, n.m, n.h, n.lat, n.lng,
           2 * pi() * (('x' || substr(n.h, 1, 4))::bit(16)::int / 65536.0) as angle,
           v_offset * (0.5 + 0.5 * (('x' || substr(n.h, 5, 4))::bit(16)::int / 65536.0)) as dist
      from near n
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'lat', round((mv.lat + mv.dist * cos(mv.angle) / 111320.0)::numeric, 5),
           'lng', round((mv.lng + mv.dist * sin(mv.angle) / (111320.0 * greatest(cos(radians(mv.lat)), 0.05)))::numeric, 5),
           'kind', mv.kind,
           'heading', (('x' || substr(mv.h, 9, 4))::bit(16)::int % 360)) order by mv.h) filter (where mv.rn <= 40), '[]'::jsonb),
         count(*)::int, min(mv.m)
    into v_cars, v_count, v_near
    from (select m2.*, row_number() over (order by m2.m) as rn from moved m2) mv;
  v_out := jsonb_build_object('on', true, 'cars', v_cars, 'every', (cfg->>'cars_every_s')::int, 'at', now());
  if 'count' = any (v_fields) then
    v_out := v_out || jsonb_build_object('count', v_count);
  end if;
  -- About 25 km/h through town, at least a minute: never a precise distance.
  if 'pickup_time' = any (v_fields) and v_near is not null then
    v_out := v_out || jsonb_build_object('pickupMin', greatest(1, ceil(v_near / 416.0)::int));
  end if;
  return public.rider_live_map_keep('cars', v_out);
end;
$$;
revoke execute on function public.rider_live_map_cars(float8, float8, jsonb) from public, anon;
grant execute on function public.rider_live_map_cars(float8, float8, jsonb) to authenticated;

-- ---- 6. Busy areas -------------------------------------------------------------------------------
-- The honeycomb over the box: each cell with at least the minimum of open
-- and recent requests, its level 0-4 and the fields the rule shows. No
-- counts, no trip ids.
create or replace function public.rider_live_map_busy(p_south float8, p_west float8, p_north float8, p_east float8,
                                                      p_place jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  cfg jsonb;
  v_cached jsonb;
  v_fields text[];
  v_hex float8;
  v_min integer;
  v_window interval;
  v_half interval;
  v_lat_c float8;
  v_lng_c float8;
  v_span float8;
  v_ref float8;
  v_pad float8;
  v_s float8; v_w float8; v_n float8; v_e float8;
  v_cells jsonb;
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'RLM_SIGN_IN' using errcode = '42501', hint = 'Sign in to see the map.';
  end if;
  if p_south is null or p_north is null or p_west is null or p_east is null
     or p_south >= p_north or p_west >= p_east or abs(p_south) > 85 or abs(p_north) > 85 then
    return jsonb_build_object('on', false);
  end if;
  cfg := public.rider_live_map_settings_at(coalesce(p_place, '{}'::jsonb));
  if not coalesce((cfg->>'busy_on')::boolean, false)
     or not (cfg->>'busy_who' = 'all' or (cfg->>'busy_who' = 'plus' and public.rider_live_map_is_plus(v_uid))) then
    return jsonb_build_object('on', false);
  end if;
  v_cached := public.rider_live_map_cached('busy', (cfg->>'busy_every_s')::int);
  if v_cached is not null then
    return v_cached;
  end if;
  v_fields := public.rider_live_map_fields(cfg->'busy_fields');
  v_hex := (cfg->>'busy_hex_m')::float8;
  v_min := (cfg->>'busy_min')::int;
  v_window := make_interval(mins => (cfg->>'busy_window_min')::int);
  v_half := v_window / 2;
  -- At most about 30 km across, around the box's middle.
  v_lat_c := (p_south + p_north) / 2;
  v_lng_c := (p_west + p_east) / 2;
  v_span := 0.14;
  v_s := greatest(p_south, v_lat_c - v_span);
  v_n := least(p_north, v_lat_c + v_span);
  v_w := greatest(p_west, v_lng_c - v_span / greatest(cos(radians(v_lat_c)), 0.05));
  v_e := least(p_east, v_lng_c + v_span / greatest(cos(radians(v_lat_c)), 0.05));
  v_ref := round(v_lat_c);
  -- Two rings of cells past the edge, for the quieter tip.
  v_pad := 3 * v_hex / 111320.0;
  with req as (
    select h.q, h.r, x.created_at, x.accepted_at, x.arrived_at,
           coalesce(nullif(btrim(x.suburb), ''), nullif(btrim(x.city), '')) as area
      from public.ride_requests x
      cross join lateral public.rider_live_map_hex_of(x.pickup_lat, x.pickup_lng, v_hex, v_ref) h
     where x.pickup_lat between v_s - v_pad and v_n + v_pad
       and x.pickup_lng between v_w - v_pad and v_e + v_pad
       and x.created_at > now() - interval '12 hours'
       and (x.status = 'open' or x.created_at > now() - v_window)
  ),
  agg as (
    select q, r, count(*)::int as n,
           count(*) filter (where created_at > now() - v_half)::int as n_late,
           count(*) filter (where created_at <= now() - v_half and created_at > now() - v_window)::int as n_early,
           avg(extract(epoch from arrived_at - accepted_at) / 60)
             filter (where accepted_at is not null and arrived_at > accepted_at
                       and arrived_at - accepted_at < interval '2 hours') as wait,
           mode() within group (order by area) as area
      from req group by q, r
  ),
  fares as (
    select h.q, h.r, avg(f.duration_min / f.standard_duration_min) as fx
      from public.fare_ai_responses f
      cross join lateral public.rider_live_map_hex_of(f.origin_lat, f.origin_lng, v_hex, v_ref) h
     where f.created_at > now() - v_window and f.success
       and f.standard_duration_min > 0 and f.duration_min > 0
       and f.origin_lat between v_s - v_pad and v_n + v_pad
       and f.origin_lng between v_w - v_pad and v_e + v_pad
     group by h.q, h.r
  ),
  shown as (
    select a.*, public.rider_live_map_level(a.n, v_min) as level, c.lat, c.lng,
           (select round(least(3, greatest(1, fr.fx))::numeric, 1) from fares fr where fr.q = a.q and fr.r = a.r) as fare
      from agg a
      cross join lateral public.rider_live_map_hex_centre(a.q, a.r, v_hex, v_ref) c
     where a.n >= v_min
       and c.lat between v_s and v_n and c.lng between v_w and v_e
  ),
  -- The ring-1 and ring-2 neighbours, nearest first.
  ring (dq, dr, k) as (
    values (1, 0, 1), (1, -1, 1), (0, -1, 1), (-1, 0, 1), (-1, 1, 1), (0, 1, 1),
           (2, 0, 2), (2, -1, 2), (2, -2, 2), (1, -2, 2), (0, -2, 2), (-1, -1, 2),
           (-2, 0, 2), (-2, 1, 2), (-2, 2, 2), (-1, 2, 2), (0, 2, 2), (1, 1, 2)
  ),
  tips as (
    select distinct on (s.q, s.r) s.q, s.r, nb.k, nc.lat as tlat, nc.lng as tlng,
           (select round(least(3, greatest(1, fr.fx))::numeric, 1) from fares fr
             where fr.q = s.q + nb.dq and fr.r = s.r + nb.dr) as tfare
      from shown s
      cross join ring nb
      left join agg o on o.q = s.q + nb.dq and o.r = s.r + nb.dr
      cross join lateral public.rider_live_map_hex_centre(s.q + nb.dq, s.r + nb.dr, v_hex, v_ref) nc
     where s.level >= 2
       and coalesce(public.rider_live_map_level(o.n, v_min), -1) <= s.level - 2
     order by s.q, s.r, nb.k, nb.dq, nb.dr
  )
  select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'q', s.q, 'r', s.r,
           'lat', round(s.lat::numeric, 6), 'lng', round(s.lng::numeric, 6),
           'level', s.level,
           'area', s.area,
           'fare', case when 'fare' = any (v_fields) then s.fare end,
           'wait', case when 'wait' = any (v_fields) and s.wait is not null then greatest(1, round(s.wait)::int) end,
           'next', case when 'next_hour' = any (v_fields) and s.n_late + s.n_early >= v_min then
                     case when s.n_late > 1.2 * s.n_early then 'up' when s.n_late < 0.8 * s.n_early then 'down' else 'flat' end
                   end,
           'tip', case when 'tip' = any (v_fields) and t.q is not null then jsonb_build_object(
                    'm', (round(public.rider_live_map_metres(s.lat, s.lng, t.tlat, t.tlng) / 100) * 100)::int,
                    'dir', public.rider_live_map_direction((t.tlng - s.lng) * cos(radians(s.lat)), t.tlat - s.lat),
                    'fare', case when 'fare' = any (v_fields) then t.tfare end) end
         )) order by s.q, s.r), '[]'::jsonb)
    into v_cells
    from shown s
    left join tips t on t.q = s.q and t.r = s.r;
  -- Without the level field the cells still show, all one colour.
  if not ('level' = any (v_fields)) then
    select coalesce(jsonb_agg(c - 'level' || jsonb_build_object('level', 2)), '[]'::jsonb) into v_cells
      from jsonb_array_elements(v_cells) c;
  end if;
  v_out := jsonb_build_object('on', true, 'cells', v_cells, 'hexM', v_hex, 'latRef', v_ref,
                              'colours', cfg->'busy_colours', 'opacity', (cfg->>'busy_opacity')::int,
                              'fields', to_jsonb(v_fields), 'every', (cfg->>'busy_every_s')::int, 'at', now());
  return public.rider_live_map_keep('busy', v_out);
end;
$$;
revoke execute on function public.rider_live_map_busy(float8, float8, float8, float8, jsonb) from public, anon;
grant execute on function public.rider_live_map_busy(float8, float8, float8, float8, jsonb) to authenticated;

-- ---- 7. My people --------------------------------------------------------------------------------
-- Where each trip's car has been, kept only while the rule keeps a history.
create table if not exists public.rider_live_map_trail (
  id      bigint generated always as identity primary key,
  trip_id uuid not null,
  lat     float8 not null,
  lng     float8 not null,
  at      timestamptz not null default now()
);
create index if not exists rider_live_map_trail_trip_idx on public.rider_live_map_trail (trip_id, at);
alter table public.rider_live_map_trail enable row level security;
revoke all on public.rider_live_map_trail from public, anon, authenticated;

-- One person for the map, from their trip [r] (a ride) and the fields shown.
create or replace function public.rider_live_map_trip_item(r public.ride_requests, p_fields text[], p_history integer,
                                                           p_dropped boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v jsonb := '{}'::jsonb;
  v_eta integer;
  v_left integer;
  v_trail jsonb;
  v_lat float8 := case when p_dropped then r.drop_lat else r.partner_live_lat end;
  v_lng float8 := case when p_dropped then r.drop_lng else r.partner_live_lng end;
begin
  if 'status' = any (p_fields) then
    v := v || jsonb_build_object('status', case when p_dropped then 'dropped'
                                                when r.status = 'on_trip' then 'on_trip'
                                                when r.status in ('accepted', 'arrived') then 'pickup'
                                                else 'waiting' end,
                                 'from', r.pickup_name, 'to', r.drop_name,
                                 'kind', public.rider_live_map_vehicle_kind(r.service, r.partner_vehicle));
  end if;
  if r.status = 'on_trip' and r.started_at is not null and r.duration_min is not null and not p_dropped then
    v_left := greatest(0, r.duration_min - (extract(epoch from now() - r.started_at) / 60)::int);
    if 'eta' = any (p_fields) then
      v := v || jsonb_build_object('eta', v_left,
                                   'progress', round(least(1, greatest(0, 1 - v_left::numeric / greatest(r.duration_min, 1))), 2));
    end if;
    if 'dropoff' = any (p_fields) then
      v := v || jsonb_build_object('dropoffAt', r.started_at + make_interval(mins => r.duration_min));
    end if;
  elsif r.status in ('accepted', 'arrived') and 'eta' = any (p_fields) and not p_dropped then
    select o.eta_min into v_eta from public.ride_offers o
     where o.request_id = r.id and o.status = 'accepted' order by o.created_at desc limit 1;
    if v_eta is not null then
      v := v || jsonb_build_object('eta', v_eta, 'etaTo', 'pickup');
    end if;
  end if;
  if p_dropped and 'dropoff' = any (p_fields) then
    v := v || jsonb_build_object('dropoffAt', r.completed_at);
  end if;
  if 'driver' = any (p_fields) and not p_dropped and r.status in ('accepted', 'arrived', 'on_trip') then
    -- The car, never the plate.
    v := v || jsonb_strip_nulls(jsonb_build_object('driver', public.rider_live_map_first_name(r.partner_name),
                                                   'car', nullif(btrim(r.partner_vehicle), '')));
  end if;
  if 'spot' = any (p_fields) and v_lat is not null and v_lng is not null then
    v := v || jsonb_build_object('lat', round(v_lat::numeric, 6), 'lng', round(v_lng::numeric, 6),
                                 'at', case when p_dropped then r.completed_at else r.partner_live_at end);
    if p_history > 0 and not p_dropped then
      if not exists (select 1 from public.rider_live_map_trail t
                      where t.trip_id = r.id and t.at > now() - interval '15 seconds') then
        insert into public.rider_live_map_trail (trip_id, lat, lng) values (r.id, v_lat, v_lng);
      end if;
      delete from public.rider_live_map_trail t where t.trip_id = r.id and t.at < now() - make_interval(mins => p_history);
      select jsonb_agg(jsonb_build_array(round(t.lat::numeric, 6), round(t.lng::numeric, 6)) order by t.at) into v_trail
        from public.rider_live_map_trail t where t.trip_id = r.id;
      if v_trail is not null then
        v := v || jsonb_build_object('trail', v_trail);
      end if;
    end if;
  end if;
  return v;
end;
$$;
revoke execute on function public.rider_live_map_trip_item(public.ride_requests, text[], integer, boolean)
  from public, anon, authenticated;

-- The family members the caller may see now, through Family's disclosed
-- ways only: the host sees what family_can_view_location allows (a shared
-- trip under way, or the phone's last place under "always") and their
-- children's trips; where the rule says all members, a member sees the
-- others' shared trips under way (and nothing else). The minutes after a
-- trip: its drop-off and time, while the member still shares trips.
create or replace function public.rider_live_map_people(p_place jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  cfg jsonb;
  v_cached jsonb;
  v_family uuid;
  v_host boolean;
  v_fields text[];
  v_history integer;
  v_after integer;
  m public.family_members;
  r public.ride_requests;
  v_trip uuid;
  v_rule text;
  v_item jsonb;
  v_items jsonb := '[]'::jsonb;
  v_out jsonb;
  pt record;
begin
  if v_uid is null then
    raise exception 'RLM_SIGN_IN' using errcode = '42501', hint = 'Sign in to see the map.';
  end if;
  cfg := public.rider_live_map_people_allowed(v_uid);
  if cfg is null then
    return jsonb_build_object('on', false);
  end if;
  v_cached := public.rider_live_map_cached('people', (cfg->>'people_every_s')::int);
  if v_cached is not null then
    return v_cached;
  end if;
  v_family := (cfg->>'_family')::uuid;
  v_host := (cfg->>'_host')::boolean;
  v_fields := public.rider_live_map_fields(cfg->'people_fields');
  v_history := (cfg->>'people_history_min')::int;
  v_after := (cfg->>'people_after_min')::int;
  for m in select * from public.family_members
            where family_id = v_family and status = 'active' and profile_id is distinct from v_uid
            order by created_at loop
    if m.kind = 'child' and not v_host then
      continue;
    end if;
    v_trip := null;
    v_item := null;
    v_rule := case when m.kind = 'member' then public.family_location_rule(m.id) else 'ride' end;
    if m.kind = 'member' then
      -- The host: Family's own test. A member: a shared trip under way, by the same rule.
      if (v_host and public.family_can_view_location(v_uid, m.profile_id))
         or (not v_host and v_rule in ('ride', 'always')) then
        v_trip := public.family_shared_trip(m.id);
      end if;
    else
      select t.trip_id into v_trip from public.family_trips t
       where t.member_id = m.id and t.ended_at is null and public.family_trip_live(t.trip_id)
       order by t.created_at desc limit 1;
    end if;
    if v_trip is not null then
      select * into r from public.ride_requests where id = v_trip;
      if found then
        v_item := public.rider_live_map_trip_item(r, v_fields, v_history, false);
      else
        -- City to City: the trip, no live spot.
        select jsonb_build_object('status', case when b.status = 'on_trip' then 'on_trip' else 'pickup' end,
                                  'from', b.pickup_name, 'to', b.drop_name, 'kind', 'car')
          into v_item from public.c2c_bookings b where b.id = v_trip and 'status' = any (v_fields);
      end if;
    elsif v_host and m.kind = 'member' and v_rule = 'always' and 'spot' = any (v_fields) then
      -- "Always", which the member turned on: the phone's last place.
      select t.last_lat, t.last_lng, t.located_at, concat_ws(', ', nullif(t.area_suburb, ''), nullif(t.area_city, '')) as area
        into pt from public.push_tokens t
       where t.profile_id = m.profile_id and t.located_at is not null and t.last_lat is not null
       order by t.located_at desc limit 1;
      if pt.located_at is not null then
        v_item := jsonb_build_object('status', 'here', 'area', nullif(pt.area, ''),
                                     'lat', round(pt.last_lat::numeric, 6), 'lng', round(pt.last_lng::numeric, 6),
                                     'at', pt.located_at);
      end if;
    end if;
    -- The minutes after a shared trip: where and when it ended.
    if v_item is null and v_after > 0 and (v_rule in ('ride', 'always')) then
      select x.* into r
        from public.family_trips t
        join public.ride_requests x on x.id = t.trip_id
       where t.member_id = m.id and (t.live_share or m.kind = 'child')
         and x.status = 'completed' and x.completed_at > now() - make_interval(mins => v_after)
       order by x.completed_at desc limit 1;
      if found then
        v_item := public.rider_live_map_trip_item(r, v_fields, 0, true);
      end if;
    end if;
    if v_item is not null then
      v_items := v_items || jsonb_build_array(jsonb_build_object('id', m.id, 'name', m.name, 'kind', m.kind) || v_item);
    end if;
  end loop;
  -- Trails of trips no longer shown are not kept.
  delete from public.rider_live_map_trail t
   where t.at < now() - make_interval(mins => greatest(v_history, 0))
      or t.at < now() - interval '2 hours';
  v_out := jsonb_build_object('on', true, 'host', v_host, 'people', v_items,
                              'every', (cfg->>'people_every_s')::int, 'at', now());
  return public.rider_live_map_keep('people', v_out);
end;
$$;
revoke execute on function public.rider_live_map_people(jsonb) from public, anon;
grant execute on function public.rider_live_map_people(jsonb) to authenticated;

-- The member stops sharing this trip at once (the host and, where the rule
-- says so, the other members stop seeing it on the map and in Family).
create or replace function public.rider_live_map_stop_sharing(p_trip uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member uuid;
begin
  select t.member_id into v_member
    from public.family_trips t
    join public.family_members m on m.id = t.member_id
   where t.trip_id = p_trip and m.profile_id = auth.uid() and m.kind = 'member';
  if v_member is null then
    raise exception 'RLM_NOT_YOURS' using errcode = '42501', hint = 'Only the person on the trip can stop sharing it.';
  end if;
  update public.family_trips set live_share = false where trip_id = p_trip;
  delete from public.rider_live_map_trail where trip_id = p_trip;
  return true;
end;
$$;
revoke execute on function public.rider_live_map_stop_sharing(uuid) from public, anon;
grant execute on function public.rider_live_map_stop_sharing(uuid) to authenticated;

-- As 0317, plus "Your family members" among who can see a shared trip while
-- the live map's rule lets members see each other, and 'mine' (the member's
-- own trip, which they may stop sharing).
create or replace function public.family_trip_status(p_trip uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t public.family_trips;
  m public.family_members;
  v_uid uuid := auth.uid();
  v_host text;
  v_shared boolean;
  v_viewers jsonb := '[]'::jsonb;
begin
  select * into t from public.family_trips where trip_id = p_trip;
  if not found or v_uid is null then
    return jsonb_build_object('family', false);
  end if;
  select * into m from public.family_members where id = t.member_id;
  if v_uid is distinct from m.profile_id and v_uid is distinct from t.payer_id and v_uid is distinct from t.booked_by then
    return jsonb_build_object('family', false);
  end if;
  select coalesce(nullif(btrim(p.name), ''), 'Your family host') into v_host
    from public.profiles p join public.families f on f.host_id = p.id where f.id = t.family_id;
  v_shared := m.kind = 'member' and public.family_can_view_location(t.payer_id, m.profile_id)
              and public.family_shared_trip(m.id) = p_trip;
  if coalesce(v_shared, false) then
    v_viewers := jsonb_build_array(jsonb_build_object('name', v_host, 'role', 'host',
                                                      'what', 'Live location until drop-off'));
    if public.rider_live_map_members_see(t.family_id) then
      v_viewers := v_viewers || jsonb_build_array(jsonb_build_object(
        'name', 'Your family members', 'role', 'members', 'what', 'Live location on their map until drop-off'));
    end if;
  end if;
  return jsonb_build_object(
    'family', true, 'child', t.child, 'familyPays', t.family_pays and t.released_at is null,
    'payer', v_host, 'shared', coalesce(v_shared, false),
    -- The member's own trip: they may stop sharing it (rider_live_map_stop_sharing).
    'mine', v_uid = m.profile_id,
    'left', case when t.family_pays then public.family_month_left(m.id) end,
    'viewers', v_viewers);
end;
$$;
revoke execute on function public.family_trip_status(uuid) from public, anon;
grant execute on function public.family_trip_status(uuid) to authenticated;

-- ---- 8. Team -------------------------------------------------------------------------------------
-- Who looked at which company trip, kept the rule's days: the member sees it.
create table if not exists public.rider_live_map_team_log (
  id         uuid primary key default gen_random_uuid(),
  account_id uuid not null,
  ride_id    uuid not null,
  viewer_id  uuid not null,
  at         timestamptz not null default now()
);
create index if not exists rider_live_map_team_log_ride_idx on public.rider_live_map_team_log (ride_id, at desc);
create index if not exists rider_live_map_team_log_account_idx on public.rider_live_map_team_log (account_id, at);
alter table public.rider_live_map_team_log enable row level security;
revoke all on public.rider_live_map_team_log from public, anon, authenticated;
drop policy if exists "rider_live_map_team_log admin read" on public.rider_live_map_team_log;
create policy "rider_live_map_team_log admin read" on public.rider_live_map_team_log
  for select to authenticated using ((select public.caller_is_admin()));
grant select on public.rider_live_map_team_log to authenticated;

-- The company-paid trips the caller may see: their companies' trips under
-- way (and the rule's minutes after), never a personal trip.
create or replace function public.rider_live_map_team(p_place jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_cached jsonb;
  v_every integer;
  a record;
  r public.ride_requests;
  v_fields text[];
  v_item jsonb;
  v_items jsonb := '[]'::jsonb;
  v_left integer;
  v_name text;
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'RLM_SIGN_IN' using errcode = '42501', hint = 'Sign in to see the map.';
  end if;
  select min((t.cfg->>'team_every_s')::int) into v_every from public.rider_live_map_team_accounts(v_uid) t;
  if v_every is null then
    return jsonb_build_object('on', false);
  end if;
  v_cached := public.rider_live_map_cached('team', v_every);
  if v_cached is not null then
    return v_cached;
  end if;
  for a in select * from public.rider_live_map_team_accounts(v_uid) loop
    v_fields := public.rider_live_map_fields(a.cfg->'team_fields');
    for r in
      select x.* from public.ride_requests x
       where x.business_account_id = a.account_id
         and x.rider_id is distinct from v_uid
         and (x.status in ('accepted', 'arrived', 'on_trip')
              or (x.status = 'completed'
                  and x.completed_at > now() - make_interval(mins => coalesce((a.cfg->>'team_after_min')::int, 0))))
         and x.updated_at > now() - interval '12 hours'
       order by x.created_at
       limit 100
    loop
      select coalesce(nullif(btrim(bm.name), ''), nullif(btrim(p.name), ''), 'Staff') into v_name
        from public.profiles p
        left join public.business_members bm on bm.account_id = a.account_id and bm.profile_id = p.id and bm.status <> 'removed'
       where p.id = r.rider_id;
      v_item := jsonb_build_object('id', r.id, 'name', public.rider_live_map_first_name(coalesce(v_name, 'Staff')),
                                   'company', a.account_name,
                                   'status', case when r.status = 'completed' then 'dropped'
                                                  when r.status = 'on_trip' then 'on_trip' else 'pickup' end,
                                   'from', r.pickup_name, 'to', r.drop_name,
                                   'kind', public.rider_live_map_vehicle_kind(r.service, r.partner_vehicle));
      if 'purpose' = any (v_fields) and nullif(btrim(r.business_note), '') is not null then
        v_item := v_item || jsonb_build_object('purpose', btrim(r.business_note));
      end if;
      if 'eta' = any (v_fields) and r.status = 'on_trip' and r.started_at is not null and r.duration_min is not null then
        v_left := greatest(0, r.duration_min - (extract(epoch from now() - r.started_at) / 60)::int);
        v_item := v_item || jsonb_build_object('eta', v_left,
          'progress', round(least(1, greatest(0, 1 - v_left::numeric / greatest(r.duration_min, 1))), 2));
      end if;
      if 'cost' = any (v_fields) then
        v_item := v_item || jsonb_build_object('cost', public.ride_amount_due(r), 'currency', r.currency);
      end if;
      if 'spot' = any (v_fields) then
        if r.status = 'completed' and r.drop_lat is not null then
          v_item := v_item || jsonb_build_object('lat', round(r.drop_lat::numeric, 6), 'lng', round(r.drop_lng::numeric, 6),
                                                 'at', r.completed_at);
        elsif r.partner_live_lat is not null then
          v_item := v_item || jsonb_build_object('lat', round(r.partner_live_lat::numeric, 6),
                                                 'lng', round(r.partner_live_lng::numeric, 6), 'at', r.partner_live_at);
        end if;
      end if;
      v_items := v_items || jsonb_build_array(v_item);
      -- The log: one line per viewer and trip every 10 minutes.
      if not exists (select 1 from public.rider_live_map_team_log l
                      where l.ride_id = r.id and l.viewer_id = v_uid and l.at > now() - interval '10 minutes') then
        insert into public.rider_live_map_team_log (account_id, ride_id, viewer_id) values (a.account_id, r.id, v_uid);
      end if;
    end loop;
    delete from public.rider_live_map_team_log l
     where l.account_id = a.account_id
       and l.at < now() - make_interval(days => coalesce((a.cfg->>'team_log_days')::int, 30));
  end loop;
  v_out := jsonb_build_object('on', true, 'trips', v_items, 'every', v_every, 'at', now());
  return public.rider_live_map_keep('team', v_out);
end;
$$;
revoke execute on function public.rider_live_map_team(jsonb) from public, anon;
grant execute on function public.rider_live_map_team(jsonb) to authenticated;

-- The member's own company trip: whether it shows on the company's map,
-- who can see it, and who looked lately. {} for any other trip.
create or replace function public.rider_live_map_trip_note(p_trip uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  a public.business_accounts;
  cfg jsonb;
  v_seen jsonb;
begin
  select * into r from public.ride_requests where id = p_trip;
  if not found or r.rider_id is distinct from auth.uid() or r.business_account_id is null then
    return '{}'::jsonb;
  end if;
  select * into a from public.business_accounts where id = r.business_account_id;
  cfg := public.rider_live_map_settings_at(jsonb_build_object('country', a.country, 'state', a.state, 'city', a.city));
  if not coalesce((cfg->>'team_on')::boolean, false) or cfg->>'team_who' = 'nobody' then
    return jsonb_build_object('company', true, 'name', a.name, 'shown', false);
  end if;
  select jsonb_agg(jsonb_build_object('name', public.rider_live_map_first_name(coalesce(p.name, 'Someone')), 'at', x.at)
                   order by x.at desc)
    into v_seen
    from (select l.viewer_id, max(l.at) as at from public.rider_live_map_team_log l
           where l.ride_id = r.id group by l.viewer_id order by max(l.at) desc limit 5) x
    left join public.profiles p on p.id = x.viewer_id;
  return jsonb_build_object('company', true, 'name', a.name, 'shown', true, 'who', cfg->>'team_who',
                            'seenBy', coalesce(v_seen, '[]'::jsonb));
end;
$$;
revoke execute on function public.rider_live_map_trip_note(uuid) from public, anon;
grant execute on function public.rider_live_map_trip_note(uuid) to authenticated;

-- ---- 9. Live admin page --------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public'
                        and tablename = 'rider_live_map_rules') then
    alter publication supabase_realtime add table public.rider_live_map_rules;
  end if;
end $$;

notify pgrst, 'reload schema';
