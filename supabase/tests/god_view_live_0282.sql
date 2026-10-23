-- ============================================================================
-- Regression test for migration 0282: God View's fresh phone details, Live
-- now and a new phone number from the admin panel.
--   * a ping's answer brings the phone's details (a user_sessions row with
--     the device's own columns kept), only when asked for, once in 20 s;
--     god_view_ping_answer says the details came;
--   * Live now: an admin with God View starts one share a person, the phone
--     streams with its key (one point in 4 s), the points reach the history,
--     Stop ends it and the phone is told; anyone else is refused; logged;
--   * a new number: only with EDIT on the Users pages, never one already in
--     use, an SMS with the link (masked for admins), the link moves the
--     sign-in number; an old or used link does nothing.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/god_view_live_0282.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if not has_function_privilege('anon', 'public.push_live_location(text, double precision, double precision, double precision, double precision)', 'execute')
     or not has_function_privilege('anon', 'public.push_background_details(text, jsonb)', 'execute')
     or not has_function_privilege('anon', 'public.phone_change_confirm(text)', 'execute')
     or not has_function_privilege('anon', 'public.phone_change_lookup(text)', 'execute')
     or has_function_privilege('anon', 'public.god_view_live_start(uuid, integer)', 'execute')
     or has_function_privilege('anon', 'public.admin_phone_change_request(uuid, text)', 'execute')
     or has_function_privilege('authenticated', 'public.god_view_live_tick()', 'execute')
     or has_function_privilege('authenticated', 'public.god_view_live_flush(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.god_view_live_start(uuid, integer)', 'execute') then
    raise exception 'FAILED: 0282 function grants';
  end if;
end
$$;

create function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'FAILED: %', what; end if;
end $$;
create function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
create function pg_temp.refused(p_sql text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return true;
end $$;
grant execute on function pg_temp.check(boolean, text) to anon, authenticated;
grant execute on function pg_temp.refused(text) to anon, authenticated;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000282a1', '60128200001'),  -- full admin
  ('00000000-0000-0000-0000-0000000282a2', '60128200002'),  -- sub-admin, READ on Users
  ('00000000-0000-0000-0000-0000000282b1', '60128200011'),  -- someone else, no admin
  ('00000000-0000-0000-0000-0000000282f1', '60128200021'),  -- the person
  ('00000000-0000-0000-0000-0000000282f2', '60128200022'),  -- no phone to go live with
  ('00000000-0000-0000-0000-0000000282f3', '60128200023')   -- holds a number already
on conflict do nothing;
insert into public.profiles (id, name, phone) select id, 'P282 ' || right(id::text, 2), '+' || phone from auth.users
 where id::text like '00000000-0000-0000-0000-0000000282%'
on conflict (id) do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000282a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000282a2', 'admin-users', 'read')
on conflict do nothing;
insert into public.push_tokens (profile_id, token, platform, device_key, last_lat, last_lng, located_at, located_bg,
                                location_always, bg_key_hash) values
  ('00000000-0000-0000-0000-0000000282f1', 'gv282-f1', 'android', 'dk282', 3.1, 101.6, now() - interval '1 hour', true,
   true, encode(extensions.digest('k282k282k282k282k282k282k282k282k282k282', 'sha256'), 'hex'));
insert into public.user_sessions (user_id, event_type, device_id, os_name, device_model_name, app_version, captured_at, raw) values
  ('00000000-0000-0000-0000-0000000282f1', 'app_launch', 'dev-282', 'android', 'SM-A546E', '1.4.0',
   now() - interval '2 days', '{"push_device_key": "dk282", "screen": "1080x2340", "battery_pct": 90}');

-- 1. Details on a ping's answer -----------------------------------------------------------------
select pg_temp.as_anon();
set local role anon;
select pg_temp.check(not public.push_background_details('k282k282k282k282k282k282k282k282k282k282',
                                                        '{"battery_pct": 40}'), 'details nobody asked for are refused');
reset role;
update public.push_tokens set ping_sent_at = now() where token = 'gv282-f1';
set local role anon;
select pg_temp.check(public.push_background_details('k282k282k282k282k282k282k282k282k282k282',
  '{"battery_pct": 41.6, "battery_charging": true, "network_type": "wifi", "app_version": "1.4.2",
    "perm_location": "always", "perm_notifications": false, "storage_free_bytes": 1000000, "junk": "x",
    "network_operator": "  CelcomDigi  ", "cellular_generation": "9G"}'), 'a ping''s details are taken');
select pg_temp.check(not public.push_background_details('k282k282k282k282k282k282k282k282k282k282', '{}'),
                     'once in 20 seconds');
select pg_temp.check(not public.push_background_details('nope', '{}'), 'a wrong key is refused');
reset role;
do $$
declare r public.user_sessions;
begin
  select * into r from public.user_sessions
   where user_id = '00000000-0000-0000-0000-0000000282f1' and event_type = 'ping';
  perform pg_temp.check(r.device_id = 'dev-282' and r.device_model_name = 'SM-A546E', 'the device''s own columns kept');
  perform pg_temp.check(r.app_version = '1.4.2' and r.network_type = 'wifi' and r.network_operator = 'CelcomDigi',
                        'the fresh columns');
  perform pg_temp.check(r.cellular_generation is null, 'an unknown value is dropped');
  perform pg_temp.check((r.raw ->> 'battery_pct')::int = 42 and (r.raw ->> 'battery_charging')::boolean
                        and r.raw ->> 'perm_location' = 'always' and (r.raw ->> 'perm_notifications') = 'false'
                        and r.raw ->> 'screen' = '1080x2340' and r.raw ->> 'push_device_key' = 'dk282',
                        'the card''s raw keys: ' || r.raw::text);
  perform pg_temp.check(not (r.raw ? 'junk'), 'nothing else');
end $$;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000282a1');
select pg_temp.check((public.god_view_ping_answer('00000000-0000-0000-0000-0000000282f1', now()) ->> 'details')::boolean,
                     'the ping answer says the details came');
select pg_temp.check(not (public.god_view_ping_answer('00000000-0000-0000-0000-0000000282f1', now() + interval '1 minute')
                          ->> 'details')::boolean, 'not before they did');

-- 2. Live now ------------------------------------------------------------------------------------
do $$
declare
  j jsonb := public.god_view_live_start('00000000-0000-0000-0000-0000000282f1', 15);
  again jsonb := public.god_view_live_start('00000000-0000-0000-0000-0000000282f1', 60);
  none jsonb := public.god_view_live_start('00000000-0000-0000-0000-0000000282f2', 5);
  big jsonb;
begin
  perform pg_temp.check((j ->> 'phones')::int = 1 and j -> 'session' ->> 'id' is not null, 'a share started: ' || j::text);
  perform pg_temp.check((j -> 'session' ->> 'ends_at')::timestamptz = now() + interval '15 minutes', '15 minutes');
  perform pg_temp.check((again ->> 'already')::boolean and again -> 'session' ->> 'id' = j -> 'session' ->> 'id',
                        'one share a person at a time');
  perform pg_temp.check((none ->> 'phones')::int = 0 and none -> 'session' = 'null'::jsonb, 'no phone, no share');
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000282b1');
select pg_temp.check(pg_temp.refused($q$select public.god_view_live_start('00000000-0000-0000-0000-0000000282f1', 5)$q$),
                     'someone without God View is refused');
select pg_temp.check(pg_temp.refused($q$select public.god_view_live_status('00000000-0000-0000-0000-0000000282f1', 0)$q$),
                     'and cannot read it');
select pg_temp.check((select count(*) from public.god_view_live_points) = 0, 'no points yet');
reset role;

select pg_temp.as_anon();
set local role anon;
do $$
declare
  a jsonb := public.push_live_location('k282k282k282k282k282k282k282k282k282k282', 3.2, 101.7, 4.5, 8);
  b jsonb := public.push_live_location('k282k282k282k282k282k282k282k282k282k282', 3.3, 101.8);
  c jsonb := public.push_live_location('wrongwrongwrongwrongwrongwrongwrongwrong', 3.3, 101.8);
begin
  perform pg_temp.check((a ->> 'live')::boolean and (a ->> 'taken')::boolean and (a ->> 'ends_in')::int > 800,
                        'the first point is taken: ' || a::text);
  perform pg_temp.check((b ->> 'live')::boolean and not (b ->> 'taken')::boolean, 'one in 4 seconds');
  perform pg_temp.check(not (c ->> 'live')::boolean, 'another key is not live');
end $$;
reset role;
update public.god_view_live_sessions set last_point_at = now() - interval '5 seconds'
 where profile_id = '00000000-0000-0000-0000-0000000282f1';
select pg_temp.as_anon();
set local role anon;
select pg_temp.check((public.push_live_location('k282k282k282k282k282k282k282k282k282k282', 3.3, 101.8) ->> 'taken')::boolean,
                     'the next point after 4 seconds');
reset role;
select pg_temp.check((select last_lat from public.push_tokens where token = 'gv282-f1') = 3.3, 'the phone moved on the map');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000282f1');
select pg_temp.check(public.my_live_share() ->> 'id' is not null, 'the person sees their share');
select pg_temp.as_user('00000000-0000-0000-0000-0000000282a1');
do $$
declare
  st jsonb := public.god_view_live_status('00000000-0000-0000-0000-0000000282f1', 0);
  first_id bigint := (st -> 'points' -> 0 ->> 0)::bigint;
  later jsonb := public.god_view_live_status('00000000-0000-0000-0000-0000000282f1', first_id);
  stopped jsonb;
begin
  perform pg_temp.check(jsonb_array_length(st -> 'points') = 2 and (st -> 'session' ->> 'points')::int = 2,
                        'two points: ' || st::text);
  perform pg_temp.check(jsonb_array_length(later -> 'points') = 1, 'only the points after the one given');
  stopped := public.god_view_live_stop((st -> 'session' ->> 'id')::uuid);
  perform pg_temp.check(stopped ->> 'stopped_at' is not null and stopped ->> 'stop_reason' = 'admin', 'stopped');
end $$;
reset role;
select pg_temp.check((select count(*) from public.user_location_history
                       where user_id = '00000000-0000-0000-0000-0000000282f1') = 2, 'the points are in the history');
select pg_temp.check((select bool_and(in_history) from public.god_view_live_points), 'and marked so');
select pg_temp.as_anon();
set local role anon;
select pg_temp.check(not (public.push_live_location('k282k282k282k282k282k282k282k282k282k282', 3.4, 101.9) ->> 'live')::boolean,
                     'the phone is told the share is over');
reset role;
select pg_temp.check((select count(*) from public.admin_audit_log
                       where target_profile_id = '00000000-0000-0000-0000-0000000282f1'
                         and action in ('god_view.live_start', 'god_view.live_stop')) = 2, 'start and stop are logged');

-- A share past its time ends by itself.
insert into public.god_view_live_sessions (profile_id, started_at, ends_at)
values ('00000000-0000-0000-0000-0000000282f2', now() - interval '20 minutes', now() - interval '5 minutes');
select public.god_view_live_tick();
select pg_temp.check((select stop_reason from public.god_view_live_sessions
                       where profile_id = '00000000-0000-0000-0000-0000000282f2') = 'expired', 'expired by the tick');

-- 3. A new phone number ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000282a2');
select pg_temp.check(pg_temp.refused($q$select public.admin_phone_change_request('00000000-0000-0000-0000-0000000282f1', '+60 12-820 9999')$q$),
                     'READ on Users cannot change a number');
select pg_temp.check(public.admin_phone_change_status('00000000-0000-0000-0000-0000000282f1') is null,
                     'but can see there is none waiting');
select pg_temp.as_user('00000000-0000-0000-0000-0000000282b1');
select pg_temp.check(pg_temp.refused($q$select public.admin_phone_change_status('00000000-0000-0000-0000-0000000282f1')$q$),
                     'someone else cannot see it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000282a1');
select pg_temp.check(pg_temp.refused($q$select public.admin_phone_change_request('00000000-0000-0000-0000-0000000282f1', '+60128200023')$q$),
                     'a number in use is refused');
select pg_temp.check(pg_temp.refused($q$select public.admin_phone_change_request('00000000-0000-0000-0000-0000000282f1', '+60128200021')$q$),
                     'their own number is refused');
select pg_temp.check(pg_temp.refused($q$select public.admin_phone_change_request('00000000-0000-0000-0000-0000000282f1', '12')$q$),
                     'not a number');
do $$
declare j jsonb := public.admin_phone_change_request('00000000-0000-0000-0000-0000000282f1', '+60 12-820 9999');
begin
  perform pg_temp.check(j ->> 'status' = 'waiting' and j ->> 'phone_tail' = '9999', 'waiting: ' || j::text);
  perform pg_temp.check(public.admin_phone_change_status('00000000-0000-0000-0000-0000000282f1') ->> 'status' = 'waiting',
                        'the status says so');
end $$;
select pg_temp.check(pg_temp.refused($q$select public.admin_phone_change_request('00000000-0000-0000-0000-0000000282f1', '+60128209998')$q$),
                     'one text a minute a person');
reset role;
do $$
declare
  b text := (select body from public.sms_outbox where to_phone = '+60128209999');
  token text := substring(b from 'number/([0-9a-f]+)');
  l jsonb;
  c jsonb;
begin
  perform pg_temp.check(b like '%https://getride.my/number/%', 'the SMS carries the link: ' || coalesce(b, 'none'));
  perform pg_temp.check((select channel from public.sms_outbox where to_phone = '+60128209999') = 'otp',
                        'queued as a code, masked for admins');
  perform pg_temp.check(length(token) = 36, 'the token');
  perform pg_temp.as_anon();
  set local role anon;
  l := public.phone_change_lookup(token);
  perform pg_temp.check(l ->> 'status' = 'waiting' and l ->> 'phone_masked' = '+60 ••• 9999' and not (l ? 'id'),
                        'the page: ' || l::text);
  perform pg_temp.check(public.phone_change_lookup('x' || token) ->> 'status' = 'unknown', 'a wrong link');
  c := public.phone_change_confirm(token);
  perform pg_temp.check(c ->> 'status' = 'confirmed', 'confirmed: ' || c::text);
  perform pg_temp.check(public.phone_change_confirm(token) ->> 'status' = 'confirmed', 'twice is harmless');
  reset role;
end $$;
select pg_temp.check((select phone from auth.users where id = '00000000-0000-0000-0000-0000000282f1') = '60128209999',
                     'the sign-in number moved');
select pg_temp.check((select regexp_replace(phone, '\D', '', 'g') from public.profiles
                       where id = '00000000-0000-0000-0000-0000000282f1') = '60128209999', 'the profile follows');
select pg_temp.check(not exists (select 1 from auth.users where phone = '60128200021'), 'the old number signs in no one');
update public.phone_change_requests set expires_at = now() - interval '1 minute', confirmed_at = null, created_at = now() - interval '2 days';
do $$
declare token text := substring((select body from public.sms_outbox where to_phone = '+60128209999') from 'number/([0-9a-f]+)');
begin
  perform pg_temp.check(pg_temp.refused(format('select public.phone_change_confirm(%L)', token)), 'an expired link does nothing');
end $$;

select 'god_view_live_0282: all passed';
rollback;
