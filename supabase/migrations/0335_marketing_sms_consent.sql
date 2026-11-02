-- ============================================================================
-- 0335 — Marketing SMS go only to people who said yes: the News and offers
-- switch (0333, profiles.news_offers, off until the person turns it on) now
-- covers the admin's marketing SMS as well as push broadcasts.
-- And a passenger is told, live on their trip screen, while their
-- driver's VoiceProtection records the trip (6).
--
-- Version 20261102120000 (0335_marketing_sms_consent). Re-runnable:
-- functions "create or replace", triggers dropped first, the index and
-- the column "if not exists". Stands on 0120 / 0183 / 0190 (the SMS queue,
-- the gateway's claim and its inbox), 0317 (family_phone_digits,
-- family_live), 0331 (mygig_link_view) and 0333 (news_offers,
-- store_review).
--
-- 1. marketing_sms_consent(phone) -> 'opted_in' | 'not_opted_in' |
--    'no_account': whether a live account (not deleted, not the store
--    review account) with that number has News and offers on. Numbers are
--    compared as digits with the country code (family_phone_digits: a
--    Malaysian 0... reads as 60...), helped by an index on profiles.
-- 2. The queue (sms_outbox), on the server, whatever path a row comes by
--    (the admin's page, a session key's test SMS, a definer function): a
--    marketing SMS to a number that has not opted in, or that has no
--    account, is refused before it is queued (MARKETING_NO_CONSENT, BEFORE
--    INSERT OR UPDATE OF channel, to_phone). Trip, safety, sign-in code,
--    support and ops SMS are not touched.
-- 3. The gateway (gateway_claim_for, 0190's, otherwise unchanged): a
--    marketing SMS still waiting when its number has since turned News and
--    offers off is failed ('No News and offers consent'), never sent.
-- 4. admin_queue_marketing_sms(phones, body): the admin's marketing send to
--    many numbers. Each distinct number is queued only when it opted in; the
--    answer says how many were queued and how many were left out, and why
--    (not opted in, no account, not a phone number). Same rights as queuing
--    an SMS on the page (caller_admin_can_write('sms_outbox')); logged in
--    admin_audit_log ('marketing_sms.queue', the counts only).
--    admin_marketing_sms_reach(): how many live accounts with a phone have
--    News and offers on, for the page (any admin).
-- 5. STOP: an SMS the gateway receives (sms_inbox, any path) that says
--    STOP, STOP ALL, UNSUBSCRIBE or BERHENTI (any case, punctuation
--    ignored) turns News and offers off for every live account with that
--    number, and fails that number's waiting marketing SMS ('Replied STOP').
--    The person can turn it on again in Settings > Notifications.
-- 6. The passenger is told while the driver records (VoiceProtection,
--    0040 / 0223): ride_requests.driver_audio, set by the driver's phone
--    with ride_set_driver_audio(ride, on) when its recorder starts and
--    stops. Only the trip's driver changes it (DRIVER_AUDIO_DRIVER_ONLY), on
--    only while the trip is under way (DRIVER_AUDIO_NOT_ON_TRIP); whatever
--    writes the row, it goes off when the trip is no longer under way or
--    changes driver (trg_ride_requests_zzzzzz_driver_audio). The passenger's
--    trip screen reads the ride row; family_live (0317) and mygig_link_view
--    (0331), otherwise unchanged, carry it as driverAudio
--    (ride_driver_audio_now) for a Family host and a myGiG link passenger.
-- ============================================================================

-- ---- 1. Consent --------------------------------------------------------------------------------
create index if not exists profiles_phone_digits_idx
  on public.profiles (public.family_phone_digits(phone))
  where phone is not null;

create or replace function public.marketing_sms_consent(p_phone text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  with d as (select public.family_phone_digits(p_phone) as digits),
  live as (
    select p.news_offers
      from public.profiles p, d
     where d.digits is not null
       and public.family_phone_digits(p.phone) = d.digits
       and p.phone is not null
       and p.deleted_at is null
       and not p.store_review
  )
  select case
    when exists (select 1 from live where news_offers) then 'opted_in'
    when exists (select 1 from live) then 'not_opted_in'
    else 'no_account'
  end;
$$;
revoke execute on function public.marketing_sms_consent(text) from public, anon, authenticated;
grant execute on function public.marketing_sms_consent(text) to service_role;

-- ---- 2. The queue refuses marketing without consent ------------------------------------------------
create or replace function public.sms_outbox_marketing_consent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v text;
begin
  if new.channel is distinct from 'marketing' then
    return new;
  end if;
  v := public.marketing_sms_consent(new.to_phone);
  if v = 'opted_in' then
    return new;
  end if;
  raise exception 'MARKETING_NO_CONSENT' using errcode = '42501',
    hint = case when v = 'no_account'
                then 'This number has no GET.ride account, so it can''t be sent marketing SMS.'
                else 'This number hasn''t turned on News and offers, so it can''t be sent marketing SMS.' end;
end;
$$;
revoke execute on function public.sms_outbox_marketing_consent() from public, anon, authenticated;

drop trigger if exists trg_sms_outbox_marketing_consent on public.sms_outbox;
create trigger trg_sms_outbox_marketing_consent
  before insert or update of channel, to_phone on public.sms_outbox
  for each row execute function public.sms_outbox_marketing_consent();

-- ---- 3. The gateway never sends one whose consent has gone -------------------------------------
-- As 0190, plus the marketing step before the claim.
create or replace function public.gateway_claim_for(p_dev uuid, p_limit integer)
returns setof public.sms_outbox
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.messaging_devices set last_seen_at = now() where id = p_dev;

  -- A sign-in code is good for the admin's minutes: one still waiting after
  -- that is failed, not sent.
  update public.sms_outbox
     set status = 'failed', error = 'expired before sending'
   where channel = 'otp' and status in ('queued', 'sending')
     and created_at < now() - make_interval(mins => coalesce(
           (select code_valid_minutes from public.sms_settings where id = 1), 5));

  -- A marketing SMS whose number turned News and offers off (or whose
  -- account went) while it waited is failed, not sent (0335).
  update public.sms_outbox
     set status = 'failed', error = 'No News and offers consent'
   where channel = 'marketing'
     and (status = 'queued' or (status = 'sending' and claimed_at < now() - interval '5 minutes'))
     and public.marketing_sms_consent(to_phone) <> 'opted_in';

  return query
  with claimed as (
    update public.sms_outbox o
       set status = 'sending', device_id = p_dev, claimed_at = now(), attempts = o.attempts + 1
     where o.id in (
       select q.id from public.sms_outbox q
        join public.messaging_routes r
          on r.channel = q.channel and r.direction = 'outbound'
         and r.transport = 'sms' and r.enabled and p_dev = any(r.device_ids)
        where (q.status = 'queued'
               or (q.status = 'sending' and q.device_id = p_dev and q.claimed_at < now() - interval '5 minutes'))
          and q.attempts < 3
        order by q.created_at
        limit greatest(1, least(coalesce(p_limit, 10), 50))
        for update of q skip locked
     )
    returning o.*
  )
  select (jsonb_populate_record(null::public.sms_outbox,
            to_jsonb(c) || jsonb_build_object('body', coalesce(s.body, c.body)))).*
    from claimed c
    left join public.sms_otp_secret s on s.outbox_id = c.id;
end;
$$;
revoke execute on function public.gateway_claim_for(uuid, integer) from public, anon, authenticated;

-- ---- 4. The admin's marketing send -------------------------------------------------------------
create or replace function public.admin_queue_marketing_sms(p_phones text[], p_body text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_body text := btrim(coalesce(p_body, ''));
  v_phone text;
  v_digits text;
  v_seen text[] := '{}';
  v_queued int := 0;
  v_not_opted int := 0;
  v_no_account int := 0;
  v_invalid int := 0;
  v_consent text;
begin
  if not public.caller_admin_can_write('sms_outbox') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You can''t send marketing SMS.';
  end if;
  if char_length(v_body) not between 1 and 1600 then
    raise exception 'MARKETING_SMS_BODY' using errcode = '22023', hint = 'Write the message (up to 1600 characters).';
  end if;
  if coalesce(array_length(p_phones, 1), 0) > 10000 then
    raise exception 'MARKETING_SMS_TOO_MANY' using errcode = '22023', hint = 'Send to at most 10,000 numbers at a time.';
  end if;

  foreach v_phone in array coalesce(p_phones, '{}') loop
    v_digits := public.family_phone_digits(v_phone);
    if v_digits is null or v_digits !~ '^[0-9]{6,15}$' then
      v_invalid := v_invalid + 1;
      continue;
    end if;
    if v_digits = any(v_seen) then
      continue;
    end if;
    v_seen := v_seen || v_digits;
    v_consent := public.marketing_sms_consent(v_digits);
    if v_consent = 'opted_in' then
      insert into public.sms_outbox (channel, to_phone, body, created_by)
      values ('marketing', '+' || v_digits, v_body, auth.uid());
      v_queued := v_queued + 1;
    elsif v_consent = 'not_opted_in' then
      v_not_opted := v_not_opted + 1;
    else
      v_no_account := v_no_account + 1;
    end if;
  end loop;

  insert into public.admin_audit_log (actor_id, action, detail)
  values (auth.uid(), 'marketing_sms.queue',
          jsonb_build_object('queued', v_queued, 'notOptedIn', v_not_opted, 'noAccount', v_no_account,
                             'invalid', v_invalid));

  return jsonb_build_object(
    'queued', v_queued,
    'notOptedIn', v_not_opted,
    'noAccount', v_no_account,
    'invalid', v_invalid,
    'leftOut', v_not_opted + v_no_account + v_invalid);
end;
$$;
revoke execute on function public.admin_queue_marketing_sms(text[], text) from public, anon;
grant execute on function public.admin_queue_marketing_sms(text[], text) to authenticated;

create or replace function public.admin_marketing_sms_reach()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  return (
    select jsonb_build_object(
      'optedIn', count(*) filter (where p.news_offers),
      'withPhone', count(*))
      from public.profiles p
     where p.phone is not null and btrim(p.phone) <> ''
       and p.deleted_at is null and not p.store_review);
end;
$$;
revoke execute on function public.admin_marketing_sms_reach() from public, anon;
grant execute on function public.admin_marketing_sms_reach() to authenticated;

-- ---- 5. STOP -----------------------------------------------------------------------------------
create or replace function public.marketing_sms_is_stop(p_body text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select upper(btrim(regexp_replace(regexp_replace(coalesce(p_body, ''), '[^[:alpha:][:space:]]', '', 'g'),
                                    '[[:space:]]+', ' ', 'g')))
         in ('STOP', 'STOP ALL', 'UNSUBSCRIBE', 'BERHENTI');
$$;

create or replace function public.sms_inbox_marketing_stop()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_digits text := public.family_phone_digits(new.from_phone);
begin
  if v_digits is null or not public.marketing_sms_is_stop(new.body) then
    return new;
  end if;
  update public.profiles p
     set news_offers = false
   where p.news_offers
     and p.phone is not null
     and public.family_phone_digits(p.phone) = v_digits;
  update public.sms_outbox o
     set status = 'failed', error = 'Replied STOP'
   where o.channel = 'marketing' and o.status = 'queued'
     and public.family_phone_digits(o.to_phone) = v_digits;
  return new;
end;
$$;
revoke execute on function public.sms_inbox_marketing_stop() from public, anon, authenticated;

drop trigger if exists trg_sms_inbox_marketing_stop on public.sms_inbox;
create trigger trg_sms_inbox_marketing_stop
  after insert on public.sms_inbox
  for each row execute function public.sms_inbox_marketing_stop();

-- ---- 6. "Your driver is recording audio for safety" --------------------------------------------
-- The owner's decision (2 Nov 2026): the passenger is told, live, while the
-- driver's VoiceProtection records their trip.
--
-- ride_requests.driver_audio: the driver's phone is recording this trip now.
-- Set by that phone when its recorder has actually started (on), and when it
-- stops (off), with ride_set_driver_audio(ride, on). The row is what the
-- passenger's trip screen already reads (realtime), so whoever may read the
-- ride sees it: its passenger, its driver and admins; a Family viewer through
-- family_live (only members the host may see, family_can_view_location); a
-- myGiG passenger on their trip link through mygig_link_view.
alter table public.ride_requests add column if not exists driver_audio boolean not null default false;
comment on column public.ride_requests.driver_audio is
  'The driver''s VoiceProtection is recording this trip now (0335): set by the driver''s phone, off whenever the trip is not under way with that driver. The passenger is shown it.';

-- What the passenger is shown: recording, on a trip under way.
create or replace function public.ride_driver_audio_now(r public.ride_requests)
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(r.driver_audio, false) and r.status = 'on_trip' and r.partner_id is not null;
$$;
revoke execute on function public.ride_driver_audio_now(public.ride_requests) from public, anon, authenticated;

-- Only the trip's driver turns it on or off, and it is on only while the
-- trip is under way with that driver: whatever writes the row (the server,
-- an admin, the app), a trip that ends, is cancelled or is handed to another
-- driver turns it off, so a phone that never says "stopped" cannot leave a
-- notice behind. The passenger can neither fake it nor hide it. A new ride
-- starts with it off.
create or replace function public.ride_requests_driver_audio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status is distinct from 'on_trip' or new.partner_id is null
     or (tg_op = 'UPDATE' and new.partner_id is distinct from old.partner_id) then
    new.driver_audio := false;
    return new;
  end if;
  -- The session's role, as 0253 / 0315: this runs as its owner. The server
  -- (no app session) is trusted; every app session, an admin's included,
  -- goes through the driver's rule.
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.driver_audio := false;
    return new;
  end if;
  if new.driver_audio is distinct from old.driver_audio and auth.uid() is distinct from old.partner_id then
    raise exception 'DRIVER_AUDIO_DRIVER_ONLY' using errcode = '42501',
      hint = 'Only the trip''s driver says when their phone records.';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_driver_audio() from public, anon, authenticated;

-- Last of the BEFORE triggers (by name), so a status another one sets is the one it reads.
drop trigger if exists trg_ride_requests_zzzzzz_driver_audio on public.ride_requests;
create trigger trg_ride_requests_zzzzzz_driver_audio
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_driver_audio();

-- Rows from before this column that are somehow still under way start off.
update public.ride_requests set driver_audio = false where driver_audio and status is distinct from 'on_trip';

-- The driver's phone: recording started (true) or stopped (false). On only
-- while the trip is under way (DRIVER_AUDIO_NOT_ON_TRIP); off any time.
-- Answers what the ride now says.
create or replace function public.ride_set_driver_audio(p_ride uuid, p_on boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r public.ride_requests;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.partner_id is distinct from v_uid then
    raise exception 'DRIVER_AUDIO_DRIVER_ONLY' using errcode = '42501',
      hint = 'Only the trip''s driver says when their phone records.';
  end if;
  if coalesce(p_on, false) and r.status is distinct from 'on_trip' then
    raise exception 'DRIVER_AUDIO_NOT_ON_TRIP' using errcode = '42501',
      hint = 'Recording is shown only while the trip is under way.';
  end if;
  if coalesce(p_on, false) is distinct from r.driver_audio then
    update public.ride_requests set driver_audio = coalesce(p_on, false) where id = p_ride;
  end if;
  return coalesce(p_on, false);
end;
$$;
revoke execute on function public.ride_set_driver_audio(uuid, boolean) from public, anon;
grant execute on function public.ride_set_driver_audio(uuid, boolean) to authenticated;

-- family_live (0317's, unchanged otherwise): a member's trip says whether
-- the driver is recording it, for the host who may see that member.
create or replace function public.family_live()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  f public.families;
  m public.family_members;
  v jsonb := '[]'::jsonb;
  v_trip uuid;
  v_item jsonb;
begin
  select * into f from public.families where host_id = auth.uid();
  if not found then
    return v;
  end if;
  for m in select * from public.family_members where family_id = f.id and status = 'active' order by created_at loop
    if m.kind = 'member' and not public.family_can_view_location(f.host_id, m.profile_id) then
      continue;
    end if;
    v_trip := public.family_shared_trip(m.id);
    if m.kind = 'child' and v_trip is null then
      select t.trip_id into v_trip from public.family_trips t
       where t.member_id = m.id and t.ended_at is null and public.family_trip_live(t.trip_id)
       order by t.created_at desc limit 1;
    end if;
    v_item := jsonb_build_object('memberId', m.id, 'name', m.name, 'kind', m.kind);
    if v_trip is not null then
      v_item := v_item || coalesce((
        select jsonb_build_object('trip', r.id, 'status', r.status, 'pickup', r.pickup_name, 'drop', r.drop_name,
                                  'driver', r.partner_name, 'plate', r.partner_plate,
                                  'lat', r.partner_live_lat, 'lng', r.partner_live_lng, 'at', r.partner_live_at,
                                  -- 0335: the driver's VoiceProtection is recording now.
                                  'driverAudio', public.ride_driver_audio_now(r))
          from public.ride_requests r where r.id = v_trip),
        (select jsonb_build_object('trip', b.id, 'status', b.status, 'pickup', b.pickup_name, 'drop', b.drop_name)
           from public.c2c_bookings b where b.id = v_trip), '{}'::jsonb);
    elsif m.kind = 'member' and public.family_location_rule(m.id) = 'always' then
      v_item := v_item || coalesce((
        select jsonb_build_object('lat', pt.last_lat, 'lng', pt.last_lng, 'at', pt.located_at,
                                  'area', concat_ws(', ', pt.area_suburb, pt.area_city))
          from public.push_tokens pt
         where pt.profile_id = m.profile_id and pt.located_at is not null
         order by pt.located_at desc limit 1), '{}'::jsonb);
    else
      continue;
    end if;
    v := v || jsonb_build_array(v_item);
  end loop;
  return v;
end;
$$;
revoke execute on function public.family_live() from public, anon;
grant execute on function public.family_live() to authenticated;

-- mygig_link_view (0331's, unchanged otherwise): the passenger on their trip
-- link (no app, no sign-in) is told too.
create or replace function public.mygig_link_view(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o public.mygig_offers;
  c public.mygig_offers;
  r public.ride_requests;
  bk public.mygig_bookings;
  ra public.mygig_reassigns;
  v_wait int;
  q jsonb;
  h text := public.mygig_token_hash(p_token);
  v_driver uuid;
begin
  v_wait := public.auth_rate_take('mygig_link', coalesce(public.request_client_ip(), 'none'), 120, interval '10 minutes');
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait using errcode = 'P0001';
  end if;
  select * into o from public.mygig_offers where token_hash = h;
  if not found then
    -- A token from an earlier send: the ride it became still answers.
    select * into r from public.ride_requests x where x.mygig->>'tokenHash' = h
     order by x.created_at desc limit 1;
    -- 0331: a change-of-driver link.
    if r.id is null then
      select * into ra from public.mygig_reassigns where token_hash = h;
      if ra.id is not null and ra.ride_id is not null then
        select * into r from public.ride_requests where id = ra.ride_id;
      elsif ra.id is not null then
        select * into o from public.mygig_offers
         where id = (select b2.offer_id from public.mygig_bookings b2 where b2.id = ra.booking_id);
      end if;
    end if;
    if r.id is null and o.id is null then
      raise exception 'MYGIG_LINK' using errcode = 'P0002', hint = 'This link isn''t valid any more.';
    end if;
    if o.id is null then
      select * into o from public.mygig_offers where id = (r.mygig->>'offerId')::uuid;
    end if;
  end if;
  if o.booking_id is not null then
    select * into bk from public.mygig_bookings where id = o.booking_id;
    select x.* into r from public.mygig_booking_days d join public.ride_requests x on x.id = d.ride_id
     where d.booking_id = bk.id order by d.day_no desc limit 1;
  elsif o.ride_id is not null then
    select * into r from public.ride_requests where id = o.ride_id;
    -- A new price waiting for the passenger shows on the first link too.
    select * into c from public.mygig_offers x
     where x.ride_id = o.ride_id and x.kind = 'change' and x.status = 'waiting' and x.expires_at > now()
     order by x.created_at desc limit 1;
    if c.id is not null then
      o := c;
    end if;
  end if;
  if bk.id is not null then
    if bk.status in ('completed', 'cancelled', 'expired')
       and bk.updated_at < now() - make_interval(hours => coalesce((bk.quote->>'linkHours')::int, 24)) then
      raise exception 'MYGIG_LINK' using errcode = 'P0002', hint = 'This link has expired.';
    end if;
  elsif r.id is not null and r.status in ('completed', 'cancelled')
     and coalesce(r.completed_at, r.cancelled_at, r.updated_at)
         < now() - make_interval(hours => coalesce((r.mygig #>> '{quote,linkHours}')::int, 24)) then
    raise exception 'MYGIG_LINK' using errcode = 'P0002', hint = 'This link has expired.';
  end if;
  -- 0331: a change of driver waiting for the passenger.
  select * into ra from public.mygig_reassigns x
   where x.stage = 'passenger' and x.answer_by > now()
     and ((r.id is not null and x.ride_id = r.id) or (bk.id is not null and x.booking_id = bk.id))
   order by x.created_at desc limit 1;
  v_driver := coalesce(case when r.id is not null and r.status in ('accepted', 'arrived', 'on_trip', 'completed')
                            then r.partner_id end, bk.driver_id, o.driver_id);
  q := o.quote;
  return jsonb_build_object(
    'status', case when o.status = 'waiting' and o.expires_at <= now() then 'expired' else o.status end,
    'kind', o.kind,
    'name', case when o.passenger_id is null then split_part(coalesce(o.passenger_name, ''), ' ', 1) end,
    'driver', public.mygig_driver_card(v_driver),
    'trip', jsonb_build_object('pickup', (o.trip -> 'pickup') - 'here', 'drop', o.trip->'drop',
                               'stops', o.trip->'stops', 'round', o.trip->'round', 'pax', o.trip->'pax',
                               'bags', o.trip->'bags', 'pay', o.trip->'pay',
                               'directed', coalesce((o.trip->>'directed')::boolean, false)),
    'quote', jsonb_build_object('km', q->'km', 'min', q->'min', 'fare', q->'fare', 'busy', q->'busy',
                                'busyLabel', q->'busyLabel', 'luggage', q->'luggage', 'approach', q->'approach',
                                'approachKm', q->'approachKm', 'pickupFee', q->'pickupFee', 'dropFee', q->'dropFee',
                                'pickupFeeName', q->'pickupFeeName', 'dropFeeName', q->'dropFeeName',
                                'tax', q->'tax', 'taxName', q->'taxName', 'showTax', q->'showTax',
                                'rounded', q->'rounded', 'total', q->'total', 'guard', q->'guard',
                                'appPrice', case when (q->>'guard')::boolean then q->'appPrice' end,
                                'terms', q->'terms',
                                'hire', q->'hire', 'title', q->'title', 'hours', q->'hours',
                                'hoursPerDay', q->'hoursPerDay', 'days', q->'days', 'periods', q->'periods',
                                'weekdays', q->'weekdays', 'kmIncluded', q->'kmIncluded',
                                'overtimePerHour', q->'overtimePerHour', 'extraKm', q->'extraKm',
                                'overnightTotal', q->'overnightTotal', 'base', q->'base', 'placeFees', q->'placeFees'),
    'offerBooking', o.booking,
    'booking', case when bk.id is not null then public.mygig_booking_json(bk, 'link') end,
    'expiresAt', o.expires_at,
    'reassign', case when ra.id is not null then public.mygig_reassign_json(ra, 'link') end,
    'ride', case when r.id is not null then jsonb_build_object(
      'id', r.id,
      'status', r.status,
      'shareToken', (select x.share_token from public.ride_request_private x where x.request_id = r.id),
      'total', public.ride_amount_due(r),
      'paymentStatus', r.payment_status,
      'cancelFee', case when r.accepted_at < now() - make_interval(
                               secs => (coalesce((r.mygig #>> '{terms,cancelFreeMin}')::numeric, 2) * 60)::int)
                        then coalesce((r.mygig #>> '{terms,cancelFee}')::numeric, 0) else 0 end,
      'canCancel', r.status in ('accepted', 'arrived') and bk.id is null,
      'owed', public.mygig_owed(r), 'linkPaid', coalesce((r.mygig->>'linkPaid')::numeric, 0),
      'payUrl', case when public.mygig_owed(r) > 0 then r.mygig->>'payUrl' end,
      'dayNo', r.mygig->'dayNo', 'days', r.mygig->'days',
      'waitingCharge', coalesce(r.waiting_charge, 0) + coalesce((r.mygig->>'stopWaitCharge')::numeric, 0),
      -- 0335: the driver's VoiceProtection is recording now (ride_driver_audio_now).
      'driverAudio', public.ride_driver_audio_now(r)) end);
end;
$$;
revoke execute on function public.mygig_link_view(text) from public;
grant execute on function public.mygig_link_view(text) to anon, authenticated;

notify pgrst, 'reload schema';
