-- ============================================================================
-- 0216: commission foundations
--
-- Admin -> Commission charged one percentage per place or per driver, found
-- by comparing typed place names. This fixes what was wrong with it, ahead of
-- the rules engine (service, time, tiers, promotions) that builds on it:
--
-- 1. Who may read and write. Every rate, a driver's own included, was
--    readable by anyone holding the public key; any admin, view-only too,
--    could write. Now a driver-specific rate is readable by admins and by
--    that driver only (signed in), and writing needs edit access to the
--    Commission page.
-- 2. Which rate wins. Each level took its first row in no particular order,
--    so two overlapping rates could each win. Now: the more specific level,
--    then the higher priority (new), then the rule that names more of its
--    parents, then the newest -- the same every time.
-- 3. Places are matched as regions are (0126 region_name_matches): the
--    admin's region names against the geocoder's ("Kajang" in "Kajang
--    Municipal Council"), and, where the admin has mapped a region's
--    outline, by the pickup point itself (0170 regions_at, the smaller
--    holding outline winning).
-- 4. The rate is locked when the driver accepts (and again if the trip is
--    handed over), with the rule that gave it: a rate changed mid-trip no
--    longer changes that trip. Trips accepted before this charge as before.
-- 5. Every change to a rate is kept (commission_rate_history): who, when,
--    before and after, and the admin's note.
-- 6. A charge that fails is recorded on the trip (commission_error) instead
--    of only in the server log, and admins can charge every completed trip
--    still uncharged (admin_charge_uncharged_commissions). A 0% rate marks
--    the trip charged at 0 instead of leaving it looking uncharged.
-- ============================================================================

-- ---- Rate rows: priority, note, who -----------------------------------------
alter table public.commission_rates add column if not exists priority integer not null default 0;
alter table public.commission_rates add column if not exists note text;
alter table public.commission_rates add column if not exists created_by uuid;
alter table public.commission_rates add column if not exists updated_by uuid;

create or replace function public.commission_rates_stamp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, auth.uid());
  end if;
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  return new;
end;
$$;

revoke execute on function public.commission_rates_stamp() from public, anon, authenticated;

drop trigger if exists trg_commission_rates_stamp on public.commission_rates;
create trigger trg_commission_rates_stamp
  before insert or update on public.commission_rates
  for each row execute function public.commission_rates_stamp();

-- ---- History ----------------------------------------------------------------
create table if not exists public.commission_rate_history (
  id uuid primary key default gen_random_uuid(),
  rate_id uuid not null,
  op text not null check (op in ('insert', 'update', 'delete')),
  old_row jsonb,
  new_row jsonb,
  changed_by uuid,
  changed_at timestamptz not null default now()
);

create index if not exists commission_rate_history_rate_idx on public.commission_rate_history (rate_id, changed_at desc);
create index if not exists commission_rate_history_at_idx on public.commission_rate_history (changed_at desc);

alter table public.commission_rate_history enable row level security;
drop policy if exists "commission_rate_history admin read" on public.commission_rate_history;
create policy "commission_rate_history admin read"
  on public.commission_rate_history for select to authenticated
  using ((select public.caller_is_admin()));
revoke all on public.commission_rate_history from anon;
grant select on public.commission_rate_history to authenticated;

create or replace function public.commission_rates_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.commission_rate_history (rate_id, op, old_row, new_row, changed_by)
  values (
    coalesce(new.id, old.id),
    lower(tg_op),
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end,
    auth.uid()
  );
  return null;
end;
$$;

revoke execute on function public.commission_rates_history() from public, anon, authenticated;

drop trigger if exists trg_commission_rates_history on public.commission_rates;
create trigger trg_commission_rates_history
  after insert or update or delete on public.commission_rates
  for each row execute function public.commission_rates_history();

-- ---- Who may read and write -------------------------------------------------
create or replace function public.commission_caller_can_edit()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and (public.admin_can_edit(auth.uid(), 'admin-settings-commission')
          or public.admin_can_edit(auth.uid(), 'admin-settings'));
$$;

revoke execute on function public.commission_caller_can_edit() from public, anon;
grant execute on function public.commission_caller_can_edit() to authenticated;

drop policy if exists "commission_rates read" on public.commission_rates;
drop policy if exists "commission_rates admin insert" on public.commission_rates;
drop policy if exists "commission_rates admin update" on public.commission_rates;
drop policy if exists "commission_rates admin delete" on public.commission_rates;

create policy "commission_rates read"
  on public.commission_rates for select to authenticated
  using (level <> 'user' or user_id = (select auth.uid()) or (select public.caller_is_admin()));
create policy "commission_rates admin insert"
  on public.commission_rates for insert to authenticated
  with check ((select public.commission_caller_can_edit()));
create policy "commission_rates admin update"
  on public.commission_rates for update to authenticated
  using ((select public.commission_caller_can_edit()))
  with check ((select public.commission_caller_can_edit()));
create policy "commission_rates admin delete"
  on public.commission_rates for delete to authenticated
  using ((select public.commission_caller_can_edit()));

revoke all on public.commission_rates from anon;
grant select, insert, update, delete on public.commission_rates to authenticated;

-- ---- Trip columns -----------------------------------------------------------
alter table public.ride_requests add column if not exists commission_rule_id uuid;
alter table public.ride_requests add column if not exists commission_locked_at timestamptz;
alter table public.ride_requests add column if not exists commission_error text;

-- ---- Resolution -------------------------------------------------------------
-- A rule's place name against a trip's: the same, or the region's name as
-- whole words in the geocoder's (0126).
create or replace function public.commission_place_matches(p_rule text, p_ride text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p_rule is not null and p_ride is not null
     and (lower(btrim(p_rule)) = lower(btrim(p_ride)) or public.region_name_matches(p_rule, p_ride));
$$;

-- A rule's parent, which only counts when both the rule and the trip name it.
create or replace function public.commission_parent_ok(p_rule text, p_ride text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p_rule is null or btrim(p_rule) = '' or p_ride is null or btrim(p_ride) = ''
      or public.commission_place_matches(p_rule, p_ride);
$$;

-- The rate for a trip by [p_user] picked up at (p_lat, p_lng) in the named
-- place, the rule that gave it (null for the built-in 15%), and its level.
create or replace function public.commission_resolve(
  p_user uuid default null,
  p_lat double precision default null,
  p_lng double precision default null,
  p_country text default null,
  p_state text default null,
  p_city text default null,
  p_suburb text default null
)
returns table (rate numeric, rule_id uuid, level text)
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
  -- Where the admin has mapped outlines, the pickup point names the places
  -- (the smallest outline holding it at each level), not the geocoder.
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

  return query
  select c.rate, c.id, c.level
    from public.commission_rates c
   where c.active
     and case c.level
       when 'user' then p_user is not null and c.user_id = p_user
       when 'suburb' then public.commission_place_matches(c.suburb, v_suburb)
         and public.commission_parent_ok(c.city, v_city)
         and public.commission_parent_ok(c.state, v_state)
         and public.commission_parent_ok(c.country, v_country)
       when 'city' then public.commission_place_matches(c.city, v_city)
         and public.commission_parent_ok(c.state, v_state)
         and public.commission_parent_ok(c.country, v_country)
       when 'state' then public.commission_place_matches(c.state, v_state)
         and public.commission_parent_ok(c.country, v_country)
       when 'country' then public.commission_place_matches(c.country, v_country)
       when 'master' then true
       else false
     end
   order by
     case c.level
       when 'user' then 6 when 'suburb' then 5 when 'city' then 4
       when 'state' then 3 when 'country' then 2 else 1
     end desc,
     c.priority desc,
     (c.country is not null)::int + (c.state is not null)::int + (c.city is not null)::int desc,
     c.updated_at desc nulls last,
     c.id
   limit 1;
  if found then return; end if;

  return query select 0.15::numeric, null::uuid, 'default'::text;
end;
$$;

revoke execute on function public.commission_resolve(uuid, double precision, double precision, text, text, text, text) from public, anon;
grant execute on function public.commission_resolve(uuid, double precision, double precision, text, text, text, text) to authenticated, service_role;

-- The old entry point, now answered the same way (no pickup point).
create or replace function public.commission_resolve_rate(
  p_user uuid default null,
  p_country text default null,
  p_state text default null,
  p_city text default null,
  p_suburb text default null
)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select r.rate from public.commission_resolve(p_user, null, null, p_country, p_state, p_city, p_suburb) r;
$$;

-- ---- Locked when the driver accepts ----------------------------------------
create or replace function public.ride_requests_lock_commission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v record;
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
    new.commission_rate := v.rate;
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

-- Named to run after trg_ride_requests_b_guard_fare, which refuses these
-- columns from the apps.
drop trigger if exists trg_ride_requests_c_commission_lock on public.ride_requests;
create trigger trg_ride_requests_c_commission_lock
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_lock_commission();

-- ---- Charging ---------------------------------------------------------------
create or replace function public.ride_charge_commission(p_ride uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_fare numeric;
  v_rate numeric;
  v_rule uuid;
  v_amount numeric(12,2);
  v record;
begin
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.status <> 'completed' or r.partner_id is null or r.commission_charged_at is not null then
    return;
  end if;

  v_fare := round(coalesce(r.ride_fare, r.fare, 0), 2);
  if not public.ride_money_ok(v_fare) or v_fare <= 0 then
    return;
  end if;

  if r.commission_locked_at is not null and r.commission_rate is not null then
    v_rate := r.commission_rate;
    v_rule := r.commission_rule_id;
  else
    select * into v from public.commission_resolve(
      r.partner_id, r.pickup_lat, r.pickup_lng, r.country, r.state, r.city, r.suburb);
    v_rate := v.rate;
    v_rule := v.rule_id;
  end if;
  if v_rate is null or v_rate < 0 or v_rate >= 1 then
    return;
  end if;

  v_amount := round(v_fare * v_rate, 2);

  if v_amount > 0 then
    -- Ledger-driven: trg_wallet_tx_apply moves the balance.
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
    values (r.partner_id, 'get_credit', 'commission', -v_amount,
            'Ride commission ' || round(v_rate * 100, 1) || '% of ' ||
            coalesce(r.currency, 'RM') || ' ' || v_fare);
  end if;

  update public.ride_requests
     set commission_rate = v_rate,
         commission_rule_id = v_rule,
         commission_amount = v_amount,
         commission_charged_at = now(),
         commission_error = null
   where id = p_ride;
end;
$$;

revoke all on function public.ride_charge_commission(uuid) from public, anon, authenticated, service_role;

create or replace function public.ride_requests_charge_commission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- A completion is never held up by the commission: a failure is written on
  -- the trip for the Commission page to charge again.
  begin
    perform public.ride_charge_commission(new.id);
  exception when others then
    raise warning 'ride % commission not charged: %', new.id, sqlerrm;
    begin
      update public.ride_requests set commission_error = left(sqlerrm, 500) where id = new.id;
    exception when others then
      null;
    end;
  end;
  return null;
end;
$$;

revoke execute on function public.ride_requests_charge_commission() from public, anon, authenticated;

-- Admin -> Commission -> "Charge now": every completed trip with a driver and
-- a fare that was never charged. Answers how many were charged and how many
-- still failed.
create or replace function public.admin_charge_uncharged_commissions()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_charged int := 0;
  v_failed int := 0;
begin
  if not public.commission_caller_can_edit() then
    raise exception 'not_authorized';
  end if;
  for r in
    select id from public.ride_requests
     where status = 'completed' and partner_id is not null and commission_charged_at is null
       and coalesce(ride_fare, fare, 0) > 0
     order by updated_at
     limit 500
  loop
    begin
      perform public.ride_charge_commission(r.id);
      if exists (select 1 from public.ride_requests where id = r.id and commission_charged_at is not null) then
        v_charged := v_charged + 1;
      end if;
    exception when others then
      v_failed := v_failed + 1;
      update public.ride_requests set commission_error = left(sqlerrm, 500) where id = r.id;
    end;
  end loop;
  return jsonb_build_object('charged', v_charged, 'failed', v_failed);
end;
$$;

revoke execute on function public.admin_charge_uncharged_commissions() from public, anon;
grant execute on function public.admin_charge_uncharged_commissions() to authenticated;

-- Admin -> Commission: completed trips not yet charged, for the "Charge now"
-- card.
create or replace function public.admin_uncharged_commissions()
returns table (ride_id uuid, partner_id uuid, fare numeric, completed_at timestamptz, error text)
language sql
stable
security definer
set search_path = public
as $$
  select r.id, r.partner_id, coalesce(r.ride_fare, r.fare), r.updated_at, r.commission_error
    from public.ride_requests r
   where public.caller_is_admin()
     and r.status = 'completed' and r.partner_id is not null and r.commission_charged_at is null
     and coalesce(r.ride_fare, r.fare, 0) > 0
   order by r.updated_at desc
   limit 200;
$$;

revoke execute on function public.admin_uncharged_commissions() from public, anon;
grant execute on function public.admin_uncharged_commissions() to authenticated;

notify pgrst, 'reload schema';
