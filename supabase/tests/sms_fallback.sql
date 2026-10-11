-- ============================================================================
-- Regression test for migration 0150: a trip alert the app never confirmed
-- goes out once as an SMS through the gateway phone, within the limits.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sms_fallback.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000150a1'),  -- rider, with a number
  ('00000000-0000-0000-0000-0000000150b1'),  -- driver, no number anywhere
  ('00000000-0000-0000-0000-0000000150c1'),  -- admin
  ('00000000-0000-0000-0000-0000000150d1')   -- gateway phone's account
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000150%'
on conflict do nothing;
update public.profiles set phone = '+60 12-345 0150' where id = '00000000-0000-0000-0000-0000000150a1';
update public.profiles set phone = null where id = '00000000-0000-0000-0000-0000000150b1';
insert into public.admin_access (profile_id, page) values ('00000000-0000-0000-0000-0000000150c1', 'admin-messaging')
on conflict do nothing;

insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, partner_name, partner_plate, pickup_name)
values ('00000000-0000-0000-0000-0000000150e1', '00000000-0000-0000-0000-0000000150a1',
        '00000000-0000-0000-0000-0000000150b1', 'arrived', 20, 20, 'Ali', 'ABC1234', 'KLCC');

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

-- An unconfirmed alert, [age] old.
create or replace function pg_temp.alert(p_event text, p_to uuid, p_age interval,
                                         p_priority text default 'critical', p_status text default 'arrived')
returns uuid language sql as $$
  insert into public.notification_outbox (event_id, profile_id, request_id, kind, priority, title, body, data,
                                          created_at, expires_at)
  values (p_event, p_to, '00000000-0000-0000-0000-0000000150e1', 'ride_status', p_priority,
          'Your driver has arrived', 'ABC1234 is waiting at KLCC.',
          jsonb_build_object('type', 'ride_status', 'request_id', '00000000-0000-0000-0000-0000000150e1',
                             'status', p_status),
          now() - p_age, now() - p_age + interval '10 minutes')
  returning id;
$$;

create or replace function pg_temp.sms(p uuid) returns public.notification_outbox language sql as $$
  select * from public.notification_outbox where id = p;
$$;

-- A clean slate: default sign-in limits, no gateway phone, the fallback off.
update public.sms_settings set enabled = true, allowed_prefixes = '{+60}', blocked_numbers = '{}';
update public.sms_fallback_settings set enabled = false, after_seconds = 60, critical_only = true,
  channel = 'otp', per_phone_per_hour = 6;
delete from public.messaging_routes where channel = 'otp';

do $$
declare
  rider constant uuid := '00000000-0000-0000-0000-0000000150a1';
  driver constant uuid := '00000000-0000-0000-0000-0000000150b1';
  a uuid;
  b uuid;
  c uuid;
  d uuid;
  q uuid;
begin
  a := pg_temp.alert('150:arrived:r', rider, interval '90 seconds');

  -- 1. Off by default: nothing goes ----------------------------------------------
  perform pg_temp.check(public.dispatch_sms_fallback() = 0, 'off: nothing sent');
  perform pg_temp.check((pg_temp.sms(a)).sms_at is null, 'off: alert untouched');

  -- 2. On, but no gateway phone: it waits rather than queue for nobody ----------
  update public.sms_fallback_settings set enabled = true;
  perform pg_temp.check(public.dispatch_sms_fallback() = 0, 'no gateway: nothing sent');
  perform pg_temp.check((pg_temp.sms(a)).sms_at is null, 'no gateway: still waiting');

  insert into public.messaging_devices (id, user_id, device_id, label, kind, capabilities, last_seen_at)
  values ('00000000-0000-0000-0000-0000000150f1', '00000000-0000-0000-0000-0000000150d1', 'gw-150', 'Gateway',
          'gateway', '{sms}', now());
  insert into public.messaging_routes (channel, direction, transport, enabled, device_ids)
  values ('otp', 'outbound', 'sms', true, array['00000000-0000-0000-0000-0000000150f1'::uuid]);

  -- 3. Too young, already confirmed, or not critical: not sent -----------------------
  b := pg_temp.alert('150:young:r', rider, interval '10 seconds');
  c := pg_temp.alert('150:normal:r', rider, interval '90 seconds', 'normal');
  d := pg_temp.alert('150:seen:r', rider, interval '90 seconds');
  update public.notification_outbox set delivered_at = now() where id = d;

  -- 4. The unconfirmed critical alert goes, once, to the rider's number -------------
  perform pg_temp.check(public.dispatch_sms_fallback() = 1, 'one alert sent');
  perform pg_temp.check((pg_temp.sms(a)).sms_status = 'queued', 'alert marked queued');
  perform pg_temp.check((pg_temp.sms(a)).sms_phone = '+60123450150', 'to the rider''s number');
  q := (pg_temp.sms(a)).sms_outbox_id;
  perform pg_temp.check(
    (select to_phone = '+60123450150' and channel = 'otp' and body like 'GET.ride: Your driver has arrived.%'
       from public.sms_outbox where id = q),
    'queued on the gateway route with the alert''s words');
  perform pg_temp.check((pg_temp.sms(b)).sms_at is null, 'a young alert waits');
  perform pg_temp.check((pg_temp.sms(c)).sms_at is null, 'a normal alert is not sent while critical only');
  perform pg_temp.check((pg_temp.sms(d)).sms_at is null, 'a confirmed alert is not sent');
  perform pg_temp.check(public.dispatch_sms_fallback() = 0, 'never sent twice');

  -- 5. All alerts, when the admin says so --------------------------------------------
  update public.sms_fallback_settings set critical_only = false;
  perform pg_temp.check(public.dispatch_sms_fallback() = 1, 'normal alert sent once allowed');

  -- 6. The trip moved on: skipped, not sent ----------------------------------------------
  b := pg_temp.alert('150:old-status:r', rider, interval '90 seconds', 'critical', 'accepted');
  perform pg_temp.check(public.dispatch_sms_fallback() = 0, 'moved on: nothing sent');
  perform pg_temp.check((pg_temp.sms(b)).sms_status = 'skipped' and (pg_temp.sms(b)).sms_reason = 'moved_on',
                        'moved on: skipped with reason');

  -- 7. Nobody's number: skipped ------------------------------------------------------------
  b := pg_temp.alert('150:arrived:p', driver, interval '90 seconds');
  perform public.dispatch_sms_fallback();
  perform pg_temp.check((pg_temp.sms(b)).sms_reason = 'no_number', 'no number: skipped');

  -- 8. Per-number cap ------------------------------------------------------------------------
  update public.sms_fallback_settings set per_phone_per_hour = 2;
  b := pg_temp.alert('150:cap:r', rider, interval '90 seconds');
  perform public.dispatch_sms_fallback();
  perform pg_temp.check((pg_temp.sms(b)).sms_reason = 'per_phone_hour', 'over the hourly cap: skipped');

  -- 9. The sign-in limits' country list applies ---------------------------------------------
  update public.sms_fallback_settings set per_phone_per_hour = 30;
  update public.sms_settings set allowed_prefixes = '{+65}';
  b := pg_temp.alert('150:prefix:r', rider, interval '90 seconds');
  perform public.dispatch_sms_fallback();
  perform pg_temp.check((pg_temp.sms(b)).sms_reason = 'prefix', 'a country not allowed: skipped');
end $$;

-- 10. Only an admin reads or changes the settings, or sees the summary ----------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000150a1');
select pg_temp.check((select count(*) = 0 from public.sms_fallback_settings), 'a rider can''t read the settings');
update public.sms_fallback_settings set enabled = false;
select pg_temp.as_user('00000000-0000-0000-0000-0000000150c1');
select pg_temp.check((select enabled from public.sms_fallback_settings), 'the rider''s update changed nothing');
select pg_temp.check((select sms_queued >= 2 from public.sms_fallback_summary(24)), 'the admin sees what was sent');
update public.sms_fallback_settings set after_seconds = 120;
select pg_temp.check((select after_seconds = 120 and updated_by = '00000000-0000-0000-0000-0000000150c1'
                        from public.sms_fallback_settings), 'the admin changes the wait');
select pg_temp.as_user('00000000-0000-0000-0000-0000000150a1');
do $$
begin
  begin
    perform public.sms_fallback_summary(24);
  exception when others then
    return;
  end;
  raise exception 'FAILED: a rider read the summary';
end $$;
reset role;

-- 11. Nobody but the database runs the fallback itself ---------------------------------------
select pg_temp.check(not has_function_privilege('authenticated', 'public.dispatch_sms_fallback(timestamptz)', 'execute'),
                     'clients can''t run the fallback');
select pg_temp.check(not has_function_privilege('anon', 'public.sms_fallback_summary(int)', 'execute'),
                     'anon can''t read the summary');

rollback;
