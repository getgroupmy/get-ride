-- ============================================================================
-- 0253: Ride Options by place, and the extras each driver takes
--
-- Admin → Display Settings → Ride Options keeps the names, order, show/hide
-- and the two charge switches (commission, promo) as one global setting in
-- the display settings blob (0248). What now varies by place is kept here:
--
--   * ride_option_places: one row per place — Default (everywhere), or a
--     country, state, city or suburb named as the Country / States / Cities
--     / Suburbs tables name it — with
--       charges: {key: {kind: fixed|percent, value, per?: pet|ride}}, where
--                key is 'pet:<type>', 'pet-size:<size>', 'assist:<item id>',
--                'child-seat' or 'more-passengers'. A key present is "set
--                here" (0 is free); absent uses the place above;
--       offered: {option id: false|true} — "Offered here", absent inherits;
--       blocked: {option id: [vehicle service ids]} — the services the
--                option is not offered on here, absent inherits.
--     Option ids: 'child-seat', 'more-passengers', 'pet', 'assistance'.
--     For a pickup the smallest place holding it with its own value wins,
--     walking up suburb → city → state → country → Default; with nothing
--     set anywhere a charge is free, an option offered on every service.
--   * The pickup's place (ride_option_place): the smallest mapped outline
--     holding the point at each level (ptr_point_place, as the partner type
--     rules and regions_at), else the names the geocoder gave (never a
--     suburb by name). The app asks for it (ride_option_place_at), so the
--     rider's sheet and this server read the same place.
--   * The amounts that were in the blob (petCharges, petSizeExtras, the
--     assistance catalogue's charges) become the Default row, so nothing
--     changes for riders until the admin edits. The fare already includes
--     the charges (the app adds them before quoting, 0248); currency is the
--     country's, as before.
--   * A booking (now or for later) with an option that is off at its pickup,
--     or blocked for its service there, is refused (RIDE_OPTION_NOT_OFFERED).
--
-- Drivers choose the extras they take (Settings → Ride extras I take):
--
--   * driver_ride_extras.off: the extras a driver turned off, as keys
--     'child-seat', 'more-passengers', 'pet:<type>' and 'assist:<item id>'
--     (lower case). Everything is on until turned off. The driver reads and
--     writes their own row; admins read every row.
--   * A request carrying an extra the driver turned off is not offered to
--     them: the open-request read rule (restrictive), the new-request,
--     widening and everyone pushes, My Ride's favourites, the airport queue
--     and waiting-zone offers, a stand group's broadcast and the scheduled
--     rides list. A request booked straight to them (GET.now, a stand's
--     assignment) still reaches them. The guide or service dog is never an
--     extra a driver can turn down.
--   * ride_extras_hidden_count: how many open requests the feed leaves out
--     for that reason.
-- ============================================================================

-- ---- 1. The places ------------------------------------------------------------------------------

-- The option ids a place setting names.
create or replace function public.ride_option_ids()
returns text[]
language sql
immutable
set search_path = ''
as $$ select array['child-seat', 'more-passengers', 'pet', 'assistance']; $$;

-- A place's settings: charges, offered and blocked as described above.
create or replace function public.ride_option_place_valid(p_charges jsonb, p_offered jsonb, p_blocked jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(p_charges) = 'object'
     and jsonb_typeof(p_offered) = 'object'
     and jsonb_typeof(p_blocked) = 'object'
     and pg_column_size(p_charges) <= 65536
     and (select count(*) from jsonb_object_keys(p_charges)) <= 400
     and not exists (
       select 1 from jsonb_each(p_charges) e
        where not coalesce(
          char_length(e.key) between 1 and 120
          and jsonb_typeof(e.value) = 'object'
          and jsonb_typeof(e.value->'value') = 'number'
          and (e.value->>'value')::numeric >= 0
          and (e.value->'kind' is null or e.value->>'kind' in ('fixed', 'percent'))
          and (e.value->>'value')::numeric <= case when e.value->>'kind' = 'percent' then 100 else 10000 end
          and (e.value->'per' is null or e.value->>'per' in ('pet', 'ride')),
          false))
     and not exists (
       select 1 from jsonb_each(p_offered) e
        where not (e.key = any (public.ride_option_ids())) or jsonb_typeof(e.value) <> 'boolean')
     and not exists (
       select 1 from jsonb_each(p_blocked) e
        where not coalesce(
          e.key = any (public.ride_option_ids())
          and jsonb_typeof(e.value) = 'array'
          and jsonb_array_length(e.value) <= 50
          and not exists (select 1 from jsonb_array_elements(e.value) s
                           where jsonb_typeof(s) <> 'string' or char_length(s #>> '{}') not between 1 and 64),
          false));
$$;

-- The place's key: '' for Default, else its names in lower case, '|'-joined.
create or replace function public.ride_option_place_key(p_level text, p_country text, p_state text, p_city text,
                                                        p_suburb text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_level = 'default' then ''
    else concat_ws('|', lower(btrim(coalesce(p_country, ''))),
                   case when p_level in ('state', 'city', 'suburb') then lower(btrim(coalesce(p_state, ''))) end,
                   case when p_level in ('city', 'suburb') then lower(btrim(coalesce(p_city, ''))) end,
                   case when p_level = 'suburb' then lower(btrim(coalesce(p_suburb, ''))) end)
  end;
$$;

create table if not exists public.ride_option_places (
  id         uuid primary key default gen_random_uuid(),
  level      text not null check (level in ('default', 'country', 'state', 'city', 'suburb')),
  country    text check (country is null or char_length(btrim(country)) between 1 and 120),
  state      text check (state is null or char_length(btrim(state)) between 1 and 120),
  city       text check (city is null or char_length(btrim(city)) between 1 and 120),
  suburb     text check (suburb is null or char_length(btrim(suburb)) between 1 and 120),
  place_key  text generated always as (public.ride_option_place_key(level, country, state, city, suburb)) stored,
  charges    jsonb not null default '{}'::jsonb,
  offered    jsonb not null default '{}'::jsonb,
  blocked    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- A place names every level above its own.
  constraint ride_option_places_names check (
    (level = 'default' and country is null and state is null and city is null and suburb is null)
    or (level = 'country' and country is not null and state is null and city is null and suburb is null)
    or (level = 'state' and country is not null and state is not null and city is null and suburb is null)
    or (level = 'city' and country is not null and state is not null and city is not null and suburb is null)
    or (level = 'suburb' and country is not null and state is not null and city is not null and suburb is not null)),
  constraint ride_option_places_valid check (public.ride_option_place_valid(charges, offered, blocked))
);
create unique index if not exists ride_option_places_key_uidx on public.ride_option_places (place_key);
comment on table public.ride_option_places is
  'Ride Options by place (0253): charges, "Offered here" and the services each option is blocked on, for Default or a country / state / city / suburb. The smallest place with its own value wins.';

drop trigger if exists trg_ride_option_places_updated_at on public.ride_option_places;
create trigger trg_ride_option_places_updated_at before update on public.ride_option_places
  for each row execute function public.set_updated_at();

alter table public.ride_option_places enable row level security;
revoke all on public.ride_option_places from anon;
grant select, insert, update, delete on public.ride_option_places to authenticated;

drop policy if exists "ride_option_places read" on public.ride_option_places;
drop policy if exists "ride_option_places admin insert" on public.ride_option_places;
drop policy if exists "ride_option_places admin update" on public.ride_option_places;
drop policy if exists "ride_option_places admin delete" on public.ride_option_places;
-- Riders read them to price and show the options; the server checks them.
create policy "ride_option_places read" on public.ride_option_places for select to authenticated using (true);
create policy "ride_option_places admin insert" on public.ride_option_places for insert to authenticated
  with check ((select public.caller_admin_can_write('ride_option_places')));
create policy "ride_option_places admin update" on public.ride_option_places for update to authenticated
  using ((select public.caller_admin_can_write('ride_option_places')))
  with check ((select public.caller_admin_can_write('ride_option_places')));
create policy "ride_option_places admin delete" on public.ride_option_places for delete to authenticated
  using ((select public.caller_admin_can_write('ride_option_places')));

-- Written from Admin → Display Settings → Ride Options.
insert into public.admin_table_pages (target, page) values
  ('ride_option_places', 'admin-settings-display')
on conflict do nothing;

-- ---- 2. The amounts that were in the blob become Default -----------------------------------------
-- The charges a display settings blob [s] held (0247, 0248), as a place's
-- charges.
create or replace function public.ride_option_charges_from_blob(s jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce((
    select jsonb_object_agg(k, v) from (
      -- Each pet type's charge, as it was ({kind, value, per}).
      select 'pet:' || e.key as k,
             jsonb_build_object('kind', case when e.value->>'kind' = 'percent' then 'percent' else 'fixed' end,
                                'value', least((e.value->>'value')::numeric,
                                               case when e.value->>'kind' = 'percent' then 100 else 10000 end),
                                'per', case when e.value->>'per' = 'ride' then 'ride' else 'pet' end) as v
        from jsonb_each(case when jsonb_typeof(s->'petCharges') = 'object' then s->'petCharges' else '{}'::jsonb end) e
       where jsonb_typeof(e.value) = 'object' and e.value->>'value' ~ '^[0-9]+(\.[0-9]+)?$'
         and (e.value->>'value')::numeric > 0 and char_length(e.key) between 1 and 100
      union all
      -- Each size's extra.
      select 'pet-size:' || e.key,
             jsonb_build_object('kind', 'fixed', 'value', least((e.value #>> '{}')::numeric, 10000))
        from jsonb_each(case when jsonb_typeof(s->'petSizeExtras') = 'object' then s->'petSizeExtras'
                             else '{}'::jsonb end) e
       where (e.value #>> '{}') ~ '^[0-9]+(\.[0-9]+)?$' and (e.value #>> '{}')::numeric > 0
         and char_length(e.key) between 1 and 100
      union all
      -- Each help item's charge (never the guide dog's).
      select 'assist:' || (i->>'id'),
             jsonb_build_object('kind', case when i->'charge'->>'kind' = 'percent' then 'percent' else 'fixed' end,
                                'value', least((i->'charge'->>'value')::numeric,
                                               case when i->'charge'->>'kind' = 'percent' then 100 else 10000 end))
        from jsonb_array_elements(case when jsonb_typeof(s->'assistanceCatalogue') = 'array'
                                       then s->'assistanceCatalogue' else '[]'::jsonb end) i
       where jsonb_typeof(i) = 'object' and jsonb_typeof(i->'charge') = 'object'
         and char_length(coalesce(i->>'id', '')) between 1 and 100 and i->>'id' <> 'guide-dog'
         and i->'charge'->>'value' ~ '^[0-9]+(\.[0-9]+)?$' and (i->'charge'->>'value')::numeric > 0
    ) x), '{}'::jsonb);
$$;

insert into public.ride_option_places (level, charges)
select 'default', public.ride_option_charges_from_blob(
  coalesce((select settings from public.admin_display_settings where id = 'global'), '{}'::jsonb))
on conflict (place_key) do nothing;

-- ---- 3. The pickup's place, and what holds there ------------------------------------------------

-- The place at a pickup: the smallest mapped outline at each level, else
-- the geocoder's names (country, state, city; a suburb only by outline).
create or replace function public.ride_option_place(p_lat double precision, p_lng double precision,
                                                    p_country text default null, p_state text default null,
                                                    p_city text default null)
returns table (country text, state text, city text, suburb text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c text := '';
  s text := '';
  t text := '';
  b text := '';
begin
  select coalesce(x.country, ''), coalesce(x.state, ''), coalesce(x.city, ''), coalesce(x.suburb, '')
    into c, s, t, b
    from public.ptr_point_place(p_lat, p_lng) x;
  if coalesce(c, '') = '' then
    c := btrim(coalesce(p_country, ''));
    b := '';
  end if;
  if c <> '' and coalesce(s, '') = '' and lower(c) = lower(btrim(coalesce(p_country, ''))) then
    s := btrim(coalesce(p_state, ''));
    b := '';
  end if;
  if s <> '' and coalesce(t, '') = '' and lower(s) = lower(btrim(coalesce(p_state, ''))) then
    t := btrim(coalesce(p_city, ''));
    b := '';
  end if;
  if c = '' then
    s := '';
  end if;
  if coalesce(s, '') = '' then
    t := '';
  end if;
  if coalesce(t, '') = '' then
    b := '';
  end if;
  return query select coalesce(c, ''), coalesce(s, ''), coalesce(t, ''), coalesce(b, '');
end;
$$;
revoke execute on function public.ride_option_place(double precision, double precision, text, text, text)
  from public, anon, authenticated;

-- For the app: the place the server will read a booking's options at.
create or replace function public.ride_option_place_at(p_lat double precision, p_lng double precision,
                                                       p_country text default null, p_state text default null,
                                                       p_city text default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('country', p.country, 'state', p.state, 'city', p.city, 'suburb', p.suburb)
    from public.ride_option_place(p_lat, p_lng, p_country, p_state, p_city) p;
$$;
revoke execute on function public.ride_option_place_at(double precision, double precision, text, text, text)
  from public, anon;
grant execute on function public.ride_option_place_at(double precision, double precision, text, text, text)
  to authenticated;

-- What holds at a place: {charges, offered, blocked}, each key from the
-- smallest place (of Default, the country, state, city and suburb named)
-- that sets it.
create or replace function public.ride_option_settings_at(p_country text, p_state text, p_city text, p_suburb text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.ride_option_places;
  v_charges jsonb := '{}'::jsonb;
  v_offered jsonb := '{}'::jsonb;
  v_blocked jsonb := '{}'::jsonb;
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
    select p.* from public.ride_option_places p
     where p.place_key = any (k)
     order by case p.level when 'default' then 0 when 'country' then 1 when 'state' then 2
                           when 'city' then 3 else 4 end
  loop
    v_charges := v_charges || r.charges;
    v_offered := v_offered || r.offered;
    v_blocked := v_blocked || r.blocked;
  end loop;
  return jsonb_build_object('charges', v_charges, 'offered', v_offered, 'blocked', v_blocked);
end;
$$;
revoke execute on function public.ride_option_settings_at(text, text, text, text) from public, anon, authenticated;

-- The options a booking has on, by id.
create or replace function public.ride_option_kinds(p_pets jsonb, p_assistance jsonb, p_names jsonb,
                                                    p_passengers integer)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array_remove(array[
    case when jsonb_typeof(p_names) = 'object' and p_names ? 'child-seat' then 'child-seat' end,
    case when (jsonb_typeof(p_names) = 'object' and p_names ? 'more-passengers') or coalesce(p_passengers, 0) > 4
         then 'more-passengers' end,
    case when (jsonb_typeof(p_pets) = 'array' and jsonb_array_length(p_pets) > 0)
              or (jsonb_typeof(p_names) = 'object' and p_names ? 'pet') then 'pet' end,
    case when jsonb_typeof(p_assistance) = 'object' then 'assistance' end], null);
$$;

-- The first of [p_kinds] that is off at a place ([p_settings], as
-- ride_option_settings_at gives it) or blocked there for [p_service] (a
-- service name); null when every one is offered.
create or replace function public.ride_option_refused(p_kinds text[], p_settings jsonb, p_service text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select k from unnest(coalesce(p_kinds, '{}')) with ordinality u(k, n)
   where p_settings->'offered'->k = 'false'::jsonb
      or (jsonb_typeof(p_settings->'blocked'->k) = 'array'
          and p_settings->'blocked'->k ? coalesce(public.vehicle_service_id_of(p_service), ''))
   order by n
   limit 1;
$$;
revoke execute on function public.ride_option_refused(text[], jsonb, text) from public, anon, authenticated;

-- The option's name for the refusal: as booked, else the built-in one.
create or replace function public.ride_option_name(p_kind text, p_names jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(case when jsonb_typeof(p_names) = 'object' then nullif(btrim(p_names->>p_kind), '') end,
                  case p_kind when 'child-seat' then 'Child safety seat'
                              when 'more-passengers' then 'More than 4 passengers'
                              when 'pet' then 'Pet with me'
                              when 'assistance' then 'Assistance required'
                              else p_kind end);
$$;

-- ---- 4. A booking with an option not offered there is refused -----------------------------------
-- App bookings only (the session's role, as 0247); a stand's order and a
-- scheduled booking's release (checked when it was booked) are not.
create or replace function public.ride_requests_option_places()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_kinds text[];
  v_refused text;
begin
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated')
     or public.caller_admin_can_write('ride_requests')
     or new.stand_id is not null or new.scheduled_ride_id is not null then
    return new;
  end if;
  v_kinds := public.ride_option_kinds(new.pets, new.assistance, new.option_names, new.passengers);
  if cardinality(v_kinds) = 0 then
    return new;
  end if;
  select public.ride_option_refused(v_kinds,
           public.ride_option_settings_at(p.country, p.state, p.city, p.suburb), new.service)
    into v_refused
    from public.ride_option_place(new.pickup_lat, new.pickup_lng, new.country, new.state, new.city) p;
  if v_refused is not null then
    raise exception 'RIDE_OPTION_NOT_OFFERED' using errcode = '22023',
      hint = public.ride_option_name(v_refused, new.option_names) || ' isn''t offered here for '
             || coalesce(nullif(btrim(new.service), ''), 'this service') || '. Turn it off and book again.';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_option_places() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_b_option_places on public.ride_requests;
create trigger trg_ride_requests_b_option_places
  before insert on public.ride_requests
  for each row execute function public.ride_requests_option_places();

create or replace function public.scheduled_rides_option_places()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  q jsonb := coalesce(new.request, '{}'::jsonb);
  v_kinds text[];
  v_refused text;
begin
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated')
     or public.caller_admin_can_write('scheduled_rides')
     or new.stand_id is not null then
    return new;
  end if;
  v_kinds := public.ride_option_kinds(q->'pets', q->'assistance', q->'option_names',
                                      case when jsonb_typeof(q->'passengers') = 'number'
                                           then floor((q->>'passengers')::numeric)::integer end);
  if cardinality(v_kinds) = 0 then
    return new;
  end if;
  select public.ride_option_refused(v_kinds,
           public.ride_option_settings_at(p.country, p.state, p.city, p.suburb), new.service)
    into v_refused
    from public.ride_option_place(new.pickup_lat, new.pickup_lng, q->>'country', q->>'state', q->>'city') p;
  if v_refused is not null then
    raise exception 'RIDE_OPTION_NOT_OFFERED' using errcode = '22023',
      hint = public.ride_option_name(v_refused, q->'option_names') || ' isn''t offered here for '
             || coalesce(nullif(btrim(new.service), ''), 'this service') || '. Turn it off and book again.';
  end if;
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_option_places() from public, anon, authenticated;

drop trigger if exists trg_scheduled_rides_option_places on public.scheduled_rides;
create trigger trg_scheduled_rides_option_places
  before insert on public.scheduled_rides
  for each row execute function public.scheduled_rides_option_places();

-- ---- 5. The extras each driver takes --------------------------------------------------------------

-- The extras a request carries, as the keys a driver turns off: each pet
-- type, each kind of help (never the guide dog), a child seat, more
-- passengers. Lower case.
create or replace function public.ride_extra_keys(p_pets jsonb, p_assistance jsonb, p_names jsonb,
                                                  p_passengers integer)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(distinct k order by k), '{}') from (
    select 'child-seat' as k where jsonb_typeof(p_names) = 'object' and p_names ? 'child-seat'
    union all
    select 'more-passengers'
     where (jsonb_typeof(p_names) = 'object' and p_names ? 'more-passengers') or coalesce(p_passengers, 0) > 4
    union all
    select 'pet:' || lower(btrim(e->>'type'))
      from jsonb_array_elements(case when jsonb_typeof(p_pets) = 'array' then p_pets else '[]'::jsonb end) e
     where jsonb_typeof(e) = 'object' and jsonb_typeof(e->'type') = 'string' and btrim(e->>'type') <> ''
    union all
    select 'assist:' || lower(btrim(coalesce(nullif(btrim(e->>'id'), ''), e->>'name')))
      from jsonb_array_elements(case when jsonb_typeof(p_assistance) = 'object'
                                          and jsonb_typeof(p_assistance->'items') = 'array'
                                     then p_assistance->'items' else '[]'::jsonb end) e
     where jsonb_typeof(e) = 'object'
       and coalesce(nullif(btrim(e->>'id'), ''), btrim(e->>'name'), '') <> ''
       and coalesce(e->>'id', '') <> 'guide-dog'
  ) x;
$$;

-- At most 200 keys of 1 to 120 characters.
create or replace function public.ride_extra_keys_valid(p text[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p is not null and cardinality(p) <= 200
     and not exists (select 1 from unnest(p) k where k is null or char_length(k) not between 1 and 120);
$$;

create table if not exists public.driver_ride_extras (
  driver_id  uuid primary key references public.profiles(id) on delete cascade,
  off        text[] not null default '{}',
  updated_at timestamptz not null default now(),
  constraint driver_ride_extras_off_valid check (public.ride_extra_keys_valid(off))
);
comment on table public.driver_ride_extras is
  'The ride extras each driver turned off (0253): requests carrying one are not offered to them.';

-- Kept trimmed, lower case and without repeats; the guide dog is never one.
create or replace function public.driver_ride_extras_normalise()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.off := coalesce((select array_agg(distinct k order by k)
                         from (select lower(btrim(x)) k from unnest(coalesce(new.off, '{}')) x) y
                        where k <> '' and k <> 'assist:guide-dog'), '{}');
  new.updated_at := now();
  return new;
end;
$$;
revoke execute on function public.driver_ride_extras_normalise() from public, anon, authenticated;

drop trigger if exists trg_driver_ride_extras_normalise on public.driver_ride_extras;
create trigger trg_driver_ride_extras_normalise before insert or update on public.driver_ride_extras
  for each row execute function public.driver_ride_extras_normalise();

alter table public.driver_ride_extras enable row level security;
revoke all on public.driver_ride_extras from anon;
grant select, insert, update, delete on public.driver_ride_extras to authenticated;

drop policy if exists "driver_ride_extras read" on public.driver_ride_extras;
drop policy if exists "driver_ride_extras own insert" on public.driver_ride_extras;
drop policy if exists "driver_ride_extras own update" on public.driver_ride_extras;
drop policy if exists "driver_ride_extras own delete" on public.driver_ride_extras;
create policy "driver_ride_extras read" on public.driver_ride_extras for select to authenticated
  using (driver_id = (select auth.uid()) or (select public.caller_is_admin()));
create policy "driver_ride_extras own insert" on public.driver_ride_extras for insert to authenticated
  with check (driver_id = (select auth.uid()));
create policy "driver_ride_extras own update" on public.driver_ride_extras for update to authenticated
  using (driver_id = (select auth.uid())) with check (driver_id = (select auth.uid()));
create policy "driver_ride_extras own delete" on public.driver_ride_extras for delete to authenticated
  using (driver_id = (select auth.uid()));

-- What a driver turned off; none without a row.
create or replace function public.driver_extras_off(p_driver uuid)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select x.off from public.driver_ride_extras x where x.driver_id = p_driver), '{}');
$$;

create or replace function public.caller_extras_off()
returns text[]
language sql
stable
security definer
set search_path = public
as $$ select public.driver_extras_off(auth.uid()); $$;

-- Whether [p_driver] takes a request carrying [p_keys].
create or replace function public.driver_takes_extras(p_driver uuid, p_keys text[])
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(cardinality(p_keys), 0) = 0 or not (public.driver_extras_off(p_driver) && p_keys);
$$;

revoke execute on function public.driver_extras_off(uuid) from public, anon, authenticated;
revoke execute on function public.caller_extras_off() from public, anon;
revoke execute on function public.driver_takes_extras(uuid, text[]) from public, anon, authenticated;
grant execute on function public.caller_extras_off() to authenticated, service_role;
grant execute on function public.driver_extras_off(uuid), public.driver_takes_extras(uuid, text[]) to service_role;

-- ---- 6. Who reads an open request ---------------------------------------------------------------
-- Restrictive, on top of "ride_requests read" (and 0249's airport hold, 0250's
-- service order): not the drivers who turned off one of its extras, unless
-- it was booked or assigned to them.
drop policy if exists "ride_requests driver extras" on public.ride_requests;
create policy "ride_requests driver extras" on public.ride_requests as restrictive for select to authenticated
  using (status <> 'open'
         or cardinality((select public.caller_extras_off())) = 0
         or rider_id = (select auth.uid()) or partner_id = (select auth.uid())
         or direct_driver_id = (select auth.uid()) or dispatch_driver_id = (select auth.uid())
         or (select public.caller_is_admin())
         or (stand_id is not null and array[stand_id] <@ (select public.dispatch_caller_stand_ids()))
         or not ((select public.caller_extras_off())
                 && public.ride_extra_keys(pets, assistance, option_names, passengers)));

-- ---- 7. My Ride's favourites who turned an extra off are left out --------------------------------
-- After My Ride and GET.now have named the targets (c_my_ride), before the
-- service order (c_service_order).
create or replace function public.ride_requests_driver_extras()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_keys text[];
  v_keep uuid[];
begin
  if new.direct_driver_id is not null or coalesce(cardinality(new.target_driver_ids), 0) = 0 then
    return new;
  end if;
  v_keys := public.ride_extra_keys(new.pets, new.assistance, new.option_names, new.passengers);
  if cardinality(v_keys) = 0 then
    return new;
  end if;
  select coalesce(array_agg(d), '{}') into v_keep
    from unnest(new.target_driver_ids) d
   where public.driver_takes_extras(d, v_keys);
  if cardinality(v_keep) = 0 then
    new.target_driver_ids := null;
    new.targeted_until := null;
  else
    new.target_driver_ids := v_keep;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_driver_extras() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_c_ride_extras on public.ride_requests;
create trigger trg_ride_requests_c_ride_extras
  before insert on public.ride_requests
  for each row execute function public.ride_requests_driver_extras();

-- ---- 8. Who is pushed ------------------------------------------------------------------------------
-- As 0250, without the drivers who turned off one of the ride's extras.
create or replace function public.ride_request_push_nearby(
  p_request uuid,
  p_rider uuid,
  p_lat double precision,
  p_lng double precision,
  p_radius_km double precision,
  p_message jsonb,
  p_kind text,
  p_once boolean
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver uuid;
  v_told int := 0;
  n int;
  v_service text;
  v_keys text[];
  v_enforced boolean := public.service_order_enforced();
begin
  select r.service, public.ride_extra_keys(r.pets, r.assistance, r.option_names, r.passengers)
    into v_service, v_keys
    from public.ride_requests r where r.id = p_request;
  for v_driver in select * from public.nearby_online_drivers(p_lat, p_lng, p_radius_km) loop
    continue when v_driver = p_rider;
    continue when v_enforced
               and not public.service_order_allows(public.driver_vehicle_service(v_driver), v_service);
    continue when not public.driver_takes_extras(v_driver, v_keys);
    insert into public.ride_request_pushes (request_id, profile_id, kind)
    values (p_request, v_driver, p_kind)
    on conflict (request_id, profile_id) where profile_id is not null do nothing;
    get diagnostics n = row_count;
    continue when p_once and n = 0;
    perform public.send_push_webhook(p_message || jsonb_build_object('profileId', v_driver));
    v_told := v_told + 1;
  end loop;
  return v_told;
end;
$$;
revoke execute on function public.ride_request_push_nearby(uuid, uuid, double precision, double precision, double precision, jsonb, text, boolean)
  from public, anon, authenticated;

-- As 0165, the everyone push leaving out the drivers who turned off one of
-- the ride's extras.
create or replace function public.ride_request_push_everyone(p_request uuid, p_message jsonb, p_kind text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rider uuid;
  v_keys text[];
  v_skip jsonb;
begin
  select r.rider_id, public.ride_extra_keys(r.pets, r.assistance, r.option_names, r.passengers)
    into v_rider, v_keys
    from public.ride_requests r where r.id = p_request;
  select coalesce(jsonb_agg(x.driver_id), '[]'::jsonb) into v_skip
    from public.driver_ride_extras x
   where cardinality(v_keys) > 0 and x.off && v_keys;
  insert into public.ride_request_pushes (request_id, profile_id, kind) values (p_request, null, p_kind);
  perform public.send_push_webhook(p_message || jsonb_build_object(
    'audience', 'partners',
    'approvedOnly', true,
    'excludeProfileIds', case when v_rider is null then '[]'::jsonb else jsonb_build_array(v_rider) end || v_skip
  ));
end;
$$;
revoke execute on function public.ride_request_push_everyone(uuid, jsonb, text) from public, anon, authenticated;
grant execute on function public.ride_request_push_everyone(uuid, jsonb, text) to service_role;

-- ---- 9. Airport queue and waiting-zone offers -------------------------------------------------------
-- As 0249, skipping the drivers who turned off one of the ride's extras.
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
  v_keys text[];
  n int;
begin
  perform set_config('getride.airport_server', 'on', true);
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.status <> 'open' or not r.airport_hold then
    return 'none';
  end if;
  v_keys := public.ride_extra_keys(r.pets, r.assistance, r.option_names, r.passengers);
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
       and public.driver_takes_extras(l.driver_id, v_keys)
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
         and public.driver_takes_extras(z.driver_id, v_keys)
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

-- ---- 10. A stand group's broadcast ---------------------------------------------------------------
-- As 0251, the group's members without those who turned off one of the
-- order's extras (an assigned driver is still told).
create or replace function public.dispatch_push(p_request uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_msg jsonb;
  v_driver uuid;
  v_keys text[];
  n int := 0;
begin
  select * into r from public.ride_requests where id = p_request;
  if not found or r.stand_id is null or r.status <> 'open' or r.dispatch_mode = 'nearby' then
    return 0;  -- a normal booking's pushes (notify_partners_on_ride_request) reach it
  end if;
  begin
    if r.dispatch_mode = 'assign' then
      if r.dispatch_returned_at is null and r.dispatch_offer_until > now() then
        perform public.send_push_webhook(public.dispatch_push_message(r, true)
                                         || jsonb_build_object('profileId', r.dispatch_driver_id));
        n := 1;
      end if;
      return n;
    end if;
    v_msg := public.dispatch_push_message(r, false);
    if r.dispatch_widened_at is not null or (r.dispatch_open_after is not null and r.dispatch_open_after <= now()) then
      return public.ride_request_push_nearby(r.id, null, r.pickup_lat, r.pickup_lng,
        (public.vehicle_service_dispatch_config(r.service)->>'search_radius_max_km')::double precision,
        v_msg, 'nearby', true);
    end if;
    v_keys := public.ride_extra_keys(r.pets, r.assistance, r.option_names, r.passengers);
    for v_driver in
      select d.profile_id from public.driver_presence d
       where d.online and d.updated_at > now() - interval '3 minutes'
         and public.dispatch_member_of(r.dispatch_group_id, d.profile_id)
         and not public.dispatch_driver_busy(d.profile_id)
         and public.service_order_driver_allows(d.profile_id, r.service)
         and public.driver_takes_extras(d.profile_id, v_keys)
    loop
      insert into public.ride_request_pushes (request_id, profile_id, kind)
      values (r.id, v_driver, 'nearby')
      on conflict (request_id, profile_id) where profile_id is not null do nothing;
      perform public.send_push_webhook(v_msg || jsonb_build_object('profileId', v_driver));
      n := n + 1;
    end loop;
  exception when others then
    raise warning 'stand order % not pushed: %', p_request, sqlerrm;
  end;
  return n;
end;
$$;
revoke execute on function public.dispatch_push(uuid) from public, anon, authenticated;

-- ---- 11. Scheduled rides -------------------------------------------------------------------------
-- As 0251, the open list without the bookings carrying an extra the caller
-- turned off.
create or replace function public.scheduled_rides_open()
returns table(id uuid, pickup_at timestamptz, service text, pickup_address text, drop_address text,
              pickup_lat double precision, pickup_lng double precision, drop_lat double precision,
              drop_lng double precision, distance_km numeric, fare numeric, scheduling_fee numeric, currency text)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.pickup_at, s.service, s.pickup_address, s.drop_address,
         s.pickup_lat, s.pickup_lng, s.drop_lat, s.drop_lng, s.distance_km, s.fare,
         case when public.scheduled_rides_config()->>'feeTo' = 'driver' then s.scheduling_fee else 0 end,
         s.currency
    from public.scheduled_rides s
   where s.status = 'scheduled' and s.partner_id is null and s.pickup_at > now()
     and s.stand_id is null
     and public.caller_is_approved_partner()
     and public.scheduled_rides_config()->>'mode' = 'advance'
     and s.rider_id <> auth.uid()
     and public.service_order_driver_allows(auth.uid(), s.service)
     and public.driver_takes_extras(auth.uid(), public.ride_extra_keys(
           s.request->'pets', s.request->'assistance', s.request->'option_names',
           case when jsonb_typeof(s.request->'passengers') = 'number'
                then floor((s.request->>'passengers')::numeric)::integer end))
   order by s.pickup_at
   limit 100;
$$;
revoke execute on function public.scheduled_rides_open() from public, anon;
grant execute on function public.scheduled_rides_open() to authenticated;

-- ---- 12. The feed's "not shown" line -------------------------------------------------------------
-- How many open requests since [p_since] (at most a day back) the caller
-- would otherwise see in the feed but does not, for an extra they turned off.
create or replace function public.ride_extras_hidden_count(p_since timestamptz)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_off text[] := public.caller_extras_off();
begin
  if auth.uid() is null or cardinality(v_off) = 0 or not public.caller_is_approved_partner() then
    return 0;
  end if;
  return (
    select count(*)::integer from public.ride_requests r
     where r.status = 'open'
       and r.created_at >= greatest(coalesce(p_since, now()), now() - interval '1 day')
       and r.rider_id is distinct from auth.uid()
       and r.stand_id is null and not coalesce(r.airport_hold, false) and r.direct_driver_id is null
       and (r.targeted_until is null or r.targeted_until <= now()
            or coalesce(cardinality(r.target_driver_ids), 0) = 0)
       and public.service_order_driver_allows(auth.uid(), r.service)
       and v_off && public.ride_extra_keys(r.pets, r.assistance, r.option_names, r.passengers));
end;
$$;
revoke execute on function public.ride_extras_hidden_count(timestamptz) from public, anon;
grant execute on function public.ride_extras_hidden_count(timestamptz) to authenticated;

-- ---- 13. Live ----------------------------------------------------------------------------------
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['ride_option_places', 'driver_ride_extras'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
