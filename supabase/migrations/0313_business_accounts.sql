-- ============================================================================
-- 0313 — Business accounts: companies whose staff book city rides, scheduled
-- rides, Freight and Courier on the company, paid from a prepaid business
-- wallet or on a monthly invoice (docs/KIV.md, Freight and Courier, after
-- launch). City to City is not included: its money is still cash or
-- "In app" recorded only (0307), so there is nothing to charge to yet.
--
-- Version 20261028060000 (0313_business_accounts). Re-runnable: tables,
-- columns and indexes "if not exists", functions "create or replace",
-- policies and triggers dropped first, seed rows only where missing.
--
-- 1. Applying: a signed-in user applies with the company's name, its SSM
--    number, the SSM document (business-documents/<uid>/..., read as the
--    partner company step reads one, lib/src/core/document_text.dart) and
--    its registered country / state / city (business_apply). The account is
--    'pending' with the applicant as its first Admin member. Admins with
--    EDIT on Admin › People › Business accounts ('admin-business-accounts')
--    approve, suspend, reactivate or reject it (admin_business_set_status).
-- 2. The defaults (business_region_rules): a Default rule and rules per
--    region (country, state, city of the company's registered address; the
--    most specific matching rule wins, and a region rule only overrides the
--    values it sets: null follows the rule above it). Values: starting credit
--    limit, invoice due days, pause bookings when overdue by N days, the
--    business discount %, the commission % on business trips, the default
--    member monthly limit (0 = no limit), the payment terms ('wallet' =
--    prepaid business wallet, 'invoice' = monthly invoice) and the services
--    allowed ('ride', 'scheduled', 'freight', 'courier'). Each account can
--    override any value (business_accounts' columns of the same names; null
--    = follows the rules). business_settings_for(account) gives the result;
--    lib/src/core/business_accounts.dart is the app's twin
--    (test/business_accounts_test.dart, supabase/tests/business_accounts_0313.sql).
-- 3. Members, invited by phone (business_member_invite): Admin, Booker or
--    Rider, a team name and a monthly limit (null = the account's default
--    member limit; 0 = no limit). An invited person sees the invitation in
--    Account › Business and joins (business_join); their row is matched by
--    the phone's digits. Admins manage members; the last Admin stays.
--    Riders book for themselves only; Bookers may book for others, and
--    Freight and Courier when the rule allows; Admins book anything allowed.
-- 4. Account rules (business_rules_set, the company's Admins), each on/off
--    with its value: booking hours from / until (on the pickup's clock, else
--    Malaysia's; may run past midnight), a trip note required, trips above
--    RM X need an Admin's approval (business_approval_request / _decide; an
--    approval covers one trip up to its amount for 24 hours; Admins need
--    none), a company monthly spend cap, and Bookers may book Freight and
--    Courier.
-- 5. Booking: the app books with business_account_id (and business_note).
--    The database checks it (BEFORE INSERT on ride_requests, and on
--    scheduled_rides for a booking for later): membership, the account
--    active, not paused for an overdue invoice, the service allowed, the
--    role, the hours, the note, the approval, the member's and the company's
--    monthly spend, then the credit (invoice: unpaid invoices + trips under
--    way + this trip within the credit limit; wallet: the balance less trips
--    under way covers it). A refusal raises BUSINESS_<CODE> with the reason
--    as the hint and nothing is written. The ride gets the member, the terms,
--    the discount % and the commission % (server columns), payment_mode
--    "Business: <company>", and no promo code. business_booking_check() is
--    the same check for the app before it books. While the request is open a
--    fare change is checked again; the business columns are the server's.
--    A booking for later is checked at its pickup time when it is booked;
--    its release only checks the account and the member are still active.
-- 6. Settlement (AFTER the status turns completed): what the trip comes to
--    (ride_left_to_pay, 0142/0242) is paid to the driver's GET.wallet as an
--    in-app payment (kind ride_earning, method business, once per ride); the
--    company is charged it less the business discount (business_trips): from
--    the business wallet (business_wallet_entries; it may go below zero on a
--    trip that cost more than estimated), or added to the month's open
--    invoice. The ride is paid (paid_method 'business', paid_amount what the
--    driver was paid; the company's charge is on business_trips). The commission is
--    the business commission % of the commission base, locked on accept and
--    charged at completion as every ride's (0224/0306).
-- 7. Invoices (business_invoices): one per account, month and terms, open
--    while the month runs. business_invoices_tick() (daily with pg_cron,
--    'business-invoices') issues last month's: an invoice account's falls due
--    after the due days; a wallet account's is a statement, issued paid.
--    Admins mark an issued invoice paid (admin_business_invoice_paid). An
--    invoice unpaid N days (the overdue days) after its due date pauses the
--    account's bookings until it is paid. The app builds the PDF and CSV from
--    business_invoice_lines(invoice).
-- 8. Who reads and writes: the tables are read by admins; members read
--    through the functions (business_my_accounts, business_account_detail);
--    nobody writes them but the functions, except business_region_rules,
--    which admins with EDIT on the page write directly.
-- ============================================================================

-- ---- 1. Tables ---------------------------------------------------------------------------------------
create table if not exists public.business_region_rules (
  id              uuid primary key default gen_random_uuid(),
  -- '' at every level: the Default rule. A state needs its country, a city its state.
  country         text not null default '' check (length(country) <= 80),
  state           text not null default '' check (length(state) <= 80),
  city            text not null default '' check (length(city) <= 80),
  credit_limit    numeric(12,2) check (credit_limit is null or credit_limit between 0 and 100000000),
  due_days        integer check (due_days is null or due_days between 0 and 365),
  overdue_days    integer check (overdue_days is null or overdue_days between 1 and 365),
  discount_pct    numeric(5,2) check (discount_pct is null or discount_pct between 0 and 90),
  commission_pct  numeric(5,2) check (commission_pct is null or commission_pct between 0 and 90),
  member_limit    numeric(12,2) check (member_limit is null or member_limit between 0 and 100000000),
  terms           text check (terms is null or terms in ('wallet', 'invoice')),
  services        text[] check (services is null or services <@ array['ride', 'scheduled', 'freight', 'courier']::text[]),
  active          boolean not null default true,
  position        integer not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  check (state = '' or country <> ''),
  check (city = '' or state <> ''),
  check (country <> '' or (credit_limit is not null and due_days is not null and overdue_days is not null
                           and discount_pct is not null and commission_pct is not null
                           and member_limit is not null and terms is not null and services is not null))
);
create unique index if not exists business_region_rules_place_key
  on public.business_region_rules (lower(country), lower(state), lower(city));
comment on table public.business_region_rules is
  'Business accounts (0313): the Default rule (country '''') and rules per region of the company''s registered address. Null values follow the rule above. Admin › People › Business accounts › Defaults.';

insert into public.business_region_rules
  (id, country, state, city, credit_limit, due_days, overdue_days, discount_pct, commission_pct,
   member_limit, terms, services, position)
values
  ('b0510313-0000-4000-8000-000000000000', '', '', '', 10000, 30, 14, 5, 15, 500, 'invoice',
   array['ride', 'scheduled', 'freight', 'courier'], 0)
on conflict do nothing;

create table if not exists public.business_accounts (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (length(btrim(name)) between 2 and 120),
  reg_no          text not null check (length(btrim(reg_no)) between 3 and 40),
  company_type    text check (company_type is null or length(company_type) <= 60),
  address         text check (address is null or length(address) <= 400),
  country         text not null default 'Malaysia' check (length(country) between 1 and 80),
  state           text not null default '' check (length(state) <= 80),
  city            text not null default '' check (length(city) <= 80),
  document_url    text check (document_url is null or length(document_url) <= 1000),
  status          text not null default 'pending' check (status in ('pending', 'active', 'suspended', 'rejected')),
  status_note     text check (status_note is null or length(status_note) <= 300),
  applied_by      uuid references public.profiles(id) on delete set null,
  approved_at     timestamptz,
  approved_by     uuid,
  -- Overrides of the rules (null: follows them).
  credit_limit    numeric(12,2) check (credit_limit is null or credit_limit between 0 and 100000000),
  due_days        integer check (due_days is null or due_days between 0 and 365),
  overdue_days    integer check (overdue_days is null or overdue_days between 1 and 365),
  discount_pct    numeric(5,2) check (discount_pct is null or discount_pct between 0 and 90),
  commission_pct  numeric(5,2) check (commission_pct is null or commission_pct between 0 and 90),
  member_limit    numeric(12,2) check (member_limit is null or member_limit between 0 and 100000000),
  terms           text check (terms is null or terms in ('wallet', 'invoice')),
  services        text[] check (services is null or services <@ array['ride', 'scheduled', 'freight', 'courier']::text[]),
  -- The prepaid business wallet.
  wallet_balance  numeric(12,2) not null default 0,
  -- The company's own rules.
  hours_on        boolean not null default false,
  hours_from      smallint not null default 7 check (hours_from between 0 and 23),
  hours_until     smallint not null default 22 check (hours_until between 1 and 24),
  note_required   boolean not null default false,
  approval_on     boolean not null default false,
  approval_over   numeric(12,2) not null default 50 check (approval_over between 0 and 1000000),
  cap_on          boolean not null default false,
  monthly_cap     numeric(12,2) not null default 8000 check (monthly_cap between 0 and 100000000),
  bookers_freight boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  updated_by      uuid,
  check (hours_from <> hours_until)
);
create unique index if not exists business_accounts_reg_no_key
  on public.business_accounts (upper(regexp_replace(reg_no, '\s', '', 'g'))) where status <> 'rejected';
create index if not exists business_accounts_status_idx on public.business_accounts (status, created_at desc);
create index if not exists business_accounts_applied_by_idx on public.business_accounts (applied_by);

create table if not exists public.business_members (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null references public.business_accounts(id) on delete cascade,
  profile_id    uuid references public.profiles(id) on delete set null,
  phone         text not null check (length(phone) between 6 and 32),
  phone_digits  text generated always as (regexp_replace(phone, '\D', '', 'g')) stored,
  name          text check (name is null or length(name) <= 80),
  role          text not null default 'rider' check (role in ('admin', 'booker', 'rider')),
  team          text check (team is null or length(team) <= 60),
  monthly_limit numeric(12,2) check (monthly_limit is null or monthly_limit between 0 and 100000000),
  status        text not null default 'invited' check (status in ('invited', 'active', 'removed')),
  invited_by    uuid,
  joined_at     timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index if not exists business_members_phone_key
  on public.business_members (account_id, phone_digits) where status <> 'removed';
create index if not exists business_members_profile_idx on public.business_members (profile_id) where status <> 'removed';
create index if not exists business_members_digits_idx on public.business_members (phone_digits) where status <> 'removed';

create table if not exists public.business_approvals (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null references public.business_accounts(id) on delete cascade,
  member_id     uuid not null references public.business_members(id) on delete cascade,
  requested_by  uuid,
  amount        numeric(12,2) not null check (amount > 0 and amount < 1000000),
  service       text check (service is null or length(service) <= 80),
  pickup        text check (pickup is null or length(pickup) <= 200),
  dropoff       text check (dropoff is null or length(dropoff) <= 200),
  note          text check (note is null or length(note) <= 300),
  status        text not null default 'pending' check (status in ('pending', 'approved', 'declined', 'used', 'expired')),
  decided_by    uuid,
  decided_at    timestamptz,
  expires_at    timestamptz,
  ride_id       uuid,
  scheduled_ride_id uuid,
  created_at    timestamptz not null default now()
);
create index if not exists business_approvals_account_idx on public.business_approvals (account_id, status, created_at desc);
create index if not exists business_approvals_member_idx on public.business_approvals (member_id, status);

create table if not exists public.business_invoices (
  id           uuid primary key default gen_random_uuid(),
  account_id   uuid not null references public.business_accounts(id) on delete cascade,
  invoice_no   text not null unique,
  terms        text not null check (terms in ('wallet', 'invoice')),
  period_start date not null,
  period_end   date not null,
  status       text not null default 'open' check (status in ('open', 'issued', 'paid', 'void')),
  gross        numeric(12,2) not null default 0,
  discount     numeric(12,2) not null default 0,
  amount       numeric(12,2) not null default 0,
  trips        integer not null default 0,
  issued_at    timestamptz,
  due_date     date,
  paid_at      timestamptz,
  paid_by      uuid,
  paid_note    text check (paid_note is null or length(paid_note) <= 300),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (account_id, period_start, terms),
  check (period_end >= period_start)
);
create index if not exists business_invoices_status_idx on public.business_invoices (status, due_date);

create table if not exists public.business_trips (
  id              uuid primary key default gen_random_uuid(),
  ride_id         uuid unique references public.ride_requests(id) on delete set null,
  account_id      uuid not null references public.business_accounts(id) on delete cascade,
  member_id       uuid references public.business_members(id) on delete set null,
  profile_id      uuid,
  member_name     text,
  team            text,
  booked_for_name text,
  service         text,
  kind            text not null check (kind in ('ride', 'scheduled', 'freight', 'courier')),
  pickup          text,
  dropoff         text,
  note            text,
  completed_at    timestamptz not null default now(),
  gross           numeric(12,2) not null,
  discount        numeric(12,2) not null default 0,
  charged         numeric(12,2) not null,
  discount_pct    numeric(5,2) not null default 0,
  commission_pct  numeric(5,2),
  terms           text not null check (terms in ('wallet', 'invoice')),
  invoice_id      uuid references public.business_invoices(id) on delete set null,
  created_at      timestamptz not null default now()
);
create index if not exists business_trips_account_idx on public.business_trips (account_id, completed_at desc);
create index if not exists business_trips_member_idx on public.business_trips (member_id, completed_at desc);
create index if not exists business_trips_invoice_idx on public.business_trips (invoice_id);

create table if not exists public.business_wallet_entries (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null references public.business_accounts(id) on delete cascade,
  amount        numeric(12,2) not null check (amount <> 0),
  kind          text not null check (kind in ('topup', 'trip', 'adjust')),
  ride_id       uuid,
  note          text check (note is null or length(note) <= 300),
  balance_after numeric(12,2),
  created_by    uuid,
  created_at    timestamptz not null default now()
);
create index if not exists business_wallet_entries_account_idx on public.business_wallet_entries (account_id, created_at desc);
create unique index if not exists business_wallet_entries_ride_key
  on public.business_wallet_entries (ride_id) where kind = 'trip';

-- ---- 2. The ride ---------------------------------------------------------------------------------------
alter table public.ride_requests
  add column if not exists business_account_id     uuid references public.business_accounts(id) on delete set null,
  add column if not exists business_note           text,
  add column if not exists business_member_id      uuid,
  add column if not exists business_terms          text,
  add column if not exists business_discount_pct   numeric(5,2),
  add column if not exists business_commission_pct numeric(5,2),
  add column if not exists business_approval_id    uuid;
create index if not exists ride_requests_business_idx
  on public.ride_requests (business_account_id, status) where business_account_id is not null;

alter table public.ride_requests drop constraint if exists ride_requests_business_note_len;
alter table public.ride_requests add constraint ride_requests_business_note_len
  check (business_note is null or length(business_note) <= 200);

-- A business payment is recorded as such (0252's list plus 'business').
alter table public.ride_requests drop constraint if exists ride_requests_paid_method_check;
alter table public.ride_requests add constraint ride_requests_paid_method_check
  check (paid_method is null or paid_method in ('get_wallet', 'get_coin', 'cash', 'counter', 'gateway', 'business'));

-- One driver payment per business ride in the ledger.
create unique index if not exists wallet_transactions_business_ride_key
  on public.wallet_transactions (ride_id) where kind = 'ride_earning' and method = 'business';

-- ---- Shared helpers --------------------------------------------------------------------------------------
create or replace function public.business_stamp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;
revoke execute on function public.business_stamp() from public, anon, authenticated;

drop trigger if exists trg_business_region_rules_stamp on public.business_region_rules;
create trigger trg_business_region_rules_stamp
  before insert or update on public.business_region_rules
  for each row execute function public.business_stamp();

-- "RM 50", "RM 12.50".
create or replace function public.business_money(p numeric)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'RM ' || case when p = trunc(p) then to_char(p, 'FM999,999,999,990')
                       else to_char(p, 'FM999,999,999,990.00') end;
$$;

create or replace function public.business_digits(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(coalesce(p, ''), '\D', '', 'g');
$$;

-- The month [p_at] falls in, on Malaysia's clock: its first day.
create or replace function public.business_month_of(p_at timestamptz)
returns date
language sql
stable
set search_path = ''
as $$
  select date_trunc('month', (p_at at time zone 'Asia/Kuala_Lumpur'))::date;
$$;

create or replace function public.business_today()
returns date
language sql
stable
set search_path = ''
as $$
  select (now() at time zone 'Asia/Kuala_Lumpur')::date;
$$;

-- ---- 3. The settings an account works with ---------------------------------------------------------------
-- The rules for a company registered at country / state / city: the Default,
-- then each matching region rule from the widest to the narrowest (the lower
-- position wins between two of the same level), each setting what it sets.
create or replace function public.business_rule_settings(p_country text, p_state text, p_city text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.business_region_rules;
  v jsonb := '{}'::jsonb;
begin
  for r in
    select * from public.business_region_rules x
     where x.active or x.country = ''
     order by (case when x.country = '' then 0 when x.state = '' then 1 when x.city = '' then 2 else 3 end),
              x.position desc, x.created_at desc
  loop
    continue when r.country <> '' and not (r.active
      and public.region_name_norm(r.country) = public.region_name_norm(p_country)
      and (r.state = '' or public.region_name_norm(r.state) = public.region_name_norm(p_state))
      and (r.city = '' or public.region_name_norm(r.city) = public.region_name_norm(p_city)));
    v := v || jsonb_strip_nulls(jsonb_build_object(
      'creditLimit', r.credit_limit, 'dueDays', r.due_days, 'overdueDays', r.overdue_days,
      'discountPct', r.discount_pct, 'commissionPct', r.commission_pct, 'memberLimit', r.member_limit,
      'terms', r.terms, 'services', to_jsonb(r.services)));
  end loop;
  return v;
end;
$$;
revoke execute on function public.business_rule_settings(text, text, text) from public, anon;
grant execute on function public.business_rule_settings(text, text, text) to authenticated;

-- The rules for [p_account] with its own overrides on top.
create or replace function public.business_settings_for(p_account uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.business_rule_settings(a.country, a.state, a.city)
         || jsonb_strip_nulls(jsonb_build_object(
              'creditLimit', a.credit_limit, 'dueDays', a.due_days, 'overdueDays', a.overdue_days,
              'discountPct', a.discount_pct, 'commissionPct', a.commission_pct, 'memberLimit', a.member_limit,
              'terms', a.terms, 'services', to_jsonb(a.services)))
    from public.business_accounts a
   where a.id = p_account;
$$;
revoke execute on function public.business_settings_for(uuid) from public, anon, authenticated;

-- ---- Membership ----------------------------------------------------------------------------------------------
-- The caller's (or [p_uid]'s) live membership of [p_account]: by profile, or
-- an invitation to their phone, never a removed one.
create or replace function public.business_member_row(p_account uuid, p_uid uuid)
returns public.business_members
language sql
stable
security definer
set search_path = public
as $$
  select m.*
    from public.business_members m
   where m.account_id = p_account and m.status <> 'removed'
     and (m.profile_id = p_uid
          or (m.profile_id is null and m.phone_digits <> ''
              and m.phone_digits = (select public.business_digits(p.phone) from public.profiles p where p.id = p_uid)))
   order by (m.profile_id = p_uid) desc nulls last
   limit 1;
$$;
revoke execute on function public.business_member_row(uuid, uuid) from public, anon, authenticated;

create or replace function public.business_caller_is_admin_of(p_account uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.business_members m
                  where m.account_id = p_account and m.profile_id = auth.uid()
                    and m.status = 'active' and m.role = 'admin');
$$;
revoke execute on function public.business_caller_is_admin_of(uuid) from public, anon, authenticated;

-- ---- Money under way and spent --------------------------------------------------------------------------------
-- What the account's (or a member's) trips under way are estimated at, after
-- the discount, leaving out [p_exclude].
create or replace function public.business_under_way(p_account uuid, p_member uuid, p_exclude uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(round(public.ride_amount_due(r) * (1 - coalesce(r.business_discount_pct, 0) / 100), 2)), 0)
    from public.ride_requests r
   where r.business_account_id = p_account
     and (p_member is null or r.business_member_id = p_member)
     and r.status in ('open', 'accepted', 'arrived', 'on_trip')
     and r.id is distinct from p_exclude;
$$;
revoke execute on function public.business_under_way(uuid, uuid, uuid) from public, anon, authenticated;

-- What the account (or a member) was charged in the month holding [p_at].
create or replace function public.business_month_spend(p_account uuid, p_member uuid, p_at timestamptz)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(t.charged), 0)
    from public.business_trips t
   where t.account_id = p_account
     and (p_member is null or t.member_id = p_member)
     and public.business_month_of(t.completed_at) = public.business_month_of(p_at);
$$;
revoke execute on function public.business_month_spend(uuid, uuid, timestamptz) from public, anon, authenticated;

-- Unpaid invoiced and accruing amounts: what counts against the credit limit.
create or replace function public.business_owed(p_account uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(i.amount), 0) from public.business_invoices i
   where i.account_id = p_account and i.terms = 'invoice' and i.status in ('open', 'issued');
$$;
revoke execute on function public.business_owed(uuid) from public, anon, authenticated;

-- The oldest invoice unpaid [overdueDays] or more after its due date: the
-- account's bookings are paused while there is one.
create or replace function public.business_overdue_invoice(p_account uuid)
returns public.business_invoices
language sql
stable
security definer
set search_path = public
as $$
  select i.* from public.business_invoices i
   where i.account_id = p_account and i.status = 'issued' and i.due_date is not null
     and public.business_today() - i.due_date
         >= coalesce((public.business_settings_for(p_account)->>'overdueDays')::int, 14)
   order by i.due_date
   limit 1;
$$;
revoke execute on function public.business_overdue_invoice(uuid) from public, anon, authenticated;

-- 'freight', 'courier', 'scheduled' or 'ride'.
create or replace function public.business_kind_of(p_service text, p_scheduled boolean)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when public.driver_service_key(p_service) = any (public.freight_service_keys()) then 'freight'
    when public.driver_service_key(p_service) = any (public.courier_service_keys()) then 'courier'
    when p_scheduled then 'scheduled'
    else 'ride' end;
$$;
revoke execute on function public.business_kind_of(text, boolean) from public, anon, authenticated;

-- ---- 4/5. The check ---------------------------------------------------------------------------------------------
-- Whether [p_uid] may book on [p_account] a trip of [p_kind] for [p_amount]
-- at [p_at]. {ok: true, memberId, role, terms, discountPct, commissionPct,
-- approvalId} or {ok: false, code, message, needsNote, needsApproval,
-- approvalPending}. Nothing is written. [p_exclude]: the ride itself, when
-- its fare is checked again.
create or replace function public.business_check(
  p_account uuid, p_uid uuid, p_kind text, p_amount numeric, p_at timestamptz, p_tz text,
  p_note text, p_for_other boolean, p_payer text, p_exclude uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a public.business_accounts;
  m public.business_members;
  s jsonb;
  v_tz text := coalesce(nullif(btrim(p_tz), ''), 'Asia/Kuala_Lumpur');
  v_amount numeric := round(greatest(coalesce(p_amount, 0), 0), 2);
  v_disc numeric;
  v_net numeric;
  v_h int;
  v_limit numeric;
  v_used numeric;
  v_appr uuid;
  v_kind_label text;
  inv public.business_invoices;
  no jsonb := jsonb_build_object('ok', false);
begin
  select * into a from public.business_accounts where id = p_account;
  if a.id is null then
    return no || jsonb_build_object('code', 'NOT_MEMBER', 'message', 'This business account isn''t available.');
  end if;
  m := public.business_member_row(p_account, p_uid);
  if m.id is null or m.status <> 'active' then
    return no || jsonb_build_object('code', 'NOT_MEMBER',
      'message', case when m.id is not null then 'Join ' || a.name || ' in Account, Business first.'
                      else 'You''re not a member of ' || a.name || '.' end);
  end if;
  if a.status <> 'active' then
    return no || jsonb_build_object('code', 'ACCOUNT', 'message', case a.status
      when 'pending' then a.name || ' is waiting for approval.'
      when 'suspended' then a.name || '''s business account is suspended.'
      else a.name || '''s business account isn''t active.' end);
  end if;
  inv := public.business_overdue_invoice(p_account);
  if inv.id is not null then
    return no || jsonb_build_object('code', 'OVERDUE',
      'message', 'Business bookings are paused: invoice ' || inv.invoice_no || ' is overdue.');
  end if;

  s := public.business_settings_for(p_account);
  v_kind_label := case p_kind when 'freight' then 'Freight' when 'courier' then 'Courier'
                              when 'scheduled' then 'Scheduled rides' else 'Rides' end;
  if not (coalesce(s->'services', '[]'::jsonb) ? p_kind) then
    return no || jsonb_build_object('code', 'SERVICE', 'message', v_kind_label || ' aren''t included in ' || a.name || '''s account.');
  end if;
  if p_kind in ('freight', 'courier') and (m.role = 'rider' or (m.role = 'booker' and not a.bookers_freight)) then
    return no || jsonb_build_object('code', 'ROLE',
      'message', 'Your role can''t book Freight or Courier on ' || a.name || '.');
  end if;
  if coalesce(p_for_other, false) and m.role = 'rider' then
    return no || jsonb_build_object('code', 'ROLE', 'message', 'Riders book business trips for themselves only.');
  end if;
  if p_kind = 'courier' and coalesce(p_payer, 'sender') <> 'sender' then
    return no || jsonb_build_object('code', 'PAYER', 'message', 'On a business account the sender pays.');
  end if;
  if a.hours_on then
    if not exists (select 1 from pg_timezone_names z where z.name = v_tz) then
      v_tz := 'Asia/Kuala_Lumpur';
    end if;
    v_h := extract(hour from (coalesce(p_at, now()) at time zone v_tz))::int;
    if not (case when a.hours_from < a.hours_until then v_h >= a.hours_from and v_h < a.hours_until
                 else v_h >= a.hours_from or v_h < a.hours_until end) then
      return no || jsonb_build_object('code', 'HOURS', 'message',
        'Business trips are only from ' || lpad(a.hours_from::text, 2, '0') || ':00 until '
        || lpad(a.hours_until::text, 2, '0') || ':00.');
    end if;
  end if;
  if a.note_required and btrim(coalesce(p_note, '')) = '' then
    return no || jsonb_build_object('code', 'NOTE', 'needsNote', true,
      'message', 'Add a trip note (the project or the reason).');
  end if;
  if a.approval_on and m.role <> 'admin' and v_amount > a.approval_over then
    select x.id into v_appr from public.business_approvals x
     where x.member_id = m.id and x.status = 'approved' and x.amount >= v_amount
       and (x.expires_at is null or x.expires_at > now())
     order by x.amount, x.decided_at
     limit 1;
    if v_appr is null then
      return no || jsonb_build_object('code', 'APPROVAL', 'needsApproval', true,
        'approvalPending', exists (select 1 from public.business_approvals x
                                    where x.member_id = m.id and x.status = 'pending'),
        'message', 'Trips above ' || public.business_money(a.approval_over) || ' need an Admin''s approval.');
    end if;
  end if;

  v_disc := coalesce((s->>'discountPct')::numeric, 0);
  v_net := round(v_amount * (1 - v_disc / 100), 2);
  v_limit := coalesce(m.monthly_limit, (s->>'memberLimit')::numeric, 0);
  if v_limit > 0 then
    v_used := public.business_month_spend(p_account, m.id, coalesce(p_at, now()))
              + public.business_under_way(p_account, m.id, p_exclude);
    if v_used + v_net > v_limit then
      return no || jsonb_build_object('code', 'MEMBER_LIMIT', 'message',
        'This trip goes over your monthly limit of ' || public.business_money(v_limit)
        || ' (' || public.business_money(round(v_used, 2)) || ' used).');
    end if;
  end if;
  if a.cap_on then
    v_used := public.business_month_spend(p_account, null, coalesce(p_at, now()))
              + public.business_under_way(p_account, null, p_exclude);
    if v_used + v_net > a.monthly_cap then
      return no || jsonb_build_object('code', 'CAP', 'message',
        'This trip goes over ' || a.name || '''s monthly spend cap.');
    end if;
  end if;
  if coalesce(s->>'terms', 'invoice') = 'wallet' then
    if a.wallet_balance - public.business_under_way(p_account, null, p_exclude) < v_net then
      return no || jsonb_build_object('code', 'WALLET', 'message',
        a.name || '''s business wallet doesn''t have enough for this trip.');
    end if;
  elsif public.business_owed(p_account) + public.business_under_way(p_account, null, p_exclude) + v_net
        > coalesce((s->>'creditLimit')::numeric, 0) then
    return no || jsonb_build_object('code', 'CREDIT', 'message',
      'This trip goes over ' || a.name || '''s credit limit.');
  end if;

  return jsonb_build_object('ok', true, 'memberId', m.id, 'role', m.role, 'name', a.name,
    'terms', coalesce(s->>'terms', 'invoice'), 'discountPct', v_disc,
    'commissionPct', (s->>'commissionPct')::numeric, 'approvalId', v_appr, 'estimate', v_net);
end;
$$;
revoke execute on function public.business_check(uuid, uuid, text, numeric, timestamptz, text, text, boolean, text, uuid)
  from public, anon, authenticated;

-- The app's check before it books: the caller, the service as named, the
-- fare, now or the pickup time of a booking for later.
create or replace function public.business_booking_check(
  p_account uuid, p_service text, p_fare numeric, p_pickup_at timestamptz default null,
  p_note text default null, p_for_other boolean default false, p_payer text default null)
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
  return public.business_check(p_account, auth.uid(), public.business_kind_of(p_service, p_pickup_at is not null),
    p_fare, coalesce(p_pickup_at, now()), null, p_note, p_for_other, p_payer, null);
end;
$$;
revoke execute on function public.business_booking_check(uuid, text, numeric, timestamptz, text, boolean, text) from public, anon;
grant execute on function public.business_booking_check(uuid, text, numeric, timestamptz, text, boolean, text) to authenticated;

create or replace function public.business_raise(p jsonb)
returns void
language plpgsql
set search_path = public
as $$
begin
  raise exception '%', 'BUSINESS_' || coalesce(p->>'code', 'REFUSED') using errcode = '22023',
    hint = coalesce(p->>'message', 'This business booking isn''t allowed.');
end;
$$;
revoke execute on function public.business_raise(jsonb) from public, anon, authenticated;

-- ---- The ride, as it is written ----------------------------------------------------------------------------
create or replace function public.ride_requests_business()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  -- The apps (PostgREST sets the role); not the server's own writes.
  v_client boolean := coalesce(current_setting('role', true), '') in ('anon', 'authenticated');
  c jsonb;
  a public.business_accounts;
  m public.business_members;
  sr public.scheduled_rides;
  v_amount numeric;
begin
  if tg_op = 'UPDATE' then
    if old.business_account_id is null and new.business_account_id is null then
      return new;
    end if;
    if v_client and not public.caller_is_admin()
       and (new.business_account_id, new.business_note, new.business_member_id, new.business_terms,
            new.business_discount_pct, new.business_commission_pct, new.business_approval_id)
           is distinct from
           (old.business_account_id, old.business_note, old.business_member_id, old.business_terms,
            old.business_discount_pct, old.business_commission_pct, old.business_approval_id) then
      raise exception 'RIDE_SERVER_ONLY' using errcode = '42501',
        hint = 'A business booking can''t be changed. Cancel it and book again.';
    end if;
    if v_client and old.business_account_id is not null
       and new.payment_mode is distinct from old.payment_mode then
      new.payment_mode := old.payment_mode;
    end if;
    -- A fare raised while it is open (or an offer taken) is checked again.
    if v_client and old.business_account_id is not null and old.status = 'open'
       and public.ride_amount_due(new) > public.ride_amount_due(old) + 0.005 then
      c := public.business_check(new.business_account_id, new.rider_id,
             public.business_kind_of(new.service, new.scheduled_ride_id is not null),
             public.ride_amount_due(new), now(), new.timezone, new.business_note,
             new.booked_for_name is not null, new.payer, new.id);
      -- The approval this ride holds covers it up to its amount.
      if not (c->>'ok')::boolean and c->>'code' = 'APPROVAL' and new.business_approval_id is not null
         and exists (select 1 from public.business_approvals x
                      where x.id = new.business_approval_id and x.amount >= public.ride_amount_due(new)) then
        c := jsonb_build_object('ok', true);
      end if;
      if not (c->>'ok')::boolean then
        perform public.business_raise(c);
      end if;
    end if;
    return new;
  end if;

  -- INSERT.
  new.business_member_id := null;
  new.business_terms := null;
  new.business_discount_pct := null;
  new.business_commission_pct := null;
  if new.business_account_id is null then
    new.business_note := null;
    new.business_approval_id := null;
    return new;
  end if;
  new.business_note := nullif(left(btrim(coalesce(new.business_note, '')), 200), '');
  select * into a from public.business_accounts where id = new.business_account_id;
  -- A booking for later being released: checked when it was booked (on the
  -- same account); now only that the account and the member are still active.
  if new.scheduled_ride_id is not null and not v_client then
    select * into sr from public.scheduled_rides s
     where s.id = new.scheduled_ride_id and s.rider_id = new.rider_id
       and s.request->>'business_account_id' = new.business_account_id::text;
  end if;
  if sr.id is not null then
    m := public.business_member_row(new.business_account_id, new.rider_id);
    if a.id is null or a.status <> 'active' or m.id is null or m.status <> 'active' then
      raise exception 'BUSINESS_ACCOUNT' using errcode = '22023',
        hint = 'The business account for this booking is no longer active.';
    end if;
    c := public.business_settings_for(a.id);
    new.business_member_id := m.id;
    new.business_terms := coalesce(c->>'terms', 'invoice');
    new.business_discount_pct := coalesce((c->>'discountPct')::numeric, 0);
    new.business_commission_pct := (c->>'commissionPct')::numeric;
    new.business_approval_id := case
      when coalesce(sr.request->>'business_approval_id', '') ~* '^[0-9a-f-]{36}$'
      then (sr.request->>'business_approval_id')::uuid end;
  else
    new.business_approval_id := null;
    v_amount := public.ride_amount_due(new);
    c := public.business_check(new.business_account_id, new.rider_id,
           public.business_kind_of(new.service, new.scheduled_ride_id is not null),
           v_amount, now(), new.timezone, new.business_note, new.booked_for_name is not null, new.payer, null);
    if not (c->>'ok')::boolean then
      perform public.business_raise(c);
    end if;
    new.business_member_id := (c->>'memberId')::uuid;
    new.business_terms := c->>'terms';
    new.business_discount_pct := (c->>'discountPct')::numeric;
    new.business_commission_pct := (c->>'commissionPct')::numeric;
    if c->>'approvalId' is not null then
      update public.business_approvals set status = 'used', ride_id = new.id
       where id = (c->>'approvalId')::uuid and status = 'approved';
      new.business_approval_id := (c->>'approvalId')::uuid;
    end if;
  end if;
  new.payment_mode := left('Business: ' || a.name, 120);
  -- The company pays: no promo code on a business trip.
  new.promo_code_id := null;
  return new;
end;
$$;
revoke execute on function public.ride_requests_business() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_c_business on public.ride_requests;
create trigger trg_ride_requests_c_business
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_business();

-- ---- A booking for later ------------------------------------------------------------------------------------
-- Checked at its pickup time as it is booked (schedule_ride, 0221); the
-- release carries the account, the note and the approval to the ride.
create or replace function public.scheduled_rides_business()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  q jsonb := coalesce(new.request, '{}'::jsonb);
  v_acc uuid;
  c jsonb;
  v_amount numeric;
begin
  if new.stand_id is not null then
    new.request := q - 'business_account_id' - 'business_note' - 'business_approval_id';
    return new;
  end if;
  if coalesce(q->>'business_account_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_acc := (q->>'business_account_id')::uuid;
  end if;
  q := q - 'business_approval_id';
  if v_acc is null then
    new.request := q - 'business_account_id' - 'business_note';
    return new;
  end if;
  v_amount := round(new.fare + coalesce(new.scheduling_fee, 0), 2);
  c := public.business_check(v_acc, new.rider_id, public.business_kind_of(new.service, true), v_amount,
         new.pickup_at, q->>'timezone', q->>'business_note', new.booked_for_name is not null, q->>'payer', null);
  if not (c->>'ok')::boolean then
    perform public.business_raise(c);
  end if;
  if c->>'approvalId' is not null then
    update public.business_approvals set status = 'used', scheduled_ride_id = new.id
     where id = (c->>'approvalId')::uuid and status = 'approved';
    q := q || jsonb_build_object('business_approval_id', c->>'approvalId');
  end if;
  q := (q - 'promo_code_id') || jsonb_build_object('payment_mode', left('Business: ' || (c->>'name'), 120));
  new.request := q;
  new.promo_code_id := null;
  new.promo_code := null;
  new.promo_estimate := null;
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_business() from public, anon, authenticated;

-- Before 0242's promo trigger (alphabetical), so no promo is quoted.
drop trigger if exists trg_scheduled_rides_a_business on public.scheduled_rides;
create trigger trg_scheduled_rides_a_business
  before insert on public.scheduled_rides
  for each row execute function public.scheduled_rides_business();

-- As 0312 (0268 plus the add-ons), with the business keys (0313).
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
       'parcel_cover', 'round_trip', 'stairs_pickup', 'stairs_drop', 'cold_level', 'cod_amount',
       -- 0313: the business account it is charged to, and its note (the
       -- approval is the server's: scheduled_rides_business sets it).
       'business_account_id', 'business_note', 'business_approval_id'])
       and (e.key <> 'charges' or jsonb_typeof(e.value) = 'array')
  ), '{}'::jsonb);
$$;

-- ---- 6. Settlement ---------------------------------------------------------------------------------------------
-- The month's open invoice of [p_account] for [p_terms], made when missing.
create or replace function public.business_open_invoice(p_account uuid, p_terms text, p_at timestamptz)
returns public.business_invoices
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start date := public.business_month_of(p_at);
  i public.business_invoices;
begin
  insert into public.business_invoices (account_id, invoice_no, terms, period_start, period_end)
  values (p_account,
          'GR' || to_char(v_start, 'YYMM') || '-' || upper(left(replace(p_account::text, '-', ''), 6))
            || case when p_terms = 'wallet' then '-S' else '' end,
          p_terms, v_start, (v_start + interval '1 month - 1 day')::date)
  on conflict (account_id, period_start, terms) do nothing;
  select * into i from public.business_invoices
   where account_id = p_account and period_start = v_start and terms = p_terms for update;
  return i;
end;
$$;
revoke execute on function public.business_open_invoice(uuid, text, timestamptz) from public, anon, authenticated;

-- {settled, gross, discount, charged} once per ride.
create or replace function public.business_settle_ride(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  a public.business_accounts;
  m public.business_members;
  i public.business_invoices;
  v_gross numeric;
  v_disc numeric;
  v_charged numeric;
  v_terms text;
  v_bal numeric;
begin
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.business_account_id is null or r.status <> 'completed' then
    return jsonb_build_object('settled', false);
  end if;
  if exists (select 1 from public.business_trips t where t.ride_id = r.id) then
    return jsonb_build_object('settled', true, 'already', true);
  end if;
  select * into a from public.business_accounts where id = r.business_account_id for update;
  select * into m from public.business_members where id = r.business_member_id;

  v_gross := public.ride_left_to_pay(r);
  v_disc := round(v_gross * coalesce(r.business_discount_pct, 0) / 100, 2);
  v_charged := v_gross - v_disc;
  v_terms := coalesce(r.business_terms, 'invoice');

  -- The driver, as an in-app payment.
  if v_gross > 0 and r.partner_id is not null then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
    values (r.partner_id, 'get_wallet', 'ride_earning', v_gross, 'business',
            'Business trip fare received — RM' || to_char(v_gross, 'FM999999990.00'), r.id);
  end if;

  i := public.business_open_invoice(a.id, v_terms, coalesce(r.completed_at, now()));
  update public.business_invoices
     set gross = gross + v_gross, discount = discount + v_disc, amount = amount + v_charged,
         trips = trips + 1, updated_at = now()
   where id = i.id;

  if v_terms = 'wallet' and v_charged > 0 then
    update public.business_accounts set wallet_balance = wallet_balance - v_charged
     where id = a.id returning wallet_balance into v_bal;
    insert into public.business_wallet_entries (account_id, amount, kind, ride_id, note, balance_after)
    values (a.id, -v_charged, 'trip', r.id,
            left(coalesce(r.pickup_name, 'Trip') || ' to ' || coalesce(r.drop_name, ''), 300), v_bal);
  end if;

  insert into public.business_trips (ride_id, account_id, member_id, profile_id, member_name, team, booked_for_name,
    service, kind, pickup, dropoff, note, completed_at, gross, discount, charged, discount_pct, commission_pct,
    terms, invoice_id)
  values (r.id, a.id, m.id, r.rider_id, coalesce(m.name, r.rider_name), m.team, r.booked_for_name,
    r.service, public.business_kind_of(r.service, r.scheduled_ride_id is not null),
    left(coalesce(r.pickup_name, r.pickup_address), 200), left(coalesce(r.drop_name, r.drop_address), 200),
    r.business_note, coalesce(r.completed_at, now()), v_gross, v_disc, v_charged,
    coalesce(r.business_discount_pct, 0), r.business_commission_pct, v_terms, i.id);

  update public.ride_requests
     set payment_status = 'paid', paid_method = 'business', paid_amount = v_gross, paid_at = now()
   where id = r.id;

  return jsonb_build_object('settled', true, 'gross', v_gross, 'discount', v_disc, 'charged', v_charged);
end;
$$;
revoke execute on function public.business_settle_ride(uuid) from public, anon, authenticated;

create or replace function public.ride_requests_business_settle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.business_settle_ride(new.id);
  return null;
end;
$$;
revoke execute on function public.ride_requests_business_settle() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_business_settle on public.ride_requests;
create trigger trg_ride_requests_business_settle
  after update of status on public.ride_requests
  for each row
  when (new.status = 'completed' and old.status is distinct from 'completed' and new.business_account_id is not null)
  execute function public.ride_requests_business_settle();

-- ---- The commission: the business rate on business trips ------------------------------------------------------
-- As 0306, with the business commission % when the ride has one.
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
  if new.business_account_id is not null and new.business_commission_pct is not null then
    new.commission_base_rate := round(new.business_commission_pct / 100, 4);
    new.commission_rate := round(new.business_commission_pct / 100, 4);
    new.commission_tier_id := null;
    new.commission_promotion_id := null;
    new.commission_rule_id := null;
    new.commission_locked_at := now();
    return new;
  end if;
  begin
    select * into v from public.commission_resolve(
      new.partner_id, new.pickup_lat, new.pickup_lng, new.country, new.state, new.city, new.suburb, new.service);
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

-- As 0306, with the business commission % when the ride has one.
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
  elsif r.business_account_id is not null and r.business_commission_pct is not null then
    v_rate := round(r.business_commission_pct / 100, 4);
  else
    -- Never locked (accepted before 0216, or the lock failed): found now.
    select * into v from public.commission_resolve(
      r.partner_id, r.pickup_lat, r.pickup_lng, r.country, r.state, r.city, r.suburb, r.service);
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

-- ---- 7. Invoices -------------------------------------------------------------------------------------------------
-- Issues every open invoice whose month has ended: an invoice account's falls
-- due after its due days, a wallet account's statement is issued paid. The
-- company's Admins are told. Answers how many were issued.
create or replace function public.business_invoices_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  i record;
  v_due int;
  v_n int := 0;
  m record;
begin
  for i in
    select x.*, a.name as account_name from public.business_invoices x
      join public.business_accounts a on a.id = x.account_id
     where x.status = 'open' and x.period_end < public.business_today()
     order by x.period_start
     for update of x
  loop
    v_due := coalesce((public.business_settings_for(i.account_id)->>'dueDays')::int, 30);
    if i.terms = 'wallet' or i.amount <= 0 then
      update public.business_invoices
         set status = 'paid', issued_at = now(), due_date = i.period_end, paid_at = now(),
             paid_note = case when i.terms = 'wallet' then 'Prepaid from the business wallet' else 'Nothing to pay' end,
             updated_at = now()
       where id = i.id;
    else
      update public.business_invoices
         set status = 'issued', issued_at = now(), due_date = i.period_end + v_due, updated_at = now()
       where id = i.id;
      for m in select profile_id from public.business_members
                where account_id = i.account_id and role = 'admin' and status = 'active' and profile_id is not null loop
        perform public.enqueue_notification(m.profile_id, 'business-invoice-' || i.id, 'business', 'normal',
          'Invoice ' || i.invoice_no,
          i.account_name || ': ' || public.business_money(i.amount) || ' for '
            || to_char(i.period_start, 'FMMonth YYYY') || ', due ' || to_char(i.period_end + v_due, 'FMDD Mon YYYY') || '.',
          jsonb_build_object('type', 'business_invoice', 'invoice_id', i.id, 'account_id', i.account_id));
      end loop;
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.business_invoices_tick() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'business-invoices';
    -- 00:15 in Malaysia.
    perform cron.schedule('business-invoices', '15 16 * * *', $job$select public.business_invoices_tick()$job$);
  end if;
end $$;

-- The trips on [p_invoice], for its PDF and CSV: the company's Admins and
-- admins. {invoice, account, lines: [...]}.
create or replace function public.business_invoice_lines(p_invoice uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  i public.business_invoices;
  a public.business_accounts;
begin
  select * into i from public.business_invoices where id = p_invoice;
  if i.id is null or not (public.caller_is_admin() or public.business_caller_is_admin_of(i.account_id)) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into a from public.business_accounts where id = i.account_id;
  return jsonb_build_object(
    'invoice', to_jsonb(i),
    'account', jsonb_build_object('id', a.id, 'name', a.name, 'regNo', a.reg_no, 'address', a.address,
                                  'state', a.state, 'country', a.country),
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object(
               'at', t.completed_at, 'member', t.member_name, 'team', t.team, 'for', t.booked_for_name,
               'service', t.service, 'kind', t.kind, 'pickup', t.pickup, 'dropoff', t.dropoff, 'note', t.note,
               'gross', t.gross, 'discount', t.discount, 'charged', t.charged)
             order by t.completed_at)
        from public.business_trips t where t.invoice_id = i.id), '[]'::jsonb));
end;
$$;
revoke execute on function public.business_invoice_lines(uuid) from public, anon;
grant execute on function public.business_invoice_lines(uuid) to authenticated;

-- ---- 1/3. Applying and members ---------------------------------------------------------------------------------
create or replace function public.business_apply(
  p_name text, p_reg_no text, p_company_type text, p_address text,
  p_country text, p_state text, p_city text, p_document_url text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_phone text;
  v_name text;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_name, ''))) < 2 or length(btrim(coalesce(p_reg_no, ''))) < 3 then
    raise exception 'BUSINESS_DETAILS' using errcode = '22023', hint = 'Enter the company name and its SSM number.';
  end if;
  if coalesce(p_document_url, '') = '' then
    raise exception 'BUSINESS_DOCUMENT' using errcode = '22023', hint = 'Upload the company''s SSM document.';
  end if;
  if exists (select 1 from public.business_accounts
              where upper(regexp_replace(reg_no, '\s', '', 'g')) = upper(regexp_replace(p_reg_no, '\s', '', 'g'))
                and status <> 'rejected') then
    raise exception 'BUSINESS_EXISTS' using errcode = '23505',
      hint = 'This company already has a business account. Ask its Admin to invite you.';
  end if;
  if (select count(*) from public.business_accounts where applied_by = v_uid and status = 'pending') >= 3 then
    raise exception 'BUSINESS_LIMIT' using errcode = '22023', hint = 'You already have applications waiting.';
  end if;
  select phone, name into v_phone, v_name from public.profiles where id = v_uid;
  if length(public.business_digits(v_phone)) < 6 then
    raise exception 'BUSINESS_PHONE' using errcode = '22023', hint = 'Add your phone number to your profile first.';
  end if;
  insert into public.business_accounts (name, reg_no, company_type, address, country, state, city, document_url, applied_by)
  values (btrim(p_name), btrim(p_reg_no), nullif(btrim(coalesce(p_company_type, '')), ''),
          nullif(btrim(coalesce(p_address, '')), ''), coalesce(nullif(btrim(coalesce(p_country, '')), ''), 'Malaysia'),
          btrim(coalesce(p_state, '')), btrim(coalesce(p_city, '')), p_document_url, v_uid)
  returning id into v_id;
  insert into public.business_members (account_id, profile_id, phone, name, role, status, invited_by, joined_at)
  values (v_id, v_uid, v_phone, left(v_name, 80), 'admin', 'active', v_uid, now());
  return v_id;
end;
$$;
revoke execute on function public.business_apply(text, text, text, text, text, text, text, text) from public, anon;
grant execute on function public.business_apply(text, text, text, text, text, text, text, text) to authenticated;

-- The caller's accounts and invitations: [{account fields, role, memberStatus,
-- myLimit, mySpend, settings}].
create or replace function public.business_my_accounts()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_digits text;
begin
  if v_uid is null then
    return '[]'::jsonb;
  end if;
  select public.business_digits(phone) into v_digits from public.profiles where id = v_uid;
  return coalesce((
    select jsonb_agg(x.j order by x.created_at)
      from (
        select distinct on (a.id) a.created_at, jsonb_build_object(
                 'id', a.id, 'name', a.name, 'status', a.status, 'statusNote', a.status_note,
                 'memberId', m.id, 'role', m.role, 'team', m.team, 'memberStatus', m.status,
                 'myLimit', coalesce(m.monthly_limit, (public.business_settings_for(a.id)->>'memberLimit')::numeric, 0),
                 'mySpend', public.business_month_spend(a.id, m.id, now()),
                 'noteRequired', a.note_required,
                 'services', public.business_settings_for(a.id)->'services',
                 'bookersFreight', a.bookers_freight) as j
          from public.business_members m
          join public.business_accounts a on a.id = m.account_id
         where m.status <> 'removed' and a.status <> 'rejected'
           and (m.profile_id = v_uid or (m.profile_id is null and m.phone_digits = v_digits and v_digits <> ''))
         order by a.id, (m.profile_id = v_uid) desc nulls last) x), '[]'::jsonb);
end;
$$;
revoke execute on function public.business_my_accounts() from public, anon;
grant execute on function public.business_my_accounts() to authenticated;

create or replace function public.business_join(p_account uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.business_members;
  v_name text;
begin
  m := public.business_member_row(p_account, auth.uid());
  if m.id is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select name into v_name from public.profiles where id = auth.uid();
  update public.business_members
     set profile_id = auth.uid(), status = 'active', joined_at = coalesce(joined_at, now()),
         name = coalesce(name, left(v_name, 80)), updated_at = now()
   where id = m.id;
end;
$$;
revoke execute on function public.business_join(uuid) from public, anon;
grant execute on function public.business_join(uuid) to authenticated;

-- Leaving (or turning down an invitation). The last Admin stays.
create or replace function public.business_leave(p_account uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.business_members;
begin
  m := public.business_member_row(p_account, auth.uid());
  if m.id is null then
    return;
  end if;
  if m.role = 'admin' and m.status = 'active'
     and not exists (select 1 from public.business_members x where x.account_id = p_account and x.id <> m.id
                       and x.role = 'admin' and x.status = 'active') then
    raise exception 'BUSINESS_LAST_ADMIN' using errcode = '22023', hint = 'Make someone else an Admin first.';
  end if;
  update public.business_members set status = 'removed', updated_at = now() where id = m.id;
end;
$$;
revoke execute on function public.business_leave(uuid) from public, anon;
grant execute on function public.business_leave(uuid) to authenticated;

-- One account as a member sees it: the overview for everyone; members,
-- rules, invoices, approvals and the wallet for its Admins.
create or replace function public.business_account_detail(p_account uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a public.business_accounts;
  m public.business_members;
  s jsonb;
  v_admin boolean;
  v_month date := public.business_month_of(now());
  inv public.business_invoices;
  j jsonb;
begin
  select * into a from public.business_accounts where id = p_account;
  m := public.business_member_row(p_account, auth.uid());
  if a.id is null or ((m.id is null or m.status <> 'active') and not public.caller_is_admin()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  v_admin := (m.role = 'admin' and m.status = 'active') or public.caller_is_admin();
  s := public.business_settings_for(p_account);
  inv := public.business_overdue_invoice(p_account);
  j := jsonb_build_object(
    'id', a.id, 'name', a.name, 'regNo', a.reg_no, 'status', a.status, 'statusNote', a.status_note,
    'state', a.state, 'country', a.country,
    'role', m.role, 'memberId', m.id, 'isAdmin', v_admin, 'settings', s,
    'pausedBy', inv.invoice_no,
    'monthSpend', public.business_month_spend(a.id, null, now()),
    'monthTrips', (select count(*) from public.business_trips t
                    where t.account_id = a.id and public.business_month_of(t.completed_at) = v_month
                      and t.kind in ('ride', 'scheduled')),
    'monthDeliveries', (select count(*) from public.business_trips t
                         where t.account_id = a.id and public.business_month_of(t.completed_at) = v_month
                           and t.kind in ('freight', 'courier')),
    'mySpend', public.business_month_spend(a.id, m.id, now()),
    'myLimit', coalesce(m.monthly_limit, (s->>'memberLimit')::numeric, 0),
    'nextInvoice', (date_trunc('month', now() at time zone 'Asia/Kuala_Lumpur') + interval '1 month')::date,
    'walletBalance', a.wallet_balance,
    'rules', jsonb_build_object('hoursOn', a.hours_on, 'hoursFrom', a.hours_from, 'hoursUntil', a.hours_until,
      'noteRequired', a.note_required, 'approvalOn', a.approval_on, 'approvalOver', a.approval_over,
      'capOn', a.cap_on, 'monthlyCap', a.monthly_cap, 'bookersFreight', a.bookers_freight));
  if v_admin then
    j := j || jsonb_build_object(
      'members', coalesce((select jsonb_agg(jsonb_build_object(
          'id', x.id, 'name', coalesce(x.name, p.name), 'phone', x.phone, 'role', x.role, 'team', x.team,
          'monthlyLimit', x.monthly_limit, 'status', x.status,
          'spend', public.business_month_spend(a.id, x.id, now()))
          order by case x.role when 'admin' then 0 when 'booker' then 1 else 2 end, coalesce(x.name, p.name))
        from public.business_members x left join public.profiles p on p.id = x.profile_id
       where x.account_id = a.id and x.status <> 'removed'), '[]'::jsonb),
      'invoices', coalesce((select jsonb_agg(to_jsonb(i) order by i.period_start desc, i.terms)
        from (select * from public.business_invoices where account_id = a.id
               order by period_start desc limit 24) i), '[]'::jsonb),
      'approvals', coalesce((select jsonb_agg(jsonb_build_object(
          'id', x.id, 'member', coalesce(bm.name, ''), 'amount', x.amount, 'service', x.service,
          'pickup', x.pickup, 'dropoff', x.dropoff, 'note', x.note, 'status', x.status, 'at', x.created_at)
          order by x.created_at desc)
        from public.business_approvals x join public.business_members bm on bm.id = x.member_id
       where x.account_id = a.id and (x.status = 'pending' or x.created_at > now() - interval '7 days')), '[]'::jsonb));
  end if;
  return j;
end;
$$;
revoke execute on function public.business_account_detail(uuid) from public, anon;
grant execute on function public.business_account_detail(uuid) to authenticated;

create or replace function public.business_require_admin(p_account uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.business_caller_is_admin_of(p_account) then
    raise exception 'not_authorized' using errcode = '42501', hint = 'Only the company''s Admins can do this.';
  end if;
end;
$$;
revoke execute on function public.business_require_admin(uuid) from public, anon, authenticated;

create or replace function public.business_member_invite(
  p_account uuid, p_phone text, p_name text, p_role text, p_team text default null, p_limit numeric default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_profile uuid;
begin
  perform public.business_require_admin(p_account);
  if length(public.business_digits(p_phone)) < 6 or length(btrim(coalesce(p_phone, ''))) > 32 then
    raise exception 'BUSINESS_PHONE' using errcode = '22023', hint = 'Enter the person''s phone number.';
  end if;
  if coalesce(p_role, '') not in ('admin', 'booker', 'rider') then
    raise exception 'BUSINESS_ROLE' using errcode = '22023', hint = 'Pick Admin, Booker or Rider.';
  end if;
  if (select count(*) from public.business_members where account_id = p_account and status <> 'removed') >= 500 then
    raise exception 'BUSINESS_MEMBERS' using errcode = '22023', hint = 'An account has 500 members at most.';
  end if;
  if exists (select 1 from public.business_members where account_id = p_account and status <> 'removed'
               and phone_digits = public.business_digits(p_phone)) then
    raise exception 'BUSINESS_MEMBER_EXISTS' using errcode = '23505', hint = 'This number is already a member.';
  end if;
  insert into public.business_members (account_id, phone, name, role, team, monthly_limit, status, invited_by)
  values (p_account, btrim(p_phone), nullif(left(btrim(coalesce(p_name, '')), 80), ''), p_role,
          nullif(left(btrim(coalesce(p_team, '')), 60), ''), p_limit, 'invited', auth.uid())
  returning id into v_id;
  select id into v_profile from public.profiles
   where public.business_digits(phone) = public.business_digits(p_phone) and deleted_at is null limit 1;
  if v_profile is not null then
    perform public.enqueue_notification(v_profile, 'business-invite-' || v_id, 'business', 'normal',
      'Business account invitation',
      (select name from public.business_accounts where id = p_account) || ' invited you to book on its account. Open Account, Business to join.',
      jsonb_build_object('type', 'business_invite', 'account_id', p_account));
  end if;
  return v_id;
end;
$$;
revoke execute on function public.business_member_invite(uuid, text, text, text, text, numeric) from public, anon;
grant execute on function public.business_member_invite(uuid, text, text, text, text, numeric) to authenticated;

-- p_limit: null follows the account's default; [p_clear_limit] sets it back to that.
create or replace function public.business_member_update(
  p_member uuid, p_role text, p_team text, p_limit numeric, p_default_limit boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.business_members;
begin
  select * into m from public.business_members where id = p_member and status <> 'removed';
  if m.id is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  perform public.business_require_admin(m.account_id);
  if coalesce(p_role, m.role) not in ('admin', 'booker', 'rider') then
    raise exception 'BUSINESS_ROLE' using errcode = '22023', hint = 'Pick Admin, Booker or Rider.';
  end if;
  if p_limit is not null and (p_limit < 0 or p_limit > 100000000) then
    raise exception 'BUSINESS_LIMIT' using errcode = '22023', hint = 'A limit is RM 0 or more.';
  end if;
  if m.role = 'admin' and coalesce(p_role, m.role) <> 'admin' and m.status = 'active'
     and not exists (select 1 from public.business_members x where x.account_id = m.account_id and x.id <> m.id
                       and x.role = 'admin' and x.status = 'active') then
    raise exception 'BUSINESS_LAST_ADMIN' using errcode = '22023', hint = 'An account keeps at least one Admin.';
  end if;
  update public.business_members
     set role = coalesce(p_role, role),
         team = case when p_team is null then team else nullif(left(btrim(p_team), 60), '') end,
         monthly_limit = case when p_default_limit then null else coalesce(p_limit, monthly_limit) end,
         updated_at = now()
   where id = m.id;
end;
$$;
revoke execute on function public.business_member_update(uuid, text, text, numeric, boolean) from public, anon;
grant execute on function public.business_member_update(uuid, text, text, numeric, boolean) to authenticated;

create or replace function public.business_member_remove(p_member uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.business_members;
begin
  select * into m from public.business_members where id = p_member and status <> 'removed';
  if m.id is null then
    return;
  end if;
  perform public.business_require_admin(m.account_id);
  if m.role = 'admin' and m.status = 'active'
     and not exists (select 1 from public.business_members x where x.account_id = m.account_id and x.id <> m.id
                       and x.role = 'admin' and x.status = 'active') then
    raise exception 'BUSINESS_LAST_ADMIN' using errcode = '22023', hint = 'An account keeps at least one Admin.';
  end if;
  update public.business_members set status = 'removed', updated_at = now() where id = m.id;
end;
$$;
revoke execute on function public.business_member_remove(uuid) from public, anon;
grant execute on function public.business_member_remove(uuid) to authenticated;

-- The company's own rules: {hoursOn, hoursFrom, hoursUntil, noteRequired,
-- approvalOn, approvalOver, capOn, monthlyCap, bookersFreight}; a key left
-- out keeps its value.
create or replace function public.business_rules_set(p_account uuid, p_rules jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r jsonb := coalesce(p_rules, '{}'::jsonb);
begin
  perform public.business_require_admin(p_account);
  begin
    update public.business_accounts set
      hours_on = coalesce((r->>'hoursOn')::boolean, hours_on),
      hours_from = coalesce((r->>'hoursFrom')::smallint, hours_from),
      hours_until = coalesce((r->>'hoursUntil')::smallint, hours_until),
      note_required = coalesce((r->>'noteRequired')::boolean, note_required),
      approval_on = coalesce((r->>'approvalOn')::boolean, approval_on),
      approval_over = coalesce((r->>'approvalOver')::numeric, approval_over),
      cap_on = coalesce((r->>'capOn')::boolean, cap_on),
      monthly_cap = coalesce((r->>'monthlyCap')::numeric, monthly_cap),
      bookers_freight = coalesce((r->>'bookersFreight')::boolean, bookers_freight),
      updated_at = now(), updated_by = auth.uid()
    where id = p_account;
  exception when check_violation or invalid_text_representation or numeric_value_out_of_range then
    raise exception 'BUSINESS_RULES' using errcode = '22023', hint = 'Check the rules'' values.';
  end;
end;
$$;
revoke execute on function public.business_rules_set(uuid, jsonb) from public, anon;
grant execute on function public.business_rules_set(uuid, jsonb) to authenticated;

-- ---- 4. Approvals ---------------------------------------------------------------------------------------------------
create or replace function public.business_approval_request(
  p_account uuid, p_amount numeric, p_service text, p_pickup text, p_dropoff text, p_note text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  m public.business_members;
  v_id uuid;
  x record;
begin
  m := public.business_member_row(p_account, auth.uid());
  if m.id is null or m.status <> 'active' then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount >= 1000000 then
    raise exception 'BUSINESS_AMOUNT' using errcode = '22023', hint = 'The trip''s fare is needed.';
  end if;
  if (select count(*) from public.business_approvals where member_id = m.id and status = 'pending') >= 3 then
    raise exception 'BUSINESS_APPROVALS' using errcode = '22023', hint = 'You already have 3 approvals waiting.';
  end if;
  insert into public.business_approvals (account_id, member_id, requested_by, amount, service, pickup, dropoff, note)
  values (p_account, m.id, auth.uid(), round(p_amount, 2), left(p_service, 80), left(p_pickup, 200),
          left(p_dropoff, 200), nullif(left(btrim(coalesce(p_note, '')), 300), ''))
  returning id into v_id;
  for x in select profile_id from public.business_members
            where account_id = p_account and role = 'admin' and status = 'active' and profile_id is not null
              and profile_id <> auth.uid() loop
    perform public.enqueue_notification(x.profile_id, 'business-approval-' || v_id, 'business', 'normal',
      'Trip approval asked',
      coalesce(m.name, 'A member') || ' asks to book a ' || public.business_money(round(p_amount, 2)) || ' trip.',
      jsonb_build_object('type', 'business_approval', 'approval_id', v_id, 'account_id', p_account));
  end loop;
  return v_id;
end;
$$;
revoke execute on function public.business_approval_request(uuid, numeric, text, text, text, text) from public, anon;
grant execute on function public.business_approval_request(uuid, numeric, text, text, text, text) to authenticated;

create or replace function public.business_approval_decide(p_approval uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  x public.business_approvals;
  v_to uuid;
begin
  select * into x from public.business_approvals where id = p_approval for update;
  if x.id is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  perform public.business_require_admin(x.account_id);
  if x.status <> 'pending' then
    raise exception 'BUSINESS_APPROVAL_DONE' using errcode = '22023', hint = 'This request was already answered.';
  end if;
  update public.business_approvals
     set status = case when p_approve then 'approved' else 'declined' end,
         decided_by = auth.uid(), decided_at = now(),
         expires_at = case when p_approve then now() + interval '24 hours' end
   where id = x.id;
  select profile_id into v_to from public.business_members where id = x.member_id;
  perform public.enqueue_notification(v_to, 'business-approval-answer-' || x.id, 'business', 'normal',
    case when p_approve then 'Trip approved' else 'Trip not approved' end,
    case when p_approve then 'Your ' || public.business_money(x.amount) || ' trip is approved for the next 24 hours.'
         else 'Your ' || public.business_money(x.amount) || ' trip wasn''t approved.' end,
    jsonb_build_object('type', 'business_approval_answer', 'approval_id', x.id, 'account_id', x.account_id));
end;
$$;
revoke execute on function public.business_approval_decide(uuid, boolean) from public, anon;
grant execute on function public.business_approval_decide(uuid, boolean) to authenticated;

-- ---- Admin › People › Business accounts -----------------------------------------------------------------------
insert into public.admin_table_pages (target, page) values
  ('business_region_rules', 'admin-business-accounts'),
  ('rpc:admin_business_set_status', 'admin-business-accounts'),
  ('rpc:admin_business_save', 'admin-business-accounts'),
  ('rpc:admin_business_wallet_adjust', 'admin-business-accounts'),
  ('rpc:admin_business_invoice_paid', 'admin-business-accounts'),
  ('rpc:admin_business_issue_invoices', 'admin-business-accounts')
on conflict do nothing;

create or replace function public.admin_business_set_status(p_account uuid, p_status text, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  a public.business_accounts;
  m record;
begin
  if not public.caller_admin_can_write('rpc:admin_business_set_status') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if coalesce(p_status, '') not in ('active', 'suspended', 'rejected', 'pending') then
    raise exception 'BUSINESS_STATUS' using errcode = '22023';
  end if;
  select * into a from public.business_accounts where id = p_account for update;
  if a.id is null then
    raise exception 'BUSINESS_GONE' using errcode = '22023';
  end if;
  update public.business_accounts
     set status = p_status, status_note = nullif(left(btrim(coalesce(p_note, '')), 300), ''),
         approved_at = case when p_status = 'active' then coalesce(approved_at, now()) else approved_at end,
         approved_by = case when p_status = 'active' then coalesce(approved_by, auth.uid()) else approved_by end,
         updated_at = now(), updated_by = auth.uid()
   where id = a.id;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'business_account_status', a.applied_by,
          jsonb_build_object('account_id', a.id, 'name', a.name, 'from', a.status, 'to', p_status, 'note', p_note));
  if p_status is distinct from a.status then
    for m in select profile_id from public.business_members
              where account_id = a.id and role = 'admin' and status = 'active' and profile_id is not null loop
      perform public.enqueue_notification(m.profile_id, 'business-status-' || a.id || '-' || p_status || '-' || now()::text,
        'business', 'normal',
        case p_status when 'active' then 'Business account approved' when 'suspended' then 'Business account suspended'
                      when 'rejected' then 'Business account not approved' else 'Business account' end,
        a.name || case p_status when 'active' then ' can book on its account now.'
                                when 'suspended' then '''s bookings are suspended.'
                                when 'rejected' then '''s application wasn''t approved.' else '.' end
          || coalesce(' ' || nullif(btrim(coalesce(p_note, '')), ''), ''),
        jsonb_build_object('type', 'business_status', 'account_id', a.id));
    end loop;
  end if;
end;
$$;
revoke execute on function public.admin_business_set_status(uuid, text, text) from public, anon;
grant execute on function public.admin_business_set_status(uuid, text, text) to authenticated;

-- The company's details and its overrides: every key given is set (a null
-- override follows the rules again); keys left out are kept.
create or replace function public.admin_business_save(p_account uuid, p jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_admin_can_write('rpc:admin_business_save') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  begin
    update public.business_accounts set
      name = case when p ? 'name' then btrim(p->>'name') else name end,
      reg_no = case when p ? 'regNo' then btrim(p->>'regNo') else reg_no end,
      address = case when p ? 'address' then nullif(btrim(coalesce(p->>'address', '')), '') else address end,
      country = case when p ? 'country' then btrim(p->>'country') else country end,
      state = case when p ? 'state' then btrim(coalesce(p->>'state', '')) else state end,
      city = case when p ? 'city' then btrim(coalesce(p->>'city', '')) else city end,
      credit_limit = case when p ? 'creditLimit' then (p->>'creditLimit')::numeric else credit_limit end,
      due_days = case when p ? 'dueDays' then (p->>'dueDays')::int else due_days end,
      overdue_days = case when p ? 'overdueDays' then (p->>'overdueDays')::int else overdue_days end,
      discount_pct = case when p ? 'discountPct' then (p->>'discountPct')::numeric else discount_pct end,
      commission_pct = case when p ? 'commissionPct' then (p->>'commissionPct')::numeric else commission_pct end,
      member_limit = case when p ? 'memberLimit' then (p->>'memberLimit')::numeric else member_limit end,
      terms = case when p ? 'terms' then p->>'terms' else terms end,
      services = case when p ? 'services' then
                   case when jsonb_typeof(p->'services') = 'array'
                        then array(select jsonb_array_elements_text(p->'services')) end
                 else services end,
      updated_at = now(), updated_by = auth.uid()
    where id = p_account;
  exception when check_violation or invalid_text_representation or numeric_value_out_of_range then
    raise exception 'BUSINESS_VALUES' using errcode = '22023', hint = 'Check the values.';
  end;
end;
$$;
revoke execute on function public.admin_business_save(uuid, jsonb) from public, anon;
grant execute on function public.admin_business_save(uuid, jsonb) to authenticated;

-- A top-up received (a bank transfer) or a correction of the business wallet.
create or replace function public.admin_business_wallet_adjust(p_account uuid, p_amount numeric, p_note text)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bal numeric;
begin
  if not public.caller_admin_can_write('rpc:admin_business_wallet_adjust') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_amount is null or p_amount = 0 or abs(p_amount) >= 100000000 then
    raise exception 'BUSINESS_AMOUNT' using errcode = '22023', hint = 'Enter an amount.';
  end if;
  if length(btrim(coalesce(p_note, ''))) < 2 then
    raise exception 'BUSINESS_NOTE' using errcode = '22023', hint = 'Say what it is (e.g. the bank transfer).';
  end if;
  update public.business_accounts set wallet_balance = wallet_balance + round(p_amount, 2)
   where id = p_account returning wallet_balance into v_bal;
  if v_bal is null then
    raise exception 'BUSINESS_GONE' using errcode = '22023';
  end if;
  insert into public.business_wallet_entries (account_id, amount, kind, note, balance_after, created_by)
  values (p_account, round(p_amount, 2), case when p_amount > 0 then 'topup' else 'adjust' end,
          left(btrim(p_note), 300), v_bal, auth.uid());
  insert into public.admin_audit_log (actor_id, action, detail)
  values (auth.uid(), 'business_wallet_adjust',
          jsonb_build_object('account_id', p_account, 'amount', round(p_amount, 2), 'note', p_note));
  return v_bal;
end;
$$;
revoke execute on function public.admin_business_wallet_adjust(uuid, numeric, text) from public, anon;
grant execute on function public.admin_business_wallet_adjust(uuid, numeric, text) to authenticated;

create or replace function public.admin_business_invoice_paid(p_invoice uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  i public.business_invoices;
begin
  if not public.caller_admin_can_write('rpc:admin_business_invoice_paid') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into i from public.business_invoices where id = p_invoice for update;
  if i.id is null or i.status <> 'issued' then
    raise exception 'BUSINESS_INVOICE' using errcode = '22023', hint = 'Only an issued invoice is marked paid.';
  end if;
  update public.business_invoices
     set status = 'paid', paid_at = now(), paid_by = auth.uid(),
         paid_note = nullif(left(btrim(coalesce(p_note, '')), 300), ''), updated_at = now()
   where id = i.id;
  insert into public.admin_audit_log (actor_id, action, detail)
  values (auth.uid(), 'business_invoice_paid',
          jsonb_build_object('invoice_id', i.id, 'invoice_no', i.invoice_no, 'amount', i.amount, 'note', p_note));
end;
$$;
revoke execute on function public.admin_business_invoice_paid(uuid, text) from public, anon;
grant execute on function public.admin_business_invoice_paid(uuid, text) to authenticated;

create or replace function public.admin_business_issue_invoices()
returns integer
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_admin_can_write('rpc:admin_business_issue_invoices') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return public.business_invoices_tick();
end;
$$;
revoke execute on function public.admin_business_issue_invoices() from public, anon;
grant execute on function public.admin_business_issue_invoices() to authenticated;

-- ---- 8. Who reads and writes -------------------------------------------------------------------------------------
do $rls$
declare
  t text;
begin
  foreach t in array array['business_region_rules', 'business_accounts', 'business_members', 'business_approvals',
                           'business_invoices', 'business_trips', 'business_wallet_entries'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke insert, update, delete, truncate on public.%I from authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
    execute format('drop policy if exists %I on public.%I', t || ' admin read', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select public.caller_is_admin()))',
                   t || ' admin read', t);
  end loop;
end
$rls$;

grant insert, update, delete on public.business_region_rules to authenticated;
drop policy if exists "business_region_rules admin insert" on public.business_region_rules;
create policy "business_region_rules admin insert" on public.business_region_rules
  for insert to authenticated with check ((select public.caller_admin_can_write('business_region_rules')));
drop policy if exists "business_region_rules admin update" on public.business_region_rules;
create policy "business_region_rules admin update" on public.business_region_rules
  for update to authenticated using ((select public.caller_admin_can_write('business_region_rules')))
  with check ((select public.caller_admin_can_write('business_region_rules')));
-- The Default rule stays.
drop policy if exists "business_region_rules admin delete" on public.business_region_rules;
create policy "business_region_rules admin delete" on public.business_region_rules
  for delete to authenticated using (country <> '' and (select public.caller_admin_can_write('business_region_rules')));

-- The SSM documents: the applicant's own folder; admins read.
insert into storage.buckets (id, name, public) values ('business-documents', 'business-documents', false)
on conflict (id) do update set public = false;

drop policy if exists "business documents owner upload" on storage.objects;
create policy "business documents owner upload"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'business-documents' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists "business documents owner update" on storage.objects;
create policy "business documents owner update"
  on storage.objects for update to authenticated
  using (bucket_id = 'business-documents' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists "business documents read" on storage.objects;
create policy "business documents read"
  on storage.objects for select to authenticated
  using (bucket_id = 'business-documents'
         and ((storage.foldername(name))[1] = (select auth.uid())::text or (select public.caller_is_admin())));

-- As 0288, with the business documents (the id-read function reads an SSM
-- document the applicant uploaded).
create or replace function public.registration_file_owned(p_uid uuid, p_bucket text, p_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_uid is not null and position('..' in coalesce(p_path, '')) = 0 and case p_bucket
    when 'ID_Image' then split_part(p_path, '/', 1) = p_uid::text
    when 'business-documents' then split_part(p_path, '/', 1) = p_uid::text
    when 'provider-documents' then exists (
      select 1 from public.partners p where p.id::text = split_part(p_path, '/', 1) and p.auth_user_id = p_uid)
    when 'vehicle-documents' then split_part(p_path, '/', 2) <> 'permits' and exists (
      select 1 from public.vehicle v
       where v.id::text = split_part(p_path, '/', 1)
         and (v.auth_user_id = p_uid
           or exists (select 1 from public.partners p where p.id = v.owner_partner_id and p.auth_user_id = p_uid)))
    else false
  end;
$$;
revoke execute on function public.registration_file_owned(uuid, text, text) from public, anon, authenticated;
grant execute on function public.registration_file_owned(uuid, text, text) to service_role;

notify pgrst, 'reload schema';
