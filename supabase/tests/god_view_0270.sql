-- ============================================================================
-- Regression test for migration 0270: God View. Only a full admin or an
-- admin given the God View page reads it; a sub-admin sees only the people
-- inside their region; partners online, on a job and (asked for) offline
-- within 2 hours; users searching, in a ride or with the app open (a
-- position in the last 30 minutes), never one whose last position is older;
-- no phone number in the snapshot; a phone shown is logged; suspend needs
-- the Partners / Users edit grant, leaves a ride in progress alone and is
-- logged; the map's box and the row cap; a rider reads nobody's presence or
-- phone position.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/god_view_0270.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if has_function_privilege('anon', 'public.god_view_snapshot(double precision, double precision, double precision, double precision, boolean, text, integer)', 'execute')
     or has_function_privilege('anon', 'public.god_view_reveal_phone(uuid)', 'execute')
     or has_function_privilege('anon', 'public.god_view_suspend(uuid, text, text)', 'execute')
     or has_function_privilege('authenticated', 'public.god_view_people(double precision[], boolean, text, uuid, boolean, jsonb, polygon[])', 'execute')
     or has_function_privilege('authenticated', 'public.god_view_caller()', 'execute')
     or not has_function_privilege('authenticated', 'public.god_view_snapshot(double precision, double precision, double precision, double precision, boolean, text, integer)', 'execute')
     or not has_function_privilege('authenticated', 'public.god_view_reveal_phone(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.god_view_suspend(uuid, text, text)', 'execute') then
    raise exception 'FAILED: God View function grants';
  end if;
  if exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime'
                and tablename in ('driver_presence', 'admin_audit_log')) then
    raise exception 'FAILED: positions are not streamed to every admin';
  end if;
end
$$;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000270a1', '60127000001'),  -- full admin
  ('00000000-0000-0000-0000-0000000270a2', '60127000002'),  -- God View, region North 270
  ('00000000-0000-0000-0000-0000000270a3', '60127000003'),  -- God View, no region yet
  ('00000000-0000-0000-0000-0000000270a4', '60127000004'),  -- another page only
  ('00000000-0000-0000-0000-0000000270a5', '60127000005'),  -- God View (Southland, by name) + Partners edit
  ('00000000-0000-0000-0000-0000000270d1', '60127000011'),  -- partner online, North
  ('00000000-0000-0000-0000-0000000270d2', '60127000012'),  -- partner online, Southland
  ('00000000-0000-0000-0000-0000000270d3', '60127000013'),  -- partner on a trip, North
  ('00000000-0000-0000-0000-0000000270d4', '60127000014'),  -- partner last seen 1 h ago, North
  ('00000000-0000-0000-0000-0000000270d5', '60127000015'),  -- partner last seen 3 h ago
  ('00000000-0000-0000-0000-0000000270f1', '60127000021'),  -- rider with d3
  ('00000000-0000-0000-0000-0000000270f2', '60127000022'),  -- searching, North
  ('00000000-0000-0000-0000-0000000270f3', '60127000023'),  -- app open 5 min ago, North
  ('00000000-0000-0000-0000-0000000270f4', '60127000024'),  -- idle, located 3 h ago
  ('00000000-0000-0000-0000-0000000270f5', '60127000025'),  -- idle, located 1 h ago
  ('00000000-0000-0000-0000-0000000270f6', '60127000026')   -- no position at all
on conflict do nothing;
insert into public.profiles (id, name, phone)
select id, 'GV ' || right(id::text, 2), '+' || phone from auth.users
 where id::text like '00000000-0000-0000-0000-0000000270%'
on conflict (id) do update set name = excluded.name, phone = excluded.phone;
update public.profiles set name = 'Aisyah Gv' where id = '00000000-0000-0000-0000-0000000270f2';

insert into public.admin_access (profile_id, page, access_level, region) values
  ('00000000-0000-0000-0000-0000000270a1', '*', 'edit', null),
  ('00000000-0000-0000-0000-0000000270a2', 'admin-god-view', 'read', '{"country": "Testland 270", "state": "North 270"}'),
  ('00000000-0000-0000-0000-0000000270a3', 'admin-god-view', 'read', null),
  ('00000000-0000-0000-0000-0000000270a4', 'admin-dashboard', 'read', null),
  ('00000000-0000-0000-0000-0000000270a5', 'admin-god-view', 'read', '{"country": "Testland 270", "state": "Southland 270"}'),
  ('00000000-0000-0000-0000-0000000270a5', 'admin-partners', 'edit', null)
on conflict do nothing;

-- North 270 has a mapped boundary (lng 101..102, lat 3..4); Southland 270 none.
insert into public.countries (name) values ('Testland 270') on conflict do nothing;
insert into public.states (country, name) values ('Testland 270', 'North 270'), ('Testland 270', 'Southland 270')
on conflict do nothing;
update public.states set boundary_polys = array['((101,3),(102,3),(102,4),(101,4))'::polygon]
 where country = 'Testland 270' and name = 'North 270';

insert into public.partners (id, auth_user_id, name, phone, status, plate, vehicle, vehicle_type) values
  ('00000000-0000-0000-0000-0000000270e1', '00000000-0000-0000-0000-0000000270d1', 'Hafiz', '60127000011', 'approved', 'VJK 270', 'Perodua Bezza', 'Car'),
  ('00000000-0000-0000-0000-0000000270e2', '00000000-0000-0000-0000-0000000270d2', 'Siti', '60127000012', 'approved', 'WXY 270', 'Honda City', 'Car'),
  ('00000000-0000-0000-0000-0000000270e3', '00000000-0000-0000-0000-0000000270d3', 'Kumar', '60127000013', 'approved', 'BMM 270', 'Yamaha Y16', 'Motorcycle'),
  ('00000000-0000-0000-0000-0000000270e4', '00000000-0000-0000-0000-0000000270d4', 'Jason', '60127000014', 'approved', 'WTF 270', 'Honda Civic', 'Car'),
  ('00000000-0000-0000-0000-0000000270e5', '00000000-0000-0000-0000-0000000270d5', 'Lim', '60127000015', 'approved', 'BQW 270', 'Isuzu', 'Lorry');

insert into public.driver_presence (profile_id, online, lat, lng, updated_at) values
  ('00000000-0000-0000-0000-0000000270d1', true, 3.5, 101.5, now()),
  ('00000000-0000-0000-0000-0000000270d2', true, 5.5, 103.5, now()),
  ('00000000-0000-0000-0000-0000000270d3', true, 3.6, 101.6, now() - interval '20 seconds'),
  ('00000000-0000-0000-0000-0000000270d4', false, 3.7, 101.7, now() - interval '1 hour'),
  ('00000000-0000-0000-0000-0000000270d5', false, 3.8, 101.8, now() - interval '3 hours')
on conflict (profile_id) do update set online = excluded.online, lat = excluded.lat, lng = excluded.lng,
                                      updated_at = excluded.updated_at;

-- Southland users and partners go by the names their phone gave.
insert into public.push_tokens (profile_id, token, last_lat, last_lng, located_at, area_country, area_state, area_city) values
  ('00000000-0000-0000-0000-0000000270d2', 'gv270-d2', 5.5, 103.5, now(), 'Testland 270', 'Southland 270', 'Port 270'),
  ('00000000-0000-0000-0000-0000000270f3', 'gv270-f3', 3.4, 101.4, now() - interval '5 minutes', 'Testland 270', 'North 270', 'Hill 270'),
  ('00000000-0000-0000-0000-0000000270f4', 'gv270-f4', 3.3, 101.3, now() - interval '3 hours', null, null, null),
  ('00000000-0000-0000-0000-0000000270f5', 'gv270-f5', 3.2, 101.2, now() - interval '1 hour', null, null, null);

insert into public.ride_requests (id, rider_id, partner_id, status, service, pickup_lat, pickup_lng, drop_lat, drop_lng,
    user_live_lat, user_live_lng, user_live_at, partner_live_lat, partner_live_lng, partner_live_at,
    partner_plate, rider_phone, partner_phone, suburb, city, started_at, duration_min) values
  ('00000000-0000-0000-0000-000000027001', '00000000-0000-0000-0000-0000000270f1', '00000000-0000-0000-0000-0000000270d3',
   'on_trip', 'Motorcycle', 3.55, 101.55, 3.9, 101.9, 3.61, 101.61, now() - interval '1 minute', 3.62, 101.62, now(),
   'BMM 270', '+60127000021', '+60127000013', 'Mid 270', 'Hill 270', now() - interval '5 minutes', 25),
  ('00000000-0000-0000-0000-000000027002', '00000000-0000-0000-0000-0000000270f2', null,
   'open', 'Car', 3.45, 101.45, 3.1, 101.1, null, null, null, null, null, null,
   null, '+60127000022', null, null, 'Hill 270', null, null);

insert into public.safety_incidents (id, ride_id, reporter_id, reporter_role, rider_id, partner_id, lat, lng, location_at,
    track_until, status) values
  ('00000000-0000-0000-0000-0000000270c1', '00000000-0000-0000-0000-000000027001', '00000000-0000-0000-0000-0000000270f1',
   'rider', '00000000-0000-0000-0000-0000000270f1', '00000000-0000-0000-0000-0000000270d3', 3.63, 101.63, now(),
   now() + interval '30 minutes', 'open');

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
-- The test people in a snapshot (other rows of the database left out).
create or replace function pg_temp.mine(p jsonb) returns jsonb language sql as $$
  select coalesce(jsonb_object_agg(x->>'id', x), '{}'::jsonb)
    from jsonb_array_elements(p->'people') x where x->>'id' like '00000000-0000-0000-0000-0000000270%'
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.mine(jsonb) to authenticated;

set local role authenticated;

-- 1. Not an admin, or not this page: refused ----------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000270f1');
select pg_temp.refused('select public.god_view_snapshot()', 'a rider reading God View');
select pg_temp.refused($q$select public.god_view_reveal_phone('00000000-0000-0000-0000-0000000270d1')$q$,
  'a rider revealing a phone');
-- RLS: a rider reads nobody's presence or phone position.
select pg_temp.check((select count(*) = 0 from public.driver_presence
                       where profile_id <> '00000000-0000-0000-0000-0000000270f1'), 'a rider reads driver presence');
select pg_temp.check((select count(*) = 0 from public.push_tokens), 'a rider reads phone positions');
select pg_temp.check((select count(*) = 0 from public.admin_audit_log), 'a rider reads the admin log');
select pg_temp.as_user('00000000-0000-0000-0000-0000000270a4');
select pg_temp.refused('select public.god_view_snapshot()', 'an admin of another page reading God View');

-- 2. A full admin: everyone, in the right states --------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000270a1');
create temp table s0270 as select pg_temp.mine(public.god_view_snapshot()) as m,
                                  public.god_view_snapshot() as raw,
                                  pg_temp.mine(public.god_view_snapshot(p_show_offline => true)) as off;
select pg_temp.check((select m->'00000000-0000-0000-0000-0000000270d1'->>'status' = 'free' from s0270), 'an online partner is free');
select pg_temp.check((select m->'00000000-0000-0000-0000-0000000270d1'->>'kind' = 'partner'
                         and m->'00000000-0000-0000-0000-0000000270d1'->>'plate' = 'VJK 270'
                         and m->'00000000-0000-0000-0000-0000000270d1'->>'partner_row_id' = '00000000-0000-0000-0000-0000000270e1'
                        from s0270), 'a partner''s card');
select pg_temp.check((select m->'00000000-0000-0000-0000-0000000270d3'->>'status' = 'sos'
                         and (m->'00000000-0000-0000-0000-0000000270d3'->>'sos')::boolean
                         and m->'00000000-0000-0000-0000-0000000270d3'->>'ride_code' like 'R-%'
                         and m->'00000000-0000-0000-0000-0000000270d3'->>'other_id' = '00000000-0000-0000-0000-0000000270f1'
                         and m->'00000000-0000-0000-0000-0000000270d3'->>'incident_id' = '00000000-0000-0000-0000-0000000270c1'
                         and (m->'00000000-0000-0000-0000-0000000270d3'->>'next_lat')::float8 = 3.9
                         and (m->'00000000-0000-0000-0000-0000000270d3'->>'eta_min')::int between 19 and 20
                        from s0270), 'the partner of a ride with an SOS: ' || (select (m->'00000000-0000-0000-0000-0000000270d3')::text from s0270));
select pg_temp.check((select (m->'00000000-0000-0000-0000-0000000270d3'->>'lat')::float8 = 3.62 from s0270),
  'a partner on a ride is where the ride''s live share says');
select pg_temp.check((select m->'00000000-0000-0000-0000-0000000270f1'->>'status' = 'sos'
                         and (m->'00000000-0000-0000-0000-0000000270f1'->>'lat')::float8 = 3.63
                         and m->'00000000-0000-0000-0000-0000000270f1'->>'other_id' = '00000000-0000-0000-0000-0000000270d3'
                        from s0270), 'the rider who raised the SOS, where they raised it');
select pg_temp.check((select m->'00000000-0000-0000-0000-0000000270f2'->>'status' = 'searching'
                         and (m->'00000000-0000-0000-0000-0000000270f2'->>'lat')::float8 = 3.45
                         and m->'00000000-0000-0000-0000-0000000270f2'->>'area' = 'Hill 270'
                        from s0270), 'a searching user at the pickup');
select pg_temp.check((select m->'00000000-0000-0000-0000-0000000270f3'->>'status' = 'app_open'
                         and (m->'00000000-0000-0000-0000-0000000270f3'->>'lat')::float8 = 3.4 from s0270),
  'an idle user with a recent position is app open');
select pg_temp.check((select not (m ? '00000000-0000-0000-0000-0000000270f4') and not (off ? '00000000-0000-0000-0000-0000000270f4')
                        from s0270), 'an idle user last located 3 h ago is never shown');
select pg_temp.check((select not (m ? '00000000-0000-0000-0000-0000000270f5')
                         and off->'00000000-0000-0000-0000-0000000270f5'->>'status' = 'offline' from s0270),
  'a user located 1 h ago only with Show offline, greyed');
select pg_temp.check((select not (m ? '00000000-0000-0000-0000-0000000270f6') and not (off ? '00000000-0000-0000-0000-0000000270f6')
                        from s0270), 'a user with no position is not shown');
select pg_temp.check((select not (m ? '00000000-0000-0000-0000-0000000270d4')
                         and off->'00000000-0000-0000-0000-0000000270d4'->>'status' = 'offline'
                         and not (off ? '00000000-0000-0000-0000-0000000270d5') from s0270),
  'Show offline adds partners seen in the past 2 hours, no older');
select pg_temp.check((select (raw->'counts'->>'sos')::int >= 2 and (raw->>'scoped')::boolean = false from s0270), 'the counts');
-- No phone number anywhere in it.
select pg_temp.check((select raw::text !~ '6012700' and off::text !~ '6012700' and not (raw::text like '%"phone"%') from s0270),
  'the snapshot has no phone numbers');

-- The map's box, the search, the cap.
select pg_temp.check((select not (pg_temp.mine(public.god_view_snapshot(3, 101, 4, 102)) ? '00000000-0000-0000-0000-0000000270d2')
                        and pg_temp.mine(public.god_view_snapshot(3, 101, 4, 102)) ? '00000000-0000-0000-0000-0000000270d1'),
  'only the box the map shows');
select pg_temp.check((select pg_temp.mine(public.god_view_snapshot(3, 101, 4, 102, false, 'wxy 270')) ? '00000000-0000-0000-0000-0000000270d2'),
  'a search by plate looks outside the box');
select pg_temp.check((select pg_temp.mine(public.god_view_snapshot(p_query => '7000022')) ? '00000000-0000-0000-0000-0000000270f2'
                         and not (pg_temp.mine(public.god_view_snapshot(p_query => '7000022')) ? '00000000-0000-0000-0000-0000000270f3')),
  'a search by phone digits');
select pg_temp.check((select (s->>'omitted')::int = (s->>'total')::int - 1 and jsonb_array_length(s->'people') = 1
                         and s->'people'->0->>'status' = 'sos'
                        from (select public.god_view_snapshot(p_limit => 1) s) x), 'the cap keeps SOS first and says how many were left out');

-- 3. A sub-admin sees only their region ------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000270a2');
select pg_temp.check((select m ? '00000000-0000-0000-0000-0000000270d1' and m ? '00000000-0000-0000-0000-0000000270f2'
                         and m ? '00000000-0000-0000-0000-0000000270f3' and m ? '00000000-0000-0000-0000-0000000270d3'
                         and not (m ? '00000000-0000-0000-0000-0000000270d2')
                        from (select pg_temp.mine(public.god_view_snapshot()) m) x),
  'a North sub-admin sees North (by its boundary), not Southland');
select pg_temp.check((select (public.god_view_snapshot()->>'scoped')::boolean), 'the snapshot says it is scoped');
select pg_temp.refused($q$select public.god_view_reveal_phone('00000000-0000-0000-0000-0000000270d2')$q$,
  'a sub-admin revealing the phone of someone outside their region');
select pg_temp.as_user('00000000-0000-0000-0000-0000000270a5');
select pg_temp.check((select m ? '00000000-0000-0000-0000-0000000270d2' and not (m ? '00000000-0000-0000-0000-0000000270d1')
                        from (select pg_temp.mine(public.god_view_snapshot()) m) x),
  'a Southland sub-admin (no boundary) goes by the names');
select pg_temp.as_user('00000000-0000-0000-0000-0000000270a3');
select pg_temp.check((select (s->>'scope_missing')::boolean and pg_temp.mine(s) = '{}'::jsonb
                        from (select public.god_view_snapshot() s) x), 'a God View grant without a region sees nobody');

-- 4. Showing a phone is logged ---------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000270a2');
select pg_temp.check((select public.god_view_reveal_phone('00000000-0000-0000-0000-0000000270d1')->>'phone' = '+60127000011'),
  'the phone, shown');
select pg_temp.as_user('00000000-0000-0000-0000-0000000270a1');
select pg_temp.check((select count(*) = 1 from public.admin_audit_log
                       where actor_id = '00000000-0000-0000-0000-0000000270a2' and action = 'god_view.reveal_phone'
                         and target_profile_id = '00000000-0000-0000-0000-0000000270d1'),
  'the reveal is in the admin log, which a full admin reads');

-- 5. Suspend -----------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000270a2');
select pg_temp.refused($q$select public.god_view_suspend('00000000-0000-0000-0000-0000000270d1', 'Safety concern')$q$,
  'a sub-admin without Partners edit suspending a partner');
select pg_temp.as_user('00000000-0000-0000-0000-0000000270a5');
select pg_temp.refused($q$select public.god_view_suspend('00000000-0000-0000-0000-0000000270d1', 'Safety concern')$q$,
  'a sub-admin suspending a partner outside their region');
select pg_temp.as_user('00000000-0000-0000-0000-0000000270a1');
select pg_temp.refused($q$select public.god_view_suspend('00000000-0000-0000-0000-0000000270d3', '')$q$, 'a suspend without a reason');
select pg_temp.check((select (public.god_view_suspend('00000000-0000-0000-0000-0000000270d3', 'Safety concern', 'Rider SOS'))->>'on_trip' = 'true'),
  'suspending a partner on a trip says so');
select pg_temp.check((select public.god_view_suspend('00000000-0000-0000-0000-0000000270f3', 'Fraud')->>'kind' = 'user'), 'a user');
reset role;
select pg_temp.check((select status = 'blocked' and status_note = 'Safety concern: Rider SOS' from public.partners
                       where id = '00000000-0000-0000-0000-0000000270e3'), 'the partner is blocked, with the reason');
select pg_temp.check((select not online from public.driver_presence where profile_id = '00000000-0000-0000-0000-0000000270d3'),
  'and offline');
select pg_temp.check((select status = 'on_trip' from public.ride_requests where id = '00000000-0000-0000-0000-000000027001'),
  'their ride in progress goes on');
select pg_temp.check((select profile_status = 'Blocked' and status = 'blocked' from public.profiles
                       where id = '00000000-0000-0000-0000-0000000270f3'), 'the user is blocked');
select pg_temp.check((select count(*) = 2 from public.admin_audit_log where action = 'god_view.suspend'
                         and actor_id = '00000000-0000-0000-0000-0000000270a1'), 'both suspends are logged');

-- 6. Presence: the rules once a minute while online -----------------------------------------------
update public.driver_presence set online = true, rules_checked_at = now() - interval '5 seconds'
 where profile_id = '00000000-0000-0000-0000-0000000270d1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000270d1');
select public.set_driver_presence(true, 3.5005, 101.5005);
reset role;
select pg_temp.check((select online and lat = 3.5005 and rules_checked_at < now() - interval '4 seconds'
                        from public.driver_presence where profile_id = '00000000-0000-0000-0000-0000000270d1'),
  'a report 5 s after a check moves the driver and keeps the check');

rollback;

select 'god_view_0270: all passed';
