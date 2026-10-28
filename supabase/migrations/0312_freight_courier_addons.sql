-- ============================================================================
-- 0312 — Freight and Courier add-ons: parcel cover, round trip, stairs, the
-- cold truck and cash on delivery for the item (docs/KIV.md, "Freight and
-- Courier, after launch").
--
-- Version 20261028050000 (0312_freight_courier_addons). Re-runnable: tables,
-- columns and indexes "if not exists", functions "create or replace",
-- policies and triggers dropped first, the Default rule only where missing,
-- and the functions it edits in place skipped once edited.
--
-- 1. The rules (delivery_addon_rules): a Default rule and a rule per region
--    (country, state, city or suburb, named and keyed as Ride Options by
--    place, 0253). For a pickup the place is 0253's (ride_option_place) and
--    the rules are laid over each other from Default down to the suburb: a
--    region rule keeps only what it sets, field by field, the rest follows
--    the rule above. Every value is the admin's (Admin > Display Settings >
--    Ride Options > Add-ons, cover and cash on delivery), and each add-on
--    has its own switch per region ("on"). The built-in values
--    (delivery_addon_defaults) hold where nothing is set; the Default rule is
--    seeded with them, every add-on OFF, so nothing changes for riders until
--    the owner switches one on.
--      cover      {on, pct, min, max, claimDays, excluded[]}   both kinds
--      roundTrip  {on, returnPct, freeWait, waitPerMin, maxWait} both kinds
--      stairs     {on, perFloor, maxFloors, helperFrom}         Freight
--      cold       {on, levels[{id, name, charge}]}              Freight
--      cod        {on, pct, min, max, carry}                    Courier
-- 2. A booking (ride_requests columns, kept by a booking for later):
--      parcel_cover   the declared value (0267's declared_value) is covered;
--                     a covered parcel may be declared up to the cover's
--                     highest value instead of the place's declared cap
--                     (ride_freight_problem / ride_courier_problem gain
--                     p_cover); option_charges line 'parcel-cover' = the
--                     premium, pct of the value, at least min.
--      round_trip     one booking, one driver, two legs; line 'round-trip' =
--                     returnPct of the outward fare (the offer, the fare less
--                     its option lines). At the drop-off the driver starts
--                     the free wait (delivery_return_arrived); starting back
--                     (delivery_return_start) adds the minutes past freeWait,
--                     at most maxWait, at waitPerMin to the fare. The ride
--                     completes back at the pickup, after the return leg.
--                     Commission is on the whole fare, both legs: the return
--                     leg's line is never left out of it
--                     (ride_option_charges_off).
--      stairs_pickup, stairs_drop  floors without a lift, 0 to maxFloors
--                     each; line 'stairs' = floors x perFloor; from
--                     helperFrom floors at either end a helper option
--                     (helper-1 / helper-2, 0267) is required
--                     (STAIRS_HELPER_REQUIRED).
--      cold_level     a temperature level's id; line 'cold-truck' = its
--                     charge; only on a Vehicle Service flagged refrigerated
--                     (values.refrigerated, beside 0267's closedBody), and
--                     only drivers whose vehicle's service is refrigerated
--                     read, offer on or take it.
--      cod_amount     the cash the courier collects for the item, up to max;
--                     cod_fee (the server's: pct, at least min) is kept from
--                     the sender's payout. A driver takes a COD request only
--                     while their COD in progress stays within carry and
--                     their GET.wallet holds it (COD_CARRY_LIMIT,
--                     COD_WALLET_SHORT). At hand-over (cod_collected) the
--                     amount leaves the driver's GET.wallet and reaches the
--                     sender's less the fee: the driver keeps the cash.
--                     "Recipient won't pay" (cod_refused) brings the parcel
--                     back at the return rate (roundTrip.returnPct of the
--                     outward fare; nothing more on a round trip) and tells
--                     the sender; no recipient code is then needed.
--    Every line (kind) must be the region's rule for what is booked, 0 for
--    what isn't, as 0253 / 0267 check theirs (ADDON_CHARGE_CHANGED). The
--    rule's values at booking are kept on the ride (addon_terms) and the
--    return leg, the wait, the COD fee and the claim days read them.
-- 3. Covered parcels: the pickup and hand-over photos are 0267's proof of
--    delivery (ride-cargo, private), already required on every Freight and
--    Courier trip. The premium is the platform's: taken from the driver's
--    GET.credit when the trip completes (the driver collected it in the
--    fare), and left out of the commission. Claims (cover_claims; support
--    tickets have no ride link): the sender files one per ride within the
--    claim days after the trip ends (cover_claim_file), up to the declared
--    value; an admin approves (paid to the sender's GET.wallet) or rejects
--    it (cover_claim_decide, in admin_audit_log).
-- ============================================================================

-- ---- 1. The rules ------------------------------------------------------------------------------
-- The values that hold where no rule sets them.
create or replace function public.delivery_addon_defaults()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'cover', jsonb_build_object('on', false, 'pct', 1, 'min', 2, 'max', 5000, 'claimDays', 7,
      'excluded', jsonb_build_array('Cash, cards and vouchers', 'Jewellery, watches and precious metals',
                                    'Glass and fragile items not packed for transport', 'Perishable food and plants',
                                    'Original documents and IDs')),
    'roundTrip', jsonb_build_object('on', false, 'returnPct', 80, 'freeWait', 15, 'waitPerMin', 0.5, 'maxWait', 120),
    'stairs', jsonb_build_object('on', false, 'perFloor', 15, 'maxFloors', 10, 'helperFrom', 3),
    'cold', jsonb_build_object('on', false, 'levels', jsonb_build_array(
      jsonb_build_object('id', 'chilled', 'name', 'Chilled 0 to 8 °C', 'charge', 60),
      jsonb_build_object('id', 'frozen', 'name', 'Frozen -18 °C', 'charge', 90))),
    'cod', jsonb_build_object('on', false, 'pct', 2, 'min', 1, 'max', 1000, 'carry', 1000));
$$;

-- Whether [p_value] may stand for [p_field] of the add-on [p_group].
create or replace function public.delivery_addon_field_ok(p_group text, p_field text, p_value jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  lo numeric;
  hi numeric;
  whole boolean := false;
  n numeric;
begin
  if p_field = 'on' then
    return jsonb_typeof(p_value) = 'boolean';
  end if;
  if p_group = 'cover' and p_field = 'excluded' then
    return jsonb_typeof(p_value) = 'array' and jsonb_array_length(p_value) <= 100
       and not exists (select 1 from jsonb_array_elements(p_value) e
                        where jsonb_typeof(e) <> 'string' or char_length(btrim(e #>> '{}')) not between 1 and 120);
  end if;
  if p_group = 'cold' and p_field = 'levels' then
    return jsonb_typeof(p_value) = 'array' and jsonb_array_length(p_value) <= 20
       and not exists (
         select 1 from jsonb_array_elements(p_value) e
          where not coalesce(jsonb_typeof(e) = 'object'
                             and (e->>'id') ~ '^[a-z0-9-]{1,40}$'
                             and char_length(btrim(e->>'name')) between 1 and 60
                             and jsonb_typeof(e->'charge') = 'number'
                             and (e->>'charge')::numeric between 0 and 100000, false))
       and (select count(distinct e->>'id') = count(*) from jsonb_array_elements(p_value) e);
  end if;
  select b.lo, b.hi, b.whole into lo, hi, whole
    from (values
      ('cover', 'pct', 0, 100, false), ('cover', 'min', 0, 100000, false), ('cover', 'max', 0, 1000000, false),
      ('cover', 'claimDays', 1, 365, true),
      ('roundTrip', 'returnPct', 0, 100, false), ('roundTrip', 'freeWait', 0, 1440, true),
      ('roundTrip', 'waitPerMin', 0, 10000, false), ('roundTrip', 'maxWait', 0, 1440, true),
      ('stairs', 'perFloor', 0, 100000, false), ('stairs', 'maxFloors', 0, 200, true),
      ('stairs', 'helperFrom', 0, 200, true),
      ('cod', 'pct', 0, 100, false), ('cod', 'min', 0, 100000, false), ('cod', 'max', 0, 1000000, false),
      ('cod', 'carry', 0, 1000000, false)
    ) as b(g, f, lo, hi, whole)
   where b.g = p_group and b.f = p_field;
  if lo is null or jsonb_typeof(p_value) <> 'number' then
    return false;
  end if;
  n := (p_value #>> '{}')::numeric;
  return n between lo and hi and (not whole or n = trunc(n));
end;
$$;

-- A rule's values: only the five add-ons, each an object of known fields.
create or replace function public.delivery_addon_values_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(p) = 'object'
     and pg_column_size(p) <= 32768
     and not exists (select 1 from jsonb_each(p) g
                      where g.key not in ('cover', 'roundTrip', 'stairs', 'cold', 'cod')
                         or jsonb_typeof(g.value) <> 'object')
     and not exists (select 1 from jsonb_each(p) g, jsonb_each(g.value) f
                      where not coalesce(public.delivery_addon_field_ok(g.key, f.key, f.value), false));
$$;

create table if not exists public.delivery_addon_rules (
  id         uuid primary key default gen_random_uuid(),
  level      text not null check (level in ('default', 'country', 'state', 'city', 'suburb')),
  country    text check (country is null or char_length(btrim(country)) between 1 and 120),
  state      text check (state is null or char_length(btrim(state)) between 1 and 120),
  city       text check (city is null or char_length(btrim(city)) between 1 and 120),
  suburb     text check (suburb is null or char_length(btrim(suburb)) between 1 and 120),
  place_key  text generated always as (public.ride_option_place_key(level, country, state, city, suburb)) stored,
  values     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint delivery_addon_rules_names check (
    (level = 'default' and country is null and state is null and city is null and suburb is null)
    or (level = 'country' and country is not null and state is null and city is null and suburb is null)
    or (level = 'state' and country is not null and state is not null and city is null and suburb is null)
    or (level = 'city' and country is not null and state is not null and city is not null and suburb is null)
    or (level = 'suburb' and country is not null and state is not null and city is not null and suburb is not null)),
  constraint delivery_addon_rules_valid check (public.delivery_addon_values_valid(values))
);
create unique index if not exists delivery_addon_rules_key_uidx on public.delivery_addon_rules (place_key);
comment on table public.delivery_addon_rules is
  'Freight and Courier add-ons (0312): parcel cover, round trip, stairs, cold truck, cash on delivery. Default and a rule per country / state / city / suburb; a region rule keeps only what it sets.';

drop trigger if exists trg_delivery_addon_rules_updated_at on public.delivery_addon_rules;
create trigger trg_delivery_addon_rules_updated_at before update on public.delivery_addon_rules
  for each row execute function public.set_updated_at();

alter table public.delivery_addon_rules enable row level security;
revoke all on public.delivery_addon_rules from anon;
grant select, insert, update, delete on public.delivery_addon_rules to authenticated;
drop policy if exists "delivery_addon_rules read" on public.delivery_addon_rules;
drop policy if exists "delivery_addon_rules admin insert" on public.delivery_addon_rules;
drop policy if exists "delivery_addon_rules admin update" on public.delivery_addon_rules;
drop policy if exists "delivery_addon_rules admin delete" on public.delivery_addon_rules;
-- Senders read them to price what they book; the server checks them.
create policy "delivery_addon_rules read" on public.delivery_addon_rules for select to authenticated using (true);
create policy "delivery_addon_rules admin insert" on public.delivery_addon_rules for insert to authenticated
  with check ((select public.caller_admin_can_write('delivery_addon_rules')));
create policy "delivery_addon_rules admin update" on public.delivery_addon_rules for update to authenticated
  using ((select public.caller_admin_can_write('delivery_addon_rules')))
  with check ((select public.caller_admin_can_write('delivery_addon_rules')));
create policy "delivery_addon_rules admin delete" on public.delivery_addon_rules for delete to authenticated
  using ((select public.caller_admin_can_write('delivery_addon_rules')));

insert into public.admin_table_pages (target, page) values
  ('delivery_addon_rules', 'admin-settings-display')
on conflict do nothing;

-- The Default rule: the built-in values, every add-on off.
insert into public.delivery_addon_rules (level, values)
values ('default', public.delivery_addon_defaults())
on conflict (place_key) do nothing;

-- [p_base] with each add-on's fields that [p_over] sets laid over it.
create or replace function public.delivery_addons_merge(p_base jsonb, p_over jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(jsonb_object_agg(g.key,
           case when jsonb_typeof(p_over->g.key) = 'object' and jsonb_typeof(g.value) = 'object'
                then g.value || (p_over->g.key) else g.value end), '{}'::jsonb)
    from jsonb_each(p_base) g;
$$;

-- What holds at a place: the built-in values, then Default, the country,
-- state, city and suburb named, each over the one before.
create or replace function public.delivery_addons_at(p_country text, p_state text, p_city text, p_suburb text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.delivery_addon_rules;
  v jsonb := public.delivery_addon_defaults();
  k text[] := array[''];
  c text := lower(btrim(coalesce(p_country, '')));
  s text := lower(btrim(coalesce(p_state, '')));
  t text := lower(btrim(coalesce(p_city, '')));
  b text := lower(btrim(coalesce(p_suburb, '')));
begin
  if c <> '' then
    k := k || c;
    if s <> '' then
      k := k || (c || '|' || s);
      if t <> '' then
        k := k || (c || '|' || s || '|' || t);
        if b <> '' then
          k := k || (c || '|' || s || '|' || t || '|' || b);
        end if;
      end if;
    end if;
  end if;
  for r in
    select x.* from public.delivery_addon_rules x
     where x.place_key = any (k)
     order by case x.level when 'default' then 0 when 'country' then 1 when 'state' then 2 when 'city' then 3 else 4 end
  loop
    v := public.delivery_addons_merge(v, r.values);
  end loop;
  return v;
end;
$$;

-- What holds at a pickup (0253's place for it).
create or replace function public.delivery_addons_for_point(p_lat double precision, p_lng double precision,
                                                            p_country text, p_state text, p_city text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.delivery_addons_at(p.country, p.state, p.city, p.suburb)
    from public.ride_option_place(p_lat, p_lng, p_country, p_state, p_city) p;
$$;
revoke execute on function public.delivery_addons_at(text, text, text, text),
  public.delivery_addons_for_point(double precision, double precision, text, text, text) from public, anon;
grant execute on function public.delivery_addons_at(text, text, text, text),
  public.delivery_addons_for_point(double precision, double precision, text, text, text) to authenticated, service_role;

-- A number of an add-on's values; 0 when not one.
create or replace function public.delivery_num(p jsonb, p_key text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case when jsonb_typeof(p->p_key) = 'number' then (p->>p_key)::numeric else 0 end;
$$;

-- The amounts, each to the cent (lib/src/core/delivery_addons.dart works
-- them out the same way).
create or replace function public.delivery_cover_premium(p_value numeric, p_cover jsonb)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select round(greatest(public.delivery_num(p_cover, 'min'),
                        greatest(coalesce(p_value, 0), 0) * public.delivery_num(p_cover, 'pct') / 100), 2);
$$;

create or replace function public.delivery_return_charge(p_outward numeric, p_round jsonb)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select round(greatest(coalesce(p_outward, 0), 0) * public.delivery_num(p_round, 'returnPct') / 100, 2);
$$;

create or replace function public.delivery_return_wait_fee(p_minutes integer, p_round jsonb)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select round(greatest(0, least(greatest(coalesce(p_minutes, 0), 0), public.delivery_num(p_round, 'maxWait'))
                           - public.delivery_num(p_round, 'freeWait'))
               * public.delivery_num(p_round, 'waitPerMin'), 2);
$$;

create or replace function public.delivery_cod_fee(p_amount numeric, p_cod jsonb)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select least(greatest(coalesce(p_amount, 0), 0),
               round(greatest(public.delivery_num(p_cod, 'min'),
                              greatest(coalesce(p_amount, 0), 0) * public.delivery_num(p_cod, 'pct') / 100), 2));
$$;

-- A temperature level of [p_cold] by id; null when there is none.
create or replace function public.delivery_cold_level(p_cold jsonb, p_id text)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select e from jsonb_array_elements(case when jsonb_typeof(p_cold->'levels') = 'array'
                                          then p_cold->'levels' else '[]'::jsonb end) e
   where e->>'id' = p_id
   limit 1;
$$;

-- The total of a booking's lines of [p_kind].
create or replace function public.delivery_lines_of(p_lines jsonb, p_kind text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select coalesce(sum((e->>'amount')::numeric), 0)
    from jsonb_array_elements(case when jsonb_typeof(p_lines) = 'array' then p_lines else '[]'::jsonb end) e
   where e->>'kind' = p_kind and jsonb_typeof(e->'amount') = 'number';
$$;

-- ---- 2. The cold truck flag ----------------------------------------------------------------------
-- Whether a Vehicle Service (an entry id, or a ride's service by name) is
-- refrigerated (values.refrigerated, set in Admin > Vehicle Services).
create or replace function public.vehicle_service_refrigerated_id(p_service_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select e.values->'refrigerated' = 'true'::jsonb from public.settings_entries e
                    where e.id::text = p_service_id and e.category = 'vehicle-services'), false);
$$;

create or replace function public.vehicle_service_refrigerated(p_service text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.vehicle_service_refrigerated_id(public.vehicle_service_id_of(p_service));
$$;

-- Whether a driver's vehicle (its approved service) is refrigerated.
create or replace function public.driver_takes_cold(p_driver uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.vehicle_service_refrigerated_id(public.driver_vehicle_service(p_driver));
$$;

create or replace function public.caller_takes_cold()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and public.driver_takes_cold(auth.uid());
$$;
revoke execute on function public.vehicle_service_refrigerated_id(text), public.vehicle_service_refrigerated(text),
  public.driver_takes_cold(uuid), public.caller_takes_cold() from public, anon;
revoke execute on function public.driver_takes_cold(uuid) from authenticated;
grant execute on function public.vehicle_service_refrigerated_id(text), public.vehicle_service_refrigerated(text),
  public.caller_takes_cold() to authenticated, service_role;
grant execute on function public.driver_takes_cold(uuid) to service_role;

-- ---- 3. The booking --------------------------------------------------------------------------------
alter table public.ride_requests add column if not exists parcel_cover boolean;
alter table public.ride_requests add column if not exists round_trip boolean;
alter table public.ride_requests add column if not exists stairs_pickup integer;
alter table public.ride_requests add column if not exists stairs_drop integer;
alter table public.ride_requests add column if not exists cold_level text;
alter table public.ride_requests add column if not exists cod_amount numeric;
alter table public.ride_requests add column if not exists cod_fee numeric;
alter table public.ride_requests add column if not exists cod_status text;
alter table public.ride_requests add column if not exists cod_settled_at timestamptz;
alter table public.ride_requests add column if not exists return_arrived_at timestamptz;
alter table public.ride_requests add column if not exists return_started_at timestamptz;
alter table public.ride_requests add column if not exists return_wait_minutes integer;
alter table public.ride_requests add column if not exists return_wait_fee numeric;
alter table public.ride_requests add column if not exists return_leg_fare numeric;
alter table public.ride_requests add column if not exists addon_terms jsonb;
alter table public.ride_requests drop constraint if exists ride_requests_delivery_addons_valid;
alter table public.ride_requests add constraint ride_requests_delivery_addons_valid check (
  (stairs_pickup is null or stairs_pickup between 0 and 200)
  and (stairs_drop is null or stairs_drop between 0 and 200)
  and (cold_level is null or cold_level ~ '^[a-z0-9-]{1,40}$')
  and (cod_amount is null or (cod_amount > 0 and cod_amount <= 1000000))
  and (cod_fee is null or cod_fee >= 0)
  and (cod_status is null or cod_status in ('pending', 'collected', 'refused'))
  and (return_wait_minutes is null or return_wait_minutes >= 0)
  and (return_wait_fee is null or return_wait_fee >= 0)
  and (return_leg_fare is null or return_leg_fare >= 0)
  and (addon_terms is null or (jsonb_typeof(addon_terms) = 'object' and pg_column_size(addon_terms) <= 32768)));
comment on column public.ride_requests.parcel_cover is 'Freight / Courier add-ons (0312): the declared value is covered.';
comment on column public.ride_requests.round_trip is 'Freight / Courier add-ons (0312): back to the pickup after the drop-off.';
comment on column public.ride_requests.cod_amount is 'Courier add-on (0312): cash the courier collects for the item.';
comment on column public.ride_requests.addon_terms is 'Freight / Courier add-ons (0312): the rule at the pickup when booked (server).';

-- The option_charges kinds of the add-ons.
create or replace function public.delivery_addon_kinds()
returns text[]
language sql
immutable
set search_path = ''
as $$ select array['parcel-cover', 'round-trip', 'stairs', 'cold-truck']; $$;

-- Why an app booking with these add-ons can't go out at its pickup, as
-- {code, hint}; null when it can (header: 2).
create or replace function public.delivery_addons_problem(
  p_service text, p_lines jsonb, p_names jsonb, p_fare numeric, p_declared numeric,
  p_cover boolean, p_round boolean, p_stairs_pickup integer, p_stairs_drop integer, p_cold text, p_cod numeric,
  p_lat double precision, p_lng double precision, p_country text, p_state text, p_city text)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_freight boolean := public.vehicle_service_is_freight(p_service);
  v_courier boolean := public.vehicle_service_is_courier(p_service);
  v_cover boolean := coalesce(p_cover, false);
  v_round boolean := coalesce(p_round, false);
  v_sp integer := coalesce(p_stairs_pickup, 0);
  v_sd integer := coalesce(p_stairs_drop, 0);
  v_cold text := nullif(btrim(coalesce(p_cold, '')), '');
  a jsonb;
  v_level jsonb;
  v_base numeric;
  k text;
  v_want numeric;
  v_have numeric;
  v_name text;
begin
  if v_sp < 0 or v_sd < 0 then
    return array['STAIRS_FLOORS', 'Floors without a lift are 0 or more.'];
  end if;
  if not (v_cover or v_round or v_sp + v_sd > 0 or v_cold is not null or p_cod is not null) then
    if exists (select 1 from unnest(public.delivery_addon_kinds()) x(kind) where public.delivery_lines_of(p_lines, x.kind) > 0) then
      return array['ADDON_CHARGE_CHANGED', 'An add-on charge is on a booking without it. Check your offer and send it again.'];
    end if;
    return null;
  end if;
  if not (v_freight or v_courier) then
    return array['ADDON_NOT_DELIVERY', 'Add-ons are for Freight and Courier only. Turn them off and book again.'];
  end if;
  if (v_sp + v_sd > 0 or v_cold is not null) and not v_freight then
    return array['ADDON_FREIGHT_ONLY', 'Stairs and the cold truck are for Freight only.'];
  end if;
  if p_cod is not null and not v_courier then
    return array['COD_COURIER_ONLY', 'Cash on delivery for the item is for Courier only.'];
  end if;
  a := public.delivery_addons_for_point(p_lat, p_lng, p_country, p_state, p_city);
  if v_cover then
    if a->'cover'->'on' is distinct from 'true'::jsonb then
      return array['ADDON_OFF', 'Parcel cover isn''t offered here. Turn it off and book again.'];
    end if;
    if p_declared is null or p_declared <= 0 then
      return array['COVER_DECLARED_VALUE', 'Enter the value of your items to cover them.'];
    end if;
    if p_declared > public.delivery_num(a->'cover', 'max') then
      return array['COVER_VALUE_MAX', 'Parcel cover goes up to '
                   || trim_scale(public.delivery_num(a->'cover', 'max'))::text || ' here. Lower the declared value.'];
    end if;
  end if;
  if v_round and a->'roundTrip'->'on' is distinct from 'true'::jsonb then
    return array['ADDON_OFF', 'Round trip isn''t offered here. Turn it off and book again.'];
  end if;
  if v_sp + v_sd > 0 then
    if a->'stairs'->'on' is distinct from 'true'::jsonb then
      return array['ADDON_OFF', 'Stairs aren''t offered here. Set the floors to 0 and book again.'];
    end if;
    if greatest(v_sp, v_sd) > public.delivery_num(a->'stairs', 'maxFloors') then
      return array['STAIRS_TOO_MANY', 'At most ' || trim_scale(public.delivery_num(a->'stairs', 'maxFloors'))::text
                   || ' floors without a lift at each end here.'];
    end if;
    if public.delivery_num(a->'stairs', 'helperFrom') > 0
       and greatest(v_sp, v_sd) >= public.delivery_num(a->'stairs', 'helperFrom')
       and not coalesce(jsonb_typeof(p_names) = 'object' and (p_names ? 'helper-1' or p_names ? 'helper-2'), false) then
      return array['STAIRS_HELPER_REQUIRED', 'From ' || trim_scale(public.delivery_num(a->'stairs', 'helperFrom'))::text
                   || ' floors without a lift, add a helper.'];
    end if;
  end if;
  if v_cold is not null then
    if a->'cold'->'on' is distinct from 'true'::jsonb then
      return array['ADDON_OFF', 'The cold truck isn''t offered here. Turn it off and book again.'];
    end if;
    v_level := public.delivery_cold_level(a->'cold', v_cold);
    if v_level is null then
      return array['COLD_LEVEL_UNKNOWN', 'That temperature isn''t offered here. Choose another and book again.'];
    end if;
    if not public.vehicle_service_refrigerated(p_service) then
      return array['COLD_TRUCK_NOT_REFRIGERATED', coalesce(nullif(btrim(p_service), ''), 'This vehicle')
                   || ' isn''t refrigerated. Choose a refrigerated vehicle.'];
    end if;
  end if;
  if p_cod is not null then
    if a->'cod'->'on' is distinct from 'true'::jsonb then
      return array['ADDON_OFF', 'Cash on delivery isn''t offered here. Turn it off and book again.'];
    end if;
    if p_cod <= 0 then
      return array['COD_AMOUNT', 'Enter the cash the courier collects for the item.'];
    end if;
    if p_cod > public.delivery_num(a->'cod', 'max') then
      return array['COD_TOO_HIGH', 'Cash on delivery goes up to ' || trim_scale(public.delivery_num(a->'cod', 'max'))::text
                   || ' a parcel here.'];
    end if;
  end if;
  -- The lines: each add-on's charge as the rule has it, none for one not booked.
  v_base := coalesce(p_fare, 0) - public.ride_option_charges_total(p_lines);
  foreach k in array public.delivery_addon_kinds() loop
    v_want := case k
      when 'parcel-cover' then case when v_cover then public.delivery_cover_premium(p_declared, a->'cover') else 0 end
      when 'round-trip' then case when v_round then public.delivery_return_charge(v_base, a->'roundTrip') else 0 end
      when 'stairs' then (v_sp + v_sd) * public.delivery_num(a->'stairs', 'perFloor')
      when 'cold-truck' then case when v_cold is not null then coalesce((v_level->>'charge')::numeric, 0) else 0 end
    end;
    v_have := public.delivery_lines_of(p_lines, k);
    -- A cent either way for the percentages, as the app rounds them.
    if abs(round(v_want, 2) - v_have) > 0.0101 then
      v_name := case k when 'parcel-cover' then 'Parcel cover' when 'round-trip' then 'The return leg'
                       when 'stairs' then 'Stairs' else 'The cold truck' end;
      return array['ADDON_CHARGE_CHANGED', v_name || '''s charge here has changed. Check your offer and send it again.'];
    end if;
  end loop;
  return null;
end;
$$;
revoke execute on function public.delivery_addons_problem(text, jsonb, jsonb, numeric, numeric, boolean, boolean, integer,
  integer, text, numeric, double precision, double precision, text, text, text) from public, anon, authenticated;

-- Why [p_driver] can't take [r] for its add-ons; null when they can: a
-- refrigerated vehicle for the cold truck, and room for its cash on
-- delivery within the carry limit and the driver's GET.wallet.
create or replace function public.delivery_driver_problem(p_driver uuid, r public.ride_requests)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_carry numeric;
  v_held numeric;
  v_balance numeric;
begin
  if p_driver is null then
    return null;
  end if;
  if r.cold_level is not null and not public.driver_takes_cold(p_driver) then
    return array['COLD_TRUCK_DRIVER', 'This request needs a refrigerated vehicle.'];
  end if;
  if r.cod_amount is not null and coalesce(r.cod_status, 'pending') = 'pending' then
    v_carry := public.delivery_num(coalesce(r.addon_terms,
                 public.delivery_addons_for_point(r.pickup_lat, r.pickup_lng, r.country, r.state, r.city))->'cod', 'carry');
    select coalesce(sum(x.cod_amount), 0) into v_held
      from public.ride_requests x
     where x.partner_id = p_driver and x.id <> r.id
       and x.status in ('accepted', 'arrived', 'on_trip') and x.cod_status = 'pending';
    if v_held + r.cod_amount > v_carry then
      return array['COD_CARRY_LIMIT', format('You can carry up to %s of cash on delivery at a time; you hold %s now.',
                                             trim_scale(v_carry), trim_scale(v_held))];
    end if;
    select w.balance into v_balance from public.wallets w where w.user_id = p_driver and w.wallet_type = 'get_wallet';
    if coalesce(v_balance, 0) < v_held + r.cod_amount then
      return array['COD_WALLET_SHORT', format('Your GET.wallet needs at least %s to take this cash on delivery: '
                                              || 'it pays the sender when you hand the parcel over.',
                                              trim_scale(v_held + r.cod_amount))];
    end if;
  end if;
  return null;
end;
$$;
revoke execute on function public.delivery_driver_problem(uuid, public.ride_requests) from public, anon, authenticated;

-- App bookings: the checks above; the server's columns (the terms, the COD
-- fee and status, the legs) are its own; afterwards the add-ons stay as
-- booked; a driver taking it must be able to (delivery_driver_problem); the
-- trip ends only after the return leg and with the COD settled. After 0267's
-- and 0268's own checks (c_services_courier, c_services_freight), before the
-- freight details move aside (zz_freight_private).
create or replace function public.ride_requests_delivery_addons()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app boolean := coalesce(current_setting('role', true), '') in ('anon', 'authenticated')
                   and not public.caller_admin_can_write('ride_requests');
  v_server boolean := coalesce(current_setting('getride.delivery_addons', true), '') = '1';
  v_problem text[];
  v_any boolean;
begin
  if tg_op = 'INSERT' then
    if v_app then
      new.addon_terms := null;
      new.cod_fee := null;
      new.cod_status := null;
      new.cod_settled_at := null;
      new.return_arrived_at := null;
      new.return_started_at := null;
      new.return_wait_minutes := null;
      new.return_wait_fee := null;
      new.return_leg_fare := null;
    end if;
    if new.stairs_pickup = 0 then
      new.stairs_pickup := null;
    end if;
    if new.stairs_drop = 0 then
      new.stairs_drop := null;
    end if;
    if new.parcel_cover is false then
      new.parcel_cover := null;
    end if;
    if new.round_trip is false then
      new.round_trip := null;
    end if;
    if v_app and new.stand_id is null and new.scheduled_ride_id is null then
      v_problem := public.delivery_addons_problem(new.service, new.option_charges, new.option_names, new.fare,
                     new.declared_value, new.parcel_cover, new.round_trip, new.stairs_pickup, new.stairs_drop,
                     new.cold_level, new.cod_amount, new.pickup_lat, new.pickup_lng, new.country, new.state, new.city);
      if v_problem is not null then
        raise exception '%', v_problem[1] using errcode = '22023', hint = v_problem[2];
      end if;
    end if;
    v_any := coalesce(new.parcel_cover, false) or coalesce(new.round_trip, false) or new.stairs_pickup is not null
             or new.stairs_drop is not null or new.cold_level is not null or new.cod_amount is not null;
    if v_any then
      new.addon_terms := coalesce(new.addon_terms,
        public.delivery_addons_for_point(new.pickup_lat, new.pickup_lng, new.country, new.state, new.city));
      if new.cod_amount is not null then
        new.cod_fee := coalesce(new.cod_fee, public.delivery_cod_fee(new.cod_amount, new.addon_terms->'cod'));
        new.cod_status := coalesce(new.cod_status, 'pending');
      end if;
      if coalesce(new.round_trip, false) then
        new.return_leg_fare := coalesce(new.return_leg_fare, public.delivery_lines_of(new.option_charges, 'round-trip'));
      end if;
    end if;
    return new;
  end if;

  if v_app and not v_server then
    if (new.parcel_cover, new.round_trip, new.stairs_pickup, new.stairs_drop, new.cold_level, new.cod_amount)
       is distinct from
       (old.parcel_cover, old.round_trip, old.stairs_pickup, old.stairs_drop, old.cold_level, old.cod_amount) then
      raise exception 'ADDONS_FIXED' using errcode = '42501',
        hint = 'The add-ons are set when the request is made. Cancel it and make a new one.';
    end if;
    if (new.addon_terms, new.cod_fee, new.cod_status, new.cod_settled_at, new.return_arrived_at, new.return_started_at,
        new.return_wait_minutes, new.return_wait_fee, new.return_leg_fare)
       is distinct from
       (old.addon_terms, old.cod_fee, old.cod_status, old.cod_settled_at, old.return_arrived_at, old.return_started_at,
        old.return_wait_minutes, old.return_wait_fee, old.return_leg_fare) then
      raise exception 'ADDONS_SERVER_ONLY' using errcode = '42501',
        hint = 'The return leg and the cash on delivery are recorded by the server.';
    end if;
  end if;
  -- A driver takes it (claims it, or the rider takes their offer).
  if v_app and new.partner_id is not null and new.partner_id is distinct from old.partner_id then
    v_problem := public.delivery_driver_problem(new.partner_id, new);
    if v_problem is not null then
      raise exception '%', v_problem[1] using errcode = '42501', hint = v_problem[2];
    end if;
  end if;
  if v_app and new.status = 'completed' and old.status is distinct from 'completed' then
    if coalesce(new.round_trip, false) and new.return_started_at is null then
      raise exception 'ROUND_TRIP_RETURN_FIRST' using errcode = '42501',
        hint = 'Start the return leg at the drop-off; the trip ends back at the pickup.';
    end if;
    if new.cod_status = 'pending' then
      raise exception 'COD_NOT_SETTLED' using errcode = '42501',
        hint = 'Collect the cash for the item, or tell us the recipient won''t pay, first.';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_delivery_addons() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_c_services_zaddons on public.ride_requests;
create trigger trg_ride_requests_c_services_zaddons
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_delivery_addons();

-- An offer on a request: the same driver checks before it is sent.
create or replace function public.ride_offers_delivery_addons()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_problem text[];
begin
  select * into r from public.ride_requests where id = new.request_id;
  if not found or (r.cold_level is null and r.cod_amount is null) then
    return new;
  end if;
  v_problem := public.delivery_driver_problem(new.partner_id, r);
  if v_problem is not null then
    raise exception '%', v_problem[1] using errcode = '42501', hint = v_problem[2];
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_offers_delivery_addons() from public, anon, authenticated;

do $$
begin
  if to_regclass('public.ride_offers') is not null then
    execute 'drop trigger if exists trg_ride_offers_delivery_addons on public.ride_offers';
    execute 'create trigger trg_ride_offers_delivery_addons before insert on public.ride_offers
               for each row execute function public.ride_offers_delivery_addons()';
  end if;
end $$;

-- An open cold-truck request: read only by drivers with a refrigerated
-- vehicle (beside 0267's freight rule, with the same exceptions).
drop policy if exists "ride_requests cold" on public.ride_requests;
create policy "ride_requests cold" on public.ride_requests as restrictive for select to authenticated
  using (status <> 'open' or cold_level is null
         or rider_id = (select auth.uid()) or partner_id = (select auth.uid())
         or direct_driver_id = (select auth.uid())
         or (select public.caller_is_admin())
         or (stand_id is not null and array[stand_id] <@ (select public.dispatch_caller_stand_ids()))
         or (select public.caller_takes_cold()));

-- A booking for later: the same checks when it is booked.
create or replace function public.scheduled_rides_delivery_addons()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  q jsonb := coalesce(new.request, '{}'::jsonb);
  v_problem text[];
begin
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated')
     or public.caller_admin_can_write('scheduled_rides')
     or new.stand_id is not null then
    return new;
  end if;
  v_problem := public.delivery_addons_problem(new.service, q->'option_charges', q->'option_names',
                 case when jsonb_typeof(q->'fare') = 'number' then (q->>'fare')::numeric end,
                 case when jsonb_typeof(q->'declared_value') = 'number' then (q->>'declared_value')::numeric end,
                 q->'parcel_cover' = 'true'::jsonb, q->'round_trip' = 'true'::jsonb,
                 case when jsonb_typeof(q->'stairs_pickup') = 'number' then floor((q->>'stairs_pickup')::numeric)::integer end,
                 case when jsonb_typeof(q->'stairs_drop') = 'number' then floor((q->>'stairs_drop')::numeric)::integer end,
                 q->>'cold_level',
                 case when jsonb_typeof(q->'cod_amount') = 'number' then (q->>'cod_amount')::numeric end,
                 new.pickup_lat, new.pickup_lng, q->>'country', q->>'state', q->>'city');
  if v_problem is not null then
    raise exception '%', v_problem[1] using errcode = '22023', hint = v_problem[2];
  end if;
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_delivery_addons() from public, anon, authenticated;

drop trigger if exists trg_scheduled_rides_delivery_addons on public.scheduled_rides;
create trigger trg_scheduled_rides_delivery_addons
  before insert on public.scheduled_rides
  for each row execute function public.scheduled_rides_delivery_addons();

-- As 0268, a booking for later keeps the add-ons too.
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
       'pickup_door_id', 'drop_door_id',
       -- 0251: a stand's order (kept only on a stand's booking).
       'stand_id', 'ticket_no', 'dispatch_stand_name', 'dispatch_created_by', 'dispatch_mode',
       'dispatch_group_id', 'dispatch_group_name', 'dispatch_group_kind', 'dispatch_driver_id',
       'fare_mode', 'dispatch_payment', 'stand_settlement', 'stand_fee_type', 'stand_fee_value',
       'stand_fee_bearer', 'stand_fee_earner_id', 'stand_fee_amount', 'stand_platform_fee_type',
       'stand_platform_fee_value', 'dispatch_booked_via', 'share_token',
       -- 0267: the cargo of a freight booking, its declared value and
       -- the recipient told when the trip starts.
       'cargo_description', 'cargo_photo_path', 'declared_value', 'prohibited_ack',
       'recipient_name', 'recipient_phone',
       -- 0268: a courier booking's parcel size and who pays.
       'parcel_size', 'payer',
       -- 0312: the add-ons booked (the server's own columns are set at release).
       'parcel_cover', 'round_trip', 'stairs_pickup', 'stairs_drop', 'cold_level', 'cod_amount'])
       and (e.key <> 'charges' or jsonb_typeof(e.value) = 'array')
  ), '{}'::jsonb);
$$;
revoke execute on function public.scheduled_request_clean(jsonb, numeric) from public, anon, authenticated;

-- ---- 4. A covered parcel may be declared up to the cover's highest value ------------------------------
-- As 0267, with p_cover: a covered booking's declared value is capped by the
-- cover (delivery_addons_problem), not by the place's declared cap.
drop function if exists public.ride_freight_problem(text, jsonb, jsonb, text, numeric, boolean, double precision,
                                                    double precision, text, text, text);
create or replace function public.ride_freight_problem(
  p_service text, p_names jsonb, p_lines jsonb, p_cargo text, p_declared numeric, p_ack boolean,
  p_lat double precision, p_lng double precision, p_country text, p_state text, p_city text,
  p_cover boolean default false)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_freight boolean := public.vehicle_service_is_freight(p_service);
  v_kinds text[] := public.ride_freight_kinds(p_names);
  v_charges jsonb;
  k text;
  v_want numeric;
  v_have numeric;
begin
  if cardinality(v_kinds) > 0 and not v_freight then
    return array['FREIGHT_OPTION_NOT_FREIGHT',
                 public.ride_option_name(v_kinds[1], p_names) || ' is for Freight only. Turn it off and book again.'];
  end if;
  if not v_freight then
    return null;
  end if;
  if coalesce(btrim(p_cargo), '') = '' then
    return array['FREIGHT_CARGO_REQUIRED', 'Describe your cargo so drivers know what they are carrying.'];
  end if;
  if not coalesce(p_ack, false) then
    return array['FREIGHT_PROHIBITED_ACK', 'Confirm that your cargo has none of the prohibited items.'];
  end if;
  if p_declared is null or p_declared < 0 then
    return array['FREIGHT_DECLARED_VALUE', 'Enter the value of your items.'];
  end if;
  if 'helper-1' = any (v_kinds) and 'helper-2' = any (v_kinds) then
    return array['FREIGHT_HELPERS_ONE', 'Choose 1 helper or 2 helpers, not both.'];
  end if;
  if 'closed-body' = any (v_kinds) and not public.vehicle_service_closed_body(p_service) then
    return array['RIDE_OPTION_NOT_OFFERED',
                 public.ride_option_name('closed-body', p_names) || ' isn''t offered for '
                 || coalesce(nullif(btrim(p_service), ''), 'this service') || '. Choose a closed body vehicle.'];
  end if;
  select public.ride_option_settings_at(p.country, p.state, p.city, p.suburb)->'charges' into v_charges
    from public.ride_option_place(p_lat, p_lng, p_country, p_state, p_city) p;
  -- The declared value is capped per place (Default RM 500); a covered one
  -- by the cover (0312).
  if not coalesce(p_cover, false) and p_declared > public.freight_place_value(v_charges, 'freight-declared-cap') then
    return array['FREIGHT_DECLARED_VALUE_CAP',
                 'The value of your items can be at most '
                 || trim_scale(public.freight_place_value(v_charges, 'freight-declared-cap'))::text
                 || ' here. Send higher-value items another way.'];
  end if;
  foreach k in array public.freight_option_ids() loop
    -- A percentage (never set from the admin page) is not checked.
    continue when k = any (v_kinds) and v_charges->k->>'kind' = 'percent';
    v_want := case when k = any (v_kinds) and jsonb_typeof(v_charges->k->'value') = 'number'
                   then (v_charges->k->>'value')::numeric else 0 end;
    select coalesce(sum((e->>'amount')::numeric), 0) into v_have
      from jsonb_array_elements(case when jsonb_typeof(p_lines) = 'array' then p_lines else '[]'::jsonb end) e
     where e->>'kind' = k and jsonb_typeof(e->'amount') = 'number';
    if abs(v_want - v_have) > 0.005 then
      return array['RIDE_OPTION_CHARGE_CHANGED',
                   public.ride_option_name(k, p_names) || '''s charge here has changed. Check your offer and send it again.'];
    end if;
  end loop;
  return null;
end;
$$;
revoke execute on function public.ride_freight_problem(text, jsonb, jsonb, text, numeric, boolean, double precision,
                                                       double precision, text, text, text, boolean)
  from public, anon, authenticated;

-- As 0268, with p_cover.
drop function if exists public.ride_courier_problem(text, text, text, text, text, text, numeric, boolean,
                                                    double precision, double precision, text, text, text);
create or replace function public.ride_courier_problem(
  p_service text, p_size text, p_payer text, p_payment text, p_recipient_phone text, p_cargo text,
  p_declared numeric, p_ack boolean,
  p_lat double precision, p_lng double precision, p_country text, p_state text, p_city text,
  p_cover boolean default false)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_charges jsonb;
  v_kg numeric;
  v_load numeric;
  v_cap numeric;
begin
  if not public.vehicle_service_is_courier(p_service) then
    if p_size is not null then
      return array['COURIER_SIZE_NOT_COURIER', 'A parcel size is for Courier only. Book it from the Courier page.'];
    end if;
    if p_payer = 'recipient' then
      return array['COURIER_RECIPIENT_PAYS_ONLY', 'Only a courier delivery can be paid by the recipient.'];
    end if;
    return null;
  end if;
  if p_size is null then
    return array['COURIER_PARCEL_SIZE', 'Choose the parcel size.'];
  end if;
  v_kg := public.courier_parcel_kg(p_size);
  v_load := public.vehicle_service_load_kg(public.vehicle_service_id_of(p_service));
  if v_load is not null and v_kg > v_load then
    return array['COURIER_TOO_HEAVY',
                 format('A %s parcel (up to %s kg) is too heavy for %s. Choose a bigger vehicle.',
                        p_size, trim_scale(v_kg), btrim(p_service))];
  end if;
  if coalesce(btrim(p_cargo), '') = '' then
    return array['COURIER_ITEM_REQUIRED', 'Say what you are sending.'];
  end if;
  if not coalesce(p_ack, false) then
    return array['COURIER_PROHIBITED_ACK', 'Confirm that your parcel has none of the prohibited items.'];
  end if;
  if p_declared is null or p_declared < 0 then
    return array['COURIER_DECLARED_VALUE', 'Enter the value of your items.'];
  end if;
  select public.ride_option_settings_at(p.country, p.state, p.city, p.suburb)->'charges' into v_charges
    from public.ride_option_place(p_lat, p_lng, p_country, p_state, p_city) p;
  v_cap := public.freight_place_value(v_charges, 'courier-declared-cap');
  if not coalesce(p_cover, false) and p_declared > v_cap then
    return array['COURIER_DECLARED_VALUE_CAP',
                 'The value of your items can be at most ' || trim_scale(v_cap)::text
                 || ' here. Send higher-value items another way.'];
  end if;
  if coalesce(btrim(p_recipient_phone), '') = '' then
    return array['COURIER_RECIPIENT_REQUIRED', 'Add the recipient''s phone number.'];
  end if;
  if p_payer = 'recipient' and position('cash' in lower(coalesce(p_payment, ''))) = 0 then
    return array['COURIER_RECIPIENT_PAYS_CASH', 'The recipient pays the courier in cash. Choose Cash.'];
  end if;
  return null;
end;
$$;
revoke execute on function public.ride_courier_problem(text, text, text, text, text, text, numeric, boolean,
                                                       double precision, double precision, text, text, text, boolean)
  from public, anon, authenticated;

-- The four callers (0267, 0268) pass whether the parcel is covered, and a
-- courier trip whose recipient wouldn't pay ends back at the sender without
-- the recipient's code; each edited in its current definition, as 0267 did.
do $edit$
declare
  e record;
  v_def text;
  v_n int;
begin
  for e in
    select * from (values
      ('ride_requests_freight', 'new.country, new.state, new.city);',
         'new.country, new.state, new.city, coalesce(new.parcel_cover, false));'),
      ('ride_requests_courier', 'new.country, new.state, new.city);',
         'new.country, new.state, new.city, coalesce(new.parcel_cover, false));'),
      ('scheduled_rides_freight', 'q->>''country'', q->>''state'', q->>''city'');',
         'q->>''country'', q->>''state'', q->>''city'', q->''parcel_cover'' = ''true''::jsonb);'),
      ('scheduled_rides_courier', 'q->>''country'', q->>''state'', q->>''city'');',
         'q->>''country'', q->>''state'', q->>''city'', q->''parcel_cover'' = ''true''::jsonb);'),
      ('ride_requests_freight_trip', 'and new.delivery_code_ok_at is null then',
         'and new.delivery_code_ok_at is null and new.cod_status is distinct from ''refused'' then')
    ) as t(fn, anchor, added)
  loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = e.fn;
    if v_def is null then
      raise exception '0312: public.% is missing', e.fn;
    end if;
    -- Run again: a function already edited is left alone.
    continue when position(e.added in v_def) > 0;
    v_n := (length(v_def) - length(replace(v_def, e.anchor, ''))) / length(e.anchor);
    if v_n <> 1 then
      raise exception '0312: public.% should have "%" once (has %); update this migration', e.fn, e.anchor, v_n;
    end if;
    execute replace(v_def, e.anchor, e.added);
  end loop;
end
$edit$;

-- ---- 5. Commission on both legs, none on the cover premium -----------------------------------------
-- As 0248: what to take off the fare for [p_for]. The return leg is always
-- commissioned and the cover premium never (it is the platform's, header: 3).
create or replace function public.ride_option_charges_off(p_charges jsonb, p_for text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_charges is null then 0
    when p_for = 'commission' then
      round(case when (public.ride_option_charge_rules()->>p_for)::boolean is not false
                 then public.delivery_lines_of(p_charges, 'parcel-cover')
                 else public.ride_option_charges_total(p_charges) - public.delivery_lines_of(p_charges, 'round-trip') end, 2)
    when (public.ride_option_charge_rules()->>p_for)::boolean is not false then 0
    else round(public.ride_option_charges_total(p_charges), 2) end;
$$;
revoke execute on function public.ride_option_charges_off(jsonb, text) from public, anon;
grant execute on function public.ride_option_charges_off(jsonb, text) to authenticated;

-- The trip completes: the cover premium the driver collected in the fare is
-- the platform's, taken from their GET.credit (once per ride).
create or replace function public.ride_requests_delivery_addons_settle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_premium numeric := round(public.delivery_lines_of(new.option_charges, 'parcel-cover'), 2);
begin
  if v_premium <= 0 or new.partner_id is null
     or exists (select 1 from public.wallet_transactions t where t.ride_id = new.id and t.kind = 'cover_premium') then
    return null;
  end if;
  begin
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note, ride_id)
    values (new.partner_id, 'get_credit', 'cover_premium', -v_premium,
            'Parcel cover premium collected in the fare', new.id);
  exception when others then
    raise warning 'ride % cover premium not taken: %', new.id, sqlerrm;
  end;
  return null;
end;
$$;
revoke execute on function public.ride_requests_delivery_addons_settle() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_delivery_addons_settle on public.ride_requests;
create trigger trg_ride_requests_delivery_addons_settle
  after update of status on public.ride_requests
  for each row when (new.status = 'completed' and old.status is distinct from 'completed' and new.parcel_cover)
  execute function public.ride_requests_delivery_addons_settle();

-- ---- 6. The driver: the return leg and the cash on delivery ------------------------------------------
-- The ride the caller drives, on the trip, locked; refused otherwise.
create or replace function public.delivery_ride_for_driver(p_ride uuid)
returns public.ride_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.partner_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status <> 'on_trip' then
    raise exception 'wrong_status:%', r.status using errcode = 'P0001',
      hint = 'This works while the trip is on.';
  end if;
  return r;
end;
$$;
revoke execute on function public.delivery_ride_for_driver(uuid) from public, anon, authenticated;

-- The outward fare: what the ride costs less its option lines and the
-- waiting at the pickup.
create or replace function public.delivery_outward_fare(r public.ride_requests)
returns numeric
language sql
immutable
set search_path = public
as $$
  select greatest(0, round(coalesce(r.ride_fare, r.fare, 0) - public.ride_option_charges_total(r.option_charges)
                           - coalesce(r.freight_waiting_fee, 0), 2));
$$;
revoke execute on function public.delivery_outward_fare(public.ride_requests) from public, anon, authenticated;

-- A round trip at the drop-off: delivered (the photo, a courier's code and
-- any cash on delivery settled), the free wait starts.
create or replace function public.delivery_return_arrived(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.delivery_ride_for_driver(p_ride);
begin
  if not coalesce(r.round_trip, false) then
    raise exception 'ROUND_TRIP_NONE' using errcode = 'P0001', hint = 'This trip has no return leg.';
  end if;
  if r.return_arrived_at is null then
    if r.dropoff_proof_path is null then
      raise exception 'ROUND_TRIP_DROP_FIRST' using errcode = 'P0001', hint = 'Take the photo at the drop-off first.';
    end if;
    if r.parcel_size is not null and r.delivery_code_ok_at is null and r.cod_status is distinct from 'refused' then
      raise exception 'ROUND_TRIP_DROP_FIRST' using errcode = 'P0001', hint = 'Enter the recipient''s code first.';
    end if;
    if r.cod_status = 'pending' then
      raise exception 'COD_NOT_SETTLED' using errcode = 'P0001',
        hint = 'Collect the cash for the item, or tell us the recipient won''t pay, first.';
    end if;
    perform set_config('getride.delivery_addons', '1', true);
    update public.ride_requests set return_arrived_at = now() where id = p_ride returning * into r;
    perform set_config('getride.delivery_addons', '', true);
  end if;
  return jsonb_build_object('return_arrived_at', r.return_arrived_at,
                            'free_wait', public.delivery_num(r.addon_terms->'roundTrip', 'freeWait'),
                            'wait_per_min', public.delivery_num(r.addon_terms->'roundTrip', 'waitPerMin'),
                            'max_wait', public.delivery_num(r.addon_terms->'roundTrip', 'maxWait'));
end;
$$;

-- A round trip heads back: the wait past the free minutes (at most the
-- longest wait) is added to the fare.
create or replace function public.delivery_return_start(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.delivery_ride_for_driver(p_ride);
  v_minutes integer;
  v_fee numeric;
begin
  if not coalesce(r.round_trip, false) then
    raise exception 'ROUND_TRIP_NONE' using errcode = 'P0001', hint = 'This trip has no return leg.';
  end if;
  if r.return_started_at is null then
    if r.return_arrived_at is null then
      raise exception 'ROUND_TRIP_ARRIVE_FIRST' using errcode = 'P0001', hint = 'Say you are at the drop-off first.';
    end if;
    v_minutes := greatest(0, floor(extract(epoch from (now() - r.return_arrived_at)) / 60))::integer;
    v_fee := public.delivery_return_wait_fee(v_minutes, r.addon_terms->'roundTrip');
    perform set_config('getride.delivery_addons', '1', true);
    update public.ride_requests
       set return_started_at = now(), return_wait_minutes = v_minutes, return_wait_fee = v_fee,
           fare = coalesce(fare, 0) + v_fee, ride_fare = coalesce(ride_fare, fare, 0) + v_fee
     where id = p_ride
    returning * into r;
    perform set_config('getride.delivery_addons', '', true);
  end if;
  return jsonb_build_object('return_started_at', r.return_started_at, 'wait_minutes', r.return_wait_minutes,
                            'wait_fee', r.return_wait_fee, 'fare', r.fare);
end;
$$;

-- At hand-over the courier has the cash: the amount leaves their GET.wallet
-- and reaches the sender's, less the COD fee.
create or replace function public.cod_collected(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.delivery_ride_for_driver(p_ride);
  v_balance numeric;
  v_paid numeric;
  v_cur text;
begin
  if r.cod_amount is null then
    raise exception 'COD_NONE' using errcode = 'P0001', hint = 'This delivery has no cash on delivery.';
  end if;
  if r.cod_status = 'collected' then
    return jsonb_build_object('amount', r.cod_amount, 'fee', r.cod_fee, 'paid', r.cod_amount - coalesce(r.cod_fee, 0),
                              'already', true);
  end if;
  if r.cod_status is distinct from 'pending' then
    raise exception 'COD_REFUSED' using errcode = 'P0001', hint = 'The recipient didn''t pay; bring the parcel back.';
  end if;
  v_cur := coalesce(r.currency, 'RM');
  v_paid := greatest(0, r.cod_amount - coalesce(r.cod_fee, 0));
  insert into public.wallets (user_id, wallet_type, balance) values (r.partner_id, 'get_wallet', 0)
  on conflict (user_id, wallet_type) do nothing;
  select balance into v_balance from public.wallets
   where user_id = r.partner_id and wallet_type = 'get_wallet' for update;
  if coalesce(v_balance, 0) < r.cod_amount then
    raise exception 'COD_WALLET_SHORT' using errcode = 'P0001',
      hint = format('Top up your GET.wallet to %s %s first: the cash on delivery is paid to the sender from it.',
                    v_cur, to_char(r.cod_amount, 'FM999999990.00'));
  end if;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id) values
    (r.partner_id, 'get_wallet', 'cod_collect', -r.cod_amount, 'cod',
     format('Cash on delivery collected, %s %s, paid to the sender', v_cur, to_char(r.cod_amount, 'FM999999990.00')),
     r.id),
    (r.rider_id, 'get_wallet', 'cod_payout', v_paid, 'cod',
     format('Cash on delivery for your item, %s %s less the %s %s fee', v_cur, to_char(r.cod_amount, 'FM999999990.00'),
            v_cur, to_char(coalesce(r.cod_fee, 0), 'FM999999990.00')),
     r.id);
  perform set_config('getride.delivery_addons', '1', true);
  update public.ride_requests set cod_status = 'collected', cod_settled_at = now() where id = p_ride;
  perform set_config('getride.delivery_addons', '', true);
  return jsonb_build_object('amount', r.cod_amount, 'fee', coalesce(r.cod_fee, 0), 'paid', v_paid);
end;
$$;

-- The recipient won't pay: the parcel goes back to the sender at the return
-- rate (nothing more on a round trip), and the sender is told.
create or replace function public.cod_refused(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests := public.delivery_ride_for_driver(p_ride);
  v_extra numeric := 0;
begin
  if r.cod_amount is null then
    raise exception 'COD_NONE' using errcode = 'P0001', hint = 'This delivery has no cash on delivery.';
  end if;
  if r.cod_status = 'refused' then
    return jsonb_build_object('return_fare', coalesce(r.return_leg_fare, 0), 'already', true);
  end if;
  if r.cod_status is distinct from 'pending' then
    raise exception 'COD_SETTLED' using errcode = 'P0001', hint = 'The cash on delivery is already settled.';
  end if;
  if not coalesce(r.round_trip, false) then
    v_extra := public.delivery_return_charge(public.delivery_outward_fare(r),
                 coalesce(r.addon_terms, public.delivery_addon_defaults())->'roundTrip');
  end if;
  perform set_config('getride.delivery_addons', '1', true);
  update public.ride_requests
     set cod_status = 'refused', cod_settled_at = now(),
         return_arrived_at = coalesce(return_arrived_at, now()),
         return_started_at = coalesce(return_started_at, now()),
         return_wait_minutes = coalesce(return_wait_minutes, 0),
         return_wait_fee = coalesce(return_wait_fee, 0),
         return_leg_fare = case when coalesce(round_trip, false) then return_leg_fare else v_extra end,
         fare = coalesce(fare, 0) + v_extra,
         ride_fare = coalesce(ride_fare, fare, 0) + v_extra
   where id = p_ride
  returning * into r;
  perform set_config('getride.delivery_addons', '', true);
  begin
    perform public.enqueue_notification(
      r.rider_id, 'cod-refused:' || r.id, 'delivery_update', 'critical',
      'Your parcel is coming back',
      'The recipient didn''t pay the cash on delivery. The courier is bringing the parcel back to you'
      || case when v_extra > 0 then format(' (return %s %s).', coalesce(r.currency, 'RM'), to_char(v_extra, 'FM999999990.00'))
              else '.' end,
      jsonb_build_object('type', 'delivery_update', 'request_id', r.id, 'cod', 'refused'),
      r.id);
  exception when others then
    null;
  end;
  return jsonb_build_object('return_fare', v_extra, 'fare', r.fare);
end;
$$;

revoke execute on function public.delivery_return_arrived(uuid), public.delivery_return_start(uuid),
  public.cod_collected(uuid), public.cod_refused(uuid) from public, anon;
grant execute on function public.delivery_return_arrived(uuid), public.delivery_return_start(uuid),
  public.cod_collected(uuid), public.cod_refused(uuid) to authenticated;

-- ---- 7. Cover claims -----------------------------------------------------------------------------------
create table if not exists public.cover_claims (
  id             uuid primary key default gen_random_uuid(),
  ride_id        uuid not null unique references public.ride_requests(id) on delete cascade,
  sender_id      uuid not null,
  service        text,
  currency       text,
  declared_value numeric not null check (declared_value > 0),
  amount         numeric not null check (amount > 0),
  reason         text not null check (char_length(btrim(reason)) between 5 and 1000),
  status         text not null default 'open' check (status in ('open', 'approved', 'rejected')),
  paid_amount    numeric check (paid_amount is null or paid_amount > 0),
  admin_note     text check (admin_note is null or char_length(admin_note) <= 1000),
  decided_by     uuid,
  decided_at     timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint cover_claims_amount check (amount <= declared_value and (paid_amount is null or paid_amount <= declared_value))
);
create index if not exists cover_claims_open_idx on public.cover_claims (status, created_at desc);
create index if not exists cover_claims_sender_idx on public.cover_claims (sender_id, created_at desc);
comment on table public.cover_claims is
  'Parcel cover claims (0312): one per covered ride, filed by its sender within the claim days; an admin approves (paid to the sender''s GET.wallet) or rejects.';

drop trigger if exists trg_cover_claims_updated_at on public.cover_claims;
create trigger trg_cover_claims_updated_at before update on public.cover_claims
  for each row execute function public.set_updated_at();

alter table public.cover_claims enable row level security;
revoke all on public.cover_claims from anon, authenticated;
grant select on public.cover_claims to authenticated;
drop policy if exists "cover_claims read" on public.cover_claims;
create policy "cover_claims read" on public.cover_claims for select to authenticated
  using (sender_id = (select auth.uid()) or (select public.caller_is_admin()));

-- The sender files a claim for a covered ride, within the claim days after
-- it ended, for up to its declared value.
create or replace function public.cover_claim_file(p_ride uuid, p_amount numeric, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_ended timestamptz;
  v_days numeric;
  c public.cover_claims;
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_ride;
  if not found or r.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if not coalesce(r.parcel_cover, false) then
    raise exception 'COVER_NONE' using errcode = 'P0001', hint = 'This delivery wasn''t covered.';
  end if;
  if not (r.status = 'completed' or (r.status = 'cancelled' and r.started_at is not null)) then
    raise exception 'COVER_CLAIM_TOO_EARLY' using errcode = 'P0001',
      hint = 'You can report a problem once the delivery has ended.';
  end if;
  v_ended := coalesce(r.completed_at, r.cancelled_at, r.updated_at, now());
  v_days := coalesce(nullif(public.delivery_num(r.addon_terms->'cover', 'claimDays'), 0), 7);
  if now() > v_ended + make_interval(days => v_days::int) then
    raise exception 'COVER_CLAIM_LATE' using errcode = 'P0001',
      hint = format('Claims are taken within %s days of the delivery.', trim_scale(v_days));
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) not between 5 and 1000 then
    raise exception 'COVER_CLAIM_REASON' using errcode = '22023', hint = 'Say what happened, in 5 to 1,000 characters.';
  end if;
  if coalesce(r.declared_value, 0) <= 0 or p_amount is null or p_amount <= 0 or p_amount > r.declared_value then
    raise exception 'COVER_CLAIM_AMOUNT' using errcode = '22023',
      hint = format('Claim up to the declared value, %s %s.', coalesce(r.currency, 'RM'),
                    to_char(coalesce(r.declared_value, 0), 'FM999999990.00'));
  end if;
  insert into public.cover_claims (ride_id, sender_id, service, currency, declared_value, amount, reason)
  values (r.id, r.rider_id, r.service, r.currency, r.declared_value, round(p_amount, 2), btrim(p_reason))
  on conflict (ride_id) do nothing
  returning * into c;
  if c.id is null then
    raise exception 'COVER_CLAIM_EXISTS' using errcode = 'P0001', hint = 'A claim for this delivery is already in.';
  end if;
  return to_jsonb(c);
end;
$$;
revoke execute on function public.cover_claim_file(uuid, numeric, text) from public, anon;
grant execute on function public.cover_claim_file(uuid, numeric, text) to authenticated;

-- An admin approves (paid to the sender's GET.wallet) or rejects an open
-- claim; in admin_audit_log.
create or replace function public.cover_claim_decide(p_claim uuid, p_approve boolean, p_amount numeric default null,
                                                     p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.cover_claims;
  v_paid numeric;
begin
  if not public.caller_admin_can_write('rpc:cover_claim_decide') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You can''t decide parcel cover claims.';
  end if;
  select * into c from public.cover_claims where id = p_claim for update;
  if not found then
    raise exception 'COVER_CLAIM_NOT_FOUND' using errcode = 'P0002', hint = 'This claim no longer exists.';
  end if;
  if c.status <> 'open' then
    raise exception 'COVER_CLAIM_DECIDED' using errcode = 'P0001', hint = 'This claim is already decided.';
  end if;
  if coalesce(p_approve, false) then
    v_paid := round(coalesce(p_amount, c.amount), 2);
    if v_paid <= 0 or v_paid > c.declared_value then
      raise exception 'COVER_CLAIM_AMOUNT' using errcode = '22023', hint = 'Pay more than 0, up to the declared value.';
    end if;
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (c.sender_id, 'get_wallet', 'cover_claim', v_paid, 'cover',
            format('Parcel cover claim paid, %s %s', coalesce(c.currency, 'RM'), to_char(v_paid, 'FM999999990.00')),
            c.ride_id);
  end if;
  update public.cover_claims
     set status = case when coalesce(p_approve, false) then 'approved' else 'rejected' end,
         paid_amount = v_paid, admin_note = nullif(btrim(left(coalesce(p_note, ''), 1000)), ''),
         decided_by = auth.uid(), decided_at = now()
   where id = p_claim
  returning * into c;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'cover_claim.' || c.status, c.sender_id,
          jsonb_build_object('claim_id', c.id, 'ride_id', c.ride_id, 'paid', v_paid));
  begin
    perform public.enqueue_notification(
      c.sender_id, 'cover-claim:' || c.id, 'delivery_update', 'normal',
      case when c.status = 'approved' then 'Your claim is approved' else 'Your claim was not approved' end,
      case when c.status = 'approved'
           then format('%s %s is in your GET.wallet.', coalesce(c.currency, 'RM'), to_char(v_paid, 'FM999999990.00'))
           else coalesce(c.admin_note, 'Open the delivery to read why.') end,
      jsonb_build_object('type', 'cover_claim', 'request_id', c.ride_id, 'claim_id', c.id),
      c.ride_id);
  exception when others then
    null;
  end;
  return to_jsonb(c);
end;
$$;
revoke execute on function public.cover_claim_decide(uuid, boolean, numeric, text) from public, anon;
grant execute on function public.cover_claim_decide(uuid, boolean, numeric, text) to authenticated;

insert into public.admin_table_pages (target, page) values
  ('rpc:cover_claim_decide', 'admin-settings-display')
on conflict do nothing;

-- ---- 8. Live ------------------------------------------------------------------------------------
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['delivery_addon_rules', 'cover_claims'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
