-- ============================================================================
-- Regression test for migration 0276: God View "Still there?" pings. Who
-- may change the God View settings (full admins) and how they are clamped;
-- when a phone last moved (more than 200 m); "Always on" for a quiet phone
-- with location always and the background key, for the admin's hours, then
-- "Last known"; "Ping now" only for someone the caller may see, each phone
-- at most once in 2 minutes, logged, never a phone number; the scheduled run
-- claiming only the phones due (key, always, FCM token, live account, older
-- than the admin's minutes, not pinged since) and nothing while pings are
-- off; what the function is handed (service role only); the answer.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/god_view_ping_0276.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if not has_function_privilege('authenticated', 'public.god_view_ping(uuid)', 'execute')
     or has_function_privilege('anon', 'public.god_view_ping(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.god_view_ping_answer(uuid, timestamptz)', 'execute')
     or has_function_privilege('anon', 'public.god_view_ping_answer(uuid, timestamptz)', 'execute')
     or not has_function_privilege('authenticated', 'public.god_view_save_settings(boolean, integer, integer)', 'execute')
     or has_function_privilege('anon', 'public.god_view_save_settings(boolean, integer, integer)', 'execute')
     or has_function_privilege('authenticated', 'public.location_ping_targets(uuid[])', 'execute')
     or has_function_privilege('anon', 'public.location_ping_targets(uuid[])', 'execute')
     or not has_function_privilege('service_role', 'public.location_ping_targets(uuid[])', 'execute')
     or has_function_privilege('authenticated', 'public.location_ping_due()', 'execute')
     or has_function_privilege('authenticated', 'public.location_ping_kick(uuid[], text)', 'execute')
     or has_function_privilege('anon', 'public.location_ping_kick(uuid[], text)', 'execute')
     or has_function_privilege('authenticated', 'public.god_view_settings()', 'execute')
     or has_function_privilege('authenticated', 'public.god_view_people(double precision[], boolean, text, uuid, boolean, jsonb, polygon[])', 'execute')
     or has_function_privilege('anon', 'public.god_view_snapshot(double precision, double precision, double precision, double precision, boolean, text, integer)', 'execute') then
    raise exception 'FAILED: 0276 function grants';
  end if;
  if exists (select 1 from pg_extension where extname = 'pg_cron')
     and not exists (select 1 from cron.job where jobname = 'god-view-location-ping' and schedule = '*/5 * * * *') then
    raise exception 'FAILED: the ping job every 5 minutes';
  end if;
end
$$;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000276a1', '60127600001'),  -- full admin
  ('00000000-0000-0000-0000-0000000276a2', '60127600002'),  -- God View, North 276
  ('00000000-0000-0000-0000-0000000276a3', '60127600003'),  -- full admin, read only
  ('00000000-0000-0000-0000-0000000276f1', '60127600011'),  -- always + key, background 2 h ago
  ('00000000-0000-0000-0000-0000000276f2', '60127600012'),  -- always + key, background 13 h ago
  ('00000000-0000-0000-0000-0000000276f3', '60127600013'),  -- always, no key, background 2 h ago
  ('00000000-0000-0000-0000-0000000276f4', '60127600014'),  -- always + key, the open app 2 h ago
  ('00000000-0000-0000-0000-0000000276f5', '60127600015'),  -- always + key, background 5 min ago
  ('00000000-0000-0000-0000-0000000276f6', '60127600016'),  -- always + key, deleted account
  ('00000000-0000-0000-0000-0000000276f7', '60127600017'),  -- always + key, Southland (outside North)
  ('00000000-0000-0000-0000-0000000276f8', '60127600018'),  -- always + key, 8 days ago
  ('00000000-0000-0000-0000-0000000276b1', '60127600021')   -- moves
on conflict do nothing;
insert into public.profiles (id, name, phone)
select id, 'GV276 ' || right(id::text, 2), '+' || phone from auth.users
 where id::text like '00000000-0000-0000-0000-0000000276%'
on conflict (id) do update set name = excluded.name, phone = excluded.phone;
update public.profiles set deleted_at = now() where id = '00000000-0000-0000-0000-0000000276f6';

insert into public.admin_access (profile_id, page, access_level, region) values
  ('00000000-0000-0000-0000-0000000276a1', '*', 'edit', null),
  ('00000000-0000-0000-0000-0000000276a2', 'admin-god-view', 'read', '{"country": "Testland 276", "state": "North 276"}'),
  ('00000000-0000-0000-0000-0000000276a3', '*', 'read', null)
on conflict do nothing;

-- North 276: lng 140..141, lat 40..41.
insert into public.countries (name) values ('Testland 276') on conflict do nothing;
insert into public.states (country, name) values ('Testland 276', 'North 276'), ('Testland 276', 'Southland 276')
on conflict do nothing;
update public.states set boundary_polys = array['((140,40),(141,40),(141,41),(140,41))'::polygon]
 where country = 'Testland 276' and name = 'North 276';

insert into public.push_tokens (profile_id, token, platform, last_lat, last_lng, located_at, located_bg,
                                location_always, bg_key_hash, area_country, area_state) values
  ('00000000-0000-0000-0000-0000000276f1', 'gv276-f1', 'ios', 40.1, 140.1, now() - interval '2 hours', true, true, 'h276f1', 'Testland 276', 'North 276'),
  ('00000000-0000-0000-0000-0000000276f1', 'gv276-f1-voip', 'ios_voip', 40.1, 140.1, now() - interval '2 hours', true, true, 'h276f1', 'Testland 276', 'North 276'),
  ('00000000-0000-0000-0000-0000000276f2', 'gv276-f2', 'android', 40.2, 140.2, now() - interval '13 hours', true, true, 'h276f2', null, null),
  ('00000000-0000-0000-0000-0000000276f3', 'gv276-f3', 'ios', 40.3, 140.3, now() - interval '2 hours', true, true, null, null, null),
  ('00000000-0000-0000-0000-0000000276f4', 'gv276-f4', 'android', 40.4, 140.4, now() - interval '2 hours', false, true, 'h276f4', null, null),
  ('00000000-0000-0000-0000-0000000276f5', 'gv276-f5', 'ios', 40.5, 140.5, now() - interval '5 minutes', true, true, 'h276f5', null, null),
  ('00000000-0000-0000-0000-0000000276f6', 'gv276-f6', 'ios', 40.6, 140.6, now() - interval '2 hours', true, true, 'h276f6', null, null),
  ('00000000-0000-0000-0000-0000000276f7', 'gv276-f7', 'ios', 45.0, 145.0, now() - interval '2 hours', true, true, 'h276f7', 'Testland 276', 'Southland 276'),
  ('00000000-0000-0000-0000-0000000276f8', 'gv276-f8', 'ios', 40.8, 140.8, now() - interval '8 days', true, true, 'h276f8', null, null);

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
create or replace function pg_temp.mine(p jsonb) returns jsonb language sql as $$
  select coalesce(jsonb_object_agg(x->>'id', x), '{}'::jsonb)
    from jsonb_array_elements(p->'people') x where x->>'id' like '00000000-0000-0000-0000-0000000276%'
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text),
  pg_temp.refused(text, text), pg_temp.mine(jsonb) to anon, authenticated, service_role;

-- 1. When the phone last moved ---------------------------------------------------------------------
insert into public.push_tokens (profile_id, token, platform, last_lat, last_lng, located_at)
values ('00000000-0000-0000-0000-0000000276b1', 'gv276-m1', 'ios', 40.9, 140.9, now() - interval '1 hour');
select pg_temp.check((select moved_at = now() - interval '1 hour' and moved_lat = 40.9 from public.push_tokens
                       where token = 'gv276-m1'), 'a first position is a move');
update public.push_tokens set last_lat = 40.9009, located_at = now() - interval '30 minutes' where token = 'gv276-m1';
select pg_temp.check((select moved_at = now() - interval '1 hour' and moved_lat = 40.9 from public.push_tokens
                       where token = 'gv276-m1'), '100 m is not a move');
update public.push_tokens set last_lat = 40.9015, located_at = now() - interval '20 minutes' where token = 'gv276-m1';
select pg_temp.check((select moved_at = now() - interval '1 hour' from public.push_tokens where token = 'gv276-m1'),
  'creeping 100 m at a time is measured from where it last moved (200 m)');
update public.push_tokens set last_lat = 40.903, located_at = now() - interval '10 minutes' where token = 'gv276-m1';
select pg_temp.check((select moved_at = now() - interval '10 minutes' and moved_lat = 40.903 from public.push_tokens
                       where token = 'gv276-m1'), 'over 200 m is a move');
select pg_temp.check((select count(*) = 0 from public.push_tokens
                       where located_at is not null and last_lat is not null and moved_at is null),
  'every located row has moved_at');
delete from public.push_tokens where token = 'gv276-m1';

-- 2. The settings ----------------------------------------------------------------------------------
update public.admin_display_settings set settings = settings - 'godView' || '{"keep276": 1}' where id = 'global';
select pg_temp.check(public.god_view_settings() = '{"pings": true, "pingMinutes": 30, "alwaysOnHours": 12}',
  'the defaults');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000276a2');
select pg_temp.refused($q$select public.god_view_save_settings(true, 15, 6)$q$, 'a God View sub-admin changing the settings');
select pg_temp.check((public.god_view_snapshot() -> 'settings' ->> 'editable')::boolean = false,
  'a sub-admin sees the settings, not to edit');
select pg_temp.as_user('00000000-0000-0000-0000-0000000276a3');
select pg_temp.refused($q$select public.god_view_save_settings(true, 15, 6)$q$, 'a read-only full admin changing the settings');
select pg_temp.as_user('00000000-0000-0000-0000-0000000276b1');
select pg_temp.refused($q$select public.god_view_save_settings(true, 15, 6)$q$, 'a user changing the settings');
select pg_temp.as_user('00000000-0000-0000-0000-0000000276a1');
select pg_temp.check(public.god_view_save_settings(false, 5, 0) = '{"pings": false, "pingMinutes": 10, "alwaysOnHours": 1}',
  'too low is clamped');
select pg_temp.check(public.god_view_save_settings(true, 999, 99) = '{"pings": true, "pingMinutes": 240, "alwaysOnHours": 48}',
  'too high is clamped');
select pg_temp.check(public.god_view_save_settings(true, 30, 12) = '{"pings": true, "pingMinutes": 30, "alwaysOnHours": 12}',
  'saved');
select pg_temp.check((public.god_view_snapshot() -> 'settings') =
                     '{"pings": true, "pingMinutes": 30, "alwaysOnHours": 12, "editable": true}',
  'the snapshot carries the settings, editable for a full admin');
reset role;
select pg_temp.check((select settings ->> 'keep276' = '1' from public.admin_display_settings where id = 'global'),
  'the rest of the display settings are kept');
select pg_temp.check((select count(*) = 3 from public.admin_audit_log
                       where actor_id = '00000000-0000-0000-0000-0000000276a1' and action = 'god_view.settings'),
  'each change is logged');
update public.admin_display_settings set settings = jsonb_set(settings, '{godView,pingMinutes}', '"x"') where id = 'global';
select pg_temp.check((public.god_view_settings() ->> 'pingMinutes')::int = 30, 'a value that is not a number reads as the default');
update public.admin_display_settings set settings = jsonb_set(settings, '{godView,pingMinutes}', '30') where id = 'global';

-- 3. Always on, quiet --------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000276a1');
create temp table s0276 as select pg_temp.mine(public.god_view_snapshot()) as live,
                                  public.god_view_snapshot(p_show_offline => true) as raw,
                                  pg_temp.mine(public.god_view_snapshot(p_show_offline => true)) as lk;
select pg_temp.check((select live->'00000000-0000-0000-0000-0000000276f1'->>'status' = 'always_on'
                         and (live->'00000000-0000-0000-0000-0000000276f1'->>'moved_at')::timestamptz = now() - interval '2 hours'
                         and (live->'00000000-0000-0000-0000-0000000276f1'->>'updated_at')::timestamptz = now() - interval '2 hours'
                        from s0276),
  'quiet for 2 hours, always with the key: Always on, with when it last moved, without the Last known toggle');
select pg_temp.check((select lk->'00000000-0000-0000-0000-0000000276f2'->>'status' = 'last_known'
                         and lk->'00000000-0000-0000-0000-0000000276f2'->>'moved_at' is null
                         and not (live ? '00000000-0000-0000-0000-0000000276f2') from s0276),
  'quiet for 13 hours: Last known, only with the toggle');
select pg_temp.check((select lk->'00000000-0000-0000-0000-0000000276f3'->>'status' = 'last_known' from s0276),
  'quiet without the background key: Last known');
select pg_temp.check((select live->'00000000-0000-0000-0000-0000000276f4'->>'status' = 'always_on' from s0276),
  'the open app 2 hours ago, always with the key (closed since): Always on');
select pg_temp.check((select live->'00000000-0000-0000-0000-0000000276f5'->>'status' = 'always_on' from s0276),
  'a fresh background report: Always on, as 0272');
select pg_temp.check((select (raw->'counts'->>'users_always_on')::int >= 4
                         and (raw->'counts'->>'always_on')::int >= 4 from s0276), 'the counts follow');
select pg_temp.check((select raw::text not like '%60127600%' from s0276), 'no phone numbers');
-- The admin's hours.
reset role;
update public.admin_display_settings set settings = jsonb_set(settings, '{godView,alwaysOnHours}', '1') where id = 'global';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000276a1');
select pg_temp.check((select pg_temp.mine(public.god_view_snapshot(p_show_offline => true))
                               -> '00000000-0000-0000-0000-0000000276f1' ->> 'status') = 'last_known',
  'with 1 hour set, quiet for 2 hours is Last known');
reset role;
update public.admin_display_settings set settings = jsonb_set(settings, '{godView,alwaysOnHours}', '12') where id = 'global';

-- 4. Ping now ------------------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000276a2');
select pg_temp.refused($q$select public.god_view_ping('00000000-0000-0000-0000-0000000276f7')$q$,
  'a sub-admin pinging someone outside their region');
select pg_temp.refused($q$select public.god_view_ping_answer('00000000-0000-0000-0000-0000000276f7', now())$q$,
  'a sub-admin asking about someone outside their region');
create temp table p0276 as select public.god_view_ping('00000000-0000-0000-0000-0000000276f1') as first;
select pg_temp.check((select (first->>'phones')::int = 1 and (first->>'sent')::int = 1 and (first->>'recent')::int = 0
                         and first->>'retry_at' is null and jsonb_typeof(first->'posted') = 'boolean'
                         and (first->>'sent_at')::timestamptz = now() from p0276),
  'a sub-admin pings someone in their region: the FCM phone, never the PushKit one');
select pg_temp.check((select (x->>'sent')::int = 0 and (x->>'recent')::int = 1
                         and (x->>'retry_at')::timestamptz = now() + interval '2 minutes'
                        from (select public.god_view_ping('00000000-0000-0000-0000-0000000276f1') as x) y),
  'each phone at most once in 2 minutes');
select pg_temp.check((select (x->>'phones')::int = 0 and (x->>'sent')::int = 0
                        from (select public.god_view_ping('00000000-0000-0000-0000-0000000276f3') as x) y),
  'a phone without the key is not pinged');
select pg_temp.check((select (x->>'answered')::boolean = false
                        from (select public.god_view_ping_answer('00000000-0000-0000-0000-0000000276f1', now()) as x) y),
  'no answer yet');
select pg_temp.check((select x::text not like '%60127600%'
                        from (select public.god_view_ping('00000000-0000-0000-0000-0000000276f1') as x) y),
  'no phone number in the answer');
select pg_temp.as_user('00000000-0000-0000-0000-0000000276a1');
select pg_temp.check((select (x->>'phones')::int = 0
                        from (select public.god_view_ping('00000000-0000-0000-0000-0000000276f6') as x) y),
  'a deleted account is not pinged');
reset role;
select pg_temp.check((select count(*) = 5 from public.admin_audit_log where action = 'god_view.ping'
                         and target_profile_id::text like '00000000-0000-0000-0000-0000000276%'),
  'every Ping now is logged');
select pg_temp.check((select ping_sent_at = now() from public.push_tokens where token = 'gv276-f1')
                     and (select ping_sent_at is null from public.push_tokens where token = 'gv276-f1-voip'),
  'the FCM phone is claimed');

-- The answer: a background report since.
update public.push_tokens set located_at = now() - interval '2 hours' where profile_id = '00000000-0000-0000-0000-0000000276f1';
set local role anon;
select pg_temp.check(public.push_background_location('k276k276k276k276k276k276k276k276k276k276', 40.1, 140.1) = 0,
  'not this key');
reset role;
update public.push_tokens set bg_key_hash = encode(extensions.digest('k276k276k276k276k276k276k276k276k276k276', 'sha256'), 'hex')
 where profile_id = '00000000-0000-0000-0000-0000000276f1';
set local role anon;
select pg_temp.check(public.push_background_location('k276k276k276k276k276k276k276k276k276k276', 40.1001, 140.1) = 2,
  'the phone answers');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000276a2');
select pg_temp.check((select (x->>'answered')::boolean and (x->>'located_at')::timestamptz = now()
                        from (select public.god_view_ping_answer('00000000-0000-0000-0000-0000000276f1', now()) as x) y),
  'answered');
select pg_temp.check((select (x->>'moved_at')::timestamptz = now() - interval '2 hours' and x->>'status' = 'always_on'
                        from (select pg_temp.mine(public.god_view_snapshot()) -> '00000000-0000-0000-0000-0000000276f1' as x) y),
  'answered without moving: Always on, not moved since 2 hours ago');
reset role;

-- 5. The scheduled run ---------------------------------------------------------------------------------
update public.push_tokens set ping_sent_at = null where token like 'gv276-%';
update public.push_tokens set located_at = now() - interval '2 hours' where profile_id = '00000000-0000-0000-0000-0000000276f1';
update public.admin_display_settings set settings = jsonb_set(settings, '{godView,pings}', 'false') where id = 'global';
select pg_temp.check(public.location_ping_due() = 0, 'nothing while pings are off');
select pg_temp.check((select count(*) = 0 from public.push_tokens where token like 'gv276-%' and ping_sent_at is not null),
  'nothing claimed while pings are off');
update public.admin_display_settings set settings = jsonb_set(settings, '{godView,pings}', 'true') where id = 'global';
-- Only this test's phones: everything else is out of the way.
update public.push_tokens set ping_sent_at = now() where token not like 'gv276-%' and bg_key_hash is not null;
select pg_temp.check(public.location_ping_due() = 4, 'the phones due');
select pg_temp.check((select array_agg(token order by token) from public.push_tokens
                       where token like 'gv276-%' and ping_sent_at = now())
                     = array['gv276-f1', 'gv276-f2', 'gv276-f4', 'gv276-f7'],
  'due: older than 30 minutes, key, always, FCM token, live account, located in the past week');
select pg_temp.check(public.location_ping_due() = 0, 'not again within the minutes');
update public.push_tokens set ping_sent_at = now() - interval '31 minutes' where token = 'gv276-f2';
select pg_temp.check(public.location_ping_due() = 1, 'again after the minutes');

-- 6. What the function is handed ------------------------------------------------------------------------
set local role service_role;
select pg_temp.as_user('00000000-0000-0000-0000-0000000276a1');
select pg_temp.check((select array_agg(t.token order by t.token)
                        from public.location_ping_targets(
                               array(select id from public.push_tokens where token like 'gv276-%')) t)
                     = array['gv276-f1', 'gv276-f2', 'gv276-f4', 'gv276-f7'],
  'the targets: the phones just claimed, never a PushKit token, a deleted account or one without the key');
reset role;
update public.push_tokens set ping_sent_at = now() - interval '11 minutes' where token = 'gv276-f7';
set local role service_role;
select pg_temp.check((select count(*) = 0
                        from public.location_ping_targets(array(select id from public.push_tokens where token = 'gv276-f7'))),
  'not a phone claimed over 10 minutes ago');
reset role;

rollback;
