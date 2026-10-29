-- ============================================================================
-- 0325 — Place fees follow-ups (after 0324).
--
-- 1. The place's outline on the rider's map: app_settings 'place_fees' gets
--    `showOutline` (default on). place_fees_normalize (so place_fees_config
--    and set_place_fees_config) keeps it, and place_fees_quote sends it with
--    the other display settings. The outline itself is the area's boundary
--    the rider's app already reads (airport_areas); nothing new is exposed.
-- 2. The driver's scheduled rides show the place fees a booking locked
--    (0324: request.charges entries with locked: true): place_fee_lines(s)
--    gives just those lines (name, amount, end, who gets it), nothing else
--    of the rider's request. scheduled_rides_open, scheduled_rides_upcoming
--    and scheduled_ride_offers_open (each copied from its current
--    definition, with 0254 / 0263 / 0267 / 0311's edits in it) return them
--    as a new last column, place_fees; My rides reads it as a computed
--    column of the driver's own bookings.
--
-- Re-runnable.
-- ============================================================================

-- ---- 1. showOutline ----------------------------------------------------------------------------------
-- 0324's place_fees_normalize, with showOutline among the switches.
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
  foreach k in array array['lockScheduled', 'showMapLabel', 'showAddressHint', 'showCardBadge', 'showOutline'] loop
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

-- The stored row says it too (a row without it reads as on anyway).
update public.app_settings set value = value || '{"showOutline": true}'::jsonb
 where key = 'place_fees' and jsonb_typeof(value) = 'object' and not value ? 'showOutline';

-- 0324's place_fees_quote, with showOutline in its display settings.
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
      'showCardBadge', cfg->'showCardBadge', 'showOutline', cfg->'showOutline',
      'badgeText', cfg->'badgeText', 'addressHintText', cfg->'addressHintText'));
end;
$$;
revoke execute on function public.place_fees_quote(float8, float8, float8, float8, jsonb, text, numeric, timestamptz)
  from public, anon;
grant execute on function public.place_fees_quote(float8, float8, float8, float8, jsonb, text, numeric, timestamptz)
  to authenticated, service_role;

-- ---- 2. The locked place fees of a booking, for its driver -----------------------------------------------
-- The place fees [s] locked when it was booked, as charges entries with
-- only what the fee line needs: name, value, end (airport), the fee's id,
-- who gets it (goes_to) and locked. Not the rider's note, nor anything
-- else of the request. A computed column for the driver's own bookings
-- (scheduled_rides' policies decide which rows), and what the RPCs below
-- return; it reads only the row it is given.
create or replace function public.place_fee_lines(s public.scheduled_rides)
returns jsonb
language sql
stable
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', 'surcharge', 'charge', 'fixed', 'name', btrim(c->>'name'),
           'value', round((c->>'value')::numeric, 2), 'airport', c->>'airport', 'place_fee', c->>'place_fee',
           'goes_to', coalesce(c->>'goes_to', 'pass'), 'locked', true) order by n), '[]'::jsonb)
    from jsonb_array_elements(case when s.place_fees_locked and jsonb_typeof(s.request->'charges') = 'array'
                                   then s.request->'charges' else '[]'::jsonb end) with ordinality t(c, n)
   where jsonb_typeof(c) = 'object' and c->'airport' is not null and c->'place_fee' is not null
     and c->'locked' = 'true'::jsonb and jsonb_typeof(c->'value') = 'number' and (c->>'value')::numeric > 0
     and btrim(coalesce(c->>'name', '')) <> '';
$$;
revoke execute on function public.place_fee_lines(public.scheduled_rides) from public, anon;
grant execute on function public.place_fee_lines(public.scheduled_rides) to authenticated, service_role;

-- Advance booking's open list: the current scheduled_rides_open (0253, with
-- 0254 / 0263 / 0267 / 0311's edits), with place_fees last.
drop function if exists public.scheduled_rides_open();
create or replace function public.scheduled_rides_open()
returns table(id uuid, pickup_at timestamptz, service text, pickup_address text, drop_address text,
              pickup_lat double precision, pickup_lng double precision, drop_lat double precision,
              drop_lng double precision, distance_km numeric, fare numeric, scheduling_fee numeric, currency text,
              place_fees jsonb)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.pickup_at, s.service, s.pickup_address, s.drop_address,
         s.pickup_lat, s.pickup_lng, s.drop_lat, s.drop_lng, s.distance_km, s.fare,
         case when public.scheduled_rides_config()->>'feeTo' = 'driver' then s.scheduling_fee else 0 end,
         s.currency,
         public.place_fee_lines(s)
    from public.scheduled_rides s
   where s.status = 'scheduled' and s.partner_id is null and s.pickup_at > now()
     and s.stand_id is null
     and public.caller_is_approved_partner()
     and public.scheduled_rides_config()->>'mode' = 'advance'
     and s.rider_id <> auth.uid()
     and not public.rider_blocks_driver(s.rider_id, auth.uid())
     and public.service_order_driver_allows(auth.uid(), s.service)
     and public.driver_permit_problem(auth.uid()) is null
     and public.driver_takes_service(auth.uid(), s.service)
     and public.driver_takes_freight(auth.uid(), s.service)
     and public.driver_takes_extras(auth.uid(), public.ride_extra_keys(
           s.request->'pets', s.request->'assistance', s.request->'option_names',
           case when jsonb_typeof(s.request->'passengers') = 'number'
                then floor((s.request->>'passengers')::numeric)::integer end))
   order by s.pickup_at
   limit 100;
$$;
revoke execute on function public.scheduled_rides_open() from public, anon;
grant execute on function public.scheduled_rides_open() to authenticated, service_role;

-- Upcoming: the current scheduled_rides_upcoming (0251, with 0311's edit),
-- with place_fees last.
drop function if exists public.scheduled_rides_upcoming();
create or replace function public.scheduled_rides_upcoming()
returns table(id uuid, pickup_at timestamptz, service text, pickup_address text, drop_address text,
              pickup_lat double precision, pickup_lng double precision, drop_lat double precision,
              drop_lng double precision, distance_km numeric, fare numeric, scheduling_fee numeric, currency text,
              interested boolean, can_accept boolean, accept_from timestamptz, place_fees jsonb)
language sql
stable
security definer
set search_path = public
as $$
  with c as (select public.scheduled_rides_config() as v)
  select s.id, s.pickup_at, s.service, s.pickup_address, s.drop_address,
         s.pickup_lat, s.pickup_lng, s.drop_lat, s.drop_lng, s.distance_km, s.fare,
         case when c.v->>'feeTo' = 'driver' then s.scheduling_fee else 0 end,
         s.currency,
         i.partner_id is not null,
         c.v->>'mode' = 'advance'
           or (i.partner_id is not null and (c.v->>'interestNoticeMinutes')::int > 0
               and now() >= s.pickup_at - make_interval(mins => (c.v->>'interestNoticeMinutes')::int)),
         case when c.v->>'mode' = 'advance' then null
              when (c.v->>'interestNoticeMinutes')::int > 0
              then s.pickup_at - make_interval(mins => (c.v->>'interestNoticeMinutes')::int) end,
         public.place_fee_lines(s)
    from public.scheduled_rides s
    cross join c
    left join public.scheduled_ride_interests i on i.scheduled_ride_id = s.id and i.partner_id = auth.uid()
   where s.status = 'scheduled' and s.partner_id is null and s.pickup_at > now()
     and s.stand_id is null
     and (c.v->>'enabled')::boolean
     and public.caller_is_approved_partner()
     and s.rider_id <> auth.uid()
     and not public.rider_blocks_driver(s.rider_id, auth.uid())
   order by s.pickup_at;
$$;
revoke execute on function public.scheduled_rides_upcoming() from public, anon;
grant execute on function public.scheduled_rides_upcoming() to authenticated, service_role;

-- Requests for you (and the ones the caller sent): the current
-- scheduled_ride_offers_open (0198), with place_fees last.
drop function if exists public.scheduled_ride_offers_open();
create or replace function public.scheduled_ride_offers_open()
returns table (
  id uuid, scheduled_ride_id uuid, kind text, incoming boolean, other_name text, expires_at timestamptz,
  pickup_at timestamptz, service text, pickup_address text, drop_address text, distance_km numeric,
  fare numeric, scheduling_fee numeric, currency text, place_fees jsonb)
language sql
stable
security definer
set search_path = public
as $$
  select o.id, o.scheduled_ride_id, o.kind, o.to_partner_id = auth.uid(),
         case when o.to_partner_id = auth.uid()
              then case when o.kind = 'transfer' then (public.my_ride_partner_of(o.from_id)).name end
              else (public.my_ride_partner_of(o.to_partner_id)).name end,
         o.expires_at, s.pickup_at, s.service, s.pickup_address, s.drop_address, s.distance_km, s.fare,
         -- Drivers see the fee only when it goes to them, as on the open list.
         case when o.kind = 'transfer' or o.to_partner_id = auth.uid()
              then case when public.scheduled_rides_config()->>'feeTo' = 'driver' then s.scheduling_fee else 0 end
              else s.scheduling_fee end,
         s.currency,
         public.place_fee_lines(s)
    from public.scheduled_ride_offers o
    join public.scheduled_rides s on s.id = o.scheduled_ride_id
   where o.status = 'pending' and o.expires_at > now()
     and (o.to_partner_id = auth.uid() or o.from_id = auth.uid())
   order by s.pickup_at;
$$;
revoke execute on function public.scheduled_ride_offers_open() from public, anon;
grant execute on function public.scheduled_ride_offers_open() to authenticated, service_role;

notify pgrst, 'reload schema';
