-- ============================================================================
-- 0258 — Places get the airport tools: a boundary, doors, a pickup guide, an
-- extra charge, their own fares and a driver waiting queue, each optional.
--
-- Admin → Settings → Multi-Gate Places stays its own page; Airport Areas
-- stays its own page. Behind them, a place with its boundary switched on is
-- an "area" in the same tables and functions the airports use (0249):
--
-- 1. public.airport_areas gains kind ('airport' | 'place'). A place's row is
--    kept by the server from its multi_gate row (values.areaOn, the
--    boundary in values.boundary): same id as the place, place_id = the
--    place, its outline in shape and its size in size_m2. The boundary
--    switched off keeps the row (and every setting) but makes it inactive.
--    The app never writes a place's row; Airport Areas lists kind 'airport'.
--    Old apps read values.boundary only, which a place's row doesn't have,
--    so they keep treating places as before.
-- 2. airport_settings is the place's settings row too (made with the place
--    defaults: no door required, no guide, no own fares, no queue, no
--    charge). New switches, on for airports as before: guide_on (show the
--    pickup guide) and fares_on (own fares; off = the normal tariff).
-- 3. Doors are the place's existing gates (multi_gate kind 'gate',
--    values.placeId = the place): public.airport_doors lists them too.
-- 4. Where a point is (area_at, which airport_at now answers): an airport
--    first (as before, by position), else the smallest place boundary that
--    holds it. Places with no boundary are not areas and work as today.
-- 5. A trip's fare comes from one end (airport_fare_end): an airport end
--    first, then a place with its own fares, the pickup end first; the
--    charges of both ends are added as before. A place without its own
--    fares and without a charge leaves the fare alone.
-- 6. Waiting zones, the queue, offers, drop-offs, the hold and the tick are
--    the airports' own, keyed by the area: a place's queue works as an
--    airport's (restrict_pickups is its switch).
-- 7. Writes: the place's settings, zones and guide photos are written from
--    the Places page (target place_areas), an airport's from Airport Areas.
-- 8. Telematics counts a pickup at a place as its own kind of trip, not an
--    airport one; the driver's queue state says which kind it is.
-- ============================================================================

-- ---- 1. Areas: airports and places ------------------------------------------------------------------
alter table public.airport_areas
  add column if not exists kind     text not null default 'airport',
  add column if not exists place_id uuid references public.multi_gate(id) on delete cascade,
  add column if not exists shape    jsonb,
  add column if not exists size_m2  float8;
alter table public.airport_areas drop constraint if exists airport_areas_kind;
alter table public.airport_areas add constraint airport_areas_kind check (
  kind in ('airport', 'place')
  and (kind = 'place') = (place_id is not null)
  and (place_id is null or place_id = id)
  and (shape is null or pg_column_size(shape) <= 262144));
create unique index if not exists airport_areas_place_idx on public.airport_areas (place_id);
comment on column public.airport_areas.kind is
  'airport: an Airport Areas row; place: a multi-gate place with its boundary on, kept by the server (0258).';

alter table public.airport_settings
  add column if not exists guide_on boolean not null default true,
  add column if not exists fares_on boolean not null default true;
comment on column public.airport_settings.guide_on is 'Riders see the pickup doors'' guides (0258; places default off).';
comment on column public.airport_settings.fares_on is 'The area''s own fares apply; off = the normal tariff (0258; places default off).';

alter table public.multi_gate drop constraint if exists multi_gate_place_size;
alter table public.multi_gate add constraint multi_gate_place_size check (
  kind <> 'place' or pg_column_size(values) <= 262144) not valid;

-- What an area is: 'airport' | 'place' (null when unknown).
create or replace function public.airport_area_kind(p_area uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$ select kind from public.airport_areas where id = p_area; $$;
revoke execute on function public.airport_area_kind(uuid) from public, anon;
grant execute on function public.airport_area_kind(uuid) to authenticated, service_role;

-- The size of a boundary's rings in square metres (flat earth near each
-- ring: plenty to tell the smaller of two places).
create or replace function public.airport_rings_m2(p_rings jsonb)
returns float8
language plpgsql
immutable
set search_path = public
as $$
declare
  r jsonb;
  n int;
  i int;
  j int;
  lat0 float8;
  acc float8;
  total float8 := 0;
  kx float8;
begin
  if jsonb_typeof(p_rings) is distinct from 'array' then
    return null;
  end if;
  for r in select value from jsonb_array_elements(p_rings) loop
    n := jsonb_array_length(r);
    continue when n < 3;
    lat0 := (r->0->>'latitude')::float8;
    kx := 111320 * cos(radians(lat0));
    acc := 0;
    j := n - 1;
    for i in 0 .. n - 1 loop
      acc := acc + ((r->j->>'longitude')::float8 * kx) * ((r->i->>'latitude')::float8 * 110540)
                 - ((r->i->>'longitude')::float8 * kx) * ((r->j->>'latitude')::float8 * 110540);
      j := i;
    end loop;
    total := total + abs(acc) / 2;
  end loop;
  return total;
exception when others then
  return null;
end;
$$;

-- A place's area row follows its multi_gate row: on with its boundary,
-- inactive without (its settings are kept for when it comes back).
create or replace function public.multi_gate_place_area()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := new.values;
  b jsonb := new.values->'boundary';
  rings jsonb;
  v_on boolean;
  v_active boolean;
begin
  if new.kind <> 'place' then
    return new;
  end if;
  rings := public.airport_rings(b);
  v_on := lower(coalesce(v->>'areaOn', 'false')) in ('true', '1', 'yes', 'on') and jsonb_array_length(rings) > 0;
  v_active := new.active and lower(coalesce(v->>'active', 'true')) not in ('false', '0', 'no', 'off');
  if v_on then
    insert into public.airport_areas (id, kind, place_id, values, position, active, shape, size_m2)
    values (new.id, 'place', new.id,
            jsonb_build_object('name', coalesce(nullif(btrim(v->>'name'), ''), 'Place')),
            new.position, v_active, b, public.airport_rings_m2(rings))
    on conflict (id) do update
      set values = excluded.values, position = excluded.position, active = excluded.active,
          shape = excluded.shape, size_m2 = excluded.size_m2, updated_at = now()
      where public.airport_areas.kind = 'place';
  else
    update public.airport_areas set active = false, updated_at = now()
     where id = new.id and kind = 'place' and active;
  end if;
  return new;
end;
$$;
revoke execute on function public.multi_gate_place_area() from public, anon, authenticated;
drop trigger if exists trg_multi_gate_place_area on public.multi_gate;
create trigger trg_multi_gate_place_area after insert or update on public.multi_gate
  for each row execute function public.multi_gate_place_area();

-- The app writes airports only: a row it adds is an airport, and a place's
-- row (kept above) is not changed or removed from Airport Areas. Server
-- steps (the place trigger, a place's delete cascading) run inside a
-- trigger and pass.
create or replace function public.airport_areas_kind_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated') or pg_trigger_depth() > 1 then
    return case when tg_op = 'DELETE' then old else new end;
  end if;
  if tg_op = 'INSERT' then
    new.kind := 'airport';
    new.place_id := null;
    new.shape := null;
    new.size_m2 := null;
    return new;
  end if;
  if old.kind = 'place' then
    raise exception 'PLACE_AREA_MANAGED' using errcode = '42501',
      hint = 'A place''s area is changed from the Places page.';
  end if;
  if tg_op = 'UPDATE' then
    new.kind := old.kind;
    new.place_id := old.place_id;
    new.shape := old.shape;
    new.size_m2 := old.size_m2;
    return new;
  end if;
  return old;
end;
$$;
revoke execute on function public.airport_areas_kind_guard() from public, anon, authenticated;
drop trigger if exists trg_airport_areas_kind_guard on public.airport_areas;
create trigger trg_airport_areas_kind_guard before insert or update or delete on public.airport_areas
  for each row execute function public.airport_areas_kind_guard();

-- Every area has its settings row: an airport with the airport defaults (as
-- 0249), a place with every tool off.
create or replace function public.airport_areas_settings_row()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.kind = 'place' then
    insert into public.airport_settings (airport_id, drop_door_required, pick_door_required, guide_on, fares_on,
                                         drop_fee_name, pick_fee_name, fares)
    values (new.id, false, false, false, false, 'Place fee', 'Place fee', '{"roundUp": false}'::jsonb)
    on conflict do nothing;
  else
    insert into public.airport_settings (airport_id) values (new.id) on conflict do nothing;
  end if;
  return new;
end;
$$;
revoke execute on function public.airport_areas_settings_row() from public, anon, authenticated;

-- ---- 2. Doors: an airport's gates and a place's gates -------------------------------------------
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
   -- A multi-gate place's gate has no parentKey, or 'multi-gate-places'.
   and coalesce(nullif(g.values->>'parentKey', ''), 'multi-gate-places') in ('airport-areas', 'multi-gate-places')
   and g.values->>'placeId' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
grant select on public.airport_doors to authenticated, service_role;

-- ---- 3. Where a point is ----------------------------------------------------------------------------
-- The area holding a point: an airport first (the first by position, as
-- 0249), else the smallest place boundary holding it.
create or replace function public.area_at(p_lat float8, p_lng float8)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select a.id
    from public.airport_areas a
   where a.active and p_lat is not null and p_lng is not null
     and public.airport_in_rings(p_lat, p_lng,
           public.airport_rings(case when a.kind = 'place' then a.shape else a.values->'boundary' end))
   order by (a.kind <> 'airport'),
            case when a.kind = 'place' then coalesce(a.size_m2, 'infinity'::float8) else 0 end,
            a.position, a.created_at
   limit 1;
$$;
revoke execute on function public.area_at(float8, float8) from public, anon;
grant execute on function public.area_at(float8, float8) to authenticated, service_role;

-- Every caller of 0249's airport_at (the ride trigger, the fare quote, the
-- scheduled doors, the driver's state) now works for places too.
create or replace function public.airport_at(p_lat float8, p_lng float8)
returns uuid
language sql
stable
security definer
set search_path = public
as $$ select public.area_at(p_lat, p_lng); $$;

-- The waiting zone (and its area) a point is in: an airport's first.
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
   order by (a.kind <> 'airport'), a.position, z.position, z.created_at
   limit 1;
$$;

-- ---- 4. Fares ---------------------------------------------------------------------------------------
-- Which end of a trip prices it: 'from' (the pickup's area) or 'to' (the
-- drop-off's), null when neither is in one. An airport end first (pickup
-- first, as 0249), then a place with its own fares, then either end (for
-- its charges only).
create or replace function public.airport_fare_end(p_pick uuid, p_drop uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  kp text := public.airport_area_kind(p_pick);
  kd text := public.airport_area_kind(p_drop);
begin
  if p_pick is not null and coalesce(kp, 'airport') = 'airport' then
    return 'from';
  elsif p_drop is not null and coalesce(kd, 'airport') = 'airport' then
    return 'to';
  elsif p_pick is not null and coalesce((select fares_on from public.airport_settings where airport_id = p_pick), false) then
    return 'from';
  elsif p_drop is not null and coalesce((select fares_on from public.airport_settings where airport_id = p_drop), false) then
    return 'to';
  elsif p_pick is not null then
    return 'from';
  elsif p_drop is not null then
    return 'to';
  end if;
  return null;
end;
$$;
revoke execute on function public.airport_fare_end(uuid, uuid) from public, anon, authenticated;

-- The area's fare (0249's airport_quote): a place without its own fares
-- prices the normal fare, with its charges; the labels name the place.
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
  v_noun  text;
begin
  select * into c from public.airport_settings where airport_id = p_airport;
  if not found then
    return null;
  end if;
  v_noun := case when public.airport_area_kind(p_airport) = 'place' then 'place' else 'airport' end;
  f := c.fares;
  -- A place without its own fares (0258): the normal fare, not rounded,
  -- with the charges on top; nothing at all without a charge either.
  if not c.fares_on then
    if coalesce(case when jsonb_typeof(p_charges) = 'array' then jsonb_array_length(p_charges) end, 0) = 0 then
      return null;
    end if;
    f := '{"roundUp": false}'::jsonb;
  else
    select * into z from public.airport_fare_zones
     where airport_id = p_airport
       and public.airport_in_rings(p_other_lat, p_other_lng, public.airport_rings(shape))
     order by position, created_at
     limit 1;
  end if;
  if z.id is not null then
    v_ride := case when p_dir = 'from' then z.from_amount else z.to_amount end;
    v_how := format('Fixed fare, %s %s the %s', z.name, case when p_dir = 'from' then 'from' else 'to' end, v_noun);
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
      'label', format('%s %s base', coalesce(nullif(p_service, ''), 'Ride'), v_noun), 'amount', v_base));
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

-- As 0249, with the end that prices the trip from airport_fare_end.
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
  v_end text := public.airport_fare_end(v_pa, v_da);
begin
  if v_pa is null and v_da is null then
    return null;
  end if;
  -- [p_normal] is the fare as the app books it (with the option charges in
  -- it, as 0248 has them); the airport fare works on the route fare.
  return public.airport_quote(
    case when v_end = 'from' then v_pa else v_da end, v_end, p_service, p_km,
    greatest(0, coalesce(p_normal, 0) - public.ride_option_charges_total(p_option_charges)),
    public.airport_per_km(p_service, p_country, p_state, p_city, p_suburb),
    case when v_end = 'from' then p_drop_lat else p_pickup_lat end,
    case when v_end = 'from' then p_drop_lng else p_pickup_lng end,
    public.airport_ride_charges(v_pa, v_da), p_option_charges);
end;
$$;

-- ---- 6. The ride trigger (0249's), the fare end from airport_fare_end ------------------------------
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
  v_end text;
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
        -- Which end's fares (0258): an airport's before a place's, a place's
        -- own fares before one without; the pickup end first.
        v_end := public.airport_fare_end(new.airport_pickup_id, new.airport_drop_id);
        v_quote := public.airport_quote(
          case when v_end = 'from' then new.airport_pickup_id else new.airport_drop_id end,
          v_end,
          new.service, new.distance_km,
          -- The route fare: the app's fare has the option charges in it (0248).
          greatest(0, coalesce(new.ride_fare, new.fare, 0) - public.ride_option_charges_total(new.option_charges)),
          public.airport_per_km(new.service, new.country, new.state, new.city, new.suburb),
          case when v_end = 'from' then new.drop_lat else new.pickup_lat end,
          case when v_end = 'from' then new.drop_lng else new.pickup_lng end,
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

-- ---- 5. Dispatch: the push names the place ----------------------------------------------------------
create or replace function public.airport_push(p_driver uuid, p_ride public.ride_requests)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place boolean := public.airport_area_kind(p_ride.airport_pickup_id) = 'place';
begin
  perform public.send_push_webhook(jsonb_build_object(
    'title', case when v_place then 'Queue order' else 'Airport order' end,
    'body', 'Pickup at ' || coalesce(nullif(p_ride.pickup_door_name, ''), nullif(p_ride.pickup_name, ''),
                                     nullif(p_ride.pickup_address, ''),
                                     case when v_place then 'the place' else 'the airport' end),
    'profileId', p_driver,
    'data', jsonb_build_object('type', 'ride_request', 'ride_request_id', p_ride.id, 'airport', true)));
exception when others then
  null; -- a push never holds dispatch up
end;
$$;
revoke execute on function public.airport_push(uuid, public.ride_requests) from public, anon, authenticated;

-- ---- 7. What the driver's app shows (0249's), with the area's kind --------------------------------
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
                              'airport', a.values->>'name', 'kind', coalesce(a.kind, 'airport'), 'code', a.values->>'code');
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
                              'airport', a.values->>'name', 'kind', coalesce(a.kind, 'airport'), 'code', a.values->>'code',
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
                              'airport', a.values->>'name', 'kind', coalesce(a.kind, 'airport'), 'code', a.values->>'code');
  end if;
  if z.airport_id is not null and (d.id is null or d.airport_id <> z.airport_id) and coalesce(c.need_dropoff, true) then
    return jsonb_build_object('state', 'refused', 'reason', 'no_dropoff',
                              'airport', a.values->>'name', 'kind', coalesce(a.kind, 'airport'), 'code', a.values->>'code');
  end if;
  if d.id is not null and d.airport_id = v_air then
    return jsonb_build_object('state', 'dropped', 'airport', a.values->>'name', 'kind', coalesce(a.kind, 'airport'), 'code', a.values->>'code',
                              'service', case when coalesce(c.queue_by_service, true) then coalesce(v_sname, '') else '' end,
                              'dropped_at', d.dropped_at, 'window_min', coalesce(c.join_window_min, 60),
                              'minutes_left', greatest(0, ceil(extract(epoch from
                                 d.dropped_at + make_interval(mins => coalesce(c.join_window_min, 60)) - now()) / 60)),
                              'zones', v_zones);
  end if;
  if coalesce(c.restrict_pickups, false) and z.airport_id is null then
    return jsonb_build_object('state', 'around', 'airport', a.values->>'name', 'kind', coalesce(a.kind, 'airport'), 'code', a.values->>'code',
                              'zones', v_zones);
  end if;
  return jsonb_build_object('state', 'outside');
end;
$$;
revoke execute on function public.airport_driver_state() from public, anon;
grant execute on function public.airport_driver_state() to authenticated;

-- ---- 8. Telematics: a place's pickup isn't an airport trip ----------------------------------------
create or replace function public.telematics_trip_kind(
  p_stand_kind text, p_stand_id uuid, p_airport_pickup uuid, p_scheduled uuid,
  p_target_drivers uuid[], p_direct_driver uuid, p_direct_token text, p_service text)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_stand_kind = 'call_centre' then 'call_centre'
    when p_stand_id is not null then 'stand'
    when p_airport_pickup is not null
         and coalesce((select a.kind from public.airport_areas a where a.id = p_airport_pickup), 'airport') = 'airport'
      then 'airport'
    when p_scheduled is not null then 'scheduled'
    when p_direct_driver is not null or nullif(btrim(coalesce(p_direct_token, '')), '') is not null
      or coalesce(cardinality(p_target_drivers), 0) > 0 then 'my_ride'
    else 'service:' || coalesce(nullif(btrim(p_service), ''), 'Ride')
  end
$$;
revoke execute on function public.telematics_trip_kind(text, uuid, uuid, uuid, uuid[], uuid, text, text) from public, anon;
grant execute on function public.telematics_trip_kind(text, uuid, uuid, uuid, uuid[], uuid, text, text)
  to authenticated, service_role;

-- ---- 9. Who writes an area's settings: Airport Areas an airport's, Places a place's ---------------
do $$
declare
  t text;
  w text;
begin
  foreach t in array array['airport_settings', 'airport_waiting_zones', 'airport_fare_zones'] loop
    w := format('((select public.caller_admin_can_write(%L)) and public.airport_area_kind(airport_id) = ''airport'')'
                ' or ((select public.caller_admin_can_write(''place_areas'')) and public.airport_area_kind(airport_id) = ''place'')',
                t);
    execute format('drop policy if exists %I on public.%I', t || ' admin insert', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (%s)', t || ' admin insert', t, w);
    execute format('drop policy if exists %I on public.%I', t || ' admin update', t);
    execute format('create policy %I on public.%I for update to authenticated using (%s) with check (%s)',
                   t || ' admin update', t, w, w);
    execute format('drop policy if exists %I on public.%I', t || ' admin delete', t);
    execute format('create policy %I on public.%I for delete to authenticated using (%s)', t || ' admin delete', t, w);
  end loop;
end $$;

insert into public.admin_table_pages (target, page) values
  ('place_areas',            'admin-settings-multi-gate-places'),
  ('storage:airport-guides', 'admin-settings-multi-gate-places')
on conflict do nothing;

notify pgrst, 'reload schema';
