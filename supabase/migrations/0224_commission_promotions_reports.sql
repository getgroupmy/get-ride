-- ============================================================================
-- 0224 — Commission promotions and reports (commission phases 3 and 4), and
-- meter trips on statements and the Earnings page
--
-- Promotions (Admin → Commission → Promotions): a lower rate for a time.
--   * Each has a name, a rate (0% allowed), when it runs (from / to), and may
--     be narrowed to a country, state or city (matched as rates are, 0216),
--     to services (the trip's service by name; "meter" for meter / TEKSI
--     hires), to days of the week and a time of day (the ride's own time
--     zone, else Malaysia's; a window like 22:00–06:00 runs past midnight),
--     and to new drivers: the first N days since they joined. Each can be
--     turned off.
--   * When the driver accepts, the rate after tiers (0218) and every running
--     promotion that fits the trip are compared and the lowest wins; the
--     trip records which promotion gave it (commission_promotion_id), and
--     then no tier. A promotion only ever lowers the rate: one at or above
--     it is ignored, and a tie stays with the tier.
--   * As with tiers, a driver's personal rate (level "user") is left as the
--     admin set it: no promotion lowers it.
--   * Meter / TEKSI hires (0219) get the same, timed at when the hire began.
--
-- Reports (Admin → Commission → Reports): commission charged between two
-- moments, by day, week or month (Malaysia), by country, state or city (the
-- trip's; a meter hire's from where it began, now stored on it), or by
-- driver, from trips and meter hires together; and the drivers whose
-- GET.credit is under the floor (0218). Admins who may read the Commission
-- page only.
--
-- Statements and Earnings (0201): a driver's own meter hires count with
-- their trips, on the day they ended: the fare, the airport and bags &
-- passengers surcharges (earnings when ticked as such on Partner statements,
-- else collected for others, like a trip's), tolls & charges as tolls, the
-- commission, and the whole as cash (a street hail is paid to the driver).
-- totals.meterTrips says how many of the trips were meter hires; the weekly
-- trip list marks them kind "meter". Both are left out where there are
-- none, so a statement without meter hires reads exactly as before and a
-- kept final copy is not marked Revised.
-- ============================================================================

-- ---- Promotions ---------------------------------------------------------------------------------
create table if not exists public.commission_promotions (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (length(btrim(name)) between 1 and 80),
  active          boolean not null default true,
  rate            numeric(6,4) not null check (rate >= 0 and rate < 1),
  starts_at       timestamptz not null,
  ends_at         timestamptz not null,
  country         text check (country is null or length(country) <= 120),
  state           text check (state is null or length(state) <= 120),
  city            text check (city is null or length(city) <= 120),
  -- Service names (any case); 'meter' for meter / TEKSI hires. Empty or null: every service.
  services        text[] check (services is null or cardinality(services) <= 30),
  -- ISO days, 1 Monday … 7 Sunday. Empty or null: every day.
  weekdays        smallint[] check (weekdays is null or weekdays <@ array[1, 2, 3, 4, 5, 6, 7]::smallint[]),
  -- Time of day, local to the ride; both or neither. from > to runs past midnight.
  time_from       time,
  time_to         time,
  -- Only the first N days since the driver joined.
  new_driver_days integer check (new_driver_days is null or new_driver_days between 1 and 3650),
  note            text check (note is null or length(note) <= 300),
  created_by      uuid,
  updated_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (ends_at > starts_at),
  check ((time_from is null) = (time_to is null) and (time_from is null or time_from <> time_to))
);

create index if not exists commission_promotions_window_idx on public.commission_promotions (starts_at, ends_at) where active;

alter table public.commission_promotions enable row level security;
revoke all on public.commission_promotions from anon;
grant select, insert, update, delete on public.commission_promotions to authenticated;

drop policy if exists "commission_promotions admin read" on public.commission_promotions;
create policy "commission_promotions admin read"
  on public.commission_promotions for select to authenticated
  using ((select public.caller_is_admin()));
drop policy if exists "commission_promotions admin insert" on public.commission_promotions;
create policy "commission_promotions admin insert"
  on public.commission_promotions for insert to authenticated
  with check (public.admin_can_edit((select auth.uid()), 'admin-settings-commission'));
drop policy if exists "commission_promotions admin update" on public.commission_promotions;
create policy "commission_promotions admin update"
  on public.commission_promotions for update to authenticated
  using (public.admin_can_edit((select auth.uid()), 'admin-settings-commission'))
  with check (public.admin_can_edit((select auth.uid()), 'admin-settings-commission'));
drop policy if exists "commission_promotions admin delete" on public.commission_promotions;
create policy "commission_promotions admin delete"
  on public.commission_promotions for delete to authenticated
  using (public.admin_can_edit((select auth.uid()), 'admin-settings-commission'));

-- The Commission page follows promotion changes live.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and tablename = 'commission_promotions') then
    alter publication supabase_realtime add table public.commission_promotions;
  end if;
end $$;

create or replace function public.commission_promotions_stamp()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, auth.uid());
  end if;
  -- Blank places are no place; a blank or empty list is every service / day.
  new.country := nullif(btrim(new.country), '');
  new.state := nullif(btrim(new.state), '');
  new.city := nullif(btrim(new.city), '');
  new.services := nullif(array(select distinct lower(btrim(s)) from unnest(coalesce(new.services, '{}')) s
                                where btrim(s) <> '' order by 1), '{}');
  new.weekdays := nullif(array(select distinct d from unnest(coalesce(new.weekdays, '{}')) d order by 1), '{}');
  return new;
end;
$$;
drop trigger if exists trg_commission_promotions_stamp on public.commission_promotions;
create trigger trg_commission_promotions_stamp
  before insert or update on public.commission_promotions
  for each row execute function public.commission_promotions_stamp();

-- Promotion changes go in the commission history (0216), marked 'promo:<op>'.
alter table public.commission_rate_history drop constraint if exists commission_rate_history_op_check;
alter table public.commission_rate_history add constraint commission_rate_history_op_check
  check (op in ('insert', 'update', 'delete', 'tier:insert', 'tier:update', 'tier:delete',
                'promo:insert', 'promo:update', 'promo:delete'));
create or replace function public.commission_promotions_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.commission_rate_history (rate_id, op, old_row, new_row, changed_by)
  values (coalesce(new.id, old.id), 'promo:' || lower(tg_op),
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end,
          auth.uid());
  return null;
end;
$$;
revoke execute on function public.commission_promotions_history() from public, anon, authenticated;
drop trigger if exists trg_commission_promotions_history on public.commission_promotions;
create trigger trg_commission_promotions_history
  after insert or update or delete on public.commission_promotions
  for each row execute function public.commission_promotions_history();

-- Service names seen on trips over the last year, for the promotion's service filter.
create or replace function public.commission_service_names()
returns table (name text, trips bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select lower(btrim(r.service)), count(*)
      from public.ride_requests r
     where r.created_at > now() - interval '365 days' and btrim(coalesce(r.service, '')) <> ''
     group by 1 order by 2 desc, 1 limit 100;
end;
$$;
revoke execute on function public.commission_service_names() from public, anon;
grant execute on function public.commission_service_names() to authenticated;

-- ---- Where a trip is ----------------------------------------------------------------------------
-- The places a pickup is in, as commission_resolve (0216) finds them: the
-- smallest mapped outline holding the point at each level, else the names given.
create or replace function public.commission_places(
  p_lat double precision,
  p_lng double precision,
  p_country text default null,
  p_state text default null,
  p_city text default null,
  p_suburb text default null
)
returns table (place_country text, place_state text, place_city text, place_suburb text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_country text := nullif(btrim(p_country), '');
  v_state text := nullif(btrim(p_state), '');
  v_city text := nullif(btrim(p_city), '');
  v_suburb text := nullif(btrim(p_suburb), '');
  g record;
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
  return query select v_country, v_state, v_city, v_suburb;
end;
$$;
revoke execute on function public.commission_places(double precision, double precision, text, text, text, text)
  from public, anon, authenticated;

-- ---- Which promotion applies ----------------------------------------------------------------------
-- The lowest of [p_rate] (the rate after tiers) and the running promotions
-- that fit a trip by [p_uid] at [p_at], and the promotion that gave it (null:
-- none is lower). A personal rate (level 'user') is not lowered.
create or replace function public.commission_apply_promotions(
  p_uid uuid,
  p_rate numeric,
  p_level text,
  p_at timestamptz,
  p_tz text,
  p_service text,
  p_lat double precision default null,
  p_lng double precision default null,
  p_country text default null,
  p_state text default null,
  p_city text default null,
  p_suburb text default null
)
returns table (rate numeric, promotion_id uuid)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_at timestamptz := coalesce(p_at, now());
  v_local timestamp;
  v_day integer;
  v_time time;
  v_joined timestamptz;
  v_service text := lower(btrim(coalesce(p_service, '')));
  pl record;
  best record;
begin
  if p_rate is null or p_level = 'user' then
    return query select p_rate, null::uuid;
    return;
  end if;
  -- The ride's own clock; a name the database doesn't know falls back to Malaysia's.
  begin
    v_local := v_at at time zone coalesce(nullif(btrim(p_tz), ''), 'Asia/Kuala_Lumpur');
  exception when others then
    v_local := v_at at time zone 'Asia/Kuala_Lumpur';
  end;
  v_day := extract(isodow from v_local)::int;
  v_time := v_local::time;
  select * into pl from public.commission_places(p_lat, p_lng, p_country, p_state, p_city, p_suburb);
  if p_uid is not null then
    select min(coalesce(pt.joined_at, pt.created_at)) into v_joined from public.partners pt where pt.auth_user_id = p_uid;
  end if;

  select c.id, c.rate as promo_rate into best
    from public.commission_promotions c
   where c.active
     and c.starts_at <= v_at and c.ends_at > v_at
     and c.rate < p_rate
     and (c.country is null or public.commission_place_matches(c.country, pl.place_country))
     and (c.state is null or public.commission_place_matches(c.state, pl.place_state))
     and (c.city is null or public.commission_place_matches(c.city, pl.place_city))
     and (coalesce(cardinality(c.services), 0) = 0 or v_service = any(c.services))
     and (coalesce(cardinality(c.weekdays), 0) = 0 or v_day = any(c.weekdays))
     and (c.time_from is null or c.time_to is null
          or case when c.time_from < c.time_to then v_time >= c.time_from and v_time < c.time_to
                  else v_time >= c.time_from or v_time < c.time_to end)
     and (c.new_driver_days is null
          or (v_joined is not null and v_at >= v_joined and v_at < v_joined + make_interval(days => c.new_driver_days)))
   order by c.rate, c.ends_at, c.id
   limit 1;
  if found then
    return query select round(best.promo_rate, 4), best.id;
    return;
  end if;
  return query select p_rate, null::uuid;
end;
$$;
revoke execute on function public.commission_apply_promotions(uuid, numeric, text, timestamptz, text, text,
  double precision, double precision, text, text, text, text) from public, anon, authenticated;

alter table public.ride_requests add column if not exists commission_promotion_id uuid;
alter table public.meter_trips
  add column if not exists commission_promotion_id uuid,
  add column if not exists country text,
  add column if not exists state text,
  add column if not exists city text;

-- ---- The lock (0218) with promotions ------------------------------------------------------------
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
      new.partner_id, new.pickup_lat, new.pickup_lng, new.country, new.state, new.city, new.suburb);
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

-- ---- Charging (0218) with promotions ------------------------------------------------------------
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
      r.partner_id, r.pickup_lat, r.pickup_lng, r.country, r.state, r.city, r.suburb);
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

-- ---- Meter hires (0219): where they began, and promotions ---------------------------------------
-- A hire is stored with the places it began in, for the reports. Never
-- holds up the upload.
create or replace function public.meter_trips_places()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  pl record;
begin
  if new.pickup_lat is not null and new.pickup_lng is not null and new.country is null then
    begin
      select * into pl from public.commission_places(new.pickup_lat, new.pickup_lng);
      new.country := pl.place_country;
      new.state := pl.place_state;
      new.city := pl.place_city;
    exception when others then
      null;
    end;
  end if;
  return new;
end;
$$;
revoke execute on function public.meter_trips_places() from public, anon, authenticated;
drop trigger if exists trg_meter_trips_places on public.meter_trips;
create trigger trg_meter_trips_places
  before insert on public.meter_trips
  for each row execute function public.meter_trips_places();

-- Hires already sent.
do $$
declare
  m record;
  pl record;
begin
  for m in select id, pickup_lat, pickup_lng from public.meter_trips
            where country is null and pickup_lat is not null and pickup_lng is not null limit 20000 loop
    begin
      select * into pl from public.commission_places(m.pickup_lat, m.pickup_lng);
      update public.meter_trips set country = pl.place_country, state = pl.place_state, city = pl.place_city
       where id = m.id;
    exception when others then
      null;
    end;
  end loop;
end $$;

create or replace function public.meter_trip_charge_commission(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.meter_trips;
  v record;
  tr record;
  pm record;
  v_base numeric;
  v_amount numeric(12,2);
begin
  select * into t from public.meter_trips where id = p_id for update;
  if not found or t.commission_charged_at is not null then
    return;
  end if;
  v_base := public.meter_trip_commission_base(t);
  if not public.ride_money_ok(v_base) or v_base <= 0 then
    return;
  end if;
  select * into v from public.commission_resolve(t.partner_id, t.pickup_lat, t.pickup_lng, t.country, t.state, t.city, null);
  select * into tr from public.commission_apply_tiers(t.partner_id, v.rate, v.level);
  -- Timed at when the hire began; the meter has no time zone of its own.
  select * into pm from public.commission_apply_promotions(
    t.partner_id, tr.rate, v.level, t.started_at, null, 'meter',
    t.pickup_lat, t.pickup_lng, t.country, t.state, t.city, null);
  if pm.rate is null or pm.rate < 0 or pm.rate >= 1 then
    return;
  end if;
  v_amount := round(v_base * pm.rate, 2);
  if v_amount > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
    values (t.partner_id, 'get_credit', 'commission', -v_amount,
            'Meter trip commission ' || round(pm.rate * 100, 1) || '% of ' || t.currency || ' ' || v_base);
  end if;
  update public.meter_trips
     set commission_rate = pm.rate,
         commission_rule_id = v.rule_id,
         commission_tier_id = case when pm.promotion_id is null then tr.tier_id end,
         commission_promotion_id = pm.promotion_id,
         commission_base_amount = v_base,
         commission_amount = v_amount,
         commission_charged_at = now(),
         commission_error = null
   where id = p_id;
end;
$$;
revoke all on function public.meter_trip_charge_commission(uuid) from public, anon, authenticated, service_role;

-- ---- The admin's "check a driver" (0218), with the promotion ------------------------------------
create or replace function public.admin_commission_preview(p_partner uuid, p_country text, p_state text, p_city text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v record;
  t record;
  pm record;
begin
  if not public.caller_is_admin() then
    raise exception 'Admins only.' using errcode = '42501';
  end if;
  select * into v from public.commission_resolve(p_partner, null, null, p_country, p_state, p_city, null);
  select * into t from public.commission_apply_tiers(p_partner, v.rate, v.level);
  -- Now, in Malaysia's time, for a trip of no particular service.
  select * into pm from public.commission_apply_promotions(
    p_partner, t.rate, v.level, now(), null, null, null, null, p_country, p_state, p_city, null);
  return jsonb_build_object(
    'baseRate', v.rate, 'level', v.level, 'ruleId', v.rule_id,
    'tierRate', t.rate, 'tierId', case when pm.promotion_id is null then t.tier_id end,
    'rate', pm.rate, 'promotionId', pm.promotion_id,
    'promotionName', (select name from public.commission_promotions where id = pm.promotion_id),
    'creditOk', public.commission_credit_ok(p_partner),
    'trips7', public.commission_tier_measure(p_partner, 'trips', 7),
    'trips30', public.commission_tier_measure(p_partner, 'trips', 30),
    'earnings7', public.commission_tier_measure(p_partner, 'earnings', 7),
    'earnings30', public.commission_tier_measure(p_partner, 'earnings', 30),
    'rating', public.commission_tier_measure(p_partner, 'rating', 0));
end;
$$;
revoke execute on function public.admin_commission_preview(uuid, text, text, text) from public, anon;
grant execute on function public.admin_commission_preview(uuid, text, text, text) to authenticated;

-- ---- Reports ------------------------------------------------------------------------------------
-- Admins who may read the Commission page (or every page).
create or replace function public.commission_caller_can_read()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and (public.admin_can_read(auth.uid(), 'admin-settings-commission') or public.caller_is_full_admin());
$$;
revoke execute on function public.commission_caller_can_read() from public, anon;
grant execute on function public.commission_caller_can_read() to authenticated;

-- Commission charged in [p_from, p_to) on trips and meter hires, grouped by
-- p_group: day | week (Monday) | month (Malaysia's calendar), country |
-- state | city (the trip's), or driver. Periods oldest first; the rest by
-- the most commission first.
create or replace function public.admin_commission_report(p_from timestamptz, p_to timestamptz, p_group text)
returns table (group_key text, label text, detail text, trips bigint, meter_trips bigint,
               base_amount numeric, commission numeric)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  tz text := 'Asia/Kuala_Lumpur';
  v_period boolean := p_group in ('day', 'week', 'month');
begin
  if not public.commission_caller_can_read() then
    raise exception 'Only an admin who may read Commission can see its reports.' using errcode = '42501';
  end if;
  if p_group is null or p_group not in ('day', 'week', 'month', 'country', 'state', 'city', 'driver') then
    raise exception 'COMMISSION_REPORT' using errcode = '22023',
      hint = 'Group by day, week, month, country, state, city or driver.';
  end if;
  if p_from is null or p_to is null or p_to <= p_from or p_to - p_from > interval '800 days' then
    raise exception 'COMMISSION_REPORT' using errcode = '22023', hint = 'Pick a range of up to two years.';
  end if;

  return query
  with charged as (
    select r.partner_id as uid, r.commission_charged_at as c_at,
           nullif(btrim(r.country), '') as c_country, nullif(btrim(r.state), '') as c_state,
           nullif(btrim(r.city), '') as c_city, false as is_meter,
           coalesce(r.commission_base_amount, r.ride_fare, r.fare, 0)::numeric as c_base,
           coalesce(r.commission_amount, 0)::numeric as c_amount
      from public.ride_requests r
     where r.commission_charged_at >= p_from and r.commission_charged_at < p_to and r.partner_id is not null
    union all
    select m.partner_id, m.commission_charged_at,
           nullif(btrim(m.country), ''), nullif(btrim(m.state), ''), nullif(btrim(m.city), ''), true,
           coalesce(m.commission_base_amount, m.fare, 0)::numeric, coalesce(m.commission_amount, 0)::numeric
      from public.meter_trips m
     where m.commission_charged_at >= p_from and m.commission_charged_at < p_to
  ),
  keyed as (
    select case p_group
             when 'day' then to_char((c.c_at at time zone tz)::date, 'YYYY-MM-DD')
             when 'week' then to_char(date_trunc('week', c.c_at at time zone tz)::date, 'YYYY-MM-DD')
             when 'month' then to_char(date_trunc('month', c.c_at at time zone tz)::date, 'YYYY-MM-DD')
             when 'country' then lower(coalesce(c.c_country, ''))
             when 'state' then lower(coalesce(c.c_country, '') || '|' || coalesce(c.c_state, ''))
             when 'city' then lower(coalesce(c.c_country, '') || '|' || coalesce(c.c_state, '') || '|' || coalesce(c.c_city, ''))
             else c.uid::text
           end as k,
           case p_group
             when 'country' then c.c_country
             when 'state' then c.c_state
             when 'city' then c.c_city
             when 'driver' then coalesce(d.d_name, 'Unknown driver')
           end as lbl,
           case p_group
             when 'state' then c.c_country
             when 'city' then concat_ws(', ', c.c_state, c.c_country)
             when 'driver' then d.d_id
           end as det,
           c.is_meter, c.c_base, c.c_amount
      from charged c
      left join lateral (
        select coalesce(pt.name, pr.name) as d_name, pt.display_id::text as d_id
          from public.profiles pr
          left join lateral (select p.name, p.display_id from public.partners p
                              where p.auth_user_id = c.uid order by p.created_at limit 1) pt on true
         where p_group = 'driver' and pr.id = c.uid
      ) d on true
  )
  select k.k, coalesce(max(k.lbl), case when v_period then k.k end), max(k.det),
         count(*) filter (where not k.is_meter), count(*) filter (where k.is_meter),
         round(sum(k.c_base), 2), round(sum(k.c_amount), 2)
    from keyed k
   group by k.k
   order by case when v_period then k.k end, round(sum(k.c_amount), 2) desc, k.k
   limit 2000;
end;
$$;
revoke execute on function public.admin_commission_report(timestamptz, timestamptz, text) from public, anon;
grant execute on function public.admin_commission_report(timestamptz, timestamptz, text) to authenticated;

-- Drivers whose GET.credit is under the floor (0218), lowest first. None
-- while going below zero has no limit.
create or replace function public.admin_drivers_below_credit()
returns table (partner_id uuid, name text, display_id text, phone text, balance numeric, credit_floor numeric)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  f numeric := public.commission_credit_floor();
begin
  if not public.commission_caller_can_read() then
    raise exception 'Only an admin who may read Commission can see this list.' using errcode = '42501';
  end if;
  if f is null then
    return;
  end if;
  return query
    select w.user_id, coalesce(pt.p_name, pr.name), pt.p_id, pt.p_phone, w.balance::numeric, f
      from public.wallets w
      left join public.profiles pr on pr.id = w.user_id
      left join lateral (select p.name as p_name, p.display_id::text as p_id, p.phone as p_phone
                           from public.partners p where p.auth_user_id = w.user_id
                          order by p.created_at limit 1) pt on true
     where w.wallet_type = 'get_credit' and w.balance < f
     order by w.balance, w.user_id
     limit 500;
end;
$$;
revoke execute on function public.admin_drivers_below_credit() from public, anon;
grant execute on function public.admin_drivers_below_credit() to authenticated;

-- ---- Meter hires on statements and the Earnings page (0201) -------------------------------------
-- One hire's lines, keyed as a trip's (statement_ride_lines).
create or replace function public.statement_meter_lines(m public.meter_trips, p_earning text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  airport numeric := round(coalesce(m.airport_surcharge, 0), 2);
  bags numeric := round(coalesce(m.card_surcharge, 0), 2);
  s_earn numeric := 0;
  s_pass numeric := 0;
begin
  if 'Airport surcharge' = any(p_earning) then s_earn := s_earn + airport; else s_pass := s_pass + airport; end if;
  if 'Bags & passengers' = any(p_earning) then s_earn := s_earn + bags; else s_pass := s_pass + bags; end if;
  return jsonb_build_object(
    'fare', round(coalesce(m.fare, 0), 2),
    'surcharges', s_earn,
    'platformCollected', 0,
    'surchargesPass', s_pass,
    'taxes', 0,
    'tolls', round(coalesce(m.extra, 0), 2),
    'otherCharges', 0,
    'commission', round(coalesce(m.commission_amount, 0), 2),
    'platformFees', 0,
    'coins', 0,
    -- A street hail is paid to the driver.
    'cash', round(coalesce(m.total, 0), 2),
    'distanceKm', round(coalesce(m.distance_km, 0), 2));
end;
$$;
revoke execute on function public.statement_meter_lines(public.meter_trips, text[]) from public, anon, authenticated;

-- As 0201, with the partner's meter hires (by when they ended).
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

  t := t || jsonb_build_object(
    'incentives', round(w.incentives, 2),
    'handoverIn', round(w.hin, 2),
    'handoverOut', round(w.hout, 2),
    'adjustments', round(adj, 2),
    'onlineHours', public.partner_online_hours(p_uid, p_from, p_to));
  e := coalesce((t->>'fare')::numeric, 0) + coalesce((t->>'surcharges')::numeric, 0)
     + coalesce((t->>'platformCollected')::numeric, 0) + w.incentives + w.hin;
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

-- As 0201; the weekly trip list also has the meter hires, marked kind "meter".
create or replace function public.partner_statement_data(p_type text, p_start date, p_lang text default 'en')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  tz text := 'Asia/Kuala_Lumpur';
  v_status text;
  v_end date;
  v_from timestamptz;
  v_to timestamptz;
  cfg jsonb := public.partner_statement_config();
  earning text[] := array(select jsonb_array_elements_text(cfg->'earningSurcharges'));
  p record;
  bank jsonb;
  breakdown jsonb := '[]';
  weeks jsonb;
  trips jsonb := '[]';
  m date;
begin
  if v_uid is null or not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  v_status := public.statement_period_status(v_uid, p_type, p_start);
  v_end := public.statement_period_end(p_type, p_start);
  v_from := p_start::timestamp at time zone tz;
  v_to := (v_end + 1)::timestamp at time zone tz;

  select pt.name, pt.display_id::text as display_id, pt.ic, pt.plate, pt.my_ride_code
    into p from public.partners pt where pt.auth_user_id = v_uid order by pt.created_at limit 1;
  if (cfg->>'showBank')::boolean then
    select jsonb_build_object('bank', a.bank_name, 'account', '****' || right(a.account_no, 4), 'holder', a.holder_name)
      into bank from public.partner_payout_accounts a where a.profile_id = v_uid;
  end if;

  if p_type = 'weekly' then
    select coalesce(jsonb_agg(jsonb_build_object('start', d::date,
             'totals', public.partner_statement_totals(v_uid, d::timestamp at time zone tz, (d::date + 1)::timestamp at time zone tz))
             order by d), '[]') into breakdown
      from generate_series(p_start::timestamp, v_end::timestamp, interval '1 day') d;
    select coalesce(jsonb_agg(x.j order by x.at, x.meter), '[]') into trips
      from (
        select r.completed_at as at, false as meter, jsonb_build_object(
                 'at', r.completed_at, 'service', r.service, 'pickup', left(coalesce(r.pickup_address, ''), 80),
                 'drop', left(coalesce(r.drop_address, ''), 80), 'payment', coalesce(r.paid_method, r.payment_mode),
                 'lines', public.statement_ride_lines(r, earning)) as j
          from public.ride_requests r
         where r.partner_id = v_uid and r.status = 'completed' and r.completed_at >= v_from and r.completed_at < v_to
        union all
        select mt.ended_at, true, jsonb_build_object(
                 'at', mt.ended_at, 'kind', 'meter', 'service', null, 'pickup', left(coalesce(mt.pickup_place, ''), 80),
                 'drop', left(coalesce(mt.dropoff_place, mt.destination, ''), 80), 'payment', 'cash',
                 'lines', public.statement_meter_lines(mt, earning))
          from public.meter_trips mt
         where mt.partner_id = v_uid and mt.ended_at >= v_from and mt.ended_at < v_to
      ) x;
  elsif p_type = 'monthly' then
    breakdown := public.statement_weeks(v_uid, p_start, v_end);
  else
    m := p_start;
    while m <= v_end loop
      weeks := public.statement_weeks(v_uid, m, (m + interval '1 month')::date - 1);
      breakdown := breakdown || jsonb_build_array(jsonb_build_object('start', m,
        'totals', public.partner_statement_totals(v_uid, m::timestamp at time zone tz,
                                                  (m + interval '1 month')::date::timestamp at time zone tz),
        'weeks', weeks));
      m := (m + interval '1 month')::date;
    end loop;
  end if;

  return jsonb_build_object(
    'type', p_type,
    'periodStart', p_start,
    'periodEnd', v_end,
    'status', v_status,
    'lang', case when p_lang = 'ms' then 'ms' else 'en' end,
    'partner', jsonb_build_object(
      'name', p.name,
      'displayId', coalesce(p.display_id, p.my_ride_code),
      'ic', case when length(regexp_replace(coalesce(p.ic, ''), '\D', '', 'g')) >= 4
                 then '******-**-' || right(regexp_replace(p.ic, '\D', '', 'g'), 4) end,
      'plate', p.plate,
      'bank', bank),
    'company', jsonb_build_object('name', cfg->>'companyName', 'ssm', cfg->>'companySsm',
                                  'support', cfg->>'supportContact', 'verifyUrl', cfg->>'verifyUrl'),
    'weekStart', cfg->>'weekStart',
    'totals', public.partner_statement_totals(v_uid, v_from, v_to),
    'incentives', coalesce((select jsonb_agg(jsonb_build_object('at', credited_at, 'label', label, 'amount', amount)
                                             order by credited_at)
                              from public.partner_incentives
                             where profile_id = v_uid and credited_at >= v_from and credited_at < v_to), '[]'),
    'adjustments', coalesce((select jsonb_agg(jsonb_build_object('at', effective_at, 'reason', reason, 'amount', amount)
                                              order by effective_at)
                               from public.partner_adjustments
                              where profile_id = v_uid and effective_at >= v_from and effective_at < v_to), '[]'),
    'breakdown', breakdown,
    'trips', trips);
end;
$$;
revoke execute on function public.partner_statement_data(text, date, text) from public, anon;
grant execute on function public.partner_statement_data(text, date, text) to authenticated;

notify pgrst, 'reload schema';
