-- ============================================================================
-- 0316 — Premium service rules and GET.Plus, the rider membership
-- (docs/KIV.md "Premium tier").
--
-- Version 20261028090000 (0316_premium_getplus). Re-runnable: tables,
-- columns and indexes "if not exists", functions "create or replace",
-- policies and triggers dropped first, the seed row "on conflict do
-- nothing", and the three functions edited in place (item 9) only when
-- they don't carry the edit yet.
--
-- 1. Premium is a flag, not a name: any Vehicle Service whose values say
--    premium: true (Admin › Vehicle Services › Premium, camelCase as 0267's
--    closedBody). vehicle_service_is_premium(service), premium_service_keys().
-- 2. premium_plus_places: the rules by place, Default or a country, state,
--    city or suburb (keyed as 0253's ride_option_places and 0269's
--    ride_cancel_places: the smallest place that sets a key wins, a region
--    rule only overrides what it sets). Keys (all optional on a region):
--      premiumOn          the Premium rules apply here (off: any driver whose
--                         Services take the service; Regions › service
--                         switches (0302) say whether Premium is offered)
--      premiumMaxCarAge   car at most N years old (0: no limit; 1–40)
--      premiumModels      allowed cars: ["Toyota Camry", "Mercedes-Benz"]
--                         (a make alone allows every model; [] any car)
--      premiumMinRating   driver rating at least X (0–5; 0 no minimum)
--      premiumMinTrips    driver trips at least Y (0–100000)
--      plusOn             GET.Plus is sold and its benefits apply here
--      plusPrice          RM a month (0–1000)
--      plusDiscountPct    off a member's ride fare (0–90)
--      plusMaxDiscount    RM most off one ride (0: no cap)
--      plusFreeCancels    free cancels a month (0–50)
--      plusPriority       members' requests first in drivers' lists
--      plusGraceDays      days a member keeps GET.Plus after a renewal the
--                         wallet couldn't pay (0–30; 0 ends it at once)
--    Seeded Default: Premium on, 5 years, 4.8, 200 trips, any model; GET.Plus
--    OFF (RM 19.90, 10 %, no cap, 2 cancels, priority on, 3 grace days) so
--    nothing is sold until the owner turns it on. Admin › Services &
--    catalogue › Premium and GET.Plus (page admin-settings-premium-plus),
--    its own page and keys so it merges beside 0314's City ride extras.
-- 3. Who may take a Premium request: premium_driver_check(driver, service,
--    place) — the car they drive (vehicle_active_session, else their latest
--    approved car): its age (registration date, else 1 January of its
--    year, whole years, as 0301), make and model on the list; the driver's
--    partners.rating and total_rides. The reasons are plain sentences the
--    driver app shows.
--    Enforced (app sessions only; the server, admins and stands pass):
--      * an offer (ride_offers insert, so ride_offer_make and an older
--        app's bid on the row) and a take of an open request
--        (ride_requests.partner_id set to the caller): PREMIUM_NOT_ELIGIBLE
--        (42501) with the reasons as the hint;
--      * a scheduled ride's accept (scheduled_rides.partner_id set to the
--        caller): the same;
--      * who reads an open request: a restrictive policy hides an open
--        Premium request from drivers who don't qualify at its pickup (the
--        rider, the driver on it, a direct booking's driver, admins and
--        stands still read it).
--    my_premium_status(lat, lng): each Premium service with ok and the
--    reasons, for the driver's Services page.
-- 4. GET.Plus: plus_memberships (one row a rider: active, grace, ended,
--    expired; auto_renew; the period; the place it was bought at and its
--    price; free cancels used this period) and plus_charges (receipts: join,
--    renewal; paid, failed). Riders read their own; admins with the page.
--    * plus_join(lat, lng, names, expected price): paid at once from
--      GET.wallet (kind plus_fee), a month from now. A member who cancelled
--      and is still in the month is resumed without a charge.
--    * plus_set_auto_renew(on): cancel (off: it runs to the period's end,
--      then ends) or resume.
--    * plus_renew_due(), every hour by pg_cron (job plus-renew-due, only
--      where pg_cron is installed): a period that ended renews at the price
--      at the member's place now; a wallet that is short moves the member
--      to grace (benefits kept) until period end + grace days, retried each
--      hour, then expired. Not auto-renewing, or GET.Plus turned off at
--      their place: ended. Each paid or failed attempt is a receipt row;
--      the member is told (notification outbox) when it renews or fails.
-- 5. The discount: a request's rider who is a member, with GET.Plus on at
--    the pickup, is stamped plus_pct, plus_max_discount and plus_priority
--    at insert (the server's: an app can't set or change them). The fare
--    on the request is the driver's as before: drivers offer and are paid
--    on the full fare, and commission is charged on it as before. When the
--    trip completes (after a promo settles) the discount is worked out on
--    the final fare (pct, the cap, never more than is left to pay), the
--    ride gets plus_discount, ride_left_to_pay takes it off what the rider
--    pays (GET.wallet, GET.coin or cash), and the driver's GET.wallet is
--    credited the same amount (kind plus_credit, once per ride). So the
--    driver still has the full fare and the platform funds the discount out
--    of its commission (revenue: fees + commission − discounts), the way
--    promo codes are funded (0242).
-- 6. Free cancels: a member's city ride cancel that would cost a late or
--    arrived fee (0269) is free while free cancels are left this period;
--    the driver is credited what the fee would have paid them (less the
--    ride's commission rate, kind plus_cancel_credit), and the ride keeps
--    plus_waived_fee. ride_cancel_terms says so (the fees 0, and
--    plusFreeCancelsLeft), so the app shows "Free to cancel". No-shows,
--    scheduled-ride and freight fees are not covered.
-- 7. Priority matching, kept simple: plus_priority on the request; the
--    driver app lists those first (after direct and starred requests) and
--    marks them GET.Plus. Pushes are unchanged.
-- 8. Admin: admin_plus_members(status, search, limit, offset) and
--    admin_plus_revenue(days): members, fees, discounts and waived fees
--    funded, commission on members' rides. Admins with a grant on the page
--    (or the Settings hub, or all pages).
-- 9. Edited in place from their current definitions (as 0223 and 0237 do),
--    so other batches' changes to them are kept: ride_left_to_pay (less
--    plus_discount), ride_requests_city_cancel_fee (plus_cancel_waive) and
--    ride_cancel_terms (plus_cancel_terms). A definition without the line
--    the edit hangs on stops the migration, rather than skip the edit.
-- ============================================================================

-- ---- 1. Premium is a flag on a Vehicle Service ----------------------------------------------------
create or replace function public.vehicle_service_is_premium(p_service text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select e.values->'premium' = 'true'::jsonb from public.settings_entries e
                    where e.id::text = coalesce(public.vehicle_service_id_of(p_service), lower(btrim(coalesce(p_service, ''))))
                      and e.category = 'vehicle-services'), false);
$$;
revoke execute on function public.vehicle_service_is_premium(text) from public, anon;
grant execute on function public.vehicle_service_is_premium(text) to authenticated, service_role;

-- The Premium services' names, lowercased and trimmed (for the read rule).
create or replace function public.premium_service_keys()
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(distinct lower(btrim(e.values->>'name'))), '{}')
    from public.settings_entries e
   where e.category = 'vehicle-services' and e.values->'premium' = 'true'::jsonb
     and btrim(coalesce(e.values->>'name', '')) <> '';
$$;
revoke execute on function public.premium_service_keys() from public, anon;
grant execute on function public.premium_service_keys() to authenticated, service_role;

-- ---- 2. The rules by place -------------------------------------------------------------------------
create or replace function public.premium_plus_rules_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(p) = 'object'
     and not exists (
       select 1 from jsonb_each(p) e
        where case
          when e.key in ('premiumOn', 'plusOn', 'plusPriority') then jsonb_typeof(e.value) <> 'boolean'
          when e.key = 'premiumModels' then
            jsonb_typeof(e.value) <> 'array' or jsonb_array_length(e.value) > 200
            or exists (select 1 from jsonb_array_elements(e.value) m
                        where jsonb_typeof(m) <> 'string' or char_length(btrim(m #>> '{}')) not between 1 and 80)
          when e.key in ('premiumMaxCarAge', 'premiumMinRating', 'premiumMinTrips', 'plusPrice', 'plusDiscountPct',
                         'plusMaxDiscount', 'plusFreeCancels', 'plusGraceDays') then
            jsonb_typeof(e.value) <> 'number'
            or (e.value #>> '{}')::numeric < 0
            or (e.value #>> '{}')::numeric > case e.key
                 when 'premiumMaxCarAge' then 40 when 'premiumMinRating' then 5 when 'premiumMinTrips' then 100000
                 when 'plusDiscountPct' then 90 when 'plusFreeCancels' then 50 when 'plusGraceDays' then 30
                 else 1000 end
            or (e.key in ('premiumMaxCarAge', 'premiumMinTrips', 'plusFreeCancels', 'plusGraceDays')
                and (e.value #>> '{}')::numeric <> trunc((e.value #>> '{}')::numeric))
          else true
        end);
$$;

create table if not exists public.premium_plus_places (
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
  constraint premium_plus_places_names check (
    (level = 'default' and country is null and state is null and city is null and suburb is null)
    or (level = 'country' and country is not null and state is null and city is null and suburb is null)
    or (level = 'state' and country is not null and state is not null and city is null and suburb is null)
    or (level = 'city' and country is not null and state is not null and city is not null and suburb is null)
    or (level = 'suburb' and country is not null and state is not null and city is not null and suburb is not null)),
  constraint premium_plus_places_valid check (public.premium_plus_rules_valid(rules))
);
create unique index if not exists premium_plus_places_key_uidx on public.premium_plus_places (place_key);
comment on table public.premium_plus_places is
  'Premium service rules and GET.Plus by place (0316), keyed as ride_option_places: the smallest place that sets a key wins.';

drop trigger if exists trg_premium_plus_places_updated_at on public.premium_plus_places;
create trigger trg_premium_plus_places_updated_at before update on public.premium_plus_places
  for each row execute function public.set_updated_at();

alter table public.premium_plus_places enable row level security;
revoke all on public.premium_plus_places from anon;
grant select, insert, update, delete on public.premium_plus_places to authenticated;
drop policy if exists "premium_plus_places read" on public.premium_plus_places;
drop policy if exists "premium_plus_places admin insert" on public.premium_plus_places;
drop policy if exists "premium_plus_places admin update" on public.premium_plus_places;
drop policy if exists "premium_plus_places admin delete" on public.premium_plus_places;
create policy "premium_plus_places read" on public.premium_plus_places for select to authenticated using (true);
create policy "premium_plus_places admin insert" on public.premium_plus_places for insert to authenticated
  with check ((select public.caller_admin_can_write('premium_plus_places')));
create policy "premium_plus_places admin update" on public.premium_plus_places for update to authenticated
  using ((select public.caller_admin_can_write('premium_plus_places')))
  with check ((select public.caller_admin_can_write('premium_plus_places')));
create policy "premium_plus_places admin delete" on public.premium_plus_places for delete to authenticated
  using ((select public.caller_admin_can_write('premium_plus_places')) and level <> 'default');

insert into public.admin_table_pages (target, page) values
  ('premium_plus_places', 'admin-settings-premium-plus')
on conflict do nothing;

insert into public.premium_plus_places (level, rules)
values ('default', jsonb_build_object(
  'premiumOn', true, 'premiumMaxCarAge', 5, 'premiumModels', '[]'::jsonb, 'premiumMinRating', 4.8,
  'premiumMinTrips', 200, 'plusOn', false, 'plusPrice', 19.9, 'plusDiscountPct', 10, 'plusMaxDiscount', 0,
  'plusFreeCancels', 2, 'plusPriority', true, 'plusGraceDays', 3))
on conflict (place_key) do nothing;

-- The rules at a place: each key from the smallest place that sets it, over
-- the built-in defaults (lib/src/core/premium_plus.dart: premiumPlusRulesAt).
create or replace function public.premium_plus_rules_at(p_country text, p_state text, p_city text, p_suburb text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v jsonb := jsonb_build_object(
    'premiumOn', true, 'premiumMaxCarAge', 5, 'premiumModels', '[]'::jsonb, 'premiumMinRating', 4.8,
    'premiumMinTrips', 200, 'plusOn', false, 'plusPrice', 19.9, 'plusDiscountPct', 10, 'plusMaxDiscount', 0,
    'plusFreeCancels', 2, 'plusPriority', true, 'plusGraceDays', 3);
  k text[] := array[''];
  c text := lower(btrim(coalesce(p_country, '')));
  s text := lower(btrim(coalesce(p_state, '')));
  t text := lower(btrim(coalesce(p_city, '')));
  b text := lower(btrim(coalesce(p_suburb, '')));
  r public.premium_plus_places;
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
    select p.* from public.premium_plus_places p
     where p.place_key = any (k)
     order by case p.level when 'default' then 0 when 'country' then 1 when 'state' then 2
                           when 'city' then 3 else 4 end
  loop
    v := v || r.rules;
  end loop;
  return v;
end;
$$;
revoke execute on function public.premium_plus_rules_at(text, text, text, text) from public, anon, authenticated;
grant execute on function public.premium_plus_rules_at(text, text, text, text) to service_role;

-- ---- 3. Who may take a Premium request --------------------------------------------------------------
-- Names compared without case or extra spaces ("mercedes  benz" is "Mercedes Benz").
create or replace function public.premium_name_key(p text)
returns text
language sql
immutable
set search_path = ''
as $$ select lower(regexp_replace(btrim(coalesce(p, '')), '[\s\-]+', ' ', 'g')); $$;

-- Whether a car of [p_make] [p_model] is on [p_list] (a make alone allows
-- its every model). An empty list allows every car. premiumModelAllowed in the app.
create or replace function public.premium_model_allowed(p_list jsonb, p_make text, p_model text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(p_list) is distinct from 'array' or jsonb_array_length(p_list) = 0
      or exists (
        select 1 from jsonb_array_elements_text(p_list) x
         where public.premium_name_key(x) <> ''
           and (public.premium_name_key(x) = public.premium_name_key(p_make)
                or public.premium_name_key(x) = public.premium_name_key(coalesce(p_make, '') || ' ' || coalesce(p_model, ''))));
$$;

-- {premium, ok, rulesOn, reasons[], carAge, rating, trips, rules{...}} for
-- [p_driver] on [p_service] at the place named. Not a Premium service, or the
-- rules off there: ok.
create or replace function public.premium_driver_check(p_driver uuid, p_service text, p_country text,
                                                       p_state text, p_city text, p_suburb text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_rules jsonb;
  v_vehicle uuid;
  v public.vehicle;
  v_reg date;
  v_age integer;
  v_rating numeric;
  v_trips integer;
  v_max integer;
  v_min_rating numeric;
  v_min_trips integer;
  v_car text;
  reasons text[] := '{}';
begin
  if not public.vehicle_service_is_premium(p_service) then
    return jsonb_build_object('premium', false, 'ok', true, 'reasons', '[]'::jsonb);
  end if;
  v_rules := public.premium_plus_rules_at(p_country, p_state, p_city, p_suburb);
  if not coalesce((v_rules->>'premiumOn')::boolean, true) then
    return jsonb_build_object('premium', true, 'ok', true, 'rulesOn', false, 'reasons', '[]'::jsonb);
  end if;
  v_max := coalesce((v_rules->>'premiumMaxCarAge')::numeric, 0)::int;
  v_min_rating := coalesce((v_rules->>'premiumMinRating')::numeric, 0);
  v_min_trips := coalesce((v_rules->>'premiumMinTrips')::numeric, 0)::int;

  v_vehicle := coalesce(public.driver_session_vehicle(p_driver),
                        (select x.id from public.vehicle x
                          where x.auth_user_id = p_driver and x.status::text = 'approved'
                          order by x.updated_at desc nulls last limit 1));
  if v_vehicle is not null then
    select * into v from public.vehicle where id = v_vehicle;
    v_reg := coalesce(v.registration_date,
                      make_date(nullif(substring(coalesce(v.year, '') from '(\d{4})'), '')::int, 1, 1));
    v_age := case when v_reg is null then null
                  else greatest(extract(year from age(current_date, v_reg))::int, 0) end;
    v_car := nullif(btrim(concat_ws(' ', btrim(v.make), btrim(v.model))), '');
  end if;
  select p.rating, p.total_rides into v_rating, v_trips
    from public.partners p where p.auth_user_id = p_driver
   order by p.created_at desc limit 1;
  v_rating := coalesce(v_rating, 0);
  v_trips := coalesce(v_trips, 0);

  if v_vehicle is null and (v_max > 0 or jsonb_array_length(coalesce(v_rules->'premiumModels', '[]'::jsonb)) > 0) then
    reasons := reasons || 'Choose the car you''re driving first.'::text;
  else
    if v_max > 0 and v_age is null then
      reasons := reasons || 'Your car''s year isn''t on record. Ask support to add it.'::text;
    elsif v_max > 0 and v_age > v_max then
      reasons := reasons || format('Your car is %s years old. Premium takes cars %s years old or newer.', v_age, v_max);
    end if;
    if not public.premium_model_allowed(v_rules->'premiumModels', v.make, v.model) then
      reasons := reasons || format('Premium takes listed car models only, and your %s isn''t on the list.',
                                   coalesce(v_car, 'car'));
    end if;
  end if;
  if v_min_rating > 0 and v_rating < v_min_rating then
    reasons := reasons || format('Your rating is %s. Premium needs %s or more.',
                                 trim_scale(round(v_rating, 2))::text, trim_scale(round(v_min_rating, 2))::text);
  end if;
  if v_min_trips > 0 and v_trips < v_min_trips then
    reasons := reasons || format('You have %s trips. Premium needs %s or more.', v_trips, v_min_trips);
  end if;
  return jsonb_build_object(
    'premium', true, 'ok', cardinality(reasons) = 0, 'rulesOn', true, 'reasons', to_jsonb(reasons),
    'carAge', v_age, 'car', v_car, 'rating', v_rating, 'trips', v_trips,
    'rules', jsonb_build_object('maxCarAge', v_max, 'models', coalesce(v_rules->'premiumModels', '[]'::jsonb),
                                'minRating', v_min_rating, 'minTrips', v_min_trips));
end;
$$;
revoke execute on function public.premium_driver_check(uuid, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.premium_driver_check(uuid, text, text, text, text, text) to service_role;

-- The same at a pickup point (the place as the server reads a booking's).
create or replace function public.premium_check_at(p_driver uuid, p_service text, p_lat double precision,
                                                   p_lng double precision, p_country text, p_state text,
                                                   p_city text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  p record;
begin
  if not public.vehicle_service_is_premium(p_service) then
    return jsonb_build_object('premium', false, 'ok', true, 'reasons', '[]'::jsonb);
  end if;
  select * into p from public.ride_option_place(p_lat, p_lng, p_country, p_state, p_city);
  return public.premium_driver_check(p_driver, p_service, p.country, p.state, p.city, p.suburb);
end;
$$;
revoke execute on function public.premium_check_at(uuid, text, double precision, double precision, text, text, text)
  from public, anon, authenticated;

-- The refusal's words: "You can't take Premium requests yet. <reasons>"
create or replace function public.premium_refusal(p_check jsonb)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if coalesce((p_check->>'ok')::boolean, true) then
    return;
  end if;
  raise exception 'PREMIUM_NOT_ELIGIBLE' using errcode = '42501',
    hint = 'You can''t take Premium requests yet. '
           || coalesce((select string_agg(x, ' ') from jsonb_array_elements_text(p_check->'reasons') x), '');
end;
$$;

-- For the read rule: whether the caller qualifies for [p_service] at the pickup.
create or replace function public.premium_caller_sees(p_service text, p_lat double precision, p_lng double precision,
                                                      p_country text, p_state text, p_city text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and coalesce((public.premium_check_at(auth.uid(), p_service, p_lat, p_lng, p_country, p_state, p_city)->>'ok')::boolean,
                  true);
$$;
revoke execute on function public.premium_caller_sees(text, double precision, double precision, text, text, text)
  from public, anon;
grant execute on function public.premium_caller_sees(text, double precision, double precision, text, text, text)
  to authenticated;

-- An offer from the app (ride_offer_make, or an older app's bid on the row).
create or replace function public.ride_offers_premium()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
begin
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated') then
    return new;
  end if;
  select * into r from public.ride_requests where id = new.request_id;
  if not found or r.stand_id is not null then
    return new;
  end if;
  perform public.premium_refusal(public.premium_check_at(new.partner_id, r.service, r.pickup_lat, r.pickup_lng,
                                                         r.country, r.state, r.city));
  return new;
end;
$$;
revoke execute on function public.ride_offers_premium() from public, anon, authenticated;
drop trigger if exists trg_ride_offers_premium on public.ride_offers;
create trigger trg_ride_offers_premium
  before insert on public.ride_offers
  for each row execute function public.ride_offers_premium();

-- A driver's own take or bid written on the request.
create or replace function public.ride_requests_premium_take()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated')
     or old.status <> 'open' or new.partner_id is null or new.partner_id is not distinct from old.partner_id
     or new.partner_id is distinct from auth.uid() or old.stand_id is not null then
    return new;
  end if;
  perform public.premium_refusal(public.premium_check_at(new.partner_id, old.service, old.pickup_lat, old.pickup_lng,
                                                         old.country, old.state, old.city));
  return new;
end;
$$;
revoke execute on function public.ride_requests_premium_take() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_c_premium on public.ride_requests;
create trigger trg_ride_requests_c_premium
  before update of partner_id on public.ride_requests
  for each row execute function public.ride_requests_premium_take();

-- A driver accepting a scheduled ride (scheduled_ride_accept).
create or replace function public.scheduled_rides_premium_take()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  q jsonb := coalesce(new.request, '{}'::jsonb);
begin
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated')
     or new.partner_id is null or new.partner_id is not distinct from old.partner_id
     or new.partner_id is distinct from auth.uid() or new.stand_id is not null then
    return new;
  end if;
  perform public.premium_refusal(public.premium_check_at(new.partner_id, coalesce(nullif(btrim(new.service), ''), q->>'service'),
                                                         new.pickup_lat, new.pickup_lng, q->>'country', q->>'state',
                                                         q->>'city'));
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_premium_take() from public, anon, authenticated;
drop trigger if exists trg_scheduled_rides_premium on public.scheduled_rides;
create trigger trg_scheduled_rides_premium
  before update of partner_id on public.scheduled_rides
  for each row execute function public.scheduled_rides_premium_take();

-- Who reads an open request: restrictive, beside 0263's and 0268's, with
-- the same exceptions.
drop policy if exists "ride_requests premium" on public.ride_requests;
create policy "ride_requests premium" on public.ride_requests as restrictive for select to authenticated
  using (status <> 'open'
         or rider_id = (select auth.uid()) or partner_id = (select auth.uid())
         or direct_driver_id = (select auth.uid())
         or (select public.caller_is_admin())
         or (stand_id is not null and array[stand_id] <@ (select public.dispatch_caller_stand_ids()))
         or not (lower(btrim(coalesce(service, ''))) = any ((select public.premium_service_keys())::text[]))
         or public.premium_caller_sees(service, pickup_lat, pickup_lng, country, state, city));

-- For the driver's Services page: each active Premium service with whether
-- the caller qualifies and why not, at [p_lat, p_lng] (else their partner
-- row's first service area).
create or replace function public.my_premium_status(p_lat double precision default null,
                                                    p_lng double precision default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  c text;
  s text;
  t text;
  b text;
  pa public.partners;
  pl record;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_lat is not null and p_lng is not null then
    select * into pl from public.ride_option_place(p_lat, p_lng);
    c := pl.country; s := pl.state; t := pl.city; b := pl.suburb;
  end if;
  if coalesce(c, '') = '' then
    select * into pa from public.partners where auth_user_id = v_uid order by created_at desc limit 1;
    c := pa.service_countries[1];
    s := case when cardinality(pa.service_states) > 0 then pa.service_states[1] end;
    t := case when cardinality(pa.service_cities) > 0 then pa.service_cities[1] end;
    b := null;
  end if;
  return coalesce((
    select jsonb_agg(public.premium_driver_check(v_uid, e.values->>'name', c, s, t, b)
                       || jsonb_build_object('service', e.values->>'name')
                     order by e.position, e.values->>'name')
      from public.settings_entries e
     where e.category = 'vehicle-services' and e.values->'premium' = 'true'::jsonb
       and coalesce(e.values->>'status', 'true') <> 'false' and e.active
       and btrim(coalesce(e.values->>'name', '')) <> ''), '[]'::jsonb);
end;
$$;
revoke execute on function public.my_premium_status(double precision, double precision) from public, anon;
grant execute on function public.my_premium_status(double precision, double precision) to authenticated;

-- ---- 4. GET.Plus memberships and receipts ----------------------------------------------------------
create table if not exists public.plus_memberships (
  rider_id          uuid primary key references public.profiles(id) on delete cascade,
  status            text not null default 'active' check (status in ('active', 'grace', 'ended', 'expired')),
  auto_renew        boolean not null default true,
  joined_at         timestamptz not null default now(),
  period_start      timestamptz not null default now(),
  period_end        timestamptz not null,
  grace_until       timestamptz,
  country           text,
  state             text,
  city              text,
  suburb            text,
  month_price       numeric(10,2) not null default 0 check (month_price >= 0),
  free_cancels_used integer not null default 0 check (free_cancels_used >= 0),
  ended_at          timestamptz,
  last_error        text,
  updated_at        timestamptz not null default now()
);
create index if not exists plus_memberships_due_idx on public.plus_memberships (period_end)
  where status in ('active', 'grace');
comment on table public.plus_memberships is
  'GET.Plus rider membership (0316): one row a rider. Written only by the plus_* functions.';

create table if not exists public.plus_charges (
  id           uuid primary key default gen_random_uuid(),
  receipt_no   bigint generated always as identity,
  rider_id     uuid not null references public.profiles(id) on delete cascade,
  kind         text not null check (kind in ('join', 'renewal')),
  status       text not null check (status in ('paid', 'failed')),
  amount       numeric(10,2) not null check (amount >= 0),
  currency     text not null default 'MYR',
  period_start timestamptz,
  period_end   timestamptz,
  country      text,
  state        text,
  city         text,
  wallet_tx_id uuid,
  note         text,
  created_at   timestamptz not null default now()
);
create index if not exists plus_charges_rider_idx on public.plus_charges (rider_id, created_at desc);
create index if not exists plus_charges_created_idx on public.plus_charges (created_at desc);
comment on table public.plus_charges is
  'GET.Plus receipts (0316): each monthly charge, paid or failed. Written only by the plus_* functions.';

-- Admins who may see members: a grant on the page, the Settings hub or every page.
create or replace function public.plus_admin_can_read()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
begin
  if v_claims is null or v_claims = '' or coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return true;
  end if;
  return auth.uid() is not null and exists (
    select 1 from public.admin_access a
     where a.profile_id = auth.uid()
       and a.page in ('*', 'admin-settings', 'admin-settings-premium-plus'));
end;
$$;
revoke execute on function public.plus_admin_can_read() from public, anon;
grant execute on function public.plus_admin_can_read() to authenticated, service_role;

alter table public.plus_memberships enable row level security;
alter table public.plus_charges enable row level security;
revoke all on public.plus_memberships, public.plus_charges from anon, authenticated;
grant select on public.plus_memberships, public.plus_charges to authenticated;
grant all on public.plus_memberships, public.plus_charges to service_role;
drop policy if exists "plus_memberships own read" on public.plus_memberships;
create policy "plus_memberships own read" on public.plus_memberships for select to authenticated
  using (rider_id = (select auth.uid()) or (select public.plus_admin_can_read()));
drop policy if exists "plus_charges own read" on public.plus_charges;
create policy "plus_charges own read" on public.plus_charges for select to authenticated
  using (rider_id = (select auth.uid()) or (select public.plus_admin_can_read()));

-- A membership whose benefits hold now: active (an auto-renewing one until
-- the hourly job has had a day to renew it), or in grace.
create or replace function public.plus_membership_live(m public.plus_memberships)
returns boolean
language sql
stable
set search_path = ''
as $$
  select m.rider_id is not null and (
    (m.status = 'active' and (m.period_end > now() or (m.auto_renew and m.period_end > now() - interval '1 day')))
    or (m.status = 'grace' and m.grace_until > now()));
$$;

-- What [p_rider]'s membership gives at a place: null when none holds, or
-- GET.Plus is off there.
create or replace function public.plus_benefits(p_rider uuid, p_country text, p_state text, p_city text,
                                                p_suburb text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m public.plus_memberships;
  v jsonb;
begin
  select * into m from public.plus_memberships where rider_id = p_rider;
  if not found or not public.plus_membership_live(m) then
    return null;
  end if;
  v := public.premium_plus_rules_at(p_country, p_state, p_city, p_suburb);
  if not coalesce((v->>'plusOn')::boolean, false) then
    return null;
  end if;
  return jsonb_build_object(
    'pct', coalesce((v->>'plusDiscountPct')::numeric, 0),
    'maxDiscount', coalesce((v->>'plusMaxDiscount')::numeric, 0),
    'priority', coalesce((v->>'plusPriority')::boolean, false),
    'freeCancels', coalesce((v->>'plusFreeCancels')::numeric, 0)::int,
    'freeCancelsLeft', greatest(0, coalesce((v->>'plusFreeCancels')::numeric, 0)::int - m.free_cancels_used));
end;
$$;
revoke execute on function public.plus_benefits(uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.plus_benefits(uuid, text, text, text, text) to service_role;

-- The membership as the app reads it.
create or replace function public.plus_membership_json(p_rider uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when m.rider_id is null then null else jsonb_build_object(
    'status', m.status, 'live', public.plus_membership_live(m), 'autoRenew', m.auto_renew,
    'joinedAt', m.joined_at, 'periodStart', m.period_start, 'periodEnd', m.period_end,
    'graceUntil', m.grace_until, 'price', m.month_price, 'freeCancelsUsed', m.free_cancels_used,
    'place', jsonb_strip_nulls(jsonb_build_object('country', m.country, 'state', m.state, 'city', m.city,
                                                  'suburb', m.suburb)),
    'lastError', m.last_error) end
    from (select 1) one left join public.plus_memberships m on m.rider_id = p_rider;
$$;
revoke execute on function public.plus_membership_json(uuid) from public, anon, authenticated;

-- For the rider app at a place (the pickup, or where they are): the
-- Premium rules (the booking card's line), GET.Plus there, the caller's
-- membership and what it gives here, and their GET.wallet balance.
create or replace function public.premium_plus_terms(p_lat double precision default null,
                                                     p_lng double precision default null,
                                                     p_country text default null, p_state text default null,
                                                     p_city text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  p record;
  v jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into p from public.ride_option_place(p_lat, p_lng, p_country, p_state, p_city);
  v := public.premium_plus_rules_at(p.country, p.state, p.city, p.suburb);
  return jsonb_build_object(
    'place', jsonb_build_object('country', p.country, 'state', p.state, 'city', p.city, 'suburb', p.suburb),
    'premium', jsonb_build_object(
      'on', coalesce((v->>'premiumOn')::boolean, true),
      'maxCarAge', coalesce((v->>'premiumMaxCarAge')::numeric, 0)::int,
      'modelsListed', jsonb_array_length(coalesce(v->'premiumModels', '[]'::jsonb)) > 0,
      'minRating', coalesce((v->>'premiumMinRating')::numeric, 0),
      'minTrips', coalesce((v->>'premiumMinTrips')::numeric, 0)::int),
    'plus', jsonb_build_object(
      'on', coalesce((v->>'plusOn')::boolean, false),
      'price', round(coalesce((v->>'plusPrice')::numeric, 0), 2),
      'discountPct', coalesce((v->>'plusDiscountPct')::numeric, 0),
      'maxDiscount', coalesce((v->>'plusMaxDiscount')::numeric, 0),
      'freeCancels', coalesce((v->>'plusFreeCancels')::numeric, 0)::int,
      'priority', coalesce((v->>'plusPriority')::boolean, false),
      'graceDays', coalesce((v->>'plusGraceDays')::numeric, 0)::int),
    'membership', public.plus_membership_json(v_uid),
    'benefits', public.plus_benefits(v_uid, p.country, p.state, p.city, p.suburb),
    'walletBalance', coalesce((select w.balance from public.wallets w
                                where w.user_id = v_uid and w.wallet_type = 'get_wallet'), 0));
end;
$$;
revoke execute on function public.premium_plus_terms(double precision, double precision, text, text, text) from public, anon;
grant execute on function public.premium_plus_terms(double precision, double precision, text, text, text) to authenticated;

-- Takes [p_amount] from [p_rider]'s GET.wallet for a month of GET.Plus: the
-- ledger row's id, or null when the wallet is short. Nothing for a free month.
create or replace function public.plus_take(p_rider uuid, p_amount numeric, p_note text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance numeric;
  v_tx uuid;
begin
  if round(coalesce(p_amount, 0), 2) <= 0 then
    return '00000000-0000-0000-0000-000000000000'::uuid;
  end if;
  insert into public.wallets (user_id, wallet_type, balance) values (p_rider, 'get_wallet', 0)
  on conflict (user_id, wallet_type) do nothing;
  select w.balance into v_balance from public.wallets w
   where w.user_id = p_rider and w.wallet_type = 'get_wallet' for update;
  if coalesce(v_balance, 0) < round(p_amount, 2) then
    return null;
  end if;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
  values (p_rider, 'get_wallet', 'plus_fee', -round(p_amount, 2), 'get_plus', p_note)
  returning id into v_tx;
  return v_tx;
end;
$$;
revoke execute on function public.plus_take(uuid, numeric, text) from public, anon, authenticated;

create or replace function public.plus_period_note(p_start timestamptz, p_end timestamptz)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'GET.Plus, ' || to_char(p_start at time zone 'Asia/Kuala_Lumpur', 'FMDD Mon')
         || ' to ' || to_char(p_end at time zone 'Asia/Kuala_Lumpur', 'FMDD Mon YYYY');
$$;

-- Tells the member; never holds anything up.
create or replace function public.plus_notify(p_rider uuid, p_event text, p_title text, p_body text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.enqueue_notification(p_rider, p_event, 'get_plus', 'normal', p_title, p_body,
                                      jsonb_build_object('type', 'get_plus'));
exception when others then
  raise warning 'GET.Plus notice to % not sent: %', p_rider, sqlerrm;
end;
$$;
revoke execute on function public.plus_notify(uuid, text, text, text) from public, anon, authenticated;

-- Join (or pay again after grace or an end): charged now from GET.wallet,
-- a month from now. [p_expected]: the price the rider was shown.
create or replace function public.plus_join(p_lat double precision default null, p_lng double precision default null,
                                            p_country text default null, p_state text default null,
                                            p_city text default null, p_expected numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  p record;
  v jsonb;
  v_price numeric;
  m public.plus_memberships;
  v_tx uuid;
  v_start timestamptz := now();
  v_end timestamptz := now() + interval '1 month';
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtext('get_plus:' || v_uid::text));
  select * into p from public.ride_option_place(p_lat, p_lng, p_country, p_state, p_city);
  v := public.premium_plus_rules_at(p.country, p.state, p.city, p.suburb);
  if not coalesce((v->>'plusOn')::boolean, false) then
    raise exception 'PLUS_OFF' using errcode = 'P0001', hint = 'GET.Plus isn''t offered here yet.';
  end if;
  v_price := round(coalesce((v->>'plusPrice')::numeric, 0), 2);
  if p_expected is not null and abs(round(p_expected, 2) - v_price) > 0.005 then
    raise exception 'PLUS_PRICE_CHANGED' using errcode = 'P0001', hint = v_price::text;
  end if;

  select * into m from public.plus_memberships where rider_id = v_uid for update;
  if found and m.status = 'active' and m.period_end > now() then
    -- Still paid for: resumed, or nothing to do.
    update public.plus_memberships set auto_renew = true, updated_at = now() where rider_id = v_uid;
    return jsonb_build_object('charged', 0, 'membership', public.plus_membership_json(v_uid));
  end if;

  v_tx := public.plus_take(v_uid, v_price, public.plus_period_note(v_start, v_end));
  if v_tx is null then
    raise exception 'insufficient_balance' using errcode = 'P0001',
      hint = 'Top up GET.wallet: GET.Plus is RM' || to_char(v_price, 'FM999990.00') || ' a month.';
  end if;
  insert into public.plus_charges (rider_id, kind, status, amount, period_start, period_end, country, state, city,
                                   wallet_tx_id, note)
  values (v_uid, 'join', 'paid', v_price, v_start, v_end, nullif(p.country, ''), nullif(p.state, ''),
          nullif(p.city, ''), nullif(v_tx, '00000000-0000-0000-0000-000000000000'::uuid),
          public.plus_period_note(v_start, v_end));
  insert into public.plus_memberships as x (rider_id, status, auto_renew, joined_at, period_start, period_end,
                                            grace_until, country, state, city, suburb, month_price, free_cancels_used,
                                            ended_at, last_error, updated_at)
  values (v_uid, 'active', true, now(), v_start, v_end, null, nullif(p.country, ''), nullif(p.state, ''),
          nullif(p.city, ''), nullif(p.suburb, ''), v_price, 0, null, null, now())
  on conflict (rider_id) do update
     set status = 'active', auto_renew = true, period_start = excluded.period_start,
         period_end = excluded.period_end, grace_until = null, country = excluded.country, state = excluded.state,
         city = excluded.city, suburb = excluded.suburb, month_price = excluded.month_price, free_cancels_used = 0,
         ended_at = null, last_error = null, updated_at = now(),
         joined_at = case when x.status in ('ended', 'expired') then now() else x.joined_at end;
  return jsonb_build_object('charged', v_price, 'membership', public.plus_membership_json(v_uid));
end;
$$;
revoke execute on function public.plus_join(double precision, double precision, text, text, text, numeric) from public, anon;
grant execute on function public.plus_join(double precision, double precision, text, text, text, numeric) to authenticated;

-- Cancel (off: kept to the end of what is paid for) or resume (on).
create or replace function public.plus_set_auto_renew(p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  m public.plus_memberships;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into m from public.plus_memberships where rider_id = v_uid for update;
  if not found or m.status in ('ended', 'expired') then
    raise exception 'PLUS_NOT_MEMBER' using errcode = 'P0001', hint = 'You aren''t a GET.Plus member.';
  end if;
  if m.status = 'grace' and not coalesce(p_on, false) then
    -- Unpaid and cancelled: it ends now.
    update public.plus_memberships
       set status = 'ended', auto_renew = false, ended_at = now(), grace_until = null, updated_at = now()
     where rider_id = v_uid;
  else
    update public.plus_memberships set auto_renew = coalesce(p_on, false), updated_at = now() where rider_id = v_uid;
  end if;
  return public.plus_membership_json(v_uid);
end;
$$;
revoke execute on function public.plus_set_auto_renew(boolean) from public, anon;
grant execute on function public.plus_set_auto_renew(boolean) to authenticated;

-- One member whose period ended (see the header, 4): 'renewed', 'grace',
-- 'expired', 'ended' or 'skipped'.
create or replace function public.plus_renew_one(p_rider uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.plus_memberships;
  v jsonb;
  v_price numeric;
  v_tx uuid;
  v_start timestamptz;
  v_end timestamptz;
  v_grace int;
begin
  select * into m from public.plus_memberships where rider_id = p_rider for update skip locked;
  if not found or m.status in ('ended', 'expired') or (m.status = 'active' and m.period_end > now()) then
    return 'skipped';
  end if;
  v := public.premium_plus_rules_at(m.country, m.state, m.city, m.suburb);
  if not m.auto_renew or not coalesce((v->>'plusOn')::boolean, false) then
    update public.plus_memberships
       set status = 'ended', ended_at = now(), grace_until = null, updated_at = now(),
           last_error = case when m.auto_renew then 'GET.Plus is no longer offered at your place.' end
     where rider_id = p_rider;
    if m.auto_renew then
      perform public.plus_notify(p_rider, 'plus-ended-' || p_rider || '-' || to_char(m.period_end, 'YYYYMMDD'),
                                 'GET.Plus ended', 'GET.Plus is no longer offered where you joined, so it wasn''t renewed.');
    end if;
    return 'ended';
  end if;
  v_price := round(coalesce((v->>'plusPrice')::numeric, 0), 2);
  v_grace := coalesce((v->>'plusGraceDays')::numeric, 0)::int;
  -- On time: the next month follows on; after grace (or a long gap): from now.
  v_start := case when m.status = 'active' and m.period_end + interval '1 month' > now() then m.period_end else now() end;
  v_end := v_start + interval '1 month';
  v_tx := public.plus_take(p_rider, v_price, public.plus_period_note(v_start, v_end));
  if v_tx is not null then
    insert into public.plus_charges (rider_id, kind, status, amount, period_start, period_end, country, state, city,
                                     wallet_tx_id, note)
    values (p_rider, 'renewal', 'paid', v_price, v_start, v_end, m.country, m.state, m.city,
            nullif(v_tx, '00000000-0000-0000-0000-000000000000'::uuid), public.plus_period_note(v_start, v_end));
    update public.plus_memberships
       set status = 'active', period_start = v_start, period_end = v_end, grace_until = null, month_price = v_price,
           free_cancels_used = 0, last_error = null, updated_at = now()
     where rider_id = p_rider;
    perform public.plus_notify(p_rider, 'plus-renewed-' || p_rider || '-' || to_char(v_start, 'YYYYMMDD'),
                               'GET.Plus renewed',
                               'RM' || to_char(v_price, 'FM999990.00') || ' paid from GET.wallet. '
                               || public.plus_period_note(v_start, v_end) || '.');
    return 'renewed';
  end if;
  -- The wallet is short.
  if m.status = 'active' and v_grace > 0 then
    insert into public.plus_charges (rider_id, kind, status, amount, period_start, period_end, country, state, city, note)
    values (p_rider, 'renewal', 'failed', v_price, v_start, v_end, m.country, m.state, m.city,
            'GET.wallet was short. Top up to keep GET.Plus.');
    update public.plus_memberships
       set status = 'grace', grace_until = m.period_end + make_interval(days => v_grace),
           last_error = 'GET.wallet was short.', updated_at = now()
     where rider_id = p_rider;
    perform public.plus_notify(p_rider, 'plus-grace-' || p_rider || '-' || to_char(m.period_end, 'YYYYMMDD'),
                               'Top up to keep GET.Plus',
                               'We couldn''t take RM' || to_char(v_price, 'FM999990.00')
                               || ' from GET.wallet. Top up within ' || v_grace || ' days to keep GET.Plus.');
    return 'grace';
  end if;
  if m.status = 'grace' and m.grace_until > now() then
    return 'grace';
  end if;
  if m.status = 'active' then
    insert into public.plus_charges (rider_id, kind, status, amount, period_start, period_end, country, state, city, note)
    values (p_rider, 'renewal', 'failed', v_price, v_start, v_end, m.country, m.state, m.city,
            'GET.wallet was short.');
  end if;
  update public.plus_memberships
     set status = 'expired', ended_at = now(), grace_until = null, last_error = 'GET.wallet was short.',
         updated_at = now()
   where rider_id = p_rider;
  perform public.plus_notify(p_rider, 'plus-expired-' || p_rider || '-' || to_char(m.period_end, 'YYYYMMDD'),
                             'GET.Plus ended', 'GET.wallet was short, so GET.Plus ended. Join again any time.');
  return 'expired';
end;
$$;
revoke execute on function public.plus_renew_one(uuid) from public, anon, authenticated;

-- Every member due (the hourly job): {renewed, grace, expired, ended}.
create or replace function public.plus_renew_due()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_out text;
  n jsonb := jsonb_build_object('renewed', 0, 'grace', 0, 'expired', 0, 'ended', 0);
begin
  for r in
    select m.rider_id from public.plus_memberships m
     where (m.status = 'active' and m.period_end <= now()) or m.status = 'grace'
     order by m.period_end
     limit 500
  loop
    begin
      v_out := public.plus_renew_one(r.rider_id);
    exception when others then
      raise warning 'GET.Plus renewal for % failed: %', r.rider_id, sqlerrm;
      v_out := 'skipped';
    end;
    if n ? v_out then
      n := jsonb_set(n, array[v_out], to_jsonb((n->>v_out)::int + 1));
    end if;
  end loop;
  return n;
end;
$$;
revoke execute on function public.plus_renew_due() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'plus-renew-due';
    perform cron.schedule('plus-renew-due', '7 * * * *', $job$select public.plus_renew_due()$job$);
  end if;
end $$;

-- ---- 5. The discount on a member's ride -----------------------------------------------------------
alter table public.ride_requests add column if not exists plus_pct numeric(5,2);
alter table public.ride_requests add column if not exists plus_max_discount numeric(10,2);
alter table public.ride_requests add column if not exists plus_priority boolean not null default false;
alter table public.ride_requests add column if not exists plus_discount numeric(10,2);
alter table public.ride_requests add column if not exists plus_settled_at timestamptz;
alter table public.ride_requests add column if not exists plus_waived_fee numeric(10,2);
comment on column public.ride_requests.plus_pct is
  'GET.Plus (0316): the member''s discount % at the pickup, stamped by the server at booking; null: not a member.';
comment on column public.ride_requests.plus_discount is
  'GET.Plus (0316): taken off what the rider pays when the trip completed; the driver''s GET.wallet is credited the same.';

-- Stamped at insert from the rider's membership and the pickup's rules;
-- the app's values are never kept. A stand's order has none.
create or replace function public.ride_requests_plus_stamp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  p record;
  b jsonb;
begin
  new.plus_pct := null;
  new.plus_max_discount := null;
  new.plus_priority := false;
  new.plus_discount := null;
  new.plus_settled_at := null;
  new.plus_waived_fee := null;
  if new.rider_id is null or new.stand_id is not null
     or not exists (select 1 from public.plus_memberships m where m.rider_id = new.rider_id) then
    return new;
  end if;
  begin
    select * into p from public.ride_option_place(new.pickup_lat, new.pickup_lng, new.country, new.state, new.city);
    b := public.plus_benefits(new.rider_id, p.country, p.state, p.city, p.suburb);
  exception when others then
    raise warning 'GET.Plus stamp for ride % failed: %', new.id, sqlerrm;
    b := null;
  end;
  if b is not null then
    new.plus_pct := case when (b->>'pct')::numeric > 0 then (b->>'pct')::numeric end;
    new.plus_max_discount := case when (b->>'maxDiscount')::numeric > 0 then (b->>'maxDiscount')::numeric end;
    new.plus_priority := coalesce((b->>'priority')::boolean, false);
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_plus_stamp() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_plus_stamp on public.ride_requests;
create trigger trg_ride_requests_plus_stamp
  before insert on public.ride_requests
  for each row execute function public.ride_requests_plus_stamp();

-- The GET.Plus columns are the server's.
create or replace function public.ride_requests_plus_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if (new.plus_pct, new.plus_max_discount, new.plus_priority, new.plus_discount, new.plus_settled_at,
      new.plus_waived_fee)
     is distinct from
     (old.plus_pct, old.plus_max_discount, old.plus_priority, old.plus_discount, old.plus_settled_at,
      old.plus_waived_fee) then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'GET.Plus on a ride is the server''s.';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_plus_guard() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_plus_guard on public.ride_requests;
create trigger trg_ride_requests_plus_guard
  before update on public.ride_requests
  for each row execute function public.ride_requests_plus_guard();

create unique index if not exists wallet_transactions_plus_credit_ride
  on public.wallet_transactions (ride_id) where kind = 'plus_credit';
create unique index if not exists wallet_transactions_plus_cancel_ride
  on public.wallet_transactions (ride_id) where kind = 'plus_cancel_credit';

-- Settles the discount once the trip completed (header, 5): {settled, discount}.
create or replace function public.plus_settle_ride(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_fare numeric;
  v_disc numeric;
  v_left numeric;
begin
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.plus_pct is null or r.plus_settled_at is not null or r.status <> 'completed'
     or r.partner_id is null then
    return jsonb_build_object('settled', false);
  end if;
  v_fare := round(coalesce(r.ride_fare, r.fare, 0), 2);
  v_disc := round(greatest(0, v_fare) * r.plus_pct / 100, 2);
  if coalesce(r.plus_max_discount, 0) > 0 then
    v_disc := least(v_disc, r.plus_max_discount);
  end if;
  v_left := greatest(0, round(public.ride_amount_due(r) - coalesce(r.fare_coins_value, 0)
                              - coalesce(r.promo_discount, 0), 2));
  v_disc := least(v_disc, v_left);
  if v_disc > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (r.partner_id, 'get_wallet', 'plus_credit', v_disc, 'get_plus',
            'GET.Plus member''s discount on a ride, paid by get.ride — RM' || to_char(v_disc, 'FM999999990.00'), r.id)
    on conflict (ride_id) where kind = 'plus_credit' do nothing;
  end if;
  update public.ride_requests set plus_discount = greatest(v_disc, 0), plus_settled_at = now() where id = r.id;
  return jsonb_build_object('settled', true, 'discount', greatest(v_disc, 0));
end;
$$;
revoke execute on function public.plus_settle_ride(uuid) from public, anon, authenticated;

-- After the promo (trg_ride_requests_promo_settle sorts first), so the
-- discount never passes what is left to pay.
create or replace function public.ride_requests_plus_settle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public.plus_settle_ride(new.id);
  exception when others then
    raise warning 'ride % GET.Plus not settled: %', new.id, sqlerrm;
  end;
  return null;
end;
$$;
revoke execute on function public.ride_requests_plus_settle() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_zplus_settle on public.ride_requests;
create trigger trg_ride_requests_zplus_settle
  after update of status on public.ride_requests
  for each row
  when (new.status = 'completed' and old.status is distinct from 'completed' and new.plus_pct is not null)
  execute function public.ride_requests_plus_settle();

-- ---- 6. Free cancels -----------------------------------------------------------------------------
-- What a member's cancel of [r] costs when it would cost [p_fee]: 0 while a
-- free cancel is left this period (one is used; the driver is credited what
-- the fee would have paid them), else [p_fee].
create or replace function public.plus_cancel_waive(r public.ride_requests, p_fee numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  p record;
  b jsonb;
  v_rate numeric := case when r.commission_rate >= 0 and r.commission_rate < 1 then r.commission_rate else 0 end;
  v_fee numeric := round(coalesce(p_fee, 0), 2);
  v_share numeric;
begin
  if v_fee <= 0 or r.rider_id is null then
    return p_fee;
  end if;
  begin
    perform 1 from public.plus_memberships where rider_id = r.rider_id for update;
    if not found then
      return p_fee;
    end if;
    select * into p from public.ride_option_place(r.pickup_lat, r.pickup_lng, r.country, r.state, r.city);
    b := public.plus_benefits(r.rider_id, p.country, p.state, p.city, p.suburb);
    if b is null or (b->>'freeCancelsLeft')::int <= 0 then
      return p_fee;
    end if;
    update public.plus_memberships set free_cancels_used = free_cancels_used + 1, updated_at = now()
     where rider_id = r.rider_id;
    update public.ride_requests set plus_waived_fee = v_fee where id = r.id;
    v_share := round(v_fee * (1 - v_rate), 2);
    if r.partner_id is not null and v_share > 0 then
      insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
      values (r.partner_id, 'get_wallet', 'plus_cancel_credit', v_share, 'get_plus',
              'Cancellation fee, a GET.Plus free cancel paid by get.ride'
              || case when v_rate > 0 then ' (less ' || round(v_rate * 100, 1) || '% commission)' else '' end, r.id)
      on conflict (ride_id) where kind = 'plus_cancel_credit' do nothing;
    end if;
    return 0;
  exception when others then
    raise warning 'GET.Plus free cancel on ride % not applied: %', r.id, sqlerrm;
    return p_fee;
  end;
end;
$$;
revoke execute on function public.plus_cancel_waive(public.ride_requests, numeric) from public, anon, authenticated;

-- What ride_cancel_terms shows a member with a free cancel left: no late or
-- arrived fee, and how many are left.
create or replace function public.plus_cancel_terms(r public.ride_requests, p_terms jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  p record;
  b jsonb;
begin
  if r.rider_id is null or r.scheduled_ride_id is not null then
    return p_terms;
  end if;
  select * into p from public.ride_option_place(r.pickup_lat, r.pickup_lng, r.country, r.state, r.city);
  b := public.plus_benefits(r.rider_id, p.country, p.state, p.city, p.suburb);
  if b is null or (b->>'freeCancelsLeft')::int <= 0 then
    return p_terms;
  end if;
  return p_terms || jsonb_build_object('lateFee', 0, 'arrivedFee', 0,
                                       'plusFreeCancelsLeft', (b->>'freeCancelsLeft')::int);
exception when others then
  return p_terms;
end;
$$;
revoke execute on function public.plus_cancel_terms(public.ride_requests, jsonb) from public, anon, authenticated;

-- ---- 8. Admin: members and revenue ---------------------------------------------------------------
create or replace function public.admin_plus_members(p_status text default null, p_search text default null,
                                                     p_limit integer default 50, p_offset integer default 0)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_q text := nullif(lower(btrim(coalesce(p_search, ''))), '');
begin
  if not public.plus_admin_can_read() then
    raise exception 'Only admins with Premium and GET.Plus can see members.' using errcode = '42501';
  end if;
  return (
    with m as (
      select x as mem, x.rider_id, x.joined_at, pr.name, pr.phone
        from public.plus_memberships x
        left join public.profiles pr on pr.id = x.rider_id
       where (p_status is null or p_status = '' or x.status = p_status)
         and (v_q is null or lower(coalesce(pr.name, '')) like '%' || v_q || '%'
              or coalesce(pr.phone, '') like '%' || v_q || '%' or x.rider_id::text = v_q)
    )
    select jsonb_build_object(
      'total', (select count(*) from m),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
          'riderId', m.rider_id, 'name', m.name, 'phone', m.phone, 'status', (m.mem).status,
          'live', public.plus_membership_live(m.mem), 'autoRenew', (m.mem).auto_renew, 'joinedAt', m.joined_at,
          'periodEnd', (m.mem).period_end, 'graceUntil', (m.mem).grace_until, 'price', (m.mem).month_price,
          'freeCancelsUsed', (m.mem).free_cancels_used,
          'place', nullif(concat_ws(', ', (m.mem).city, (m.mem).state, (m.mem).country), ''),
          'paid', coalesce((select sum(c.amount) from public.plus_charges c
                             where c.rider_id = m.rider_id and c.status = 'paid'), 0),
          'saved', coalesce((select sum(q.plus_discount) from public.ride_requests q
                              where q.rider_id = m.rider_id and q.plus_discount > 0), 0))
          order by m.joined_at desc, m.rider_id)
          from (select * from m order by m.joined_at desc, m.rider_id
                 limit greatest(1, least(coalesce(p_limit, 50), 200)) offset greatest(0, coalesce(p_offset, 0))) m),
        '[]'::jsonb)));
end;
$$;
revoke execute on function public.admin_plus_members(text, text, integer, integer) from public, anon;
grant execute on function public.admin_plus_members(text, text, integer, integer) to authenticated;

create or replace function public.admin_plus_revenue(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_from timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 366)));
  v_fees numeric;
  v_disc numeric;
  v_waived numeric;
  v_comm numeric;
begin
  if not public.plus_admin_can_read() then
    raise exception 'Only admins with Premium and GET.Plus can see GET.Plus revenue.' using errcode = '42501';
  end if;
  select coalesce(sum(amount), 0) into v_fees from public.plus_charges where status = 'paid' and created_at >= v_from;
  select coalesce(sum(plus_discount), 0), coalesce(sum(commission_amount), 0) into v_disc, v_comm
    from public.ride_requests where plus_settled_at >= v_from and plus_discount > 0;
  select coalesce(sum(w.amount), 0) into v_waived
    from public.wallet_transactions w where w.kind = 'plus_cancel_credit' and w.created_at >= v_from;
  return jsonb_build_object(
    'days', greatest(1, least(coalesce(p_days, 30), 366)),
    'active', (select count(*) from public.plus_memberships m where m.status = 'active'),
    'grace', (select count(*) from public.plus_memberships m where m.status = 'grace'),
    'cancelling', (select count(*) from public.plus_memberships m where m.status = 'active' and not m.auto_renew),
    'joins', (select count(*) from public.plus_charges where kind = 'join' and status = 'paid' and created_at >= v_from),
    'renewals', (select count(*) from public.plus_charges where kind = 'renewal' and status = 'paid' and created_at >= v_from),
    'failed', (select count(*) from public.plus_charges where status = 'failed' and created_at >= v_from),
    'fees', v_fees,
    'discounts', v_disc,
    'discountedRides', (select count(*) from public.ride_requests where plus_settled_at >= v_from and plus_discount > 0),
    'waivedPaid', v_waived,
    'freeCancels', (select count(*) from public.wallet_transactions w
                     where w.kind = 'plus_cancel_credit' and w.created_at >= v_from),
    'commissionOnMemberRides', v_comm,
    'net', round(v_fees - v_disc - v_waived, 2));
end;
$$;
revoke execute on function public.admin_plus_revenue(integer) from public, anon;
grant execute on function public.admin_plus_revenue(integer) to authenticated;

-- ---- 9. Edits in place ----------------------------------------------------------------------------
-- Each from the function's current definition, so a later batch's own
-- change to it stays; once only.
do $edit$
declare
  v_def text;
  v_new text;
  f record;
begin
  for f in
    select * from (values
      ('ride_left_to_pay', '',
       'coalesce(r.promo_discount, 0)',
       'coalesce(r.promo_discount, 0)' || chr(10) || '                           - coalesce(r.plus_discount, 0)',
       'r.plus_discount'),
      ('ride_requests_city_cancel_fee', '',
       'v_fee := public.ride_cancel_fee(v_rules, old.accepted_at, old.arrived_at, v_at, new.cancel_reason);',
       'v_fee := public.ride_cancel_fee(v_rules, old.accepted_at, old.arrived_at, v_at, new.cancel_reason);'
         || chr(10) || '  -- 0316: a GET.Plus free cancel.' || chr(10)
         || '  v_fee := public.plus_cancel_waive(new, v_fee);',
       'plus_cancel_waive'),
      ('ride_cancel_terms', '',
       'return v || jsonb_build_object(',
       '-- 0316: a GET.Plus free cancel left.' || chr(10) || '  v := public.plus_cancel_terms(r, v);'
         || chr(10) || '  return v || jsonb_build_object(',
       'plus_cancel_terms')
    ) as t(fn, args, anchor, replacement, marker)
  loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = f.fn
       and pg_get_function_identity_arguments(p.oid) like '%' || f.args || '%'
     order by p.oid desc limit 1;
    if v_def is null then
      raise exception '0316: public.% is missing', f.fn;
    end if;
    if position(f.marker in v_def) > 0 then
      continue;
    end if;
    if position(f.anchor in v_def) = 0 then
      raise exception '0316: public.% no longer has "%"; edit it by hand', f.fn, f.anchor;
    end if;
    v_new := replace(v_def, f.anchor, f.replacement);
    execute v_new;
  end loop;
end $edit$;

-- ---- Live settings -------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public'
                        and tablename = 'premium_plus_places') then
    alter publication supabase_realtime add table public.premium_plus_places;
  end if;
end $$;

notify pgrst, 'reload schema';
