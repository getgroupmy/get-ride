-- ============================================================================
-- Regression test for migration 0272: God View presence. The open app's
-- check-in moves only the caller's own phone and keeps the area; the
-- closed app's background report needs the install's key, location set to
-- always, and yields to the open app; God View shows "Always on" (a fresh
-- background report with location always), partners "online, not
-- responding" up to 24 hours whatever the toggle, and everyone else at
-- their last known position up to 7 days old (asked for), with the counts,
-- the row cap leaving last-known rows out first, the sub-admin's region,
-- and still no phone numbers.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/god_view_presence_0272.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if has_function_privilege('anon', 'public.push_checkin(text[], double precision, double precision, boolean, boolean, text)', 'execute')
     or not has_function_privilege('authenticated', 'public.push_checkin(text[], double precision, double precision, boolean, boolean, text)', 'execute')
     or not has_function_privilege('anon', 'public.push_background_location(text, double precision, double precision)', 'execute')
     or has_function_privilege('anon', 'public.god_view_snapshot(double precision, double precision, double precision, double precision, boolean, text, integer)', 'execute')
     or has_function_privilege('authenticated', 'public.god_view_people(double precision[], boolean, text, uuid, boolean, jsonb, polygon[])', 'execute') then
    raise exception 'FAILED: 0272 function grants';
  end if;
end
$$;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000272a1', '60127200001'),  -- full admin
  ('00000000-0000-0000-0000-0000000272a2', '60127200002'),  -- God View, North 272 (mapped)
  ('00000000-0000-0000-0000-0000000272a3', '60127200003'),  -- God View, Southland 272 (by name)
  ('00000000-0000-0000-0000-0000000272f1', '60127200011'),  -- always on, background 10 min ago
  ('00000000-0000-0000-0000-0000000272f2', '60127200012'),  -- app open 5 min ago
  ('00000000-0000-0000-0000-0000000272f3', '60127200013'),  -- background 40 min ago: last known
  ('00000000-0000-0000-0000-0000000272f4', '60127200014'),  -- located 3 days ago
  ('00000000-0000-0000-0000-0000000272f5', '60127200015'),  -- located 8 days ago
  ('00000000-0000-0000-0000-0000000272f6', '60127200016'),  -- background 5 min ago, location not always
  ('00000000-0000-0000-0000-0000000272f7', '60127200017'),  -- always on, Southland
  ('00000000-0000-0000-0000-0000000272d1', '60127200021'),  -- partner "online", last heard 2 h ago
  ('00000000-0000-0000-0000-0000000272d2', '60127200022'),  -- partner "online", last heard 30 h ago
  ('00000000-0000-0000-0000-0000000272d3', '60127200023'),  -- partner offline, phone always on
  ('00000000-0000-0000-0000-0000000272d4', '60127200024'),  -- partner online now
  ('00000000-0000-0000-0000-0000000272c1', '60127200031'),  -- checks in
  ('00000000-0000-0000-0000-0000000272c2', '60127200032')   -- someone else's phone
on conflict do nothing;
insert into public.profiles (id, name, phone)
select id, 'GV272 ' || right(id::text, 2), '+' || phone from auth.users
 where id::text like '00000000-0000-0000-0000-0000000272%'
on conflict (id) do update set name = excluded.name, phone = excluded.phone;

insert into public.admin_access (profile_id, page, access_level, region) values
  ('00000000-0000-0000-0000-0000000272a1', '*', 'edit', null),
  ('00000000-0000-0000-0000-0000000272a2', 'admin-god-view', 'read', '{"country": "Testland 272", "state": "North 272"}'),
  ('00000000-0000-0000-0000-0000000272a3', 'admin-god-view', 'read', '{"country": "Testland 272", "state": "Southland 272"}')
on conflict do nothing;

-- North 272: lng 130..131, lat 30..31. Southland 272 has no boundary.
insert into public.countries (name) values ('Testland 272') on conflict do nothing;
insert into public.states (country, name) values ('Testland 272', 'North 272'), ('Testland 272', 'Southland 272')
on conflict do nothing;
update public.states set boundary_polys = array['((130,30),(131,30),(131,31),(130,31))'::polygon]
 where country = 'Testland 272' and name = 'North 272';

insert into public.partners (id, auth_user_id, name, phone, status, plate, vehicle, vehicle_type) values
  ('00000000-0000-0000-0000-0000000272e1', '00000000-0000-0000-0000-0000000272d1', 'Amir', '60127200021', 'approved', 'NR 272', 'Proton Saga', 'Car'),
  ('00000000-0000-0000-0000-0000000272e2', '00000000-0000-0000-0000-0000000272d2', 'Bala', '60127200022', 'approved', 'OLD 272', 'Proton X50', 'Car'),
  ('00000000-0000-0000-0000-0000000272e3', '00000000-0000-0000-0000-0000000272d3', 'Chong', '60127200023', 'approved', 'AO 272', 'Honda Wave', 'Motorcycle'),
  ('00000000-0000-0000-0000-0000000272e4', '00000000-0000-0000-0000-0000000272d4', 'Dina', '60127200024', 'approved', 'FR 272', 'Perodua Myvi', 'Car');

insert into public.driver_presence (profile_id, online, lat, lng, updated_at) values
  ('00000000-0000-0000-0000-0000000272d1', true, 30.5, 130.5, now() - interval '2 hours'),
  ('00000000-0000-0000-0000-0000000272d2', true, 30.8, 130.8, now() - interval '30 hours'),
  ('00000000-0000-0000-0000-0000000272d3', false, 30.65, 130.65, now() - interval '1 day'),
  ('00000000-0000-0000-0000-0000000272d4', true, 30.7, 130.7, now())
on conflict (profile_id) do update set online = excluded.online, lat = excluded.lat, lng = excluded.lng,
                                      updated_at = excluded.updated_at;

insert into public.push_tokens (profile_id, token, last_lat, last_lng, located_at, located_bg, location_always,
                                area_country, area_state, area_city) values
  ('00000000-0000-0000-0000-0000000272f1', 'gv272-f1', 30.1, 130.1, now() - interval '10 minutes', true, true, 'Testland 272', 'North 272', 'Hill 272'),
  ('00000000-0000-0000-0000-0000000272f2', 'gv272-f2', 30.2, 130.2, now() - interval '5 minutes', false, false, null, null, null),
  ('00000000-0000-0000-0000-0000000272f3', 'gv272-f3', 30.3, 130.3, now() - interval '40 minutes', true, true, null, null, null),
  ('00000000-0000-0000-0000-0000000272f4', 'gv272-f4', 30.4, 130.4, now() - interval '3 days', false, true, null, null, null),
  ('00000000-0000-0000-0000-0000000272f5', 'gv272-f5', 30.45, 130.45, now() - interval '8 days', false, false, null, null, null),
  ('00000000-0000-0000-0000-0000000272f6', 'gv272-f6', 30.25, 130.25, now() - interval '5 minutes', true, false, null, null, null),
  ('00000000-0000-0000-0000-0000000272f7', 'gv272-f7', 35.0, 135.0, now() - interval '2 minutes', true, true, 'Testland 272', 'Southland 272', 'Port 272'),
  ('00000000-0000-0000-0000-0000000272d3', 'gv272-d3', 30.6, 130.6, now() - interval '5 minutes', true, true, null, null, null),
  ('00000000-0000-0000-0000-0000000272c1', 'gv272-c1', 1, 1, now() - interval '1 day', false, false, 'Keep 272', null, null),
  ('00000000-0000-0000-0000-0000000272c2', 'gv272-c2', 2, 2, now() - interval '1 day', false, false, null, null, null);

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
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
    from jsonb_array_elements(p->'people') x where x->>'id' like '00000000-0000-0000-0000-0000000272%'
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.as_anon(), pg_temp.check(boolean, text),
  pg_temp.refused(text, text), pg_temp.mine(jsonb) to anon, authenticated;

-- 1. The open app's check-in ------------------------------------------------------------------------
set local role anon;
select pg_temp.as_anon();
select pg_temp.refused($q$select public.push_checkin(array['gv272-c1'], 3, 101)$q$, 'a check-in without a session');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000272c1');
select pg_temp.check(public.push_checkin(array['gv272-c1', 'gv272-c2'], 30.9, 130.9, false, true,
                                         'k272k272k272k272k272k272k272k272k272k272') = 1,
  'a check-in moves the caller''s own phone only');
select pg_temp.refused($q$select public.push_checkin(array['gv272-c1'], 95, 101)$q$, 'a check-in off the map');
select pg_temp.refused($q$select public.push_checkin(array['gv272-c1'], 3, 101, false, true, 'short')$q$, 'a short key');
reset role;
select pg_temp.check((select last_lat = 30.9 and located_at = now() and not located_bg and location_always
                         and area_country = 'Keep 272'
                         and bg_key_hash = encode(extensions.digest('k272k272k272k272k272k272k272k272k272k272', 'sha256'), 'hex')
                        from public.push_tokens where token = 'gv272-c1'),
  'the check-in: position, now, foreground, always, the key''s hash, the area left alone');
select pg_temp.check((select last_lat = 2 and bg_key_hash is null from public.push_tokens where token = 'gv272-c2'),
  'someone else''s phone is untouched');

-- 2. The closed app's report ---------------------------------------------------------------------------
set local role anon;
select pg_temp.as_anon();
select pg_temp.check(public.push_background_location('k272k272k272k272k272k272k272k272k272k272', 30.91, 130.91) = 0,
  'a background report yields to the open app''s check-in for 3 minutes');
reset role;
update public.push_tokens set located_at = now() - interval '4 minutes' where token = 'gv272-c1';
set local role anon;
select pg_temp.as_anon();
select pg_temp.check(public.push_background_location('k272k272k272k272k272k272k272k272k272k272', 30.91, 130.91) = 1,
  'a background report with the key');
select pg_temp.check(public.push_background_location('k272k272k272k272k272k272k272k272k272k272', 30.92, 130.92) = 0,
  'one background report a minute at most');
select pg_temp.check(public.push_background_location('x272x272x272x272x272x272x272x272x272x272', 30.92, 130.92) = 0,
  'a wrong key moves nothing');
select pg_temp.check(public.push_background_location('short', 30.92, 130.92) = 0, 'a short key moves nothing');
select pg_temp.check(public.push_background_location('k272k272k272k272k272k272k272k272k272k272', 91, 130.92) = 0,
  'a background report off the map moves nothing');
reset role;
select pg_temp.check((select last_lat = 30.91 and located_bg and area_country = 'Keep 272' from public.push_tokens
                       where token = 'gv272-c1'), 'the background report: position, background, the area left alone');
-- Location no longer always: the key goes, and with it the background report.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000272c1');
select public.push_checkin(array['gv272-c1'], 30.93, 130.93);
reset role;
select pg_temp.check((select bg_key_hash is null and not location_always and not located_bg from public.push_tokens
                       where token = 'gv272-c1'), 'a check-in without always clears the key');
update public.push_tokens set located_at = now() - interval '10 minutes' where token = 'gv272-c1';
set local role anon;
select pg_temp.as_anon();
select pg_temp.check(public.push_background_location('k272k272k272k272k272k272k272k272k272k272', 30.94, 130.94) = 0,
  'no background report once location is not always');
-- push_set_location (0168) marks the position as the open app's.
reset role;
update public.push_tokens set located_bg = true where token = 'gv272-c1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000272c1');
select public.push_set_location(array['gv272-c1'], 30.95, 130.95, 'Testland 272', 'North 272', 'Hill 272', null);
reset role;
select pg_temp.check((select not located_bg and area_state = 'North 272' from public.push_tokens where token = 'gv272-c1'),
  'push_set_location is a foreground report');
-- Out of God View's way below.
delete from public.push_tokens where token in ('gv272-c1', 'gv272-c2');

-- 3. God View: the statuses ------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000272a1');
create temp table s0272 as select pg_temp.mine(public.god_view_snapshot()) as live,
                                  public.god_view_snapshot(p_show_offline => true) as raw,
                                  pg_temp.mine(public.god_view_snapshot(p_show_offline => true)) as lk;
select pg_temp.check((select live->'00000000-0000-0000-0000-0000000272f1'->>'status' = 'always_on'
                         and (live->'00000000-0000-0000-0000-0000000272f1'->>'lat')::float8 = 30.1
                         and live->'00000000-0000-0000-0000-0000000272f1'->>'area' = 'Hill 272' from s0272),
  'a fresh background report with location always is Always on');
select pg_temp.check((select live->'00000000-0000-0000-0000-0000000272f2'->>'status' = 'app_open' from s0272),
  'a fresh open-app report is App open');
select pg_temp.check((select not (live ? '00000000-0000-0000-0000-0000000272f3')
                         and lk->'00000000-0000-0000-0000-0000000272f3'->>'status' = 'last_known' from s0272),
  'a background report 40 min old is only a last known position');
select pg_temp.check((select not (live ? '00000000-0000-0000-0000-0000000272f6')
                         and lk->'00000000-0000-0000-0000-0000000272f6'->>'status' = 'last_known' from s0272),
  'a background report without location always is not Always on');
select pg_temp.check((select not (live ? '00000000-0000-0000-0000-0000000272f4')
                         and lk->'00000000-0000-0000-0000-0000000272f4'->>'status' = 'last_known'
                         and (lk->'00000000-0000-0000-0000-0000000272f4'->>'lat')::float8 = 30.4
                         and (lk->'00000000-0000-0000-0000-0000000272f4'->>'updated_at')::timestamptz = now() - interval '3 days'
                        from s0272), 'a user located 3 days ago, at that position, with its age');
select pg_temp.check((select not (lk ? '00000000-0000-0000-0000-0000000272f5') from s0272),
  'nobody older than 7 days');
select pg_temp.check((select live->'00000000-0000-0000-0000-0000000272d1'->>'status' = 'not_responding'
                         and live->'00000000-0000-0000-0000-0000000272d1'->>'kind' = 'partner'
                         and (live->'00000000-0000-0000-0000-0000000272d1'->>'updated_at')::timestamptz = now() - interval '2 hours'
                         and (live->'00000000-0000-0000-0000-0000000272d1'->>'lat')::float8 = 30.5 from s0272),
  'a partner left online 2 h ago is not responding, without the toggle, with the age');
select pg_temp.check((select not (live ? '00000000-0000-0000-0000-0000000272d2')
                         and lk->'00000000-0000-0000-0000-0000000272d2'->>'status' = 'last_known'
                         and lk->'00000000-0000-0000-0000-0000000272d2'->>'kind' = 'partner' from s0272),
  'a partner left online 30 h ago is only a last known position');
select pg_temp.check((select live->'00000000-0000-0000-0000-0000000272d3'->>'status' = 'always_on'
                         and live->'00000000-0000-0000-0000-0000000272d3'->>'kind' = 'partner'
                         and live->'00000000-0000-0000-0000-0000000272d3'->>'plate' = 'AO 272'
                         and (live->'00000000-0000-0000-0000-0000000272d3'->>'lat')::float8 = 30.6 from s0272),
  'an offline partner whose phone reports from the background is an Always on partner, where the phone is');
select pg_temp.check((select live->'00000000-0000-0000-0000-0000000272d4'->>'status' = 'free' from s0272),
  'a partner online now is still free');
select pg_temp.check((select (raw->'counts'->>'always_on')::int >= 3 and (raw->'counts'->>'users_always_on')::int >= 2
                         and (raw->'counts'->>'partners_always_on')::int >= 1
                         and (raw->'counts'->>'not_responding')::int >= 1
                         and (raw->'counts'->>'partners_not_responding')::int >= 1
                         and (raw->'counts'->>'last_known')::int >= 4
                         and (raw->'counts'->>'last_known')::int
                             = (raw->'counts'->>'partners_offline')::int + (raw->'counts'->>'users_offline')::int
                        from s0272), 'the counts: ' || (select (raw->'counts')::text from s0272));
select pg_temp.check((select raw::text !~ '6012720' and not (raw::text like '%"phone"%') from s0272),
  'still no phone numbers');

-- The box and the cap: live rows first, the last known ones left out first and counted.
select pg_temp.check((select (s->>'total')::int = 9 and (s->>'omitted')::int = 4
                         and (s->>'omitted_last_known')::int = 4
                         and not exists (select 1 from jsonb_array_elements(s->'people') x where x->>'status' = 'last_known')
                         and s->'people'->0->>'status' = 'free'
                        from (select public.god_view_snapshot(29.9, 129.9, 30.99, 130.99, true, null, 5) s) x),
  'the cap keeps the live rows: ' || (select public.god_view_snapshot(29.9, 129.9, 30.99, 130.99, true, null, 5)::text));
select pg_temp.check((select (s->>'total')::int = 5 and (s->>'omitted')::int = 0
                        from (select public.god_view_snapshot(29.9, 129.9, 30.99, 130.99, false) s) x),
  'without the toggle, the live rows only');

-- 4. A sub-admin's region -------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000272a2');
select pg_temp.check((select m ? '00000000-0000-0000-0000-0000000272f1' and m ? '00000000-0000-0000-0000-0000000272d1'
                         and m ? '00000000-0000-0000-0000-0000000272f4' and m ? '00000000-0000-0000-0000-0000000272d2'
                         and not (m ? '00000000-0000-0000-0000-0000000272f7')
                        from (select pg_temp.mine(public.god_view_snapshot(p_show_offline => true)) m) x),
  'a North sub-admin sees North''s always on, not responding and last known, not Southland');
select pg_temp.check((select public.god_view_reveal_phone('00000000-0000-0000-0000-0000000272f4')->>'phone' = '+60127200014'),
  'a sub-admin may show the phone of someone at a last known position in their region');
select pg_temp.as_user('00000000-0000-0000-0000-0000000272a3');
select pg_temp.check((select m->'00000000-0000-0000-0000-0000000272f7'->>'status' = 'always_on'
                         and not (m ? '00000000-0000-0000-0000-0000000272f1') and not (m ? '00000000-0000-0000-0000-0000000272d1')
                        from (select pg_temp.mine(public.god_view_snapshot(p_show_offline => true)) m) x),
  'a Southland sub-admin (no boundary) goes by the names the phone gave');

rollback;

select 'god_view_presence_0272: all passed';
