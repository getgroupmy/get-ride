-- ============================================================================
-- 0242 — Rider promo codes, end to end
--
-- Until now the codes (WELCOME10, RIDE5) were rows of settings_entries
-- (category 'promocode-list': code, description, discount, maxUses, active)
-- that nothing read: the rider's promo sheet answered every code "not
-- valid". This gives them a table, rules, a check at booking and a
-- settlement when the trip completes.
--
-- promo_codes (Admin → Settings → Promocode, page 'admin-settings-promocode'):
--   * discount: a fixed amount (RM) or a percentage with an optional cap (RM);
--   * limits: uses in total, uses per rider, a total budget (RM), a minimum fare;
--   * expiry: starts_at / ends_at;
--   * where: regions (country / state / city / suburb, matched by name against
--     the places holding the point, as commission rates and promotions are,
--     0216 / 0224), applied to the pickup, the drop-off, or both (both points
--     inside). No region: everywhere;
--   * when: a date range, a daily window (may run past midnight) and weekdays,
--     on the pickup region's clock, else Malaysia's (as 0224);
--   * who: every gender or some (profiles.gender: male, female, other), every
--     rider or the riders listed; optionally first ride only;
--   * services (by name, any case; empty: all), auto apply, active.
--   uses_count and discount_total are kept by the settlement under the code's
--   row lock, so two trips completing together can't overspend.
--
-- promo_redemptions: one row per settled trip (ride_id unique): the code, the
--   rider, the driver, the final fare, the discount, what the rider pays and
--   what the driver is credited. Read by the rider and the driver of that
--   trip and by admins with the page; written only by the settlement.
--
-- Rider RPCs (SECURITY DEFINER, signed-in callers):
--   Each code is shown in the app (show_in_app, default) or not: a hidden code
--   is never listed and works only when the rider types it. A code that
--   applies by itself is always shown (a check holds it).
--   * promo_offers(pickup, drop, service, fare): the shown codes that apply now to
--     the caller, with the estimated discount, which one auto-applies (the
--     largest auto-apply discount) and whether it is about the pickup only.
--     Codes the caller doesn't qualify for are never listed.
--   * promo_check(code, pickup, drop, service, fare): a typed code; one plain
--     reason when it doesn't apply. 20 tries per 10 minutes per account.
--   * promo_zone_here(lat, lng): the caller stands in the area of an active,
--     shown auto-apply code about the pickup (one with regions) they qualify for.
--
-- The ride: the app books with promo_code_id. The database checks it again
-- (BEFORE INSERT) against the ride's own pickup, drop-off, service and fare;
-- a code that doesn't apply is dropped from the ride (promo_error says why)
-- and the booking goes ahead without it. The estimate follows fare changes
-- while the request is open. Every other promo column is the server's.
--
-- Settlement (AFTER the status turns completed): only a trip completed in
-- full. A trip the driver ended early (ended_early_at, 0104) gets no promo;
-- cancelled or expired trips never complete. Under the code's row lock the
-- limits and budget are checked again, the discount is worked out on the
-- final fare (ride_fare), the redemption is written (once per ride), the
-- driver's GET.wallet is credited through the ledger (kind 'promo_credit',
-- keyed on the ride: wallet_transactions.ride_id is unique per kind there),
-- the ride gets promo_discount and promo_payable, and the rider is told
-- ("Promo RIDE5 saved you RM5.00 · you paid RM15.00"). Any failure leaves
-- the trip completed with no promo (promo_error).
--
-- Paying: ride_left_to_pay (0142) is less the promo discount, so GET.wallet,
-- GET.coin and cash all take what the rider owes after the promo; the driver
-- has the rest from the credit.
--
-- The settings_entries codes are moved here (fixed RM amounts, as the old
-- Discount field was) and their rows removed.
-- ============================================================================

-- ---- Tables -------------------------------------------------------------------------------------
create table if not exists public.promo_codes (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique check (code ~ '^[A-Z0-9_-]{2,32}$'),
  description         text check (description is null or length(description) <= 200),
  active              boolean not null default true,
  discount_type       text not null default 'fixed' check (discount_type in ('fixed', 'percent')),
  discount_value      numeric(10,2) not null check (discount_value > 0),
  max_discount        numeric(10,2) check (max_discount is null or max_discount > 0),
  max_uses            integer check (max_uses is null or max_uses > 0),
  max_uses_per_rider  integer check (max_uses_per_rider is null or max_uses_per_rider > 0),
  budget              numeric(12,2) check (budget is null or budget > 0),
  min_fare            numeric(10,2) check (min_fare is null or min_fare >= 0),
  starts_at           timestamptz,
  ends_at             timestamptz,
  applies_to          text not null default 'pickup' check (applies_to in ('pickup', 'dropoff', 'both')),
  -- [{country, state, city, suburb}], each level optional below the first given.
  regions             jsonb not null default '[]'::jsonb
                        check (jsonb_typeof(regions) = 'array' and jsonb_array_length(regions) <= 100),
  date_from           date,
  date_to             date,
  -- ISO days, 1 Monday … 7 Sunday. Empty: every day.
  weekdays            smallint[] not null default '{}'
                        check (weekdays <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]),
  -- Both or neither; from > to runs past midnight.
  time_from           time,
  time_to             time,
  -- profiles.gender values. Empty: everyone.
  genders             text[] not null default '{}'
                        check (genders <@ array['male', 'female', 'other']::text[]),
  -- The riders it is for. Empty: everyone.
  rider_ids           uuid[] not null default '{}' check (cardinality(rider_ids) <= 5000),
  -- Service names, any case. Empty: every service.
  services            text[] not null default '{}' check (cardinality(services) <= 50),
  first_ride_only     boolean not null default false,
  auto_apply          boolean not null default false,
  -- Listed to riders (promo_offers, the zone bar). Off: works only when typed.
  -- A code that applies by itself is always shown.
  show_in_app         boolean not null default true,
  uses_count          integer not null default 0,
  discount_total      numeric(12,2) not null default 0,
  legacy              jsonb,
  created_by          uuid,
  updated_by          uuid,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (show_in_app or not auto_apply),
  check (discount_type = 'percent' or max_discount is null),
  check (discount_type = 'fixed' or discount_value <= 100),
  check (starts_at is null or ends_at is null or ends_at > starts_at),
  check (date_from is null or date_to is null or date_to >= date_from),
  check ((time_from is null) = (time_to is null) and (time_from is null or time_from <> time_to))
);

create index if not exists promo_codes_live_idx on public.promo_codes (auto_apply) where active;

create table if not exists public.promo_redemptions (
  id             uuid primary key default gen_random_uuid(),
  -- No foreign key: a trip's money record outlives the trip row.
  ride_id        uuid not null unique,
  code_id        uuid not null references public.promo_codes(id) on delete restrict,
  code           text not null,
  rider_id       uuid,
  driver_id      uuid,
  fare           numeric(10,2) not null,
  discount       numeric(10,2) not null check (discount > 0),
  payable        numeric(10,2) not null check (payable >= 0),
  driver_credit  numeric(10,2) not null check (driver_credit >= 0),
  wallet_tx_id   uuid,
  created_at     timestamptz not null default now()
);

create index if not exists promo_redemptions_code_idx on public.promo_redemptions (code_id, created_at desc);
create index if not exists promo_redemptions_code_rider_idx on public.promo_redemptions (code_id, rider_id);
create index if not exists promo_redemptions_rider_idx on public.promo_redemptions (rider_id);
create index if not exists promo_redemptions_driver_idx on public.promo_redemptions (driver_id);

-- The ride's promo: the code asked for (checked again by the server), its
-- text, the estimate at booking, and what the settlement decided.
alter table public.ride_requests
  add column if not exists promo_code_id    uuid,
  add column if not exists promo_code       text,
  add column if not exists promo_estimate   numeric(10,2),
  add column if not exists promo_discount   numeric(10,2),
  add column if not exists promo_payable    numeric(10,2),
  add column if not exists promo_settled_at timestamptz,
  add column if not exists promo_error      text;

-- One promo credit per ride in the ledger.
alter table public.wallet_transactions add column if not exists ride_id uuid;
create unique index if not exists wallet_transactions_promo_ride_key
  on public.wallet_transactions (ride_id) where kind = 'promo_credit';

-- ---- Who manages them ---------------------------------------------------------------------------
insert into public.admin_table_pages (target, page) values
  ('promo_codes', 'admin-settings-promocode')
on conflict do nothing;

-- Admins with the Promocode page (or the Settings hub, or every page).
create or replace function public.promo_caller_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1 from public.admin_access a
     where a.profile_id = auth.uid()
       and a.page in ('*', 'admin-settings', 'admin-settings-promocode'));
$$;
revoke execute on function public.promo_caller_is_admin() from public, anon;
grant execute on function public.promo_caller_is_admin() to authenticated;

alter table public.promo_codes enable row level security;
revoke all on public.promo_codes from anon;
grant select, insert, update, delete on public.promo_codes to authenticated;

drop policy if exists "promo_codes admin read" on public.promo_codes;
create policy "promo_codes admin read" on public.promo_codes
  for select to authenticated using ((select public.promo_caller_is_admin()));
drop policy if exists "promo_codes admin insert" on public.promo_codes;
create policy "promo_codes admin insert" on public.promo_codes
  for insert to authenticated with check ((select public.caller_admin_can_write('promo_codes')));
drop policy if exists "promo_codes admin update" on public.promo_codes;
create policy "promo_codes admin update" on public.promo_codes
  for update to authenticated
  using ((select public.caller_admin_can_write('promo_codes')))
  with check ((select public.caller_admin_can_write('promo_codes')));
drop policy if exists "promo_codes admin delete" on public.promo_codes;
create policy "promo_codes admin delete" on public.promo_codes
  for delete to authenticated using ((select public.caller_admin_can_write('promo_codes')));

alter table public.promo_redemptions enable row level security;
revoke all on public.promo_redemptions from anon, authenticated;
grant select on public.promo_redemptions to authenticated;
drop policy if exists "promo_redemptions own or admin read" on public.promo_redemptions;
create policy "promo_redemptions own or admin read" on public.promo_redemptions
  for select to authenticated
  using (rider_id = (select auth.uid()) or driver_id = (select auth.uid())
         or (select public.promo_caller_is_admin()));

-- The editor's stamps; the counters are the settlement's.
create or replace function public.promo_codes_stamp()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.code := upper(btrim(new.code));
  new.updated_at := now();
  new.updated_by := auth.uid();
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
    new.created_at := now();
  end if;
  if current_user in ('anon', 'authenticated') then
    if tg_op = 'INSERT' then
      new.uses_count := 0;
      new.discount_total := 0;
      new.legacy := null;
    else
      new.uses_count := old.uses_count;
      new.discount_total := old.discount_total;
      new.legacy := old.legacy;
      new.created_by := old.created_by;
      new.created_at := old.created_at;
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.promo_codes_stamp() from public, anon, authenticated;

drop trigger if exists trg_promo_codes_stamp on public.promo_codes;
create trigger trg_promo_codes_stamp
  before insert or update on public.promo_codes
  for each row execute function public.promo_codes_stamp();

-- The Promocode page follows changes live.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and tablename = 'promo_codes') then
      alter publication supabase_realtime add table public.promo_codes;
    end if;
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and tablename = 'promo_redemptions') then
      alter publication supabase_realtime add table public.promo_redemptions;
    end if;
  end if;
end $$;

-- ---- The rules ----------------------------------------------------------------------------------
-- The places holding a point, as {country, state, city, suburb}; null without a point.
create or replace function public.promo_places(p_lat double precision, p_lng double precision)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select case when p_lat is null or p_lng is null then null
              else (select array[p.place_country, p.place_state, p.place_city, p.place_suburb]
                      from public.commission_places(p_lat, p_lng) p) end;
$$;
revoke execute on function public.promo_places(double precision, double precision) from public, anon, authenticated;

-- Whether a point's places are in one of [p_regions]; no regions: everywhere.
create or replace function public.promo_in_regions(p_regions jsonb, p_place text[])
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(jsonb_array_length(p_regions), 0) = 0
      or (p_place is not null and exists (
            select 1 from jsonb_array_elements(p_regions) g
             where coalesce(nullif(btrim(g->>'country'), ''), nullif(btrim(g->>'state'), ''),
                            nullif(btrim(g->>'city'), ''), nullif(btrim(g->>'suburb'), '')) is not null
               and (nullif(btrim(g->>'country'), '') is null or public.commission_place_matches(g->>'country', p_place[1]))
               and (nullif(btrim(g->>'state'), '') is null or public.commission_place_matches(g->>'state', p_place[2]))
               and (nullif(btrim(g->>'city'), '') is null or public.commission_place_matches(g->>'city', p_place[3]))
               and (nullif(btrim(g->>'suburb'), '') is null or public.commission_place_matches(g->>'suburb', p_place[4]))));
$$;
revoke execute on function public.promo_in_regions(jsonb, text[]) from public, anon, authenticated;

-- The pickup region's clock (Admin → Country / States / Cities → Time zone),
-- the most specific one holding the point that has one; else Malaysia's.
create or replace function public.promo_tz(p_lat double precision, p_lng double precision)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select a."values"->>'timezone'
      from public.regions_at(p_lat, p_lng) a
     where p_lat is not null and a.inside and coalesce(btrim(a."values"->>'timezone'), '') <> ''
     order by a.area asc nulls last
     limit 1), 'Asia/Kuala_Lumpur');
$$;
revoke execute on function public.promo_tz(double precision, double precision) from public, anon, authenticated;

-- The discount [c] gives on [p_fare]: the fixed amount or the percentage
-- (capped), never more than the fare or what is left of the budget.
create or replace function public.promo_amount(c public.promo_codes, p_fare numeric)
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare
  v numeric;
begin
  if p_fare is null or p_fare <= 0 then
    return 0;
  end if;
  if c.discount_type = 'percent' then
    v := round(p_fare * c.discount_value / 100, 2);
    if c.max_discount is not null then
      v := least(v, c.max_discount);
    end if;
  else
    v := c.discount_value;
  end if;
  v := least(v, p_fare);
  if c.budget is not null then
    v := least(v, greatest(0, c.budget - c.discount_total));
  end if;
  return round(greatest(v, 0), 2);
end;
$$;
revoke execute on function public.promo_amount(public.promo_codes, numeric) from public, anon, authenticated;

-- Why [c] doesn't apply to [p_rider] at [p_at], or null when it does.
--   p_pick / p_drop: promo_places of the points (null: no point given);
--   p_check_drop: false asks about the pickup alone (the home bar);
--   p_service / p_fare: null skips that rule;
--   p_ride: a trip to leave out of "first ride".
-- Reasons: inactive, not_started, expired, not_for_you, first_ride_only,
-- not_now, outside_area, service, min_fare, used_up, used_by_you.
create or replace function public.promo_reason(
  c public.promo_codes,
  p_rider uuid,
  p_at timestamptz,
  p_tz text,
  p_pick text[],
  p_drop text[],
  p_check_drop boolean,
  p_service text,
  p_fare numeric,
  p_ride uuid default null
)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_local timestamp;
  v_day integer;
  v_time time;
  v_gender text;
  v_pick_ok boolean;
  v_drop_ok boolean;
begin
  if not c.active then
    return 'inactive';
  end if;
  if c.starts_at is not null and p_at < c.starts_at then
    return 'not_started';
  end if;
  if c.ends_at is not null and p_at >= c.ends_at then
    return 'expired';
  end if;
  if p_rider is null then
    return 'not_for_you';
  end if;
  if cardinality(c.rider_ids) > 0 and not (p_rider = any (c.rider_ids)) then
    return 'not_for_you';
  end if;
  if cardinality(c.genders) > 0 then
    select pr.gender::text into v_gender from public.profiles pr where pr.id = p_rider;
    if v_gender is null or not (v_gender = any (c.genders)) then
      return 'not_for_you';
    end if;
  end if;
  if c.first_ride_only and exists (
       select 1 from public.ride_requests x
        where x.rider_id = p_rider and x.status = 'completed'
          and x.id is distinct from p_ride) then
    return 'first_ride_only';
  end if;

  begin
    v_local := p_at at time zone coalesce(nullif(btrim(p_tz), ''), 'Asia/Kuala_Lumpur');
  exception when others then
    v_local := p_at at time zone 'Asia/Kuala_Lumpur';
  end;
  v_day := extract(isodow from v_local)::int;
  v_time := v_local::time;
  if (c.date_from is not null and v_local::date < c.date_from)
     or (c.date_to is not null and v_local::date > c.date_to)
     or (cardinality(c.weekdays) > 0 and not (v_day = any (c.weekdays)))
     or (c.time_from is not null and c.time_to is not null
         and not case when c.time_from < c.time_to then v_time >= c.time_from and v_time < c.time_to
                      else v_time >= c.time_from or v_time < c.time_to end) then
    return 'not_now';
  end if;

  if coalesce(jsonb_array_length(c.regions), 0) > 0 then
    v_pick_ok := public.promo_in_regions(c.regions, p_pick);
    v_drop_ok := public.promo_in_regions(c.regions, p_drop);
    if (c.applies_to = 'pickup' and not v_pick_ok)
       or (c.applies_to = 'dropoff' and (not p_check_drop or not v_drop_ok))
       or (c.applies_to = 'both' and (not v_pick_ok or (p_check_drop and not v_drop_ok))) then
      return 'outside_area';
    end if;
  end if;

  if p_service is not null and cardinality(c.services) > 0
     and not exists (select 1 from unnest(c.services) s
                      where lower(btrim(s)) = lower(btrim(p_service))) then
    return 'service';
  end if;
  if p_fare is not null and c.min_fare is not null and p_fare < c.min_fare then
    return 'min_fare';
  end if;
  if (c.max_uses is not null and c.uses_count >= c.max_uses)
     or (c.budget is not null and c.discount_total >= c.budget) then
    return 'used_up';
  end if;
  if c.max_uses_per_rider is not null and (
       select count(*) from public.promo_redemptions r
        where r.code_id = c.id and r.rider_id = p_rider) >= c.max_uses_per_rider then
    return 'used_by_you';
  end if;
  return null;
end;
$$;
revoke execute on function public.promo_reason(public.promo_codes, uuid, timestamptz, text, text[], text[],
  boolean, text, numeric, uuid) from public, anon, authenticated;

-- What the rider is told when a code doesn't apply.
create or replace function public.promo_reason_text(p_reason text, c public.promo_codes default null,
                                                    p_service text default null)
returns text
language sql
stable
set search_path = public
as $$
  select case p_reason
    when 'not_found' then 'This code isn''t valid.'
    when 'inactive' then 'This code isn''t valid.'
    when 'not_started' then 'This code isn''t active yet.'
    when 'expired' then 'This code has expired.'
    when 'not_for_you' then 'This code isn''t available on your account.'
    when 'first_ride_only' then 'This code is for your first ride only.'
    when 'not_now' then 'This code can''t be used at this time.'
    when 'outside_area' then case c.applies_to
        when 'dropoff' then 'This code doesn''t apply to this drop-off.'
        when 'both' then 'This code needs both the pickup and the drop-off inside its area.'
        else 'This code doesn''t apply to this pickup.' end
    when 'service' then 'This code doesn''t apply to ' || coalesce(nullif(btrim(p_service), ''), 'this service') || '.'
    when 'min_fare' then 'This code needs a fare of at least RM' || to_char(c.min_fare, 'FM999999990.00') || '.'
    when 'used_up' then 'This code has been fully used.'
    when 'used_by_you' then 'You''ve already used this code.'
    when 'rate_limited' then 'Too many tries. Please wait a few minutes and try again.'
    when 'sign_in' then 'Sign in to use a promo code.'
    else 'This code can''t be used on this ride.'
  end;
$$;
revoke execute on function public.promo_reason_text(text, public.promo_codes, text) from public, anon, authenticated;

-- ---- Rider RPCs ---------------------------------------------------------------------------------
create or replace function public.promo_offers(
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_drop_lat double precision default null,
  p_drop_lng double precision default null,
  p_service text default null,
  p_fare numeric default null
)
returns table (
  code_id uuid,
  code text,
  description text,
  discount_type text,
  discount_value numeric,
  max_discount numeric,
  estimated_discount numeric,
  estimated_payable numeric,
  auto_apply boolean,
  applies_to text,
  pickup_only boolean,
  ends_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_fare numeric := case when p_fare is not null and p_fare > 0 and p_fare < 1000000000 then round(p_fare, 2) end;
  v_pick text[];
  v_drop text[];
  v_tz text;
  v_has_drop boolean := p_drop_lat is not null and p_drop_lng is not null;
begin
  if v_uid is null or p_pickup_lat is null or p_pickup_lng is null then
    return;
  end if;
  if not exists (select 1 from public.promo_codes c where c.active and c.show_in_app) then
    return;
  end if;
  v_pick := public.promo_places(p_pickup_lat, p_pickup_lng);
  v_drop := case when v_has_drop then public.promo_places(p_drop_lat, p_drop_lng) end;
  v_tz := public.promo_tz(p_pickup_lat, p_pickup_lng);
  return query
  with fit as (
    select c.*, public.promo_amount(c, v_fare) as est
      from public.promo_codes c
     where c.active and c.show_in_app
       and public.promo_reason(c, v_uid, now(), v_tz, v_pick, v_drop, v_has_drop,
                               nullif(btrim(p_service), ''), v_fare) is null
  ),
  best as (
    select f.id from fit f where f.auto_apply
     order by f.est desc, f.ends_at asc nulls last, f.code
     limit 1
  )
  select f.id, f.code, f.description, f.discount_type, f.discount_value, f.max_discount,
         f.est, case when v_fare is null then null else greatest(0, v_fare - f.est) end,
         f.id = (select b.id from best b), f.applies_to, f.applies_to = 'pickup', f.ends_at
    from fit f
   order by (f.id = (select b.id from best b)) desc, f.est desc, f.code;
end;
$$;
revoke execute on function public.promo_offers(double precision, double precision, double precision,
  double precision, text, numeric) from public, anon;
grant execute on function public.promo_offers(double precision, double precision, double precision,
  double precision, text, numeric) to authenticated;

-- A code the rider typed: {ok, code_id, code, discount, payable, applies_to,
-- auto_apply} or {ok: false, reason, message}.
create or replace function public.promo_check(
  p_code text,
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_drop_lat double precision default null,
  p_drop_lng double precision default null,
  p_service text default null,
  p_fare numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_fare numeric := case when p_fare is not null and p_fare > 0 and p_fare < 1000000000 then round(p_fare, 2) end;
  v_has_drop boolean := p_drop_lat is not null and p_drop_lng is not null;
  v_wait integer;
  v_reason text;
  v_est numeric;
  c public.promo_codes;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'reason', 'sign_in', 'message', public.promo_reason_text('sign_in'));
  end if;
  -- As the other lookups (0137): a code can't be guessed by trying many.
  v_wait := public.auth_rate_take('promo_check', v_uid::text, 20, interval '10 minutes');
  if v_wait > 0 then
    return jsonb_build_object('ok', false, 'reason', 'rate_limited', 'wait', v_wait,
                              'message', public.promo_reason_text('rate_limited'));
  end if;
  if v_code !~ '^[A-Z0-9_-]{2,32}$' then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', public.promo_reason_text('not_found'));
  end if;
  select * into c from public.promo_codes where code = v_code;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found', 'message', public.promo_reason_text('not_found'));
  end if;
  v_reason := public.promo_reason(
    c, v_uid, now(), public.promo_tz(p_pickup_lat, p_pickup_lng),
    public.promo_places(p_pickup_lat, p_pickup_lng),
    case when v_has_drop then public.promo_places(p_drop_lat, p_drop_lng) end,
    true, nullif(btrim(p_service), ''), v_fare);
  if v_reason is null and p_pickup_lat is null then
    v_reason := 'outside_area';
  end if;
  if v_reason is not null then
    -- An inactive code reads as one that doesn't exist.
    if v_reason = 'inactive' then
      v_reason := 'not_found';
    end if;
    return jsonb_build_object('ok', false, 'reason', v_reason,
                              'message', public.promo_reason_text(v_reason, c, p_service));
  end if;
  v_est := public.promo_amount(c, v_fare);
  return jsonb_build_object(
    'ok', true, 'code_id', c.id, 'code', c.code, 'description', c.description,
    'discount_type', c.discount_type, 'discount_value', c.discount_value, 'max_discount', c.max_discount,
    'discount', v_est, 'payable', case when v_fare is null then null else greatest(0, v_fare - v_est) end,
    'applies_to', c.applies_to, 'auto_apply', c.auto_apply);
end;
$$;
revoke execute on function public.promo_check(text, double precision, double precision, double precision,
  double precision, text, numeric) from public, anon;
grant execute on function public.promo_check(text, double precision, double precision, double precision,
  double precision, text, numeric) to authenticated;

-- The home bar: the caller stands in the area of an active auto-apply code
-- about the pickup that they qualify for.
create or replace function public.promo_zone_here(p_lat double precision, p_lng double precision)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_pick text[];
  v_tz text;
begin
  if v_uid is null or p_lat is null or p_lng is null then
    return false;
  end if;
  if not exists (select 1 from public.promo_codes c
                  where c.active and c.show_in_app and c.auto_apply and c.applies_to = 'pickup'
                    and jsonb_array_length(c.regions) > 0) then
    return false;
  end if;
  v_pick := public.promo_places(p_lat, p_lng);
  v_tz := public.promo_tz(p_lat, p_lng);
  return exists (
    select 1 from public.promo_codes c
     where c.active and c.show_in_app and c.auto_apply and c.applies_to = 'pickup'
       and jsonb_array_length(c.regions) > 0
       and public.promo_reason(c, v_uid, now(), v_tz, v_pick, null, false, null, null) is null);
end;
$$;
revoke execute on function public.promo_zone_here(double precision, double precision) from public, anon;
grant execute on function public.promo_zone_here(double precision, double precision) to authenticated;

-- ---- The ride ----------------------------------------------------------------------------------
-- A ride's code checked against the ride: {reason} or {code, estimate}.
create or replace function public.promo_ride_quote(
  p_code_id uuid,
  p_rider uuid,
  p_tz text,
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_drop_lat double precision,
  p_drop_lng double precision,
  p_service text,
  p_fare numeric
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c public.promo_codes;
  v_reason text;
begin
  -- Called by the booking trigger as the app's role: only about the caller's own ride.
  if auth.uid() is not null and p_rider is distinct from auth.uid() then
    return jsonb_build_object('reason', 'not_for_you');
  end if;
  select * into c from public.promo_codes where id = p_code_id;
  if not found then
    return jsonb_build_object('reason', 'not_found');
  end if;
  v_reason := public.promo_reason(
    c, p_rider, now(), coalesce(p_tz, public.promo_tz(p_pickup_lat, p_pickup_lng)),
    public.promo_places(p_pickup_lat, p_pickup_lng), public.promo_places(p_drop_lat, p_drop_lng),
    true, coalesce(p_service, ''), p_fare);
  if v_reason is not null then
    return jsonb_build_object('reason', v_reason);
  end if;
  return jsonb_build_object('code', c.code, 'estimate', public.promo_amount(c, p_fare));
end;
$$;
-- The booking trigger runs as the app's role, so the app may call it; it
-- answers only about the caller's own ride and a code id it was given.
revoke execute on function public.promo_ride_quote(uuid, uuid, text, double precision, double precision,
  double precision, double precision, text, numeric) from public, anon;
grant execute on function public.promo_ride_quote(uuid, uuid, text, double precision, double precision,
  double precision, double precision, text, numeric) to authenticated;

-- The estimate of a ride's code on a new fare (null: the code is gone).
create or replace function public.promo_ride_estimate(p_code_id uuid, p_fare numeric)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select public.promo_amount(c, p_fare) from public.promo_codes c where c.id = p_code_id;
$$;
revoke execute on function public.promo_ride_estimate(uuid, numeric) from public, anon;
grant execute on function public.promo_ride_estimate(uuid, numeric) to authenticated;

-- At booking the code is checked again against the ride itself; while the
-- request is open the estimate follows the fare. The rest is the server's.
-- Not SECURITY DEFINER: it tells the apps (client roles) from the server.
create or replace function public.ride_requests_promo_guard()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_client boolean := current_user in ('anon', 'authenticated') and not public.caller_is_admin();
  v_quote jsonb;
  v_fare numeric;
begin
  if tg_op = 'INSERT' then
    new.promo_code := null;
    new.promo_estimate := null;
    new.promo_discount := null;
    new.promo_payable := null;
    new.promo_settled_at := null;
    new.promo_error := null;
    if new.promo_code_id is null then
      return new;
    end if;
    v_fare := round(coalesce(new.ride_fare, new.fare), 2);
    begin
      v_quote := public.promo_ride_quote(new.promo_code_id, new.rider_id, new.timezone,
                                         new.pickup_lat, new.pickup_lng, new.drop_lat, new.drop_lng,
                                         new.service, v_fare);
    exception when others then
      v_quote := jsonb_build_object('reason', 'check_failed');
    end;
    if v_quote ? 'reason' then
      -- The booking goes ahead without the code.
      new.promo_code_id := null;
      new.promo_error := v_quote->>'reason';
    else
      new.promo_code := v_quote->>'code';
      new.promo_estimate := (v_quote->>'estimate')::numeric;
    end if;
    return new;
  end if;

  if v_client
     and (new.promo_code_id, new.promo_code, new.promo_estimate, new.promo_discount,
          new.promo_payable, new.promo_settled_at, new.promo_error)
         is distinct from
         (old.promo_code_id, old.promo_code, old.promo_estimate, old.promo_discount,
          old.promo_payable, old.promo_settled_at, old.promo_error) then
    raise exception 'RIDE_SERVER_ONLY' using errcode = '42501', hint = 'The promo on a ride is the server''s.';
  end if;

  if new.promo_code_id is not null and old.status = 'open'
     and (new.fare, new.ride_fare) is distinct from (old.fare, old.ride_fare) then
    new.promo_estimate := coalesce(
      public.promo_ride_estimate(new.promo_code_id, round(coalesce(new.ride_fare, new.fare), 2)),
      new.promo_estimate);
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_promo_guard() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_d_promo on public.ride_requests;
create trigger trg_ride_requests_d_promo
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_promo_guard();

-- What is left to pay (0142): less the promo the trip was settled with.
create or replace function public.ride_left_to_pay(r public.ride_requests)
returns numeric
language sql
stable
set search_path = public
as $$
  select greatest(0, round(public.ride_amount_due(r) - coalesce(r.fare_coins_value, 0)
                           - coalesce(r.promo_discount, 0), 2));
$$;

-- ---- Settlement ---------------------------------------------------------------------------------
-- {settled, discount, payable} or {settled: false, reason}. Once per ride.
create or replace function public.promo_settle_ride(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  c public.promo_codes;
  v_fare numeric;
  v_discount numeric;
  v_payable numeric;
  v_reason text;
  v_red uuid;
  v_tx uuid;
  v_money text;
begin
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.promo_code_id is null or r.promo_settled_at is not null then
    return jsonb_build_object('settled', false, 'reason', 'nothing');
  end if;
  if r.status <> 'completed' then
    return jsonb_build_object('settled', false, 'reason', 'not_completed');
  end if;

  v_fare := round(coalesce(r.ride_fare, r.fare, 0), 2);
  if r.ended_early_at is not null then
    v_reason := 'ended_early';
  elsif r.partner_id is null then
    v_reason := 'no_driver';
  elsif not public.ride_money_ok(v_fare) or v_fare <= 0 then
    v_reason := 'no_fare';
  end if;

  if v_reason is null then
    -- The code's row lock: trips completing together take turns here.
    select * into c from public.promo_codes where id = r.promo_code_id for update;
    if not found or not c.active then
      v_reason := 'inactive';
    elsif c.max_uses is not null and c.uses_count >= c.max_uses then
      v_reason := 'used_up';
    elsif c.budget is not null and c.discount_total >= c.budget then
      v_reason := 'used_up';
    elsif c.max_uses_per_rider is not null and (
            select count(*) from public.promo_redemptions x
             where x.code_id = c.id and x.rider_id = r.rider_id) >= c.max_uses_per_rider then
      v_reason := 'used_by_you';
    elsif c.min_fare is not null and v_fare < c.min_fare then
      v_reason := 'min_fare';
    elsif c.first_ride_only and exists (
            select 1 from public.ride_requests x
             where x.rider_id = r.rider_id and x.status = 'completed' and x.id <> r.id
               and x.completed_at <= coalesce(r.completed_at, now())) then
      v_reason := 'first_ride_only';
    end if;
  end if;

  if v_reason is null then
    v_discount := public.promo_amount(c, v_fare);
    if v_discount <= 0 then
      v_reason := 'used_up';
    end if;
  end if;

  if v_reason is not null then
    update public.ride_requests
       set promo_discount = 0, promo_payable = null, promo_settled_at = now(), promo_error = v_reason
     where id = r.id;
    return jsonb_build_object('settled', false, 'reason', v_reason);
  end if;

  v_payable := greatest(0, round(public.ride_amount_due(r) - coalesce(r.fare_coins_value, 0) - v_discount, 2));

  insert into public.promo_redemptions (ride_id, code_id, code, rider_id, driver_id, fare, discount, payable, driver_credit)
  values (r.id, c.id, c.code, r.rider_id, r.partner_id, v_fare, v_discount, v_payable, v_discount)
  on conflict (ride_id) do nothing
  returning id into v_red;
  if v_red is null then
    return jsonb_build_object('settled', false, 'reason', 'already');
  end if;

  -- The driver has the discount from the platform; ledger-driven, once per ride.
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
  values (r.partner_id, 'get_wallet', 'promo_credit', v_discount, 'promo',
          'Promo ' || c.code || ' on a ride — RM' || to_char(v_discount, 'FM999999990.00'), r.id)
  on conflict (ride_id) where kind = 'promo_credit' do nothing
  returning id into v_tx;
  update public.promo_redemptions set wallet_tx_id = v_tx where id = v_red;

  update public.promo_codes
     set uses_count = uses_count + 1,
         discount_total = discount_total + v_discount
   where id = c.id;

  update public.ride_requests
     set promo_discount = v_discount, promo_payable = v_payable, promo_settled_at = now(), promo_error = null
     where id = r.id;

  v_money := 'Promo ' || c.code || ' saved you RM' || to_char(v_discount, 'FM999999990.00')
             || ' · you paid RM' || to_char(v_payable, 'FM999999990.00');
  begin
    perform public.enqueue_notification(
      r.rider_id, r.id || ':promo', 'promo', 'normal', 'Promo applied', v_money,
      jsonb_build_object('type', 'promo', 'request_id', r.id, 'status', 'completed', 'role', 'rider',
                         'code', c.code, 'discount', v_discount, 'payable', v_payable),
      r.id);
  exception when others then
    raise warning 'ride % promo notice not sent: %', r.id, sqlerrm;
  end;

  return jsonb_build_object('settled', true, 'discount', v_discount, 'payable', v_payable);
end;
$$;
revoke execute on function public.promo_settle_ride(uuid) from public, anon, authenticated;

create or replace function public.ride_requests_promo_settle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.promo_code_id is null then
    return null;
  end if;
  -- Never holds up the completion: a failure leaves the trip without a promo.
  begin
    perform public.promo_settle_ride(new.id);
  exception when others then
    raise warning 'ride % promo not settled: %', new.id, sqlerrm;
    begin
      update public.ride_requests
         set promo_discount = 0, promo_payable = null, promo_settled_at = now(),
             promo_error = left('failed: ' || sqlerrm, 300)
       where id = new.id and promo_settled_at is null;
    exception when others then
      null;
    end;
  end;
  return null;
end;
$$;
revoke execute on function public.ride_requests_promo_settle() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_promo_settle on public.ride_requests;
create trigger trg_ride_requests_promo_settle
  after update of status on public.ride_requests
  for each row
  when (new.status = 'completed' and old.status is distinct from 'completed')
  execute function public.ride_requests_promo_settle();

-- ---- Admin: what a code has given ---------------------------------------------------------------
create or replace function public.admin_promo_redemption_stats()
returns table (code_id uuid, uses bigint, discount numeric, last_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select r.code_id, count(*), coalesce(sum(r.discount), 0), max(r.created_at)
    from public.promo_redemptions r
   where public.promo_caller_is_admin()
   group by r.code_id;
$$;
revoke execute on function public.admin_promo_redemption_stats() from public, anon;
grant execute on function public.admin_promo_redemption_stats() to authenticated;

-- ---- The codes kept in settings_entries until now ------------------------------------------------
with moved as (
  select e.id,
         upper(regexp_replace(btrim(coalesce(e."values"->>'code', '')), '[^A-Za-z0-9_-]', '', 'g')) as code,
         nullif(btrim(coalesce(e."values"->>'description', '')), '') as description,
         case when btrim(coalesce(e."values"->>'discount', '')) ~ '^[0-9]+(\.[0-9]+)?$'
              then round((btrim(e."values"->>'discount'))::numeric, 2) end as discount,
         case when btrim(coalesce(e."values"->>'maxUses', '')) ~ '^[0-9]{1,9}$'
              then (btrim(e."values"->>'maxUses'))::integer end as max_uses,
         case when lower(coalesce(e."values"->>'active', '')) in ('true', 'false')
              then (e."values"->>'active')::boolean else e.active end as active,
         e."values" as legacy
    from public.settings_entries e
   where e.category = 'promocode-list'
),
ins as (
  insert into public.promo_codes (code, description, active, discount_type, discount_value, max_uses, legacy)
  select m.code, left(m.description, 200), m.active, 'fixed', m.discount,
         case when m.max_uses > 0 then m.max_uses end,
         m.legacy || jsonb_build_object('settings_entry_id', m.id)
    from moved m
   where m.code ~ '^[A-Z0-9_-]{2,32}$' and m.discount > 0
  on conflict (code) do nothing
  returning legacy->>'settings_entry_id' as entry_id
)
delete from public.settings_entries e
 using ins
 where e.category = 'promocode-list' and e.id::text = ins.entry_id;

notify pgrst, 'reload schema';
