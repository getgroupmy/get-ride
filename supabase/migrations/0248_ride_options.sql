-- ============================================================================
-- 0248: Ride Options — "Assistance required", and what the options add to
-- the fare
--
-- Admin → Display Settings → Ride Options (kept in the display settings
-- blob, as before) shows, hides, renames and orders the rider's options,
-- and sets an assistance catalogue and charges for pets and assistance.
-- What reaches the ride:
--
--   * ride_requests.assistance: {items: [{id, name, emoji, choice}], note}.
--     Each item's name and emoji are copied in, so a ride keeps what was
--     picked even after the admin renames or removes it. The note label
--     keeps "Assistance: ..." (names only) for driver apps that don't read
--     the column.
--   * Ride privacy (0182, 0195, 0247) holds: approved drivers read an open
--     request's row, so they see what help is needed before accepting, but
--     the rider's free-text note waits in ride_request_private (the rider
--     and admins). When a driver takes the ride the note comes back to the
--     row, which only the rider, that driver and admins read. Reopened, it
--     moves out again. Only the rider (or an admin) changes the help.
--   * ride_requests.option_charges: [{kind, name, amount}], what the pets
--     and the assistance added ("Pet charge" 10). The fare already includes
--     them (the app adds them before quoting); the column says what is in
--     it, for the driver and admins. Written at booking only, by the rider,
--     and never more than the fare.
--   * Commission and promo codes: Ride Options → Charges has a switch for
--     each ("rideOptionCharges" in the blob, both on by default, as before).
--     With one off, commission_base (0218) or the promo guard and settlement
--     (0242) work on the fare less the option charges.
--   * ride_requests.option_names: the names the options were booked under
--     (the admin may rename them), so the driver reads the ride as booked.
--   * Pet types are the admin's own list now: ride_pets_valid (0247) only
--     checks a type's length, never a fixed list, so a custom type books.
--   * A scheduled booking keeps them (0247's list plus assistance,
--     option_charges and option_names); the booking is read by the rider,
--     the driver who took it and admins only.
-- ============================================================================

-- ---- The help ------------------------------------------------------------------
-- Null, or an object with 1 to 40 items, each with a name (1 to 60
-- characters), maybe an id (up to 60), an emoji (up to 16) and a choice (up
-- to 80); and maybe a note (up to 500).
create or replace function public.ride_assistance_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p is null
      or jsonb_typeof(p) = 'null'
      or (jsonb_typeof(p) = 'object'
          and jsonb_typeof(p->'items') = 'array'
          and jsonb_array_length(p->'items') between 1 and 40
          and (p->'note' is null or jsonb_typeof(p->'note') = 'null'
               or (jsonb_typeof(p->'note') = 'string' and char_length(p->>'note') <= 500))
          and pg_column_size(p) <= 16384
          and not exists (
            select 1 from jsonb_array_elements(p->'items') e
             where not coalesce(
               jsonb_typeof(e) = 'object'
               and jsonb_typeof(e->'name') = 'string'
               and char_length(btrim(e->>'name')) between 1 and 60
               and (e->'id' is null or (jsonb_typeof(e->'id') = 'string' and char_length(e->>'id') <= 60))
               and (e->'emoji' is null or jsonb_typeof(e->'emoji') = 'null'
                    or (jsonb_typeof(e->'emoji') = 'string' and char_length(e->>'emoji') <= 16))
               and (e->'choice' is null or jsonb_typeof(e->'choice') = 'null'
                    or (jsonb_typeof(e->'choice') = 'string' and char_length(e->>'choice') <= 80)),
               false)));
$$;

-- The help without the rider's note: what an open request shows drivers.
create or replace function public.ride_assistance_public(p jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case when p is null or jsonb_typeof(p) <> 'object' then p else p - 'note' end;
$$;
revoke execute on function public.ride_assistance_public(jsonb) from public, anon, authenticated;

-- ---- What the options add to the fare ------------------------------------------
-- Null, or up to 10 lines, each a name (1 to 60) and an amount of zero or
-- more (at most 100000), maybe with a kind.
create or replace function public.ride_option_charges_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p is null
      or jsonb_typeof(p) = 'null'
      or (jsonb_typeof(p) = 'array'
          and jsonb_array_length(p) <= 10
          and not exists (
            select 1 from jsonb_array_elements(p) e
             where not coalesce(
               jsonb_typeof(e) = 'object'
               and jsonb_typeof(e->'name') = 'string'
               and char_length(btrim(e->>'name')) between 1 and 60
               and jsonb_typeof(e->'amount') = 'number'
               and (e->>'amount')::numeric between 0 and 100000
               and (e->'kind' is null or (jsonb_typeof(e->'kind') = 'string' and char_length(e->>'kind') <= 20)),
               false)));
$$;

-- The lines' total; 0 for none.
create or replace function public.ride_option_charges_total(p jsonb)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select coalesce((select sum((e->>'amount')::numeric)
                     from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) e
                    where jsonb_typeof(e->'amount') = 'number'), 0);
$$;

alter table public.ride_requests add column if not exists assistance jsonb;
alter table public.ride_requests drop constraint if exists ride_requests_assistance_valid;
alter table public.ride_requests
  add constraint ride_requests_assistance_valid check (public.ride_assistance_valid(assistance));

alter table public.ride_requests add column if not exists option_charges jsonb;
alter table public.ride_requests drop constraint if exists ride_requests_option_charges_valid;
alter table public.ride_requests
  add constraint ride_requests_option_charges_valid check (public.ride_option_charges_valid(option_charges));

-- The names riders saw the options under (Admin → Display Settings → Ride
-- Options may rename them), for the ones the rider turned on: {pet: "Bringing
-- a pet", ...}. The driver reads the ride under the names it was booked with.
create or replace function public.ride_option_names_valid(p jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p is null
      or jsonb_typeof(p) = 'null'
      or (jsonb_typeof(p) = 'object'
          and (select count(*) from jsonb_object_keys(p)) <= 10
          and not exists (
            select 1 from jsonb_each(p) e
             where char_length(e.key) > 40
                or jsonb_typeof(e.value) <> 'string'
                or char_length(btrim(e.value #>> '{}')) not between 1 and 40));
$$;

alter table public.ride_requests add column if not exists option_names jsonb;
alter table public.ride_requests drop constraint if exists ride_requests_option_names_valid;
alter table public.ride_requests
  add constraint ride_requests_option_names_valid check (public.ride_option_names_valid(option_names));

alter table public.ride_request_private add column if not exists assistance jsonb;

-- ---- Open requests keep the note aside -------------------------------------------
-- Before the pets and privacy triggers (zz_assistance < zz_pets <
-- zz_privacy); it only touches assistance and option_charges. Who may
-- change them is the guard's below.
create or replace function public.ride_requests_assistance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ins boolean := tg_op = 'INSERT';
begin
  if new.assistance is not null and jsonb_typeof(new.assistance) = 'null' then
    new.assistance := null;
  end if;
  if new.option_charges is not null
     and (jsonb_typeof(new.option_charges) = 'null'
          or (jsonb_typeof(new.option_charges) = 'array' and jsonb_array_length(new.option_charges) = 0)) then
    new.option_charges := null;
  end if;
  if not public.ride_assistance_valid(new.assistance) then
    raise exception 'RIDE_ASSISTANCE_INVALID' using errcode = '22023',
      hint = 'Each kind of help needs a name; the note is at most 500 characters.';
  end if;

  if new.status = 'open' then
    if ins or new.assistance is distinct from old.assistance
       or (jsonb_typeof(new.assistance) = 'object' and new.assistance ? 'note') then
      insert into public.ride_request_private as p (request_id, assistance)
      values (new.id, new.assistance)
      on conflict (request_id) do update set assistance = excluded.assistance, updated_at = now();
      new.assistance := public.ride_assistance_public(new.assistance);
    end if;
  elsif not ins and old.status = 'open' and new.assistance is not distinct from old.assistance then
    -- Taken (or ended): the note comes back to the row.
    new.assistance := coalesce((select p.assistance from public.ride_request_private p where p.request_id = new.id),
                               new.assistance);
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_assistance() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_zz_assistance on public.ride_requests;
create trigger trg_ride_requests_zz_assistance
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_assistance();

-- ---- Who changes them ------------------------------------------------------------
-- App callers are told apart by the session's role, as in 0247's pets guard;
-- the server's functions and admins who may edit rides are unaffected.
--   * the help is the rider's: nobody else changes it;
--   * what the options add, and the names they were booked under, are set
--     when the ride is booked; the charges are part of its fare.
create or replace function public.ride_requests_guard_rider_options()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_setting('role', true) not in ('anon', 'authenticated')
     or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.option_charges is not null and jsonb_typeof(new.option_charges) = 'array'
       and public.ride_option_charges_total(new.option_charges) > coalesce(new.fare, 0) + 0.005 then
      raise exception 'RIDE_OPTION_CHARGES_INVALID' using errcode = '22023',
        hint = 'The option charges are part of the fare.';
    end if;
    return new;
  end if;
  if auth.uid() is distinct from old.rider_id
     and new.assistance is distinct from old.assistance then
    raise exception 'RIDE_RIDER_ONLY' using errcode = '42501',
      hint = 'Only the passenger changes the help they asked for.';
  end if;
  if new.option_charges is distinct from old.option_charges or new.option_names is distinct from old.option_names then
    raise exception 'RIDE_OPTION_CHARGES_FIXED' using errcode = '42501',
      hint = 'The option charges and names are set when the ride is booked.';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_guard_rider_options() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_b_guard_rider_options on public.ride_requests;
create trigger trg_ride_requests_b_guard_rider_options
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_guard_rider_options();

-- ---- Scheduled bookings ----------------------------------------------------------
-- The booking keeps the help and the option charges (0247's list, plus
-- assistance and option_charges).
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
       'promo_code_id', 'pets', 'assistance', 'option_charges', 'option_names'])
       and (e.key <> 'charges' or jsonb_typeof(e.value) = 'array')
  ), '{}'::jsonb);
$$;
revoke execute on function public.scheduled_request_clean(jsonb, numeric) from public, anon, authenticated;

-- Help or charges that would stop the ride at its release are refused at
-- booking.
create or replace function public.scheduled_rides_options_check()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if not public.ride_assistance_valid(new.request->'assistance') then
    raise exception 'RIDE_ASSISTANCE_INVALID' using errcode = '22023',
      hint = 'Each kind of help needs a name; the note is at most 500 characters.';
  end if;
  if not public.ride_option_charges_valid(new.request->'option_charges')
     or not public.ride_option_names_valid(new.request->'option_names') then
    raise exception 'RIDE_OPTION_CHARGES_INVALID' using errcode = '22023',
      hint = 'The option charges are part of the fare.';
  end if;
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_options_check() from public, anon, authenticated;

drop trigger if exists trg_scheduled_rides_options on public.scheduled_rides;
create trigger trg_scheduled_rides_options
  before insert or update of request on public.scheduled_rides
  for each row execute function public.scheduled_rides_options_check();

-- ---- Commission and promo codes on the option charges ------------------------------------
-- Admin → Display Settings → Ride Options → Charges: two switches in the
-- display settings blob ("rideOptionCharges": {commission, promo}), both on
-- unless set off (today's behaviour: the charges are part of the fare). With
-- one off, that side works on the fare less the ride's option charges.
create or replace function public.ride_option_charge_rules()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'commission', coalesce(s->'commission' <> 'false'::jsonb, true),
    'promo', coalesce(s->'promo' <> 'false'::jsonb, true))
    from (select (select settings->'rideOptionCharges' from public.admin_display_settings where id = 'global') s) x;
$$;
revoke execute on function public.ride_option_charge_rules() from public, anon;
grant execute on function public.ride_option_charge_rules() to authenticated;

-- What to take off the fare for [p_for] ('commission' or 'promo'): the
-- option charges when the admin leaves them out of it, else 0.
create or replace function public.ride_option_charges_off(p_charges jsonb, p_for text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case when p_charges is null or (public.ride_option_charge_rules()->>p_for)::boolean is not false then 0
              else round(public.ride_option_charges_total(p_charges), 2) end;
$$;
revoke execute on function public.ride_option_charges_off(jsonb, text) from public, anon;
-- The promo guard (0242) runs as the caller.
grant execute on function public.ride_option_charges_off(jsonb, text) to authenticated;

-- 0218's commission base, on the fare less the option charges when they are
-- left out of it.
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
  f numeric := greatest(0, round(coalesce(r.ride_fare, r.fare, 0), 2)
                         - public.ride_option_charges_off(r.option_charges, 'commission'));
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

-- 0242's promo guard and settlement, on the fare less the option charges
-- when promo codes don't discount them.
create or replace function public.ride_requests_promo_guard()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_client boolean := current_user in ('anon', 'authenticated') and not public.caller_is_admin();
  v_quote jsonb;
  v_fare numeric;
  v_pickup_at timestamptz;
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
    v_fare := greatest(0, round(coalesce(new.ride_fare, new.fare), 2)
                          - public.ride_option_charges_off(new.option_charges, 'promo'));
    -- A scheduled booking turned into a ride by the server (never one from
    -- the apps) is checked again as a scheduled ride, at its pickup time.
    if new.scheduled_ride_id is not null and not v_client then
      v_pickup_at := public.promo_scheduled_pickup(new.scheduled_ride_id);
    end if;
    begin
      v_quote := public.promo_ride_quote(new.promo_code_id, new.rider_id, new.timezone,
                                         new.pickup_lat, new.pickup_lng, new.drop_lat, new.drop_lng,
                                         new.service, v_fare,
                                         case when v_pickup_at is null then 'now' else 'scheduled' end,
                                         coalesce(v_pickup_at, now()));
    exception when others then
      v_quote := jsonb_build_object('reason', 'check_failed');
    end;
    if v_quote ? 'reason' then
      -- The booking goes ahead without the code.
      new.promo_code_id := null;
      new.promo_error := v_quote->>'reason';
      if v_pickup_at is not null then
        perform public.promo_scheduled_dropped(new.scheduled_ride_id, v_quote->>'reason');
      end if;
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
      public.promo_ride_estimate(new.promo_code_id,
        greatest(0, round(coalesce(new.ride_fare, new.fare), 2) - public.ride_option_charges_off(new.option_charges, 'promo'))),
      new.promo_estimate);
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_promo_guard() from public, anon, authenticated;

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

  v_fare := greatest(0, round(coalesce(r.ride_fare, r.fare, 0), 2) - public.ride_option_charges_off(r.option_charges, 'promo'));
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

notify pgrst, 'reload schema';
