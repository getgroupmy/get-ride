-- ============================================================================
-- 0218 — Commission settings and tiers (commission phase 2a)
--
-- Admin → Commission gains Settings and Tiers:
--
--   * GET.credit below zero: allowed (as today), allowed down to a limit, or
--     not allowed. A driver under the floor can't go online, offer on or take
--     a trip until they top up; a trip they are already on finishes and is
--     charged as usual.
--   * What commission is charged on: the fare (as today), plus each surcharge
--     the admin ticks by name, plus tolls and other charges if ticked. Taxes
--     and GET.ride's own fees are never in it.
--   * Tiers: as many as wanted, each on or off. A tier asks for trips, fare
--     earnings or online hours over the last 7 or 30 days, or a rating, and
--     gives a lower rate: a set rate ("at most 10%") or points off ("2% off").
--     Of the tiers a driver meets, the lowest rate wins. A driver's personal
--     rate (level "user") is left as the admin set it.
--   * Meter / TEKSI trips: the switch is stored here; those trips are only on
--     the driver's phone today, so charging them comes with their upload
--     (phase 2b).
--
-- The tier and the rate before it are locked with the rate when the driver
-- accepts (0216), so a tier reached mid-trip does not change that trip.
-- Defaults keep today's behaviour.
-- ============================================================================

-- ---- Settings ----------------------------------------------------------------------------------
insert into public.app_settings (key, value) values ('commission', jsonb_build_object(
  'allowNegativeCredit', true,
  'negativeLimit', 0,
  'baseSurcharges', '[]'::jsonb,
  'baseTolls', false,
  'baseOtherCharges', false,
  'meterCommission', false))
on conflict (key) do nothing;

create or replace function public.commission_config_clean(p jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object(
    'allowNegativeCredit', coalesce(p->'allowNegativeCredit' <> 'false'::jsonb, true),
    'negativeLimit', case when jsonb_typeof(p->'negativeLimit') = 'number'
                          then least(100000, greatest(0, round((p->>'negativeLimit')::numeric, 2))) else 0 end,
    'baseSurcharges', coalesce((
      select jsonb_agg(distinct btrim(n)) from jsonb_array_elements_text(
        case when jsonb_typeof(p->'baseSurcharges') = 'array' then p->'baseSurcharges' else '[]' end) n
       where btrim(n) <> '' and length(n) <= 80), '[]'::jsonb),
    'baseTolls', coalesce(p->'baseTolls' = 'true'::jsonb, false),
    'baseOtherCharges', coalesce(p->'baseOtherCharges' = 'true'::jsonb, false),
    'meterCommission', coalesce(p->'meterCommission' = 'true'::jsonb, false));
$$;

-- Read by the admin page and the driver app (the floor, for "top up to drive").
create or replace function public.commission_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.commission_config_clean(coalesce((select value from public.app_settings where key = 'commission'), '{}'));
$$;
revoke execute on function public.commission_config() from public, anon;
grant execute on function public.commission_config() to authenticated;

create or replace function public.set_commission_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := public.commission_config_clean(coalesce(p_config, '{}'));
begin
  if not public.commission_caller_can_edit() then
    raise exception 'Only an admin with edit rights can change commission.' using errcode = '42501';
  end if;
  insert into public.app_settings (key, value, updated_at) values ('commission', v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return v;
end;
$$;
revoke execute on function public.set_commission_config(jsonb) from public, anon;
grant execute on function public.set_commission_config(jsonb) to authenticated;

-- ---- The GET.credit floor ---------------------------------------------------------------------
-- The lowest balance a driver may take work at: 0 when going below zero is
-- not allowed, minus the limit when there is one, null when there is none.
create or replace function public.commission_credit_floor()
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case
           when not (c->>'allowNegativeCredit')::boolean then 0::numeric
           when (c->>'negativeLimit')::numeric > 0 then -(c->>'negativeLimit')::numeric
         end
    from (select public.commission_config() c) s;
$$;
revoke execute on function public.commission_credit_floor() from public, anon;
grant execute on function public.commission_credit_floor() to authenticated;

create or replace function public.commission_credit_ok(p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select f is null
      or coalesce((select balance from public.wallets where user_id = p_uid and wallet_type = 'get_credit'), 0) >= f
    from (select public.commission_credit_floor() f) s;
$$;
-- The claim guard runs as the caller and asks this; it says only whether a driver may take work.
revoke execute on function public.commission_credit_ok(uuid) from public, anon;
grant execute on function public.commission_credit_ok(uuid) to authenticated;

-- The signed-in driver's standing: may they take work, their balance, the floor.
create or replace function public.partner_credit_status()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'ok', public.commission_credit_ok(auth.uid()),
    'balance', coalesce((select balance from public.wallets where user_id = auth.uid() and wallet_type = 'get_credit'), 0),
    'floor', public.commission_credit_floor());
$$;
revoke execute on function public.partner_credit_status() from public, anon;
grant execute on function public.partner_credit_status() to authenticated;

-- Offering on or taking a trip (the app sets partner_id) under the floor is refused.
-- Admins and the server's own functions (handover, scheduled assignment) are not held up.
-- Runs as the caller (not security definer), so current_user tells the apps apart.
create or replace function public.ride_requests_guard_credit()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.partner_id is null
     or (tg_op = 'UPDATE' and new.partner_id is not distinct from old.partner_id)
     or current_user not in ('anon', 'authenticated')
     or public.caller_is_admin() then
    return new;
  end if;
  if not public.commission_credit_ok(new.partner_id) then
    if auth.uid() is distinct from new.partner_id then
      -- A rider booking a driver directly (GET.now, My Ride).
      raise exception 'DRIVER_UNAVAILABLE' using errcode = 'P0001',
        hint = 'This driver can''t take trips right now. Please book another driver.';
    end if;
    raise exception 'GET_CREDIT_TOO_LOW' using errcode = 'P0001',
      hint = case when public.commission_credit_floor() = 0
                  then 'Your GET.credit is below zero. Top up to take trips again.'
                  else 'Your GET.credit is below RM ' || to_char(public.commission_credit_floor(), 'FM999990.00')
                       || '. Top up to take trips again.' end;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_guard_credit() from public, anon, authenticated;

-- Runs with the claim guard, before the commission lock.
drop trigger if exists trg_ride_requests_a_guard_credit on public.ride_requests;
create trigger trg_ride_requests_a_guard_credit
  before insert or update of partner_id on public.ride_requests
  for each row execute function public.ride_requests_guard_credit();

-- Under the floor, going online is kept offline (the app reads partner_credit_status to say why).
create or replace function public.driver_presence_guard_credit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.online and not public.commission_credit_ok(new.profile_id) then
    new.online := false;
  end if;
  return new;
end;
$$;
revoke execute on function public.driver_presence_guard_credit() from public, anon, authenticated;

drop trigger if exists trg_driver_presence_guard_credit on public.driver_presence;
create trigger trg_driver_presence_guard_credit
  before insert or update on public.driver_presence
  for each row execute function public.driver_presence_guard_credit();

-- ---- What commission is charged on ------------------------------------------------------------
-- The fare, plus the surcharges ticked by name, plus tolls and other charges
-- if ticked. Surcharges are worked out as the statement does (0201).
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
  f numeric := round(coalesce(r.ride_fare, r.fare, 0), 2);
  total numeric := f;
  c jsonb;
  v numeric;
begin
  if jsonb_typeof(r.charges) = 'array' and cardinality(names) > 0 then
    for c in select value from jsonb_array_elements(r.charges) loop
      v := case when jsonb_typeof(c->'value') = 'number' then (c->>'value')::numeric end;
      continue when v is null or v <= 0 or c->>'kind' = 'tax' or (c->>'platform')::boolean is true
                 or not (btrim(coalesce(c->>'name', '')) = any(names));
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

-- ---- Tiers ------------------------------------------------------------------------------------
create table if not exists public.commission_tiers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(btrim(name)) between 1 and 80),
  active      boolean not null default true,
  -- trips | earnings | online_hours (over the window), rating (now)
  metric      text not null check (metric in ('trips', 'earnings', 'online_hours', 'rating')),
  window_days integer not null default 7 check (window_days in (7, 30)),
  threshold   numeric(12,2) not null check (threshold >= 0),
  -- rate: the rate is at most `value`; minus: `value` comes off the rate
  adjust      text not null check (adjust in ('rate', 'minus')),
  value       numeric(6,4) not null check (value >= 0 and value < 1),
  note        text check (note is null or length(note) <= 300),
  position    integer not null default 0,
  created_by  uuid,
  updated_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

alter table public.commission_tiers enable row level security;
revoke all on public.commission_tiers from anon;
grant select, insert, update, delete on public.commission_tiers to authenticated;

drop policy if exists "commission_tiers read" on public.commission_tiers;
create policy "commission_tiers read"
  on public.commission_tiers for select to authenticated
  using (true);
drop policy if exists "commission_tiers admin insert" on public.commission_tiers;
create policy "commission_tiers admin insert"
  on public.commission_tiers for insert to authenticated
  with check ((select public.commission_caller_can_edit()));
drop policy if exists "commission_tiers admin update" on public.commission_tiers;
create policy "commission_tiers admin update"
  on public.commission_tiers for update to authenticated
  using ((select public.commission_caller_can_edit()))
  with check ((select public.commission_caller_can_edit()));
drop policy if exists "commission_tiers admin delete" on public.commission_tiers;
create policy "commission_tiers admin delete"
  on public.commission_tiers for delete to authenticated
  using ((select public.commission_caller_can_edit()));

-- The Commission page follows tier changes live.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and tablename = 'commission_tiers') then
    alter publication supabase_realtime add table public.commission_tiers;
  end if;
end $$;

create or replace function public.commission_tiers_stamp()
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
  return new;
end;
$$;
drop trigger if exists trg_commission_tiers_stamp on public.commission_tiers;
create trigger trg_commission_tiers_stamp
  before insert or update on public.commission_tiers
  for each row execute function public.commission_tiers_stamp();

-- Tier changes go in the same history as rates (0216), marked by op 'tier:<op>'.
alter table public.commission_rate_history drop constraint if exists commission_rate_history_op_check;
alter table public.commission_rate_history add constraint commission_rate_history_op_check
  check (op in ('insert', 'update', 'delete', 'tier:insert', 'tier:update', 'tier:delete'));
create or replace function public.commission_tiers_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.commission_rate_history (rate_id, op, old_row, new_row, changed_by)
  values (coalesce(new.id, old.id), 'tier:' || lower(tg_op),
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end,
          auth.uid());
  return null;
end;
$$;
revoke execute on function public.commission_tiers_history() from public, anon, authenticated;
drop trigger if exists trg_commission_tiers_history on public.commission_tiers;
create trigger trg_commission_tiers_history
  after insert or update or delete on public.commission_tiers
  for each row execute function public.commission_tiers_history();

-- What a driver has done: trips, fare earnings or online hours over the last
-- p_days, or their rating.
create or replace function public.commission_tier_measure(p_uid uuid, p_metric text, p_days integer)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case p_metric
    when 'trips' then (select count(*)::numeric from public.ride_requests
                        where partner_id = p_uid and status = 'completed'
                          and completed_at >= now() - make_interval(days => p_days))
    when 'earnings' then (select coalesce(sum(coalesce(ride_fare, fare, 0)), 0) from public.ride_requests
                           where partner_id = p_uid and status = 'completed'
                             and completed_at >= now() - make_interval(days => p_days))
    when 'online_hours' then public.partner_online_hours(p_uid, now() - make_interval(days => p_days), now())
    when 'rating' then (select coalesce(max(rating), 0) from public.partners where auth_user_id = p_uid)
  end;
$$;
revoke execute on function public.commission_tier_measure(uuid, text, integer) from public, anon, authenticated;

-- The lowest rate the driver's tiers give on [p_rate], and the tier that gave it
-- (null: none applies). A personal rate is not lowered.
create or replace function public.commission_apply_tiers(p_uid uuid, p_rate numeric, p_level text)
returns table (rate numeric, tier_id uuid)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  t record;
  best numeric := p_rate;
  best_tier uuid;
  r numeric;
  m numeric;
begin
  if p_uid is null or p_rate is null or p_level = 'user' then
    return query select p_rate, null::uuid;
    return;
  end if;
  for t in select * from public.commission_tiers where active order by position, created_at, id loop
    m := public.commission_tier_measure(p_uid, t.metric, t.window_days);
    continue when m is null or m < t.threshold;
    r := case t.adjust when 'rate' then least(p_rate, t.value) else greatest(0, p_rate - t.value) end;
    if r < best then
      best := r;
      best_tier := t.id;
    end if;
  end loop;
  return query select round(best, 4), best_tier;
end;
$$;
revoke execute on function public.commission_apply_tiers(uuid, numeric, text) from public, anon, authenticated;

alter table public.ride_requests
  add column if not exists commission_tier_id uuid,
  add column if not exists commission_base_rate numeric(6,4),
  add column if not exists commission_base_amount numeric(12,2);

-- ---- The lock (0216) with tiers -----------------------------------------------------------------
create or replace function public.ride_requests_lock_commission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v record;
  t record;
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
    new.commission_base_rate := v.rate;
    new.commission_rate := t.rate;
    new.commission_tier_id := t.tier_id;
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

-- ---- Charging (0216) on the chosen base, with tiers --------------------------------------------
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
  v_amount numeric(12,2);
  v record;
  t record;
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
  else
    select * into v from public.commission_resolve(
      r.partner_id, r.pickup_lat, r.pickup_lng, r.country, r.state, r.city, r.suburb);
    select * into t from public.commission_apply_tiers(r.partner_id, v.rate, v.level);
    v_rate := t.rate;
    v_rule := v.rule_id;
    v_tier := t.tier_id;
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
         commission_base_amount = v_base,
         commission_amount = v_amount,
         commission_charged_at = now(),
         commission_error = null
   where id = p_ride;
end;
$$;
revoke all on function public.ride_charge_commission(uuid) from public, anon, authenticated, service_role;

-- What a driver would pay now, for the admin's "check a driver" (rate, tier, measures).
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
begin
  if not public.caller_is_admin() then
    raise exception 'Admins only.' using errcode = '42501';
  end if;
  select * into v from public.commission_resolve(p_partner, null, null, p_country, p_state, p_city, null);
  select * into t from public.commission_apply_tiers(p_partner, v.rate, v.level);
  return jsonb_build_object(
    'baseRate', v.rate, 'level', v.level, 'ruleId', v.rule_id, 'rate', t.rate, 'tierId', t.tier_id,
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
