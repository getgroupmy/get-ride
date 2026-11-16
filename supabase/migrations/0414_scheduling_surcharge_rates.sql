-- ============================================================================
-- Advance-booking surcharge rates (migration 0414)
--
-- The scheduling fee on a future-dated ("Later") booking is today one global
-- flat + percentage pair on scheduled_rides_config() (migration 0189). This
-- adds admin overrides scoped by BOTH service type AND region, so an operator
-- can charge, say, +RM5 on a scheduled TEKSI in Selangor but +10% on a
-- scheduled Ride everywhere.
--
-- A row carries:
--   * level              master / country / state / city / suburb (region scope)
--   * service            a service-type key, or NULL = every service
--   * fee_fixed          a flat amount (0-1000)
--   * fee_percent        a percentage of the fare (0-100)
--
-- Resolution (scheduling_surcharge_fee) mirrors commission_resolve: the pickup
-- point names the region (narrowest-first), a service-specific row beats an
-- all-service row at the same level, and when NOTHING matches it falls back to
-- the global scheduled_rides_config() fee -- so existing behaviour is kept and
-- the feature is purely additive. Riders read the rows on the device for the
-- "+ RM x scheduling fee" preview; admins alone may write.
-- ============================================================================

create table if not exists public.scheduling_surcharge_rates (
  id          uuid primary key default gen_random_uuid(),
  level       text not null check (level in ('master', 'country', 'state', 'city', 'suburb')),
  country     text check (country is null or char_length(btrim(country)) between 1 and 120),
  state       text check (state is null or char_length(btrim(state)) between 1 and 120),
  city        text check (city is null or char_length(btrim(city)) between 1 and 120),
  suburb      text check (suburb is null or char_length(btrim(suburb)) between 1 and 120),
  service     text check (service is null or char_length(btrim(service)) between 1 and 120),
  fee_fixed   numeric not null default 0 check (fee_fixed >= 0 and fee_fixed <= 1000),
  fee_percent numeric not null default 0 check (fee_percent >= 0 and fee_percent <= 100),
  active      boolean not null default true,
  priority    integer not null default 0,
  note        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint scheduling_surcharge_names check (
    (level = 'master' and country is null and state is null and city is null and suburb is null)
    or (level = 'country' and country is not null and state is null and city is null and suburb is null)
    or (level = 'state' and country is not null and state is not null and city is null and suburb is null)
    or (level = 'city' and country is not null and state is not null and city is not null and suburb is null)
    or (level = 'suburb' and country is not null and state is not null and city is not null and suburb is not null))
);

comment on table public.scheduling_surcharge_rates is
  'Advance-booking (scheduled ride) surcharge overrides (0414): per service type and '
  'Country/State/City/Suburb (+ master), a flat + percentage fee. Resolved narrowest-first '
  'with a service-specific row beating an all-service one; falls back to scheduled_rides_config().';

drop trigger if exists trg_scheduling_surcharge_updated_at on public.scheduling_surcharge_rates;
create trigger trg_scheduling_surcharge_updated_at before update on public.scheduling_surcharge_rates
  for each row execute function public.set_updated_at();

-- Page-scoped edit check (migration 0223 convention): a sub-admin writes this
-- table only with edit on its page (or the Settings hub). Writes must not go
-- through caller_is_admin() -- supabase/tests/admin_page_scope.sql enforces it.
create or replace function public.scheduling_surcharge_caller_can_edit()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and (public.admin_can_edit(auth.uid(), 'admin-settings-scheduling-surcharge')
          or public.admin_can_edit(auth.uid(), 'admin-settings'));
$$;

revoke execute on function public.scheduling_surcharge_caller_can_edit() from public, anon;
grant execute on function public.scheduling_surcharge_caller_can_edit() to authenticated;

alter table public.scheduling_surcharge_rates enable row level security;
revoke all on public.scheduling_surcharge_rates from anon;
grant select, insert, update, delete on public.scheduling_surcharge_rates to authenticated;

drop policy if exists "scheduling_surcharge read" on public.scheduling_surcharge_rates;
drop policy if exists "scheduling_surcharge admin insert" on public.scheduling_surcharge_rates;
drop policy if exists "scheduling_surcharge admin update" on public.scheduling_surcharge_rates;
drop policy if exists "scheduling_surcharge admin delete" on public.scheduling_surcharge_rates;

-- Every signed-in rider reads the rows (the preview runs on the device).
create policy "scheduling_surcharge read"
  on public.scheduling_surcharge_rates for select to authenticated
  using (true);
create policy "scheduling_surcharge admin insert"
  on public.scheduling_surcharge_rates for insert to authenticated
  with check ((select public.scheduling_surcharge_caller_can_edit()));
create policy "scheduling_surcharge admin update"
  on public.scheduling_surcharge_rates for update to authenticated
  using ((select public.scheduling_surcharge_caller_can_edit()))
  with check ((select public.scheduling_surcharge_caller_can_edit()));
create policy "scheduling_surcharge admin delete"
  on public.scheduling_surcharge_rates for delete to authenticated
  using ((select public.scheduling_surcharge_caller_can_edit()));

-- Live: the booking sheet's fee preview refetches the moment an admin saves
-- (live_tables.dart / live_admin_changes.sql).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'scheduling_surcharge_rates'
  ) then
    alter publication supabase_realtime add table public.scheduling_surcharge_rates;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- Resolver (region already named): the surcharge on a scheduled booking of
-- [p_service] in the given region for a fare of [p_fare]. A service-specific
-- row beats an all-service one at the same level; the narrowest region wins;
-- when nothing matches it falls back to the global scheduled_rides_config()
-- fee. Returns the fee to the cent. The coordinate wrapper below names the
-- region from the pickup point; this inner form is called directly by tests.
-- ----------------------------------------------------------------------------
create or replace function public.scheduling_surcharge_fee_at(
  p_service text,
  p_country text,
  p_state text,
  p_city text,
  p_suburb text,
  p_fare numeric
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_service text := nullif(btrim(p_service), '');
  v_country text := nullif(btrim(p_country), '');
  v_state   text := nullif(btrim(p_state), '');
  v_city    text := nullif(btrim(p_city), '');
  v_suburb  text := nullif(btrim(p_suburb), '');
  v_fare    numeric := greatest(coalesce(p_fare, 0), 0);
  c         jsonb;
  v_fixed   numeric;
  v_percent numeric;
begin
  select s.fee_fixed, s.fee_percent into v_fixed, v_percent
    from public.scheduling_surcharge_rates s
   where s.active
     and (s.service is null or lower(btrim(s.service)) = lower(coalesce(v_service, '')))
     and case s.level
       when 'suburb' then public.commission_place_matches(s.suburb, v_suburb)
         and public.commission_parent_ok(s.city, v_city)
         and public.commission_parent_ok(s.state, v_state)
         and public.commission_parent_ok(s.country, v_country)
       when 'city' then public.commission_place_matches(s.city, v_city)
         and public.commission_parent_ok(s.state, v_state)
         and public.commission_parent_ok(s.country, v_country)
       when 'state' then public.commission_place_matches(s.state, v_state)
         and public.commission_parent_ok(s.country, v_country)
       when 'country' then public.commission_place_matches(s.country, v_country)
       when 'master' then true
       else false
     end
   order by
     case s.level
       when 'suburb' then 5 when 'city' then 4 when 'state' then 3 when 'country' then 2 else 1
     end desc,
     (s.service is not null)::int desc,            -- a service-specific row wins
     s.priority desc,
     (s.country is not null)::int + (s.state is not null)::int + (s.city is not null)::int desc,
     s.updated_at desc nulls last,
     s.id
   limit 1;

  if found then
    return round(coalesce(v_fixed, 0) + v_fare * coalesce(v_percent, 0) / 100, 2);
  end if;

  -- No override: the global scheduled-rides fee (unchanged behaviour).
  c := public.scheduled_rides_config();
  return round((c->>'feeFixed')::numeric + v_fare * (c->>'feePercent')::numeric / 100, 2);
end;
$$;

revoke execute on function public.scheduling_surcharge_fee_at(text, text, text, text, text, numeric) from public, anon;
grant execute on function public.scheduling_surcharge_fee_at(text, text, text, text, text, numeric) to authenticated, service_role;

-- Coordinate wrapper: name the region from the pickup point (narrowest-first,
-- like commission_resolve) where the admin mapped outlines, then resolve.
create or replace function public.scheduling_surcharge_fee(
  p_service text,
  p_lat double precision,
  p_lng double precision,
  p_fare numeric
)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_country text;
  v_state   text;
  v_city    text;
  v_suburb  text;
  g         record;
begin
  if p_lat is not null and p_lng is not null then
    for g in
      select distinct on (a.region_table) a.region_table, a.country, a.state, a.city, a.suburb
        from public.regions_at(p_lat, p_lng) a
       where a.inside
       order by a.region_table, a.area asc nulls last
    loop
      case g.region_table
        when 'countries' then v_country := g.country;
        when 'states' then v_state := g.state; v_country := coalesce(nullif(g.country, ''), v_country);
        when 'cities' then v_city := g.city; v_state := coalesce(nullif(g.state, ''), v_state);
        when 'suburbs' then v_suburb := g.suburb; v_city := coalesce(nullif(g.city, ''), v_city);
        else null;
      end case;
    end loop;
  end if;
  return public.scheduling_surcharge_fee_at(p_service, v_country, v_state, v_city, v_suburb, p_fare);
end;
$$;

revoke execute on function public.scheduling_surcharge_fee(text, double precision, double precision, numeric) from public, anon;
grant execute on function public.scheduling_surcharge_fee(text, double precision, double precision, numeric) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- Route schedule_ride's fee through the resolver (was an inline global-config
-- computation). Everything else about the function is unchanged.
-- ----------------------------------------------------------------------------
create or replace function public.schedule_ride(p_request jsonb, p_pickup_at timestamptz)
returns public.scheduled_rides
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  c      jsonb := public.scheduled_rides_config();
  v_req  jsonb := coalesce(p_request, '{}'::jsonb);
  v_fare numeric;
  v_fee  numeric;
  v_name text;
  v_phone text;
  r      public.scheduled_rides;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if not (c->>'enabled')::boolean then
    raise exception 'SCHEDULED_OFF' using hint = 'Scheduled rides are not available.';
  end if;
  if p_pickup_at is null
     or p_pickup_at < now() + make_interval(mins => (c->>'minLeadMinutes')::int)
     or p_pickup_at > now() + make_interval(days => (c->>'maxDaysAhead')::int) then
    raise exception 'SCHEDULED_TIME' using hint = format('Pick a time between %s minutes and %s days from now.',
      c->>'minLeadMinutes', c->>'maxDaysAhead');
  end if;
  if (select count(*) from public.scheduled_rides
       where rider_id = v_uid and status in ('scheduled', 'assigned', 'released')) >= 5 then
    raise exception 'SCHEDULED_LIMIT' using hint = 'You already have 5 upcoming rides.';
  end if;

  v_fare := round(coalesce(
    case when jsonb_typeof(v_req->'ride_fare') = 'number' then (v_req->>'ride_fare')::numeric end,
    case when jsonb_typeof(v_req->'fare') = 'number' then (v_req->>'fare')::numeric end, 0), 2);
  if not public.ride_money_ok(v_fare) or v_fare <= 0 then
    raise exception 'RIDE_FARE_INVALID' using errcode = '22023';
  end if;
  if jsonb_typeof(v_req->'pickup_lat') <> 'number' or jsonb_typeof(v_req->'pickup_lng') <> 'number' then
    raise exception 'SCHEDULED_PICKUP' using hint = 'A pickup point is needed.';
  end if;

  v_name := nullif(btrim(coalesce(v_req->>'booked_for_name', '')), '');
  v_phone := nullif(btrim(coalesce(v_req->>'booked_for_phone', '')), '');
  if (v_name is not null and (v_phone is null or length(v_name) > 80))
     or (v_phone is not null and length(v_phone) not between 6 and 32) then
    raise exception 'SCHEDULED_PASSENGER' using hint = 'Give the passenger''s name and phone number.';
  end if;

  -- Only what the booking sheet sends; the release skips the app's checks.
  v_req := public.scheduled_request_clean(v_req);

  -- The advance-booking surcharge: a per-service/per-region override where the
  -- admin set one, else the global scheduled-rides fee (migration 0414).
  v_fee := public.scheduling_surcharge_fee(
    v_req->>'service',
    (v_req->>'pickup_lat')::double precision,
    (v_req->>'pickup_lng')::double precision,
    v_fare);
  if v_fee > 0 then
    v_req := jsonb_set(v_req, '{charges}',
      coalesce(v_req->'charges', '[]'::jsonb)
      || jsonb_build_array(jsonb_build_object(
           'kind', 'surcharge', 'name', 'Scheduling fee', 'charge', 'fixed', 'value', v_fee,
           'platform', (c->>'feeTo') = 'platform')));
  end if;

  insert into public.scheduled_rides (
    rider_id, pickup_at, request, service, pickup_address, drop_address,
    pickup_lat, pickup_lng, drop_lat, drop_lng, distance_km, fare, scheduling_fee, currency,
    booked_for_name, booked_for_phone)
  values (
    v_uid, p_pickup_at, v_req, v_req->>'service',
    coalesce(v_req->>'pickup_address', v_req->>'pickup_name'), coalesce(v_req->>'drop_address', v_req->>'drop_name'),
    (v_req->>'pickup_lat')::double precision, (v_req->>'pickup_lng')::double precision,
    case when jsonb_typeof(v_req->'drop_lat') = 'number' then (v_req->>'drop_lat')::double precision end,
    case when jsonb_typeof(v_req->'drop_lng') = 'number' then (v_req->>'drop_lng')::double precision end,
    case when jsonb_typeof(v_req->'distance_km') = 'number' then (v_req->>'distance_km')::numeric end,
    v_fare, greatest(v_fee, 0), v_req->>'currency', v_name, v_phone)
  returning * into r;
  return r;
end;
$$;
revoke execute on function public.schedule_ride(jsonb, timestamptz) from public, anon;
grant execute on function public.schedule_ride(jsonb, timestamptz) to authenticated;
