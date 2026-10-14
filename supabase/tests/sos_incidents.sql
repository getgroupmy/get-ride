-- ============================================================================
-- Regression test for migration 0193: an SOS raises a safety incident that
-- alerts the on-call admins (push) and the ops numbers (SMS), is sent again
-- to every full admin until acknowledged, keeps the reporter's location,
-- and is never shown to the other person on the ride.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sos_incidents.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000193a1'),  -- passenger
  ('00000000-0000-0000-0000-0000000193b1'),  -- driver
  ('00000000-0000-0000-0000-0000000193c1'),  -- on-call admin (sub-admin)
  ('00000000-0000-0000-0000-0000000193c2'),  -- full admin, not on call
  ('00000000-0000-0000-0000-0000000193d1')   -- stranger
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000193%'
on conflict do nothing;
update public.profiles set name = 'Siti', phone = '+60100000193' where id = '00000000-0000-0000-0000-0000000193a1';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000193c1', 'admin-rides', 'edit'),
  ('00000000-0000-0000-0000-0000000193c2', '*', 'edit')
on conflict do nothing;
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name, drop_name,
                                  partner_name, partner_plate) values
  ('00000000-0000-0000-0000-0000000193e1', '00000000-0000-0000-0000-0000000193a1',
   '00000000-0000-0000-0000-0000000193b1', 'on_trip', 20, 20, 'KLCC', 'Cheras', 'Ali', 'WXY1234');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text) to authenticated;
create temp table ids (k text primary key, id uuid);
grant all on ids to authenticated;

-- 1. Settings are the admins' ------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000193a1');
select pg_temp.refused($q$select public.admin_sos_ops_config()$q$, 'a passenger reading the on-call list');
select pg_temp.refused($q$select public.set_sos_ops_config('{}')$q$, 'a passenger changing SOS alerts');
select pg_temp.as_user('00000000-0000-0000-0000-0000000193c2');
select public.set_sos_ops_config(jsonb_build_object(
  'onCall', jsonb_build_array('00000000-0000-0000-0000-0000000193c1', 'not-a-uuid'),
  'smsNumbers', jsonb_build_array('+60111111111', '+60122222222', 'bad'),
  'smsEnabled', true, 'realertMinutes', 2, 'locationMinutes', 30));
select pg_temp.check(jsonb_array_length(public.admin_sos_ops_config()->'onCall') = 1
                     and jsonb_array_length(public.admin_sos_ops_config()->'smsNumbers') = 2,
  'the lists keep only real ids and numbers');

-- 2. The passenger presses SOS --------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000193a1');
insert into ids select 'inc', public.sos_raise('00000000-0000-0000-0000-0000000193e1', 3.15, 101.71);
select pg_temp.check((select reporter_role = 'rider' and plate = 'WXY1234' and partner_name = 'Ali'
                             and reporter_name = 'Siti' and status = 'open' and alert_round = 1
                             and track_until > now() + interval '29 minutes'
                        from public.safety_incidents where id = (select id from ids where k = 'inc')),
  'an incident with the ride, the plate and both people');
select pg_temp.check((select count(*) = 1 from public.safety_incidents), 'the reporter sees their own incident');
select pg_temp.check(public.sos_raise('00000000-0000-0000-0000-0000000193e1', 3.16, 101.72) = (select id from ids where k = 'inc'),
  'pressing again within ten minutes is the same incident');
select pg_temp.check(public.sos_location((select id from ids where k = 'inc'), 3.17, 101.73), 'the location keeps coming');

select pg_temp.as_user('00000000-0000-0000-0000-0000000193b1');
select pg_temp.check((select count(*) = 0 from public.safety_incidents), 'the driver is not told');
select pg_temp.check(not public.sos_location((select id from ids where k = 'inc'), 1, 1), 'nor can they move it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000193d1');
select pg_temp.refused($q$select public.sos_acknowledge((select id from ids where k = 'inc'))$q$, 'a stranger acknowledging');
reset role;

select pg_temp.check((select lat = 3.17 from public.safety_incidents where id = (select id from ids where k = 'inc')),
  'the latest place is on the incident');
select pg_temp.check((select count(*) = 3 from public.safety_incident_locations where incident_id = (select id from ids where k = 'inc')),
  'and the trail is kept');
select pg_temp.check((select count(*) = 1 from public.notification_outbox
                       where profile_id = '00000000-0000-0000-0000-0000000193c1' and priority = 'critical'),
  'the on-call admin gets a critical push');
select pg_temp.check((select count(*) = 0 from public.notification_outbox
                       where profile_id = '00000000-0000-0000-0000-0000000193c2'),
  'a full admin not on call is not woken on the first round');
select pg_temp.check((select count(*) = 0 from public.notification_outbox
                       where profile_id = '00000000-0000-0000-0000-0000000193b1'),
  'nothing reaches the driver');
select pg_temp.check((select count(*) = 2 and bool_and(body like '%WXY1234%' and body like '%maps.google.com%')
                        from public.sms_outbox where channel = 'ops_alert'),
  'each ops number gets an SMS with the plate and the map');

-- 3. Unanswered: again, to every full admin; then acknowledged, no more -------------------------------
update public.safety_incidents set last_alert_at = now() - interval '3 minutes' where id = (select id from ids where k = 'inc');
select pg_temp.check(public.sos_realert() = 1, 'an unanswered SOS is sent again');
select pg_temp.check((select count(*) = 1 from public.notification_outbox
                       where profile_id = '00000000-0000-0000-0000-0000000193c2' and priority = 'critical'),
  'the second round reaches every full admin');
select pg_temp.check((select count(*) = 4 from public.sms_outbox where channel = 'ops_alert'), 'and the ops numbers again');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000193c1');
select pg_temp.check((select count(*) = 1 from public.safety_incidents), 'admins see the incident');
select public.sos_acknowledge((select id from ids where k = 'inc'));
reset role;
update public.safety_incidents set last_alert_at = now() - interval '10 minutes' where id = (select id from ids where k = 'inc');
select pg_temp.check(public.sos_realert() = 0, 'an acknowledged SOS is not sent again');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000193c2');
select public.sos_resolve((select id from ids where k = 'inc'), 'Called the passenger; safe.');
reset role;
select pg_temp.check((select status = 'resolved' and note like 'Called%' and acknowledged_by = '00000000-0000-0000-0000-0000000193c1'
                        from public.safety_incidents where id = (select id from ids where k = 'inc')),
  'resolved, keeping who acknowledged it');

-- 4. Raised without a ride, and by someone not on the ride --------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000193d1');
insert into ids select 'inc2', public.sos_raise('00000000-0000-0000-0000-0000000193e1', null, null);
reset role;
select pg_temp.check((select reporter_role = 'user' and ride_id is null and plate is null
                        from public.safety_incidents where id = (select id from ids where k = 'inc2')),
  'someone else''s ride is not attached to their SOS');
select pg_temp.check(not has_function_privilege('authenticated', 'public.sos_realert()', 'execute')
                 and not has_function_privilege('authenticated', 'public.sos_alert(uuid)', 'execute')
                 and not has_function_privilege('anon', 'public.sos_raise(uuid, double precision, double precision)', 'execute'),
  'only the server sends alerts');

select 'sos_incidents: all passed';
rollback;
