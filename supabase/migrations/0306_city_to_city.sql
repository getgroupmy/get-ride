-- ============================================================================
-- 0306 — City to City (intercity rides, e.g. Kuala Lumpur to Ipoh): the
-- server and admin half (docs/KIV.md L8, part C1). The rider app (C2) and
-- the driver app (C3) come next and read what is here.
--
-- Version 20261027230000 (0306_city_to_city). Re-runnable: tables, columns
-- and indexes "if not exists", functions "create or replace", policies and
-- triggers dropped first, seed rows only where missing.
--
-- 1. The service: a Vehicle Service "City to City" (serviceTypes
--    ["City to City"]) under a master service of that name, both added
--    INACTIVE (as 0268 added the courier vehicles) when no entry has the
--    name. Launch is whole car only: pay-per-seat sharing and trips a driver
--    posts come later (c2c_route_rules.trip_kind keeps room; only
--    'whole_car' is matched). The home box's "coming soon" is left alone.
-- 2. city_to_city_settings (one row): the cancel fee (on/off, amount, free
--    until N hours before; default RM 20 after 24 h), the payment methods
--    allowed (In app, Cash; at least one), the minimum driving experience
--    (on/off, default 3 years), and the default rule's add-on, range and
--    book-ahead days. Admin → Services & catalogue → City to City.
-- 3. c2c_country_permits: per country, the permits (permit_types, 0254;
--    driver or vehicle, taken from the type) a driver needs for City to
--    City. Checked for the pickup country and every country the trip enters.
-- 4. c2c_route_rules: From and To each a list of places at any level
--    ([{level, country, state, city, suburb}], level country | state | city
--    | suburb; the parents are those of the region row it was picked from,
--    so Kuala Lumpur, a federal territory, is never taken to be in
--    Selangor). Places match as commission rates do (0216): the place's own
--    name (or as whole words in the geocoder's), and each parent that both
--    name. Per rule: fare mode 'card' (the fare card for the pickup and the
--    service, plus an add-on in RM and/or % of the card) or 'fixed' (a fare
--    per car); range mode 'auto' (± X %, default 8) or 'set' (low / high);
--    book ahead (days); minimum years ('default' follows the settings, 'set'
--    its own number, 'off' no restriction); active; position.
--    Which rule: each end takes the most specific place of the rule that
--    matches it (suburb 4, city 3, state 2, country 1; no match: the rule
--    does not apply). The winner has (1) the highest sum of both ends, then
--    (2) the more specific pickup end, then (3) the lower position (list
--    order), then (4) the older rule, then (5) the lower id. No rule: the
--    default (fare card + the settings' add-on and range).
-- 5. The fare card (c2c_fare_card): the Fare tariffs card for the pickup and
--    the service as the app's resolveFareTariff (fare_tariff.dart): the
--    narrowest place with a card for it, there the service's own card over
--    its type's over every service's; base + per km + per min, never below
--    the minimum, plus the booking fee (no service multiplier). No card: the
--    service's own rates (0300), else the built-in TEKSI tariff.
--    c2c_quote(pickup point and names, drop names, km, minutes, service):
--    {fareCard, addOn, suggested, low, high, ruleId, ...}. Suggested: card +
--    add-on RM + card × add-on % (cents), or the fixed fare. Auto range:
--    suggested × (1 ∓ X %), to whole units. The pickup's names come from the
--    mapped outlines where there are any (commission_places, 0224).
--    lib/src/core/city_to_city.dart is the app's twin, tested on the same
--    cases (test/city_to_city_test.dart, supabase/tests/city_to_city_0306.sql).
-- 6. c2c_available_at(place): the City to City vehicle service is active and
--    on at the pickup's place by the region service switches (0302).
-- 7. c2c_driver_check / c2c_driver_ok(driver, pickup, drop, via): enough
--    driving experience and every permit needed. Experience is counted from
--    partners.driving_since (new: when the driver's licence was first
--    issued; admins set it now, the driver app asks for it in C3), else the
--    earliest start date of an approved driving licence document. Unknown
--    experience does not meet a minimum. A permit counts when its latest
--    document is approved and in date (0254): a driver permit on the driver,
--    a vehicle permit on the vehicle they drive now (else any of theirs).
-- 8. Commission per service: commission_service_rates, a rate per Vehicle
--    Service (Admin → Commission → Per service) used instead of the place
--    rate. Which rate: the driver's own rate (level user) first, then the
--    service's rate, then the place rate (suburb, city, state, country,
--    master). Tiers (0218) then lower a service rate as they lower a place
--    rate, and a running promotion (0224) that is lower still wins, as
--    today; neither touches a driver's own rate. So in effect: user rate,
--    then promotion, then service rate, then place rate.
--    commission_resolve gets an 8-argument form with the service; the
--    7-argument form (every other caller) is unchanged. The lock on accept
--    and the charge on completion (0224) pass the ride's service.
-- 9. Admins with EDIT on admin-settings-city-to-city write the settings,
--    permits and rules (admin_table_pages, 0223); everyone signed in reads
--    them (the apps need them). Service rates: admins read, EDIT on
--    Commission writes.
-- ============================================================================

-- ---- 1. The service ----------------------------------------------------------------------------------
insert into public.settings_entries (id, category, values, position)
select '63326331-0000-4000-8000-000000000000', 'service-settings',
       jsonb_build_object('name', 'City to City', 'description', 'Intercity rides, whole car.',
                          'iconUri', '', 'active', false, 'isDefault', false,
                          'displayPriority', coalesce((select count(*) from public.settings_entries
                                                        where category = 'service-settings'), 0) + 1),
       coalesce((select max(position) from public.settings_entries where category = 'service-settings'), 0) + 1
 where not exists (select 1 from public.settings_entries
                    where category = 'service-settings' and lower(btrim(values->>'name')) = 'city to city')
on conflict (id) do nothing;

insert into public.settings_entries (id, category, values, position)
select '63326331-0000-4000-8000-000000000001', 'vehicle-services',
       jsonb_build_object(
         'name', 'City to City', 'description', 'A whole car from one city to another.',
         'shortDescription', 'Intercity, whole car',
         'serviceTypes', jsonb_build_array('City to City'), 'parentServices', '[]'::jsonb, 'fuelTypes', '[]'::jsonb,
         'status', false,
         'iconUri', '', 'heroImageUri', '', 'mapIconUri', '', 'mapIconColor', '',
         'costPerKm', 0.45, 'costPerMin', 0.15, 'minFareAmount', 50,
         'displayPriority', 950),
       coalesce((select max(position) from public.settings_entries where category = 'vehicle-services'), 0) + 1
 where not exists (select 1 from public.settings_entries
                    where category = 'vehicle-services' and lower(btrim(values->>'name')) = 'city to city')
on conflict (id) do nothing;

-- ---- Shared: who changed a row, and when -------------------------------------------------------------
create or replace function public.c2c_stamp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;
revoke execute on function public.c2c_stamp() from public, anon, authenticated;

-- ---- 2. Settings -------------------------------------------------------------------------------------
create table if not exists public.city_to_city_settings (
  id                      smallint primary key default 1 check (id = 1),
  cancel_fee_on           boolean not null default true,
  cancel_fee_amount       numeric(10,2) not null default 20 check (cancel_fee_amount between 0 and 10000),
  cancel_free_hours       integer not null default 24 check (cancel_free_hours between 0 and 720),
  pay_in_app              boolean not null default true,
  pay_cash                boolean not null default true,
  min_years_on            boolean not null default true,
  min_years               integer not null default 3 check (min_years between 0 and 60),
  default_add_on_amount   numeric(10,2) not null default 0 check (default_add_on_amount between 0 and 10000),
  default_add_on_percent  numeric(6,2) not null default 0 check (default_add_on_percent between 0 and 500),
  default_range_mode      text not null default 'auto' check (default_range_mode in ('auto', 'set')),
  default_range_percent   numeric(6,2) not null default 8 check (default_range_percent between 0 and 90),
  default_range_low       numeric(10,2),
  default_range_high      numeric(10,2),
  default_book_ahead_days integer not null default 14 check (default_book_ahead_days between 1 and 365),
  currency                text not null default 'MYR' check (currency ~ '^[A-Z]{3}$'),
  updated_at              timestamptz not null default now(),
  updated_by              uuid,
  constraint city_to_city_settings_pay check (pay_in_app or pay_cash),
  constraint city_to_city_settings_range check (
    default_range_mode = 'auto'
    or (default_range_low is not null and default_range_high is not null
        and default_range_low > 0 and default_range_low <= default_range_high))
);
comment on table public.city_to_city_settings is
  'City to City (0306), one row: cancel fee, payment methods, minimum driving experience, the default rule.';
insert into public.city_to_city_settings (id) values (1) on conflict (id) do nothing;

drop trigger if exists trg_city_to_city_settings_stamp on public.city_to_city_settings;
create trigger trg_city_to_city_settings_stamp
  before insert or update on public.city_to_city_settings
  for each row execute function public.c2c_stamp();

-- ---- 3. Permits by country ---------------------------------------------------------------------------
create table if not exists public.c2c_country_permits (
  id             uuid primary key default gen_random_uuid(),
  country        text not null check (char_length(btrim(country)) between 1 and 120),
  permit_type_id uuid not null references public.permit_types(id) on delete cascade,
  applies_to     text not null default 'driver' check (applies_to in ('driver', 'vehicle')),
  position       integer not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  updated_by     uuid
);
create unique index if not exists c2c_country_permits_uidx
  on public.c2c_country_permits (lower(btrim(country)), permit_type_id);
comment on table public.c2c_country_permits is
  'City to City (0306): the permits a driver needs for trips that start in or enter a country.';

-- Driver or vehicle is the permit type's own.
create or replace function public.c2c_country_permits_fill()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.country := btrim(new.country);
  select t.applies_to into new.applies_to from public.permit_types t where t.id = new.permit_type_id;
  new.applies_to := coalesce(new.applies_to, 'driver');
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;
revoke execute on function public.c2c_country_permits_fill() from public, anon, authenticated;
drop trigger if exists trg_c2c_country_permits_fill on public.c2c_country_permits;
create trigger trg_c2c_country_permits_fill
  before insert or update on public.c2c_country_permits
  for each row execute function public.c2c_country_permits_fill();

-- ---- 4. Route rules ----------------------------------------------------------------------------------
-- A list of 1 to 30 places: {level, country, state, city, suburb}; the
-- country and the level's own name are given; names up to 120 characters.
create or replace function public.c2c_places_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(p) = 'array'
     and jsonb_array_length(p) between 1 and 30
     and not exists (
       select 1 from jsonb_array_elements(p) e
        where jsonb_typeof(e) <> 'object'
           or coalesce(e->>'level', '') not in ('country', 'state', 'city', 'suburb')
           or char_length(btrim(coalesce(e->>'country', ''))) not between 1 and 120
           or char_length(btrim(coalesce(e->>(e->>'level'), ''))) not between 1 and 120
           or char_length(coalesce(e->>'state', '')) > 120
           or char_length(coalesce(e->>'city', '')) > 120
           or char_length(coalesce(e->>'suburb', '')) > 120);
$$;

create table if not exists public.c2c_route_rules (
  id              uuid primary key default gen_random_uuid(),
  from_places     jsonb not null check (public.c2c_places_valid(from_places)),
  to_places       jsonb not null check (public.c2c_places_valid(to_places)),
  fare_mode       text not null default 'card' check (fare_mode in ('card', 'fixed')),
  add_on_amount   numeric(10,2) not null default 0 check (add_on_amount between 0 and 10000),
  add_on_percent  numeric(6,2) not null default 0 check (add_on_percent between 0 and 500),
  fixed_fare      numeric(10,2) check (fixed_fare is null or fixed_fare between 1 and 100000),
  range_mode      text not null default 'auto' check (range_mode in ('auto', 'set')),
  range_percent   numeric(6,2) not null default 8 check (range_percent between 0 and 90),
  range_low       numeric(10,2),
  range_high      numeric(10,2),
  book_ahead_days integer not null default 14 check (book_ahead_days between 1 and 365),
  min_years_mode  text not null default 'default' check (min_years_mode in ('default', 'set', 'off')),
  min_years       integer check (min_years is null or min_years between 0 and 60),
  -- Room for later: pay-per-seat sharing (not built; only whole_car is matched).
  trip_kind       text not null default 'whole_car' check (trip_kind in ('whole_car', 'per_seat')),
  active          boolean not null default true,
  position        integer not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  constraint c2c_route_rules_fixed check (fare_mode = 'card' or fixed_fare is not null),
  constraint c2c_route_rules_range check (
    range_mode = 'auto'
    or (range_low is not null and range_high is not null and range_low > 0 and range_low <= range_high)),
  constraint c2c_route_rules_years check (min_years_mode <> 'set' or min_years is not null)
);
create index if not exists c2c_route_rules_active_idx on public.c2c_route_rules (position) where active;
comment on table public.c2c_route_rules is
  'City to City (0306): fare and range per route. The most specific rule for the pickup and the drop-off wins.';

drop trigger if exists trg_c2c_route_rules_stamp on public.c2c_route_rules;
create trigger trg_c2c_route_rules_stamp
  before insert or update on public.c2c_route_rules
  for each row execute function public.c2c_stamp();

-- ---- Reading and writing ------------------------------------------------------------------------------
-- Everyone signed in reads (the apps price and check from them); admins with
-- EDIT on City to City write.
do $rls$
declare
  t text;
begin
  foreach t in array array['city_to_city_settings', 'c2c_country_permits', 'c2c_route_rules'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('drop policy if exists %I on public.%I', t || ' read', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select auth.uid()) is not null)',
                   t || ' read', t);
    execute format('drop policy if exists %I on public.%I', t || ' admin insert', t);
    execute format('drop policy if exists %I on public.%I', t || ' admin update', t);
    execute format('drop policy if exists %I on public.%I', t || ' admin delete', t);
    execute format('create policy %I on public.%I for update to authenticated using ((select public.caller_admin_can_write(%L))) with check ((select public.caller_admin_can_write(%L)))',
                   t || ' admin update', t, t, t);
    -- The settings are one row: changed, never added or removed.
    if t <> 'city_to_city_settings' then
      execute format('create policy %I on public.%I for insert to authenticated with check ((select public.caller_admin_can_write(%L)))',
                     t || ' admin insert', t, t);
      execute format('create policy %I on public.%I for delete to authenticated using ((select public.caller_admin_can_write(%L)))',
                     t || ' admin delete', t, t);
    end if;
  end loop;
end
$rls$;

insert into public.admin_table_pages (target, page) values
  ('city_to_city_settings', 'admin-settings-city-to-city'),
  ('c2c_country_permits', 'admin-settings-city-to-city'),
  ('c2c_route_rules', 'admin-settings-city-to-city'),
  ('commission_service_rates', 'admin-settings-commission')
on conflict do nothing;

-- ---- 5. Which rule -----------------------------------------------------------------------------------
-- How specifically [p_spec] holds the trip end [p_place] ({country, state,
-- city, suburb}): suburb 4, city 3, state 2, country 1, 0 when it doesn't.
create or replace function public.c2c_place_rank(p_spec jsonb, p_place jsonb)
returns integer
language sql
immutable
set search_path = public
as $$
  select case p_spec->>'level'
    when 'suburb' then case when public.commission_place_matches(p_spec->>'suburb', p_place->>'suburb')
                              and public.commission_parent_ok(p_spec->>'city', p_place->>'city')
                              and public.commission_parent_ok(p_spec->>'state', p_place->>'state')
                              and public.commission_parent_ok(p_spec->>'country', p_place->>'country') then 4 else 0 end
    when 'city' then case when public.commission_place_matches(p_spec->>'city', p_place->>'city')
                            and public.commission_parent_ok(p_spec->>'state', p_place->>'state')
                            and public.commission_parent_ok(p_spec->>'country', p_place->>'country') then 3 else 0 end
    when 'state' then case when public.commission_place_matches(p_spec->>'state', p_place->>'state')
                             and public.commission_parent_ok(p_spec->>'country', p_place->>'country') then 2 else 0 end
    when 'country' then case when public.commission_place_matches(p_spec->>'country', p_place->>'country') then 1 else 0 end
    else 0
  end;
$$;

-- The most specific of [p_specs] that holds [p_place]; 0 for none.
create or replace function public.c2c_side_rank(p_specs jsonb, p_place jsonb)
returns integer
language sql
immutable
set search_path = public
as $$
  select coalesce(max(public.c2c_place_rank(e, coalesce(p_place, '{}'::jsonb))), 0)
    from jsonb_array_elements(case when jsonb_typeof(p_specs) = 'array' then p_specs else '[]'::jsonb end) e;
$$;

-- The rule for a whole-car trip from [p_pickup] to [p_drop] (each
-- {country, state, city, suburb}); no row: the default. See item 4 above
-- for the order.
create or replace function public.c2c_rule_for(p_pickup jsonb, p_drop jsonb)
returns setof public.c2c_route_rules
language sql
stable
security definer
set search_path = public
as $$
  select (x.r).*
    from (select r, public.c2c_side_rank(r.from_places, p_pickup) as fr, public.c2c_side_rank(r.to_places, p_drop) as tr
            from public.c2c_route_rules r
           where r.active and r.trip_kind = 'whole_car') x
   where x.fr > 0 and x.tr > 0
   order by x.fr + x.tr desc, x.fr desc, (x.r).position asc, (x.r).created_at asc, (x.r).id asc
   limit 1;
$$;
revoke execute on function public.c2c_rule_for(jsonb, jsonb) from public, anon;
grant execute on function public.c2c_rule_for(jsonb, jsonb) to authenticated, service_role;

-- ---- 6. The fare card --------------------------------------------------------------------------------
-- The built-in TEKSI tariff (fare.dart calculateFare, old tariff, ×1).
create or replace function public.c2c_teksi_fare(p_km numeric, p_min numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case when greatest(p_km, 0) <= 1 then 4.00
    else round(4 + greatest(ceil((greatest(p_km, 0) - 1) * 1000 / 200),
                            ceil(greatest(p_min, 0) * 60 * (1 - 1 / greatest(p_km, 0)) / 36)) * 0.35, 2)
  end;
$$;

-- What [p_service] costs for [p_km] km and [p_min] minutes from a pickup
-- at [p_place] on its fare card (see item 5), the currency and the card
-- (null: the service's own rates or the TEKSI tariff).
create or replace function public.c2c_fare_card(p_service text, p_place jsonb, p_km numeric, p_min numeric)
returns table (fare numeric, currency text, tariff_id uuid)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sid text;
  v_vals jsonb;
  v_types text[];
  v_km numeric := greatest(coalesce(p_km, 0), 0);
  v_min numeric := greatest(coalesce(p_min, 0), 0);
  v_country text := lower(btrim(coalesce(p_place->>'country', '')));
  v_state text := lower(btrim(coalesce(p_place->>'state', '')));
  v_city text := lower(btrim(coalesce(p_place->>'city', '')));
  v_suburb text := lower(btrim(coalesce(p_place->>'suburb', '')));
  v_cur text := coalesce((select s.currency from public.city_to_city_settings s where s.id = 1), 'MYR');
  t public.fare_tariffs;
  v_per_km numeric;
  v_taxi boolean;
begin
  select e.id::text, e.values into v_sid, v_vals
    from public.settings_entries e
   where e.category = 'vehicle-services' and lower(btrim(e.values->>'name')) = lower(btrim(coalesce(p_service, '')))
   order by e.position
   limit 1;
  select array_agg(m.id::text) into v_types
    from public.settings_entries m
   where m.category = 'service-settings'
     and lower(btrim(m.values->>'name')) in (
       select lower(btrim(x)) from jsonb_array_elements_text(
         case when jsonb_typeof(v_vals->'serviceTypes') = 'array' then v_vals->'serviceTypes' else '[]'::jsonb end) x);
  v_types := coalesce(v_types, '{}');

  select f.* into t
    from public.fare_tariffs f
   where f.active
     and ((f.vehicle_service is not null and f.vehicle_service = v_sid
           and (f.service_type is null or cardinality(v_types) = 0 or f.service_type = any(v_types)))
          or (f.vehicle_service is null and f.service_type is not null and f.service_type = any(v_types))
          or (f.vehicle_service is null and f.service_type is null))
     and case f.level
       when 'suburb' then v_suburb <> '' and lower(btrim(f.suburb)) = v_suburb and lower(btrim(f.city)) = v_city
                          and lower(btrim(f.state)) = v_state and lower(btrim(f.country)) = v_country
       when 'city' then v_city <> '' and lower(btrim(f.city)) = v_city and lower(btrim(f.state)) = v_state
                        and lower(btrim(f.country)) = v_country
       when 'state' then v_state <> '' and lower(btrim(f.state)) = v_state and lower(btrim(f.country)) = v_country
       when 'country' then v_country <> '' and lower(btrim(f.country)) = v_country
       when 'master' then true
       else false
     end
   order by case f.level when 'suburb' then 0 when 'city' then 1 when 'state' then 2 when 'country' then 3 else 4 end,
            case when f.vehicle_service is not null then 0 when f.service_type is not null then 1 else 2 end,
            f.created_at, f.id
   limit 1;
  if t.id is not null then
    return query select round(greatest(t.minimum_fare, t.base_fare + t.per_km * v_km + t.per_minute * v_min)
                              + t.booking_fee, 2), t.currency, t.id;
    return;
  end if;

  -- The service's own rates (0300); a metered taxi has none.
  v_per_km := case when v_vals->>'costPerKm' ~ '^[0-9]+(\.[0-9]+)?$' then (v_vals->>'costPerKm')::numeric end;
  v_taxi := lower(coalesce(v_vals->>'name', '') || ' ' || coalesce(v_vals->>'serviceTypes', '')) ~ '(teksi|taxi)';
  if v_per_km is not null and v_per_km > 0 and not coalesce(v_taxi, false) then
    return query select round(greatest(
      case when v_vals->>'minFareAmount' ~ '^[0-9]+(\.[0-9]+)?$' then (v_vals->>'minFareAmount')::numeric else 0 end,
      v_km * v_per_km
        + v_min * case when v_vals->>'costPerMin' ~ '^[0-9]+(\.[0-9]+)?$' then (v_vals->>'costPerMin')::numeric else 0 end), 2),
      v_cur, null::uuid;
    return;
  end if;
  return query select public.c2c_teksi_fare(v_km, v_min), v_cur, null::uuid;
end;
$$;
revoke execute on function public.c2c_fare_card(text, jsonb, numeric, numeric) from public, anon;
grant execute on function public.c2c_fare_card(text, jsonb, numeric, numeric) to authenticated, service_role;

-- The minimum years of driving for a trip under [r] (null: the default
-- rule), or null for no restriction.
create or replace function public.c2c_min_years(r public.c2c_route_rules)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select case
    when not s.min_years_on then null
    when r.id is null or r.min_years_mode = 'default' then s.min_years
    when r.min_years_mode = 'set' then r.min_years
    else null
  end
  from public.city_to_city_settings s where s.id = 1;
$$;
revoke execute on function public.c2c_min_years(public.c2c_route_rules) from public, anon, authenticated;

-- The quote for a whole-car trip: the pickup at (p_lat, p_lng) and named
-- [p_pickup], to [p_drop] (each {country, state, city, suburb}), [p_km] km
-- and [p_min] minutes, for [p_service].
create or replace function public.c2c_quote(
  p_lat double precision,
  p_lng double precision,
  p_pickup jsonb,
  p_drop jsonb,
  p_km numeric,
  p_min numeric,
  p_service text default 'City to City'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  pl record;
  v_pick jsonb;
  r public.c2c_route_rules;
  s public.city_to_city_settings;
  c record;
  v_mode text;
  v_add numeric;
  v_pct numeric;
  v_range text;
  v_rpct numeric;
  v_card numeric;
  v_sugg numeric;
  v_low numeric;
  v_high numeric;
  v_cur text;
begin
  if p_km is null or p_km < 0 or p_km > 5000 or p_min is null or p_min < 0 or p_min > 10000 then
    raise exception 'C2C_BAD_TRIP' using errcode = '22023', hint = 'The distance or the time is out of range.';
  end if;
  select * into pl from public.commission_places(p_lat, p_lng, p_pickup->>'country', p_pickup->>'state',
                                                 p_pickup->>'city', p_pickup->>'suburb');
  v_pick := jsonb_build_object('country', pl.place_country, 'state', pl.place_state,
                               'city', pl.place_city, 'suburb', pl.place_suburb);
  select * into s from public.city_to_city_settings where id = 1;
  select * into r from public.c2c_rule_for(v_pick, p_drop);
  v_cur := coalesce(s.currency, 'MYR');

  if r.id is null then
    v_mode := 'card';
    v_add := coalesce(s.default_add_on_amount, 0);
    v_pct := coalesce(s.default_add_on_percent, 0);
    v_range := coalesce(s.default_range_mode, 'auto');
    v_rpct := coalesce(s.default_range_percent, 8);
    v_low := s.default_range_low;
    v_high := s.default_range_high;
  else
    v_mode := r.fare_mode;
    v_add := r.add_on_amount;
    v_pct := r.add_on_percent;
    v_range := r.range_mode;
    v_rpct := r.range_percent;
    v_low := r.range_low;
    v_high := r.range_high;
  end if;

  if v_mode = 'fixed' then
    v_sugg := round(r.fixed_fare, 2);
  else
    select * into c from public.c2c_fare_card(p_service, v_pick, p_km, p_min);
    v_card := c.fare;
    v_cur := coalesce(c.currency, v_cur);
    v_sugg := round(v_card + v_add + v_card * v_pct / 100, 2);
  end if;
  if v_range = 'auto' then
    v_low := round(v_sugg * (1 - v_rpct / 100));
    v_high := round(v_sugg * (1 + v_rpct / 100));
  end if;

  return jsonb_build_object(
    'ruleId', r.id,
    'fareMode', v_mode,
    'fareCard', v_card,
    'addOn', case when v_mode = 'fixed' then 0 else v_sugg - v_card end,
    'suggested', v_sugg,
    'low', v_low,
    'high', v_high,
    'rangeMode', v_range,
    'rangePercent', v_rpct,
    'bookAheadDays', coalesce(r.book_ahead_days, s.default_book_ahead_days, 14),
    'minYears', public.c2c_min_years(r),
    'currency', v_cur,
    'pickup', v_pick);
end;
$$;
revoke execute on function public.c2c_quote(double precision, double precision, jsonb, jsonb, numeric, numeric, text)
  from public, anon;
grant execute on function public.c2c_quote(double precision, double precision, jsonb, jsonb, numeric, numeric, text)
  to authenticated, service_role;

-- ---- 7. Where it is offered ----------------------------------------------------------------------------
-- Whether [p_service] (a Vehicle Service, active) is on at [p_place] by the
-- region service switches (0302; a place or service they don't know: on).
create or replace function public.c2c_available_at(p_place jsonb, p_service text default 'City to City')
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.settings_entries e
                  where e.category = 'vehicle-services'
                    and lower(btrim(e.values->>'name')) = lower(btrim(coalesce(p_service, '')))
                    and lower(coalesce(e.values->>'status', 'true')) not in ('false', '0', 'off', 'inactive'))
     and coalesce(public.service_offered_at(p_service, p_place->>'country', p_place->>'state',
                                            p_place->>'city', p_place->>'suburb'), true);
$$;
revoke execute on function public.c2c_available_at(jsonb, text) from public, anon;
grant execute on function public.c2c_available_at(jsonb, text) to authenticated, service_role;

-- ---- 8. Drivers ----------------------------------------------------------------------------------------
alter table public.partners add column if not exists driving_since date;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'partners_driving_since_range') then
    alter table public.partners add constraint partners_driving_since_range
      check (driving_since is null or driving_since >= date '1930-01-01');
  end if;
end $$;
comment on column public.partners.driving_since is
  'When the driver''s licence was first issued (0306): City to City counts driving experience from it.';

-- When driver [p_uid] started driving: partners.driving_since, else the
-- earliest start date of an approved driving licence document.
create or replace function public.c2c_driving_since(p_uid uuid)
returns date
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select min(p.driving_since) from public.partners p where p.auth_user_id = p_uid),
    (select min(d.start_date)
       from public.provider_documents d
       join public.partners p on p.id = d.partner_id
      where p.auth_user_id = p_uid and d.status = 'Approved'
        and d.start_date is not null and d.start_date <= current_date
        and (d.read_fields->>'kind' = 'licence' or d.doc_name ~* '(driving|driver).*(licen[cs]e)|lesen memandu')));
$$;
revoke execute on function public.c2c_driving_since(uuid) from public, anon, authenticated;

-- Whether driver [p_uid] holds permit type [p_type]: its latest document
-- approved and in date (0254), on the driver or on the vehicle they drive
-- now (else any of their vehicles).
create or replace function public.c2c_holds_permit(p_uid uuid, p_type uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t public.permit_types;
  v_vehicle uuid;
begin
  select * into t from public.permit_types where id = p_type;
  if t.id is null or p_uid is null then
    return false;
  end if;
  if t.applies_to = 'driver' then
    return t.document_id is not null and exists (
      select 1 from public.partners p
       cross join lateral (
         select d.status, d.expiry_date from public.provider_documents d
          where d.partner_id = p.id and d.doc_id = t.document_id
          order by d.uploaded_at desc limit 1) d
       where p.auth_user_id = p_uid and public.permit_doc_state(d.status, d.expiry_date) = 'with');
  end if;
  select s.vehicle_id into v_vehicle from public.vehicle_active_session s where s.user_id = p_uid limit 1;
  return exists (
    select 1 from public.vehicle v
     cross join lateral (
       select d.status, d.expiry_date from public.vehicle_documents d
        where d.vehicle_id = v.id and d.permit_type_id = t.id
        order by d.uploaded_at desc limit 1) d
     where (case when v_vehicle is not null then v.id = v_vehicle
                 else v.auth_user_id = p_uid
                      or exists (select 1 from public.vehicle_user_assignment a
                                  where a.vehicle_id = v.id and a.user_id = p_uid and a.is_active) end)
       and public.permit_doc_state(d.status, d.expiry_date) = 'with');
end;
$$;
revoke execute on function public.c2c_holds_permit(uuid, uuid) from public, anon, authenticated;

-- Whether driver [p_driver] may take a whole-car trip from [p_pickup] to
-- [p_drop] (and through the countries [p_via]): {ok, minYears, years,
-- drivingSince, experienceOk, needs: [{permitTypeId, name, shortName,
-- appliesTo, country}], ruleId}. The driver themself, an admin or the
-- server.
create or replace function public.c2c_driver_check(p_driver uuid, p_pickup jsonb, p_drop jsonb,
                                                   p_via text[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.c2c_route_rules;
  v_min integer;
  v_since date;
  v_years integer;
  v_exp boolean;
  v_needs jsonb;
  v_countries text[];
begin
  if auth.uid() is not null and auth.uid() is distinct from p_driver and not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.c2c_rule_for(p_pickup, p_drop);
  v_min := public.c2c_min_years(r);
  v_since := public.c2c_driving_since(p_driver);
  v_years := case when v_since is null then null else extract(year from age(current_date, v_since))::integer end;
  v_exp := v_min is null or (v_years is not null and v_years >= v_min);
  select array_agg(distinct btrim(c)) into v_countries
    from unnest(array[p_pickup->>'country', p_drop->>'country'] || coalesce(p_via, '{}')) c
   where coalesce(btrim(c), '') <> '';
  select coalesce(jsonb_agg(jsonb_build_object('permitTypeId', x.id, 'name', x.name, 'shortName', x.short_name,
                                               'appliesTo', x.applies_to, 'country', x.country)
                            order by x.country, x.position, x.name), '[]'::jsonb)
    into v_needs
    from (select distinct on (t.id) t.id, t.name, t.short_name, t.applies_to, cp.country, cp.position
            from public.c2c_country_permits cp
            join public.permit_types t on t.id = cp.permit_type_id and t.active
           where exists (select 1 from unnest(coalesce(v_countries, '{}')) c
                          where public.commission_place_matches(cp.country, c))
             and not public.c2c_holds_permit(p_driver, t.id)
           order by t.id, cp.position) x;
  return jsonb_build_object(
    'ok', v_exp and jsonb_array_length(v_needs) = 0,
    'minYears', v_min,
    'years', v_years,
    'drivingSince', v_since,
    'experienceOk', v_exp,
    'needs', v_needs,
    'ruleId', r.id);
end;
$$;
revoke execute on function public.c2c_driver_check(uuid, jsonb, jsonb, text[]) from public, anon;
grant execute on function public.c2c_driver_check(uuid, jsonb, jsonb, text[]) to authenticated, service_role;

create or replace function public.c2c_driver_ok(p_driver uuid, p_pickup jsonb, p_drop jsonb, p_via text[] default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((public.c2c_driver_check(p_driver, p_pickup, p_drop, p_via)->>'ok')::boolean, false);
$$;
revoke execute on function public.c2c_driver_ok(uuid, jsonb, jsonb, text[]) from public, anon;
grant execute on function public.c2c_driver_ok(uuid, jsonb, jsonb, text[]) to authenticated, service_role;

-- ---- 9. Commission per service -------------------------------------------------------------------------
create table if not exists public.commission_service_rates (
  id           uuid primary key default gen_random_uuid(),
  -- The Vehicle Services entry's id.
  service_id   text not null unique check (char_length(btrim(service_id)) between 1 and 64),
  service_name text check (service_name is null or char_length(service_name) <= 120),
  rate         numeric(6,4) not null check (rate >= 0 and rate < 1),
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  updated_by   uuid
);
comment on table public.commission_service_rates is
  'Commission per Vehicle Service (0306): used instead of the place rate; a driver''s own rate still comes first.';

drop trigger if exists trg_commission_service_rates_stamp on public.commission_service_rates;
create trigger trg_commission_service_rates_stamp
  before insert or update on public.commission_service_rates
  for each row execute function public.c2c_stamp();

alter table public.commission_service_rates enable row level security;
revoke all on public.commission_service_rates from anon;
grant select, insert, update, delete on public.commission_service_rates to authenticated;
grant all on public.commission_service_rates to service_role;
drop policy if exists "commission_service_rates admin read" on public.commission_service_rates;
create policy "commission_service_rates admin read" on public.commission_service_rates
  for select to authenticated using ((select public.caller_is_admin()));
drop policy if exists "commission_service_rates admin insert" on public.commission_service_rates;
create policy "commission_service_rates admin insert" on public.commission_service_rates
  for insert to authenticated with check ((select public.caller_admin_can_write('commission_service_rates')));
drop policy if exists "commission_service_rates admin update" on public.commission_service_rates;
create policy "commission_service_rates admin update" on public.commission_service_rates
  for update to authenticated using ((select public.caller_admin_can_write('commission_service_rates')))
  with check ((select public.caller_admin_can_write('commission_service_rates')));
drop policy if exists "commission_service_rates admin delete" on public.commission_service_rates;
create policy "commission_service_rates admin delete" on public.commission_service_rates
  for delete to authenticated using ((select public.caller_admin_can_write('commission_service_rates')));

-- The rate for a trip by [p_user] at the place named, for [p_service] (a
-- Vehicle Service name or entry id): the driver's own rate, else the
-- service's, else the place's (the 7-argument form, 0216).
create or replace function public.commission_resolve(
  p_user uuid,
  p_lat double precision,
  p_lng double precision,
  p_country text,
  p_state text,
  p_city text,
  p_suburb text,
  p_service text
)
returns table (rate numeric, rule_id uuid, level text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v record;
  sr record;
  v_sid text;
begin
  select * into v from public.commission_resolve(p_user, p_lat, p_lng, p_country, p_state, p_city, p_suburb);
  if v.level is distinct from 'user' and coalesce(btrim(p_service), '') <> '' then
    v_sid := coalesce(
      (select e.id::text from public.settings_entries e
        where e.category = 'vehicle-services' and e.id::text = lower(btrim(p_service)) limit 1),
      public.vehicle_service_id_of(p_service));
    select c.rate, c.id into sr from public.commission_service_rates c
     where c.active and c.service_id = v_sid
     limit 1;
    if found then
      return query select sr.rate, sr.id, 'service'::text;
      return;
    end if;
  end if;
  return query select v.rate, v.rule_id, v.level;
end;
$$;
revoke execute on function public.commission_resolve(uuid, double precision, double precision, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.commission_resolve(uuid, double precision, double precision, text, text, text, text, text)
  to service_role;

-- ---- The lock (0224) with the service ------------------------------------------------------------------
create or replace function public.ride_requests_lock_commission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v record;
  t record;
  pm record;
begin
  if new.partner_id is null or new.status not in ('accepted', 'arrived', 'on_trip') then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.commission_locked_at is not null
     and old.partner_id is not distinct from new.partner_id then
    return new;
  end if;
  begin
    select * into v from public.commission_resolve(
      new.partner_id, new.pickup_lat, new.pickup_lng, new.country, new.state, new.city, new.suburb, new.service);
    select * into t from public.commission_apply_tiers(new.partner_id, v.rate, v.level);
    select * into pm from public.commission_apply_promotions(
      new.partner_id, t.rate, v.level, now(), new.timezone, new.service,
      new.pickup_lat, new.pickup_lng, new.country, new.state, new.city, new.suburb);
    new.commission_base_rate := v.rate;
    new.commission_rate := pm.rate;
    -- The tier only when it gave the rate; a lower promotion replaces it.
    new.commission_tier_id := case when pm.promotion_id is null then t.tier_id end;
    new.commission_promotion_id := pm.promotion_id;
    new.commission_rule_id := v.rule_id;
    new.commission_locked_at := now();
  exception when others then
    -- Never holds up the accept: the rate is found again at completion.
    raise warning 'ride % commission not locked: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;
revoke execute on function public.ride_requests_lock_commission() from public, anon, authenticated;

-- ---- Charging (0224) with the service --------------------------------------------------------------------
create or replace function public.ride_charge_commission(p_ride uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_fare numeric;
  v_base numeric;
  v_rate numeric;
  v_rule uuid;
  v_tier uuid;
  v_promo uuid;
  v_amount numeric(12,2);
  v record;
  t record;
  pm record;
begin
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.status <> 'completed' or r.partner_id is null or r.commission_charged_at is not null then
    return;
  end if;

  v_fare := round(coalesce(r.ride_fare, r.fare, 0), 2);
  if not public.ride_money_ok(v_fare) or v_fare <= 0 then
    return;
  end if;
  v_base := public.commission_base(r);
  if not public.ride_money_ok(v_base) then
    v_base := v_fare;
  end if;

  if r.commission_locked_at is not null and r.commission_rate is not null then
    v_rate := r.commission_rate;
    v_rule := r.commission_rule_id;
    v_tier := r.commission_tier_id;
    v_promo := r.commission_promotion_id;
  else
    -- Never locked (accepted before 0216, or the lock failed): found now.
    select * into v from public.commission_resolve(
      r.partner_id, r.pickup_lat, r.pickup_lng, r.country, r.state, r.city, r.suburb, r.service);
    select * into t from public.commission_apply_tiers(r.partner_id, v.rate, v.level);
    select * into pm from public.commission_apply_promotions(
      r.partner_id, t.rate, v.level, coalesce(r.accepted_at, now()), r.timezone, r.service,
      r.pickup_lat, r.pickup_lng, r.country, r.state, r.city, r.suburb);
    v_rate := pm.rate;
    v_rule := v.rule_id;
    v_tier := case when pm.promotion_id is null then t.tier_id end;
    v_promo := pm.promotion_id;
  end if;
  if v_rate is null or v_rate < 0 or v_rate >= 1 then
    return;
  end if;

  v_amount := round(v_base * v_rate, 2);

  if v_amount > 0 then
    -- Ledger-driven: trg_wallet_tx_apply moves the balance.
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
    values (r.partner_id, 'get_credit', 'commission', -v_amount,
            'Ride commission ' || round(v_rate * 100, 1) || '% of ' ||
            coalesce(r.currency, 'RM') || ' ' || v_base);
  end if;

  update public.ride_requests
     set commission_rate = v_rate,
         commission_rule_id = v_rule,
         commission_tier_id = v_tier,
         commission_promotion_id = v_promo,
         commission_base_amount = v_base,
         commission_amount = v_amount,
         commission_charged_at = now(),
         commission_error = null
   where id = p_ride;
end;
$$;
revoke all on function public.ride_charge_commission(uuid) from public, anon, authenticated, service_role;

-- ---- Live in the apps and the admin pages ----------------------------------------------------------------
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['city_to_city_settings', 'c2c_country_permits', 'c2c_route_rules',
                             'commission_service_rates'] loop
      if not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

notify pgrst, 'reload schema';
