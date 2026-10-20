-- ============================================================================
-- 0249 — Airport doors, pickup guides, charges and the waiting queue
--
-- Admin → Settings → Airport Areas becomes one editor per airport with five
-- tabs: Area, Gates & doors, Pickup rules, Waiting queue and Charges.
--
-- 1. Doors are the airport's gates in public.multi_gate (kind 'gate',
--    values.placeId = the airport, values.parentKey = 'airport-areas'): one
--    store, edited from Airport Areas and from the Multi-Gate page alike, and
--    followed live by both. A door's use is values.mode ('drop' | 'pickup' |
--    'both'); a pickup door carries its how-to guide in values.guide
--    ([{photo, text}], in order; photos in the private 'airport-guides'
--    bucket). public.airport_doors reads them as {kind: drop | pick | both}.
-- 2. public.airport_settings: per airport, whether the rider must pick a
--    drop-off / pickup door, the optional drop-off and pickup charges, the
--    pickup rules, the waiting-queue settings and the airport fares (fares
--    jsonb, plus public.airport_fare_zones for fixed zone fares).
-- 2b. Airport fares are worked out by the server (airport_quote) and stamped
--    on the ride with their breakdown (ride_requests.airport_fare): a fixed
--    zone fare when the other end is in a zone, else the distance band, else
--    the normal fare the app sent (less 0248's option charges); + the
--    service's airport base; raised to the pickup / drop-off minimum; + the
--    option charges (pets, assistance: they stay part of the fare, as 0248
--    has them); + the airport charge (its own step, ride_requests.charges);
--    rounded up to a whole amount when the airport says so.
--    airport_fare_quote gives the app the same breakdown.
-- 3. public.airport_waiting_zones: one or more drawn waiting zones.
-- 4. ride_requests gains the airport of its pickup and of its drop-off (the
--    server's), the doors the rider chose (the rider's only; checked and
--    named by the server), and airport_hold / airport_open_at for pickups
--    held for the airport's queue or zone drivers.
-- 5. A ride completed with its drop-off inside an airport records a drop-off
--    (public.airport_dropoffs). Its driver joins the airport's queue
--    (public.airport_queue, per service) by being reported inside a waiting
--    zone (set_driver_presence) within the join window; one drop-off gives
--    one place; the earliest drop-off goes first. Leaving the zones for
--    longer than the grace minutes loses the place.
-- 6. A pickup inside an airport that restricts pickups is held: only the
--    drivers it is offered to (public.airport_ride_offers) see it or take it
--    — the queue in order, one at a time, then (or instead) every driver in
--    a waiting zone, nearest first. A declined or missed queue offer sends
--    the driver to the back, unless the admin switched that off. With nobody
--    to offer it to: wait, decline (the request expires, cancel_reason
--    AIRPORT_NO_DRIVER) or, after N minutes, normal nearby dispatch.
--    Enforced here: a restrictive read policy, a claim check and the push.
-- 7. Queue lines are the vehicle's approved service (vehicle.service_id, from
--    its make & model when that maps one, else the driver's choice;
--    vehicle.service_approved_id, the admin's). public.vehicle_service_order
--    ranks the services lowest to highest: a driver whose vehicle is a higher
--    service may take a lower one's pickup, never the reverse. A pickup is
--    offered to its own service's line first, then each higher line in rank
--    order (airport_queue_lineup), and zone pickups follow the same rule. A
--    vehicle without an approved service can't join a queue.
-- 8. Scheduled rides pick their doors too: kept in the booking, checked when
--    scheduled and again when released.
-- ============================================================================

-- ---- 1. Settings, zones -----------------------------------------------------------------------------
create table if not exists public.airport_settings (
  airport_id          uuid primary key references public.airport_areas(id) on delete cascade,
  drop_door_required  boolean not null default true,
  pick_door_required  boolean not null default true,
  restrict_pickups    boolean not null default false,
  pickup_from         text[]  not null default '{queue}',
  empty_action        text    not null default 'wait',
  nearby_after_min    integer not null default 5,
  queue_by_service    boolean not null default true,
  need_dropoff        boolean not null default true,
  join_window_min     integer not null default 60,
  leave_grace_min     integer not null default 3,
  back_on_decline     boolean not null default true,
  offer_seconds       integer not null default 30,
  drop_fee_on         boolean not null default false,
  drop_fee_name       text    not null default 'Airport fee',
  drop_fee_amount     numeric(10, 2) not null default 0,
  pick_fee_on         boolean not null default false,
  pick_fee_name       text    not null default 'Airport fee',
  pick_fee_amount     numeric(10, 2) not null default 0,
  -- Airport fares (the Fares tab): {base: {<service, lower case>: amount},
  -- minPick / minDrop: {on, amount}, band: {on, tiers: [{uptoKm, flat}],
  -- extra: 'extra' | 'all', applies: 'both' | 'pick' | 'drop'}, roundUp}.
  -- Zone fares are rows of airport_fare_zones. Kept apart from the charges.
  fares               jsonb   not null default '{"roundUp": true}'::jsonb,
  updated_at          timestamptz not null default now(),
  constraint airport_settings_pickup_from check (
    cardinality(pickup_from) between 1 and 2 and pickup_from <@ array['queue', 'zone']),
  constraint airport_settings_empty_action check (empty_action in ('wait', 'decline', 'nearby')),
  constraint airport_settings_nearby check (nearby_after_min between 0 and 120),
  constraint airport_settings_window check (join_window_min between 1 and 720),
  constraint airport_settings_grace check (leave_grace_min between 0 and 60),
  constraint airport_settings_offer check (offer_seconds between 10 and 300),
  constraint airport_settings_fees check (
    drop_fee_amount between 0 and 1000 and pick_fee_amount between 0 and 1000
    and length(drop_fee_name) between 1 and 60 and length(pick_fee_name) between 1 and 60),
  constraint airport_settings_fares check (jsonb_typeof(fares) = 'object' and pg_column_size(fares) <= 65536)
);
comment on table public.airport_settings is
  'Per airport (airport_areas): door switches, charges, pickup rules and waiting-queue settings (0249).';

create table if not exists public.airport_waiting_zones (
  id         uuid primary key default gen_random_uuid(),
  airport_id uuid not null references public.airport_areas(id) on delete cascade,
  name       text not null default 'Waiting zone',
  -- A BoundaryShape: {coords:[{latitude,longitude}], polygons?, bbox}.
  shape      jsonb not null,
  position   integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint airport_waiting_zones_name check (length(name) between 1 and 80),
  constraint airport_waiting_zones_shape check (jsonb_typeof(shape) = 'object' and pg_column_size(shape) <= 65536)
);
create index if not exists airport_waiting_zones_airport_idx on public.airport_waiting_zones (airport_id, position);

create table if not exists public.airport_fare_zones (
  id          uuid primary key default gen_random_uuid(),
  airport_id  uuid not null references public.airport_areas(id) on delete cascade,
  name        text not null default 'Zone',
  shape       jsonb not null,
  to_amount   numeric(10, 2) not null default 0,
  from_amount numeric(10, 2) not null default 0,
  position    integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint airport_fare_zones_name check (length(name) between 1 and 80),
  constraint airport_fare_zones_shape check (jsonb_typeof(shape) = 'object' and pg_column_size(shape) <= 65536),
  constraint airport_fare_zones_amounts check (to_amount between 0 and 100000 and from_amount between 0 and 100000)
);
create index if not exists airport_fare_zones_airport_idx on public.airport_fare_zones (airport_id, position);

drop trigger if exists trg_airport_settings_updated_at on public.airport_settings;
create trigger trg_airport_settings_updated_at before update on public.airport_settings
  for each row execute function public.set_updated_at();
drop trigger if exists trg_airport_waiting_zones_updated_at on public.airport_waiting_zones;
create trigger trg_airport_waiting_zones_updated_at before update on public.airport_waiting_zones
  for each row execute function public.set_updated_at();
drop trigger if exists trg_airport_fare_zones_updated_at on public.airport_fare_zones;
create trigger trg_airport_fare_zones_updated_at before update on public.airport_fare_zones
  for each row execute function public.set_updated_at();

-- Every airport has its settings row, with the defaults.
create or replace function public.airport_areas_settings_row()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.airport_settings (airport_id) values (new.id) on conflict do nothing;
  return new;
end;
$$;
revoke execute on function public.airport_areas_settings_row() from public, anon, authenticated;
drop trigger if exists trg_airport_areas_settings on public.airport_areas;
create trigger trg_airport_areas_settings after insert on public.airport_areas
  for each row execute function public.airport_areas_settings_row();
insert into public.airport_settings (airport_id) select id from public.airport_areas on conflict do nothing;

alter table public.airport_settings enable row level security;
alter table public.airport_waiting_zones enable row level security;
alter table public.airport_fare_zones enable row level security;
revoke all on public.airport_settings, public.airport_waiting_zones, public.airport_fare_zones from anon;
grant select, insert, update, delete on public.airport_settings, public.airport_waiting_zones, public.airport_fare_zones
  to authenticated;

drop policy if exists "airport_settings read" on public.airport_settings;
create policy "airport_settings read" on public.airport_settings for select to authenticated using (true);
drop policy if exists "airport_settings admin insert" on public.airport_settings;
create policy "airport_settings admin insert" on public.airport_settings for insert to authenticated
  with check ((select public.caller_admin_can_write('airport_settings')));
drop policy if exists "airport_settings admin update" on public.airport_settings;
create policy "airport_settings admin update" on public.airport_settings for update to authenticated
  using ((select public.caller_admin_can_write('airport_settings')))
  with check ((select public.caller_admin_can_write('airport_settings')));
drop policy if exists "airport_settings admin delete" on public.airport_settings;
create policy "airport_settings admin delete" on public.airport_settings for delete to authenticated
  using ((select public.caller_admin_can_write('airport_settings')));

drop policy if exists "airport_waiting_zones read" on public.airport_waiting_zones;
create policy "airport_waiting_zones read" on public.airport_waiting_zones for select to authenticated using (true);
drop policy if exists "airport_waiting_zones admin insert" on public.airport_waiting_zones;
create policy "airport_waiting_zones admin insert" on public.airport_waiting_zones for insert to authenticated
  with check ((select public.caller_admin_can_write('airport_waiting_zones')));
drop policy if exists "airport_waiting_zones admin update" on public.airport_waiting_zones;
create policy "airport_waiting_zones admin update" on public.airport_waiting_zones for update to authenticated
  using ((select public.caller_admin_can_write('airport_waiting_zones')))
  with check ((select public.caller_admin_can_write('airport_waiting_zones')));
drop policy if exists "airport_waiting_zones admin delete" on public.airport_waiting_zones;
create policy "airport_waiting_zones admin delete" on public.airport_waiting_zones for delete to authenticated
  using ((select public.caller_admin_can_write('airport_waiting_zones')));

drop policy if exists "airport_fare_zones read" on public.airport_fare_zones;
create policy "airport_fare_zones read" on public.airport_fare_zones for select to authenticated using (true);
drop policy if exists "airport_fare_zones admin insert" on public.airport_fare_zones;
create policy "airport_fare_zones admin insert" on public.airport_fare_zones for insert to authenticated
  with check ((select public.caller_admin_can_write('airport_fare_zones')));
drop policy if exists "airport_fare_zones admin update" on public.airport_fare_zones;
create policy "airport_fare_zones admin update" on public.airport_fare_zones for update to authenticated
  using ((select public.caller_admin_can_write('airport_fare_zones')))
  with check ((select public.caller_admin_can_write('airport_fare_zones')));
drop policy if exists "airport_fare_zones admin delete" on public.airport_fare_zones;
create policy "airport_fare_zones admin delete" on public.airport_fare_zones for delete to authenticated
  using ((select public.caller_admin_can_write('airport_fare_zones')));

-- ---- 2. Doors: the airport's gates in multi_gate ----------------------------------------------------
alter table public.multi_gate drop constraint if exists multi_gate_gate_mode;
alter table public.multi_gate add constraint multi_gate_gate_mode check (
  kind <> 'gate' or coalesce(values->>'mode', 'both') in ('pickup', 'drop', 'both')) not valid;
alter table public.multi_gate drop constraint if exists multi_gate_gate_guide;
alter table public.multi_gate add constraint multi_gate_gate_guide check (
  values->'guide' is null or jsonb_typeof(values->'guide') = 'null'
  or (jsonb_typeof(values->'guide') = 'array' and jsonb_array_length(values->'guide') <= 20
      and pg_column_size(values->'guide') <= 32768)) not valid;

create or replace view public.airport_doors with (security_invoker = true) as
select g.id,
       (g.values->>'placeId')::uuid as airport_id,
       coalesce(nullif(btrim(g.values->>'name'), ''), 'Door') as name,
       case g.values->>'mode' when 'pickup' then 'pick' when 'drop' then 'drop' else 'both' end as kind,
       case when g.values->>'displayPriority' ~ '^-?[0-9]+(\.[0-9]+)?$'
            then (g.values->>'displayPriority')::numeric else 9999 end as sort_order,
       case when g.values->>'lat' ~ '^-?[0-9]+(\.[0-9]+)?$' then (g.values->>'lat')::float8 end as lat,
       case when g.values->>'lon' ~ '^-?[0-9]+(\.[0-9]+)?$' then (g.values->>'lon')::float8 end as lng,
       case when jsonb_typeof(g.values->'guide') = 'array' then g.values->'guide' else '[]'::jsonb end as guide,
       g.active and coalesce(lower(g.values->>'active'), 'true') not in ('false', '0', 'no', 'off') as active
  from public.multi_gate g
 where g.kind = 'gate'
   and g.values->>'parentKey' = 'airport-areas'
   and g.values->>'placeId' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
grant select on public.airport_doors to authenticated, service_role;

-- ---- 3. Where a point is --------------------------------------------------------------------------
-- The rings of a stored boundary (a BoundaryShape, or its JSON string):
-- its polygons, else its main ring, else its bounding box.
create or replace function public.airport_rings(p_shape jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  b   jsonb := p_shape;
  out jsonb := '[]'::jsonb;
  r   jsonb;
  bb  jsonb;
begin
  if b is null then
    return out;
  end if;
  if jsonb_typeof(b) = 'string' then
    begin
      b := (b #>> '{}')::jsonb;
    exception when others then
      return out;
    end;
  end if;
  if jsonb_typeof(b) is distinct from 'object' then
    return out;
  end if;
  if jsonb_typeof(b->'polygons') = 'array' then
    for r in select value from jsonb_array_elements(b->'polygons') loop
      if jsonb_typeof(r) = 'array' and jsonb_array_length(r) >= 3 then
        out := out || jsonb_build_array(r);
      end if;
    end loop;
  end if;
  if jsonb_array_length(out) = 0 and jsonb_typeof(b->'coords') = 'array' and jsonb_array_length(b->'coords') >= 3 then
    out := jsonb_build_array(b->'coords');
  end if;
  if jsonb_array_length(out) = 0 and jsonb_typeof(b->'bbox') = 'object' then
    bb := b->'bbox';
    begin
      out := jsonb_build_array(jsonb_build_array(
        jsonb_build_object('latitude', (bb->>'north')::float8, 'longitude', (bb->>'west')::float8),
        jsonb_build_object('latitude', (bb->>'north')::float8, 'longitude', (bb->>'east')::float8),
        jsonb_build_object('latitude', (bb->>'south')::float8, 'longitude', (bb->>'east')::float8),
        jsonb_build_object('latitude', (bb->>'south')::float8, 'longitude', (bb->>'west')::float8)));
    exception when others then
      return '[]'::jsonb;
    end;
  end if;
  return out;
end;
$$;

-- Whether a point is inside any of the rings (ray casting).
create or replace function public.airport_in_rings(p_lat float8, p_lng float8, p_rings jsonb)
returns boolean
language plpgsql
immutable
set search_path = public
as $$
declare
  r jsonb;
  n int;
  i int;
  j int;
  xi float8; yi float8; xj float8; yj float8;
  inside boolean;
begin
  if p_lat is null or p_lng is null or jsonb_typeof(p_rings) is distinct from 'array' then
    return false;
  end if;
  for r in select value from jsonb_array_elements(p_rings) loop
    n := jsonb_array_length(r);
    continue when n < 3;
    inside := false;
    j := n - 1;
    for i in 0 .. n - 1 loop
      yi := (r->i->>'latitude')::float8; xi := (r->i->>'longitude')::float8;
      yj := (r->j->>'latitude')::float8; xj := (r->j->>'longitude')::float8;
      if (yi > p_lat) <> (yj > p_lat)
         and p_lng < (xj - xi) * (p_lat - yi) / (yj - yi) + xi then
        inside := not inside;
      end if;
      j := i;
    end loop;
    if inside then
      return true;
    end if;
  end loop;
  return false;
exception when others then
  return false;
end;
$$;

-- The airport whose drawn area holds a point (the first by position).
create or replace function public.airport_at(p_lat float8, p_lng float8)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select a.id
    from public.airport_areas a
   where a.active and p_lat is not null and p_lng is not null
     and public.airport_in_rings(p_lat, p_lng, public.airport_rings(a.values->'boundary'))
   order by a.position, a.created_at
   limit 1;
$$;

-- The waiting zone (and its airport) a point is in.
create or replace function public.airport_zone_at(p_lat float8, p_lng float8)
returns table (airport_id uuid, zone_id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select z.airport_id, z.id
    from public.airport_waiting_zones z
    join public.airport_areas a on a.id = z.airport_id and a.active
   where p_lat is not null and p_lng is not null
     and public.airport_in_rings(p_lat, p_lng, public.airport_rings(z.shape))
   order by a.position, z.position, z.created_at
   limit 1;
$$;

revoke execute on function public.airport_at(float8, float8) from public, anon;
revoke execute on function public.airport_zone_at(float8, float8) from public, anon;
grant execute on function public.airport_at(float8, float8) to authenticated, service_role;
grant execute on function public.airport_zone_at(float8, float8) to authenticated, service_role;

-- ---- 3b. Vehicle service types and their order ----------------------------------------------------
-- A vehicle carries the vehicle service (Admin → Vehicle Services entry id)
-- it is approved for: the driver picks one when registering it, unless its
-- make & model already maps to one (vehicle_make_models.service_id); the
-- admin approves or changes it on the vehicle's approval page
-- (service_approved_id). The airport queue uses the approved one only.
alter table public.vehicle add column if not exists service_id text;
alter table public.vehicle add column if not exists service_approved_id text;
alter table public.vehicle_make_models add column if not exists service_id text;
alter table public.vehicle drop constraint if exists vehicle_service_ids;
alter table public.vehicle add constraint vehicle_service_ids
  check (coalesce(length(service_id), 0) <= 64 and coalesce(length(service_approved_id), 0) <= 64);

-- The services from lowest to highest (Ride < Comfort < 6-seater < Premium):
-- a driver whose vehicle's service is higher may get orders for a lower
-- one, never the reverse. Shared by every airport (Admin → Airport Areas →
-- Waiting queue edits it), so normal dispatch can use it later.
create table if not exists public.vehicle_service_order (
  service_id text primary key,
  rank       integer not null,
  updated_at timestamptz not null default now(),
  constraint vehicle_service_order_id check (length(service_id) between 1 and 64),
  constraint vehicle_service_order_rank check (rank between 1 and 1000)
);
comment on table public.vehicle_service_order is
  'Vehicle services from lowest (rank 1) to highest: a higher service may take a lower one''s orders (0249).';
alter table public.vehicle_service_order enable row level security;
revoke all on public.vehicle_service_order from anon;
grant select, insert, update, delete on public.vehicle_service_order to authenticated;
drop policy if exists "vehicle_service_order read" on public.vehicle_service_order;
create policy "vehicle_service_order read" on public.vehicle_service_order for select to authenticated using (true);
drop policy if exists "vehicle_service_order admin insert" on public.vehicle_service_order;
create policy "vehicle_service_order admin insert" on public.vehicle_service_order for insert to authenticated
  with check ((select public.caller_admin_can_write('vehicle_service_order')));
drop policy if exists "vehicle_service_order admin update" on public.vehicle_service_order;
create policy "vehicle_service_order admin update" on public.vehicle_service_order for update to authenticated
  using ((select public.caller_admin_can_write('vehicle_service_order')))
  with check ((select public.caller_admin_can_write('vehicle_service_order')));
drop policy if exists "vehicle_service_order admin delete" on public.vehicle_service_order;
create policy "vehicle_service_order admin delete" on public.vehicle_service_order for delete to authenticated
  using ((select public.caller_admin_can_write('vehicle_service_order')));

-- The vehicle service entry a ride's service name is (case-blind).
create or replace function public.vehicle_service_id_of(p_name text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select e.id::text from public.settings_entries e
   where e.category = 'vehicle-services' and lower(btrim(e.values->>'name')) = lower(btrim(coalesce(p_name, '')))
   order by e.position
   limit 1;
$$;

create or replace function public.vehicle_service_rank(p_service_id text)
returns integer
language sql
stable
security definer
set search_path = public
as $$ select rank from public.vehicle_service_order where service_id = p_service_id; $$;

-- How far above a ride's service a driver's vehicle service is: 0 for the
-- same service (or a ride whose service isn't a known one), the difference
-- in rank for a higher one, null when the driver may not take it (a lower or
-- unranked service, or a vehicle with none).
create or replace function public.airport_line_gap(p_driver_service text, p_ride_service text)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  rsid text := public.vehicle_service_id_of(p_ride_service);
  dr int;
  rr int;
begin
  if nullif(p_driver_service, '') is null then
    return null;
  end if;
  if rsid is null or p_driver_service = rsid then
    return 0;
  end if;
  dr := public.vehicle_service_rank(p_driver_service);
  rr := public.vehicle_service_rank(rsid);
  if dr is null or rr is null or dr <= rr then
    return null;
  end if;
  return dr - rr;
end;
$$;

-- The approved service of the vehicle a driver is driving: the one taken
-- (vehicle_active_session), else their own approved vehicle that has one
-- (the latest changed). Null: the driver can't join an airport queue.
create or replace function public.driver_vehicle_service(p_uid uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select nullif(v.service_approved_id, '') from public.vehicle_active_session s
       join public.vehicle v on v.id = s.vehicle_id
      where s.user_id = p_uid limit 1),
    (select v.service_approved_id from public.vehicle v
      where v.auth_user_id = p_uid and v.status = 'approved' and nullif(v.service_approved_id, '') is not null
      order by v.updated_at desc limit 1));
$$;

revoke execute on function public.vehicle_service_id_of(text) from public, anon;
revoke execute on function public.vehicle_service_rank(text) from public, anon;
revoke execute on function public.airport_line_gap(text, text) from public, anon;
revoke execute on function public.driver_vehicle_service(uuid) from public, anon, authenticated;
grant execute on function public.vehicle_service_id_of(text), public.vehicle_service_rank(text),
  public.airport_line_gap(text, text) to authenticated, service_role;

-- The vehicle's service: taken from its make & model when that maps one;
-- the driver's choice resets the approval; the approved one is the admin's
-- (approving the vehicle approves the service it asks for, unless the admin
-- set another).
create or replace function public.vehicle_service_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_client boolean := coalesce(current_setting('role', true), '') in ('anon', 'authenticated')
                      and not public.caller_admin_can_write('vehicle');
  v_mapped text;
begin
  if nullif(new.service_id, '') is null then
    select m.service_id into v_mapped from public.vehicle_make_models m
     where m.status and nullif(m.service_id, '') is not null
       and lower(m.make) = lower(coalesce(new.make, '')) and lower(m.model) = lower(coalesce(new.model, ''))
       and (coalesce(new.vehicle_type, '') = '' or lower(m.vehicle_type) = lower(new.vehicle_type))
     order by m.position limit 1;
    new.service_id := v_mapped;
  end if;
  if v_client then
    if tg_op = 'INSERT' then
      new.service_approved_id := null;
    else
      new.service_approved_id := case when new.service_id is distinct from old.service_id then null
                                      else old.service_approved_id end;
    end if;
  elsif tg_op = 'UPDATE' and new.status = 'approved' and old.status is distinct from 'approved'
        and nullif(new.service_approved_id, '') is null then
    new.service_approved_id := new.service_id;
  end if;
  return new;
end;
$$;
revoke execute on function public.vehicle_service_guard() from public, anon, authenticated;
drop trigger if exists trg_vehicle_c_service on public.vehicle;
create trigger trg_vehicle_c_service before insert or update on public.vehicle
  for each row execute function public.vehicle_service_guard();

-- ---- 4. Drop-offs, the queue, offers ----------------------------------------------------------------
create table if not exists public.airport_dropoffs (
  id         uuid primary key default gen_random_uuid(),
  airport_id uuid not null references public.airport_areas(id) on delete cascade,
  driver_id  uuid not null references public.profiles(id) on delete cascade,
  ride_id    uuid unique references public.ride_requests(id) on delete set null,
  service    text not null default '',
  dropped_at timestamptz not null default now(),
  -- When it gave the driver a place in the queue (one drop-off, one place).
  used_at    timestamptz
);
create index if not exists airport_dropoffs_driver_idx on public.airport_dropoffs (driver_id, dropped_at);
create index if not exists airport_dropoffs_airport_idx on public.airport_dropoffs (airport_id);

create table if not exists public.airport_queue (
  id            uuid primary key default gen_random_uuid(),
  airport_id    uuid not null references public.airport_areas(id) on delete cascade,
  driver_id     uuid not null unique references public.profiles(id) on delete cascade,
  -- '' when the airport keeps one queue for every service.
  service       text not null default '',
  dropoff_id    uuid unique references public.airport_dropoffs(id) on delete set null,
  -- The order: the drop-off time, or when a declined / missed offer sent
  -- the driver to the back.
  place_at      timestamptz not null,
  joined_at     timestamptz not null default now(),
  -- Since when the driver is outside every waiting zone (or offline).
  outside_since timestamptz
);
create index if not exists airport_queue_airport_idx on public.airport_queue (airport_id, place_at);

create table if not exists public.airport_ride_offers (
  ride_id    uuid not null references public.ride_requests(id) on delete cascade,
  driver_id  uuid not null references public.profiles(id) on delete cascade,
  stage      text not null,
  offered_at timestamptz not null default now(),
  -- A queue offer's answer-by time; null for a zone offer.
  until      timestamptz,
  outcome    text,
  primary key (ride_id, driver_id),
  constraint airport_ride_offers_stage check (stage in ('queue', 'zone')),
  constraint airport_ride_offers_outcome check (
    outcome is null or outcome in ('declined', 'missed', 'taken', 'closed', 'left'))
);
create index if not exists airport_ride_offers_driver_idx on public.airport_ride_offers (driver_id);

alter table public.airport_dropoffs enable row level security;
alter table public.airport_queue enable row level security;
alter table public.airport_ride_offers enable row level security;
revoke all on public.airport_dropoffs, public.airport_queue, public.airport_ride_offers from anon;
revoke insert, update, delete, truncate on public.airport_dropoffs, public.airport_queue, public.airport_ride_offers
  from authenticated;
grant select on public.airport_dropoffs, public.airport_queue, public.airport_ride_offers to authenticated;
-- Written by the server only.
drop policy if exists "airport_dropoffs own or admin read" on public.airport_dropoffs;
create policy "airport_dropoffs own or admin read" on public.airport_dropoffs for select to authenticated
  using (driver_id = (select auth.uid()) or (select public.caller_is_admin()));
drop policy if exists "airport_queue own or admin read" on public.airport_queue;
create policy "airport_queue own or admin read" on public.airport_queue for select to authenticated
  using (driver_id = (select auth.uid()) or (select public.caller_is_admin()));
drop policy if exists "airport_ride_offers own or admin read" on public.airport_ride_offers;
create policy "airport_ride_offers own or admin read" on public.airport_ride_offers for select to authenticated
  using (driver_id = (select auth.uid()) or (select public.caller_is_admin()));

-- ---- 5. The ride's airport columns ------------------------------------------------------------------
alter table public.ride_requests
  add column if not exists airport_pickup_id uuid references public.airport_areas(id) on delete set null,
  add column if not exists airport_drop_id   uuid references public.airport_areas(id) on delete set null,
  add column if not exists pickup_door_id    uuid,
  add column if not exists pickup_door_name  text,
  add column if not exists drop_door_id      uuid,
  add column if not exists drop_door_name    text,
  add column if not exists airport_hold      boolean not null default false,
  add column if not exists airport_open_at   timestamptz,
  -- The airport fare's breakdown (0249): {airport, dir, how, lines:
  -- [{label, amount}], normal, fare, charge, total, fixed, roundUp}.
  add column if not exists airport_fare      jsonb;
create index if not exists ride_requests_airport_pickup_idx on public.ride_requests (airport_pickup_id)
  where airport_pickup_id is not null;
create index if not exists ride_requests_airport_drop_idx on public.ride_requests (airport_drop_id)
  where airport_drop_id is not null;

-- ---- 6. Who may get a held pickup ------------------------------------------------------------------
-- Queued drivers in a waiting zone and online who may take a ride of
-- [p_service], in offer order: by line — the ride's own service first, then
-- each higher service in rank order (line_gap 0, 1, 2 …) — and in each line
-- by place. With one queue for every service ([p_by_service] off) the order
-- is the place alone. A lower service never gets a higher one's ride.
create or replace function public.airport_queue_lineup(p_airport uuid, p_service text, p_by_service boolean)
returns table (driver_id uuid, place_at timestamptz, joined_at timestamptz, line_gap integer)
language sql
stable
security definer
set search_path = public
as $$
  select q.driver_id, q.place_at, q.joined_at, g.gap
    from public.airport_queue q
    join public.driver_presence d on d.profile_id = q.driver_id
   cross join lateral (select public.airport_line_gap(q.service, p_service) as gap) g
   where q.airport_id = p_airport
     and q.outside_since is null
     and d.online and d.updated_at > now() - interval '3 minutes'
     and g.gap is not null
   order by case when p_by_service then g.gap else 0 end, q.place_at, q.joined_at, q.driver_id;
$$;

-- Approved drivers online inside one of the airport's waiting zones whose
-- vehicle may take a ride of [p_service] (any, when null), nearest to a
-- point first.
create or replace function public.airport_zone_drivers(p_airport uuid, p_lat float8, p_lng float8,
                                                       p_service text default null)
returns table (driver_id uuid, km float8)
language sql
stable
security definer
set search_path = public
as $$
  select d.profile_id,
         2 * 6371 * asin(sqrt(
           power(sin(radians(d.lat - coalesce(p_lat, d.lat)) / 2), 2)
           + cos(radians(coalesce(p_lat, d.lat))) * cos(radians(d.lat))
             * power(sin(radians(d.lng - coalesce(p_lng, d.lng)) / 2), 2))) as km
    from public.driver_presence d
    join public.partners p on p.auth_user_id = d.profile_id
                          and (p.status = 'approved' or p.status::text like 'permit-%')
   where d.online and d.updated_at > now() - interval '3 minutes'
     and (p_service is null
          or public.airport_line_gap(public.driver_vehicle_service(d.profile_id), p_service) is not null)
     and exists (select 1 from public.airport_waiting_zones z
                  where z.airport_id = p_airport
                    and public.airport_in_rings(d.lat, d.lng, public.airport_rings(z.shape)))
   order by km, d.profile_id;
$$;

-- Whether anyone could be offered a pickup at the airport now.
create or replace function public.airport_has_candidates(p_airport uuid, p_service text, p_rider uuid,
                                                         p_lat float8, p_lng float8)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c public.airport_settings;
begin
  select * into c from public.airport_settings where airport_id = p_airport;
  if not found then
    return true;
  end if;
  if 'queue' = any (c.pickup_from) and exists (
       select 1 from public.airport_queue_lineup(p_airport, p_service, c.queue_by_service) l
        where l.driver_id is distinct from p_rider) then
    return true;
  end if;
  if 'zone' = any (c.pickup_from) and exists (
       select 1 from public.airport_zone_drivers(p_airport, p_lat, p_lng, p_service) z
        where z.driver_id is distinct from p_rider) then
    return true;
  end if;
  return false;
end;
$$;

-- Whether a held ride is offered to the driver right now.
create or replace function public.airport_ride_offered(p_ride uuid, p_driver uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_driver is not null and exists (
    select 1 from public.airport_ride_offers o
     where o.ride_id = p_ride and o.driver_id = p_driver and o.outcome is null
       and (o.until is null or o.until > now()));
$$;
grant execute on function public.airport_ride_offered(uuid, uuid) to authenticated, service_role;
revoke execute on function public.airport_queue_lineup(uuid, text, boolean) from public, anon, authenticated;
revoke execute on function public.airport_zone_drivers(uuid, float8, float8, text) from public, anon, authenticated;
revoke execute on function public.airport_has_candidates(uuid, text, uuid, float8, float8) from public, anon, authenticated;

-- A held pickup is read by its rider, its driver, admins and the drivers it
-- is offered to only. (Restrictive: on top of "ride_requests read".)
drop policy if exists "ride_requests airport hold" on public.ride_requests;
create policy "ride_requests airport hold" on public.ride_requests as restrictive for select to authenticated
  using (not airport_hold or status <> 'open'
         or rider_id = (select auth.uid()) or partner_id = (select auth.uid())
         or (select public.caller_is_admin())
         or public.airport_ride_offered(id, (select auth.uid())));

-- ---- 7. Charges (their own step; airport fares would be a separate one) ---------------------------
-- The airport charges for a ride from [p_pickup_airport] to [p_drop_airport],
-- as ride_requests.charges entries ({kind: surcharge, charge: fixed, airport}).
create or replace function public.airport_ride_charges(p_pickup_airport uuid, p_drop_airport uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c   public.airport_settings;
  out jsonb := '[]'::jsonb;
begin
  if p_drop_airport is not null then
    select * into c from public.airport_settings where airport_id = p_drop_airport;
    if found and c.drop_fee_on and c.drop_fee_amount > 0 then
      out := out || jsonb_build_array(jsonb_build_object(
        'kind', 'surcharge', 'name', c.drop_fee_name, 'charge', 'fixed',
        'value', round(c.drop_fee_amount, 2), 'airport', 'drop'));
    end if;
  end if;
  if p_pickup_airport is not null then
    select * into c from public.airport_settings where airport_id = p_pickup_airport;
    if found and c.pick_fee_on and c.pick_fee_amount > 0 then
      out := out || jsonb_build_array(jsonb_build_object(
        'kind', 'surcharge', 'name', c.pick_fee_name, 'charge', 'fixed',
        'value', round(c.pick_fee_amount, 2), 'airport', 'pick'));
    end if;
  end if;
  return out;
end;
$$;
revoke execute on function public.airport_ride_charges(uuid, uuid) from public, anon, authenticated;

-- ---- 7b. Airport fares (their own step, before the charges are added) ---------------------------
-- The normal tariff's rate per km for a service where a ride starts: the
-- narrowest active Fare tariffs card for the vehicle service (else for every
-- service), with the service's multiplier on a card for every service; the
-- built-in TEKSI rate (RM 0.35 per 200 m) without one. Service-type cards
-- are not considered.
create or replace function public.airport_per_km(p_service text, p_country text, p_state text, p_city text,
                                                 p_suburb text)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sid  text;
  v_cost numeric;
  v_mult numeric := 1;
  t public.fare_tariffs;
  eq text := '';
begin
  select e.id::text,
         case when e.values->>'costPerKm' ~ '^[0-9]+(\.[0-9]+)?$' then (e.values->>'costPerKm')::numeric end
    into v_sid, v_cost
    from public.settings_entries e
   where e.category = 'vehicle-services'
     and lower(btrim(e.values->>'name')) = lower(btrim(coalesce(p_service, '')))
   order by e.position
   limit 1;
  if v_cost is not null and v_cost > 0 then
    v_mult := v_cost / 1.5;
  end if;
  select f.* into t
    from public.fare_tariffs f
   where f.active and f.service_type is null
     and (f.vehicle_service is null or f.vehicle_service = v_sid)
     and (f.level = 'master'
          or (f.level = 'country' and lower(f.country) = lower(coalesce(p_country, eq)))
          or (f.level = 'state' and lower(f.country) = lower(coalesce(p_country, eq))
              and lower(f.state) = lower(coalesce(p_state, eq)))
          or (f.level = 'city' and lower(f.country) = lower(coalesce(p_country, eq))
              and lower(f.state) = lower(coalesce(p_state, eq)) and lower(f.city) = lower(coalesce(p_city, eq)))
          or (f.level = 'suburb' and lower(f.country) = lower(coalesce(p_country, eq))
              and lower(f.state) = lower(coalesce(p_state, eq)) and lower(f.city) = lower(coalesce(p_city, eq))
              and lower(f.suburb) = lower(coalesce(p_suburb, eq))))
   order by case f.level when 'suburb' then 0 when 'city' then 1 when 'state' then 2 when 'country' then 3 else 4 end,
            (f.vehicle_service is null)
   limit 1;
  if t.id is not null then
    return round(t.per_km * case when t.vehicle_service is null then v_mult else 1 end, 4);
  end if;
  return round(1.75 * v_mult, 4);
end;
$$;
revoke execute on function public.airport_per_km(text, text, text, text, text) from public, anon, authenticated;

-- A number from json, or null.
create or replace function public.airport_num(p jsonb)
returns numeric
language sql
immutable
set search_path = public
as $$
  select case when jsonb_typeof(p) = 'number' then (p #>> '{}')::numeric
              when jsonb_typeof(p) = 'string' and (p #>> '{}') ~ '^-?[0-9]+(\.[0-9]+)?$' then (p #>> '{}')::numeric end;
$$;

-- The airport fare of a ride from ('from') or to ('to') [p_airport]:
--   1. a fixed zone fare when the other end is in one of its fare zones, else
--      the distance band (the first tier the trip fits in; past the last,
--      its flat fare + the normal rate per km for the km past it, or for the
--      whole trip), else the normal fare [p_normal];
--   2. + the service's airport base;
--   3. raised to the pickup / drop-off minimum;
--   4. + the ride's option charges [p_options] (pets, assistance: 0248's
--      option_charges lines, part of the fare);
--   5. + the airport charges [p_charges] (charges entries);
--   6. rounded up to a whole amount when fares.roundUp (the default).
-- [p_normal] is the route fare without the option charges. fare is the
-- total less the airport charges (what ride_requests.fare carries: the
-- option charges stay in it, as 0248 has them).
-- Null when the airport has no settings.
create or replace function public.airport_quote(p_airport uuid, p_dir text, p_service text, p_km numeric,
                                                p_normal numeric, p_per_km numeric, p_other_lat float8,
                                                p_other_lng float8, p_charges jsonb,
                                                p_options jsonb default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c       public.airport_settings;
  f       jsonb;
  z       public.airport_fare_zones;
  v_band  jsonb;
  t       jsonb;
  v_last  jsonb;
  v_km    numeric := greatest(coalesce(p_km, 0), 0);
  v_ride  numeric;
  v_how   text;
  v_fixed boolean := false;
  v_lines jsonb := '[]'::jsonb;
  v_base  numeric;
  v_sub   numeric;
  v_min   jsonb;
  v_charge numeric := 0;
  v_total numeric;
  v_round boolean;
  v_up    numeric;
  e       jsonb;
begin
  select * into c from public.airport_settings where airport_id = p_airport;
  if not found then
    return null;
  end if;
  f := c.fares;

  select * into z from public.airport_fare_zones
   where airport_id = p_airport
     and public.airport_in_rings(p_other_lat, p_other_lng, public.airport_rings(shape))
   order by position, created_at
   limit 1;
  if z.id is not null then
    v_ride := case when p_dir = 'from' then z.from_amount else z.to_amount end;
    v_how := format('Fixed fare, %s %s the airport', z.name, case when p_dir = 'from' then 'from' else 'to' end);
    v_fixed := true;
  else
    v_band := f->'band';
    if coalesce((v_band->>'on')::boolean, false)
       and coalesce(v_band->>'applies', 'both') in ('both', case when p_dir = 'from' then 'pick' else 'drop' end)
       and jsonb_typeof(v_band->'tiers') = 'array' and jsonb_array_length(v_band->'tiers') > 0 then
      for t in
        select value from jsonb_array_elements(v_band->'tiers')
         where public.airport_num(value->'uptoKm') is not null and public.airport_num(value->'flat') is not null
         order by public.airport_num(value->'uptoKm')
      loop
        v_last := t;
        if v_ride is null and v_km <= public.airport_num(t->'uptoKm') then
          v_ride := public.airport_num(t->'flat');
          v_how := format('Flat fare up to %s km', trim_scale(public.airport_num(t->'uptoKm')));
        end if;
      end loop;
      if v_ride is null and v_last is not null then
        if coalesce(v_band->>'extra', 'extra') = 'all' then
          v_ride := public.airport_num(v_last->'flat') + coalesce(p_per_km, 0) * v_km;
          v_how := format('Flat fare + normal rate for all %s km', trim_scale(round(v_km, 1)));
        else
          v_ride := public.airport_num(v_last->'flat')
                    + coalesce(p_per_km, 0) * (v_km - public.airport_num(v_last->'uptoKm'));
          v_how := format('Flat fare + normal rate for %s km past %s km',
                          trim_scale(round(v_km - public.airport_num(v_last->'uptoKm'), 1)),
                          trim_scale(public.airport_num(v_last->'uptoKm')));
        end if;
      end if;
      v_fixed := v_ride is not null;
    end if;
    if v_ride is null then
      v_ride := coalesce(p_normal, 0);
      v_how := 'Normal fare';
    end if;
  end if;
  v_ride := round(greatest(v_ride, 0), 2);
  v_lines := v_lines || jsonb_build_array(jsonb_build_object('label', v_how, 'amount', v_ride));

  v_base := 0;
  if jsonb_typeof(f->'base') = 'object' then
    select coalesce(max(public.airport_num(b.value)), 0) into v_base
      from jsonb_each(f->'base') b
     where lower(btrim(b.key)) = lower(btrim(coalesce(p_service, '')));
  end if;
  v_base := round(greatest(coalesce(v_base, 0), 0), 2);
  if v_base > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'label', format('%s airport base', coalesce(nullif(p_service, ''), 'Ride')), 'amount', v_base));
  end if;
  v_sub := v_ride + v_base;

  v_min := f->(case when p_dir = 'from' then 'minPick' else 'minDrop' end);
  if coalesce((v_min->>'on')::boolean, false) and coalesce(public.airport_num(v_min->'amount'), 0) > v_sub then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'label', format('Raised to the %s minimum', case when p_dir = 'from' then 'pickup' else 'drop-off' end),
      'amount', round(public.airport_num(v_min->'amount') - v_sub, 2)));
    v_sub := round(public.airport_num(v_min->'amount'), 2);
  end if;

  for e in select value from jsonb_array_elements(case when jsonb_typeof(p_options) = 'array' then p_options else '[]'::jsonb end) loop
    continue when coalesce(public.airport_num(e->'amount'), 0) <= 0;
    v_sub := v_sub + round(public.airport_num(e->'amount'), 2);
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('label', e->>'name',
                                                               'amount', round(public.airport_num(e->'amount'), 2),
                                                               'option', true));
  end loop;

  for e in select value from jsonb_array_elements(case when jsonb_typeof(p_charges) = 'array' then p_charges else '[]'::jsonb end) loop
    v_charge := v_charge + coalesce(public.airport_num(e->'value'), 0);
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('label', e->>'name', 'amount', public.airport_num(e->'value'),
                                                               'charge', true));
  end loop;
  v_total := v_sub + v_charge;
  v_round := coalesce((f->>'roundUp')::boolean, true);
  v_up := case when v_round then ceil(v_total) else round(v_total, 2) end;
  if v_up > v_total then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('label', 'Rounded up', 'amount', round(v_up - v_total, 2)));
  end if;
  return jsonb_build_object(
    'airport', p_airport, 'dir', p_dir, 'how', v_how, 'lines', v_lines, 'normal', p_normal, 'perKm', p_per_km,
    'fare', round(v_up - v_charge, 2), 'charge', round(v_charge, 2), 'total', round(v_up, 2),
    'fixed', v_fixed, 'roundUp', v_round);
end;
$$;
revoke execute on function public.airport_quote(uuid, text, text, numeric, numeric, numeric, float8, float8, jsonb, jsonb)
  from public, anon, authenticated;

-- The airport fare a ride would be booked at, for the app's confirm step:
-- what the booking trigger stamps. Null when neither end is at an airport.
create or replace function public.airport_fare_quote(
  p_pickup_lat float8, p_pickup_lng float8, p_drop_lat float8, p_drop_lng float8,
  p_service text, p_km numeric, p_normal numeric,
  p_country text default null, p_state text default null, p_city text default null, p_suburb text default null,
  p_option_charges jsonb default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pa uuid := public.airport_at(p_pickup_lat, p_pickup_lng);
  v_da uuid := public.airport_at(p_drop_lat, p_drop_lng);
begin
  if v_pa is null and v_da is null then
    return null;
  end if;
  -- [p_normal] is the fare as the app books it (with the option charges in
  -- it, as 0248 has them); the airport fare works on the route fare.
  return public.airport_quote(
    coalesce(v_pa, v_da), case when v_pa is not null then 'from' else 'to' end, p_service, p_km,
    greatest(0, coalesce(p_normal, 0) - public.ride_option_charges_total(p_option_charges)),
    public.airport_per_km(p_service, p_country, p_state, p_city, p_suburb),
    case when v_pa is not null then p_drop_lat else p_pickup_lat end,
    case when v_pa is not null then p_drop_lng else p_pickup_lng end,
    public.airport_ride_charges(v_pa, v_da), p_option_charges);
end;
$$;
revoke execute on function public.airport_fare_quote(float8, float8, float8, float8, text, numeric, numeric, text, text, text, text, jsonb)
  from public, anon;
grant execute on function public.airport_fare_quote(float8, float8, float8, float8, text, numeric, numeric, text, text, text, text, jsonb)
  to authenticated, service_role;

-- ---- 8. The ride trigger: doors, charges, the hold ----------------------------------------------
-- Whether the caller is a client (not the server, not an admin with the
-- Rides page). A SECURITY DEFINER function reads the session's role, not
-- current_user (which is the owner inside it). Server steps that run inside a
-- client's call (a driver's presence, a decline) set getride.airport_server.
create or replace function public.airport_caller_is_client()
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(current_setting('role', true), '') in ('anon', 'authenticated')
     and coalesce(current_setting('getride.airport_server', true), '') <> 'on'
     and not public.caller_admin_can_write('ride_requests');
$$;
revoke execute on function public.airport_caller_is_client() from public, anon, authenticated;

-- The door's name when it is one of [p_airport]'s active doors for [p_side]
-- ('pick' | 'drop'), else null.
create or replace function public.airport_door_name(p_door uuid, p_airport uuid, p_side text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select d.name from public.airport_doors d
   where d.id = p_door and d.airport_id = p_airport and d.active and d.kind in (p_side, 'both');
$$;
revoke execute on function public.airport_door_name(uuid, uuid, text) from public, anon, authenticated;

create or replace function public.ride_requests_airport()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_client boolean := public.airport_caller_is_client();
  cp public.airport_settings;
  cd public.airport_settings;
  v_rest jsonb;
  v_charges jsonb;
  v_quote jsonb;
  v_name text;
begin
  if tg_op = 'INSERT' then
    new.airport_pickup_id := public.airport_at(new.pickup_lat, new.pickup_lng);
    new.airport_drop_id := public.airport_at(new.drop_lat, new.drop_lng);
    new.airport_hold := false;
    new.airport_open_at := null;
    new.pickup_door_name := null;
    new.drop_door_name := null;
    if new.airport_pickup_id is not null then
      select * into cp from public.airport_settings where airport_id = new.airport_pickup_id;
    end if;
    if new.airport_drop_id is not null then
      select * into cd from public.airport_settings where airport_id = new.airport_drop_id;
    end if;

    -- The doors the rider chose: a door of that airport, for that side.
    if new.pickup_door_id is not null then
      new.pickup_door_name := public.airport_door_name(new.pickup_door_id, new.airport_pickup_id, 'pick');
      if new.pickup_door_name is null then
        raise exception 'AIRPORT_DOOR_INVALID' using errcode = '22023',
          hint = 'That door is not a pickup door of this airport.';
      end if;
    elsif (v_client or new.scheduled_ride_id is not null) and cp.airport_id is not null and cp.pick_door_required
          and exists (select 1 from public.airport_doors d
                       where d.airport_id = new.airport_pickup_id and d.active and d.kind in ('pick', 'both')) then
      raise exception 'AIRPORT_DOOR_REQUIRED' using errcode = '22023',
        hint = 'Choose where the driver should pick you up.';
    end if;
    if new.drop_door_id is not null then
      new.drop_door_name := public.airport_door_name(new.drop_door_id, new.airport_drop_id, 'drop');
      if new.drop_door_name is null then
        raise exception 'AIRPORT_DOOR_INVALID' using errcode = '22023',
          hint = 'That door is not a drop-off door of this airport.';
      end if;
    elsif (v_client or new.scheduled_ride_id is not null) and cd.airport_id is not null and cd.drop_door_required
          and exists (select 1 from public.airport_doors d
                       where d.airport_id = new.airport_drop_id and d.active and d.kind in ('drop', 'both')) then
      raise exception 'AIRPORT_DOOR_REQUIRED' using errcode = '22023',
        hint = 'Choose the door you are going to.';
    end if;

    -- The airport fare and charges are the server's: what a client sent is
    -- dropped and worked out again. (A row the server already stamped, such
    -- as a scheduled ride's, keeps its own.)
    if v_client or new.airport_fare is null then
      new.airport_fare := null;
      select coalesce(jsonb_agg(e), '[]'::jsonb) into v_rest
        from jsonb_array_elements(case when jsonb_typeof(new.charges) = 'array' then new.charges else '[]'::jsonb end) e
       where e->'airport' is null;
      v_charges := public.airport_ride_charges(new.airport_pickup_id, new.airport_drop_id);
      v_rest := v_rest || v_charges;
      new.charges := case when v_rest = '[]'::jsonb then null else v_rest end;
      -- The fare step, then the charges on top (airport_quote).
      if new.airport_pickup_id is not null or new.airport_drop_id is not null then
        v_quote := public.airport_quote(
          coalesce(new.airport_pickup_id, new.airport_drop_id),
          case when new.airport_pickup_id is not null then 'from' else 'to' end,
          new.service, new.distance_km,
          -- The route fare: the app's fare has the option charges in it (0248).
          greatest(0, coalesce(new.ride_fare, new.fare, 0) - public.ride_option_charges_total(new.option_charges)),
          public.airport_per_km(new.service, new.country, new.state, new.city, new.suburb),
          case when new.airport_pickup_id is not null then new.drop_lat else new.pickup_lat end,
          case when new.airport_pickup_id is not null then new.drop_lng else new.pickup_lng end,
          v_charges, new.option_charges);
        if v_quote is not null then
          new.airport_fare := v_quote;
          new.fare := (v_quote->>'fare')::numeric;
          new.ride_fare := new.fare;
          -- A fixed airport fare isn't bid on.
          if (v_quote->>'fixed')::boolean then
            new.offer_me := false;
            new.auto_accept_fare := null;
          end if;
        end if;
      end if;
    end if;

    -- A pickup the airport keeps for its queue / zone drivers.
    if new.status = 'open' and cp.airport_id is not null and cp.restrict_pickups then
      if new.direct_driver_id is not null then
        raise exception 'AIRPORT_QUEUE_ONLY' using errcode = '42501',
          hint = 'Pickups at this airport go to the drivers waiting for them; a driver''s code can''t be used here.';
      end if;
      new.airport_hold := true;
      new.target_driver_ids := null;
      new.targeted_until := null;
      if not public.airport_has_candidates(new.airport_pickup_id, new.service, new.rider_id,
                                           new.pickup_lat, new.pickup_lng) then
        if cp.empty_action = 'decline' then
          new.status := 'expired';
          new.cancel_reason := 'AIRPORT_NO_DRIVER';
        elsif cp.empty_action = 'nearby' then
          if cp.nearby_after_min = 0 then
            new.airport_hold := false;
          else
            new.airport_open_at := now() + make_interval(mins => cp.nearby_after_min);
          end if;
        end if;
      end if;
    end if;
    return new;
  end if;

  -- UPDATE
  if v_client then
    new.airport_pickup_id := old.airport_pickup_id;
    new.airport_drop_id := old.airport_drop_id;
    new.airport_hold := old.airport_hold;
    new.airport_open_at := old.airport_open_at;
    new.airport_fare := old.airport_fare;
    new.pickup_door_name := old.pickup_door_name;
    new.drop_door_name := old.drop_door_name;

    -- The airport charges stay as stamped.
    if new.charges is distinct from old.charges then
      select coalesce(jsonb_agg(e), '[]'::jsonb) into v_rest
        from jsonb_array_elements(case when jsonb_typeof(new.charges) = 'array' then new.charges else '[]'::jsonb end) e
       where e->'airport' is null;
      select v_rest || coalesce(jsonb_agg(e), '[]'::jsonb) into v_rest
        from jsonb_array_elements(case when jsonb_typeof(old.charges) = 'array' then old.charges else '[]'::jsonb end) e
       where e->'airport' is not null;
      new.charges := case when v_rest = '[]'::jsonb then null else v_rest end;
    end if;

    -- The doors are the rider's to choose, while the ride hasn't started.
    if new.pickup_door_id is distinct from old.pickup_door_id or new.drop_door_id is distinct from old.drop_door_id then
      if auth.uid() is distinct from old.rider_id then
        raise exception 'AIRPORT_DOOR_RIDER_ONLY' using errcode = '42501',
          hint = 'Only the passenger chooses the door.';
      end if;
      if old.status not in ('open', 'accepted', 'arrived') then
        raise exception 'AIRPORT_DOOR_LOCKED' using errcode = '42501',
          hint = 'The door can''t be changed once the trip has started.';
      end if;
      if new.pickup_door_id is distinct from old.pickup_door_id then
        v_name := case when new.pickup_door_id is null then null
                       else public.airport_door_name(new.pickup_door_id, old.airport_pickup_id, 'pick') end;
        if new.pickup_door_id is not null and v_name is null then
          raise exception 'AIRPORT_DOOR_INVALID' using errcode = '22023',
            hint = 'That door is not a pickup door of this airport.';
        end if;
        new.pickup_door_name := v_name;
      end if;
      if new.drop_door_id is distinct from old.drop_door_id then
        v_name := case when new.drop_door_id is null then null
                       else public.airport_door_name(new.drop_door_id, old.airport_drop_id, 'drop') end;
        if new.drop_door_id is not null and v_name is null then
          raise exception 'AIRPORT_DOOR_INVALID' using errcode = '22023',
            hint = 'That door is not a drop-off door of this airport.';
        end if;
        new.drop_door_name := v_name;
      end if;
    end if;

    -- A held pickup is taken (or bid on) only by a driver it is offered to.
    if old.airport_hold and old.status = 'open'
       and new.partner_id is not null and new.partner_id is distinct from old.partner_id
       and not public.airport_ride_offered(old.id, new.partner_id) then
      raise exception 'AIRPORT_QUEUE_ONLY' using errcode = '42501',
        hint = 'This airport pickup is offered to the drivers waiting for it.';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_airport() from public, anon, authenticated;

-- After My Ride and GET.now (c_my_ride), before the promo (d_promo, which
-- prices the discount on the fare) and privacy (zz_).
drop trigger if exists trg_ride_requests_c_zairport on public.ride_requests;
create trigger trg_ride_requests_c_zairport
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_airport();

-- ---- 8b. Scheduled rides pick their doors too ----------------------------------------------------
-- The booking keeps the doors (0248's list, with the door ids), they are
-- checked when the ride is scheduled, and again when it is released (the
-- ride trigger above; a release refused is retried and its error kept).
create or replace function public.scheduled_request_clean(p_request jsonb, p_fee numeric default null)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select coalesce((
    select jsonb_object_agg(e.key,
      case when e.key = 'charges' then (
        select coalesce(jsonb_agg(
          case when p_fee is not null and c->>'name' = 'Scheduling fee' and c->'value' = to_jsonb(p_fee)
                    and c->>'kind' = 'surcharge'
               then c else c - 'platform' end), '[]'::jsonb)
          from jsonb_array_elements(e.value) c
         where jsonb_typeof(c) = 'object')
      else e.value end)
      from jsonb_each(coalesce(p_request, '{}'::jsonb)) e
     where e.key = any (array[
       'rider_name', 'rider_phone', 'rider_photo', 'service', 'payment_mode',
       'pickup_name', 'pickup_address', 'pickup_lat', 'pickup_lng',
       'drop_name', 'drop_address', 'drop_lat', 'drop_lng', 'stops',
       'distance_km', 'duration_min', 'fare', 'ride_fare', 'currency',
       'passengers', 'luggage', 'note', 'offer_me', 'otp', 'device_os',
       'user_accept_lat', 'user_accept_lng', 'booked_for_name', 'booked_for_phone',
       'country', 'state', 'city', 'suburb', 'full_address', 'ip_address', 'gender',
       'whole_fare', 'tax_name', 'tax_kind', 'tax_value', 'charges', 'timezone',
       'promo_code_id', 'pets', 'assistance', 'option_charges', 'option_names',
       'pickup_door_id', 'drop_door_id'])
       and (e.key <> 'charges' or jsonb_typeof(e.value) = 'array')
  ), '{}'::jsonb);
$$;
revoke execute on function public.scheduled_request_clean(jsonb, numeric) from public, anon, authenticated;

-- Raises as booking does when a door is missing where the airport asks for
-- one, or isn't one of its doors for that end.
create or replace function public.airport_require_doors(p_plat float8, p_plng float8, p_dlat float8, p_dlng float8,
                                                        p_pick_door uuid, p_drop_door uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pa uuid := public.airport_at(p_plat, p_plng);
  v_da uuid := public.airport_at(p_dlat, p_dlng);
begin
  if p_pick_door is not null and public.airport_door_name(p_pick_door, v_pa, 'pick') is null then
    raise exception 'AIRPORT_DOOR_INVALID' using errcode = '22023',
      hint = 'That door is not a pickup door of this airport.';
  end if;
  if p_drop_door is not null and public.airport_door_name(p_drop_door, v_da, 'drop') is null then
    raise exception 'AIRPORT_DOOR_INVALID' using errcode = '22023',
      hint = 'That door is not a drop-off door of this airport.';
  end if;
  if p_pick_door is null and v_pa is not null
     and coalesce((select pick_door_required from public.airport_settings where airport_id = v_pa), false)
     and exists (select 1 from public.airport_doors d where d.airport_id = v_pa and d.active and d.kind in ('pick', 'both')) then
    raise exception 'AIRPORT_DOOR_REQUIRED' using errcode = '22023', hint = 'Choose where the driver should pick you up.';
  end if;
  if p_drop_door is null and v_da is not null
     and coalesce((select drop_door_required from public.airport_settings where airport_id = v_da), false)
     and exists (select 1 from public.airport_doors d where d.airport_id = v_da and d.active and d.kind in ('drop', 'both')) then
    raise exception 'AIRPORT_DOOR_REQUIRED' using errcode = '22023', hint = 'Choose the door you are going to.';
  end if;
end;
$$;
revoke execute on function public.airport_require_doors(float8, float8, float8, float8, uuid, uuid)
  from public, anon, authenticated;

create or replace function public.scheduled_rides_airport_doors()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req jsonb := coalesce(new.request, '{}'::jsonb);
  re text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
begin
  if coalesce(v_req->>'pickup_door_id', '') !~* re then
    v_req := v_req - 'pickup_door_id';
  end if;
  if coalesce(v_req->>'drop_door_id', '') !~* re then
    v_req := v_req - 'drop_door_id';
  end if;
  new.request := v_req;
  perform public.airport_require_doors(new.pickup_lat, new.pickup_lng, new.drop_lat, new.drop_lng,
                                       (v_req->>'pickup_door_id')::uuid, (v_req->>'drop_door_id')::uuid);
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_airport_doors() from public, anon, authenticated;
drop trigger if exists trg_scheduled_rides_airport_doors on public.scheduled_rides;
create trigger trg_scheduled_rides_airport_doors before insert on public.scheduled_rides
  for each row execute function public.scheduled_rides_airport_doors();

-- ---- 9. Dispatch ----------------------------------------------------------------------------------
create or replace function public.airport_push(p_driver uuid, p_ride public.ride_requests)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.send_push_webhook(jsonb_build_object(
    'title', 'Airport order',
    'body', 'Pickup at ' || coalesce(nullif(p_ride.pickup_door_name, ''), nullif(p_ride.pickup_name, ''),
                                     nullif(p_ride.pickup_address, ''), 'the airport'),
    'profileId', p_driver,
    'data', jsonb_build_object('type', 'ride_request', 'ride_request_id', p_ride.id, 'airport', true)));
exception when others then
  null; -- a push never holds dispatch up
end;
$$;
revoke execute on function public.airport_push(uuid, public.ride_requests) from public, anon, authenticated;

-- The ride goes to normal nearby dispatch, as a new request would.
create or replace function public.airport_open_to_nearby(p_ride uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  cfg jsonb;
  v_msg jsonb;
  v_told int;
begin
  perform set_config('getride.airport_server', 'on', true);
  update public.ride_requests set airport_hold = false where id = p_ride and airport_hold
  returning * into r;
  if not found then
    return;
  end if;
  update public.airport_ride_offers set outcome = 'closed' where ride_id = p_ride and outcome is null;
  begin
    cfg := public.vehicle_service_dispatch_config(r.service);
    v_msg := public.ride_request_push_message(r.id, r.pickup_name, r.pickup_address, r.fare, r.currency, 'new');
    v_told := public.ride_request_push_nearby(r.id, r.rider_id, r.pickup_lat, r.pickup_lng,
                                              (cfg->>'search_radius_min_km')::double precision, v_msg, 'nearby', false);
    if v_told = 0 then
      perform public.ride_request_push_everyone(r.id, v_msg, 'everyone');
    end if;
  exception when others then
    null;
  end;
end;
$$;
revoke execute on function public.airport_open_to_nearby(uuid) from public, anon, authenticated;

-- A driver who declined or missed a queue offer goes to the back (or keeps
-- their place when the airport says so).
create or replace function public.airport_after_refusal(p_airport uuid, p_driver uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce((select back_on_decline from public.airport_settings where airport_id = p_airport), true) then
    update public.airport_queue
       set place_at = greatest(now(), (select max(place_at) from public.airport_queue where airport_id = p_airport)
                                      + interval '1 millisecond')
     where airport_id = p_airport and driver_id = p_driver;
  end if;
end;
$$;
revoke execute on function public.airport_after_refusal(uuid, uuid) from public, anon, authenticated;

-- Offers a held pickup to the next driver(s) by the airport's rules.
-- Answers what happened: queue | zone | wait | declined | nearby | opened | none.
create or replace function public.airport_dispatch(p_ride uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  c public.airport_settings;
  v_driver uuid;
  n int;
begin
  perform set_config('getride.airport_server', 'on', true);
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.status <> 'open' or not r.airport_hold then
    return 'none';
  end if;
  select * into c from public.airport_settings where airport_id = r.airport_pickup_id;
  if not found or not c.restrict_pickups
     or (r.airport_open_at is not null and r.airport_open_at <= now()) then
    perform public.airport_open_to_nearby(p_ride);
    return 'opened';
  end if;

  -- Queue offers not answered in time: missed.
  for v_driver in
    select o.driver_id from public.airport_ride_offers o
     where o.ride_id = p_ride and o.outcome is null and o.until is not null and o.until <= now()
  loop
    update public.airport_ride_offers set outcome = 'missed' where ride_id = p_ride and driver_id = v_driver;
    perform public.airport_after_refusal(r.airport_pickup_id, v_driver);
  end loop;
  -- Zone offers to drivers no longer in a zone: withdrawn.
  update public.airport_ride_offers o set outcome = 'left'
   where o.ride_id = p_ride and o.outcome is null and o.stage = 'zone'
     and not exists (select 1 from public.airport_zone_drivers(r.airport_pickup_id, null, null) z
                      where z.driver_id = o.driver_id);

  -- One queue offer at a time.
  if exists (select 1 from public.airport_ride_offers o
              where o.ride_id = p_ride and o.outcome is null and o.stage = 'queue') then
    return 'queue';
  end if;

  if 'queue' = any (c.pickup_from) then
    select l.driver_id into v_driver
      from public.airport_queue_lineup(r.airport_pickup_id, r.service, c.queue_by_service) l
     where l.driver_id is distinct from r.rider_id
       and not exists (select 1 from public.airport_ride_offers o where o.ride_id = p_ride and o.driver_id = l.driver_id)
     order by case when c.queue_by_service then l.line_gap else 0 end, l.place_at, l.joined_at, l.driver_id
     limit 1;
    if v_driver is not null then
      insert into public.airport_ride_offers (ride_id, driver_id, stage, until)
      values (p_ride, v_driver, 'queue', now() + make_interval(secs => c.offer_seconds));
      perform public.airport_push(v_driver, r);
      return 'queue';
    end if;
  end if;

  if 'zone' = any (c.pickup_from) then
    for v_driver in
      select z.driver_id from public.airport_zone_drivers(r.airport_pickup_id, r.pickup_lat, r.pickup_lng, r.service) z
       where z.driver_id is distinct from r.rider_id
         and not exists (select 1 from public.airport_ride_offers o where o.ride_id = p_ride and o.driver_id = z.driver_id)
       order by z.km, z.driver_id
    loop
      insert into public.airport_ride_offers (ride_id, driver_id, stage) values (p_ride, v_driver, 'zone')
      on conflict do nothing;
      perform public.airport_push(v_driver, r);
    end loop;
    if exists (select 1 from public.airport_ride_offers o
                where o.ride_id = p_ride and o.outcome is null and o.stage = 'zone') then
      return 'zone';
    end if;
  end if;

  -- Nobody to offer it to.
  if c.empty_action = 'decline' then
    update public.ride_requests set status = 'expired', cancel_reason = 'AIRPORT_NO_DRIVER' where id = p_ride;
    return 'declined';
  elsif c.empty_action = 'nearby' then
    if c.nearby_after_min = 0 then
      perform public.airport_open_to_nearby(p_ride);
      return 'opened';
    end if;
    if r.airport_open_at is null then
      update public.ride_requests set airport_open_at = now() + make_interval(mins => c.nearby_after_min)
       where id = p_ride;
    end if;
    return 'nearby';
  end if;
  return 'wait';
end;
$$;
revoke execute on function public.airport_dispatch(uuid) from public, anon, authenticated;
grant execute on function public.airport_dispatch(uuid) to service_role;

-- The driver turns an airport offer down.
create or replace function public.airport_decline_offer(p_ride uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_stage text;
  v_airport uuid;
begin
  if v_uid is null then
    raise exception 'not_authorized';
  end if;
  update public.airport_ride_offers set outcome = 'declined'
   where ride_id = p_ride and driver_id = v_uid and outcome is null
  returning stage into v_stage;
  if v_stage is null then
    return;
  end if;
  select airport_pickup_id into v_airport from public.ride_requests where id = p_ride;
  if v_stage = 'queue' then
    perform public.airport_after_refusal(v_airport, v_uid);
  end if;
  perform public.airport_dispatch(p_ride);
end;
$$;
revoke execute on function public.airport_decline_offer(uuid) from public, anon;
grant execute on function public.airport_decline_offer(uuid) to authenticated;

-- After the insert: offer it. After a status change: a taken pickup uses the
-- driver's place; an ended one closes its offers; a completed drop-off at an
-- airport is recorded.
create or replace function public.ride_requests_airport_after()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.airport_hold and new.status = 'open' then
      perform public.airport_dispatch(new.id);
    end if;
    return new;
  end if;
  if old.status = 'open' and new.status is distinct from 'open' then
    if new.partner_id is not null and new.status in ('accepted', 'arrived', 'on_trip', 'completed') then
      update public.airport_ride_offers set outcome = 'taken'
       where ride_id = new.id and driver_id = new.partner_id;
      if old.airport_hold then
        delete from public.airport_queue where driver_id = new.partner_id and airport_id = new.airport_pickup_id;
      end if;
    end if;
    update public.airport_ride_offers set outcome = 'closed' where ride_id = new.id and outcome is null;
  end if;
  if new.status = 'completed' and old.status is distinct from 'completed'
     and new.airport_drop_id is not null and new.partner_id is not null then
    insert into public.airport_dropoffs (airport_id, driver_id, ride_id, service)
    values (new.airport_drop_id, new.partner_id, new.id, coalesce(new.service, ''))
    on conflict (ride_id) do nothing;
  end if;
  return new;
exception when others then
  raise warning 'ride % airport step: %', new.id, sqlerrm;
  return new;
end;
$$;
revoke execute on function public.ride_requests_airport_after() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_airport_after on public.ride_requests;
create trigger trg_ride_requests_airport_after
  after insert or update of status on public.ride_requests
  for each row execute function public.ride_requests_airport_after();

-- ---- 10. The queue follows the driver's reported position -----------------------------------------
create or replace function public.airport_on_presence(p_driver uuid, p_online boolean, p_lat float8, p_lng float8)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  z record;
  q public.airport_queue;
  c public.airport_settings;
  d public.airport_dropoffs;
  v_service text;
  v_ride uuid;
begin
  perform set_config('getride.airport_server', 'on', true);
  if p_online then
    select * into z from public.airport_zone_at(p_lat, p_lng);
  end if;
  select * into q from public.airport_queue where driver_id = p_driver;

  if z.airport_id is null then
    -- Outside every zone, or offline: the place is kept for the grace minutes.
    if q.id is not null then
      if q.outside_since is null then
        update public.airport_queue set outside_since = now() where id = q.id;
      elsif q.outside_since <= now() - make_interval(mins => coalesce(
              (select leave_grace_min from public.airport_settings where airport_id = q.airport_id), 3)) then
        delete from public.airport_queue where id = q.id;
      end if;
    end if;
    return;
  end if;

  if q.id is not null and q.airport_id = z.airport_id then
    if q.outside_since is not null then
      update public.airport_queue set outside_since = null where id = q.id;
    end if;
  else
    if q.id is not null then
      delete from public.airport_queue where id = q.id;
    end if;
    select * into c from public.airport_settings where airport_id = z.airport_id;
    -- The line is the vehicle's approved service; without one, no queue.
    v_service := public.driver_vehicle_service(p_driver);
    if c.airport_id is not null and v_service is not null then
      select * into d from public.airport_dropoffs
       where driver_id = p_driver and airport_id = z.airport_id and used_at is null
         and dropped_at > now() - make_interval(mins => c.join_window_min)
       order by dropped_at
       limit 1;
      if d.id is not null then
        insert into public.airport_queue (airport_id, driver_id, service, dropoff_id, place_at)
        values (z.airport_id, p_driver, v_service, d.id, d.dropped_at)
        on conflict (driver_id) do nothing;
        update public.airport_dropoffs set used_at = now() where id = d.id;
      elsif not c.need_dropoff then
        insert into public.airport_queue (airport_id, driver_id, service, place_at)
        values (z.airport_id, p_driver, v_service, now())
        on conflict (driver_id) do nothing;
      end if;
    end if;
  end if;

  -- Someone may now be offered a held pickup here.
  for v_ride in
    select r.id from public.ride_requests r
     where r.status = 'open' and r.airport_hold and r.airport_pickup_id = z.airport_id
     order by r.created_at
  loop
    perform public.airport_dispatch(v_ride);
  end loop;
end;
$$;
revoke execute on function public.airport_on_presence(uuid, boolean, float8, float8) from public, anon, authenticated;

create or replace function public.driver_presence_airport()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.airport_on_presence(new.profile_id, new.online, new.lat, new.lng);
  return new;
exception when others then
  raise warning 'airport queue for %: %', new.profile_id, sqlerrm;
  return new;
end;
$$;
revoke execute on function public.driver_presence_airport() from public, anon, authenticated;

drop trigger if exists trg_driver_presence_airport on public.driver_presence;
create trigger trg_driver_presence_airport
  after insert or update on public.driver_presence
  for each row execute function public.driver_presence_airport();

-- ---- 11. The tick: places lost, offers missed, nearby fallbacks -------------------------------------
create or replace function public.airport_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  n int := 0;
begin
  perform set_config('getride.airport_server', 'on', true);
  -- A driver no longer reporting (or offline) is outside.
  update public.airport_queue q set outside_since = now()
   where q.outside_since is null
     and not exists (select 1 from public.driver_presence d
                      where d.profile_id = q.driver_id and d.online and d.updated_at > now() - interval '3 minutes');
  delete from public.airport_queue q
   using public.airport_settings s
   where s.airport_id = q.airport_id and q.outside_since is not null
     and q.outside_since <= now() - make_interval(mins => s.leave_grace_min);
  for v_id in
    select id from public.ride_requests
     where status = 'open' and airport_hold and created_at > now() - interval '1 hour'
     order by created_at
  loop
    perform public.airport_dispatch(v_id);
    n := n + 1;
  end loop;
  delete from public.airport_dropoffs where dropped_at < now() - interval '2 days';
  return n;
end;
$$;
revoke execute on function public.airport_tick() from public, anon, authenticated;
grant execute on function public.airport_tick() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'airport-tick';
    begin
      perform cron.schedule('airport-tick', '20 seconds', $job$select public.airport_tick()$job$);
    exception when others then
      perform cron.schedule('airport-tick', '* * * * *', $job$select public.airport_tick()$job$);
    end;
  else
    raise notice 'pg_cron not available: call public.airport_tick() from a scheduled job.';
  end if;
end $$;

-- ---- 12. Held pickups are not pushed to everyone nearby ------------------------------------------
-- As 0161, with the airport hold first: airport_dispatch tells the drivers
-- it is offered to.
create or replace function public.notify_partners_on_ride_request()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  cfg      jsonb;
  v_raised boolean := tg_op = 'UPDATE';
  v_msg    jsonb;
  v_radius double precision;
  v_driver uuid;
  v_told   int := 0;
begin
  -- Only ever notify about requests that are still open (biddable).
  if new.status is distinct from 'open' then
    return new;
  end if;

  -- Held for the airport's waiting drivers (0249).
  if new.airport_hold then
    return new;
  end if;

  -- On UPDATE, fire only when the passenger raised their fare on the open row.
  if tg_op = 'UPDATE'
     and not (new.fare is distinct from old.fare
              and coalesce(new.fare, 0) > coalesce(old.fare, 0)) then
    return new;
  end if;

  -- Inside the favourites / direct window: the targeted drivers, wherever they are.
  if public.ride_request_targeting(new.target_driver_ids, new.targeted_until) then
    v_msg := public.ride_request_push_message(new.id, new.pickup_name, new.pickup_address, new.fare, new.currency,
                                              case when v_raised then 'raised'
                                                   when new.direct_driver_id is not null then 'direct'
                                                   else 'my_ride' end);
    if v_raised then
      foreach v_driver in array new.target_driver_ids loop
        continue when v_driver = new.rider_id;
        perform public.send_push_webhook(v_msg || jsonb_build_object('profileId', v_driver));
      end loop;
    else
      perform public.ride_request_push_targets(new.id, new.target_driver_ids, v_msg);
    end if;
    return new;
  end if;

  -- Open to all: the drivers near the pickup — the service's min radius,
  -- or its max once widened.
  cfg := public.vehicle_service_dispatch_config(new.service);
  v_radius := case when new.widened_pushed_at is not null
                   then (cfg->>'search_radius_max_km')::double precision
                   else (cfg->>'search_radius_min_km')::double precision end;
  v_msg := public.ride_request_push_message(new.id, new.pickup_name, new.pickup_address, new.fare, new.currency,
                                            case when v_raised then 'raised' else 'new' end);
  v_told := public.ride_request_push_nearby(new.id, new.rider_id, new.pickup_lat, new.pickup_lng, v_radius, v_msg,
                                            case when v_raised then 'raised' else 'nearby' end, false);

  -- Nobody known nearby: every driver, as before.
  if v_told = 0 then
    perform public.ride_request_push_everyone(new.id, v_msg, case when v_raised then 'raised' else 'everyone' end);
  end if;

  return new;
exception when others then
  -- Never let a notification failure block the ride request write.
  return new;
end;
$$;

-- As 0161, but a held airport pickup is not widened to drivers who can't see it.
create or replace function public.ride_requests_dispatch_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  n int := 0;
begin
  for v_id in
    select id from public.ride_requests
     where status = 'open'
       and created_at > now() - interval '15 minutes'
       and targeted_until is not null and targeted_until <= now()
       and fallback_pushed_at is null
       and direct_driver_id is null
       and not airport_hold
  loop
    if public.ride_request_open_to_all(v_id) >= 0 then
      n := n + 1;
    end if;
  end loop;

  for v_id in
    select id from public.ride_requests
     where status = 'open'
       and created_at > now() - interval '15 minutes'
       and widened_pushed_at is null
       and (targeted_until is null or fallback_pushed_at is not null)
       and not airport_hold
  loop
    if public.ride_request_widen(v_id) >= 0 then
      n := n + 1;
    end if;
  end loop;

  delete from public.ride_request_pushes where at < now() - interval '1 day';
  return n;
end;
$$;
revoke execute on function public.ride_requests_dispatch_tick() from public, anon, authenticated;
grant execute on function public.ride_requests_dispatch_tick() to service_role;

-- ---- 13. What the driver's app shows ------------------------------------------------------------
-- {state: outside | around | dropped | queued | offer | refused, ...}
create or replace function public.airport_driver_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  p public.driver_presence;
  q public.airport_queue;
  c public.airport_settings;
  d public.airport_dropoffs;
  a public.airport_areas;
  z record;
  o record;
  v_air uuid;
  v_pos int;
  v_total int;
  v_zones jsonb;
  v_sid text;
  v_sname text;
begin
  if v_uid is null then
    return jsonb_build_object('state', 'outside');
  end if;
  select * into p from public.driver_presence where profile_id = v_uid;
  v_sid := public.driver_vehicle_service(v_uid);
  select e.values->>'name' into v_sname from public.settings_entries e
   where e.category = 'vehicle-services' and e.id::text = v_sid;

  select o2.ride_id, r.pickup_door_name, r.pickup_name, r.service, r.airport_pickup_id, o2.stage, o2.until into o
    from public.airport_ride_offers o2
    join public.ride_requests r on r.id = o2.ride_id and r.status = 'open' and r.airport_hold
   where o2.driver_id = v_uid and o2.outcome is null and (o2.until is null or o2.until > now())
   order by o2.offered_at desc
   limit 1;
  if o.ride_id is not null then
    select * into a from public.airport_areas where id = o.airport_pickup_id;
    return jsonb_build_object('state', 'offer', 'ride_id', o.ride_id, 'door', coalesce(o.pickup_door_name, o.pickup_name),
                              'service', o.service, 'stage', o.stage, 'until', o.until,
                              'airport', a.values->>'name', 'code', a.values->>'code');
  end if;

  select * into q from public.airport_queue where driver_id = v_uid;
  if q.id is not null then
    select * into a from public.airport_areas where id = q.airport_id;
    select * into c from public.airport_settings where airport_id = q.airport_id;
    select count(*) filter (where l.place_at < q.place_at
                              or (l.place_at = q.place_at and (l.joined_at, l.driver_id) < (q.joined_at, q.driver_id))) + 1,
           count(*)
      into v_pos, v_total
      from public.airport_queue l
     where l.airport_id = q.airport_id and (not coalesce(c.queue_by_service, true) or l.service = q.service);
    return jsonb_build_object('state', 'queued', 'position', v_pos, 'total', v_total,
                              'service', case when coalesce(c.queue_by_service, true)
                                              then coalesce((select e.values->>'name' from public.settings_entries e
                                                              where e.id::text = q.service), '') else '' end,
                              'airport', a.values->>'name', 'code', a.values->>'code',
                              'outside_since', q.outside_since, 'grace_min', c.leave_grace_min);
  end if;

  if p.online and p.updated_at > now() - interval '3 minutes' then
    select * into z from public.airport_zone_at(p.lat, p.lng);
  end if;

  select * into d from public.airport_dropoffs
   where driver_id = v_uid and used_at is null
   order by dropped_at desc limit 1;
  if d.id is not null then
    select * into c from public.airport_settings where airport_id = d.airport_id;
    if d.dropped_at <= now() - make_interval(mins => coalesce(c.join_window_min, 60)) then
      d := null;
    end if;
  end if;

  v_air := coalesce(z.airport_id, d.airport_id);
  if v_air is null and p.online and p.updated_at > now() - interval '3 minutes' then
    v_air := public.airport_at(p.lat, p.lng);
  end if;
  if v_air is null then
    return jsonb_build_object('state', 'outside');
  end if;
  select * into a from public.airport_areas where id = v_air;
  select * into c from public.airport_settings where airport_id = v_air;
  select coalesce(jsonb_agg(w.name order by w.position), '[]'::jsonb) into v_zones
    from public.airport_waiting_zones w where w.airport_id = v_air;

  -- A vehicle without an approved service type can't join any queue.
  if v_sid is null and (z.airport_id is not null or (d.id is not null and d.airport_id = v_air)) then
    return jsonb_build_object('state', 'refused', 'reason', 'no_service',
                              'airport', a.values->>'name', 'code', a.values->>'code');
  end if;
  if z.airport_id is not null and (d.id is null or d.airport_id <> z.airport_id) and coalesce(c.need_dropoff, true) then
    return jsonb_build_object('state', 'refused', 'reason', 'no_dropoff',
                              'airport', a.values->>'name', 'code', a.values->>'code');
  end if;
  if d.id is not null and d.airport_id = v_air then
    return jsonb_build_object('state', 'dropped', 'airport', a.values->>'name', 'code', a.values->>'code',
                              'service', case when coalesce(c.queue_by_service, true) then coalesce(v_sname, '') else '' end,
                              'dropped_at', d.dropped_at, 'window_min', coalesce(c.join_window_min, 60),
                              'minutes_left', greatest(0, ceil(extract(epoch from
                                 d.dropped_at + make_interval(mins => coalesce(c.join_window_min, 60)) - now()) / 60)),
                              'zones', v_zones);
  end if;
  if coalesce(c.restrict_pickups, false) and z.airport_id is null then
    return jsonb_build_object('state', 'around', 'airport', a.values->>'name', 'code', a.values->>'code',
                              'zones', v_zones);
  end if;
  return jsonb_build_object('state', 'outside');
end;
$$;
revoke execute on function public.airport_driver_state() from public, anon;
grant execute on function public.airport_driver_state() to authenticated;

-- ---- 14. Guide photos -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('airport-guides', 'airport-guides', false)
on conflict (id) do update set public = false;

drop policy if exists "airport-guides read" on storage.objects;
create policy "airport-guides read" on storage.objects for select to authenticated
  using (bucket_id = 'airport-guides');
drop policy if exists "airport-guides admin insert" on storage.objects;
create policy "airport-guides admin insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'airport-guides' and (select public.caller_admin_can_write('storage:airport-guides')));
drop policy if exists "airport-guides admin update" on storage.objects;
create policy "airport-guides admin update" on storage.objects for update to authenticated
  using (bucket_id = 'airport-guides' and (select public.caller_admin_can_write('storage:airport-guides')))
  with check (bucket_id = 'airport-guides' and (select public.caller_admin_can_write('storage:airport-guides')));
drop policy if exists "airport-guides admin delete" on storage.objects;
create policy "airport-guides admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'airport-guides' and (select public.caller_admin_can_write('storage:airport-guides')));

-- ---- 15. Which admin pages write them -------------------------------------------------------------
insert into public.admin_table_pages (target, page) values
  ('airport_settings',        'admin-settings-airport-areas'),
  ('airport_waiting_zones',   'admin-settings-airport-areas'),
  ('airport_fare_zones',      'admin-settings-airport-areas'),
  ('vehicle_service_order',   'admin-settings-airport-areas'),
  ('vehicle_service_order',   'admin-settings-vehicle-services'),
  ('storage:airport-guides',  'admin-settings-airport-areas'),
  ('storage:airport-guides',  'admin-settings-multi-gate-place-gates')
on conflict do nothing;

-- ---- 16. Followed live by the apps ----------------------------------------------------------------
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['airport_settings', 'airport_waiting_zones', 'airport_fare_zones', 'vehicle_service_order'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
