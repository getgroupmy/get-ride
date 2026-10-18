-- ============================================================================
-- 0219 — Meter / TEKSI trips reach the server (commission phase 2b)
--
-- A metered hire (a TEKSI street hail, or the meter on its own) was kept only
-- on the driver's phone, its paper roll. The app now also sends each finished
-- hire here with meter_trip_record(), from the phone's queue, so one made
-- with no signal arrives later. Sending the same hire twice does nothing.
--
-- When Admin → Commission → Settings → "Charge commission on meter / TEKSI
-- trips" is on (0218), the hire is charged as a booked trip is: the rate for
-- where it began (0216), the driver's tiers (0218), on the fare plus what is
-- ticked (tolls & charges with "Tolls", and the surcharges named "Airport
-- surcharge" and "Bags & passengers"), from GET.credit. Off, the hire is kept
-- and not charged; turning it on later does not charge hires already sent.
--
-- The driver reads their own hires; admins read all. Nothing else writes.
-- ============================================================================

create table if not exists public.meter_trips (
  id                     uuid primary key,
  partner_id             uuid not null references public.profiles(id) on delete cascade,
  started_at             timestamptz not null,
  ended_at               timestamptz not null,
  distance_km            numeric(10,3) not null default 0 check (distance_km >= 0 and distance_km < 5000),
  duration_s             integer not null default 0 check (duration_s >= 0),
  waiting_s              integer not null default 0 check (waiting_s >= 0),
  rate_label             text check (rate_label is null or length(rate_label) <= 80),
  period                 text check (period is null or length(period) <= 20),
  currency               text not null default 'MYR' check (length(currency) <= 8),
  fare                   numeric(12,2) not null check (fare >= 0 and fare < 100000),
  extra                  numeric(12,2) not null default 0 check (extra >= 0 and extra < 100000),
  airport_surcharge      numeric(12,2) not null default 0 check (airport_surcharge >= 0 and airport_surcharge < 100000),
  card_surcharge         numeric(12,2) not null default 0 check (card_surcharge >= 0 and card_surcharge < 100000),
  total                  numeric(12,2) not null check (total >= 0 and total < 400000),
  pax                    integer check (pax is null or pax between 0 and 99),
  luggage                integer check (luggage is null or luggage between 0 and 99),
  pickup_lat             double precision check (pickup_lat is null or pickup_lat between -90 and 90),
  pickup_lng             double precision check (pickup_lng is null or pickup_lng between -180 and 180),
  pickup_place           text check (pickup_place is null or length(pickup_place) <= 200),
  dropoff_lat            double precision check (dropoff_lat is null or dropoff_lat between -90 and 90),
  dropoff_lng            double precision check (dropoff_lng is null or dropoff_lng between -180 and 180),
  dropoff_place          text check (dropoff_place is null or length(dropoff_place) <= 200),
  destination            text check (destination is null or length(destination) <= 200),
  plate                  text check (plate is null or length(plate) <= 20),
  commission_rate        numeric(6,4),
  commission_rule_id     uuid,
  commission_tier_id     uuid,
  commission_base_amount numeric(12,2),
  commission_amount      numeric(12,2),
  commission_charged_at  timestamptz,
  commission_error       text,
  uploaded_at            timestamptz not null default now(),
  check (ended_at >= started_at)
);

create index if not exists meter_trips_partner_ended_idx on public.meter_trips (partner_id, ended_at desc);

alter table public.meter_trips enable row level security;
revoke all on public.meter_trips from anon;
revoke insert, update, delete on public.meter_trips from authenticated;
grant select on public.meter_trips to authenticated;

drop policy if exists "meter_trips own or admin read" on public.meter_trips;
create policy "meter_trips own or admin read"
  on public.meter_trips for select to authenticated
  using (partner_id = (select auth.uid()) or (select public.caller_is_admin()));

-- ---- Charging -----------------------------------------------------------------------------------
-- What commission is charged on for a hire: the fare, plus tolls & charges if
-- "Tolls" is ticked, plus the airport and bags & passengers surcharges if
-- ticked by those names.
create or replace function public.meter_trip_commission_base(t public.meter_trips)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.commission_config();
  names text[] := array(select jsonb_array_elements_text(cfg->'baseSurcharges'));
  total numeric := round(coalesce(t.fare, 0), 2);
begin
  if (cfg->>'baseTolls')::boolean then
    total := total + round(coalesce(t.extra, 0), 2);
  end if;
  if 'Airport surcharge' = any(names) then
    total := total + round(coalesce(t.airport_surcharge, 0), 2);
  end if;
  if 'Bags & passengers' = any(names) then
    total := total + round(coalesce(t.card_surcharge, 0), 2);
  end if;
  return round(total, 2);
end;
$$;
revoke execute on function public.meter_trip_commission_base(public.meter_trips) from public, anon, authenticated;

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
  select * into v from public.commission_resolve(t.partner_id, t.pickup_lat, t.pickup_lng, null, null, null, null);
  select * into tr from public.commission_apply_tiers(t.partner_id, v.rate, v.level);
  if tr.rate is null or tr.rate < 0 or tr.rate >= 1 then
    return;
  end if;
  v_amount := round(v_base * tr.rate, 2);
  if v_amount > 0 then
    insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
    values (t.partner_id, 'get_credit', 'commission', -v_amount,
            'Meter trip commission ' || round(tr.rate * 100, 1) || '% of ' || t.currency || ' ' || v_base);
  end if;
  update public.meter_trips
     set commission_rate = tr.rate,
         commission_rule_id = v.rule_id,
         commission_tier_id = tr.tier_id,
         commission_base_amount = v_base,
         commission_amount = v_amount,
         commission_charged_at = now(),
         commission_error = null
   where id = p_id;
end;
$$;
revoke all on function public.meter_trip_charge_commission(uuid) from public, anon, authenticated, service_role;

-- ---- Sending a hire -----------------------------------------------------------------------------
-- The app's upload. Answers { recorded, charged, amount }. A hire already sent
-- is answered as it stands. The hire must be the caller's, an approved
-- partner's, and have ended within the last 90 days.
create or replace function public.meter_trip_record(p_trip jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_started timestamptz;
  v_ended timestamptz;
  t public.meter_trips;
begin
  if v_uid is null or not public.caller_is_approved_partner() then
    raise exception 'METER_TRIP_NOT_PARTNER' using errcode = '42501',
      hint = 'Only an approved partner can send meter trips.';
  end if;
  if jsonb_typeof(p_trip) <> 'object' or pg_column_size(p_trip) > 8000 then
    raise exception 'METER_TRIP_INVALID' using errcode = '22023', hint = 'That meter trip could not be read.';
  end if;
  begin
    v_id := (p_trip->>'id')::uuid;
    v_started := to_timestamp((p_trip->>'startedAt')::bigint / 1000.0);
    v_ended := to_timestamp((p_trip->>'endedAt')::bigint / 1000.0);
  exception when others then
    raise exception 'METER_TRIP_INVALID' using errcode = '22023', hint = 'That meter trip could not be read.';
  end;
  if v_id is null or v_ended < v_started or v_ended > now() + interval '1 day'
     or v_ended < now() - interval '90 days' or v_ended - v_started > interval '24 hours' then
    raise exception 'METER_TRIP_INVALID' using errcode = '22023', hint = 'That meter trip''s times are not possible.';
  end if;

  select * into t from public.meter_trips where id = v_id;
  if found then
    if t.partner_id <> v_uid then
      raise exception 'METER_TRIP_INVALID' using errcode = '22023', hint = 'That meter trip could not be read.';
    end if;
    return jsonb_build_object('recorded', true, 'charged', t.commission_charged_at is not null,
                              'amount', coalesce(t.commission_amount, 0));
  end if;

  begin
    insert into public.meter_trips (
      id, partner_id, started_at, ended_at, distance_km, duration_s, waiting_s, rate_label, period, currency,
      fare, extra, airport_surcharge, card_surcharge, total, pax, luggage,
      pickup_lat, pickup_lng, pickup_place, dropoff_lat, dropoff_lng, dropoff_place, destination, plate)
    values (
      v_id, v_uid, v_started, v_ended,
      round(greatest(0, coalesce((p_trip->>'distanceM')::numeric, 0)) / 1000, 3),
      greatest(0, coalesce((p_trip->>'elapsedMs')::bigint, 0) / 1000)::int,
      greatest(0, coalesce((p_trip->>'waitingMs')::bigint, 0) / 1000)::int,
      left(nullif(btrim(p_trip->>'rateLabel'), ''), 80),
      left(nullif(btrim(p_trip->>'period'), ''), 20),
      left(coalesce(nullif(btrim(p_trip->>'currency'), ''), 'MYR'), 8),
      round((p_trip->>'fare')::numeric, 2),
      round(coalesce((p_trip->>'extra')::numeric, 0), 2),
      round(coalesce((p_trip->>'airportSurcharge')::numeric, 0), 2),
      round(coalesce((p_trip->>'cardSurcharge')::numeric, 0), 2),
      round((p_trip->>'total')::numeric, 2),
      (p_trip->>'pax')::int,
      (p_trip->>'luggage')::int,
      (p_trip->'pickup'->>'latitude')::double precision,
      (p_trip->'pickup'->>'longitude')::double precision,
      left(nullif(btrim(p_trip->'pickup'->>'place'), ''), 200),
      (p_trip->'dropoff'->>'latitude')::double precision,
      (p_trip->'dropoff'->>'longitude')::double precision,
      left(nullif(btrim(p_trip->'dropoff'->>'place'), ''), 200),
      left(nullif(btrim(p_trip->>'destination'), ''), 200),
      left(nullif(btrim(p_trip->>'plate'), ''), 20))
    returning * into t;
  exception when check_violation or invalid_text_representation or numeric_value_out_of_range
                 or not_null_violation then
    raise exception 'METER_TRIP_INVALID' using errcode = '22023', hint = 'That meter trip''s numbers are not possible.';
  end;

  if (public.commission_config()->>'meterCommission')::boolean then
    -- A failed charge never loses the hire: it is kept with the reason.
    begin
      perform public.meter_trip_charge_commission(t.id);
    exception when others then
      update public.meter_trips set commission_error = left(sqlerrm, 500) where id = t.id;
    end;
    select * into t from public.meter_trips where id = t.id;
  end if;
  return jsonb_build_object('recorded', true, 'charged', t.commission_charged_at is not null,
                            'amount', coalesce(t.commission_amount, 0));
end;
$$;
revoke execute on function public.meter_trip_record(jsonb) from public, anon;
grant execute on function public.meter_trip_record(jsonb) to authenticated;
