-- ============================================================================
-- 0324 — Place fees: a list of pickup / drop-off fees for each fenced place.
--
-- Until now an airport (or a Multi-Gate place with its boundary on, 0258)
-- had one fixed pickup charge and one fixed drop-off charge
-- (airport_settings.pick_fee_* / drop_fee_*, 0249). Each area now has a
-- list of fees, every value set in the admin (Airport Areas → Fees, and a
-- place's Fees tab on Multi-Gate Places):
--
-- 1. public.place_fees: per area (airport_areas, kind 'airport' or
--    'place') — name and rider note (what riders see), which end it is for
--    (pickup, dropoff, either end charged once, each end), a fixed amount or
--    a percentage of the fare with an optional least and most, the vehicle
--    services it is for (none = every service, as ride_requests.service
--    names them), days of the week, a time window (one past midnight wraps),
--    a date range, whether a stop inside the area counts like a drop-off,
--    and who gets it: the driver (an earning, in the commission base), the
--    platform (taken back from the driver's GET credit as 0189's platform
--    fees are) or passed on (neither, as the old airport charge). Admins
--    with Airport Areas (an airport's) or Multi-Gate Places (a place's) edit
--    them; riders never read the table, they get the server's answer.
--    The old pickup / drop-off charges become fees here once; their columns
--    stay but nothing reads them any more.
-- 2. app_settings 'place_fees' (place_fees_config / set_place_fees_config):
--    lock the fee of a ride booked for later (default on), the time zone the
--    days and hours are read in, what a percentage is of, whether the app
--    shows the map label, the address hint and the vehicle card badge, their
--    texts, and the most all place fees may add to one ride.
-- 3. place_ride_charges: the fees for a trip, as ride_requests.charges
--    entries ({kind: surcharge, charge: fixed, name, value, airport: pick |
--    drop | stop | once, place_fee, area, goes_to, note, platform | earning}).
--    The `airport` key keeps 0249's rule: the ride trigger drops a client's
--    entries that have it, so fees can't be forged. airport_ride_charges now
--    answers from it.
-- 4. The ride trigger (0264's ride_requests_airport) stamps them with the
--    ride's service, stops and route fare. A scheduled booking works its fees
--    out for the pickup time and keeps them (locked: true, and
--    scheduled_rides.place_fees_locked); its release charges those, so the
--    rider pays what they saw.
-- 5. place_fees_quote: the same lines for the app before booking (and the
--    pickup's and drop-off's fees, and the display settings), and
--    airport_fare_quote adds them to the airport fare as before.
-- 6. Partner statements count a driver's place fee as an earning
--    (statement_ride_lines) and the commission base includes it
--    (commission_base), as a ticked surcharge.
-- ============================================================================

-- ---- 1. The fees ------------------------------------------------------------------------------------
create table if not exists public.place_fees (
  id          uuid primary key default gen_random_uuid(),
  area_id     uuid not null references public.airport_areas(id) on delete cascade,
  enabled     boolean not null default true,
  sort_order  integer not null default 0,
  name        text not null,
  rider_note  text not null default '',
  applies_to  text not null default 'pickup',
  amount_kind text not null default 'fixed',
  amount      numeric(10, 2) not null default 0,
  min_amount  numeric(10, 2),
  max_amount  numeric(10, 2),
  services    text[] not null default '{}',
  days        smallint[] not null default '{0,1,2,3,4,5,6}',
  time_from   time,
  time_to     time,
  date_from   date,
  date_to     date,
  count_stops boolean not null default false,
  goes_to     text not null default 'pass',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint place_fees_name check (char_length(btrim(name)) between 1 and 60 and char_length(name) <= 60),
  constraint place_fees_note check (char_length(rider_note) <= 240),
  constraint place_fees_applies check (applies_to in ('pickup', 'dropoff', 'either', 'each')),
  constraint place_fees_kind check (amount_kind in ('fixed', 'percent')),
  constraint place_fees_amount check (
    amount >= 0 and amount <= case when amount_kind = 'percent' then 100 else 1000 end),
  constraint place_fees_limits check (
    (min_amount is null or min_amount between 0 and 1000)
    and (max_amount is null or max_amount between 0 and 1000)
    and (min_amount is null or max_amount is null or min_amount <= max_amount)),
  constraint place_fees_services check (
    cardinality(services) <= 50 and array_position(services, null) is null),
  constraint place_fees_days check (
    cardinality(days) between 1 and 7 and days <@ array[0, 1, 2, 3, 4, 5, 6]::smallint[]),
  constraint place_fees_dates check (date_from is null or date_to is null or date_from <= date_to),
  constraint place_fees_goes_to check (goes_to in ('driver', 'platform', 'pass')),
  constraint place_fees_sort check (sort_order between -100000 and 100000)
);
create index if not exists place_fees_area_idx on public.place_fees (area_id, sort_order);
comment on table public.place_fees is
  'Pickup / drop-off fees of a fenced place (airport_areas), as many as the admin sets (0324).';
comment on column public.place_fees.services is
  'Vehicle services (as ride_requests.service names them) the fee is for; empty = every service.';
comment on column public.place_fees.days is '0 = Sunday. With a time window past midnight, the day it starts.';

drop trigger if exists trg_place_fees_updated_at on public.place_fees;
create trigger trg_place_fees_updated_at before update on public.place_fees
  for each row execute function public.set_updated_at();

alter table public.place_fees enable row level security;
revoke all on public.place_fees from anon;
grant select, insert, update, delete on public.place_fees to authenticated;

drop policy if exists "place_fees admin read" on public.place_fees;
create policy "place_fees admin read" on public.place_fees for select to authenticated
  using ((select public.caller_is_admin()));
-- An airport's fees from Airport Areas, a place's from Multi-Gate Places (as 0258's settings).
do $$
declare
  w text := '((select public.caller_admin_can_write(''place_fees'')) and public.airport_area_kind(area_id) = ''airport'')'
            ' or ((select public.caller_admin_can_write(''place_areas'')) and public.airport_area_kind(area_id) = ''place'')';
begin
  execute 'drop policy if exists "place_fees admin insert" on public.place_fees';
  execute format('create policy "place_fees admin insert" on public.place_fees for insert to authenticated with check (%s)', w);
  execute 'drop policy if exists "place_fees admin update" on public.place_fees';
  execute format('create policy "place_fees admin update" on public.place_fees for update to authenticated using (%s) with check (%s)', w, w);
  execute 'drop policy if exists "place_fees admin delete" on public.place_fees';
  execute format('create policy "place_fees admin delete" on public.place_fees for delete to authenticated using (%s)', w);
end $$;

insert into public.admin_table_pages (target, page) values
  ('place_fees',                  'admin-settings-airport-areas'),
  ('rpc:set_place_fees_config',   'admin-settings-airport-areas'),
  ('rpc:set_place_fees_config',   'admin-settings-multi-gate-places')
on conflict do nothing;

-- The old pickup / drop-off charges become fees, once: on the first run
-- (before the settings row below exists), and never twice for the same
-- area, end and name.
do $$
begin
  if not exists (select 1 from public.app_settings where key = 'place_fees') then
    insert into public.place_fees (area_id, name, applies_to, amount_kind, amount, sort_order)
    select s.airport_id, btrim(s.drop_fee_name), 'dropoff', 'fixed', s.drop_fee_amount, 0
      from public.airport_settings s
      join public.airport_areas a on a.id = s.airport_id
     where s.drop_fee_on and s.drop_fee_amount > 0 and btrim(s.drop_fee_name) <> ''
       and not exists (select 1 from public.place_fees f
                        where f.area_id = s.airport_id and f.applies_to = 'dropoff' and f.name = btrim(s.drop_fee_name));
    insert into public.place_fees (area_id, name, applies_to, amount_kind, amount, sort_order)
    select s.airport_id, btrim(s.pick_fee_name), 'pickup', 'fixed', s.pick_fee_amount, 1
      from public.airport_settings s
      join public.airport_areas a on a.id = s.airport_id
     where s.pick_fee_on and s.pick_fee_amount > 0 and btrim(s.pick_fee_name) <> ''
       and not exists (select 1 from public.place_fees f
                        where f.area_id = s.airport_id and f.applies_to = 'pickup' and f.name = btrim(s.pick_fee_name));
  end if;
end $$;
comment on column public.airport_settings.pick_fee_on is 'Unused since 0324 (place_fees).';
comment on column public.airport_settings.drop_fee_on is 'Unused since 0324 (place_fees).';

-- ---- 2. Settings --------------------------------------------------------------------------------------
insert into public.app_settings (key, value)
values ('place_fees', jsonb_build_object(
  'lockScheduled', true, 'timeZone', 'Asia/Kuala_Lumpur', 'percentOf', 'fare',
  'showMapLabel', true, 'showAddressHint', true, 'showCardBadge', true,
  'badgeText', 'incl. place fee', 'addressHintText', '{name} {amount} applies here', 'maxTotal', null))
on conflict (key) do nothing;

-- The settings with every key, each a sensible value (a missing or wrong
-- one takes its default).
create or replace function public.place_fees_normalize(v jsonb)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  tz text := coalesce(nullif(btrim(v->>'timeZone'), ''), 'Asia/Kuala_Lumpur');
  cap numeric := case when jsonb_typeof(v->'maxTotal') = 'number' then (v->>'maxTotal')::numeric end;
  badge text := btrim(coalesce(v->>'badgeText', ''));
  hint text := btrim(coalesce(v->>'addressHintText', ''));
  bool_of jsonb := jsonb_build_object();
  k text;
begin
  begin
    perform now() at time zone tz;
  exception when others then
    tz := 'Asia/Kuala_Lumpur';
  end;
  foreach k in array array['lockScheduled', 'showMapLabel', 'showAddressHint', 'showCardBadge'] loop
    bool_of := bool_of || jsonb_build_object(k, case when jsonb_typeof(v->k) = 'boolean' then (v->>k)::boolean else true end);
  end loop;
  return bool_of || jsonb_build_object(
    'timeZone', tz,
    'percentOf', 'fare',
    'badgeText', case when char_length(badge) between 1 and 40 then badge else 'incl. place fee' end,
    'addressHintText', case when char_length(hint) between 1 and 120 then hint else '{name} {amount} applies here' end,
    'maxTotal', case when cap between 0 and 10000 then round(cap, 2) end);
end;
$$;
revoke execute on function public.place_fees_normalize(jsonb) from public, anon, authenticated;

create or replace function public.place_fees_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.place_fees_normalize(coalesce((select value from public.app_settings where key = 'place_fees'), '{}'::jsonb));
$$;
revoke execute on function public.place_fees_config() from public, anon;
grant execute on function public.place_fees_config() to authenticated, service_role;

-- Admin → Airport Areas → Place fee settings (and Multi-Gate Places).
create or replace function public.set_place_fees_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.caller_admin_can_write('rpc:set_place_fees_config') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You can''t change the place fee settings.';
  end if;
  if jsonb_typeof(p_config) is distinct from 'object' then
    raise exception 'PLACE_FEES_CONFIG_INVALID' using errcode = '22023';
  end if;
  v := public.place_fees_normalize(p_config);
  insert into public.app_settings (key, value, updated_at) values ('place_fees', v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return v;
end;
$$;
revoke execute on function public.set_place_fees_config(jsonb) from public, anon;
grant execute on function public.set_place_fees_config(jsonb) to authenticated;

-- ---- 3. The fees of a trip ----------------------------------------------------------------------------
-- The areas a trip's stops ([{name, address, lat, lng}], 0098) are in, in
-- order; a stop outside every area is left out.
create or replace function public.place_stop_areas(p_stops jsonb)
returns uuid[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(x.area order by x.n), '{}'::uuid[])
    from (select n, public.airport_at(public.airport_num(s->'lat')::float8, public.airport_num(s->'lng')::float8) as area
            from jsonb_array_elements(case when jsonb_typeof(p_stops) = 'array' then p_stops else '[]'::jsonb end)
                 with ordinality t(s, n)
           where n <= 10 and jsonb_typeof(s) = 'object') x
   where x.area is not null;
$$;
revoke execute on function public.place_stop_areas(jsonb) from public, anon, authenticated;

-- The fees for a trip from [p_pick_area] to [p_drop_area] by way of
-- [p_stop_areas], on [p_service], with a route fare of [p_fare] (what a
-- percentage is of), at [p_at]. A fee counts when it is on, for the service,
-- and its days, hours and dates hold at [p_at] in the settings' time zone.
--   pickup  one line when the pickup is in its area;
--   dropoff one when the drop-off is, and one per stop in it with count_stops;
--   each    the pickup's line and the drop-off's (and the stops');
--   either  one line when any end (or, with count_stops, a stop) is in it.
-- A percentage is of [p_fare], then raised to its least and cut to its most.
-- At most 10 lines; then the settings' maxTotal caps their sum (the last
-- lines are cut down, then left out).
create or replace function public.place_ride_charges(p_pick_area uuid, p_drop_area uuid, p_stop_areas uuid[],
                                                     p_service text, p_fare numeric, p_at timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  cfg     jsonb := public.place_fees_config();
  v_local timestamp := coalesce(p_at, now()) at time zone (cfg->>'timeZone');
  v_time  time := v_local::time;
  v_date  date := v_local::date;
  v_dow   int := extract(dow from v_local)::int;
  v_fare  numeric := greatest(0, coalesce(p_fare, 0));
  v_stops uuid[] := coalesce(p_stop_areas, '{}'::uuid[]);
  v_areas uuid[] := array_remove(array[p_pick_area, p_drop_area] || coalesce(p_stop_areas, '{}'::uuid[]), null);
  v_cap   numeric := public.airport_num(cfg->'maxTotal');
  f       public.place_fees;
  v_day   int;
  v_amt   numeric;
  v_n     int;
  v_ends  text[];
  e       text;
  v_entry jsonb;
  v_sum   numeric := 0;
  out     jsonb := '[]'::jsonb;
  capped  jsonb := '[]'::jsonb;
begin
  if cardinality(v_areas) = 0 then
    return out;
  end if;
  for f in
    select * from public.place_fees
     where area_id = any(v_areas) and enabled
     order by sort_order, created_at, id
  loop
    exit when jsonb_array_length(out) >= 10;
    -- The service.
    continue when cardinality(f.services) > 0
      and not exists (select 1 from unnest(f.services) s
                       where lower(btrim(s)) = lower(btrim(coalesce(p_service, ''))));
    -- The dates.
    continue when (f.date_from is not null and v_date < f.date_from) or (f.date_to is not null and v_date > f.date_to);
    -- The hours and the day (past midnight, the day the window started).
    v_day := v_dow;
    if f.time_from is not null and f.time_to is not null and f.time_from <> f.time_to then
      if f.time_from < f.time_to then
        continue when not (v_time >= f.time_from and v_time < f.time_to);
      elsif v_time < f.time_to then
        v_day := (v_dow + 6) % 7;
      else
        continue when v_time < f.time_from;
      end if;
    end if;
    continue when not (v_day = any(f.days));

    v_amt := case when f.amount_kind = 'percent' then round(v_fare * f.amount / 100, 2) else round(f.amount, 2) end;
    if f.amount_kind = 'percent' then
      v_amt := greatest(v_amt, coalesce(round(f.min_amount, 2), v_amt));
      v_amt := least(v_amt, coalesce(round(f.max_amount, 2), v_amt));
    end if;
    continue when v_amt <= 0;

    v_n := coalesce(cardinality(array_positions(v_stops, f.area_id)), 0);
    v_ends := '{}'::text[];
    if f.applies_to = 'either' then
      if p_pick_area = f.area_id or p_drop_area = f.area_id or (f.count_stops and v_n > 0) then
        v_ends := array['once'];
      end if;
    else
      if f.applies_to in ('pickup', 'each') and p_pick_area = f.area_id then
        v_ends := v_ends || 'pick'::text;
      end if;
      if f.applies_to in ('dropoff', 'each') then
        if f.count_stops and v_n > 0 then
          v_ends := v_ends || array_fill('stop'::text, array[v_n]);
        end if;
        if p_drop_area = f.area_id then
          v_ends := v_ends || 'drop'::text;
        end if;
      end if;
    end if;

    foreach e in array v_ends loop
      exit when jsonb_array_length(out) >= 10;
      out := out || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
        'kind', 'surcharge', 'charge', 'fixed', 'name', btrim(f.name), 'value', v_amt,
        'airport', e, 'place_fee', f.id, 'area', f.area_id, 'goes_to', f.goes_to,
        'note', nullif(btrim(f.rider_note), ''),
        'platform', case when f.goes_to = 'platform' then true end,
        'earning', case when f.goes_to = 'driver' then true end)));
    end loop;
  end loop;

  if v_cap is not null then
    for v_entry in select value from jsonb_array_elements(out) loop
      exit when v_sum >= v_cap;
      v_amt := round(least((v_entry->>'value')::numeric, v_cap - v_sum), 2);
      exit when v_amt <= 0;
      v_sum := v_sum + v_amt;
      capped := capped || jsonb_build_array(jsonb_set(v_entry, '{value}', to_jsonb(v_amt)));
    end loop;
    out := capped;
  end if;
  return out;
end;
$$;
revoke execute on function public.place_ride_charges(uuid, uuid, uuid[], text, numeric, timestamptz)
  from public, anon, authenticated;

-- [p_fees] as they fit beside [p_rest] in ride_requests.charges (0122: at
-- most 20 entries and 8 KB): the rider notes go first, then the last fees.
create or replace function public.place_fees_fit(p_rest jsonb, p_fees jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_rest jsonb := case when jsonb_typeof(p_rest) = 'array' then p_rest else '[]'::jsonb end;
  v_fees jsonb := case when jsonb_typeof(p_fees) = 'array' then p_fees else '[]'::jsonb end;
begin
  while jsonb_array_length(v_fees) > 0 and jsonb_array_length(v_rest) + jsonb_array_length(v_fees) > 20 loop
    v_fees := v_fees - (jsonb_array_length(v_fees) - 1);
  end loop;
  if pg_column_size(v_rest || v_fees) > 7800 then
    select coalesce(jsonb_agg(e - 'note' order by n), '[]'::jsonb) into v_fees
      from jsonb_array_elements(v_fees) with ordinality t(e, n);
  end if;
  while jsonb_array_length(v_fees) > 0 and pg_column_size(v_rest || v_fees) > 7800 loop
    v_fees := v_fees - (jsonb_array_length(v_fees) - 1);
  end loop;
  return v_fees;
end;
$$;

-- 0249's airport charges for any old caller: the place fees of the two ends, now.
create or replace function public.airport_ride_charges(p_pickup_airport uuid, p_drop_airport uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.place_ride_charges(p_pickup_airport, p_drop_airport, null, null, null, now());
$$;
revoke execute on function public.airport_ride_charges(uuid, uuid) from public, anon, authenticated;

-- ---- 4. Booked for later: the fees are locked at booking ------------------------------------------
alter table public.scheduled_rides add column if not exists place_fees_locked boolean not null default false;
comment on column public.scheduled_rides.place_fees_locked is
  'The place fees in request.charges (locked: true) were worked out for the pickup time when it was booked, and are charged at release (0324).';

-- A booking keeps no place fee the app sent; with lockScheduled on, the
-- server's for the pickup time are added (locked: true).
create or replace function public.scheduled_rides_place_fees()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req  jsonb := coalesce(new.request, '{}'::jsonb);
  v_rest jsonb;
  v_fees jsonb := '[]'::jsonb;
begin
  select coalesce(jsonb_agg(c - 'earning' - 'place_fee' - 'locked'), '[]'::jsonb) into v_rest
    from jsonb_array_elements(case when jsonb_typeof(v_req->'charges') = 'array' then v_req->'charges' else '[]'::jsonb end) c
   where jsonb_typeof(c) = 'object' and c->'airport' is null;
  new.place_fees_locked := coalesce((public.place_fees_config()->>'lockScheduled')::boolean, true);
  if new.place_fees_locked then
    select coalesce(jsonb_agg(e || '{"locked": true}'::jsonb order by n), '[]'::jsonb) into v_fees
      from jsonb_array_elements(public.place_ride_charges(
             public.airport_at(new.pickup_lat, new.pickup_lng), public.airport_at(new.drop_lat, new.drop_lng),
             public.place_stop_areas(v_req->'stops'), coalesce(new.service, v_req->>'service'),
             greatest(0, coalesce(new.fare, 0) - public.ride_option_charges_total(v_req->'option_charges')),
             new.pickup_at)) with ordinality t(e, n);
    v_fees := public.place_fees_fit(v_rest, v_fees);
  end if;
  if v_req ? 'charges' or jsonb_array_length(v_fees) > 0 then
    new.request := jsonb_set(v_req, '{charges}', v_rest || v_fees);
  end if;
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_place_fees() from public, anon, authenticated;
drop trigger if exists trg_scheduled_rides_place_fees on public.scheduled_rides;
create trigger trg_scheduled_rides_place_fees before insert on public.scheduled_rides
  for each row execute function public.scheduled_rides_place_fees();

-- The fees a released booking locked, read from the booking itself (null
-- when it locked none, or the admin has since switched locking off: the
-- ride's fees are then worked out as for any ride).
create or replace function public.scheduled_place_fees(p_scheduled uuid, p_rider uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
           select jsonb_agg(c order by n)
             from jsonb_array_elements(case when jsonb_typeof(s.request->'charges') = 'array'
                                            then s.request->'charges' else '[]'::jsonb end) with ordinality t(c, n)
            where jsonb_typeof(c) = 'object' and c->'airport' is not null and c->'place_fee' is not null
              and c->'locked' = 'true'::jsonb), '[]'::jsonb)
    from public.scheduled_rides s
   where p_scheduled is not null and s.id = p_scheduled and s.rider_id = p_rider and s.place_fees_locked
     and coalesce((public.place_fees_config()->>'lockScheduled')::boolean, true);
$$;
revoke execute on function public.scheduled_place_fees(uuid, uuid) from public, anon, authenticated;

-- ---- 5. The ride trigger: 0264's ride_requests_airport (its latest definition), with the place
-- fees (place_ride_charges, or a scheduled booking's locked ones) instead of 0249's two charges.
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

    -- The type of the place at each end (0264): the server's.
    new.pickup_place_type := public.place_type_at(new.airport_pickup_id, new.pickup_door_id,
                                                  new.pickup_lat, new.pickup_lng);
    new.drop_place_type := public.place_type_at(new.airport_drop_id, new.drop_door_id,
                                                new.drop_lat, new.drop_lng);

    -- The airport fare and charges are the server's: what a client sent is
    -- dropped and worked out again. (A row the server already stamped, such
    -- as a scheduled ride's, keeps its own.)
    if v_client or new.airport_fare is null then
      new.airport_fare := null;
      -- 0324: a client's charge can't say it is a place fee or the driver's.
      select coalesce(jsonb_agg(e - 'earning' - 'place_fee' - 'locked'), '[]'::jsonb) into v_rest
        from jsonb_array_elements(case when jsonb_typeof(new.charges) = 'array' then new.charges else '[]'::jsonb end) e
       where jsonb_typeof(e) = 'object' and e->'airport' is null;
      -- 0324: the place fees (place_ride_charges), or those a scheduled
      -- booking locked when it was booked (scheduled_place_fees).
      v_charges := public.scheduled_place_fees(new.scheduled_ride_id, new.rider_id);
      if v_charges is null then
        v_charges := public.place_ride_charges(
          new.airport_pickup_id, new.airport_drop_id, public.place_stop_areas(new.stops), new.service,
          greatest(0, coalesce(new.ride_fare, new.fare, 0) - public.ride_option_charges_total(new.option_charges)),
          now());
      end if;
      v_charges := public.place_fees_fit(v_rest, v_charges);
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
    new.pickup_place_type := old.pickup_place_type;
    new.drop_place_type := old.drop_place_type;

    -- The airport charges stay as stamped.
    if new.charges is distinct from old.charges then
      select coalesce(jsonb_agg(e - 'earning' - 'place_fee' - 'locked'), '[]'::jsonb) into v_rest
        from jsonb_array_elements(case when jsonb_typeof(new.charges) = 'array' then new.charges else '[]'::jsonb end) e
       where jsonb_typeof(e) = 'object' and e->'airport' is null;
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
revoke execute on function public.ride_requests_airport() from public, anon, authenticated;

-- ---- 6. What the app shows before booking -------------------------------------------------------
-- The place fees a ride would be booked with: the lines the ride trigger
-- stamps for the same trip (place_ride_charges), their total, the pickup's
-- and the drop-off's place with its fees (null when that end has none) and
-- the display settings. [p_fare] is the route fare (the fare less 0248's
-- option charges); [p_at] the pickup time (null: now).
create or replace function public.place_fees_quote(
  p_pickup_lat float8, p_pickup_lng float8, p_drop_lat float8, p_drop_lng float8,
  p_stops jsonb, p_service text, p_fare numeric, p_at timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  cfg   jsonb := public.place_fees_config();
  v_pa  uuid := public.airport_at(p_pickup_lat, p_pickup_lng);
  v_da  uuid := public.airport_at(p_drop_lat, p_drop_lng);
  v_lines jsonb;
  v_pick jsonb;
  v_drop jsonb;
begin
  v_lines := public.place_ride_charges(v_pa, v_da, public.place_stop_areas(p_stops), p_service, p_fare,
                                       coalesce(p_at, now()));
  select jsonb_build_object('area_id', v_pa, 'name', a.values->>'name',
                            'fees', jsonb_agg(jsonb_build_object('name', l->>'name', 'amount', (l->>'value')::numeric)
                                              order by n))
    into v_pick
    from jsonb_array_elements(v_lines) with ordinality t(l, n)
    join public.airport_areas a on a.id = v_pa
   where (l->>'area')::uuid = v_pa and l->>'airport' in ('pick', 'once')
   group by a.values->>'name';
  select jsonb_build_object('area_id', v_da, 'name', a.values->>'name',
                            'fees', jsonb_agg(jsonb_build_object('name', l->>'name', 'amount', (l->>'value')::numeric)
                                              order by n))
    into v_drop
    from jsonb_array_elements(v_lines) with ordinality t(l, n)
    join public.airport_areas a on a.id = v_da
   where (l->>'area')::uuid = v_da
     and (l->>'airport' = 'drop' or (l->>'airport' = 'once' and v_pa is distinct from v_da))
   group by a.values->>'name';
  return jsonb_build_object(
    'lines', v_lines,
    'total', coalesce((select round(sum((l->>'value')::numeric), 2) from jsonb_array_elements(v_lines) l), 0),
    'pickup', v_pick,
    'drop', v_drop,
    'settings', jsonb_build_object(
      'showMapLabel', cfg->'showMapLabel', 'showAddressHint', cfg->'showAddressHint',
      'showCardBadge', cfg->'showCardBadge', 'badgeText', cfg->'badgeText',
      'addressHintText', cfg->'addressHintText'));
end;
$$;
revoke execute on function public.place_fees_quote(float8, float8, float8, float8, jsonb, text, numeric, timestamptz)
  from public, anon;
grant execute on function public.place_fees_quote(float8, float8, float8, float8, jsonb, text, numeric, timestamptz)
  to authenticated, service_role;

-- 0258's airport_fare_quote, with its charges from place_ride_charges (the
-- trip's stops and pickup time: two new parameters, both optional).
drop function if exists public.airport_fare_quote(float8, float8, float8, float8, text, numeric, numeric, text, text, text, text, jsonb);
create or replace function public.airport_fare_quote(
  p_pickup_lat float8, p_pickup_lng float8, p_drop_lat float8, p_drop_lng float8,
  p_service text, p_km numeric, p_normal numeric,
  p_country text default null, p_state text default null, p_city text default null, p_suburb text default null,
  p_option_charges jsonb default null, p_stops jsonb default null, p_at timestamptz default null)
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
  v_route numeric := greatest(0, coalesce(p_normal, 0) - public.ride_option_charges_total(p_option_charges));
begin
  if v_pa is null and v_da is null then
    return null;
  end if;
  -- [p_normal] is the fare as the app books it (with the option charges in
  -- it, as 0248 has them); the airport fare works on the route fare.
  return public.airport_quote(
    case when v_end = 'from' then v_pa else v_da end, v_end, p_service, p_km,
    v_route,
    public.airport_per_km(p_service, p_country, p_state, p_city, p_suburb),
    case when v_end = 'from' then p_drop_lat else p_pickup_lat end,
    case when v_end = 'from' then p_drop_lng else p_pickup_lng end,
    public.place_ride_charges(v_pa, v_da, public.place_stop_areas(p_stops), p_service, v_route, coalesce(p_at, now())),
    p_option_charges);
end;
$$;
revoke execute on function public.airport_fare_quote(float8, float8, float8, float8, text, numeric, numeric, text, text, text, text, jsonb, jsonb, timestamptz)
  from public, anon;
grant execute on function public.airport_fare_quote(float8, float8, float8, float8, text, numeric, numeric, text, text, text, text, jsonb, jsonb, timestamptz)
  to authenticated, service_role;

-- ---- 7. Statements and commission: a place fee for the driver is the driver's -----------------------
-- 0201's statement_ride_lines (its latest definition), with a charge marked
-- earning (a place fee that goes to the driver) counted as an earning.
create or replace function public.statement_ride_lines(r public.ride_requests, p_earning text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  f numeric := round(coalesce(r.ride_fare, r.fare, 0), 2);
  c jsonb;
  v numeric;
  amt numeric;
  s_earn numeric := 0;
  s_pass numeric := 0;
  s_platform numeric := 0;
  s_all numeric := 0;
  due numeric := public.ride_amount_due(r);
  tolls numeric := round(coalesce(r.toll_charges, 0), 2);
  other numeric := round(coalesce(r.other_charges, 0), 2);
begin
  if jsonb_typeof(r.charges) = 'array' then
    for c in select value from jsonb_array_elements(r.charges) loop
      v := case when jsonb_typeof(c->'value') = 'number' then (c->>'value')::numeric end;
      continue when v is null or v <= 0 or btrim(coalesce(c->>'name', '')) = '' or c->>'kind' = 'tax';
      amt := round(greatest(0, case when c->>'charge' = 'fixed' then v else f * v / 100 end), 2);
      s_all := s_all + amt;
      if (c->>'platform')::boolean is true then
        s_platform := s_platform + amt;
      elsif btrim(c->>'name') = any(p_earning) or coalesce(c->'earning' = 'true'::jsonb, false) then
        s_earn := s_earn + amt;
      else
        s_pass := s_pass + amt;
      end if;
    end loop;
  end if;
  return jsonb_build_object(
    'fare', f,
    'surcharges', s_earn,
    'platformCollected', s_platform,
    'surchargesPass', s_pass,
    'taxes', greatest(0, round(due - f - s_all - tolls - other, 2)),
    'tolls', tolls,
    'otherCharges', other,
    'commission', round(coalesce(r.commission_amount, 0), 2),
    -- Only fixed platform fees are taken back from GET credit (0189).
    'platformFees', coalesce((select sum(round((e->>'value')::numeric, 2)) from jsonb_array_elements(
                        case when jsonb_typeof(r.charges) = 'array' then r.charges else '[]' end) e
                      where (e->>'platform')::boolean is true and e->>'charge' = 'fixed'
                        and jsonb_typeof(e->'value') = 'number' and (e->>'value')::numeric > 0), 0),
    'coins', round(coalesce(r.fare_coins_value, 0), 2),
    'cash', case when lower(coalesce(r.paid_method, r.payment_mode, 'cash')) like 'cash%'
                 then greatest(0, round(due - coalesce(r.fare_coins_value, 0), 2)) else 0 end,
    'distanceKm', round(coalesce(r.distance_km, 0), 2));
end;
$$;
revoke execute on function public.statement_ride_lines(public.ride_requests, text[]) from public, anon, authenticated;

-- 0248's commission_base (its latest definition), with a charge marked
-- earning in the base as a ticked surcharge is. Platform and passed-on
-- place fees stay out of it.
create or replace function public.commission_base(r public.ride_requests)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.commission_config();
  names text[] := array(select jsonb_array_elements_text(cfg->'baseSurcharges'));
  f numeric := greatest(0, round(coalesce(r.ride_fare, r.fare, 0), 2)
                         - public.ride_option_charges_off(r.option_charges, 'commission'));
  total numeric := f;
  c jsonb;
  v numeric;
begin
  if jsonb_typeof(r.charges) = 'array' then
    for c in select value from jsonb_array_elements(r.charges) loop
      v := case when jsonb_typeof(c->'value') = 'number' then (c->>'value')::numeric end;
      continue when v is null or v <= 0 or c->>'kind' = 'tax' or (c->>'platform')::boolean is true
                 or not (btrim(coalesce(c->>'name', '')) = any(names) or coalesce(c->'earning' = 'true'::jsonb, false));
      total := total + round(greatest(0, case when c->>'charge' = 'fixed' then v else f * v / 100 end), 2);
    end loop;
  end if;
  if (cfg->>'baseTolls')::boolean then
    total := total + round(greatest(0, coalesce(r.toll_charges, 0)), 2);
  end if;
  if (cfg->>'baseOtherCharges')::boolean then
    total := total + round(greatest(0, coalesce(r.other_charges, 0)), 2);
  end if;
  return round(total, 2);
end;
$$;
revoke execute on function public.commission_base(public.ride_requests) from public, anon, authenticated;

-- ---- 8. Followed live by the admin ------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'place_fees') then
    alter publication supabase_realtime add table public.place_fees;
  end if;
end $$;

notify pgrst, 'reload schema';
