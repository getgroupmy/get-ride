-- ============================================================================
-- 0201 · Partner statements: weekly, monthly and annual earnings statements
-- for drivers (PDF from the `partner-statement` function), and the Earnings
-- page's totals, from one calculation.
--
-- The lines, per completed trip (bucketed by completed_at, Asia/Kuala_Lumpur):
--   Earnings      fare (ride_fare, else fare); the surcharges an admin marks
--                 as earnings; fees collected for GET.ride (scheduling and
--                 late-cancel fees, platform surcharges); incentives (GET
--                 credit, kind 'incentive'); trip handover shares received.
--   Pass-through  taxes, tolls, other charges and the surcharges not marked
--                 as earnings: collected from the rider, not income.
--   Deductions    commission; platform fees (the same scheduling and
--                 late-cancel fees, taken back from GET credit); handover
--                 shares paid.
--   Adjustments   ± corrections an admin with edit rights posts (GET credit,
--                 kind 'adjustment').
--   Net           earnings − deductions + adjustments.
-- GET.coin is shown only as how riders paid (already inside the fare).
--
-- Also: online-hours history (from driver_presence, recorded from now on),
-- incentive payouts (manual, or weekly from the driver_incentive rules),
-- payout bank details (shown only when the admin turns the bank line on),
-- the statement records (final copies cached, "Revised" when the numbers
-- change) and verification by the QR code's token: the QR opens the app's
-- public page <verifyUrl>/<token> (blank: https://getride.my/verify).
-- ============================================================================

-- ---- Settings ------------------------------------------------------------------------------
insert into public.app_settings (key, value) values ('partner_statement', jsonb_build_object(
  'weekStart', 'monday',
  'earningSurcharges', '[]'::jsonb,
  'showBank', false,
  'companyName', 'PUNCAK NIAGA BERSAMA SDN. BHD.',
  'companySsm', '202201025129 (1470826-D)',
  'supportContact', '+6012-5252255',
  'verifyUrl', ''))
on conflict (key) do nothing;

create or replace function public.partner_statement_config_clean(p jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select jsonb_build_object(
    'weekStart', case when p->>'weekStart' = 'sunday' then 'sunday' else 'monday' end,
    'earningSurcharges', coalesce((
      select jsonb_agg(distinct btrim(n)) from jsonb_array_elements_text(
        case when jsonb_typeof(p->'earningSurcharges') = 'array' then p->'earningSurcharges' else '[]' end) n
       where btrim(n) <> '' and length(n) <= 80), '[]'::jsonb),
    'showBank', coalesce(p->'showBank' = 'true'::jsonb, false),
    'companyName', left(btrim(coalesce(p->>'companyName', '')), 120),
    'companySsm', left(btrim(coalesce(p->>'companySsm', '')), 60),
    'supportContact', left(btrim(coalesce(p->>'supportContact', '')), 60),
    'verifyUrl', case when coalesce(p->>'verifyUrl', '') ~ '^https://[^\s]+$' then p->>'verifyUrl' else '' end);
$$;

-- Read by the app (Earnings page, statements sheet) and the PDF function.
create or replace function public.partner_statement_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.partner_statement_config_clean(
    coalesce((select value from public.app_settings where key = 'partner_statement'), '{}'));
$$;
revoke execute on function public.partner_statement_config() from public, anon;
grant execute on function public.partner_statement_config() to authenticated;

-- Admins with edit rights on Partner statements (or every page).
create or replace function public.caller_can_edit_statements()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and public.admin_can_edit(auth.uid(), 'admin-settings-partner-statements');
$$;
revoke execute on function public.caller_can_edit_statements() from public, anon;
grant execute on function public.caller_can_edit_statements() to authenticated;

create or replace function public.set_partner_statement_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := public.partner_statement_config_clean(p_config);
begin
  if not public.caller_can_edit_statements() then
    raise exception 'Only an admin with edit rights can change partner statements.' using errcode = '42501';
  end if;
  insert into public.app_settings (key, value, updated_at) values ('partner_statement', v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return v;
end;
$$;
revoke execute on function public.set_partner_statement_config(jsonb) from public, anon;
grant execute on function public.set_partner_statement_config(jsonb) to authenticated;

-- Surcharge names seen on trips (the last year), for the admin to mark as earnings.
create or replace function public.statement_surcharge_names()
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
    select btrim(e->>'name'), count(*)
      from public.ride_requests r, jsonb_array_elements(case when jsonb_typeof(r.charges) = 'array' then r.charges else '[]' end) e
     where r.status = 'completed' and r.completed_at > now() - interval '365 days'
       and coalesce(e->>'kind', 'surcharge') <> 'tax' and (e->>'platform')::boolean is not true
       and btrim(coalesce(e->>'name', '')) <> ''
     group by 1 order by 2 desc, 1 limit 100;
end;
$$;
revoke execute on function public.statement_surcharge_names() from public, anon;
grant execute on function public.statement_surcharge_names() to authenticated;

-- ---- Online hours (recorded from now on) ---------------------------------------------------
create table if not exists public.partner_online_sessions (
  id           bigint generated always as identity primary key,
  profile_id   uuid not null references auth.users(id) on delete cascade,
  started_at   timestamptz not null,
  last_seen_at timestamptz not null,
  ended_at     timestamptz
);
create index if not exists partner_online_sessions_profile_idx on public.partner_online_sessions (profile_id, started_at);
create unique index if not exists partner_online_sessions_open_idx
  on public.partner_online_sessions (profile_id) where ended_at is null;
alter table public.partner_online_sessions enable row level security;
revoke all on public.partner_online_sessions from anon, authenticated;
grant select on public.partner_online_sessions to authenticated;
drop policy if exists "partner_online_sessions own" on public.partner_online_sessions;
create policy "partner_online_sessions own" on public.partner_online_sessions
  for select to authenticated using (profile_id = (select auth.uid()) or public.caller_is_admin());

-- A gap this long without a report ends the session where it was last seen
-- (the app reports about once a minute while online).
create or replace function public.driver_presence_record_session()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.partner_online_sessions;
begin
  select * into s from public.partner_online_sessions where profile_id = new.profile_id and ended_at is null;
  if found and (not new.online or now() - s.last_seen_at > interval '5 minutes') then
    update public.partner_online_sessions
       set ended_at = case when new.online then s.last_seen_at else now() end,
           last_seen_at = case when new.online then s.last_seen_at else now() end
     where id = s.id;
    s := null;
  elsif found then
    update public.partner_online_sessions set last_seen_at = now() where id = s.id;
    return new;
  end if;
  if new.online then
    insert into public.partner_online_sessions (profile_id, started_at, last_seen_at) values (new.profile_id, now(), now())
    on conflict do nothing;
  end if;
  return new;
end;
$$;
revoke execute on function public.driver_presence_record_session() from public, anon, authenticated;

drop trigger if exists trg_driver_presence_session on public.driver_presence;
create trigger trg_driver_presence_session
  after insert or update of online, updated_at on public.driver_presence
  for each row execute function public.driver_presence_record_session();

-- Hours online between two moments (sessions clipped to them).
create or replace function public.partner_online_hours(p_uid uuid, p_from timestamptz, p_to timestamptz)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select round(coalesce(sum(extract(epoch from
           least(coalesce(ended_at, last_seen_at), p_to) - greatest(started_at, p_from))) / 3600.0, 0)::numeric, 2)
    from public.partner_online_sessions
   where profile_id = p_uid and started_at < p_to and coalesce(ended_at, last_seen_at) > p_from;
$$;
revoke execute on function public.partner_online_hours(uuid, timestamptz, timestamptz) from public, anon, authenticated;

-- ---- Incentives and adjustments (GET credit) -----------------------------------------------
create table if not exists public.partner_incentives (
  id           uuid primary key default gen_random_uuid(),
  profile_id   uuid not null references auth.users(id) on delete cascade,
  amount       numeric(12,2) not null check (amount > 0),
  label        text not null,
  rule_id      uuid,
  period_start date,
  credited_at  timestamptz not null default now(),
  created_by   uuid,
  unique (profile_id, rule_id, period_start)
);
create table if not exists public.partner_adjustments (
  id           uuid primary key default gen_random_uuid(),
  profile_id   uuid not null references auth.users(id) on delete cascade,
  amount       numeric(12,2) not null check (amount <> 0),
  reason       text not null,
  effective_at timestamptz not null default now(),
  created_at   timestamptz not null default now(),
  created_by   uuid
);
create index if not exists partner_incentives_profile_idx on public.partner_incentives (profile_id, credited_at);
create index if not exists partner_adjustments_profile_idx on public.partner_adjustments (profile_id, effective_at);
alter table public.partner_incentives enable row level security;
alter table public.partner_adjustments enable row level security;
revoke all on public.partner_incentives, public.partner_adjustments from anon, authenticated;
grant select on public.partner_incentives, public.partner_adjustments to authenticated;
drop policy if exists "partner_incentives own" on public.partner_incentives;
create policy "partner_incentives own" on public.partner_incentives
  for select to authenticated using (profile_id = (select auth.uid()) or public.caller_is_admin());
drop policy if exists "partner_adjustments own" on public.partner_adjustments;
create policy "partner_adjustments own" on public.partner_adjustments
  for select to authenticated using (profile_id = (select auth.uid()) or public.caller_is_admin());

-- The partner's auth account for a partners.id, display id, phone or auth id.
create or replace function public.statement_partner_uid(p_ref text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select p.auth_user_id from public.partners p
   where p.auth_user_id is not null
     and (p.auth_user_id::text = btrim(p_ref) or p.id::text = btrim(p_ref)
          or p.display_id::text = btrim(p_ref) or p.phone = btrim(p_ref))
   limit 1;
$$;
revoke execute on function public.statement_partner_uid(text) from public, anon, authenticated;

create or replace function public.admin_credit_incentive(p_partner text, p_amount numeric, p_label text)
returns public.partner_incentives
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.statement_partner_uid(p_partner);
  i public.partner_incentives;
begin
  if not public.caller_can_edit_statements() then
    raise exception 'Only an admin with edit rights can credit incentives.' using errcode = '42501';
  end if;
  if v_uid is null then
    raise exception 'STATEMENT_PARTNER' using hint = 'No partner with that ID or phone.';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100000 then
    raise exception 'STATEMENT_AMOUNT' using hint = 'Give an amount above 0.';
  end if;
  if btrim(coalesce(p_label, '')) = '' then
    raise exception 'STATEMENT_LABEL' using hint = 'Give the incentive a name.';
  end if;
  insert into public.partner_incentives (profile_id, amount, label, created_by)
  values (v_uid, round(p_amount, 2), left(btrim(p_label), 120), auth.uid()) returning * into i;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
  values (v_uid, 'get_credit', 'incentive', i.amount, 'Incentive: ' || i.label);
  perform public.enqueue_notification(v_uid, 'incentive-' || i.id, 'statement', 'normal', 'Incentive credited',
    coalesce((select value->>'currency' from public.app_settings where key = 'currency'), 'RM') || ' '
      || to_char(i.amount, 'FM999999990.00') || ' for ' || i.label || ' was added to your GET credit.',
    jsonb_build_object('type', 'partner_incentive', 'role', 'partner'));
  return i;
end;
$$;
revoke execute on function public.admin_credit_incentive(text, numeric, text) from public, anon;
grant execute on function public.admin_credit_incentive(text, numeric, text) to authenticated;

create or replace function public.admin_post_adjustment(p_partner text, p_amount numeric, p_reason text,
                                                        p_effective date default null)
returns public.partner_adjustments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.statement_partner_uid(p_partner);
  v_at timestamptz := case when p_effective is null then now()
                           else (p_effective::timestamp + interval '12 hours') at time zone 'Asia/Kuala_Lumpur' end;
  a public.partner_adjustments;
begin
  if not public.caller_can_edit_statements() then
    raise exception 'Only an admin with edit rights can post adjustments.' using errcode = '42501';
  end if;
  if v_uid is null then
    raise exception 'STATEMENT_PARTNER' using hint = 'No partner with that ID or phone.';
  end if;
  if p_amount is null or p_amount = 0 or abs(p_amount) > 100000 then
    raise exception 'STATEMENT_AMOUNT' using hint = 'Give an amount other than 0 (minus for a deduction).';
  end if;
  if btrim(coalesce(p_reason, '')) = '' then
    raise exception 'STATEMENT_LABEL' using hint = 'Say what the adjustment is for.';
  end if;
  if v_at > now() + interval '1 day' or v_at < now() - interval '7 years' then
    raise exception 'STATEMENT_DATE' using hint = 'The date must be within the last 7 years and not in the future.';
  end if;
  insert into public.partner_adjustments (profile_id, amount, reason, effective_at, created_by)
  values (v_uid, round(p_amount, 2), left(btrim(p_reason), 200), v_at, auth.uid()) returning * into a;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
  values (v_uid, 'get_credit', 'adjustment', a.amount, 'Adjustment: ' || a.reason);
  -- Final statements covering that day are revised on their next download.
  update public.partner_statements set data_hash = 'stale'
   where partner_user_id = v_uid and is_final
     and period_start <= (v_at at time zone 'Asia/Kuala_Lumpur')::date
     and period_end >= (v_at at time zone 'Asia/Kuala_Lumpur')::date;
  perform public.enqueue_notification(v_uid, 'adjustment-' || a.id, 'statement', 'normal', 'Earnings adjusted',
    'An adjustment of ' || to_char(a.amount, 'FMS999999990.00') || ' was made: ' || a.reason || '.',
    jsonb_build_object('type', 'partner_adjustment', 'role', 'partner'));
  return a;
end;
$$;
revoke execute on function public.admin_post_adjustment(text, numeric, text, date) from public, anon;
grant execute on function public.admin_post_adjustment(text, numeric, text, date) to authenticated;

-- Admin lists (newest first).
create or replace function public.admin_statement_entries(p_kind text, p_limit integer default 100)
returns table (id uuid, kind text, partner_name text, partner_display_id text, amount numeric, label text,
               at timestamptz, created_by_name text)
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
    select x.id, x.kind, p.name, p.display_id::text, x.amount, x.label, x.at, pr.name
      from (
        select i.id, 'incentive'::text as kind, i.profile_id, i.amount, i.label, i.credited_at as at, i.created_by
          from public.partner_incentives i where p_kind in ('incentive', 'all')
        union all
        select a.id, 'adjustment', a.profile_id, a.amount, a.reason, a.effective_at, a.created_by
          from public.partner_adjustments a where p_kind in ('adjustment', 'all')
      ) x
      left join public.partners p on p.auth_user_id = x.profile_id
      left join public.profiles pr on pr.id = x.created_by
     order by x.at desc
     limit greatest(1, least(coalesce(p_limit, 100), 500));
end;
$$;
revoke execute on function public.admin_statement_entries(text, integer) from public, anon;
grant execute on function public.admin_statement_entries(text, integer) to authenticated;

-- Weekly incentive rules (driver_incentive: name, minRides, reward, active):
-- each driver with at least minRides completed trips in the week just
-- closed is credited the reward once. Runs Monday 06:00 (Malaysia).
create or replace function public.partner_incentives_weekly()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  ws date := public.statement_week_start((now() at time zone 'Asia/Kuala_Lumpur')::date - 7);
  v_from timestamptz := ws::timestamp at time zone 'Asia/Kuala_Lumpur';
  v_to timestamptz := (ws + 7)::timestamp at time zone 'Asia/Kuala_Lumpur';
  rule record;
  d record;
  n integer := 0;
  v_reward numeric;
  v_min integer;
begin
  for rule in
    select id, values from public.driver_incentive
     where coalesce(active, true) and coalesce((values->>'active')::boolean, true)
  loop
    v_reward := case when coalesce(rule.values->>'reward', '') ~ '^\d+(\.\d+)?$' then (rule.values->>'reward')::numeric end;
    v_min := case when coalesce(rule.values->>'minRides', '') ~ '^\d+$' then (rule.values->>'minRides')::int end;
    continue when v_reward is null or v_reward <= 0 or v_min is null or v_min <= 0;
    for d in
      select partner_id as uid from public.ride_requests
       where status = 'completed' and partner_id is not null and completed_at >= v_from and completed_at < v_to
       group by partner_id having count(*) >= v_min
    loop
      begin
        insert into public.partner_incentives (profile_id, amount, label, rule_id, period_start)
        values (d.uid, round(v_reward, 2), left(coalesce(nullif(btrim(rule.values->>'name'), ''), 'Weekly incentive'), 120),
                rule.id, ws);
        insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
        values (d.uid, 'get_credit', 'incentive', round(v_reward, 2),
                'Incentive: ' || coalesce(nullif(btrim(rule.values->>'name'), ''), 'Weekly incentive'));
        n := n + 1;
      exception when unique_violation then
        null;
      end;
    end loop;
  end loop;
  return n;
end;
$$;
revoke execute on function public.partner_incentives_weekly() from public, anon, authenticated;

-- ---- Payout bank (shown only when the admin turns the bank line on) -----------------------
create table if not exists public.partner_payout_accounts (
  profile_id   uuid primary key references auth.users(id) on delete cascade,
  bank_name    text not null,
  account_no   text not null,
  holder_name  text not null,
  updated_at   timestamptz not null default now()
);
alter table public.partner_payout_accounts enable row level security;
revoke all on public.partner_payout_accounts from anon, authenticated;
grant select on public.partner_payout_accounts to authenticated;
drop policy if exists "partner_payout_accounts own" on public.partner_payout_accounts;
create policy "partner_payout_accounts own" on public.partner_payout_accounts
  for select to authenticated using (profile_id = (select auth.uid()) or public.caller_is_admin());

create or replace function public.set_my_payout_account(p_bank text, p_account text, p_holder text)
returns public.partner_payout_accounts
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.partner_payout_accounts;
  v_acc text := regexp_replace(coalesce(p_account, ''), '[\s-]', '', 'g');
begin
  if not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if btrim(coalesce(p_bank, '')) = '' or btrim(coalesce(p_holder, '')) = '' or v_acc !~ '^\d{6,20}$' then
    raise exception 'STATEMENT_BANK' using hint = 'Give the bank, the account holder and a 6 to 20 digit account number.';
  end if;
  insert into public.partner_payout_accounts (profile_id, bank_name, account_no, holder_name, updated_at)
  values (auth.uid(), left(btrim(p_bank), 80), v_acc, left(btrim(p_holder), 120), now())
  on conflict (profile_id) do update
    set bank_name = excluded.bank_name, account_no = excluded.account_no,
        holder_name = excluded.holder_name, updated_at = now()
  returning * into a;
  return a;
end;
$$;
revoke execute on function public.set_my_payout_account(text, text, text) from public, anon;
grant execute on function public.set_my_payout_account(text, text, text) to authenticated;

-- ---- Periods -------------------------------------------------------------------------------
-- The first day of [d]'s week: Monday (Mon–Sun) or Sunday (Sun–Sat), as set.
create or replace function public.statement_week_start(d date)
returns date
language sql
stable
security definer
set search_path = public
as $$
  select case when public.partner_statement_config()->>'weekStart' = 'sunday'
              then d - extract(dow from d)::int
              else d - (extract(isodow from d)::int - 1) end;
$$;

create or replace function public.statement_period_end(p_type text, p_start date)
returns date
language sql
immutable
set search_path = public
as $$
  select case p_type
           when 'weekly' then p_start + 6
           when 'monthly' then (p_start + interval '1 month')::date - 1
           else (p_start + interval '1 year')::date - 1 end;
$$;

-- ---- The calculation ----------------------------------------------------------------------
-- One trip's lines.
create or replace function public.statement_ride_lines(r public.ride_requests, p_earning text[])
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  f numeric := round(coalesce(r.ride_fare, r.fare, 0), 2);
  c jsonb;
  v numeric;
  amt numeric;
  s_earn numeric := 0;
  s_pass numeric := 0;
  s_platform numeric := 0;
  s_all numeric := 0;
  due numeric := public.ride_amount_due(r);
  tolls numeric := round(coalesce(r.toll_charges, 0), 2);
  other numeric := round(coalesce(r.other_charges, 0), 2);
begin
  if jsonb_typeof(r.charges) = 'array' then
    for c in select value from jsonb_array_elements(r.charges) loop
      v := case when jsonb_typeof(c->'value') = 'number' then (c->>'value')::numeric end;
      continue when v is null or v <= 0 or btrim(coalesce(c->>'name', '')) = '' or c->>'kind' = 'tax';
      amt := round(greatest(0, case when c->>'charge' = 'fixed' then v else f * v / 100 end), 2);
      s_all := s_all + amt;
      if (c->>'platform')::boolean is true then
        s_platform := s_platform + amt;
      elsif btrim(c->>'name') = any(p_earning) then
        s_earn := s_earn + amt;
      else
        s_pass := s_pass + amt;
      end if;
    end loop;
  end if;
  return jsonb_build_object(
    'fare', f,
    'surcharges', s_earn,
    'platformCollected', s_platform,
    'surchargesPass', s_pass,
    'taxes', greatest(0, round(due - f - s_all - tolls - other, 2)),
    'tolls', tolls,
    'otherCharges', other,
    'commission', round(coalesce(r.commission_amount, 0), 2),
    -- Only fixed platform fees are taken back from GET credit (0189).
    'platformFees', coalesce((select sum(round((e->>'value')::numeric, 2)) from jsonb_array_elements(
                        case when jsonb_typeof(r.charges) = 'array' then r.charges else '[]' end) e
                      where (e->>'platform')::boolean is true and e->>'charge' = 'fixed'
                        and jsonb_typeof(e->'value') = 'number' and (e->>'value')::numeric > 0), 0),
    'coins', round(coalesce(r.fare_coins_value, 0), 2),
    'cash', case when lower(coalesce(r.paid_method, r.payment_mode, 'cash')) like 'cash%'
                 then greatest(0, round(due - coalesce(r.fare_coins_value, 0), 2)) else 0 end,
    'distanceKm', round(coalesce(r.distance_km, 0), 2));
end;
$$;
revoke execute on function public.statement_ride_lines(public.ride_requests, text[]) from public, anon, authenticated;

-- Every line between two moments for one partner: the Earnings page and the
-- statement both come from here.
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
  e numeric;
  d numeric;
  adj numeric;
begin
  select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) into t from (
    select k, round(sum((l->>k)::numeric), 2) as v
      from public.ride_requests r
      cross join lateral public.statement_ride_lines(r, earning) l
      cross join lateral jsonb_object_keys(l) k
     where r.partner_id = p_uid and r.status = 'completed' and r.completed_at >= p_from and r.completed_at < p_to
     group by k) s;
  select count(*) as trips into w from public.ride_requests r
   where r.partner_id = p_uid and r.status = 'completed' and r.completed_at >= p_from and r.completed_at < p_to;
  t := t || jsonb_build_object('trips', w.trips);

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

-- The Earnings page: totals for the signed-in partner between two moments.
create or replace function public.my_earnings(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_to <= p_from or p_to - p_from > interval '400 days' then
    raise exception 'STATEMENT_PERIOD' using hint = 'Pick a period of up to a year.';
  end if;
  return public.partner_statement_totals(auth.uid(), p_from, p_to);
end;
$$;
revoke execute on function public.my_earnings(timestamptz, timestamptz) from public, anon;
grant execute on function public.my_earnings(timestamptz, timestamptz) to authenticated;

-- The same totals bucketed (day | week | month), for charts and breakdowns.
create or replace function public.my_earnings_series(p_from timestamptz, p_to timestamptz, p_bucket text)
returns table (bucket_start date, totals jsonb)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  tz text := 'Asia/Kuala_Lumpur';
  d date := (p_from at time zone tz)::date;
  stop date := (p_to at time zone tz)::date;
  nxt date;
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_bucket not in ('day', 'week', 'month') or p_to <= p_from or p_to - p_from > interval '400 days' then
    raise exception 'STATEMENT_PERIOD' using hint = 'Pick a period of up to a year.';
  end if;
  if p_bucket = 'week' then d := public.statement_week_start(d); end if;
  if p_bucket = 'month' then d := date_trunc('month', d)::date; end if;
  while d < stop or (d = stop and p_to > (stop::timestamp at time zone tz)) loop
    nxt := case p_bucket when 'day' then d + 1 when 'week' then d + 7 else (d + interval '1 month')::date end;
    bucket_start := d;
    totals := public.partner_statement_totals(auth.uid(),
      greatest(p_from, d::timestamp at time zone tz), least(p_to, nxt::timestamp at time zone tz));
    return next;
    d := nxt;
  end loop;
end;
$$;
revoke execute on function public.my_earnings_series(timestamptz, timestamptz, text) from public, anon;
grant execute on function public.my_earnings_series(timestamptz, timestamptz, text) to authenticated;

-- ---- Statements ----------------------------------------------------------------------------
create sequence if not exists public.partner_statement_no_seq;

create table if not exists public.partner_statements (
  id              uuid primary key default gen_random_uuid(),
  statement_no    text unique not null,
  verify_token    text unique not null default encode(extensions.gen_random_bytes(12), 'hex'),
  partner_user_id uuid not null references auth.users(id) on delete cascade,
  period_type     text not null check (period_type in ('weekly', 'monthly', 'annual')),
  period_start    date not null,
  period_end      date not null,
  lang            text not null check (lang in ('en', 'ms')),
  is_final        boolean not null,
  totals          jsonb not null,
  storage_path    text not null,
  data_hash       text not null,
  revised_at      timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (partner_user_id, period_type, period_start, lang)
);
alter table public.partner_statements enable row level security;
revoke all on public.partner_statements from anon, authenticated;
grant select on public.partner_statements to authenticated;
drop policy if exists "partner_statements own" on public.partner_statements;
create policy "partner_statements own" on public.partner_statements
  for select to authenticated using (partner_user_id = (select auth.uid()) or public.caller_is_admin());

-- Downloads per partner per hour (the PDF function counts each generation).
create table if not exists public.partner_statement_rate (
  profile_id   uuid primary key,
  window_start timestamptz not null,
  hits         integer not null
);
alter table public.partner_statement_rate enable row level security;
revoke all on public.partner_statement_rate from anon, authenticated;

-- Whether [p_type] [p_start] is a period this partner may have: the right
-- first day, from the period they joined, within 7 years, not in the future.
-- Returns the status: 'final' (closed, from 06:00 after) or 'provisional'.
create or replace function public.statement_period_status(p_uid uuid, p_type text, p_start date)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  tz text := 'Asia/Kuala_Lumpur';
  today date := (now() at time zone tz)::date;
  joined date;
  v_end date;
begin
  if p_type not in ('weekly', 'monthly', 'annual') or p_start is null then
    raise exception 'STATEMENT_PERIOD' using hint = 'That is not a statement period.';
  end if;
  if (p_type = 'weekly' and p_start <> public.statement_week_start(p_start))
     or (p_type = 'monthly' and extract(day from p_start) <> 1)
     or (p_type = 'annual' and (extract(day from p_start) <> 1 or extract(month from p_start) <> 1)) then
    raise exception 'STATEMENT_PERIOD' using hint = 'That is not a statement period.';
  end if;
  select coalesce(p.joined_at, p.created_at)::date into joined from public.partners p where p.auth_user_id = p_uid
   order by p.created_at limit 1;
  v_end := public.statement_period_end(p_type, p_start);
  if p_start > today or v_end < coalesce(joined, today) or v_end < (today - interval '7 years')::date then
    raise exception 'STATEMENT_PERIOD' using hint = 'There is no statement for that period.';
  end if;
  return case when now() >= ((v_end + 1)::timestamp + interval '6 hours') at time zone tz
              then 'final' else 'provisional' end;
end;
$$;
revoke execute on function public.statement_period_status(uuid, text, date) from public, anon, authenticated;

-- Everything a statement shows, for the signed-in partner.
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
    select coalesce(jsonb_agg(jsonb_build_object(
             'at', r.completed_at, 'service', r.service, 'pickup', left(coalesce(r.pickup_address, ''), 80),
             'drop', left(coalesce(r.drop_address, ''), 80), 'payment', coalesce(r.paid_method, r.payment_mode),
             'lines', public.statement_ride_lines(r, array(select jsonb_array_elements_text(cfg->'earningSurcharges'))))
             order by r.completed_at), '[]') into trips
      from public.ride_requests r
     where r.partner_id = v_uid and r.status = 'completed' and r.completed_at >= v_from and r.completed_at < v_to;
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

-- The weeks overlapping [p_from, p_to], each clipped to it (monthly and annual breakdowns).
create or replace function public.statement_weeks(p_uid uuid, p_from date, p_to date)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'start', greatest(w, p_from), 'end', least(w + 6, p_to),
           'totals', public.partner_statement_totals(p_uid,
                       greatest(w, p_from)::timestamp at time zone 'Asia/Kuala_Lumpur',
                       (least(w + 6, p_to) + 1)::timestamp at time zone 'Asia/Kuala_Lumpur'))
           order by w), '[]')
    from (select generate_series(public.statement_week_start(p_from)::timestamp, p_to::timestamp, interval '7 days')::date as w) s;
$$;
revoke execute on function public.statement_weeks(uuid, date, date) from public, anon, authenticated;

-- The statements list: newest periods first, with net and status.
create or replace function public.my_statement_periods(p_type text, p_limit integer default 12, p_before date default null)
returns table (period_start date, period_end date, status text, net numeric, trips integer, revised_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  tz text := 'Asia/Kuala_Lumpur';
  today date := (now() at time zone tz)::date;
  joined date;
  d date;
  n integer := 0;
  t jsonb;
  floor_d date := (today - interval '7 years')::date;
begin
  if v_uid is null or not public.caller_is_approved_partner() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_type not in ('weekly', 'monthly', 'annual') then
    raise exception 'STATEMENT_PERIOD' using hint = 'That is not a statement period.';
  end if;
  select coalesce(min(coalesce(p.joined_at, p.created_at))::date, today) into joined
    from public.partners p where p.auth_user_id = v_uid;
  d := coalesce(p_before, today + 1) - 1;
  d := case p_type when 'weekly' then public.statement_week_start(d)
                   when 'monthly' then date_trunc('month', d)::date
                   else date_trunc('year', d)::date end;
  while n < greatest(1, least(coalesce(p_limit, 12), 60)) loop
    period_end := public.statement_period_end(p_type, d);
    exit when period_end < joined or period_end < floor_d;
    period_start := d;
    status := public.statement_period_status(v_uid, p_type, d);
    t := public.partner_statement_totals(v_uid, d::timestamp at time zone tz, (period_end + 1)::timestamp at time zone tz);
    net := (t->>'net')::numeric;
    trips := (t->>'trips')::int;
    select s.revised_at into revised_at from public.partner_statements s
     where s.partner_user_id = v_uid and s.period_type = p_type and s.period_start = d
     order by s.revised_at desc nulls last limit 1;
    return next;
    n := n + 1;
    d := case p_type when 'weekly' then d - 7
                     when 'monthly' then (d - interval '1 month')::date
                     else (d - interval '1 year')::date end;
  end loop;
end;
$$;
revoke execute on function public.my_statement_periods(text, integer, date) from public, anon;
grant execute on function public.my_statement_periods(text, integer, date) to authenticated;

-- Verification (the QR code): anyone with the token sees initials, period and net.
create or replace function public.statement_verify(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'statementNo', s.statement_no,
           'initials', (select string_agg(left(w, 1), '') from regexp_split_to_table(coalesce(p.name, ''), '\s+') w where w <> ''),
           'type', s.period_type,
           'periodStart', s.period_start,
           'periodEnd', s.period_end,
           'net', s.totals->'net',
           'final', s.is_final,
           'revisedAt', s.revised_at,
           'issuedAt', s.updated_at)
    from public.partner_statements s
    left join public.partners p on p.auth_user_id = s.partner_user_id
   where s.verify_token = p_token and length(coalesce(p_token, '')) = 24
   limit 1;
$$;
revoke execute on function public.statement_verify(text) from public;
grant execute on function public.statement_verify(text) to anon, authenticated;

-- The PDF function's bookkeeping (service role only): the next statement no.,
-- and one generation counted against the partner's hour (20 an hour).
create or replace function public.statement_next_no(p_type text)
returns text
language sql
security definer
set search_path = public
as $$
  select 'GR-' || upper(left(p_type, 1)) || '-' || to_char(now() at time zone 'Asia/Kuala_Lumpur', 'YYYY') || '-'
         || lpad(nextval('public.partner_statement_no_seq')::text, 6, '0');
$$;
revoke execute on function public.statement_next_no(text) from public, anon, authenticated;
grant execute on function public.statement_next_no(text) to service_role;

create or replace function public.statement_take(p_uid uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  insert into public.partner_statement_rate as g (profile_id, window_start, hits) values (p_uid, now(), 1)
  on conflict (profile_id) do update
    set hits = case when g.window_start < now() - interval '1 hour' then 1 else g.hits + 1 end,
        window_start = case when g.window_start < now() - interval '1 hour' then now() else g.window_start end
  returning hits into n;
  return n <= 20;
end;
$$;
revoke execute on function public.statement_take(uuid) from public, anon, authenticated;
grant execute on function public.statement_take(uuid) to service_role;

-- Private bucket for final copies.
insert into storage.buckets (id, name, public) values ('partner-statements', 'partner-statements', false)
on conflict (id) do update set public = false;

-- Weekly incentives, Monday 06:00 Malaysia (Sunday 22:00 UTC).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'partner-incentives-weekly';
    perform cron.schedule('partner-incentives-weekly', '0 22 * * 0', $job$select public.partner_incentives_weekly()$job$);
  end if;
end $$;

notify pgrst, 'reload schema';
