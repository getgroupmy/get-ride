-- ============================================================================
-- 0326 — Hourly hire: a driver and car by the hour, now or later.
--
-- A hire is a ride_requests row with hire columns (hire_package 'hourly'),
-- so the whole ride pipeline (dispatch, the offer card, accept, tracking,
-- chat, calls, payment, Family, commission, statements, receipts and the
-- release of a scheduled booking) carries it. Nothing here is a new trip
-- table. Daily, weekly and monthly hire come later: hire_package is the
-- one place they will be told apart.
--
-- 1. Settings (app_settings 'hourly_hire', hourly_hire_config /
--    set_hourly_hire_config, Admin › Settings › Hourly hire): on / off,
--    now and later, the least and most hours and their step, the overtime
--    step, the extension choices, whether a driver's extension waits for
--    the rider, whether the rider may end early and what an early end pays
--    ('booked' hours, the 'minimum' hours, or the hours 'used'), the
--    GET.wallet hold and its buffer, cash, the km per hour, the reminder
--    before the end, the auto-end, and the tile and switch texts.
-- 2. Rates: per Vehicle Service (settings_entries 'vehicle-services':
--    hireEnabled, hirePerHour, hireMinHours, hireKmPerHour,
--    hireOvertimePerHour, hireExtraKm) and per fare tariff card (the
--    hire_* columns of fare_tariffs, null = not set there). Each value
--    comes from the narrowest card that sets it, else the service's own,
--    as normal fares resolve (hire_rates). Without an overtime rate the
--    hourly rate is used; without an extra-km rate the service's per-km
--    fare (airport_per_km); without km per hour the settings' default.
-- 3. hire_quote: the server's price (hours × rate, at least the least
--    hours), the km included, overtime and extra-km rates and the place
--    fees (0324) at the pickup and the drop-off. The app adds the region's
--    tax and surcharge lines on top as it does for rides.
-- 4. The ride row (trg_ride_requests_c_zzhire, after 0324's airport / place
--    fee trigger, before the promo, the privacy and the Family triggers):
--    the price is the server's (a client's fare is replaced), bidding and
--    auto-accept are off, and a booking is refused with HIRE_OFF,
--    HIRE_SERVICE_OFF, HIRE_NO_RATE, HIRE_HOURS, HIRE_CASH, HIRE_NOW_OFF,
--    HIRE_LATER_OFF or HIRE_BUSINESS. option_names carries 'hire', so the
--    0253 add-on filter (pushes, the open-request policy, My Ride) offers it
--    only to drivers who take hire; ride_offers refuse a counter-offer
--    (HIRE_FIXED_FARE). The hire columns are the server's once written.
--    The trip starting stamps hire_started_at and hire_ends_at.
-- 5. Drivers: "Take hourly hire" (driver_ride_extras.takes_hire, default
--    off). A driver who doesn't take it has 'hire' among the add-ons they
--    turned off (driver_extras_off), so nothing of 0253 / 0263 changes; a
--    lock on 'extra:hire' (Driver service locks) overrides it either way.
--    A take or bid by such a driver is refused (HIRE_DRIVER_OFF). A driver
--    on a hire is busy (dispatch_driver_busy) until it ends.
-- 6. The 12-hour active-ride rule (0195 / 0251) holds a hire until
--    hire_ends_at plus the auto-end minutes instead (hire_active_until).
-- 7. Later: schedule_ride keeps hire_package and hire_hours
--    (scheduled_request_clean); a booking is priced by the server for its
--    pickup time and keeps the quote (request.hire_quote), which its
--    release charges (the price is fixed at booking, as 0324 locks place
--    fees); scheduled_partner_clash compares real spans (pickup to pickup
--    plus the hire hours) both ways, an hour apart as before. The drivers'
--    lists (scheduled_rides_open, scheduled_rides_upcoming,
--    scheduled_ride_offers_open, as 0325 left them with place_fees) add
--    hire_package and hire_hours, and list a hire only to drivers who take it.
-- 8. Extensions: hire_extend_ask(ride, minutes) by the rider (approved at
--    once: they pay it) or the driver (pending until the rider, the
--    Family host or whoever booked it answers with hire_extend_answer;
--    approved at once with extendNeedsRider off). Approved minutes move
--    hire_ends_at; overtime is billed per started step of what is used
--    past the booked hours, up to the approved minutes.
-- 9. The end: hire_end(ride, km) by the driver (or the rider where
--    riderCanEndEarly). km: the driver's, else the trip's telematics
--    (0255), else none. hire_settled: the base (the booked hours, or as
--    earlyEndPays says when ended early), overtime, extra km beyond the km
--    included; the fare becomes their sum and the ride completes as any
--    ride does (payment, commission at the rate locked at accept,
--    statements, receipt). hire_tick (every minute) tells both sides
--    before the booked time ends and ends a hire nobody ended
--    autoEndAfterMin after its time.
-- 10. The hold: a hire booked with GET.wallet (or Family) while holdInWallet
--    is on holds the quote plus holdBufferPercent at booking (a now hire)
--    or at its release (a booking for later; one released when the wallet
--    is short goes ahead unheld and is paid at the end as any ride) as a
--    wallet_transactions row with ride_id (so Family's layer moves it to
--    the host, within the member's limits, checked on
--    family_wallet_owner). It is returned when the ride is paid (ride_pay
--    then charges the settled amount), cancelled or expires (a cancel fee
--    is charged on its own, as for rides). Cash only where allowCash.
-- 11. Family: module 'hire' (family_register_module); family_ride_module
--    and scheduled_rides_family name it for hire rows.
-- 12. Statements: statement_ride_lines adds the hire lines ("Hourly hire
--    4 hr", "Overtime 30 min", "Extra km 12 km"); the commission base is
--    the fare, as for a ride.
-- ============================================================================

-- ---- 1. Columns -----------------------------------------------------------------------------------
alter table public.ride_requests add column if not exists hire_package text;
alter table public.ride_requests add column if not exists hire_hours numeric(4,1);
alter table public.ride_requests add column if not exists hire_rate numeric(10,2);
alter table public.ride_requests add column if not exists hire_km_included numeric(8,1);
alter table public.ride_requests add column if not exists hire_overtime_rate numeric(10,2);
alter table public.ride_requests add column if not exists hire_step_min integer;
alter table public.ride_requests add column if not exists hire_extra_km_rate numeric(10,2);
alter table public.ride_requests add column if not exists hire_quote jsonb;
alter table public.ride_requests add column if not exists hire_started_at timestamptz;
alter table public.ride_requests add column if not exists hire_ends_at timestamptz;
alter table public.ride_requests add column if not exists hire_extensions jsonb;
alter table public.ride_requests add column if not exists hire_km_used numeric(8,1);
alter table public.ride_requests add column if not exists hire_settled jsonb;
alter table public.ride_requests add column if not exists hire_reminded_at timestamptz;

alter table public.ride_requests drop constraint if exists ride_requests_hire_valid;
alter table public.ride_requests add constraint ride_requests_hire_valid check (
  (hire_package is null or hire_package in ('hourly'))
  and (hire_hours is null or hire_hours between 0.5 and 72)
  and (hire_rate is null or hire_rate between 0 and 100000)
  and (hire_km_included is null or hire_km_included between 0 and 100000)
  and (hire_overtime_rate is null or hire_overtime_rate between 0 and 100000)
  and (hire_step_min is null or hire_step_min between 1 and 240)
  and (hire_extra_km_rate is null or hire_extra_km_rate between 0 and 10000)
  and (hire_km_used is null or hire_km_used between 0 and 100000)
  and (hire_quote is null or (jsonb_typeof(hire_quote) = 'object' and pg_column_size(hire_quote) <= 16384))
  and (hire_extensions is null or (jsonb_typeof(hire_extensions) = 'array' and pg_column_size(hire_extensions) <= 16384))
  and (hire_settled is null or (jsonb_typeof(hire_settled) = 'object' and pg_column_size(hire_settled) <= 16384)));
comment on column public.ride_requests.hire_package is
  'Hourly hire (0326): ''hourly''; null for a normal ride. Later packages (daily, weekly) are new values.';

alter table public.scheduled_rides add column if not exists hire_package text;
alter table public.scheduled_rides add column if not exists hire_hours numeric(4,1);
alter table public.scheduled_rides drop constraint if exists scheduled_rides_hire_valid;
alter table public.scheduled_rides add constraint scheduled_rides_hire_valid check (
  (hire_package is null or hire_package in ('hourly')) and (hire_hours is null or hire_hours between 0.5 and 72));

alter table public.fare_tariffs add column if not exists hire_enabled boolean;
alter table public.fare_tariffs add column if not exists hire_per_hour numeric(10,2);
alter table public.fare_tariffs add column if not exists hire_min_hours numeric(4,1);
alter table public.fare_tariffs add column if not exists hire_km_per_hour numeric(8,1);
alter table public.fare_tariffs add column if not exists hire_overtime_per_hour numeric(10,2);
alter table public.fare_tariffs add column if not exists hire_extra_km numeric(10,2);
alter table public.fare_tariffs drop constraint if exists fare_tariffs_hire_valid;
alter table public.fare_tariffs add constraint fare_tariffs_hire_valid check (
  (hire_per_hour is null or hire_per_hour between 0 and 100000)
  and (hire_min_hours is null or hire_min_hours between 0.5 and 72)
  and (hire_km_per_hour is null or hire_km_per_hour between 0 and 1000)
  and (hire_overtime_per_hour is null or hire_overtime_per_hour between 0 and 100000)
  and (hire_extra_km is null or hire_extra_km between 0 and 10000));

alter table public.driver_ride_extras add column if not exists takes_hire boolean not null default false;
comment on column public.driver_ride_extras.takes_hire is
  'The driver''s "Take hourly hire" switch (0326); off by default.';

-- The holds on riders' GET.wallets (one per hire).
create table if not exists public.hire_holds (
  ride_id     uuid primary key references public.ride_requests(id) on delete cascade,
  rider_id    uuid not null,
  amount      numeric(12,2) not null check (amount > 0),
  status      text not null default 'held' check (status in ('held', 'returned')),
  created_at  timestamptz not null default now(),
  returned_at timestamptz,
  returned_why text
);
alter table public.hire_holds enable row level security;
revoke all on public.hire_holds from anon;
grant select on public.hire_holds to authenticated;
drop policy if exists "hire_holds read" on public.hire_holds;
create policy "hire_holds read" on public.hire_holds for select to authenticated
  using (rider_id = (select auth.uid()) or (select public.caller_is_admin()));

-- ---- 2. Settings -----------------------------------------------------------------------------------
insert into public.app_settings (key, value) values ('hourly_hire', '{}'::jsonb)
on conflict (key) do nothing;

-- A number from [v] (a number or a numeric string), else null.
create or replace function public.hire_num(v jsonb)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case when jsonb_typeof(v) = 'number' then (v #>> '{}')::numeric
              when jsonb_typeof(v) = 'string' and btrim(v #>> '{}') ~ '^[0-9]+(\.[0-9]+)?$'
              then btrim(v #>> '{}')::numeric end;
$$;

-- The settings with every key, each a sensible value (a missing or wrong
-- one takes its default).
create or replace function public.hourly_hire_normalize(v jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  b jsonb := '{}'::jsonb;
  k text;
  d boolean;
  v_min numeric;
  v_max numeric;
  v_step numeric;
  v_choices jsonb;
  v_pays text := v->>'earlyEndPays';
  v_tile text := btrim(coalesce(v->>'tileTitle', ''));
  v_trip text := btrim(coalesce(v#>>'{panelLabels,trip}', ''));
  v_hire text := btrim(coalesce(v#>>'{panelLabels,hire}', ''));
  n numeric;
begin
  v := coalesce(v, '{}'::jsonb);
  foreach k in array array['enabled', 'allowNow', 'allowLater', 'extendNeedsRider', 'riderCanEndEarly',
                           'holdInWallet', 'allowCash'] loop
    d := k not in ('enabled', 'allowCash');
    b := b || jsonb_build_object(k, case when jsonb_typeof(v->k) = 'boolean' then (v->>k)::boolean else d end);
  end loop;
  v_step := case when public.hire_num(v->'hourStep') = 0.5 then 0.5 else 1 end;
  v_min := least(24, greatest(0.5, coalesce(public.hire_num(v->'minHours'), 2)));
  v_min := ceil(v_min / v_step) * v_step;
  v_max := least(72, greatest(v_min, coalesce(public.hire_num(v->'maxHours'), 12)));
  v_max := greatest(v_min, floor(v_max / v_step) * v_step);
  select coalesce(jsonb_agg(m order by m), '[]'::jsonb) into v_choices
    from (select distinct x::int as m
            from jsonb_array_elements(case when jsonb_typeof(v->'extendChoices') = 'array'
                                           then v->'extendChoices' else '[30,60,120]'::jsonb end) e,
                 lateral (select public.hire_num(e) as x) y
           where x is not null and x between 5 and 720 and x = round(x)
           limit 6) c;
  if v_choices = '[]'::jsonb then
    v_choices := '[30,60,120]'::jsonb;
  end if;
  n := public.hire_num(v->'holdBufferPercent');
  return b || jsonb_build_object(
    'minHours', v_min,
    'maxHours', v_max,
    'hourStep', v_step,
    'stepMinutes', least(120, greatest(5, coalesce(round(public.hire_num(v->'stepMinutes')), 30)))::int,
    'extendChoices', v_choices,
    'earlyEndPays', case when v_pays in ('booked', 'minimum', 'used') then v_pays else 'booked' end,
    'holdBufferPercent', round(least(100, greatest(0, coalesce(n, 0))), 2),
    'kmPerHourDefault', round(least(500, greatest(0, coalesce(public.hire_num(v->'kmPerHourDefault'), 20))), 1),
    'reminderBeforeEndMin', least(240, greatest(0, coalesce(round(public.hire_num(v->'reminderBeforeEndMin')), 15)))::int,
    'autoEndAfterMin', least(1440, greatest(5, coalesce(round(public.hire_num(v->'autoEndAfterMin')), 30)))::int,
    'tileTitle', case when char_length(v_tile) between 1 and 40 then v_tile else 'Hire a driver' end,
    'panelLabels', jsonb_build_object(
      'trip', case when char_length(v_trip) between 1 and 30 then v_trip else 'Go somewhere' end,
      'hire', case when char_length(v_hire) between 1 and 30 then v_hire else 'Hire by time' end));
end;
$$;
revoke execute on function public.hourly_hire_normalize(jsonb) from public, anon, authenticated;

create or replace function public.hourly_hire_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.hourly_hire_normalize(coalesce((select value from public.app_settings where key = 'hourly_hire'),
                                               '{}'::jsonb));
$$;
revoke execute on function public.hourly_hire_config() from public;
grant execute on function public.hourly_hire_config() to anon, authenticated, service_role;

-- Admin › Settings › Hourly hire.
create or replace function public.set_hourly_hire_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.caller_admin_can_write('rpc:set_hourly_hire_config') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You can''t change the hourly hire settings.';
  end if;
  if jsonb_typeof(p_config) is distinct from 'object' then
    raise exception 'HIRE_CONFIG_INVALID' using errcode = '22023';
  end if;
  v := public.hourly_hire_normalize(p_config);
  insert into public.app_settings (key, value, updated_at) values ('hourly_hire', v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return v;
end;
$$;
revoke execute on function public.set_hourly_hire_config(jsonb) from public, anon;
grant execute on function public.set_hourly_hire_config(jsonb) to authenticated;

insert into public.admin_table_pages (target, page) values
  ('rpc:set_hourly_hire_config', 'admin-settings-site')
on conflict do nothing;

-- ---- 2b. Rates ------------------------------------------------------------------------------------
-- A service's hire rates where the pickup is: each value from the
-- narrowest tariff card that sets it (as airport_per_km picks cards), else
-- the Vehicle Service's own, else the default.
create or replace function public.hire_rates(p_service text, p_country text, p_state text, p_city text,
                                             p_suburb text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.hourly_hire_config();
  v jsonb;
  v_sid text;
  eq text := '';
  c record;
  v_on boolean;
  v_rate numeric;
  v_min numeric;
  v_kmh numeric;
  v_ot numeric;
  v_xkm numeric;
begin
  select e.id::text, e.values into v_sid, v
    from public.settings_entries e
   where e.category = 'vehicle-services'
     and lower(btrim(e.values->>'name')) = lower(btrim(coalesce(p_service, '')))
   order by e.position
   limit 1;
  if v_sid is null then
    return jsonb_build_object('enabled', false, 'service', false);
  end if;
  for c in
    select f.*
      from public.fare_tariffs f
     where f.active and f.service_type is null
       and (f.vehicle_service is null or f.vehicle_service = v_sid)
       and (f.level = 'master'
            or (f.level = 'country' and lower(f.country) = lower(coalesce(p_country, eq)))
            or (f.level = 'state' and lower(f.country) = lower(coalesce(p_country, eq))
                and lower(f.state) = lower(coalesce(p_state, eq)))
            or (f.level = 'city' and lower(f.country) = lower(coalesce(p_country, eq))
                and lower(f.state) = lower(coalesce(p_state, eq)) and lower(f.city) = lower(coalesce(p_city, eq)))
            or (f.level = 'suburb' and lower(f.country) = lower(coalesce(p_country, eq))
                and lower(f.state) = lower(coalesce(p_state, eq)) and lower(f.city) = lower(coalesce(p_city, eq))
                and lower(f.suburb) = lower(coalesce(p_suburb, eq))))
     order by case f.level when 'suburb' then 0 when 'city' then 1 when 'state' then 2 when 'country' then 3 else 4 end,
              (f.vehicle_service is null)
  loop
    v_on := coalesce(v_on, c.hire_enabled);
    v_rate := coalesce(v_rate, c.hire_per_hour);
    v_min := coalesce(v_min, c.hire_min_hours);
    v_kmh := coalesce(v_kmh, c.hire_km_per_hour);
    v_ot := coalesce(v_ot, c.hire_overtime_per_hour);
    v_xkm := coalesce(v_xkm, c.hire_extra_km);
  end loop;
  v_on := coalesce(v_on, case when jsonb_typeof(v->'hireEnabled') = 'boolean' then (v->>'hireEnabled')::boolean end,
                   false);
  v_rate := coalesce(v_rate, public.hire_num(v->'hirePerHour'));
  v_min := coalesce(v_min, public.hire_num(v->'hireMinHours'), (cfg->>'minHours')::numeric);
  v_kmh := coalesce(v_kmh, public.hire_num(v->'hireKmPerHour'), (cfg->>'kmPerHourDefault')::numeric);
  v_ot := coalesce(v_ot, public.hire_num(v->'hireOvertimePerHour'), v_rate);
  v_xkm := coalesce(v_xkm, public.hire_num(v->'hireExtraKm'),
                    public.airport_per_km(p_service, p_country, p_state, p_city, p_suburb));
  return jsonb_build_object(
    'enabled', v_on,
    'service', true,
    'perHour', case when v_rate > 0 then round(v_rate, 2) end,
    -- The service's least hours, within the settings' range.
    'minHours', least((cfg->>'maxHours')::numeric, greatest(0.5, v_min)),
    'kmPerHour', round(greatest(0, v_kmh), 1),
    'overtimePerHour', round(greatest(0, coalesce(v_ot, 0)), 2),
    'extraKm', round(greatest(0, coalesce(v_xkm, 0)), 2));
end;
$$;
revoke execute on function public.hire_rates(text, text, text, text, text) from public, anon, authenticated;

-- 'cash', 'wallet' (GET.wallet, Family) or 'other' (a business account,
-- a card): how a booking's payment_mode pays.
create or replace function public.hire_pay_kind(p_mode text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when lower(coalesce(p_mode, '')) like 'business%' then 'other'
              when lower(coalesce(p_mode, 'cash')) like '%cash%' or btrim(coalesce(p_mode, '')) = '' then 'cash'
              when lower(p_mode) ~ '(wallet|get ?pay|ewallet|family)' then 'wallet'
              else 'other' end;
$$;

-- What a refusal reason says to the rider.
create or replace function public.hire_hint(p_reason text, q jsonb default null)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_reason
    when 'HIRE_OFF' then 'Hiring a driver by the hour is not available.'
    when 'HIRE_SERVICE_OFF' then 'This vehicle can''t be hired by the hour here. Choose another.'
    when 'HIRE_NO_RATE' then 'This vehicle has no hourly price here yet. Choose another.'
    when 'HIRE_HOURS' then format('Choose between %s and %s hours.', q->>'minHours', q->>'maxHours')
    when 'HIRE_CASH' then 'Hourly hire is paid in the app. Choose GET.wallet.'
    when 'HIRE_NOW_OFF' then 'Hourly hire can only be booked for later.'
    when 'HIRE_LATER_OFF' then 'Hourly hire can''t be booked for later.'
    when 'HIRE_BUSINESS' then 'Hourly hire can''t be charged to a business account yet.'
    else 'Hourly hire is not available.' end;
$$;

-- ---- 3. The quote ----------------------------------------------------------------------------------
-- The server's price for [p_hours] of [p_service] from the pickup, with
-- the place fees at the pickup and the drop-off (optional) at [p_at]
-- (null: now). {available, reason, hint, hours, minHours, maxHours,
-- hourStep, rate, kmPerHour, kmIncluded, overtimePerHour, stepMinutes,
-- extraKm, base, placeFees, placeFeesTotal, total, hold, ...}.
create or replace function public.hire_quote(
  p_pickup_lat float8, p_pickup_lng float8, p_drop_lat float8, p_drop_lng float8,
  p_service text, p_hours numeric, p_at timestamptz default null,
  p_country text default null, p_state text default null, p_city text default null, p_suburb text default null,
  p_payment text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.hourly_hire_config();
  r jsonb;
  v_reason text;
  v_min numeric;
  v_max numeric := (cfg->>'maxHours')::numeric;
  v_step numeric := (cfg->>'hourStep')::numeric;
  v_hours numeric;
  v_base numeric := 0;
  v_fees jsonb := '[]'::jsonb;
  v_fees_total numeric := 0;
  v_total numeric;
  q jsonb;
begin
  r := public.hire_rates(p_service, p_country, p_state, p_city, p_suburb);
  v_min := coalesce((r->>'minHours')::numeric, (cfg->>'minHours')::numeric);
  v_min := least(v_max, ceil(v_min / v_step) * v_step);
  v_hours := coalesce(p_hours, v_min);
  if not (cfg->>'enabled')::boolean then
    v_reason := 'HIRE_OFF';
  elsif not coalesce((r->>'enabled')::boolean, false) then
    v_reason := 'HIRE_SERVICE_OFF';
  elsif r->>'perHour' is null then
    v_reason := 'HIRE_NO_RATE';
  elsif v_hours < v_min or v_hours > v_max or v_hours <> round(v_hours / v_step) * v_step then
    v_reason := 'HIRE_HOURS';
  elsif p_payment is not null and public.hire_pay_kind(p_payment) = 'cash' and not (cfg->>'allowCash')::boolean then
    v_reason := 'HIRE_CASH';
  end if;
  -- Priced on the hours asked for, kept within the range.
  v_hours := least(v_max, greatest(v_min, round(v_hours / v_step) * v_step));
  if r->>'perHour' is not null then
    v_base := round(v_hours * (r->>'perHour')::numeric, 2);
    v_fees := public.place_ride_charges(public.airport_at(p_pickup_lat, p_pickup_lng),
                                        public.airport_at(p_drop_lat, p_drop_lng), null, p_service, v_base,
                                        coalesce(p_at, now()));
    v_fees_total := coalesce((select round(sum((l->>'value')::numeric), 2) from jsonb_array_elements(v_fees) l), 0);
  end if;
  v_total := round(v_base + v_fees_total, 2);
  q := jsonb_build_object(
    'available', v_reason is null,
    'reason', v_reason,
    'package', 'hourly',
    'service', p_service,
    'hours', v_hours,
    'minHours', v_min,
    'maxHours', v_max,
    'hourStep', v_step,
    'rate', (r->>'perHour')::numeric,
    'kmPerHour', coalesce((r->>'kmPerHour')::numeric, 0),
    'kmIncluded', round(v_hours * coalesce((r->>'kmPerHour')::numeric, 0), 1),
    'overtimePerHour', coalesce((r->>'overtimePerHour')::numeric, 0),
    'stepMinutes', (cfg->>'stepMinutes')::int,
    'extraKm', coalesce((r->>'extraKm')::numeric, 0),
    'base', v_base,
    'placeFees', v_fees,
    'placeFeesTotal', v_fees_total,
    'total', v_total,
    'holdInWallet', (cfg->>'holdInWallet')::boolean,
    'hold', round(v_total * (1 + (cfg->>'holdBufferPercent')::numeric / 100), 2),
    'allowCash', (cfg->>'allowCash')::boolean,
    'at', coalesce(p_at, now()));
  if v_reason is not null then
    q := q || jsonb_build_object('hint', public.hire_hint(v_reason, q));
  end if;
  return q;
end;
$$;
revoke execute on function public.hire_quote(float8, float8, float8, float8, text, numeric, timestamptz, text, text, text, text, text)
  from public, anon;
grant execute on function public.hire_quote(float8, float8, float8, float8, text, numeric, timestamptz, text, text, text, text, text)
  to authenticated, service_role;

create or replace function public.hire_raise(q jsonb)
returns void
language plpgsql
immutable
set search_path = public
as $$
begin
  raise exception '%', coalesce(q->>'reason', 'HIRE_OFF') using errcode = '22023',
    hint = coalesce(q->>'hint', public.hire_hint(q->>'reason', q));
end;
$$;
revoke execute on function public.hire_raise(jsonb) from public, anon;
-- The ride trigger runs as the app's role: it raises through this.
grant execute on function public.hire_raise(jsonb) to authenticated;

-- Until when a hire on the go counts as active: its end plus the auto-end
-- minutes (before it starts, its pickup plus its hours).
create or replace function public.hire_active_until(r public.ride_requests)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$
  select case when r.hire_package is null then null
              else coalesce(r.hire_ends_at,
                            greatest(r.updated_at, r.created_at) + make_interval(mins => (coalesce(r.hire_hours, 0) * 60)::int))
                   + make_interval(mins => (public.hourly_hire_config()->>'autoEndAfterMin')::int) end;
$$;
revoke execute on function public.hire_active_until(public.ride_requests) from public, anon;
-- The one-ride guard runs as the app's role.
grant execute on function public.hire_active_until(public.ride_requests) to authenticated;

-- The approved extension minutes of a hire.
create or replace function public.hire_extension_minutes(p jsonb)
returns integer
language sql
immutable
set search_path = ''
as $$
  select coalesce(sum((e->>'minutes')::int), 0)::int
    from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) e
   where e->>'status' = 'approved';
$$;

-- What [p_minutes] of overtime cost: rounded up to whole steps.
create or replace function public.hire_overtime_amount(p_minutes numeric, p_step integer, p_rate numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select round(ceil(greatest(0, coalesce(p_minutes, 0)) / greatest(1, coalesce(p_step, 30)))
               * greatest(1, coalesce(p_step, 30)) / 60.0 * greatest(0, coalesce(p_rate, 0)), 2);
$$;

-- ---- 4. The ride row ---------------------------------------------------------------------------------
-- Not security definer: current_user tells the app (anon / authenticated)
-- from the server's own functions, as the other ride guards do.
create or replace function public.ride_requests_hire()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_client boolean := current_user in ('anon', 'authenticated') and not public.caller_admin_can_write('ride_requests');
  cfg jsonb;
  q jsonb;
  v_rest jsonb;
  v_fees jsonb;
begin
  if tg_op = 'INSERT' then
    if new.hire_package is null then
      -- A normal ride carries no hire value, and can't ask for hire drivers.
      new.hire_hours := null; new.hire_rate := null; new.hire_km_included := null; new.hire_overtime_rate := null;
      new.hire_step_min := null; new.hire_extra_km_rate := null; new.hire_quote := null;
      new.hire_started_at := null; new.hire_ends_at := null; new.hire_extensions := null;
      new.hire_km_used := null; new.hire_settled := null; new.hire_reminded_at := null;
      if jsonb_typeof(new.option_names) = 'object' and new.option_names ? 'hire' then
        new.option_names := nullif(new.option_names - 'hire', '{}'::jsonb);
      end if;
      return new;
    end if;
    cfg := public.hourly_hire_config();
    if new.business_account_id is not null then
      perform public.hire_raise(jsonb_build_object('reason', 'HIRE_BUSINESS'));
    end if;
    -- A released booking keeps the quote it was booked at.
    if new.scheduled_ride_id is not null then
      select s.request->'hire_quote' into q
        from public.scheduled_rides s
       where s.id = new.scheduled_ride_id and s.rider_id = new.rider_id and s.hire_package is not null
         and jsonb_typeof(s.request->'hire_quote') = 'object';
    end if;
    if q is null then
      if v_client and not (cfg->>'allowNow')::boolean then
        perform public.hire_raise(jsonb_build_object('reason', 'HIRE_NOW_OFF'));
      end if;
      q := public.hire_quote(new.pickup_lat, new.pickup_lng, new.drop_lat, new.drop_lng, new.service,
                             new.hire_hours, now(), new.country, new.state, new.city, new.suburb, new.payment_mode);
      if not (q->>'available')::boolean then
        perform public.hire_raise(q);
      end if;
      -- The place fees on the hire's price (0324 worked them out on the
      -- app's fare): a client's are dropped, the quote's stamped.
      select coalesce(jsonb_agg(e), '[]'::jsonb) into v_rest
        from jsonb_array_elements(case when jsonb_typeof(new.charges) = 'array' then new.charges else '[]'::jsonb end) e
       where jsonb_typeof(e) = 'object' and e->'airport' is null;
      v_fees := public.place_fees_fit(v_rest, coalesce(q->'placeFees', '[]'::jsonb));
      v_rest := v_rest || v_fees;
      new.charges := case when v_rest = '[]'::jsonb then null else v_rest end;
    elsif public.hire_pay_kind(new.payment_mode) = 'cash' and not (cfg->>'allowCash')::boolean then
      -- A booking for later paid in cash while the admin has since turned cash off: still booked as it was.
      null;
    end if;
    new.hire_package := 'hourly';
    new.hire_quote := q - 'available' - 'reason' - 'hint';
    new.hire_hours := (q->>'hours')::numeric;
    new.hire_rate := (q->>'rate')::numeric;
    new.hire_km_included := (q->>'kmIncluded')::numeric;
    new.hire_overtime_rate := (q->>'overtimePerHour')::numeric;
    new.hire_step_min := (q->>'stepMinutes')::int;
    new.hire_extra_km_rate := (q->>'extraKm')::numeric;
    new.hire_started_at := null;
    new.hire_ends_at := null;
    new.hire_extensions := '[]'::jsonb;
    new.hire_km_used := null;
    new.hire_settled := null;
    new.hire_reminded_at := null;
    -- The price is the server's, fixed: no offers, no auto-accept, no airport fare.
    new.fare := (q->>'base')::numeric;
    new.ride_fare := new.fare;
    new.airport_fare := null;
    new.offer_me := false;
    new.auto_accept_fare := null;
    new.offered_fare := null;
    new.distance_km := coalesce(new.distance_km, 0);
    -- Offered only to drivers who take hire (0253's add-on filter).
    new.option_names := coalesce(case when jsonb_typeof(new.option_names) = 'object' then new.option_names end,
                                 '{}'::jsonb) || jsonb_build_object('hire', 'Hourly hire');
    return new;
  end if;

  -- UPDATE
  if old.hire_package is null then
    if new.hire_package is not null then
      new.hire_package := null;
    end if;
    return new;
  end if;
  if v_client then
    -- The hire's terms are the server's once written.
    new.hire_package := old.hire_package; new.hire_hours := old.hire_hours; new.hire_rate := old.hire_rate;
    new.hire_km_included := old.hire_km_included; new.hire_overtime_rate := old.hire_overtime_rate;
    new.hire_step_min := old.hire_step_min; new.hire_extra_km_rate := old.hire_extra_km_rate;
    new.hire_quote := old.hire_quote; new.hire_started_at := old.hire_started_at;
    new.hire_ends_at := old.hire_ends_at; new.hire_extensions := old.hire_extensions;
    new.hire_km_used := old.hire_km_used; new.hire_settled := old.hire_settled;
    new.hire_reminded_at := old.hire_reminded_at;
    if (new.fare, new.ride_fare) is distinct from (old.fare, old.ride_fare)
       or (new.offered_fare is not null and round(new.offered_fare, 2) <> round(coalesce(old.fare, 0), 2))
       or new.auto_accept_fare is not null then
      raise exception 'HIRE_FIXED_FARE' using errcode = '42501', hint = 'Hourly hire is at a fixed price.';
    end if;
    if old.status = 'open' and new.partner_id is not null and new.partner_id is distinct from old.partner_id
       and not public.driver_takes_hire(new.partner_id) then
      raise exception 'HIRE_DRIVER_OFF' using errcode = '42501',
        hint = 'Turn on "Take hourly hire" in your preferences to take hourly hires.';
    end if;
    if new.status = 'completed' and old.status is distinct from 'completed' then
      raise exception 'HIRE_END_USE' using errcode = '42501', hint = 'Use End hire to finish an hourly hire.';
    end if;
  end if;
  -- The clock starts with the trip.
  if new.status = 'on_trip' and old.status is distinct from 'on_trip' and new.hire_started_at is null then
    new.hire_started_at := now();
    new.hire_ends_at := now() + make_interval(mins => (new.hire_hours * 60)::int
                                                      + public.hire_extension_minutes(new.hire_extensions));
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_hire() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_c_zzhire on public.ride_requests;
create trigger trg_ride_requests_c_zzhire
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_hire();

-- No counter-offer on a hire.
create or replace function public.ride_offers_hire()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.ride_requests r where r.id = new.request_id and r.hire_package is not null) then
    raise exception 'HIRE_FIXED_FARE' using errcode = '42501', hint = 'Hourly hire is at a fixed price.';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_offers_hire() from public, anon, authenticated;
drop trigger if exists trg_ride_offers_hire on public.ride_offers;
create trigger trg_ride_offers_hire before insert on public.ride_offers
  for each row execute function public.ride_offers_hire();

-- ---- 5. Drivers who take hire -----------------------------------------------------------------------
-- 0253's ride_extra_keys, plus 'hire' for a hire (its option_names).
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
    select 'hire' where jsonb_typeof(p_names) = 'object' and p_names ? 'hire'
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
  ) x;
$$;

-- 0263's driver_extras_off, with 'hire' off unless the driver takes it.
create or replace function public.driver_extras_off(p_driver uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_own text[] := coalesce((select x.off from public.driver_ride_extras x where x.driver_id = p_driver), '{}');
  v_vehicle uuid;
  v_on text[] := '{}';
  v_off text[] := '{}';
  l public.driver_service_locks;
  k text;
begin
  if not coalesce((select x.takes_hire from public.driver_ride_extras x where x.driver_id = p_driver), false) then
    v_own := v_own || 'hire'::text;
  end if;
  if p_driver is not null and exists (select 1 from public.driver_service_locks x
                                       where x.service_key like 'extra:%' and (x.until is null or x.until > now())) then
    v_vehicle := public.driver_session_vehicle(p_driver);
    for k in select distinct x.service_key from public.driver_service_locks x
              where x.service_key like 'extra:%' and (x.until is null or x.until > now()) loop
      l := public.driver_service_lock(p_driver, v_vehicle, k);
      continue when l.id is null;
      if l.mode = 'on' then
        v_on := v_on || substr(k, 7);
      else
        v_off := v_off || substr(k, 7);
      end if;
    end loop;
  end if;
  return coalesce((select array_agg(distinct x order by x)
                     from unnest(v_own || v_off) x
                    where not (x = any (v_on))), '{}');
end;
$$;

create or replace function public.driver_takes_hire(p_driver uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_driver is not null and not ('hire' = any (public.driver_extras_off(p_driver)));
$$;
revoke execute on function public.driver_takes_hire(uuid) from public, anon;
-- The ride trigger runs as the app's role and checks the driver taking it.
grant execute on function public.driver_takes_hire(uuid) to authenticated;

-- The driver's own switch, read back by the app.
create or replace function public.my_takes_hire()
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select public.driver_takes_hire(auth.uid()); $$;
revoke execute on function public.my_takes_hire() from public, anon;
grant execute on function public.my_takes_hire() to authenticated;

-- 0253's count of open requests a driver's add-ons hide: a hire a driver
-- doesn't take isn't one of them (it isn't an add-on they turned off).
create or replace function public.ride_extras_hidden_count(p_since timestamptz)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_off text[] := array_remove(public.caller_extras_off(), 'hire');
begin
  if auth.uid() is null or cardinality(v_off) = 0 or not public.caller_is_approved_partner() then
    return 0;
  end if;
  return (
    select count(*)::integer from public.ride_requests r
     where r.status = 'open'
       and r.created_at >= greatest(coalesce(p_since, now()), now() - interval '1 day')
       and r.rider_id is distinct from auth.uid()
       and not public.rider_blocks_driver(r.rider_id, auth.uid())
       and r.stand_id is null and not coalesce(r.airport_hold, false) and r.direct_driver_id is null
       and (r.targeted_until is null or r.targeted_until <= now()
            or coalesce(cardinality(r.target_driver_ids), 0) = 0)
       and public.service_order_driver_allows(auth.uid(), r.service)
       and v_off && public.ride_extra_keys(r.pets, r.assistance, r.option_names, r.passengers));
end;
$$;

-- 0251's dispatch_driver_busy: a driver on a hire is busy until it ends.
create or replace function public.dispatch_driver_busy(p_driver uuid, p_except uuid default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.ride_requests r
                  where r.partner_id = p_driver and r.status in ('accepted', 'arrived', 'on_trip')
                    and r.id is distinct from p_except
                    and (r.updated_at > now() - interval '12 hours'
                         or (r.hire_package is not null and public.hire_active_until(r) > now())));
$$;

-- ---- 6. One ride on the go: a hire lasts its hours ---------------------------------------------------
create or replace function public.ride_requests_one_active_request()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  phone text := nullif(regexp_replace(coalesce(new.booked_for_phone,
    (select p.booked_for_phone from public.ride_request_private p where p.request_id = new.id), ''), '\D', '', 'g'), '');
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  if new.rider_id is null or new.status is distinct from 'open' then
    return new;
  end if;
  -- Two taps land as two transactions: the second waits for the first.
  perform pg_advisory_xact_lock(hashtextextended('ride_request:' || new.rider_id::text, 0));
  if exists (
    select 1
      from public.ride_requests r
      left join public.ride_request_private p on p.request_id = r.id
     where r.rider_id = new.rider_id
       and r.id is distinct from new.id
       and (
         (r.status = 'open' and r.created_at > now() - interval '7 minutes')
         or (r.status in ('accepted', 'arrived', 'on_trip')
             and (r.updated_at > now() - interval '12 hours'
                  -- 0326: a hire until its end (and the auto-end after it).
                  or (r.hire_package is not null and public.hire_active_until(r) > now())))
       )
       and (
         (phone is null and coalesce(r.booked_for_phone, p.booked_for_phone) is null)
         or (phone is not null
             and regexp_replace(coalesce(r.booked_for_phone, p.booked_for_phone, ''), '\D', '', 'g') = phone)
       )
  ) then
    raise exception 'RIDE_REQUEST_DUPLICATE' using errcode = 'P0001',
      hint = case when phone is null
        then 'You already have a ride request on the go.'
        else 'You already have a ride on the go for this passenger.' end;
  end if;
  return new;
end;
$$;

-- ---- 7. Booked for later -------------------------------------------------------------------------------
-- As 0317, plus the hire keys a booking keeps (the server prices it).
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
       'business_account_id', 'business_note', 'business_approval_id',
       -- 0317: who it is for in the family.
       'family',
       -- 0326: an hourly hire and its hours (the quote is the server's).
       'hire_package', 'hire_hours'])
       and (e.key <> 'charges' or jsonb_typeof(e.value) = 'array')
  ), '{}'::jsonb);
$$;
revoke execute on function public.scheduled_request_clean(jsonb, numeric) from public, anon, authenticated;

-- A booking for later: priced by the server for its pickup time, and the
-- quote kept for its release. Runs first among the booking's triggers, so
-- the business, promo, place fee and Family checks see the hire's price.
create or replace function public.scheduled_rides_hire()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  q jsonb := coalesce(new.request, '{}'::jsonb);
  cfg jsonb;
  sc jsonb;
  quote jsonb;
  v_fee numeric;
  v_charges jsonb;
begin
  if coalesce(q->>'hire_package', '') = '' then
    new.request := q - 'hire_package' - 'hire_hours' - 'hire_quote';
    new.hire_package := null;
    new.hire_hours := null;
    if jsonb_typeof(q->'option_names') = 'object' and q->'option_names' ? 'hire' then
      new.request := jsonb_set(new.request, '{option_names}', (q->'option_names') - 'hire');
    end if;
    return new;
  end if;
  cfg := public.hourly_hire_config();
  if q->>'hire_package' <> 'hourly' then
    perform public.hire_raise(jsonb_build_object('reason', 'HIRE_OFF'));
  end if;
  if (cfg->>'enabled')::boolean and not (cfg->>'allowLater')::boolean then
    perform public.hire_raise(jsonb_build_object('reason', 'HIRE_LATER_OFF'));
  end if;
  if coalesce(q->>'business_account_id', '') <> '' then
    perform public.hire_raise(jsonb_build_object('reason', 'HIRE_BUSINESS'));
  end if;
  quote := public.hire_quote(new.pickup_lat, new.pickup_lng, new.drop_lat, new.drop_lng,
                             coalesce(new.service, q->>'service'), public.hire_num(q->'hire_hours'), new.pickup_at,
                             q->>'country', q->>'state', q->>'city', q->>'suburb', q->>'payment_mode');
  if not (quote->>'available')::boolean then
    perform public.hire_raise(quote);
  end if;
  new.hire_package := 'hourly';
  new.hire_hours := (quote->>'hours')::numeric;
  new.fare := (quote->>'base')::numeric;
  -- The scheduling fee on the hire's price.
  sc := public.scheduled_rides_config();
  v_fee := round((sc->>'feeFixed')::numeric + new.fare * (sc->>'feePercent')::numeric / 100, 2);
  select coalesce(jsonb_agg(c), '[]'::jsonb) into v_charges
    from jsonb_array_elements(case when jsonb_typeof(q->'charges') = 'array' then q->'charges' else '[]'::jsonb end) c
   where not (c->>'name' = 'Scheduling fee' and c->>'kind' = 'surcharge');
  if v_fee > 0 then
    v_charges := v_charges || jsonb_build_array(jsonb_build_object(
      'kind', 'surcharge', 'name', 'Scheduling fee', 'charge', 'fixed', 'value', v_fee,
      'platform', (sc->>'feeTo') = 'platform'));
  end if;
  new.scheduling_fee := greatest(v_fee, 0);
  new.request := (q - 'auto_accept_fare') || jsonb_build_object(
    'fare', new.fare, 'ride_fare', new.fare, 'offer_me', false,
    'hire_package', 'hourly', 'hire_hours', new.hire_hours,
    'hire_quote', quote - 'available' - 'reason' - 'hint',
    'charges', v_charges,
    'option_names', coalesce(case when jsonb_typeof(q->'option_names') = 'object' then q->'option_names' end,
                             '{}'::jsonb) || jsonb_build_object('hire', 'Hourly hire'));
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_hire() from public, anon, authenticated;
drop trigger if exists trg_scheduled_rides_0_hire on public.scheduled_rides;
create trigger trg_scheduled_rides_0_hire
  before insert on public.scheduled_rides
  for each row execute function public.scheduled_rides_hire();

-- When a booking's trip ends: a hire's pickup plus its hours.
create or replace function public.scheduled_span_end(s public.scheduled_rides)
returns timestamptz
language sql
immutable
set search_path = ''
as $$
  select s.pickup_at + make_interval(mins => (coalesce(s.hire_hours, 0) * 60)::int);
$$;

-- 0198's clash, with real spans: two bookings clash when they are less than
-- an hour apart, a hire counting from its pickup to the end of its hours.
create or replace function public.scheduled_partner_clash(p_partner uuid, p_at timestamptz, p_except uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with t as (
    select coalesce((select s.pickup_at from public.scheduled_rides s where s.id = p_except), p_at) as a1,
           coalesce((select public.scheduled_span_end(s) from public.scheduled_rides s where s.id = p_except), p_at) as a2)
  select exists (select 1 from public.scheduled_rides o, t
                  where o.partner_id = p_partner and o.id <> p_except and o.status in ('assigned', 'released')
                    and o.pickup_at < t.a2 + interval '1 hour'
                    and t.a1 < public.scheduled_span_end(o) + interval '1 hour');
$$;
revoke execute on function public.scheduled_partner_clash(uuid, timestamptz, uuid) from public, anon, authenticated;

-- The drivers' booking lists, each 0325's definition (with place_fees), plus a
-- hire's package and hours last; a hire only for drivers who take hire. (A
-- transfer offer of a hire is refused at accept: scheduled_rides_hire_driver.)
drop function if exists public.scheduled_rides_open();
create or replace function public.scheduled_rides_open()
returns table(id uuid, pickup_at timestamptz, service text, pickup_address text, drop_address text,
              pickup_lat double precision, pickup_lng double precision, drop_lat double precision,
              drop_lng double precision, distance_km numeric, fare numeric, scheduling_fee numeric, currency text,
              place_fees jsonb, hire_package text, hire_hours numeric)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.pickup_at, s.service, s.pickup_address, s.drop_address,
         s.pickup_lat, s.pickup_lng, s.drop_lat, s.drop_lng, s.distance_km, s.fare,
         case when public.scheduled_rides_config()->>'feeTo' = 'driver' then s.scheduling_fee else 0 end,
         s.currency,
         public.place_fee_lines(s),
         s.hire_package, s.hire_hours
    from public.scheduled_rides s
   where s.status = 'scheduled' and s.partner_id is null and s.pickup_at > now()
     and s.stand_id is null
     and public.caller_is_approved_partner()
     and public.scheduled_rides_config()->>'mode' = 'advance'
     and s.rider_id <> auth.uid()
     and not public.rider_blocks_driver(s.rider_id, auth.uid())
     and public.service_order_driver_allows(auth.uid(), s.service)
     and public.driver_permit_problem(auth.uid()) is null
     and public.driver_takes_service(auth.uid(), s.service)
     and public.driver_takes_freight(auth.uid(), s.service)
     and public.driver_takes_extras(auth.uid(), public.ride_extra_keys(
           s.request->'pets', s.request->'assistance', s.request->'option_names',
           case when jsonb_typeof(s.request->'passengers') = 'number'
                then floor((s.request->>'passengers')::numeric)::integer end))
     -- 0326: a hire only for drivers who take hire (also its 'hire' add-on above).
     and (s.hire_package is null or public.driver_takes_hire(auth.uid()))
   order by s.pickup_at
   limit 100;
$$;
revoke execute on function public.scheduled_rides_open() from public, anon;
grant execute on function public.scheduled_rides_open() to authenticated, service_role;

drop function if exists public.scheduled_rides_upcoming();
create or replace function public.scheduled_rides_upcoming()
returns table(id uuid, pickup_at timestamptz, service text, pickup_address text, drop_address text,
              pickup_lat double precision, pickup_lng double precision, drop_lat double precision,
              drop_lng double precision, distance_km numeric, fare numeric, scheduling_fee numeric, currency text,
              interested boolean, can_accept boolean, accept_from timestamptz, place_fees jsonb,
              hire_package text, hire_hours numeric)
language sql
stable
security definer
set search_path = public
as $$
  with c as (select public.scheduled_rides_config() as v)
  select s.id, s.pickup_at, s.service, s.pickup_address, s.drop_address,
         s.pickup_lat, s.pickup_lng, s.drop_lat, s.drop_lng, s.distance_km, s.fare,
         case when c.v->>'feeTo' = 'driver' then s.scheduling_fee else 0 end,
         s.currency,
         i.partner_id is not null,
         c.v->>'mode' = 'advance'
           or (i.partner_id is not null and (c.v->>'interestNoticeMinutes')::int > 0
               and now() >= s.pickup_at - make_interval(mins => (c.v->>'interestNoticeMinutes')::int)),
         case when c.v->>'mode' = 'advance' then null
              when (c.v->>'interestNoticeMinutes')::int > 0
              then s.pickup_at - make_interval(mins => (c.v->>'interestNoticeMinutes')::int) end,
         public.place_fee_lines(s),
         s.hire_package, s.hire_hours
    from public.scheduled_rides s
    cross join c
    left join public.scheduled_ride_interests i on i.scheduled_ride_id = s.id and i.partner_id = auth.uid()
   where s.status = 'scheduled' and s.partner_id is null and s.pickup_at > now()
     and s.stand_id is null
     and (c.v->>'enabled')::boolean
     and public.caller_is_approved_partner()
     and s.rider_id <> auth.uid()
     and not public.rider_blocks_driver(s.rider_id, auth.uid())
     -- 0326: a hire only for drivers who take hire.
     and (s.hire_package is null or public.driver_takes_hire(auth.uid()))
   order by s.pickup_at;
$$;
revoke execute on function public.scheduled_rides_upcoming() from public, anon;
grant execute on function public.scheduled_rides_upcoming() to authenticated, service_role;

drop function if exists public.scheduled_ride_offers_open();
create or replace function public.scheduled_ride_offers_open()
returns table (
  id uuid, scheduled_ride_id uuid, kind text, incoming boolean, other_name text, expires_at timestamptz,
  pickup_at timestamptz, service text, pickup_address text, drop_address text, distance_km numeric,
  fare numeric, scheduling_fee numeric, currency text, place_fees jsonb,
  hire_package text, hire_hours numeric)
language sql
stable
security definer
set search_path = public
as $$
  select o.id, o.scheduled_ride_id, o.kind, o.to_partner_id = auth.uid(),
         case when o.to_partner_id = auth.uid()
              then case when o.kind = 'transfer' then (public.my_ride_partner_of(o.from_id)).name end
              else (public.my_ride_partner_of(o.to_partner_id)).name end,
         o.expires_at, s.pickup_at, s.service, s.pickup_address, s.drop_address, s.distance_km, s.fare,
         -- Drivers see the fee only when it goes to them, as on the open list.
         case when o.kind = 'transfer' or o.to_partner_id = auth.uid()
              then case when public.scheduled_rides_config()->>'feeTo' = 'driver' then s.scheduling_fee else 0 end
              else s.scheduling_fee end,
         s.currency,
         public.place_fee_lines(s),
         s.hire_package, s.hire_hours
    from public.scheduled_ride_offers o
    join public.scheduled_rides s on s.id = o.scheduled_ride_id
   where o.status = 'pending' and o.expires_at > now()
     and (o.to_partner_id = auth.uid() or o.from_id = auth.uid())
   order by s.pickup_at;
$$;
revoke execute on function public.scheduled_ride_offers_open() from public, anon;
grant execute on function public.scheduled_ride_offers_open() to authenticated, service_role;

-- A booked hire is taken only by a driver who takes hire.
create or replace function public.scheduled_rides_hire_driver()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.hire_package is not null and new.partner_id is not null
     and new.partner_id is distinct from old.partner_id and not public.driver_takes_hire(new.partner_id) then
    raise exception 'HIRE_DRIVER_OFF' using errcode = '42501',
      hint = 'Turn on "Take hourly hire" in your preferences to take hourly hires.';
  end if;
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_hire_driver() from public, anon, authenticated;
drop trigger if exists trg_scheduled_rides_hire_driver on public.scheduled_rides;
create trigger trg_scheduled_rides_hire_driver
  before update of partner_id on public.scheduled_rides
  for each row execute function public.scheduled_rides_hire_driver();

-- ---- 8. Family: the 'hire' module ---------------------------------------------------------------------
select public.family_register_module('hire', 'Hourly hire');

create or replace function public.family_ride_module(r public.ride_requests)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  -- 0326: an hourly hire, now or released from a booking.
  if r.hire_package is not null then
    return 'hire';
  end if;
  if r.parcel_size is not null or coalesce(public.vehicle_service_is_courier(r.service), false) then
    return 'courier';
  end if;
  if public.ride_request_is_freight(r) then
    return 'freight';
  end if;
  if r.scheduled_ride_id is not null then
    return 'scheduled_ride';
  end if;
  return 'ride';
end;
$$;
revoke execute on function public.family_ride_module(public.ride_requests) from public, anon, authenticated;

create or replace function public.scheduled_rides_family()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  q jsonb := coalesce(new.request, '{}'::jsonb);
  v_pays boolean := lower(btrim(coalesce(q->>'payment_mode', ''))) = 'family';
  v_passenger uuid := public.family_passenger_of(q->'family');
  v_module text := case when new.hire_package is not null then 'hire'
                        when q ? 'parcel_size' then 'courier'
                        when q ? 'cargo_description' then 'freight' else 'scheduled_ride' end;
begin
  if not v_pays and v_passenger is null then
    return null;
  end if;
  perform public.family_attach_trip(v_module, new.id, new.rider_id, v_passenger, new.fare,
                                    jsonb_build_object('country', q->>'country', 'state', q->>'state',
                                                       'city', q->>'city', 'suburb', q->>'suburb'),
                                    q->'family', v_pays);
  return null;
end;
$$;
revoke execute on function public.scheduled_rides_family() from public, anon, authenticated;

-- ---- 9. The hold -----------------------------------------------------------------------------------
-- A hire paid from GET.wallet (or Family): the quote plus the buffer held
-- when it is booked (or released from a booking), with the trip named so
-- the Family layer charges whoever pays it.
create or replace function public.ride_requests_hire_hold()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg jsonb;
  v_amount numeric;
  v_owner uuid;
  v_balance numeric;
begin
  if new.hire_package is null or new.status not in ('open', 'accepted')
     or public.hire_pay_kind(new.payment_mode) <> 'wallet' then
    return null;
  end if;
  cfg := public.hourly_hire_config();
  if not (cfg->>'holdInWallet')::boolean then
    return null;
  end if;
  v_amount := round(coalesce((new.hire_quote->>'total')::numeric, new.fare, 0)
                    * (1 + (cfg->>'holdBufferPercent')::numeric / 100), 2);
  if v_amount <= 0 then
    return null;
  end if;
  v_owner := public.family_wallet_owner(new.id, new.rider_id, v_amount);
  insert into public.wallets (user_id, wallet_type, balance) values (v_owner, 'get_wallet', 0)
    on conflict (user_id, wallet_type) do nothing;
  select balance into v_balance from public.wallets where user_id = v_owner and wallet_type = 'get_wallet' for update;
  if coalesce(v_balance, 0) < v_amount then
    if new.scheduled_ride_id is not null then
      return null;  -- released from a booking: goes ahead unheld, paid at the end
    end if;
    raise exception 'HIRE_BALANCE' using errcode = 'P0001',
      hint = format('Top up your GET.wallet: %s is held for this hire until it ends.',
                    'RM' || to_char(v_amount, 'FM999999990.00'));
  end if;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
  values (new.rider_id, 'get_wallet', 'hire_hold', -v_amount, 'hire',
          'Hourly hire held — RM' || to_char(v_amount, 'FM999999990.00'), new.id);
  insert into public.hire_holds (ride_id, rider_id, amount) values (new.id, new.rider_id, v_amount)
  on conflict (ride_id) do nothing;
  return null;
end;
$$;
revoke execute on function public.ride_requests_hire_hold() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_hire_hold on public.ride_requests;
create trigger trg_ride_requests_hire_hold
  after insert on public.ride_requests
  for each row execute function public.ride_requests_hire_hold();

-- Returns a hire's hold (to whoever paid it: the Family layer sends a
-- refund back to the host up to what the family paid). True when one was.
create or replace function public.hire_hold_return(p_ride uuid, p_why text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  h public.hire_holds;
begin
  select * into h from public.hire_holds where ride_id = p_ride and status = 'held' for update;
  if not found then
    return false;
  end if;
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id)
  values (h.rider_id, 'get_wallet', 'hire_hold_return', h.amount, 'hire',
          case p_why when 'paid' then 'Hourly hire hold returned (paid)'
                     else 'Hourly hire hold returned' end, p_ride);
  update public.hire_holds set status = 'returned', returned_at = now(), returned_why = left(p_why, 40)
   where ride_id = p_ride;
  return true;
end;
$$;
revoke execute on function public.hire_hold_return(uuid, text) from public, anon, authenticated;

-- Cancelled, expired or paid some other way: the hold goes back. Runs
-- before the cancel fee (trg_ride_requests_city_cancel_fee), so the fee is
-- taken from the returned money.
create or replace function public.ride_requests_hire_after()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.hire_package is null then
    return null;
  end if;
  if new.status in ('cancelled', 'expired') and old.status is distinct from new.status then
    perform public.hire_hold_return(new.id, new.status);
  elsif new.payment_status = 'paid' and old.payment_status is distinct from 'paid' then
    perform public.hire_hold_return(new.id, 'paid');
  end if;
  return null;
end;
$$;
revoke execute on function public.ride_requests_hire_after() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_a_hire on public.ride_requests;
create trigger trg_ride_requests_a_hire
  after update of status, payment_status on public.ride_requests
  for each row execute function public.ride_requests_hire_after();

-- 0317's ride_pay, with a hire's hold returned first (its money then pays
-- the settled amount).
create or replace function public.ride_pay(p_ride uuid, p_method text, p_expected numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_due numeric;
  v_rate numeric;
  v_coins numeric;
  v_balance numeric;
  v_owner uuid;
  v_state text;
begin
  if auth.uid() is null then
    raise exception 'not_authorized';
  end if;
  if p_method not in ('get_wallet', 'get_coin', 'family') then
    raise exception 'invalid_method';
  end if;
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized';
  end if;
  if r.status <> 'completed' then
    raise exception 'ride_not_completed';
  end if;
  if r.payment_status = 'paid' then
    return jsonb_build_object('paid', coalesce(r.paid_amount, 0), 'method', r.paid_method, 'already', true);
  end if;
  if r.partner_id is null then
    raise exception 'no_driver';
  end if;

  v_due := public.ride_left_to_pay(r);
  if not public.ride_money_ok(v_due) then
    raise exception 'invalid_amount';
  end if;

  if p_expected is not null and abs(round(p_expected, 2) - v_due) > 0.005 then
    raise exception 'amount_changed' using hint = v_due::text;
  end if;

  -- 0326: a hire's hold comes back before it is paid.
  perform public.hire_hold_return(r.id, 'paid');

  v_owner := r.rider_id;
  if p_method = 'family' then
    v_state := public.family_trip_state(r.id, r.rider_id, v_due);
    if v_state <> 'ok' then
      raise exception '%', v_state using errcode = 'P0001',
        hint = case v_state when 'FAMILY_LIMIT_REACHED' then 'The family limit for this month doesn''t cover this trip.'
                            when 'FAMILY_RIDE_LIMIT' then 'This trip is over the family limit for one trip.'
                            when 'FAMILY_NOT_MEMBER' then 'You are no longer in the family.'
                            else 'The family doesn''t pay for this trip.' end;
    end if;
    v_owner := public.family_wallet_owner(r.id, r.rider_id, v_due);
  else
    perform public.family_release_trip(r.id);
  end if;

  if v_due > 0 and p_method in ('get_wallet', 'family') then
    insert into public.wallets (user_id, wallet_type, balance) values (v_owner, 'get_wallet', 0)
      on conflict (user_id, wallet_type) do nothing;
    select balance into v_balance from public.wallets
     where user_id = v_owner and wallet_type = 'get_wallet' for update;
    if coalesce(v_balance, 0) < v_due then
      raise exception 'insufficient_balance';
    end if;
    -- Charged to the rider and tagged with the trip: the family layer moves it to the host.
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id) values
      (r.rider_id, 'get_wallet', 'ride_payment', -v_due, 'ride',
       'Ride paid — RM' || to_char(v_due, 'FM999999990.00'), r.id),
      (r.partner_id, 'get_wallet', 'ride_earning', v_due, 'ride',
       'Ride fare received — RM' || to_char(v_due, 'FM999999990.00'), r.id);
  elsif v_due > 0 and p_method = 'get_coin' then
    select coins_per_currency into v_rate from public.get_coin_settings where id = 'master';
    if coalesce(v_rate, 0) <= 0 then
      raise exception 'coins_unavailable';
    end if;
    v_coins := ceil(v_due * v_rate * 100) / 100;
    insert into public.wallets (user_id, wallet_type, balance) values (r.rider_id, 'get_coin', 0)
      on conflict (user_id, wallet_type) do nothing;
    select balance into v_balance from public.wallets
     where user_id = r.rider_id and wallet_type = 'get_coin' for update;
    if coalesce(v_balance, 0) < v_coins then
      raise exception 'insufficient_balance';
    end if;
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
      (r.rider_id, 'get_coin', 'redeem', -v_coins, 'ride_fare',
       'Ride fare — RM' || to_char(v_due, 'FM999999990.00') || ' paid with coins'),
      (r.partner_id, 'get_wallet', 'ride_coin_payout', v_due, 'ride_fare',
       'Ride fare paid with GET.coin — RM' || to_char(v_due, 'FM999999990.00'));
  end if;

  update public.ride_requests
     set payment_status = 'paid',
         paid_method = case when p_method = 'family' then 'get_wallet' else p_method end,
         paid_amount = v_due,
         paid_at = now(),
         fare_coins_value = case when p_method = 'get_coin' then coalesce(fare_coins_value, 0) + v_due else fare_coins_value end,
         fare_coins_used = case when p_method = 'get_coin' then coalesce(fare_coins_used, 0) + coalesce(v_coins, 0) else fare_coins_used end,
         fare_coins_redeemed_at = coalesce(fare_coins_redeemed_at, now())
   where id = p_ride;

  return jsonb_build_object('paid', v_due, 'method', p_method, 'coins', coalesce(v_coins, 0),
                            'family', p_method = 'family');
end;
$$;
revoke execute on function public.ride_pay(uuid, text, numeric) from public, anon;
grant execute on function public.ride_pay(uuid, text, numeric) to authenticated;

-- ---- 10. Extensions --------------------------------------------------------------------------------
-- Who answers for the rider: the rider, the Family host who pays, or
-- whoever booked it in the family.
create or replace function public.hire_rider_side(r public.ride_requests, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_user is not null and (p_user = r.rider_id
     or exists (select 1 from public.family_trips t
                 where t.trip_id = r.id and (t.payer_id = p_user or t.booked_by = p_user)));
$$;
revoke execute on function public.hire_rider_side(public.ride_requests, uuid) from public, anon, authenticated;

create or replace function public.hire_extend_ask(p_ride uuid, p_minutes integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.hourly_hire_config();
  r public.ride_requests;
  v_uid uuid := auth.uid();
  v_by text;
  v_ext jsonb;
  v_auto boolean;
begin
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.hire_package is null then
    raise exception 'HIRE_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_by := case when v_uid = r.partner_id then 'driver'
               when public.hire_rider_side(r, v_uid) then 'rider' end;
  if v_by is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status not in ('accepted', 'arrived', 'on_trip') then
    raise exception 'HIRE_NOT_ON' using errcode = '22023', hint = 'This hire is not on the go.';
  end if;
  if not (cfg->'extendChoices' @> to_jsonb(p_minutes)) then
    raise exception 'HIRE_EXTEND_CHOICE' using errcode = '22023', hint = 'Choose one of the times offered.';
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(r.hire_extensions, '[]'::jsonb)) e
              where e->>'status' = 'pending') then
    raise exception 'HIRE_EXTEND_PENDING' using errcode = '22023', hint = 'An extension is already waiting for an answer.';
  end if;
  -- The rider asking pays it, so it is approved; the driver's waits for
  -- the rider unless the admin says it needn't.
  v_auto := v_by = 'rider' or not (cfg->>'extendNeedsRider')::boolean;
  v_ext := jsonb_build_object(
    'id', gen_random_uuid(), 'minutes', p_minutes,
    'amount', public.hire_overtime_amount(p_minutes, r.hire_step_min, r.hire_overtime_rate),
    'asked_at', now(), 'asked_by', v_by,
    'status', case when v_auto then 'approved' else 'pending' end,
    'approved_at', case when v_auto then now() end);
  update public.ride_requests
     set hire_extensions = coalesce(hire_extensions, '[]'::jsonb) || jsonb_build_array(v_ext),
         hire_ends_at = case when v_auto and hire_ends_at is not null
                             then hire_ends_at + make_interval(mins => p_minutes) else hire_ends_at end,
         hire_reminded_at = case when v_auto then null else hire_reminded_at end
   where id = p_ride;
  if v_auto then
    perform public.enqueue_notification(case when v_by = 'rider' then r.partner_id else r.rider_id end,
      'hire-ext-' || (v_ext->>'id'), 'ride_status', 'normal', 'Hire extended',
      format('The hire is %s minutes longer.', p_minutes),
      jsonb_build_object('type', 'hire_extended', 'request_id', r.id, 'extension', v_ext), r.id);
  else
    perform public.enqueue_notification(r.rider_id, 'hire-ask-' || (v_ext->>'id'), 'ride_status', 'critical',
      'Your driver asks to extend',
      format('%s more minutes for RM%s. Open the trip to approve or decline.', p_minutes,
             to_char((v_ext->>'amount')::numeric, 'FM999999990.00')),
      jsonb_build_object('type', 'hire_extend_request', 'request_id', r.id, 'extension', v_ext), r.id);
  end if;
  return v_ext;
end;
$$;
revoke execute on function public.hire_extend_ask(uuid, integer) from public, anon;
grant execute on function public.hire_extend_ask(uuid, integer) to authenticated;

create or replace function public.hire_extend_answer(p_ride uuid, p_id text, p_approve boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_ext jsonb;
  v_list jsonb;
begin
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.hire_package is null then
    raise exception 'HIRE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not public.hire_rider_side(r, auth.uid()) then
    raise exception 'not_authorized' using errcode = '42501', hint = 'The rider answers an extension.';
  end if;
  select e into v_ext from jsonb_array_elements(coalesce(r.hire_extensions, '[]'::jsonb)) e
   where e->>'id' = p_id and e->>'status' = 'pending';
  if v_ext is null then
    raise exception 'HIRE_EXTEND_GONE' using errcode = '22023', hint = 'This extension was already answered.';
  end if;
  v_ext := v_ext || jsonb_build_object('status', case when p_approve then 'approved' else 'declined' end,
                                       'answered_at', now(),
                                       'approved_at', case when p_approve then to_jsonb(now()) end);
  select coalesce(jsonb_agg(case when e->>'id' = p_id then v_ext else e end order by n), '[]'::jsonb) into v_list
    from jsonb_array_elements(r.hire_extensions) with ordinality t(e, n);
  update public.ride_requests
     set hire_extensions = v_list,
         hire_ends_at = case when p_approve and hire_ends_at is not null
                             then hire_ends_at + make_interval(mins => (v_ext->>'minutes')::int) else hire_ends_at end,
         hire_reminded_at = case when p_approve then null else hire_reminded_at end
   where id = p_ride;
  perform public.enqueue_notification(r.partner_id, 'hire-answer-' || p_id, 'ride_status', 'normal',
    case when p_approve then 'Extension approved' else 'Extension declined' end,
    case when p_approve then format('The hire is %s minutes longer.', v_ext->>'minutes')
         else 'The rider declined the extension. The hire ends at the booked time.' end,
    jsonb_build_object('type', 'hire_extend_answer', 'request_id', r.id, 'extension', v_ext), r.id);
  return v_ext;
end;
$$;
revoke execute on function public.hire_extend_answer(uuid, text, boolean) from public, anon;
grant execute on function public.hire_extend_answer(uuid, text, boolean) to authenticated;

-- ---- 11. The end -----------------------------------------------------------------------------------
-- The settled breakdown of [r] ended at [p_at] with [p_km] driven.
create or replace function public.hire_settle(r public.ride_requests, p_km numeric, p_at timestamptz,
                                              p_by text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.hourly_hire_config();
  q jsonb := coalesce(r.hire_quote, '{}'::jsonb);
  v_step numeric := coalesce((q->>'hourStep')::numeric, (cfg->>'hourStep')::numeric);
  v_min numeric := coalesce((q->>'minHours')::numeric, (cfg->>'minHours')::numeric);
  v_booked numeric := r.hire_hours;
  v_used_min numeric := greatest(0, extract(epoch from p_at - coalesce(r.hire_started_at, p_at)) / 60);
  v_ext_min integer := public.hire_extension_minutes(r.hire_extensions);
  v_pays text := cfg->>'earlyEndPays';
  v_hours numeric;
  v_over_min numeric;
  v_overtime numeric;
  v_km numeric := round(greatest(0, coalesce(p_km, 0)), 1);
  v_included numeric;
  v_extra_km numeric;
  v_extra numeric;
  v_base numeric;
  v_early boolean;
  v_lines jsonb := '[]'::jsonb;
begin
  v_early := v_used_min < v_booked * 60;
  -- The hours billed: the booked ones, or what an early end pays.
  v_hours := case
    when not v_early or v_pays = 'booked' then v_booked
    when v_pays = 'minimum' then least(v_booked, greatest(v_min, ceil(v_used_min / 60 / v_step) * v_step))
    else least(v_booked, greatest(v_step, ceil(v_used_min / 60 / v_step) * v_step)) end;
  v_base := round(v_hours * r.hire_rate, 2);
  -- Overtime: what is used past the booked hours, in started steps, up to
  -- the minutes the rider approved.
  v_over_min := least(v_ext_min, greatest(0, v_used_min - v_booked * 60));
  v_over_min := least(v_ext_min, ceil(v_over_min / greatest(1, r.hire_step_min)) * greatest(1, r.hire_step_min));
  v_overtime := public.hire_overtime_amount(v_over_min, r.hire_step_min, r.hire_overtime_rate);
  v_included := round(coalesce(r.hire_km_included, 0)
                      + v_ext_min / 60.0 * coalesce((q->>'kmPerHour')::numeric, 0), 1);
  v_extra_km := greatest(0, round(v_km - v_included, 1));
  v_extra := round(v_extra_km * coalesce(r.hire_extra_km_rate, 0), 2);
  v_lines := jsonb_build_array(jsonb_build_object('kind', 'hire', 'label', public.hire_hours_label(v_hours),
                                                  'amount', v_base));
  if v_overtime > 0 then
    v_lines := v_lines || jsonb_build_object('kind', 'overtime', 'label', 'Overtime ' || v_over_min::int || ' min',
                                             'amount', v_overtime);
  end if;
  if v_extra > 0 then
    v_lines := v_lines || jsonb_build_object('kind', 'extra_km', 'label', 'Extra km ' || public.hire_plain(v_extra_km) || ' km',
                                             'amount', v_extra);
  end if;
  return jsonb_build_object(
    'base', v_base, 'hours', v_hours, 'bookedHours', v_booked, 'earlyEnd', v_early, 'earlyEndPays', v_pays,
    'usedMinutes', round(v_used_min)::int, 'extensionMinutes', v_ext_min,
    'overtimeMinutes', v_over_min::int, 'overtime', v_overtime,
    'kmUsed', v_km, 'kmIncluded', v_included, 'extraKm', v_extra_km, 'extraKmAmount', v_extra,
    'placeFees', coalesce((q->>'placeFeesTotal')::numeric, 0),
    'fare', round(v_base + v_overtime + v_extra, 2),
    'endedBy', p_by, 'endedAt', p_at, 'lines', v_lines);
end;
$$;
revoke execute on function public.hire_settle(public.ride_requests, numeric, timestamptz, text) from public, anon, authenticated;

-- "4 hr", "1.5 hr".
create or replace function public.hire_plain(p numeric)
returns text
language sql
immutable
set search_path = ''
as $$ select case when p = round(p) then round(p)::text else trim(trailing '0' from round(p, 1)::text) end; $$;

create or replace function public.hire_hours_label(p numeric)
returns text
language sql
immutable
set search_path = public
as $$ select 'Hourly hire ' || public.hire_plain(p) || ' hr'; $$;

-- Ends [p_ride]: settled, then completed as any ride is.
create or replace function public.hire_finish(p_ride uuid, p_km numeric, p_by text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_km numeric := p_km;
  s jsonb;
begin
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.hire_package is null or r.status <> 'on_trip' then
    return null;
  end if;
  if v_km is null then
    select t.actual_trip_km into v_km from public.ride_telematics t where t.ride_id = p_ride;
  end if;
  s := public.hire_settle(r, v_km, now(), p_by);
  update public.ride_requests
     set status = 'completed', completed_at = now(),
         ended_early_at = case when (s->>'earlyEnd')::boolean then now() end,
         fare = (s->>'fare')::numeric, ride_fare = (s->>'fare')::numeric,
         hire_km_used = (s->>'kmUsed')::numeric, hire_settled = s,
         hire_extensions = (select coalesce(jsonb_agg(case when e->>'status' = 'pending'
                                                           then e || '{"status": "lapsed"}'::jsonb else e end), '[]'::jsonb)
                              from jsonb_array_elements(coalesce(hire_extensions, '[]'::jsonb)) e)
   where id = p_ride;
  return s;
end;
$$;
revoke execute on function public.hire_finish(uuid, numeric, text) from public, anon, authenticated;

create or replace function public.hire_end(p_ride uuid, p_km_used numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_uid uuid := auth.uid();
  v_by text;
  s jsonb;
begin
  select * into r from public.ride_requests where id = p_ride;
  if not found or r.hire_package is null then
    raise exception 'HIRE_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_by := case when v_uid = r.partner_id then 'driver'
               when v_uid = r.rider_id and (public.hourly_hire_config()->>'riderCanEndEarly')::boolean then 'rider' end;
  if v_by is null then
    raise exception 'not_authorized' using errcode = '42501', hint = 'Only the driver ends this hire.';
  end if;
  if r.status <> 'on_trip' then
    raise exception 'HIRE_NOT_ON' using errcode = '22023', hint = 'The hire ends once it has started.';
  end if;
  if p_km_used is not null and (p_km_used < 0 or p_km_used > 5000) then
    raise exception 'HIRE_KM' using errcode = '22023', hint = 'Enter the km driven (0 to 5000).';
  end if;
  -- The rider's own end: km as the trip measured it, never the rider's figure.
  s := public.hire_finish(p_ride, case when v_by = 'driver' then p_km_used end, v_by);
  if v_by = 'rider' then
    perform public.enqueue_notification(r.partner_id, 'hire-end-' || r.id, 'ride_status', 'critical',
      'The rider ended the hire', 'The hire is over. The trip is complete.',
      jsonb_build_object('type', 'hire_ended', 'request_id', r.id), r.id);
  end if;
  return s;
end;
$$;
revoke execute on function public.hire_end(uuid, numeric) from public, anon;
grant execute on function public.hire_end(uuid, numeric) to authenticated;

-- Every minute: the reminder before a hire's time is up, and the end of
-- a hire nobody ended.
create or replace function public.hire_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.hourly_hire_config();
  r public.ride_requests;
  n integer := 0;
begin
  if (cfg->>'reminderBeforeEndMin')::int > 0 then
    for r in
      select * from public.ride_requests
       where hire_package is not null and status = 'on_trip' and hire_ends_at is not null
         and hire_reminded_at is null and hire_ends_at > now()
         and hire_ends_at - make_interval(mins => (cfg->>'reminderBeforeEndMin')::int) <= now()
    loop
      perform public.enqueue_notification(p, 'hire-remind-' || r.id || '-' || extract(epoch from r.hire_ends_at)::bigint,
        'ride_status', 'normal', 'Hire time nearly up',
        format('The hire ends at %s.', to_char(r.hire_ends_at at time zone coalesce(r.timezone, 'Asia/Kuala_Lumpur'), 'HH12:MI am')),
        jsonb_build_object('type', 'hire_reminder', 'request_id', r.id), r.id)
        from unnest(array[r.rider_id, r.partner_id]) p;
      update public.ride_requests set hire_reminded_at = now() where id = r.id;
    end loop;
  end if;
  for r in
    select * from public.ride_requests
     where hire_package is not null and status = 'on_trip' and hire_ends_at is not null
       and hire_ends_at + make_interval(mins => (cfg->>'autoEndAfterMin')::int) <= now()
  loop
    perform public.hire_finish(r.id, null, 'auto');
    perform public.enqueue_notification(p, 'hire-auto-end-' || r.id, 'ride_status', 'normal', 'Hire ended',
      'The hire''s time was up, so it has been ended.',
      jsonb_build_object('type', 'hire_ended', 'request_id', r.id), r.id)
      from unnest(array[r.rider_id, r.partner_id]) p;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.hire_tick() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'hourly-hire-tick';
    perform cron.schedule('hourly-hire-tick', '* * * * *', $job$select public.hire_tick()$job$);
  end if;
end $$;

-- ---- 12. Statements ---------------------------------------------------------------------------------
-- 0324's statement_ride_lines, with a hire's lines.
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
  out jsonb;
begin
  if jsonb_typeof(r.charges) = 'array' then
    for c in select value from jsonb_array_elements(r.charges) loop
      v := case when jsonb_typeof(c->'value') = 'number' then (c->>'value')::numeric end;
      continue when v is null or v <= 0 or btrim(coalesce(c->>'name', '')) = '' or c->>'kind' = 'tax';
      amt := round(greatest(0, case when c->>'charge' = 'fixed' then v else f * v / 100 end), 2);
      s_all := s_all + amt;
      if (c->>'platform')::boolean is true then
        s_platform := s_platform + amt;
      elsif btrim(c->>'name') = any(p_earning) or coalesce(c->'earning' = 'true'::jsonb, false) then
        s_earn := s_earn + amt;
      else
        s_pass := s_pass + amt;
      end if;
    end loop;
  end if;
  out := jsonb_build_object(
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
  -- 0326: the fare of a hire, in its lines.
  if r.hire_package is not null then
    out := out || jsonb_build_object('hire', coalesce(r.hire_settled->'lines',
      jsonb_build_array(jsonb_build_object('kind', 'hire', 'label', public.hire_hours_label(r.hire_hours), 'amount', f))));
  end if;
  return out;
end;
$$;
revoke execute on function public.statement_ride_lines(public.ride_requests, text[]) from public, anon, authenticated;

notify pgrst, 'reload schema';
