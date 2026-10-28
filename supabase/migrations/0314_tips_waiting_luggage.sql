-- ============================================================================
-- 0314 — City ride extras, part 1: tips, the waiting charge and luggage
-- (docs/KIV.md: "Tips after the trip", "Waiting-time charge on city rides",
-- "Luggage option when the rider books a city ride").
--
-- Version 20261028070000 (0314_tips_waiting_luggage). Re-runnable: tables
-- and columns "if not exists", functions "create or replace", triggers and
-- policies dropped first, the Default row added only when missing.
--
-- 1. Settings: Admin > Services & catalogue > City ride extras
--    (page admin-settings-city-ride-extras, grantable to sub-admins).
--    * public.city_ride_extra_places: Default, or a country, state, city or
--      suburb (keyed as 0253's ride_option_places), with rules: one object
--      per card, {"tips": {...}, "waiting": {...}, "luggage": {...}}. A key a
--      place sets wins over the place above, key by key, so a region rule
--      only overrides what it sets; "on" switches a card per place.
--    * Built to grow: each card is a section with its own checker,
--      city_ride_extras_check_<section>(jsonb) -> text (null when fine), and
--      its own defaults, city_ride_extras_default_<section>() -> jsonb. The
--      table's check (city_ride_extras_problem) and the resolver
--      (city_ride_extras_at) find them by name, so a later card (rider
--      audio, Premium, GET.Plus) adds its two functions and its section,
--      and edits nothing here.
--    * This part's sections and defaults (the approved board):
--        tips     on, presets 2 / 5 / 10, other amount 1 to 100, from the
--                 receipt for 3 days, commission on tips 0%;
--        waiting  on, 3 free minutes, then 0.30 a minute, at most 6, and
--                 Arrived only within 150 m of the pickup;
--        luggage  on, 2 free bags, 2 per extra bag, at most 5 bags. The
--                 Default row starts from the meter's master tariff
--                 (meter_digital_settings: free_luggage and
--                 extra_luggage_charge, when it charges for bags), so the
--                 meter and the app ask the same for a bag.
--
-- 2. Waiting charge (city rides: not Freight or Courier, which have their
--    own, 0267):
--    * Arrived is checked by the server: with the waiting card on where the
--      ride starts, a driver's Arrived further than the radius from the
--      pickup is refused (RIDE_ARRIVED_TOO_FAR). Their position is the one
--      the app sends with Arrived (partner_arrive_lat/lng), else their live
--      position on the ride or their presence, when under 2 minutes old.
--      With no position at all Arrived goes through but no clock starts.
--    * Checked, the clock starts (ride_requests.waiting_from): now for a
--      ride now, the booked time for a scheduled ride the driver reached by
--      then. The terms are stamped with it (waiting_terms: freeMinutes,
--      perMinute, cap), so the rider and the driver run the same clock
--      (lib/src/core/city_ride_extras.dart) and an admin edit never changes
--      a ride already waiting.
--    * "Rider picked up" (status on_trip, whichever way: start_trip or the
--      app): the whole minutes since waiting_from past the free ones, times
--      the rate, at most the cap, are added to the fare (fare and ride_fare,
--      as 0267 does) and kept in waiting_minutes / waiting_charge for the
--      receipt. The four columns are the server's (RIDE_SERVER_ONLY).
--
-- 3. Luggage: the rider picks the bags at booking (ride_requests.luggage,
--    which was always there; a booking for later keeps it in its request).
--    The charge is an option_charges line of kind 'luggage' (0248), part
--    of the fare. An app booking, now or for later, is refused when it has
--    more bags than the place allows (RIDE_LUGGAGE_TOO_MANY), when its
--    luggage line isn't the place's charge for the bags
--    (RIDE_LUGGAGE_CHARGE_CHANGED), or when Freight or Courier carries one
--    (RIDE_LUGGAGE_NOT_HERE). The driver reads the bags and the line on the
--    request as before.
--
-- 4. Tips (public.ride_tips):
--    * ride_tip_terms(ride): what the rider's tip card and the driver's
--      trip card show: the presets, the other amount's limits, until when,
--      the commission, the tip already given and the driver's cash tip mark.
--    * ride_tip(ride, amount, method): the ride's rider, after it is
--      completed, within the days, once per ride (a second call answers
--      "already", so a retry never pays twice), not on their own trip, from
--      GET.wallet or GET.coin. The driver's GET.wallet gets it less the
--      commission on tips (0% by default: all of it), and a push.
--    * ride_cash_tip(ride, on, amount): the driver marks "Got a cash tip",
--      for their own earnings view only (no money moves).
--
-- 5. Earnings and statements: partner_statement_totals (as 0224) adds the
--    tips paid in the period ('tips', in the earnings and the net) and the
--    cash tips the driver marked ('cashTips', 'cashTipCount': the Earnings
--    page only). The keys are there only when not zero.
-- ============================================================================

-- ---- 1. Settings by place -------------------------------------------------------------------------

-- Checks one card's keys against a spec: {"key": "bool"} or {"key": [min, max]}.
-- Null when fine, else what is wrong.
create or replace function public.city_ride_extras_check_keys(p jsonb, p_spec jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    (select format('%s is not a setting of this card', e.key)
       from jsonb_each(p) e where not (p_spec ? e.key) limit 1),
    (select format('%s must be on or off', e.key)
       from jsonb_each(p) e
      where jsonb_typeof(p_spec->e.key) = 'string' and jsonb_typeof(e.value) <> 'boolean' limit 1),
    (select format('%s must be a number from %s to %s', e.key, p_spec->e.key->>0, p_spec->e.key->>1)
       from jsonb_each(p) e
      where jsonb_typeof(p_spec->e.key) = 'array'
        and (jsonb_typeof(e.value) <> 'number'
             or (e.value #>> '{}')::numeric < (p_spec->e.key->>0)::numeric
             or (e.value #>> '{}')::numeric > (p_spec->e.key->>1)::numeric)
      limit 1));
$$;
revoke execute on function public.city_ride_extras_check_keys(jsonb, jsonb) from public, anon, authenticated;

-- Tips.
create or replace function public.city_ride_extras_default_tips()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select '{"on": true, "preset1": 2, "preset2": 5, "preset3": 10, "min": 1, "max": 100, "days": 3,
           "commissionPercent": 0}'::jsonb;
$$;

create or replace function public.city_ride_extras_check_tips(p jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    public.city_ride_extras_check_keys(p, '{"on": "bool", "preset1": [1, 200], "preset2": [1, 200],
      "preset3": [1, 200], "min": [0.5, 100], "max": [1, 1000], "days": [1, 30], "commissionPercent": [0, 50]}'),
    case when jsonb_typeof(p->'min') = 'number' and jsonb_typeof(p->'max') = 'number'
              and (p->>'min')::numeric > (p->>'max')::numeric
         then 'the smallest tip is more than the largest' end);
$$;

-- The waiting charge.
create or replace function public.city_ride_extras_default_waiting()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select '{"on": true, "freeMinutes": 3, "perMinute": 0.3, "cap": 6, "radiusM": 150}'::jsonb;
$$;

create or replace function public.city_ride_extras_check_waiting(p jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select public.city_ride_extras_check_keys(p, '{"on": "bool", "freeMinutes": [0, 30], "perMinute": [0, 5],
    "cap": [0, 100], "radiusM": [25, 1000]}');
$$;

-- Luggage.
create or replace function public.city_ride_extras_default_luggage()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select '{"on": true, "freeBags": 2, "perBag": 2, "maxBags": 5}'::jsonb;
$$;

create or replace function public.city_ride_extras_check_luggage(p jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    public.city_ride_extras_check_keys(p, '{"on": "bool", "freeBags": [0, 10], "perBag": [0, 50], "maxBags": [1, 20]}'),
    case when jsonb_typeof(p->'freeBags') = 'number' and jsonb_typeof(p->'maxBags') = 'number'
              and (p->>'freeBags')::numeric > (p->>'maxBags')::numeric
         then 'more free bags than bags allowed' end);
$$;

-- The cards there are: every section with a defaults function.
create or replace function public.city_ride_extras_sections()
returns text[]
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(substr(p.proname, length('city_ride_extras_default_') + 1) order by p.proname), '{}')
    from pg_catalog.pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname like 'city\_ride\_extras\_default\_%'
     and p.pronargs = 0;
$$;

-- What is wrong with a place's rules, or null: an object of known cards,
-- each an object its own checker accepts.
create or replace function public.city_ride_extras_problem(p_rules jsonb)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  e record;
  v_why text;
begin
  if p_rules is null or jsonb_typeof(p_rules) <> 'object' then
    return 'the rules must be an object';
  end if;
  if pg_column_size(p_rules) > 32768 then
    return 'the rules are too large';
  end if;
  for e in select * from jsonb_each(p_rules) loop
    if e.key !~ '^[a-z][a-z0-9_]{0,39}$'
       or to_regprocedure(format('public.city_ride_extras_check_%s(jsonb)', e.key)) is null then
      return format('%s is not a card of this page', e.key);
    end if;
    if jsonb_typeof(e.value) <> 'object' then
      return format('%s must be an object', e.key);
    end if;
    execute format('select public.%I($1)', 'city_ride_extras_check_' || e.key) into v_why using e.value;
    if v_why is not null then
      return e.key || ': ' || v_why;
    end if;
  end loop;
  return null;
end;
$$;
revoke execute on function public.city_ride_extras_problem(jsonb) from public, anon, authenticated;

create table if not exists public.city_ride_extra_places (
  id         uuid primary key default gen_random_uuid(),
  level      text not null check (level in ('default', 'country', 'state', 'city', 'suburb')),
  country    text check (country is null or char_length(btrim(country)) between 1 and 120),
  state      text check (state is null or char_length(btrim(state)) between 1 and 120),
  city       text check (city is null or char_length(btrim(city)) between 1 and 120),
  suburb     text check (suburb is null or char_length(btrim(suburb)) between 1 and 120),
  place_key  text generated always as (public.ride_option_place_key(level, country, state, city, suburb)) stored,
  rules      jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint city_ride_extra_places_names check (
    (level = 'default' and country is null and state is null and city is null and suburb is null)
    or (level = 'country' and country is not null and state is null and city is null and suburb is null)
    or (level = 'state' and country is not null and state is not null and city is null and suburb is null)
    or (level = 'city' and country is not null and state is not null and city is not null and suburb is null)
    or (level = 'suburb' and country is not null and state is not null and city is not null and suburb is not null))
);
create unique index if not exists city_ride_extra_places_key_uidx on public.city_ride_extra_places (place_key);
comment on table public.city_ride_extra_places is
  'City ride extras by place (0314): one object per card (tips, waiting, luggage, and later cards). The smallest place that sets a key wins, key by key.';

-- The rules are checked by each card's own checker (a trigger: a check
-- constraint can't call the functions it finds by name).
create or replace function public.city_ride_extra_places_check()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_why text := public.city_ride_extras_problem(new.rules);
begin
  if v_why is not null then
    raise exception 'CITY_RIDE_EXTRAS_INVALID' using errcode = '23514', hint = v_why;
  end if;
  return new;
end;
$$;
revoke execute on function public.city_ride_extra_places_check() from public, anon, authenticated;

drop trigger if exists trg_city_ride_extra_places_check on public.city_ride_extra_places;
create trigger trg_city_ride_extra_places_check before insert or update on public.city_ride_extra_places
  for each row execute function public.city_ride_extra_places_check();
drop trigger if exists trg_city_ride_extra_places_updated_at on public.city_ride_extra_places;
create trigger trg_city_ride_extra_places_updated_at before update on public.city_ride_extra_places
  for each row execute function public.set_updated_at();

alter table public.city_ride_extra_places enable row level security;
revoke all on public.city_ride_extra_places from anon;
grant select, insert, update, delete on public.city_ride_extra_places to authenticated;
drop policy if exists "city_ride_extra_places read" on public.city_ride_extra_places;
drop policy if exists "city_ride_extra_places admin insert" on public.city_ride_extra_places;
drop policy if exists "city_ride_extra_places admin update" on public.city_ride_extra_places;
drop policy if exists "city_ride_extra_places admin delete" on public.city_ride_extra_places;
-- Riders and drivers read them to price and show the extras; the server checks them.
create policy "city_ride_extra_places read" on public.city_ride_extra_places for select to authenticated using (true);
create policy "city_ride_extra_places admin insert" on public.city_ride_extra_places for insert to authenticated
  with check ((select public.caller_admin_can_write('city_ride_extra_places')));
create policy "city_ride_extra_places admin update" on public.city_ride_extra_places for update to authenticated
  using ((select public.caller_admin_can_write('city_ride_extra_places')))
  with check ((select public.caller_admin_can_write('city_ride_extra_places')));
-- Default stays: it is where every place starts.
create policy "city_ride_extra_places admin delete" on public.city_ride_extra_places for delete to authenticated
  using (level <> 'default' and (select public.caller_admin_can_write('city_ride_extra_places')));

insert into public.admin_table_pages (target, page) values
  ('city_ride_extra_places', 'admin-settings-city-ride-extras')
on conflict do nothing;

-- Default: the luggage numbers from the meter's master tariff when it
-- charges for bags; every other value is the built-in default above.
insert into public.city_ride_extra_places (level, rules)
select 'default', coalesce((
         select jsonb_build_object('luggage', jsonb_build_object('freeBags', least(greatest(m.free_luggage, 0), 10),
                                                                'perBag', least(m.extra_luggage_charge, 50)))
           from public.meter_digital_settings m
          where m.level = 'master' and m.active and m.extra_luggage_charge > 0
          order by m.updated_at desc
          limit 1), '{}'::jsonb)
on conflict (place_key) do nothing;

-- What holds at a place: every card's defaults, then each place from
-- Default down to the suburb laying its own keys over them.
create or replace function public.city_ride_extras_at(p_country text, p_state text, p_city text, p_suburb text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v jsonb := '{}'::jsonb;
  d jsonb;
  s text;
  e record;
  k text[] := array[''];
  c text := lower(btrim(coalesce(p_country, '')));
  st text := lower(btrim(coalesce(p_state, '')));
  t text := lower(btrim(coalesce(p_city, '')));
  b text := lower(btrim(coalesce(p_suburb, '')));
  r public.city_ride_extra_places;
begin
  foreach s in array public.city_ride_extras_sections() loop
    execute format('select public.%I()', 'city_ride_extras_default_' || s) into d;
    v := v || jsonb_build_object(s, coalesce(d, '{}'::jsonb));
  end loop;
  if c <> '' then
    k := k || c;
    if st <> '' then
      k := k || (c || '|' || st);
      if t <> '' then
        k := k || (c || '|' || st || '|' || t);
        if b <> '' then
          k := k || (c || '|' || st || '|' || t || '|' || b);
        end if;
      end if;
    end if;
  end if;
  for r in
    select p.* from public.city_ride_extra_places p
     where p.place_key = any (k)
     order by case p.level when 'default' then 0 when 'country' then 1 when 'state' then 2
                           when 'city' then 3 else 4 end
  loop
    for e in select * from jsonb_each(r.rules) where jsonb_typeof(value) = 'object' loop
      v := v || jsonb_build_object(e.key, coalesce(v->e.key, '{}'::jsonb) || e.value);
    end loop;
  end loop;
  return v;
end;
$$;
revoke execute on function public.city_ride_extras_at(text, text, text, text) from public, anon, authenticated;

-- What holds at a point (the place the server reads a booking's options
-- at, 0253).
create or replace function public.city_ride_extras_here(p_lat double precision, p_lng double precision,
                                                        p_country text default null, p_state text default null,
                                                        p_city text default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.city_ride_extras_at(p.country, p.state, p.city, p.suburb)
    from public.ride_option_place(p_lat, p_lng, p_country, p_state, p_city) p;
$$;
revoke execute on function public.city_ride_extras_here(double precision, double precision, text, text, text)
  from public, anon;
grant execute on function public.city_ride_extras_here(double precision, double precision, text, text, text)
  to authenticated;

create or replace function public.city_ride_extras_for(r public.ride_requests)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.city_ride_extras_here(r.pickup_lat, r.pickup_lng, r.country, r.state, r.city);
$$;
revoke execute on function public.city_ride_extras_for(public.ride_requests) from public, anon, authenticated;

-- A number from a card, or [p_default].
create or replace function public.city_ride_extras_num(p jsonb, p_key text, p_default numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case when jsonb_typeof(p->p_key) = 'number' then (p->>p_key)::numeric else p_default end;
$$;

create or replace function public.city_ride_extras_on(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(case when jsonb_typeof(p->'on') = 'boolean' then (p->>'on')::boolean end, false);
$$;

-- ---- 2. The waiting charge ------------------------------------------------------------------------
alter table public.ride_requests add column if not exists waiting_from timestamptz;
alter table public.ride_requests add column if not exists waiting_terms jsonb;
alter table public.ride_requests add column if not exists waiting_minutes integer;
alter table public.ride_requests add column if not exists waiting_charge numeric(10,2);
alter table public.ride_requests drop constraint if exists ride_requests_waiting_valid;
alter table public.ride_requests add constraint ride_requests_waiting_valid check (
  (waiting_minutes is null or waiting_minutes >= 0)
  and (waiting_charge is null or waiting_charge >= 0)
  and (waiting_terms is null or jsonb_typeof(waiting_terms) = 'object'));

-- The minutes waited from [p_from] to [p_at] and what they cost under
-- [p_terms] ({freeMinutes, perMinute, cap}). Kept in step with
-- waitingCharge (lib/src/core/city_ride_extras.dart).
create or replace function public.ride_waiting_charge(p_terms jsonb, p_from timestamptz, p_at timestamptz)
returns table (minutes integer, charge numeric)
language sql
immutable
set search_path = ''
as $$
  select m, round(least(public.city_ride_extras_num(p_terms, 'cap', 0),
                        greatest(0, m - public.city_ride_extras_num(p_terms, 'freeMinutes', 0))
                        * public.city_ride_extras_num(p_terms, 'perMinute', 0)), 2)
    from (select greatest(0, floor(extract(epoch from (p_at - p_from)) / 60))::integer as m) x;
$$;

-- The server's columns stay the server's.
create or replace function public.ride_requests_guard_city_extras()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if num_nonnulls(new.waiting_from, new.waiting_terms, new.waiting_minutes, new.waiting_charge) > 0 then
      raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'The waiting charge is the server''s.';
    end if;
    return new;
  end if;
  if (new.waiting_from, new.waiting_terms, new.waiting_minutes, new.waiting_charge)
     is distinct from (old.waiting_from, old.waiting_terms, old.waiting_minutes, old.waiting_charge) then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'The waiting charge is the server''s.';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_guard_city_extras() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_b_guard_city_extras on public.ride_requests;
create trigger trg_ride_requests_b_guard_city_extras
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_guard_city_extras();

-- Arrived, checked; picked up, charged (see the header). After the guards
-- (b_*) and 0223's stamps (0_client_columns), beside 0267's d_freight_trip.
create or replace function public.ride_requests_city_waiting()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app boolean := coalesce(current_setting('role', true), '') in ('anon', 'authenticated')
                   and not public.caller_admin_can_write('ride_requests');
  w jsonb;
  v_lat double precision;
  v_lng double precision;
  v_m numeric;
  v_radius numeric;
  v_booked timestamptz;
  c record;
begin
  if old.cargo_description is not null then
    return new;  -- Freight and Courier wait by 0267's rules
  end if;

  if new.status = 'arrived' and old.status = 'accepted' then
    if not v_app then
      return new;
    end if;
    w := public.city_ride_extras_for(old)->'waiting';
    if not public.city_ride_extras_on(w) then
      return new;
    end if;
    -- Where the driver is: what the app sent with Arrived, else a fresh
    -- live position on the ride, else a fresh presence.
    if new.partner_arrive_lat is not null and new.partner_arrive_lng is not null
       and (new.partner_arrive_lat, new.partner_arrive_lng)
           is distinct from (old.partner_arrive_lat, old.partner_arrive_lng) then
      v_lat := new.partner_arrive_lat;
      v_lng := new.partner_arrive_lng;
    elsif new.partner_live_lat is not null and new.partner_live_lng is not null
          and new.partner_live_at > now() - interval '2 minutes' then
      v_lat := new.partner_live_lat;
      v_lng := new.partner_live_lng;
    else
      select d.lat, d.lng into v_lat, v_lng from public.driver_presence d
       where d.profile_id = old.partner_id and d.updated_at > now() - interval '2 minutes'
         and d.lat is not null and d.lng is not null;
    end if;
    if v_lat is null or v_lng is null or old.pickup_lat is null or old.pickup_lng is null then
      return new;  -- nothing to check against: no clock
    end if;
    v_radius := public.city_ride_extras_num(w, 'radiusM', 150);
    v_m := round((public.km_between(v_lat, v_lng, old.pickup_lat, old.pickup_lng) * 1000)::numeric);
    if v_m > v_radius then
      raise exception 'RIDE_ARRIVED_TOO_FAR' using errcode = '42501',
        hint = format('You''re about %s m from the pickup. Arrived works within %s m of it.',
                      trim_scale(v_m), trim_scale(v_radius));
    end if;
    if old.scheduled_ride_id is not null then
      select s.pickup_at into v_booked from public.scheduled_rides s where s.id = old.scheduled_ride_id;
    end if;
    new.waiting_from := greatest(now(), coalesce(v_booked, now()));
    new.waiting_terms := jsonb_build_object(
      'freeMinutes', public.city_ride_extras_num(w, 'freeMinutes', 0),
      'perMinute', public.city_ride_extras_num(w, 'perMinute', 0),
      'cap', public.city_ride_extras_num(w, 'cap', 0));
    return new;
  end if;

  if new.status = 'on_trip' and old.status in ('accepted', 'arrived') and old.waiting_from is not null
     and new.waiting_charge is null then
    select * into c from public.ride_waiting_charge(old.waiting_terms, old.waiting_from, now());
    new.waiting_minutes := c.minutes;
    new.waiting_charge := c.charge;
    if c.charge > 0 then
      new.fare := coalesce(new.fare, 0) + c.charge;
      new.ride_fare := coalesce(new.ride_fare, old.fare, 0) + c.charge;
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_city_waiting() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_d_city_waiting on public.ride_requests;
create trigger trg_ride_requests_d_city_waiting
  before update of status on public.ride_requests
  for each row execute function public.ride_requests_city_waiting();

-- ---- 3. Luggage -------------------------------------------------------------------------------------
-- Why a booking's bags and luggage line can't go at its pickup, as
-- {code, hint}; null when they can.
create or replace function public.ride_luggage_problem(
  p_bags integer, p_lines jsonb, p_cargo boolean,
  p_lat double precision, p_lng double precision, p_country text, p_state text, p_city text)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  l jsonb;
  v_lines integer;
  v_have numeric;
  v_want numeric;
  v_bags integer := coalesce(p_bags, 0);
begin
  select count(*), coalesce(sum((e->>'amount')::numeric), 0) into v_lines, v_have
    from jsonb_array_elements(case when jsonb_typeof(p_lines) = 'array' then p_lines else '[]'::jsonb end) e
   where e->>'kind' = 'luggage' and jsonb_typeof(e->'amount') = 'number';
  if coalesce(p_cargo, false) then
    if v_lines > 0 then
      return array['RIDE_LUGGAGE_NOT_HERE', 'Luggage is for rides. Describe what you send instead.'];
    end if;
    return null;
  end if;
  if v_bags < 0 then
    return array['RIDE_LUGGAGE_TOO_MANY', 'Choose how many bags you bring.'];
  end if;
  l := public.city_ride_extras_here(p_lat, p_lng, p_country, p_state, p_city)->'luggage';
  if not public.city_ride_extras_on(l) then
    v_want := 0;
  else
    if v_bags > public.city_ride_extras_num(l, 'maxBags', 5) then
      return array['RIDE_LUGGAGE_TOO_MANY',
                   format('Up to %s bags here. Book a bigger car or take fewer bags.',
                          trim_scale(public.city_ride_extras_num(l, 'maxBags', 5)))];
    end if;
    v_want := round(greatest(0, v_bags - public.city_ride_extras_num(l, 'freeBags', 0))
                    * public.city_ride_extras_num(l, 'perBag', 0), 2);
  end if;
  if abs(v_want - v_have) > 0.005 then
    return array['RIDE_LUGGAGE_CHARGE_CHANGED', 'The luggage charge here has changed. Check your fare and book again.'];
  end if;
  return null;
end;
$$;
revoke execute on function public.ride_luggage_problem(integer, jsonb, boolean, double precision, double precision,
                                                       text, text, text) from public, anon, authenticated;

-- App bookings now. A stand's order and a scheduled booking's release
-- (checked when it was booked) are not the app's.
create or replace function public.ride_requests_city_luggage()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_problem text[];
begin
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated')
     or public.caller_admin_can_write('ride_requests')
     or new.stand_id is not null or new.scheduled_ride_id is not null then
    return new;
  end if;
  v_problem := public.ride_luggage_problem(new.luggage, new.option_charges, new.cargo_description is not null,
                                           new.pickup_lat, new.pickup_lng, new.country, new.state, new.city);
  if v_problem is not null then
    raise exception '%', v_problem[1] using errcode = '22023', hint = v_problem[2];
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_city_luggage() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_c_city_luggage on public.ride_requests;
create trigger trg_ride_requests_c_city_luggage
  before insert on public.ride_requests
  for each row execute function public.ride_requests_city_luggage();

-- The bags are set when the ride is booked.
create or replace function public.ride_requests_luggage_fixed()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if new.luggage is distinct from old.luggage then
    raise exception 'RIDE_LUGGAGE_FIXED' using errcode = '42501',
      hint = 'The bags are set when the ride is booked.';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_luggage_fixed() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_b_luggage_fixed on public.ride_requests;
create trigger trg_ride_requests_b_luggage_fixed
  before update of luggage on public.ride_requests
  for each row execute function public.ride_requests_luggage_fixed();

-- A booking for later: the same check when it is booked.
create or replace function public.scheduled_rides_city_luggage()
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
  v_problem := public.ride_luggage_problem(
    case when jsonb_typeof(q->'luggage') = 'number' then (q->>'luggage')::numeric::integer else 0 end,
    q->'option_charges', nullif(btrim(coalesce(q->>'cargo_description', '')), '') is not null,
    new.pickup_lat, new.pickup_lng, q->>'country', q->>'state', q->>'city');
  if v_problem is not null then
    raise exception '%', v_problem[1] using errcode = '22023', hint = v_problem[2];
  end if;
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_city_luggage() from public, anon, authenticated;

drop trigger if exists trg_scheduled_rides_city_luggage on public.scheduled_rides;
create trigger trg_scheduled_rides_city_luggage
  before insert on public.scheduled_rides
  for each row execute function public.scheduled_rides_city_luggage();

-- ---- 4. Tips --------------------------------------------------------------------------------------
create table if not exists public.ride_tips (
  id              uuid primary key default gen_random_uuid(),
  ride_id         uuid not null references public.ride_requests(id) on delete cascade,
  rider_id        uuid,
  partner_id      uuid not null,
  -- GET.wallet or GET.coin from the rider's app; 'cash' the driver marked.
  method          text not null check (method in ('get_wallet', 'get_coin', 'cash')),
  -- The tip; for a cash mark, what the driver noted (maybe nothing).
  amount          numeric(10,2) check (amount is null or amount > 0),
  commission_rate numeric(6,4) not null default 0 check (commission_rate >= 0 and commission_rate < 1),
  -- What reached the driver's GET.wallet (app tips).
  driver_amount   numeric(10,2) check (driver_amount is null or driver_amount >= 0),
  coins_used      numeric(12,2),
  currency        text,
  created_at      timestamptz not null default now(),
  constraint ride_tips_paid check (method = 'cash' or (amount is not null and driver_amount is not null))
);
create unique index if not exists ride_tips_app_uidx on public.ride_tips (ride_id) where method <> 'cash';
create unique index if not exists ride_tips_cash_uidx on public.ride_tips (ride_id) where method = 'cash';
create index if not exists ride_tips_partner_idx on public.ride_tips (partner_id, created_at);
create index if not exists ride_tips_rider_idx on public.ride_tips (rider_id) where rider_id is not null;
comment on table public.ride_tips is
  'Tips (0314): a rider''s GET.wallet / GET.coin tip, one per ride, and the cash tip a driver marked for their own earnings view. Written only by ride_tip and ride_cash_tip.';

alter table public.ride_tips enable row level security;
revoke all on public.ride_tips from anon, authenticated;
grant select on public.ride_tips to authenticated;
drop policy if exists "ride_tips parties read" on public.ride_tips;
-- The rider reads their tip; the driver every tip of theirs (a cash mark
-- is theirs alone).
create policy "ride_tips parties read" on public.ride_tips for select to authenticated
  using ((rider_id = (select auth.uid()) and method <> 'cash')
         or partner_id = (select auth.uid())
         or (select public.caller_is_admin()));

-- What the tip card and the driver's trip card show (see the header). The
-- ride's rider or driver.
create or replace function public.ride_tip_terms(p_ride uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.ride_requests;
  x jsonb;
  v_until timestamptz;
  v_why text;
  v_tip jsonb;
  v_cash jsonb;
begin
  select * into r from public.ride_requests where id = p_ride;
  if not found or v_uid is null or (v_uid is distinct from r.rider_id and v_uid is distinct from r.partner_id) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  x := public.city_ride_extras_for(r)->'tips';
  v_until := coalesce(r.completed_at, now())
             + make_interval(days => public.city_ride_extras_num(x, 'days', 3)::integer);
  select jsonb_build_object('amount', t.amount, 'method', t.method, 'at', t.created_at,
                            'driverAmount', t.driver_amount)
    into v_tip from public.ride_tips t where t.ride_id = r.id and t.method <> 'cash';
  if v_uid = r.partner_id then
    select jsonb_build_object('amount', t.amount, 'at', t.created_at)
      into v_cash from public.ride_tips t where t.ride_id = r.id and t.method = 'cash';
  end if;
  v_why := case
    when not public.city_ride_extras_on(x) then 'off'
    when r.status <> 'completed' then 'not_completed'
    when r.partner_id is null then 'no_driver'
    when r.rider_id = r.partner_id then 'own_trip'
    when v_tip is not null then 'tipped'
    when now() > v_until then 'expired'
    when v_uid is distinct from r.rider_id then 'not_rider'
  end;
  return jsonb_build_object(
    'on', public.city_ride_extras_on(x),
    'presets', jsonb_build_array(public.city_ride_extras_num(x, 'preset1', 2),
                                 public.city_ride_extras_num(x, 'preset2', 5),
                                 public.city_ride_extras_num(x, 'preset3', 10)),
    'min', public.city_ride_extras_num(x, 'min', 1),
    'max', public.city_ride_extras_num(x, 'max', 100),
    'days', public.city_ride_extras_num(x, 'days', 3),
    'commissionPercent', public.city_ride_extras_num(x, 'commissionPercent', 0),
    'until', v_until,
    'currency', r.currency,
    'driverName', r.partner_name,
    'canTip', v_why is null,
    'why', v_why,
    'tip', v_tip,
    'cashTip', v_cash);
end;
$$;
revoke execute on function public.ride_tip_terms(uuid) from public, anon;
grant execute on function public.ride_tip_terms(uuid) to authenticated;

-- The rider tips the ride's driver (see the header).
create or replace function public.ride_tip(p_ride uuid, p_amount numeric, p_method text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.ride_requests;
  x jsonb;
  t public.ride_tips;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_rate numeric;
  v_driver numeric;
  v_coin_rate numeric;
  v_coins numeric;
  v_balance numeric;
  v_money text;
  v_rider text;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_method not in ('get_wallet', 'get_coin') then
    raise exception 'invalid_method' using errcode = '22023';
  end if;
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.rider_id is distinct from v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status <> 'completed' then
    raise exception 'TIP_NOT_COMPLETED' using errcode = '42501', hint = 'You can tip once the trip is complete.';
  end if;
  if r.partner_id is null or r.partner_id = r.rider_id then
    raise exception 'TIP_OWN_TRIP' using errcode = '42501', hint = 'You can''t tip your own trip.';
  end if;
  -- Once per ride: a second call (a retry) answers with the first.
  select * into t from public.ride_tips where ride_id = r.id and method <> 'cash';
  if found then
    return jsonb_build_object('already', true, 'amount', t.amount, 'method', t.method,
                              'driverAmount', t.driver_amount);
  end if;
  x := public.city_ride_extras_for(r)->'tips';
  if not public.city_ride_extras_on(x) then
    raise exception 'TIP_OFF' using errcode = '42501', hint = 'Tips aren''t taken here.';
  end if;
  if now() > coalesce(r.completed_at, now())
             + make_interval(days => public.city_ride_extras_num(x, 'days', 3)::integer) then
    raise exception 'TIP_EXPIRED' using errcode = '42501', hint = 'The time to tip this trip has passed.';
  end if;
  if not public.ride_money_ok(v_amount) or v_amount < public.city_ride_extras_num(x, 'min', 1)
     or v_amount > public.city_ride_extras_num(x, 'max', 100) then
    raise exception 'TIP_AMOUNT' using errcode = '22023',
      hint = format('Tip from %s to %s.', trim_scale(public.city_ride_extras_num(x, 'min', 1)),
                    trim_scale(public.city_ride_extras_num(x, 'max', 100)));
  end if;
  v_rate := least(0.5, greatest(0, public.city_ride_extras_num(x, 'commissionPercent', 0) / 100));
  v_driver := round(v_amount * (1 - v_rate), 2);
  v_money := coalesce(r.currency, 'RM') || ' ' || to_char(v_amount, 'FM999999990.00');
  v_rider := coalesce(nullif(split_part(btrim(coalesce(r.rider_name, '')), ' ', 1), ''), 'Your rider');

  if p_method = 'get_wallet' then
    insert into public.wallets (user_id, wallet_type, balance) values (v_uid, 'get_wallet', 0)
    on conflict (user_id, wallet_type) do nothing;
    select w.balance into v_balance from public.wallets w
     where w.user_id = v_uid and w.wallet_type = 'get_wallet' for update;
    if coalesce(v_balance, 0) < v_amount then
      raise exception 'insufficient_balance' using errcode = '22023', hint = 'Top up GET.wallet, or tip with GET.coin.';
    end if;
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (v_uid, 'get_wallet', 'tip', -v_amount, 'tip', 'Tip for ' || coalesce(r.partner_name, 'your driver'));
  else
    select s.coins_per_currency into v_coin_rate from public.get_coin_settings s where s.id = 'master';
    if coalesce(v_coin_rate, 0) <= 0 then
      raise exception 'coins_unavailable' using errcode = '22023';
    end if;
    v_coins := ceil(v_amount * v_coin_rate * 100) / 100;
    insert into public.wallets (user_id, wallet_type, balance) values (v_uid, 'get_coin', 0)
    on conflict (user_id, wallet_type) do nothing;
    select w.balance into v_balance from public.wallets w
     where w.user_id = v_uid and w.wallet_type = 'get_coin' for update;
    if coalesce(v_balance, 0) < v_coins then
      raise exception 'insufficient_balance' using errcode = '22023', hint = 'Not enough GET.coin for this tip.';
    end if;
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (v_uid, 'get_coin', 'redeem', -v_coins, 'tip',
            'Tip for ' || coalesce(r.partner_name, 'your driver') || ' (' || v_money || ')');
  end if;
  if v_driver > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (r.partner_id, 'get_wallet', 'tip', v_driver, 'tip',
            'Tip from ' || v_rider || case when v_rate > 0
              then ' (less ' || trim_scale(round(v_rate * 100, 1)) || '% commission)' else '' end);
  end if;
  insert into public.ride_tips (ride_id, rider_id, partner_id, method, amount, commission_rate, driver_amount,
                                coins_used, currency)
  values (r.id, v_uid, r.partner_id, p_method, v_amount, v_rate, v_driver, v_coins, r.currency)
  returning * into t;

  begin
    perform public.enqueue_notification(r.partner_id, 'ride_tip:' || t.id, 'ride_tip', 'normal',
      'You got a tip', v_rider || ' tipped you ' || v_money || '.',
      jsonb_build_object('type', 'ride_tip', 'rideId', r.id), r.id);
  exception when others then
    raise warning 'tip push for % not sent: %', t.id, sqlerrm;
  end;

  return jsonb_build_object('already', false, 'amount', t.amount, 'method', t.method,
                            'driverAmount', t.driver_amount, 'coins', coalesce(v_coins, 0));
end;
$$;
revoke execute on function public.ride_tip(uuid, numeric, text) from public, anon;
grant execute on function public.ride_tip(uuid, numeric, text) to authenticated;

-- The driver marks a cash tip (or takes the mark back), for their own
-- earnings view. [p_amount] is optional.
create or replace function public.ride_cash_tip(p_ride uuid, p_on boolean, p_amount numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.ride_requests;
  v_amount numeric := case when p_amount is null or p_amount <= 0 then null else round(p_amount, 2) end;
begin
  select * into r from public.ride_requests where id = p_ride;
  if not found or v_uid is null or r.partner_id is distinct from v_uid then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status <> 'completed' then
    raise exception 'TIP_NOT_COMPLETED' using errcode = '42501', hint = 'Mark a cash tip once the trip is complete.';
  end if;
  if v_amount is not null and not (public.ride_money_ok(v_amount) and v_amount <= 10000) then
    raise exception 'TIP_AMOUNT' using errcode = '22023', hint = 'Enter what you were given, or leave it empty.';
  end if;
  if not coalesce(p_on, false) then
    delete from public.ride_tips where ride_id = r.id and method = 'cash';
    return jsonb_build_object('cashTip', null);
  end if;
  insert into public.ride_tips (ride_id, rider_id, partner_id, method, amount, currency)
  values (r.id, r.rider_id, v_uid, 'cash', v_amount, r.currency)
  on conflict (ride_id) where method = 'cash' do update set amount = excluded.amount;
  return jsonb_build_object('cashTip', jsonb_build_object('amount', v_amount));
end;
$$;
revoke execute on function public.ride_cash_tip(uuid, boolean, numeric) from public, anon;
grant execute on function public.ride_cash_tip(uuid, boolean, numeric) to authenticated;

-- ---- 5. Earnings and statements -------------------------------------------------------------------
-- As 0224, with the tips paid in the period and the cash tips marked.
create or replace function public.partner_statement_totals(p_uid uuid, p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.partner_statement_config();
  earning text[] := array(select jsonb_array_elements_text(cfg->'earningSurcharges'));
  t jsonb;
  w record;
  tp record;
  n_rides bigint;
  n_meter bigint;
  e numeric;
  d numeric;
  adj numeric;
begin
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) into t from (
    select k, round(sum((s.l->>k)::numeric), 2) as v
      from (
        select public.statement_ride_lines(r, earning) as l
          from public.ride_requests r
         where r.partner_id = p_uid and r.status = 'completed' and r.completed_at >= p_from and r.completed_at < p_to
        union all
        select public.statement_meter_lines(m, earning)
          from public.meter_trips m
         where m.partner_id = p_uid and m.ended_at >= p_from and m.ended_at < p_to
      ) s
      cross join lateral jsonb_object_keys(s.l) k
     group by k) s2;
  select count(*) into n_rides from public.ride_requests r
   where r.partner_id = p_uid and r.status = 'completed' and r.completed_at >= p_from and r.completed_at < p_to;
  select count(*) into n_meter from public.meter_trips m
   where m.partner_id = p_uid and m.ended_at >= p_from and m.ended_at < p_to;
  t := t || jsonb_build_object('trips', n_rides + n_meter);
  -- Only where there are some, so a period without meter hires reads as before.
  if n_meter > 0 then
    t := t || jsonb_build_object('meterTrips', n_meter);
  end if;

  select coalesce(sum(case when kind = 'incentive' then amount end), 0) as incentives,
         coalesce(sum(case when kind = 'handover_share' and amount > 0 then amount end), 0) as hin,
         coalesce(-sum(case when kind = 'handover_share' and amount < 0 then amount end), 0) as hout
    into w
    from public.wallet_transactions
   where user_id = p_uid and wallet_type = 'get_credit' and kind in ('incentive', 'handover_share')
     and created_at >= p_from and created_at < p_to;
  select coalesce(sum(amount), 0) into adj from public.partner_adjustments
   where profile_id = p_uid and effective_at >= p_from and effective_at < p_to;

  -- Tips (0314): what reached the driver, by when it was given; and the
  -- cash tips they marked, for the Earnings page alone.
  select coalesce(sum(x.driver_amount) filter (where x.method <> 'cash'), 0) as tips,
         coalesce(sum(x.amount) filter (where x.method = 'cash'), 0) as cash,
         count(*) filter (where x.method = 'cash') as cash_n
    into tp
    from public.ride_tips x
   where x.partner_id = p_uid and x.created_at >= p_from and x.created_at < p_to;
  if tp.tips > 0 then
    t := t || jsonb_build_object('tips', round(tp.tips, 2));
  end if;
  if tp.cash_n > 0 then
    t := t || jsonb_build_object('cashTips', round(tp.cash, 2), 'cashTipCount', tp.cash_n);
  end if;

  t := t || jsonb_build_object(
    'incentives', round(w.incentives, 2),
    'handoverIn', round(w.hin, 2),
    'handoverOut', round(w.hout, 2),
    'adjustments', round(adj, 2),
    'onlineHours', public.partner_online_hours(p_uid, p_from, p_to));
  e := coalesce((t->>'fare')::numeric, 0) + coalesce((t->>'surcharges')::numeric, 0)
     + coalesce((t->>'platformCollected')::numeric, 0) + w.incentives + w.hin + tp.tips;
  d := coalesce((t->>'commission')::numeric, 0) + coalesce((t->>'platformFees')::numeric, 0) + w.hout;
  return t || jsonb_build_object(
    'totalEarnings', round(e, 2),
    'totalDeductions', round(d, 2),
    'net', round(e - d + adj, 2),
    'passThrough', round(coalesce((t->>'taxes')::numeric, 0) + coalesce((t->>'tolls')::numeric, 0)
                         + coalesce((t->>'otherCharges')::numeric, 0) + coalesce((t->>'surchargesPass')::numeric, 0), 2));
end;
$$;
revoke execute on function public.partner_statement_totals(uuid, timestamptz, timestamptz) from public, anon, authenticated;

-- ---- 6. Live in the apps --------------------------------------------------------------------------
do $$
begin
  -- Read live by every app (lib/src/data/live_tables.dart).
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and tablename = 'city_ride_extra_places') then
    alter publication supabase_realtime add table public.city_ride_extra_places;
  end if;
  -- A tip shows on the driver's trip card as it is given.
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and tablename = 'ride_tips') then
    alter publication supabase_realtime add table public.ride_tips;
  end if;
end $$;

notify pgrst, 'reload schema';
