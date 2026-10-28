-- ============================================================================
-- 0309 — City to City money and reminders (docs/KIV.md L8, part C4): the fee
-- a driver pays for giving a booked trip up, in-app payment (held at booking
-- or paid after the trip), collecting the cancel fees a rider owes and the
-- give-up fees a driver owes, and reminders before a trip.
--
-- Version 20261028020000 (0309_city_to_city_money_reminders). Re-runnable:
-- tables, columns and indexes "if not exists", functions "create or
-- replace", policies and triggers dropped first, seed rows only where
-- missing.
--
-- 1. Driver gives up a booked trip (c2c_giveup_rules): a default rule (place
--    null, always there, never deleted) and a rule per region (one place:
--    country, state, city or suburb). The pickup's most specific region with
--    an active rule wins (suburb 4, city 3, state 2, country 1, as 0306's
--    c2c_place_rank), else the default. Per rule: charge on/off; the fee in
--    RM; when: 'always' or 'within' free_hours of the time to leave; where
--    it goes: 'rider', 'platform' (get.ride keeps it: no row credits it, as
--    with commission) or 'split' (to the rider a percent, or a fixed RM up
--    to the fee; the rest to get.ride); if the driver's GET wallet is short:
--    'negative' (what the wallet lacks comes off the driver's GET.credit,
--    which may go below zero as commission does: GET.wallet itself never
--    goes below zero, wallets_balance_check) and the rider is paid their
--    share in full now, or 'owed' (what is in the wallet is taken now, the
--    rider's share first; the rest is a c2c_driver_fees row, taken from the
--    driver's next earnings as they land, and the rider's part paid to the
--    rider as it is). The default seeds with the charge OFF (RM 30 inside
--    24 h, to the rider, may go negative), so nothing changes until an
--    admin turns it on. c2c_driver_cancel (0308) charges it.
-- 2. In-app payment (c2c_pay_rules, default + regions as above): when the
--    rider pays: 'hold' (at accept) or 'after' (after Complete trip, as city
--    rides); ways: GET.wallet, GET.coin, mix (coins first, the rest from the
--    wallet; needs both); if short: offer Top up, offer Switch to cash.
--    Cash trips are not touched. The rule is read at accept and kept on the
--    booking (pay_mode).
--    Hold: c2c_accept_offer_pay(offer, method, expected) takes the fare (and
--    the cancel fees owed, item 3) from the rider at accept: coins as
--    'redeem', the wallet part as 'c2c_hold', one c2c_payments row 'held'.
--    Short: C2C_WALLET_SHORT and nothing changes. At Complete trip
--    (c2c_driver_progress) the fare goes to the driver ('c2c_earning') and
--    the commission comes off it in the same ledger ('commission', GET
--    wallet), stamped on the booking as 0307's charge does, so 0307's
--    c2c_charge_commission (GET.credit) does not run for it: never twice.
--    A rider's cancel (c2c_cancel) gives the held fare back less the cancel
--    fee (0307's rule; the fee to the driver less commission, as before); an
--    admin's cancel and a driver giving up give it all back ('c2c_refund';
--    coins back at the coin rate of the hold, rounded down).
--    After: the commission is charged at completion as 0307 does; the rider
--    pays with c2c_pay(booking, method, expected): ride_pay's checks
--    (wallet / coin / mix, the amount they saw, idempotent), the driver
--    credited the fare ('c2c_earning').
--    c2c_accept_offer(offer) (0307's, one argument, kept for the apps and
--    tests that call it) is c2c_accept_offer_pay with the rule's first way.
--    c2c_switch_to_cash(booking): the rider, when the rule offers it and
--    Cash is on, before a driver is picked or after the trip while unpaid.
--    c2c_pay_info(booking): what the rider's pay sheet needs.
-- 3. Cancel fees a rider owes (0307's 'due'): city_to_city_settings gains
--    owed_from_topup (taken when the rider's GET wallet is topped up),
--    owed_next_in_app (added to the next in-app payment), owed_cash_collect
--    (the driver of the rider's next cash trip collects it and marks it:
--    c2c_mark_collected; their GET.credit is charged what they took in cash
--    and the fee goes to the driver it was owed to, less commission) and
--    owed_block (no new City to City booking until paid: C2C_FEES_OWED).
--    Any combination. c2c_my_owed() shows the rider (and a driver, their
--    give-up fees owed) what they owe and why; c2c_pay_owed() is Pay now in
--    Wallet. A paid fee is 'charged' with cancel_fee_paid_at and _via.
--    The collection on a top-up and on a driver's earnings is an AFTER
--    INSERT trigger on wallet_transactions (trg_wallet_tx_c2c_collect): a
--    GET.wallet credit of kind 'topup', or an earning ('ride_earning',
--    'ride_coin_payout', 'c2c_earning', 'cancellation_fee', 'stand_payout',
--    'stand_fee_earning'). It never stands in the way of the credit.
-- 4. Trip reminders: city_to_city_settings gains reminders_on, the list
--    (reminders: [{minutes, to: rider | driver | both}], up to 10, 5 minutes
--    to 7 days, each time once; default 1 day both, 2 h both, 30 min the
--    driver) and the channels (reminder_push, reminder_inbox, reminder_sms).
--    c2c_send_reminders() (pg_cron 'c2c-send-reminders', every 5 minutes)
--    sends each due reminder once per booking, reminder and person
--    (c2c_reminder_log): booked or on the way only (none after a cancel or
--    give-up); one whose time had passed when the trip was booked, or that
--    is more than 30 minutes late, is skipped. Push: the outbox (0144,
--    event 'c2c-rem:<booking>:<minutes>', kind and type 'c2c_reminder'),
--    which keeps it on the Notifications page too unless that channel is
--    off (data.inbox false; send-push skips it). Push off, page on: the
--    page row is written here. SMS: a pushed reminder the app hasn't
--    confirmed after 2 minutes goes once by SMS through the gateway, with
--    0150's number, refusal rules and gateway check (needs push on).
-- 5. Admins with EDIT on admin-settings-city-to-city write the rules
--    (admin_table_pages); everyone signed in reads them. Payments and fees
--    owed: their own people and admins read; only these functions write.
--    None of the functions here is on 0223's rewrite list.
-- ============================================================================

-- ---- 3, 4. Settings ---------------------------------------------------------------------------------------
-- A list of reminders: up to 10, each {minutes 5..10080, to}, no time twice.
create or replace function public.c2c_reminders_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(p) = 'array'
     and jsonb_array_length(p) <= 10
     and not exists (
       select 1 from jsonb_array_elements(p) e
        where case when jsonb_typeof(e) <> 'object' or jsonb_typeof(e->'minutes') <> 'number' then true
                   else (e->>'minutes')::numeric <> trunc((e->>'minutes')::numeric)
                        or (e->>'minutes')::numeric not between 5 and 10080
                        or coalesce(e->>'to', '') not in ('rider', 'driver', 'both') end)
     and (select count(distinct e->>'minutes') from jsonb_array_elements(p) e) = jsonb_array_length(p);
$$;

alter table public.city_to_city_settings add column if not exists owed_from_topup boolean not null default true;
alter table public.city_to_city_settings add column if not exists owed_next_in_app boolean not null default true;
alter table public.city_to_city_settings add column if not exists owed_cash_collect boolean not null default false;
alter table public.city_to_city_settings add column if not exists owed_block boolean not null default false;
alter table public.city_to_city_settings add column if not exists reminders_on boolean not null default true;
alter table public.city_to_city_settings add column if not exists reminder_push boolean not null default true;
alter table public.city_to_city_settings add column if not exists reminder_inbox boolean not null default true;
alter table public.city_to_city_settings add column if not exists reminder_sms boolean not null default false;
alter table public.city_to_city_settings add column if not exists reminders jsonb not null
  default '[{"minutes": 1440, "to": "both"}, {"minutes": 120, "to": "both"}, {"minutes": 30, "to": "driver"}]'::jsonb;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'city_to_city_settings_reminders') then
    alter table public.city_to_city_settings add constraint city_to_city_settings_reminders
      check (public.c2c_reminders_valid(reminders));
  end if;
end $$;
comment on column public.city_to_city_settings.reminders is
  'Trip reminders (0309): [{minutes before the time to leave, to: rider | driver | both}].';

-- ---- 1, 2. Rules by region ----------------------------------------------------------------------------------
-- One place {level, country, state, city, suburb} (0306's shape), or null.
create or replace function public.c2c_place_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p is null or public.c2c_places_valid(jsonb_build_array(p));
$$;

create table if not exists public.c2c_giveup_rules (
  id            uuid primary key default gen_random_uuid(),
  -- Null: the default, for every pickup without a region rule.
  place         jsonb check (public.c2c_place_valid(place)),
  charge        boolean not null default true,
  amount        numeric(10,2) not null default 30 check (amount between 0 and 10000),
  when_mode     text not null default 'within' check (when_mode in ('within', 'always')),
  free_hours    integer not null default 24 check (free_hours between 0 and 720),
  dest          text not null default 'rider' check (dest in ('rider', 'platform', 'split')),
  split_mode    text not null default 'percent' check (split_mode in ('percent', 'fixed')),
  split_percent numeric(5,2) not null default 70 check (split_percent between 0 and 100),
  split_fixed   numeric(10,2) not null default 20 check (split_fixed between 0 and 10000),
  short_mode    text not null default 'negative' check (short_mode in ('negative', 'owed')),
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    uuid
);
comment on table public.c2c_giveup_rules is
  'City to City (0309): what a driver pays to give a booked trip up. The pickup''s most specific region wins, else the default (place null).';

create table if not exists public.c2c_pay_rules (
  id           uuid primary key default gen_random_uuid(),
  place        jsonb check (public.c2c_place_valid(place)),
  when_mode    text not null default 'hold' check (when_mode in ('hold', 'after')),
  pay_wallet   boolean not null default true,
  pay_coin     boolean not null default true,
  pay_mix      boolean not null default true,
  offer_topup  boolean not null default true,
  offer_cash   boolean not null default true,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  constraint c2c_pay_rules_ways check (pay_wallet or pay_coin),
  constraint c2c_pay_rules_mix check (not pay_mix or (pay_wallet and pay_coin))
);
comment on table public.c2c_pay_rules is
  'City to City (0309): how a trip paid In app is charged. The pickup''s most specific region wins, else the default (place null).';

do $$
declare
  t text;
begin
  foreach t in array array['c2c_giveup_rules', 'c2c_pay_rules'] loop
    execute format('create unique index if not exists %I on public.%I ((true)) where place is null', t || '_default', t);
    execute format('create unique index if not exists %I on public.%I (lower(place::text)) where place is not null',
                   t || '_place', t);
  end loop;
end $$;

insert into public.c2c_giveup_rules (id, place, charge)
select '63326331-0000-4000-8000-000000000309', null, false
 where not exists (select 1 from public.c2c_giveup_rules where place is null)
on conflict (id) do nothing;
insert into public.c2c_pay_rules (id, place)
select '63326331-0000-4000-8000-00000000030a', null
 where not exists (select 1 from public.c2c_pay_rules where place is null)
on conflict (id) do nothing;

-- The default stays the default: never deleted, never given a place; a
-- region rule never becomes the default.
create or replace function public.c2c_region_rule_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    if old.place is null then
      raise exception 'C2C_DEFAULT_RULE' using errcode = '22023', hint = 'The default rule can''t be removed.';
    end if;
    return old;
  end if;
  if (old.place is null) <> (new.place is null) then
    raise exception 'C2C_DEFAULT_RULE' using errcode = '22023', hint = 'The default rule has no region.';
  end if;
  return new;
end;
$$;
revoke execute on function public.c2c_region_rule_guard() from public, anon, authenticated;

do $rls$
declare
  t text;
begin
  foreach t in array array['c2c_giveup_rules', 'c2c_pay_rules'] loop
    execute format('drop trigger if exists %I on public.%I', 'trg_' || t || '_stamp', t);
    execute format('create trigger %I before insert or update on public.%I for each row execute function public.c2c_stamp()',
                   'trg_' || t || '_stamp', t);
    execute format('drop trigger if exists %I on public.%I', 'trg_' || t || '_guard', t);
    execute format('create trigger %I before update or delete on public.%I for each row execute function public.c2c_region_rule_guard()',
                   'trg_' || t || '_guard', t);
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
    execute format('create policy %I on public.%I for insert to authenticated with check ((select public.caller_admin_can_write(%L)))',
                   t || ' admin insert', t, t);
    execute format('create policy %I on public.%I for update to authenticated using ((select public.caller_admin_can_write(%L))) with check ((select public.caller_admin_can_write(%L)))',
                   t || ' admin update', t, t, t);
    execute format('create policy %I on public.%I for delete to authenticated using ((select public.caller_admin_can_write(%L)))',
                   t || ' admin delete', t, t);
  end loop;
end
$rls$;

insert into public.admin_table_pages (target, page) values
  ('c2c_giveup_rules', 'admin-settings-city-to-city'),
  ('c2c_pay_rules', 'admin-settings-city-to-city')
on conflict do nothing;

-- The rule for a pickup at [p_pickup] ({country, state, city, suburb}).
create or replace function public.c2c_giveup_rule_for(p_pickup jsonb)
returns setof public.c2c_giveup_rules
language sql
stable
security definer
set search_path = public
as $$
  select (x.r).*
    from (select r, case when r.place is null then 0
                         else public.c2c_place_rank(r.place, coalesce(p_pickup, '{}'::jsonb)) end as rk
            from public.c2c_giveup_rules r
           where r.place is null or r.active) x
   where (x.r).place is null or x.rk > 0
   order by x.rk desc, (x.r).created_at, (x.r).id
   limit 1;
$$;
revoke execute on function public.c2c_giveup_rule_for(jsonb) from public, anon;
grant execute on function public.c2c_giveup_rule_for(jsonb) to authenticated, service_role;

create or replace function public.c2c_pay_rule_for(p_pickup jsonb)
returns setof public.c2c_pay_rules
language sql
stable
security definer
set search_path = public
as $$
  select (x.r).*
    from (select r, case when r.place is null then 0
                         else public.c2c_place_rank(r.place, coalesce(p_pickup, '{}'::jsonb)) end as rk
            from public.c2c_pay_rules r
           where r.place is null or r.active) x
   where (x.r).place is null or x.rk > 0
   order by x.rk desc, (x.r).created_at, (x.r).id
   limit 1;
$$;
revoke execute on function public.c2c_pay_rule_for(jsonb) from public, anon;
grant execute on function public.c2c_pay_rule_for(jsonb) to authenticated, service_role;

-- ---- 2, 3. The booking's money --------------------------------------------------------------------------------
alter table public.c2c_bookings add column if not exists pay_mode text;
alter table public.c2c_bookings add column if not exists pay_status text;
alter table public.c2c_bookings add column if not exists paid_method text;
alter table public.c2c_bookings add column if not exists paid_amount numeric(10,2);
alter table public.c2c_bookings add column if not exists paid_at timestamptz;
alter table public.c2c_bookings add column if not exists collect_amount numeric(10,2);
alter table public.c2c_bookings add column if not exists collect_fee_ids uuid[];
alter table public.c2c_bookings add column if not exists collected_at timestamptz;
alter table public.c2c_bookings add column if not exists cancel_fee_paid_at timestamptz;
alter table public.c2c_bookings add column if not exists cancel_fee_paid_via text;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'c2c_bookings_pay_mode') then
    alter table public.c2c_bookings add constraint c2c_bookings_pay_mode
      check (pay_mode is null or pay_mode in ('hold', 'after'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'c2c_bookings_pay_status') then
    alter table public.c2c_bookings add constraint c2c_bookings_pay_status
      check (pay_status is null or pay_status in ('held', 'paid', 'refunded', 'unpaid', 'cash'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'c2c_bookings_fee_paid_via') then
    alter table public.c2c_bookings add constraint c2c_bookings_fee_paid_via
      check (cancel_fee_paid_via is null or cancel_fee_paid_via in ('topup', 'in_app', 'cash', 'pay_now'));
  end if;
end $$;
create index if not exists c2c_bookings_due_idx on public.c2c_bookings (rider_id, cancelled_at)
  where cancel_fee_status = 'due';
comment on column public.c2c_bookings.pay_status is
  'In-app payment (0309): held (taken at accept), paid, refunded, unpaid (pay after the trip), cash (switched).';
comment on column public.c2c_bookings.collect_fee_ids is
  'Cancel fees the rider owes that the driver of this cash trip collects (0309).';

create table if not exists public.c2c_payments (
  id             uuid primary key default gen_random_uuid(),
  booking_id     uuid not null references public.c2c_bookings(id) on delete cascade,
  rider_id       uuid not null references public.profiles(id) on delete cascade,
  driver_id      uuid references public.profiles(id) on delete set null,
  mode           text not null check (mode in ('hold', 'after')),
  status         text not null check (status in ('held', 'released', 'refunded', 'paid')),
  method         text not null check (method in ('get_wallet', 'get_coin', 'mix')),
  -- The fare; the part of it from the wallet and from coins.
  amount         numeric(10,2) not null check (amount >= 0),
  wallet_amount  numeric(10,2) not null default 0,
  coin_value     numeric(10,2) not null default 0,
  coins          numeric(12,2) not null default 0,
  coin_rate      numeric(12,4),
  -- Cancel fees owed paid with it (item 3).
  dues_amount    numeric(10,2) not null default 0,
  due_ids        uuid[] not null default '{}',
  fee_kept       numeric(10,2),
  refund_wallet  numeric(10,2),
  refund_coins   numeric(12,2),
  commission     numeric(10,2),
  created_at     timestamptz not null default now(),
  settled_at     timestamptz
);
create unique index if not exists c2c_payments_one_held on public.c2c_payments (booking_id) where status = 'held';
create unique index if not exists c2c_payments_one_paid on public.c2c_payments (booking_id)
  where mode = 'after' and status = 'paid';
create index if not exists c2c_payments_rider_idx on public.c2c_payments (rider_id, created_at desc);
comment on table public.c2c_payments is
  'City to City (0309): a fare paid in the app, held at booking or paid after the trip.';

create table if not exists public.c2c_driver_fees (
  id          uuid primary key default gen_random_uuid(),
  driver_id   uuid not null references public.profiles(id) on delete cascade,
  booking_id  uuid references public.c2c_bookings(id) on delete set null,
  ref         text,
  rider_id    uuid references public.profiles(id) on delete set null,
  fee         numeric(10,2) not null check (fee > 0),
  to_rider    numeric(10,2) not null default 0,
  to_platform numeric(10,2) not null default 0,
  short_mode  text not null check (short_mode in ('negative', 'owed')),
  -- Taken now from the GET wallet (and from GET.credit when it may go negative).
  taken       numeric(10,2) not null default 0,
  from_credit numeric(10,2) not null default 0,
  -- Still owed, and the rider's part of it.
  owed        numeric(10,2) not null default 0 check (owed >= 0),
  owed_rider  numeric(10,2) not null default 0 check (owed_rider >= 0),
  status      text not null default 'paid' check (status in ('owed', 'paid')),
  created_at  timestamptz not null default now(),
  paid_at     timestamptz
);
create index if not exists c2c_driver_fees_driver_idx on public.c2c_driver_fees (driver_id, created_at desc);
create index if not exists c2c_driver_fees_owed_idx on public.c2c_driver_fees (driver_id, created_at)
  where status = 'owed';
comment on table public.c2c_driver_fees is
  'City to City (0309): each fee a driver paid to give a booked trip up, and what of it is still owed.';

create table if not exists public.c2c_reminder_log (
  booking_id uuid not null references public.c2c_bookings(id) on delete cascade,
  minutes    integer not null,
  profile_id uuid not null,
  skipped    boolean not null default false,
  sent_at    timestamptz not null default now(),
  primary key (booking_id, minutes, profile_id)
);
comment on table public.c2c_reminder_log is
  'City to City (0309): each trip reminder sent (or skipped), once per booking, reminder and person.';

alter table public.c2c_payments enable row level security;
alter table public.c2c_driver_fees enable row level security;
alter table public.c2c_reminder_log enable row level security;
revoke all on public.c2c_payments, public.c2c_driver_fees, public.c2c_reminder_log from anon, authenticated;
grant select on public.c2c_payments, public.c2c_driver_fees to authenticated;
grant all on public.c2c_payments, public.c2c_driver_fees, public.c2c_reminder_log to service_role;
drop policy if exists "c2c_payments read" on public.c2c_payments;
create policy "c2c_payments read" on public.c2c_payments for select to authenticated
  using (rider_id = (select auth.uid()) or driver_id = (select auth.uid()) or (select public.caller_is_admin()));
drop policy if exists "c2c_driver_fees read" on public.c2c_driver_fees;
create policy "c2c_driver_fees read" on public.c2c_driver_fees for select to authenticated
  using (driver_id = (select auth.uid()) or (select public.caller_is_admin()));

-- What the rider may not set on a new request, and the block (item 3).
-- Runs after trg_c2c_bookings_check (0307), which set the rider.
create or replace function public.c2c_bookings_check_money()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owed numeric;
begin
  new.pay_mode := null;
  new.pay_status := null;
  new.paid_method := null;
  new.paid_amount := null;
  new.paid_at := null;
  new.collect_amount := null;
  new.collect_fee_ids := null;
  new.collected_at := null;
  new.cancel_fee_paid_at := null;
  new.cancel_fee_paid_via := null;
  if coalesce((select s.owed_block from public.city_to_city_settings s where s.id = 1), false) then
    select sum(b.cancel_fee) into v_owed from public.c2c_bookings b
     where b.rider_id = new.rider_id and b.cancel_fee_status = 'due' and b.cancel_fee > 0;
    if coalesce(v_owed, 0) > 0 then
      raise exception 'C2C_FEES_OWED' using errcode = '22023',
        hint = 'Pay ' || public.c2c_money(v_owed, new.currency) || ' owed first. Open Wallet to pay it.';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.c2c_bookings_check_money() from public, anon, authenticated;
drop trigger if exists trg_c2c_bookings_owed on public.c2c_bookings;
create trigger trg_c2c_bookings_owed
  before insert on public.c2c_bookings
  for each row execute function public.c2c_bookings_check_money();

-- ---- Money helpers ------------------------------------------------------------------------------------------
-- How [p_total] is paid by [p_method] ('get_wallet', 'get_coin', 'mix')
-- from a wallet of [p_wallet] and [p_coins] coins at [p_rate] coins per
-- unit: the wallet part, the coins' value, the coins (rounded up, as
-- ride_pay) and how much is short. lib/src/core/city_to_city.dart's
-- c2cPaySplit is its twin.
create or replace function public.c2c_pay_split(p_total numeric, p_method text, p_wallet numeric, p_coins numeric,
                                                p_rate numeric)
returns table (wallet_part numeric, coin_value numeric, coins numeric, short numeric)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_total numeric := round(greatest(coalesce(p_total, 0), 0), 2);
  v_rate numeric := coalesce(p_rate, 0);
  v_wallet numeric := greatest(coalesce(p_wallet, 0), 0);
  v_max numeric := case when coalesce(p_rate, 0) > 0
                        then floor(greatest(coalesce(p_coins, 0), 0) / p_rate * 100) / 100 else 0 end;
  v_cv numeric;
begin
  if p_method = 'get_coin' then
    return query select 0::numeric, v_total,
                        case when v_rate > 0 then ceil(v_total * v_rate * 100) / 100 else 0::numeric end,
                        greatest(v_total - v_max, 0);
  elsif p_method = 'mix' then
    v_cv := least(v_max, v_total);
    return query select v_total - v_cv, v_cv,
                        case when v_rate > 0 then ceil(v_cv * v_rate * 100) / 100 else 0::numeric end,
                        greatest(v_total - v_cv - v_wallet, 0);
  else
    return query select v_total, 0::numeric, 0::numeric, greatest(v_total - v_wallet, 0);
  end if;
end;
$$;
revoke execute on function public.c2c_pay_split(numeric, text, numeric, numeric, numeric) from public, anon;
grant execute on function public.c2c_pay_split(numeric, text, numeric, numeric, numeric) to authenticated, service_role;

-- The commission rate of booking [b]: the one locked as it was booked, else
-- found now as 0307's c2c_charge_commission finds it.
create or replace function public.c2c_commission_of(b public.c2c_bookings)
returns table (rate numeric, rule_id uuid, tier_id uuid, promotion_id uuid)
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
  if b.commission_locked_at is not null and b.commission_rate is not null then
    return query select b.commission_rate, b.commission_rule_id, b.commission_tier_id, b.commission_promotion_id;
    return;
  end if;
  select * into v from public.commission_resolve(
    b.driver_id, b.pickup_lat, b.pickup_lng, b.pickup_place->>'country', b.pickup_place->>'state',
    b.pickup_place->>'city', b.pickup_place->>'suburb', b.service);
  select * into t from public.commission_apply_tiers(b.driver_id, v.rate, v.level);
  select * into pm from public.commission_apply_promotions(
    b.driver_id, t.rate, v.level, coalesce(b.booked_at, now()), coalesce(b.timezone, 'Asia/Kuala_Lumpur'), b.service,
    b.pickup_lat, b.pickup_lng, b.pickup_place->>'country', b.pickup_place->>'state',
    b.pickup_place->>'city', b.pickup_place->>'suburb');
  return query select pm.rate, v.rule_id, case when pm.promotion_id is null then t.tier_id end, pm.promotion_id;
exception when others then
  return query select null::numeric, null::uuid, null::uuid, null::uuid;
end;
$$;
revoke execute on function public.c2c_commission_of(public.c2c_bookings) from public, anon, authenticated;

-- Pays the cancel fee owed on [d] (cancelled, 'due'): from the rider's GET
-- wallet when [p_debit] (the caller checked it holds it; else the caller
-- took the money), by [p_via]; in cash ('cash'), the collector [p_collector]
-- is charged it on GET.credit. The driver it was owed to gets it less the
-- trip's commission, as 0307's c2c_fee_take pays it.
create or replace function public.c2c_settle_due(d public.c2c_bookings, p_via text, p_debit boolean,
                                                 p_collector uuid default null)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amount numeric := round(coalesce(d.cancel_fee, 0), 2);
  v_rate numeric := case when d.commission_rate >= 0 and d.commission_rate < 1 then d.commission_rate else 0 end;
  v_label text := 'City to City cancellation fee ' || d.ref || ' (owed)';
begin
  if v_amount <= 0 or d.cancel_fee_status is distinct from 'due' then
    return 0;
  end if;
  if p_debit then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (d.rider_id, 'get_wallet', 'payment', -v_amount, 'cancellation_fee',
            v_label || case p_via when 'topup' then ', taken from your top-up'
                                  when 'pay_now' then ', paid in Wallet' else '' end);
  end if;
  if p_via = 'cash' and p_collector is not null then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (p_collector, 'get_credit', 'c2c_fee_collected', -v_amount, 'cancellation_fee',
            v_label || ', collected by you in cash');
  end if;
  if d.driver_id is not null then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (d.driver_id, 'get_wallet', 'cancellation_fee', round(v_amount * (1 - v_rate), 2), 'cancellation_fee',
            v_label || case when v_rate > 0 then ' (less ' || round(v_rate * 100, 1) || '% commission)' else '' end);
  end if;
  update public.c2c_bookings
     set cancel_fee_status = 'charged', cancel_fee_paid_at = now(), cancel_fee_paid_via = p_via
   where id = d.id;
  return v_amount;
end;
$$;
revoke execute on function public.c2c_settle_due(public.c2c_bookings, text, boolean, uuid) from public, anon, authenticated;

-- Pays [p_rider]'s owed cancel fees, oldest first, each one whole, while
-- their GET wallet holds it. How much was paid.
create or replace function public.c2c_collect_rider_dues(p_rider uuid, p_via text)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  d public.c2c_bookings;
  v_balance numeric;
  v_paid numeric := 0;
begin
  for d in
    select * from public.c2c_bookings
     where rider_id = p_rider and cancel_fee_status = 'due' and cancel_fee > 0
     order by cancelled_at, id
     for update
  loop
    select w.balance into v_balance from public.wallets w
     where w.user_id = p_rider and w.wallet_type = 'get_wallet' for update;
    continue when coalesce(v_balance, 0) < d.cancel_fee;
    v_paid := v_paid + public.c2c_settle_due(d, p_via, true, null);
  end loop;
  return v_paid;
end;
$$;
revoke execute on function public.c2c_collect_rider_dues(uuid, text) from public, anon, authenticated;

-- Takes [p_driver]'s owed give-up fees from their GET wallet, oldest first,
-- as far as it goes (a part when that is all there is); the rider's part of
-- each goes to the rider. How much was taken.
create or replace function public.c2c_collect_driver_fees(p_driver uuid, p_why text default 'earnings')
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  f public.c2c_driver_fees;
  v_balance numeric;
  v_take numeric;
  v_rider numeric;
  v_paid numeric := 0;
begin
  for f in
    select * from public.c2c_driver_fees
     where driver_id = p_driver and status = 'owed' and owed > 0
     order by created_at, id
     for update
  loop
    select w.balance into v_balance from public.wallets w
     where w.user_id = p_driver and w.wallet_type = 'get_wallet' for update;
    v_take := least(greatest(coalesce(v_balance, 0), 0), f.owed);
    exit when v_take <= 0;
    v_rider := case when f.rider_id is null then 0 else least(v_take, f.owed_rider) end;
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (p_driver, 'get_wallet', 'c2c_giveup_fee', -v_take, 'c2c_giveup',
            'City to City give-up fee ' || coalesce(f.ref, '') || ' (owed), '
            || case when p_why = 'pay_now' then 'paid in Wallet' else 'taken from your earnings' end);
    if v_rider > 0 then
      insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
      values (f.rider_id, 'get_wallet', 'c2c_giveup_comp', v_rider, 'c2c_giveup',
              'City to City ' || coalesce(f.ref, '') || ': the rest of what your driver owed for giving the trip up');
    end if;
    update public.c2c_driver_fees
       set owed = owed - v_take, owed_rider = greatest(owed_rider - v_rider, 0),
           status = case when owed - v_take <= 0 then 'paid' else 'owed' end,
           paid_at = case when owed - v_take <= 0 then now() else paid_at end
     where id = f.id;
    v_paid := v_paid + v_take;
  end loop;
  return v_paid;
end;
$$;
revoke execute on function public.c2c_collect_driver_fees(uuid, text) from public, anon, authenticated;

-- A top-up pays the rider's owed cancel fees (when the settings say so); a
-- driver's earnings pay their owed give-up fees. Never stands in the way
-- of the credit itself.
create or replace function public.c2c_wallet_tx_collect()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.amount is null or new.amount <= 0 or new.wallet_type <> 'get_wallet' then
    return null;
  end if;
  begin
    if new.kind = 'topup' then
      if coalesce((select s.owed_from_topup from public.city_to_city_settings s where s.id = 1), false)
         and exists (select 1 from public.c2c_bookings b
                      where b.rider_id = new.user_id and b.cancel_fee_status = 'due' and b.cancel_fee > 0) then
        perform public.c2c_collect_rider_dues(new.user_id, 'topup');
      end if;
    elsif new.kind in ('ride_earning', 'ride_coin_payout', 'c2c_earning', 'cancellation_fee', 'stand_payout',
                       'stand_fee_earning') then
      if exists (select 1 from public.c2c_driver_fees f where f.driver_id = new.user_id and f.status = 'owed') then
        perform public.c2c_collect_driver_fees(new.user_id, 'earnings');
      end if;
    end if;
  exception when others then
    raise warning 'c2c fees not collected for %: %', new.user_id, sqlerrm;
  end;
  return null;
end;
$$;
revoke execute on function public.c2c_wallet_tx_collect() from public, anon, authenticated;
drop trigger if exists trg_wallet_tx_c2c_collect on public.wallet_transactions;
create trigger trg_wallet_tx_c2c_collect
  after insert on public.wallet_transactions
  for each row execute function public.c2c_wallet_tx_collect();

-- ---- 1. The driver gives up a booked trip ----------------------------------------------------------------
-- The fee under rule [r] to give up at [p_at] a trip leaving at
-- [p_leave_at], and how it splits (lib/src/core/city_to_city.dart's
-- c2cGiveUpFee is its twin).
create or replace function public.c2c_giveup_fee(r public.c2c_giveup_rules, p_leave_at timestamptz,
                                                 p_at timestamptz default now())
returns table (fee numeric, to_rider numeric, to_platform numeric)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_fee numeric;
  v_rider numeric;
begin
  if r.id is null or not r.charge or coalesce(r.amount, 0) <= 0
     or (r.when_mode = 'within' and p_at < p_leave_at - make_interval(hours => r.free_hours)) then
    return query select 0::numeric, 0::numeric, 0::numeric;
    return;
  end if;
  v_fee := round(r.amount, 2);
  v_rider := case r.dest
    when 'rider' then v_fee
    when 'platform' then 0
    else case when r.split_mode = 'fixed' then least(round(r.split_fixed, 2), v_fee)
              else round(v_fee * r.split_percent / 100, 2) end
  end;
  return query select v_fee, v_rider, v_fee - v_rider;
end;
$$;
revoke execute on function public.c2c_giveup_fee(public.c2c_giveup_rules, timestamptz, timestamptz) from public, anon;
grant execute on function public.c2c_giveup_fee(public.c2c_giveup_rules, timestamptz, timestamptz)
  to authenticated, service_role;

-- Charges the booked driver of [b] the give-up fee [p_fee] under [r]
-- (item 1). The c2c_driver_fees row.
create or replace function public.c2c_giveup_charge(b public.c2c_bookings, r public.c2c_giveup_rules, p_fee numeric,
                                                    p_to_rider numeric, p_to_platform numeric)
returns public.c2c_driver_fees
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance numeric;
  v_take numeric;
  v_credit numeric := 0;
  v_rider_now numeric;
  v_label text := 'City to City trip given up ' || b.ref;
  f public.c2c_driver_fees;
begin
  insert into public.wallets (user_id, wallet_type, balance) values (b.driver_id, 'get_wallet', 0)
  on conflict (user_id, wallet_type) do nothing;
  select w.balance into v_balance from public.wallets w
   where w.user_id = b.driver_id and w.wallet_type = 'get_wallet' for update;
  v_take := least(greatest(coalesce(v_balance, 0), 0), p_fee);
  if v_take > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (b.driver_id, 'get_wallet', 'c2c_giveup_fee', -v_take, 'c2c_giveup', v_label);
  end if;
  if r.short_mode = 'negative' then
    v_credit := p_fee - v_take;
    if v_credit > 0 then
      insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
      values (b.driver_id, 'get_credit', 'c2c_giveup_fee', -v_credit, 'c2c_giveup',
              v_label || ' (from GET.credit: the GET wallet was short)');
    end if;
    v_rider_now := p_to_rider;
  else
    v_rider_now := least(v_take, p_to_rider);
  end if;
  if v_rider_now > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (b.rider_id, 'get_wallet', 'c2c_giveup_comp', v_rider_now, 'c2c_giveup',
            'City to City ' || b.ref || ': your driver gave the trip up');
  end if;
  insert into public.c2c_driver_fees (driver_id, booking_id, ref, rider_id, fee, to_rider, to_platform, short_mode,
                                      taken, from_credit, owed, owed_rider, status, paid_at)
  values (b.driver_id, b.id, b.ref, b.rider_id, p_fee, p_to_rider, p_to_platform, r.short_mode,
          v_take, v_credit, p_fee - v_take - v_credit, p_to_rider - v_rider_now,
          case when p_fee - v_take - v_credit > 0 then 'owed' else 'paid' end,
          case when p_fee - v_take - v_credit > 0 then null else now() end)
  returning * into f;
  return f;
end;
$$;
revoke execute on function public.c2c_giveup_charge(public.c2c_bookings, public.c2c_giveup_rules, numeric, numeric, numeric)
  from public, anon, authenticated;

-- ---- 2. Held fares ----------------------------------------------------------------------------------------
-- Why a short wallet can't pay, in the rider's words.
create or replace function public.c2c_short_hint(p_short numeric, p_method text, p_currency text,
                                                 p_topup boolean, p_cash boolean)
returns text
language sql
immutable
set search_path = public
as $$
  select case when p_method = 'get_coin' then 'Your coins are ' else 'Your GET wallet is ' end
         || public.c2c_money(p_short, p_currency) || ' short.'
         || case when p_topup and p_cash then ' Top up, or switch this trip to cash.'
                 when p_topup then ' Top up first.'
                 when p_cash then ' Switch this trip to cash, or pay another way.'
                 else '' end;
$$;

-- Takes the fare [p_fare] of [b] (and, when the settings say so, the
-- cancel fees the rider owes) from the rider by [p_method] under rule [pr]
-- (hold, or pay after the trip when [p_hold] is false). The c2c_payments row.
create or replace function public.c2c_take_fare(b public.c2c_bookings, p_fare numeric, p_method text,
                                                p_expected numeric, pr public.c2c_pay_rules, p_hold boolean)
returns public.c2c_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.city_to_city_settings;
  v_fare numeric := round(coalesce(p_fare, 0), 2);
  v_dues numeric := 0;
  v_due_ids uuid[] := '{}';
  v_total numeric;
  v_rate numeric;
  v_wallet numeric;
  v_coins numeric;
  sp record;
  v_fare_cv numeric;
  v_fare_wallet numeric;
  v_due_wallet numeric;
  d public.c2c_bookings;
  p public.c2c_payments;
begin
  if p_method is null or p_method not in ('get_wallet', 'get_coin', 'mix')
     or (p_method = 'get_wallet' and not pr.pay_wallet)
     or (p_method = 'get_coin' and not pr.pay_coin)
     or (p_method = 'mix' and not pr.pay_mix) then
    raise exception 'C2C_PAY_WAY' using errcode = '22023', hint = 'That way to pay isn''t offered here. Pick another.';
  end if;
  if v_fare <= 0 then
    raise exception 'invalid_amount';
  end if;
  select * into s from public.city_to_city_settings where id = 1;
  if coalesce(s.owed_next_in_app, false) then
    select coalesce(sum(x.cancel_fee), 0), coalesce(array_agg(x.id order by x.cancelled_at, x.id), '{}')
      into v_dues, v_due_ids
      from public.c2c_bookings x
     where x.rider_id = b.rider_id and x.cancel_fee_status = 'due' and x.cancel_fee > 0;
  end if;
  v_total := v_fare + v_dues;
  -- The rider agreed to pay what they were shown.
  if p_expected is not null and abs(round(p_expected, 2) - v_total) > 0.005 then
    raise exception 'C2C_AMOUNT_CHANGED' using errcode = '22023',
      hint = 'The amount is now ' || public.c2c_money(v_total, b.currency) || '. Check it and try again.';
  end if;

  select g.coins_per_currency into v_rate from public.get_coin_settings g where g.id = 'master';
  if p_method = 'get_coin' and coalesce(v_rate, 0) <= 0 then
    raise exception 'C2C_PAY_WAY' using errcode = '22023', hint = 'Paying with coins isn''t available now.';
  end if;
  insert into public.wallets (user_id, wallet_type, balance)
  values (b.rider_id, 'get_wallet', 0), (b.rider_id, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;
  select w.balance into v_wallet from public.wallets w
   where w.user_id = b.rider_id and w.wallet_type = 'get_wallet' for update;
  select w.balance into v_coins from public.wallets w
   where w.user_id = b.rider_id and w.wallet_type = 'get_coin' for update;
  select * into sp from public.c2c_pay_split(v_total, p_method, v_wallet, v_coins, v_rate);
  if sp.short > 0 then
    raise exception 'C2C_WALLET_SHORT' using errcode = '22023',
      hint = public.c2c_short_hint(sp.short, p_method, b.currency, pr.offer_topup,
                                   pr.offer_cash and coalesce(s.pay_cash, true));
  end if;

  -- Coins pay the fare first, then the fees owed.
  v_fare_cv := least(sp.coin_value, v_fare);
  v_fare_wallet := v_fare - v_fare_cv;
  v_due_wallet := v_dues - (sp.coin_value - v_fare_cv);
  if sp.coins > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (b.rider_id, 'get_coin', 'redeem', -sp.coins, 'c2c_fare',
            'City to City ' || b.ref || ': ' || public.c2c_money(sp.coin_value, b.currency) || ' paid with coins');
  end if;
  if v_fare_wallet > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (b.rider_id, 'get_wallet', case when p_hold then 'c2c_hold' else 'c2c_payment' end, -v_fare_wallet,
            'c2c_fare',
            case when p_hold then 'City to City fare held ' || b.ref || ' (paid to the driver when the trip is complete)'
                 else 'City to City fare paid ' || b.ref end);
  end if;
  if v_due_wallet > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (b.rider_id, 'get_wallet', 'payment', -v_due_wallet, 'cancellation_fee',
            'City to City cancel fees owed, paid with ' || b.ref);
  end if;
  for d in select * from public.c2c_bookings where id = any(v_due_ids) for update loop
    perform public.c2c_settle_due(d, 'in_app', false, null);
  end loop;

  insert into public.c2c_payments (booking_id, rider_id, driver_id, mode, status, method, amount, wallet_amount,
                                   coin_value, coins, coin_rate, dues_amount, due_ids, settled_at)
  values (b.id, b.rider_id, b.driver_id, case when p_hold then 'hold' else 'after' end,
          case when p_hold then 'held' else 'paid' end, p_method, v_fare, v_fare_wallet, v_fare_cv, sp.coins, v_rate,
          v_dues, v_due_ids, case when p_hold then null else now() end)
  returning * into p;
  return p;
end;
$$;
revoke execute on function public.c2c_take_fare(public.c2c_bookings, numeric, text, numeric, public.c2c_pay_rules, boolean)
  from public, anon, authenticated;

-- Gives the held fare of [b] back to the rider less [p_fee], which goes to
-- the driver less the trip's commission. The fee kept.
create or replace function public.c2c_hold_refund(b public.c2c_bookings, p_fee numeric default 0)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.c2c_payments;
  v_fee numeric;
  v_fee_wallet numeric;
  v_fee_cv numeric;
  v_back_wallet numeric;
  v_back_coins numeric := 0;
  v_rate numeric := case when b.commission_rate >= 0 and b.commission_rate < 1 then b.commission_rate else 0 end;
begin
  select * into p from public.c2c_payments where booking_id = b.id and status = 'held' for update;
  if p.id is null then
    return 0;
  end if;
  v_fee := least(round(greatest(coalesce(p_fee, 0), 0), 2), p.amount);
  v_fee_wallet := least(v_fee, p.wallet_amount);
  v_fee_cv := least(v_fee - v_fee_wallet, p.coin_value);
  v_back_wallet := p.wallet_amount - v_fee_wallet;
  if p.coin_value - v_fee_cv > 0 and coalesce(p.coin_rate, 0) > 0 then
    v_back_coins := least(floor((p.coin_value - v_fee_cv) * p.coin_rate * 100) / 100, p.coins);
  end if;
  if v_back_wallet > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (b.rider_id, 'get_wallet', 'c2c_refund', v_back_wallet, 'c2c_fare',
            'City to City fare ' || b.ref || ' given back'
            || case when v_fee > 0 then ' (less the ' || public.c2c_money(v_fee, b.currency) || ' cancel fee)' else '' end);
  end if;
  if v_back_coins > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (b.rider_id, 'get_coin', 'c2c_refund', v_back_coins, 'c2c_fare',
            'City to City fare ' || b.ref || ': coins given back');
  end if;
  if v_fee > 0 and b.driver_id is not null then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
    values (b.driver_id, 'get_wallet', 'cancellation_fee', round(v_fee * (1 - v_rate), 2), 'cancellation_fee',
            'City to City cancellation fee ' || b.ref
            || case when v_rate > 0 then ' (less ' || round(v_rate * 100, 1) || '% commission)' else '' end);
  end if;
  update public.c2c_payments
     set status = 'refunded', fee_kept = v_fee, refund_wallet = v_back_wallet, refund_coins = v_back_coins,
         driver_id = b.driver_id, settled_at = now()
   where id = p.id;
  return v_fee;
end;
$$;
revoke execute on function public.c2c_hold_refund(public.c2c_bookings, numeric) from public, anon, authenticated;

-- The held fare of [p_booking] (completed) to its driver, the commission off
-- it in the same ledger, stamped as 0307's charge stamps it.
create or replace function public.c2c_hold_release(p_booking uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  p public.c2c_payments;
  c record;
  v_rate numeric;
  v_amount numeric(12,2) := 0;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  select * into p from public.c2c_payments where booking_id = p_booking and status = 'held' for update;
  if b.id is null or p.id is null or b.status <> 'completed' or b.driver_id is null then
    return;
  end if;
  select * into c from public.c2c_commission_of(b);
  v_rate := case when c.rate >= 0 and c.rate < 1 then c.rate end;
  if v_rate is not null and b.commission_charged_at is null then
    v_amount := round(p.amount * v_rate, 2);
  end if;
  -- One statement: the fare lands before the commission comes off it, and
  -- an owed give-up fee (trg_wallet_tx_c2c_collect) is taken after both.
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
  select * from (values
    (b.driver_id, 'get_wallet', 'c2c_earning', p.amount, 'c2c_fare',
     'City to City fare ' || b.ref || ', paid in the app'),
    (b.driver_id, 'get_wallet', 'commission', -v_amount, 'c2c_fare',
     'City to City commission ' || round(coalesce(v_rate, 0) * 100, 1) || '% of '
     || public.c2c_money(p.amount, b.currency) || ' (' || b.ref || ')')) x(u, w, k, a, m, n)
   where x.a <> 0;
  update public.c2c_payments
     set status = 'released', driver_id = b.driver_id, commission = v_amount, settled_at = now()
   where id = p.id;
  update public.c2c_bookings
     set pay_status = 'paid', paid_at = now(),
         commission_rate = coalesce(commission_rate, v_rate),
         commission_rule_id = coalesce(commission_rule_id, c.rule_id),
         commission_tier_id = coalesce(commission_tier_id, c.tier_id),
         commission_promotion_id = coalesce(commission_promotion_id, c.promotion_id),
         commission_amount = case when commission_charged_at is null then v_amount else commission_amount end,
         commission_charged_at = coalesce(commission_charged_at, now())
   where id = b.id;
end;
$$;
revoke execute on function public.c2c_hold_release(uuid) from public, anon, authenticated;

-- ---- 3. Cancel fees owed, on a cash trip ----------------------------------------------------------------
-- The fees [p_rider] owes for the driver of their next cash trip to collect,
-- when the settings say so: (ids, total), or (null, null).
create or replace function public.c2c_dues_to_collect(p_rider uuid)
returns table (ids uuid[], total numeric)
language sql
stable
security definer
set search_path = public
as $$
  select case when sum(x.cancel_fee) > 0 then array_agg(x.id order by x.cancelled_at, x.id) end,
         case when sum(x.cancel_fee) > 0 then sum(x.cancel_fee) end
    from public.c2c_bookings x
    join public.city_to_city_settings s on s.id = 1 and s.owed_cash_collect
   where x.rider_id = p_rider and x.cancel_fee_status = 'due' and x.cancel_fee > 0;
$$;
revoke execute on function public.c2c_dues_to_collect(uuid) from public, anon, authenticated;

-- ---- 2. Accepting an offer, with the payment ------------------------------------------------------------
-- As 0307's c2c_accept_offer, and for a trip paid In app: under the
-- pickup's rule, the fare held now by [p_method] (null: the rule's first
-- way, mix, else the wallet, else coins), checked against [p_expected] (the
-- total the rider saw); or paid after the trip. A cash trip takes the fees
-- owed for its driver to collect (item 3). {id, status, agreedFare,
-- payMode, payStatus, held, dues}.
create or replace function public.c2c_accept_offer_pay(p_offer uuid, p_method text default null,
                                                       p_expected numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.c2c_offers;
  b public.c2c_bookings;
  pr public.c2c_pay_rules;
  p public.c2c_payments;
  v_collect_ids uuid[];
  v_collect numeric;
  v_mode text;
  v_status text;
begin
  select * into o from public.c2c_offers where id = p_offer;
  if o.id is null then
    raise exception 'C2C_OFFER_GONE' using errcode = '22023', hint = 'This offer is no longer available.';
  end if;
  select * into b from public.c2c_bookings where id = o.booking_id for update;
  if b.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.status in ('open', 'offered') and b.expires_at <= now() then
    perform public.c2c_expire_due();
    raise exception 'C2C_EXPIRED' using errcode = '22023',
      hint = 'This request has expired. Plan the trip again.';
  end if;
  if b.status not in ('open', 'offered') then
    raise exception 'C2C_NOT_OPEN' using errcode = '22023',
      hint = 'This trip already has a driver, or it was cancelled.';
  end if;
  select * into o from public.c2c_offers where id = p_offer for update;
  if o.status <> 'open' then
    raise exception 'C2C_OFFER_GONE' using errcode = '22023', hint = 'This offer is no longer available.';
  end if;
  if not coalesce((public.c2c_driver_eligibility(o.driver_id, b.pickup_place, b.drop_place)->>'ok')::boolean, false) then
    raise exception 'C2C_OFFER_GONE' using errcode = '22023', hint = 'This driver can no longer take the trip.';
  end if;
  if exists (select 1 from public.c2c_bookings x
              where x.driver_id = o.driver_id and x.id <> b.id
                and x.status in ('booked', 'driver_arriving', 'on_trip')
                and abs(extract(epoch from coalesce(x.driver_leave_at, x.leave_at) - o.leave_at))
                    < (greatest(x.duration_min, b.duration_min) + 120) * 60) then
    raise exception 'C2C_DRIVER_BUSY' using errcode = '22023',
      hint = 'This driver has just been booked for another trip at that time.';
  end if;

  if b.payment = 'in_app' then
    select * into pr from public.c2c_pay_rule_for(b.pickup_place);
    v_mode := coalesce(pr.when_mode, 'hold');
    if v_mode = 'hold' then
      p := public.c2c_take_fare(b, o.price,
                                coalesce(p_method, case when pr.pay_mix then 'mix' when pr.pay_wallet then 'get_wallet'
                                                        else 'get_coin' end),
                                p_expected, pr, true);
      v_status := 'held';
    end if;
  else
    select x.ids, x.total into v_collect_ids, v_collect from public.c2c_dues_to_collect(b.rider_id) x;
  end if;

  update public.c2c_offers set status = 'accepted' where id = o.id;
  update public.c2c_offers set status = 'declined', declined_reason = 'taken'
   where booking_id = b.id and id <> o.id and status = 'open';
  update public.c2c_bookings
     set status = 'booked', driver_id = o.driver_id, offer_id = o.id, agreed_fare = o.price,
         driver_leave_at = o.leave_at, booked_at = now(),
         pay_mode = v_mode, pay_status = v_status,
         paid_method = p.method, paid_amount = p.amount,
         collect_fee_ids = v_collect_ids, collect_amount = v_collect, collected_at = null
   where id = b.id
  returning * into b;
  update public.c2c_payments set driver_id = o.driver_id where id = p.id;
  return jsonb_build_object('id', b.id, 'status', b.status, 'agreedFare', b.agreed_fare,
                            'payMode', b.pay_mode, 'payStatus', b.pay_status,
                            'held', p.amount, 'dues', coalesce(p.dues_amount, 0));
end;
$$;
revoke execute on function public.c2c_accept_offer_pay(uuid, text, numeric) from public, anon;
grant execute on function public.c2c_accept_offer_pay(uuid, text, numeric) to authenticated, service_role;

-- 0307's one-argument accept: the rule's first way.
create or replace function public.c2c_accept_offer(p_offer uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select public.c2c_accept_offer_pay(p_offer, null, null);
$$;
revoke execute on function public.c2c_accept_offer(uuid) from public, anon;
grant execute on function public.c2c_accept_offer(uuid) to authenticated, service_role;

-- ---- 2. Cancelling a held trip ------------------------------------------------------------------------------
-- As 0307, and a held fare: back to the rider less the cancel fee (the fee
-- from the held money, never 'due'); all of it on an admin's cancel.
create or replace function public.c2c_cancel(p_booking uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  v_by text;
  v_fee numeric := 0;
  v_fee_status text := 'none';
  v_held boolean;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.id is null then
    raise exception 'C2C_NOT_FOUND' using errcode = '22023', hint = 'This trip was not found.';
  end if;
  if b.rider_id = auth.uid() then
    v_by := 'rider';
  elsif auth.uid() is not null and public.caller_admin_can_write('c2c_bookings') then
    v_by := 'admin';
  else
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.status in ('completed', 'cancelled', 'expired') then
    raise exception 'C2C_NOT_OPEN' using errcode = '22023', hint = 'This trip has already ended.';
  end if;
  if b.status = 'on_trip' then
    raise exception 'C2C_ON_TRIP' using errcode = '22023',
      hint = 'The trip has started. Talk to your driver, or contact support.';
  end if;
  if v_by = 'rider' and b.status in ('booked', 'driver_arriving') then
    v_fee := public.c2c_cancel_fee(b.leave_at, now());
  end if;
  v_held := b.pay_status = 'held';
  if v_held then
    v_fee := public.c2c_hold_refund(b, v_fee);
    v_fee_status := case when v_fee > 0 then 'charged' else 'none' end;
  elsif v_fee > 0 then
    v_fee_status := public.c2c_fee_take(b, v_fee);
  end if;
  update public.c2c_offers set status = 'declined', declined_reason = 'cancelled'
   where booking_id = b.id and status = 'open';
  update public.c2c_bookings
     set status = 'cancelled', cancelled_at = now(), cancelled_by = v_by,
         cancel_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 300),
         cancel_fee = v_fee, cancel_fee_status = v_fee_status,
         pay_status = case when v_held then 'refunded' else pay_status end
   where id = b.id;
  return jsonb_build_object('status', 'cancelled', 'fee', v_fee, 'feeStatus', v_fee_status, 'refunded', v_held);
end;
$$;
revoke execute on function public.c2c_cancel(uuid, text) from public, anon;
grant execute on function public.c2c_cancel(uuid, text) to authenticated, service_role;

-- ---- 1, 2. The driver gives up ----------------------------------------------------------------------------
-- As 0308, and: the give-up fee of the pickup's rule (item 1); a held fare
-- back to the rider in full; the payment and the fees to collect cleared
-- with the driver. {status: 'open', fee}.
create or replace function public.c2c_driver_cancel(p_booking uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  r public.c2c_giveup_rules;
  f record;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.id is null or auth.uid() is null or b.driver_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.status = 'on_trip' then
    raise exception 'C2C_ON_TRIP' using errcode = '22023',
      hint = 'The rider is on board. Finish the trip, or contact support.';
  end if;
  if b.status not in ('booked', 'driver_arriving') then
    raise exception 'C2C_NOT_OPEN' using errcode = '22023', hint = 'This trip has already ended.';
  end if;
  if now() >= b.leave_at then
    raise exception 'C2C_TOO_LATE' using errcode = '22023',
      hint = 'It is past the time to leave. Contact support to cancel this trip.';
  end if;

  select * into r from public.c2c_giveup_rule_for(b.pickup_place);
  select * into f from public.c2c_giveup_fee(r, b.leave_at, now());
  if f.fee > 0 then
    perform public.c2c_giveup_charge(b, r, f.fee, f.to_rider, f.to_platform);
  end if;
  if b.pay_status = 'held' then
    perform public.c2c_hold_refund(b, 0);
  end if;

  update public.c2c_offers set status = 'withdrawn'
   where booking_id = b.id and driver_id = b.driver_id and status = 'accepted';
  update public.c2c_bookings
     set status = 'open', driver_id = null, offer_id = null, agreed_fare = null, driver_leave_at = null,
         booked_at = null, arriving_at = null,
         commission_rate = null, commission_base_rate = null, commission_rule_id = null,
         commission_tier_id = null, commission_promotion_id = null, commission_locked_at = null,
         pay_mode = null, pay_status = null, paid_method = null, paid_amount = null, paid_at = null,
         collect_fee_ids = null, collect_amount = null, collected_at = null,
         driver_dropped_at = now(), driver_drop_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 300)
   where id = b.id;
  return jsonb_build_object('status', 'open', 'fee', coalesce(f.fee, 0));
end;
$$;
revoke execute on function public.c2c_driver_cancel(uuid, text) from public, anon;
grant execute on function public.c2c_driver_cancel(uuid, text) to authenticated, service_role;

-- ---- 2. Complete trip -----------------------------------------------------------------------------------
-- As 0307; at completion a held fare goes to the driver less commission
-- (c2c_hold_release, which stamps the commission so 0307's charge on
-- GET.credit is not taken too); otherwise 0307's charge, and a trip paid
-- after it is 'unpaid' until the rider pays (they are told).
create or replace function public.c2c_driver_progress(p_booking uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.id is null or b.driver_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if not ((b.status = 'booked' and p_status in ('driver_arriving', 'on_trip'))
          or (b.status = 'driver_arriving' and p_status = 'on_trip')
          or (b.status = 'on_trip' and p_status = 'completed')) then
    raise exception 'C2C_BAD_STEP' using errcode = '22023', hint = 'This trip can''t move to that step now.';
  end if;
  update public.c2c_bookings
     set status = p_status,
         arriving_at = case when p_status = 'driver_arriving' then now() else arriving_at end,
         started_at = case when p_status = 'on_trip' then now() else started_at end,
         completed_at = case when p_status = 'completed' then now() else completed_at end,
         pay_status = case when p_status = 'completed' and payment = 'in_app' and pay_mode = 'after'
                                and pay_status is null then 'unpaid' else pay_status end
   where id = b.id;
  if p_status = 'completed' then
    if b.pay_status = 'held' then
      perform public.c2c_hold_release(b.id);
    else
      perform public.c2c_charge_commission(b.id);
    end if;
    if b.payment = 'in_app' and b.pay_mode = 'after' then
      begin
        perform public.enqueue_notification(
          b.rider_id, 'c2c-pay:' || b.id, 'c2c_pay', 'normal', 'Pay for your trip',
          'Your trip to ' || coalesce(b.drop_place->>'city', b.drop_place->>'state', b.drop_name) || ' is complete. Pay '
          || public.c2c_money(coalesce(b.agreed_fare, b.fare), b.currency) || ' in the app.',
          jsonb_build_object('type', 'c2c_pay', 'c2c_booking_id', b.id, 'role', 'rider'), null);
      exception when others then
        null;
      end;
    end if;
  end if;
end;
$$;
revoke execute on function public.c2c_driver_progress(uuid, text) from public, anon;
grant execute on function public.c2c_driver_progress(uuid, text) to authenticated, service_role;

-- ---- 2. Paying after the trip ------------------------------------------------------------------------------
-- The rider pays completed trip [p_booking] (In app, pay after) by
-- [p_method], the total they saw being [p_expected]: the fare to the driver
-- (the commission was charged at completion), the fees owed with it.
-- Paid already: {already: true}. {paid, method, coins, dues}.
create or replace function public.c2c_pay(p_booking uuid, p_method text, p_expected numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  pr public.c2c_pay_rules;
  p public.c2c_payments;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.id is null or auth.uid() is null or b.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.pay_status = 'paid' then
    return jsonb_build_object('paid', b.paid_amount, 'method', b.paid_method, 'already', true);
  end if;
  if b.status <> 'completed' then
    raise exception 'C2C_NOT_DONE' using errcode = '22023', hint = 'Pay once the trip is complete.';
  end if;
  if b.payment <> 'in_app' or b.pay_mode is distinct from 'after' or b.pay_status is distinct from 'unpaid'
     or b.driver_id is null then
    raise exception 'C2C_NOTHING_TO_PAY' using errcode = '22023', hint = 'There is nothing to pay in the app for this trip.';
  end if;
  select * into pr from public.c2c_pay_rule_for(b.pickup_place);
  p := public.c2c_take_fare(b, coalesce(b.agreed_fare, b.fare), p_method, p_expected, pr, false);
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
  values (b.driver_id, 'get_wallet', 'c2c_earning', p.amount, 'c2c_fare',
          'City to City fare ' || b.ref || ', paid in the app');
  update public.c2c_bookings
     set pay_status = 'paid', paid_method = p.method, paid_amount = p.amount, paid_at = now()
   where id = b.id;
  return jsonb_build_object('paid', p.amount, 'method', p.method, 'coins', p.coins, 'dues', p.dues_amount);
end;
$$;
revoke execute on function public.c2c_pay(uuid, text, numeric) from public, anon;
grant execute on function public.c2c_pay(uuid, text, numeric) to authenticated, service_role;

-- The rider pays [p_booking] in cash instead (the rule offers it and Cash is
-- on): before a driver is picked, or after the trip while unpaid.
create or replace function public.c2c_switch_to_cash(p_booking uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  pr public.c2c_pay_rules;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.id is null or auth.uid() is null or b.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.payment = 'cash' then
    return jsonb_build_object('payment', 'cash');
  end if;
  select * into pr from public.c2c_pay_rule_for(b.pickup_place);
  if not coalesce(pr.offer_cash, false)
     or not coalesce((select s.pay_cash from public.city_to_city_settings s where s.id = 1), true) then
    raise exception 'C2C_PAYMENT_NOT_ALLOWED' using errcode = '22023', hint = 'Cash isn''t offered for this trip.';
  end if;
  if b.status in ('open', 'offered') then
    update public.c2c_bookings set payment = 'cash' where id = b.id;
  elsif b.status = 'completed' and b.pay_status = 'unpaid' then
    update public.c2c_bookings set payment = 'cash', pay_status = 'cash' where id = b.id;
  else
    raise exception 'C2C_NOT_OPEN' using errcode = '22023', hint = 'This trip''s payment can''t change now.';
  end if;
  return jsonb_build_object('payment', 'cash');
end;
$$;
revoke execute on function public.c2c_switch_to_cash(uuid) from public, anon;
grant execute on function public.c2c_switch_to_cash(uuid) to authenticated, service_role;

-- What the rider's pay sheet for [p_booking] needs: the rule, the
-- balances, the coin rate, the fees owed that are added.
create or replace function public.c2c_pay_info(p_booking uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  pr public.c2c_pay_rules;
  s public.city_to_city_settings;
  v_items jsonb;
begin
  select * into b from public.c2c_bookings where id = p_booking;
  if b.id is null or auth.uid() is null or b.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into pr from public.c2c_pay_rule_for(b.pickup_place);
  select * into s from public.city_to_city_settings where id = 1;
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'ref', x.ref, 'fee', x.cancel_fee,
                                               'cancelledAt', x.cancelled_at) order by x.cancelled_at, x.id), '[]')
    into v_items
    from public.c2c_bookings x
   where coalesce(s.owed_next_in_app, false) and x.rider_id = b.rider_id
     and x.cancel_fee_status = 'due' and x.cancel_fee > 0;
  return jsonb_build_object(
    'when', coalesce(b.pay_mode, pr.when_mode, 'hold'),
    'wallet', coalesce(pr.pay_wallet, true), 'coin', coalesce(pr.pay_coin, true), 'mix', coalesce(pr.pay_mix, true),
    'offerTopup', coalesce(pr.offer_topup, true),
    'offerCash', coalesce(pr.offer_cash, true) and coalesce(s.pay_cash, true),
    'walletBalance', coalesce((select w.balance from public.wallets w
                                where w.user_id = b.rider_id and w.wallet_type = 'get_wallet'), 0),
    'coinBalance', coalesce((select w.balance from public.wallets w
                              where w.user_id = b.rider_id and w.wallet_type = 'get_coin'), 0),
    'coinRate', (select g.coins_per_currency from public.get_coin_settings g where g.id = 'master'),
    'dues', v_items,
    'payStatus', b.pay_status);
end;
$$;
revoke execute on function public.c2c_pay_info(uuid) from public, anon;
grant execute on function public.c2c_pay_info(uuid) to authenticated, service_role;

-- ---- 3. What is owed, and Pay now -------------------------------------------------------------------------
-- The caller's City to City fees owed: as a rider (cancel fees, and how they
-- are collected) and as a driver (give-up fees).
create or replace function public.c2c_my_owed()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  s public.city_to_city_settings;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into s from public.city_to_city_settings where id = 1;
  return jsonb_build_object(
    'rider', (select coalesce(jsonb_agg(jsonb_build_object(
                'id', x.id, 'ref', x.ref, 'fee', x.cancel_fee, 'currency', x.currency, 'cancelledAt', x.cancelled_at,
                'route', coalesce(x.pickup_place->>'city', x.pickup_name) || ' to '
                         || coalesce(x.drop_place->>'city', x.drop_place->>'state', x.drop_name))
                order by x.cancelled_at, x.id), '[]')
                from public.c2c_bookings x
               where x.rider_id = v_uid and x.cancel_fee_status = 'due' and x.cancel_fee > 0),
    'driver', (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', f.id, 'ref', f.ref, 'fee', f.fee, 'owed', f.owed, 'createdAt', f.created_at)
                 order by f.created_at, f.id), '[]')
                 from public.c2c_driver_fees f
                where f.driver_id = v_uid and f.status = 'owed'),
    'options', jsonb_build_object('topup', coalesce(s.owed_from_topup, false),
                                  'nextInApp', coalesce(s.owed_next_in_app, false),
                                  'cash', coalesce(s.owed_cash_collect, false),
                                  'block', coalesce(s.owed_block, false)));
end;
$$;
revoke execute on function public.c2c_my_owed() from public, anon;
grant execute on function public.c2c_my_owed() to authenticated, service_role;

-- Pay now (Wallet): the caller's owed cancel fees, each whole, then their
-- owed give-up fees, from their GET wallet as far as it goes. {paid, left}.
create or replace function public.c2c_pay_owed()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_paid numeric;
  v_left numeric;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  v_paid := public.c2c_collect_rider_dues(v_uid, 'pay_now') + public.c2c_collect_driver_fees(v_uid, 'pay_now');
  v_left := coalesce((select sum(x.cancel_fee) from public.c2c_bookings x
                       where x.rider_id = v_uid and x.cancel_fee_status = 'due' and x.cancel_fee > 0), 0)
            + coalesce((select sum(f.owed) from public.c2c_driver_fees f
                         where f.driver_id = v_uid and f.status = 'owed'), 0);
  if v_paid = 0 and v_left > 0 then
    raise exception 'C2C_WALLET_SHORT' using errcode = '22023',
      hint = 'Your GET wallet doesn''t hold enough. Top up, then pay.';
  end if;
  return jsonb_build_object('paid', v_paid, 'left', v_left);
end;
$$;
revoke execute on function public.c2c_pay_owed() from public, anon;
grant execute on function public.c2c_pay_owed() to authenticated, service_role;

-- The driver of cash trip [p_booking] says they collected the fees owed
-- with it. What they took ({collected}); fees paid another way meanwhile
-- are left out.
create or replace function public.c2c_mark_collected(p_booking uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  b public.c2c_bookings;
  d public.c2c_bookings;
  v_total numeric := 0;
begin
  select * into b from public.c2c_bookings where id = p_booking for update;
  if b.id is null or auth.uid() is null or b.driver_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if b.status not in ('booked', 'driver_arriving', 'on_trip', 'completed') or b.payment <> 'cash' then
    raise exception 'C2C_NOT_OPEN' using errcode = '22023', hint = 'There is nothing to collect on this trip.';
  end if;
  if b.collected_at is not null then
    return jsonb_build_object('collected', coalesce(b.collect_amount, 0), 'already', true);
  end if;
  for d in
    select * from public.c2c_bookings
     where id = any(coalesce(b.collect_fee_ids, '{}')) and rider_id = b.rider_id and cancel_fee_status = 'due'
     order by cancelled_at, id
     for update
  loop
    v_total := v_total + public.c2c_settle_due(d, 'cash', false, b.driver_id);
  end loop;
  update public.c2c_bookings set collect_amount = v_total, collected_at = now() where id = b.id;
  return jsonb_build_object('collected', v_total);
end;
$$;
revoke execute on function public.c2c_mark_collected(uuid) from public, anon;
grant execute on function public.c2c_mark_collected(uuid) to authenticated, service_role;

-- ---- 4. Trip reminders ---------------------------------------------------------------------------------------
-- "1 day", "2 days", "2 h", "1 h 30 min", "30 min" (c2cReminderWhen's twin).
create or replace function public.c2c_reminder_when(p_minutes integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_minutes >= 1440 and p_minutes % 1440 = 0
      then (p_minutes / 1440) || case when p_minutes = 1440 then ' day' else ' days' end
    when p_minutes >= 60 and p_minutes % 60 = 0 then (p_minutes / 60) || ' h'
    when p_minutes > 60 then (p_minutes / 60) || ' h ' || (p_minutes % 60) || ' min'
    else p_minutes || ' min'
  end;
$$;

-- Sends the reminders due now (see item 4); how many went.
create or replace function public.c2c_send_reminders()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.city_to_city_settings;
  b record;
  e record;
  v_due timestamptz;
  v_to uuid;
  v_role text;
  v_when text;
  v_clock text;
  v_drop text;
  v_title text;
  v_body text;
  v_event text;
  v_n integer := 0;
  f public.sms_fallback_settings;
  r public.notification_outbox;
  v_phone text;
  v_reason text;
  v_sms uuid;
begin
  select * into s from public.city_to_city_settings where id = 1;
  if s.id is null or not s.reminders_on or jsonb_array_length(coalesce(s.reminders, '[]')) = 0 then
    return 0;
  end if;

  for b in
    select x.*, coalesce(x.driver_leave_at, x.leave_at) as leaves,
           o.driver_name, nullif(btrim(concat_ws(', ', o.car, o.plate)), '') as car_line,
           (select pr.name from public.profiles pr where pr.id = x.rider_id) as rider_name
      from public.c2c_bookings x
      left join public.c2c_offers o on o.id = x.offer_id
     where x.status in ('booked', 'driver_arriving') and x.driver_id is not null
       and coalesce(x.driver_leave_at, x.leave_at) > now()
     order by coalesce(x.driver_leave_at, x.leave_at)
  loop
    for e in
      select (j->>'minutes')::integer as minutes, j->>'to' as who
        from jsonb_array_elements(s.reminders) j
       order by (j->>'minutes')::integer desc
    loop
      v_due := b.leaves - make_interval(mins => e.minutes);
      continue when now() < v_due;
      foreach v_role in array array['rider', 'partner'] loop
        continue when (v_role = 'rider' and e.who = 'driver') or (v_role = 'partner' and e.who = 'rider');
        v_to := case when v_role = 'rider' then b.rider_id else b.driver_id end;
        continue when exists (select 1 from public.c2c_reminder_log l
                               where l.booking_id = b.id and l.minutes = e.minutes and l.profile_id = v_to);
        -- Its time had passed when the trip was booked, or it is late.
        if v_due < coalesce(b.booked_at, b.created_at) or now() > v_due + interval '30 minutes' then
          insert into public.c2c_reminder_log (booking_id, minutes, profile_id, skipped)
          values (b.id, e.minutes, v_to, true) on conflict do nothing;
          continue;
        end if;
        insert into public.c2c_reminder_log (booking_id, minutes, profile_id) values (b.id, e.minutes, v_to)
        on conflict do nothing;

        v_when := public.c2c_reminder_when(e.minutes);
        v_clock := to_char(b.leaves at time zone coalesce(b.timezone, 'Asia/Kuala_Lumpur'), 'FMHH24:MI');
        v_drop := coalesce(b.drop_place->>'city', b.drop_place->>'state', b.drop_name);
        if v_role = 'rider' then
          v_title := 'Your trip to ' || v_drop || ' is in ' || v_when;
          v_body := public.c2c_short_name(b.driver_name) || ' picks you up at ' || v_clock || ' from ' || b.pickup_name
                    || '.' || coalesce(' ' || b.car_line || '.', '') || ' Tap to see the trip or chat.';
        else
          v_title := 'City to City trip in ' || v_when;
          v_body := 'Pick up ' || public.c2c_short_name(b.rider_name) || ' at ' || v_clock || ', ' || b.pickup_name
                    || ', to ' || v_drop || '. ' || public.c2c_money(coalesce(b.agreed_fare, b.fare), b.currency) || ', '
                    || case when b.payment = 'cash' then 'cash'
                            when b.pay_status = 'held' then 'paid in app'
                            else 'in app, paid after the trip' end
                    || '. Tap to start On my way.';
        end if;
        v_event := 'c2c-rem:' || b.id || ':' || e.minutes;
        begin
          if s.reminder_push then
            perform public.enqueue_notification(
              v_to, v_event, 'c2c_reminder', 'normal', v_title, v_body,
              jsonb_build_object('type', 'c2c_reminder', 'c2c_booking_id', b.id, 'role', v_role,
                                 'minutes', e.minutes, 'event_id', v_event, 'inbox', s.reminder_inbox),
              null);
          elsif s.reminder_inbox then
            insert into public.user_notifications (profile_id, title, body, data, kind, mode, event_id)
            values (v_to, v_title, v_body,
                    jsonb_build_object('type', 'c2c_reminder', 'c2c_booking_id', b.id, 'role', v_role,
                                       'minutes', e.minutes),
                    'c2c_reminder', v_role, v_event)
            on conflict (profile_id, event_id) do nothing;
          end if;
          v_n := v_n + 1;
        exception when others then
          raise warning 'c2c reminder % not sent: %', v_event, sqlerrm;
        end;
      end loop;
    end loop;
  end loop;

  -- SMS when the push wasn't confirmed (0150's number, refusals and gateway).
  if s.reminder_push and s.reminder_sms then
    begin
      select * into f from public.sms_fallback_settings where id = 1;
      if public.sms_gateway_online(coalesce(f.channel, 'otp')) then
        for r in
          select * from public.notification_outbox o
           where o.kind = 'c2c_reminder' and o.delivered_at is null and o.sms_at is null
             and o.created_at <= now() - interval '2 minutes' and o.created_at > now() - interval '30 minutes'
           order by o.created_at
           limit 50
           for update skip locked
        loop
          v_phone := public.sms_fallback_phone(r);
          v_reason := public.sms_fallback_refusal(r, v_phone);
          if v_reason is null and not exists (
               select 1 from public.c2c_bookings x
                where x.id::text = r.data->>'c2c_booking_id' and x.status in ('booked', 'driver_arriving')) then
            v_reason := 'moved_on';
          end if;
          if v_reason is not null then
            update public.notification_outbox
               set sms_status = 'skipped', sms_reason = v_reason, sms_at = now(), sms_phone = v_phone
             where id = r.id;
            continue;
          end if;
          insert into public.sms_outbox (channel, to_phone, body, created_by)
          values (coalesce(f.channel, 'otp'), v_phone, left('GET.ride: ' || r.title || '. ' || r.body, 300), null)
          returning id into v_sms;
          update public.notification_outbox
             set sms_status = 'queued', sms_reason = null, sms_at = now(), sms_phone = v_phone, sms_outbox_id = v_sms
           where id = r.id;
        end loop;
      end if;
    exception when others then
      raise warning 'c2c reminder SMS not sent: %', sqlerrm;
    end;
  end if;
  return v_n;
end;
$$;
revoke execute on function public.c2c_send_reminders() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'c2c-send-reminders';
    perform cron.schedule('c2c-send-reminders', '*/5 * * * *', $job$select public.c2c_send_reminders()$job$);
  end if;
end $$;

-- ---- Live in the apps and the admin pages ----------------------------------------------------------------
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['c2c_giveup_rules', 'c2c_pay_rules', 'c2c_driver_fees'] loop
      if not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

notify pgrst, 'reload schema';
