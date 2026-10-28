-- ============================================================================
-- Regression test for migration 0322: the rider live map.
--   0. who may call what; the tables stay closed;
--   1. the seeded Default has every mode off; a region rule overrides only
--      what it sets; only admins of the page write, and every write is logged;
--   2. Cars near me: free online drivers only, moved, no name, plate or id,
--      the kinds the rule shows, at most once per interval;
--   3. Busy areas: the hexagon maths, the minimum, no counts, the fare level;
--   4. My people: Family's disclosed ways only, the member's "who can see",
--      stopping at once, all members where the rule says so;
--   5. Team: company-paid trips only, the roles the rule allows, the member's
--      chip and who looked.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rider_live_map_0322.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- ---- 0. Grants -----------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'public.rider_live_map_config(jsonb)', 'public.rider_live_map_cars(double precision, double precision, jsonb)',
    'public.rider_live_map_busy(double precision, double precision, double precision, double precision, jsonb)',
    'public.rider_live_map_people(jsonb)', 'public.rider_live_map_team(jsonb)',
    'public.rider_live_map_trip_note(uuid)', 'public.rider_live_map_stop_sharing(uuid)'] loop
    if not has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute') then
      raise exception 'FAILED: % is for signed-in callers only', f;
    end if;
  end loop;
  foreach f in array array[
    'public.rider_live_map_settings_at(jsonb)', 'public.rider_live_map_cached(text, integer)',
    'public.rider_live_map_keep(text, jsonb)', 'public.rider_live_map_hour_salt()',
    'public.rider_live_map_people_allowed(uuid)', 'public.rider_live_map_team_accounts(uuid)',
    'public.rider_live_map_family(uuid)', 'public.rider_live_map_members_see(uuid)'] loop
    if has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute') then
      raise exception 'FAILED: % is the server''s own', f;
    end if;
  end loop;
  if has_table_privilege('authenticated', 'public.rider_live_map_calls', 'select')
     or has_table_privilege('authenticated', 'public.rider_live_map_salt', 'select')
     or has_table_privilege('authenticated', 'public.rider_live_map_trail', 'select')
     or has_table_privilege('anon', 'public.rider_live_map_rules', 'select') then
    raise exception 'FAILED: the live map''s own tables are closed';
  end if;
end
$$;

-- ---- People -------------------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.permit_country_settings') is not null then
    execute 'update public.permit_country_settings set enforce = false';
  end if;
end
$$;
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000322a1'),  -- family host
  ('00000000-0000-0000-0000-0000000322a2'),  -- member on a trip
  ('00000000-0000-0000-0000-0000000322a3'),  -- another member
  ('00000000-0000-0000-0000-0000000322a4'),  -- a stranger
  ('00000000-0000-0000-0000-0000000322b1'),  -- driver, free
  ('00000000-0000-0000-0000-0000000322b2'),  -- driver, free (bike)
  ('00000000-0000-0000-0000-0000000322b3'),  -- driver, on a trip
  ('00000000-0000-0000-0000-0000000322b4'),  -- driver, offline
  ('00000000-0000-0000-0000-0000000322b5'),  -- driver, far away
  ('00000000-0000-0000-0000-0000000322c1'),  -- admin of the page
  ('00000000-0000-0000-0000-0000000322c2'),  -- full admin
  ('00000000-0000-0000-0000-0000000322d1'),  -- company travel admin
  ('00000000-0000-0000-0000-0000000322d2'),  -- company staff on a trip
  ('00000000-0000-0000-0000-0000000322d3')   -- company staff, rider role
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000322a1', 'Karpal Contoh', '+60100322001'),
  ('00000000-0000-0000-0000-0000000322a2', 'Aisha Contoh', '+60100322002'),
  ('00000000-0000-0000-0000-0000000322a3', 'Iman Contoh', '+60100322003'),
  ('00000000-0000-0000-0000-0000000322a4', 'Other Person', '+60100322004'),
  ('00000000-0000-0000-0000-0000000322b1', 'Siti Sample', '+60100322011'),
  ('00000000-0000-0000-0000-0000000322b2', 'Ahmad Sample', '+60100322012'),
  ('00000000-0000-0000-0000-0000000322b3', 'Chong Sample', '+60100322013'),
  ('00000000-0000-0000-0000-0000000322b4', 'Devi Sample', '+60100322014'),
  ('00000000-0000-0000-0000-0000000322b5', 'Eng Sample', '+60100322015'),
  ('00000000-0000-0000-0000-0000000322c1', 'Test Admin', '+60100322021'),
  ('00000000-0000-0000-0000-0000000322c2', 'Test Full Admin', '+60100322022'),
  ('00000000-0000-0000-0000-0000000322d1', 'Mei Travel', '+60100322031'),
  ('00000000-0000-0000-0000-0000000322d2', 'Lim Staff', '+60100322032'),
  ('00000000-0000-0000-0000-0000000322d3', 'Tan Staff', '+60100322033')
on conflict (id) do update set name = excluded.name, phone = excluded.phone;
insert into public.partners (id, auth_user_id, name, phone, status, vehicle_type) values
  ('00000000-0000-0000-0000-0000000322e1', '00000000-0000-0000-0000-0000000322b1', 'Siti Sample', '+60100322011', 'approved', 'Sedan'),
  ('00000000-0000-0000-0000-0000000322e2', '00000000-0000-0000-0000-0000000322b2', 'Ahmad Sample', '+60100322012', 'approved', 'Motorcycle'),
  ('00000000-0000-0000-0000-0000000322e3', '00000000-0000-0000-0000-0000000322b3', 'Chong Sample', '+60100322013', 'approved', 'Sedan'),
  ('00000000-0000-0000-0000-0000000322e4', '00000000-0000-0000-0000-0000000322b4', 'Devi Sample', '+60100322014', 'approved', 'Sedan'),
  ('00000000-0000-0000-0000-0000000322e5', '00000000-0000-0000-0000-0000000322b5', 'Eng Sample', '+60100322015', 'approved', 'Sedan');
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000322c1', 'admin-settings-rider-live-map', 'edit'),
  ('00000000-0000-0000-0000-0000000322c2', '*', 'edit');

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
create or replace function pg_temp.refused(p_sql text, p_like text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_like || '%' then
      return;
    end if;
    raise exception 'FAILED: % refused with "%" instead of %', p_what, sqlerrm, p_like;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text, text)
  to authenticated;
create temporary table t_out (k text primary key, v jsonb);
grant all on t_out to authenticated;
create temporary table t_ids (k text primary key, id uuid);
grant all on t_ids to authenticated;

-- ---- 1. The rules --------------------------------------------------------------------------------
select pg_temp.check(not (public.rider_live_map_settings_at('{}')->>'cars_on')::boolean
  and not (public.rider_live_map_settings_at('{}')->>'busy_on')::boolean
  and not (public.rider_live_map_settings_at('{}')->>'people_on')::boolean
  and not (public.rider_live_map_settings_at('{}')->>'team_on')::boolean, 'every mode starts off');
select pg_temp.check((public.rider_live_map_settings_at('{}')->>'cars_offset_m')::int = 150
  and (public.rider_live_map_settings_at('{}')->>'busy_hex_m')::int = 350
  and (public.rider_live_map_settings_at('{}')->>'busy_min')::int = 5
  and (public.rider_live_map_settings_at('{}')->>'busy_every_s')::int = 60
  and (public.rider_live_map_settings_at('{}')->>'cars_every_s')::int = 10
  and (public.rider_live_map_settings_at('{}')->>'people_history_min')::int = 0, 'the approved numbers');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a1');
select pg_temp.check(not (public.rider_live_map_config('{"country": "Malaysia"}')->'busy'->>'on')::boolean
  and not (public.rider_live_map_config('{"country": "Malaysia"}')->'cars'->>'on')::boolean
  and not (public.rider_live_map_config('{"country": "Malaysia"}')->'people'->>'on')::boolean
  and not (public.rider_live_map_config('{"country": "Malaysia"}')->'team'->>'on')::boolean,
  'with the Default the app looks unchanged');
select pg_temp.check(not (public.rider_live_map_busy(3.0, 101.5, 3.2, 101.8, '{}')->>'on')::boolean,
  'busy areas answer nothing while off');
select pg_temp.check(not (public.rider_live_map_cars(3.1, 101.6, '{}')->>'on')::boolean,
  'cars answer nothing while off');
select pg_temp.refused($q$insert into public.rider_live_map_rules (country, busy_on) values ('Malaysia', true)$q$,
  'row-level security', 'a rider writing a rule');
select pg_temp.check((select count(*) from public.rider_live_map_rules) = 0, 'a rider reads no rules');
select pg_temp.as_user('00000000-0000-0000-0000-0000000322c1');
insert into public.rider_live_map_rules (country, cars_on, busy_on, people_on, team_on)
values ('Malaysia', true, true, true, true);
insert into public.rider_live_map_rules (country, state, city, busy_min, busy_fields)
values ('Malaysia', 'Kuala Lumpur', 'Kuala Lumpur', 3, array['level', 'fare']);
delete from public.rider_live_map_rules where country = '';
reset role;
select pg_temp.check((select count(*) from public.rider_live_map_rules where country = '') = 1, 'the Default stays');
select pg_temp.check((select count(*) from public.admin_audit_log
                       where action = 'rider_live_map.insert' and actor_id = '00000000-0000-0000-0000-0000000322c1') = 2
  and (select detail->'changed' ? 'busy_on' from public.admin_audit_log
        where action = 'rider_live_map.insert' and detail->'region'->>'state' = '' limit 1),
  'every admin write is logged with what changed');
select pg_temp.check((public.rider_live_map_settings_at('{"country": "malaysia", "state": "Kuala Lumpur", "city": "Kuala Lumpur"}')->>'busy_min')::int = 3
  and (public.rider_live_map_settings_at('{"country": "Malaysia", "state": "Kuala Lumpur", "city": "Kuala Lumpur"}')->>'busy_on')::boolean
  and (public.rider_live_map_settings_at('{"country": "Malaysia", "state": "Kuala Lumpur", "city": "Kuala Lumpur"}')->>'busy_hex_m')::int = 350
  and (public.rider_live_map_settings_at('{"country": "Malaysia"}')->>'busy_min')::int = 5
  and not (public.rider_live_map_settings_at('{"country": "Singapore"}')->>'busy_on')::boolean,
  'most specific wins, a region sets only what it sets');
select pg_temp.refused($q$insert into public.rider_live_map_rules (country, cars_offset_m) values ('Thailand', 5000)$q$,
  'check', 'an offset over 1000 m');
select pg_temp.refused($q$insert into public.rider_live_map_rules (country, busy_colours) values ('Thailand', array['red'])$q$,
  'check', 'a colour scale that is not four colours');

-- ---- 2. Cars near me -----------------------------------------------------------------------------
insert into public.driver_presence (profile_id, online, lat, lng, updated_at) values
  ('00000000-0000-0000-0000-0000000322b1', true, 3.1210, 101.6810, now()),
  ('00000000-0000-0000-0000-0000000322b2', true, 3.1190, 101.6790, now()),
  ('00000000-0000-0000-0000-0000000322b3', true, 3.1200, 101.6805, now()),
  ('00000000-0000-0000-0000-0000000322b4', false, 3.1201, 101.6801, now()),
  ('00000000-0000-0000-0000-0000000322b5', true, 3.3000, 101.9000, now());
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, payment_mode, country)
values ('00000000-0000-0000-0000-0000000322f9', '00000000-0000-0000-0000-0000000322a4', 'open', 3.12, 101.68, 10, 10, 'Cash', 'Malaysia');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000322b3', status = 'accepted'
 where id = '00000000-0000-0000-0000-0000000322f9';

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a4');
insert into t_out select 'cars', public.rider_live_map_cars(3.1205, 101.6800, '{"country": "Malaysia"}');
select pg_temp.check((select (v->>'count')::int = 2 and jsonb_array_length(v->'cars') = 2 from t_out where k = 'cars'),
  'only the free online drivers near by: ' || (select v::text from t_out where k = 'cars'));
select pg_temp.check((select bool_and(c - array['lat', 'lng', 'kind', 'heading'] = '{}'::jsonb)
                        from t_out, jsonb_array_elements(v->'cars') c where k = 'cars'),
  'a car is a dot and its kind: no name, plate, photo, rating or id');
select pg_temp.check((select bool_and(public.rider_live_map_metres((c->>'lat')::float8, (c->>'lng')::float8, 3.1210, 101.6810)
                                     between 70 and 155
                                   or public.rider_live_map_metres((c->>'lat')::float8, (c->>'lng')::float8, 3.1190, 101.6790)
                                     between 70 and 155)
                        from t_out, jsonb_array_elements(v->'cars') c where k = 'cars'),
  'each car is moved half to all of 150 m off its real spot');
select pg_temp.check((select (v->>'pickupMin')::int >= 1 from t_out where k = 'cars'), 'the pickup time, in minutes');
select pg_temp.check((public.rider_live_map_cars(3.1205, 101.6800, '{"country": "Malaysia"}')->>'cached')::boolean,
  'a call within the interval gets the last answer');
reset role;
delete from public.rider_live_map_calls;
update public.rider_live_map_rules set cars_fields = array['car'] where country = 'Malaysia' and state = '';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a4');
select pg_temp.check((select bool_and(c->>'kind' = 'car') and count(*) = 1
                        from jsonb_array_elements(public.rider_live_map_cars(3.1205, 101.6800, '{"country": "Malaysia"}')->'cars') c),
  'the kinds the rule shows, and no count or pickup time unless shown');
reset role;
delete from public.rider_live_map_calls;

-- ---- 3. Busy areas -------------------------------------------------------------------------------
-- The hexagon maths: a centre falls in its own cell, neighbours are one step away.
select pg_temp.check((select bool_and((public.rider_live_map_hex_of(c.lat, c.lng, 350, 3)).q = g.q
                                      and (public.rider_live_map_hex_of(c.lat, c.lng, 350, 3)).r = g.r)
                        from (values (0, 0), (5, -3), (-7, 2), (1050, 34)) g(q, r)
                        cross join lateral public.rider_live_map_hex_centre(g.q, g.r, 350, 3) c),
  'a centre is in its own hexagon');
select pg_temp.check((select abs(public.rider_live_map_metres(a.lat, a.lng, b.lat, b.lng) - 350) < 3
                        from public.rider_live_map_hex_centre(1050, 34, 350, 3) a,
                             public.rider_live_map_hex_centre(1051, 34, 350, 3) b),
  'neighbouring centres are one hexagon across apart');
select pg_temp.check(public.rider_live_map_level(4, 5) is null and public.rider_live_map_level(5, 5) = 0
  and public.rider_live_map_level(14, 5) = 2 and public.rider_live_map_level(40, 5) = 4, 'the levels');

-- Six requests in one cell, three in another, and fare answers starting in the first.
insert into public.ride_requests (rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, payment_mode, country, suburb)
select '00000000-0000-0000-0000-0000000322a4', 'open', 3.1180 + i * 0.00001, 101.6750, 10, 10, 'Cash', 'Malaysia', 'Mid Valley'
  from generate_series(1, 6) i;
insert into public.ride_requests (rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, payment_mode, country)
select '00000000-0000-0000-0000-0000000322a4', 'open', 3.1400, 101.7000, 10, 10, 'Cash', 'Malaysia'
  from generate_series(1, 3) i;
insert into public.fare_ai_responses (origin_lat, origin_lng, success, duration_min, standard_duration_min)
values (3.1181, 101.6750, true, 28, 20), (3.1182, 101.6751, true, 28, 20);

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a4');
insert into t_out select 'busy', public.rider_live_map_busy(3.08, 101.62, 3.16, 101.74, '{"country": "Malaysia"}');
select pg_temp.check((select jsonb_array_length(v->'cells') = 1 from t_out where k = 'busy'),
  'only a hexagon with the minimum shows: ' || (select v::text from t_out where k = 'busy'));
select pg_temp.check((select bool_and(c - array['q', 'r', 'lat', 'lng', 'level', 'area', 'fare', 'wait', 'next', 'tip'] = '{}'::jsonb)
                        from t_out, jsonb_array_elements(v->'cells') c where k = 'busy'),
  'no counts and no trip ids');
select pg_temp.check((select (v->'cells'->0->>'level')::int = 0 and (v->'cells'->0->>'fare')::numeric = 1.4
                         and v->'cells'->0->>'area' = 'Mid Valley' and (v->>'latRef')::int = 3
                         and (v->>'hexM')::int = 350 from t_out where k = 'busy'),
  'its level, the fare level as the fare trend compares, the area');
select pg_temp.check((public.rider_live_map_busy(3.08, 101.62, 3.16, 101.74, '{"country": "Malaysia"}')->>'cached')::boolean,
  'busy areas answer at most once per interval');
reset role;
delete from public.rider_live_map_calls;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a4');
select pg_temp.check((select jsonb_array_length(v->'cells') = 2 and bool_and(c.value->>'wait' is null)
                        from (select public.rider_live_map_busy(3.08, 101.62, 3.16, 101.74,
                                '{"country": "Malaysia", "state": "Kuala Lumpur", "city": "Kuala Lumpur"}') as v) x,
                             jsonb_array_elements(x.v->'cells') c group by x.v),
  'the city''s own minimum and fields');
reset role;
delete from public.rider_live_map_calls;

-- ---- 4. My people --------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a1');
insert into t_ids select 'm1', (public.family_invite('{"country": "Malaysia"}', '+60100322002', 'Aisha')->>'id')::uuid;
insert into t_ids select 'm2', (public.family_invite('{"country": "Malaysia"}', '+60100322003', 'Iman')->>'id')::uuid;
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a2');
select public.family_respond((select id from t_ids where k = 'm1'), true, '{"shown": ["payments", "location"]}');
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a3');
select public.family_respond((select id from t_ids where k = 'm2'), true, '{"shown": ["payments", "location"]}');
select pg_temp.check(not (public.rider_live_map_config('{}')->'people'->>'on')::boolean,
  'a member does not see My people while the rule says family hosts');
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a1');
select pg_temp.check((public.rider_live_map_config('{}')->'people'->>'on')::boolean, 'the host has My people');
select pg_temp.check(jsonb_array_length(public.rider_live_map_people('{}')->'people') = 0,
  'nobody shows before a shared trip');
reset role;
delete from public.rider_live_map_calls;

insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
values ('00000000-0000-0000-0000-0000000322a1', 'get_wallet', 'topup', 100, 'test', 'test');
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, payment_mode, country,
                                  pickup_name, drop_name, drop_lat, drop_lng)
values ('00000000-0000-0000-0000-0000000322f1', '00000000-0000-0000-0000-0000000322a2', 'open', 3.12, 101.68, 15, 15,
        'Family', 'Malaysia', 'Mid Valley', 'KLCC', 3.158, 101.712);
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000322b1', status = 'accepted'
 where id = '00000000-0000-0000-0000-0000000322f1';
update public.ride_requests set status = 'on_trip', started_at = now() - interval '5 minutes', duration_min = 20,
       partner_name = 'Siti Sample', partner_vehicle = 'Perodua Bezza, silver', partner_plate = 'WXY 1234',
       partner_live_lat = 3.130, partner_live_lng = 101.690, partner_live_at = now()
 where id = '00000000-0000-0000-0000-0000000322f1';
select pg_temp.check((select live_share from public.family_trips where trip_id = '00000000-0000-0000-0000-0000000322f1'),
  'the member''s ride is shared with the family');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a1');
insert into t_out select 'people', public.rider_live_map_people('{}');
select pg_temp.check((select jsonb_array_length(v->'people') = 1 and v->'people'->0->>'name' = 'Aisha'
                        and v->'people'->0->>'status' = 'on_trip' and (v->'people'->0->>'eta')::int = 15
                        and v->'people'->0->>'driver' = 'Siti' and v->'people'->0->>'car' = 'Perodua Bezza, silver'
                        and (v->'people'->0->>'lat')::float8 = 3.13
                        and v->'people'->0->>'dropoffAt' is not null from t_out where k = 'people'),
  'the host sees the shared trip: ' || (select v::text from t_out where k = 'people'));
select pg_temp.check((select position('WXY' in v::text) = 0 and not (v->'people'->0 ? 'trail') from t_out where k = 'people'),
  'never the plate; no route history by default');
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a2');
select pg_temp.check((public.family_trip_status('00000000-0000-0000-0000-0000000322f1')->>'shared')::boolean
  and jsonb_array_length(public.family_trip_status('00000000-0000-0000-0000-0000000322f1')->'viewers') = 1,
  'the member sees "Shared with family" and who can see');
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a4');
select pg_temp.check(not (public.rider_live_map_people('{}')->>'on')::boolean, 'a stranger sees no one');
select pg_temp.refused($q$select public.rider_live_map_stop_sharing('00000000-0000-0000-0000-0000000322f1')$q$,
  'RLM_NOT_YOURS', 'someone else stopping the member''s sharing');
reset role;
delete from public.rider_live_map_calls;

-- All members, with a route history.
update public.rider_live_map_rules set people_who = 'members', people_history_min = 10 where country = 'Malaysia' and state = '';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a3');
select pg_temp.check((select jsonb_array_length(v->'people') = 1 and v->'people'->0->>'name' = 'Aisha'
                        and jsonb_array_length(v->'people'->0->'trail') = 1
                        from (select public.rider_live_map_people('{}') v) x),
  'where the rule says all members, a member sees the others'' shared trips');
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a2');
select pg_temp.check(jsonb_array_length(public.family_trip_status('00000000-0000-0000-0000-0000000322f1')->'viewers') = 2
  and public.family_trip_status('00000000-0000-0000-0000-0000000322f1')->'viewers'->1->>'role' = 'members',
  'and the member is told the family members can see');
-- The member stops at once.
select public.rider_live_map_stop_sharing('00000000-0000-0000-0000-0000000322f1');
select pg_temp.check(not (public.family_trip_status('00000000-0000-0000-0000-0000000322f1')->>'shared')::boolean,
  'stopped: no longer shared');
reset role;
delete from public.rider_live_map_calls;
select pg_temp.check((select count(*) from public.rider_live_map_trail where trip_id = '00000000-0000-0000-0000-0000000322f1') = 0,
  'its route history is gone');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a1');
select pg_temp.check(jsonb_array_length(public.rider_live_map_people('{}')->'people') = 0, 'the host no longer sees it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a3');
select pg_temp.check(jsonb_array_length(public.rider_live_map_people('{}')->'people') = 0, 'nor the other member');
reset role;
delete from public.rider_live_map_calls;

-- ---- 5. Team -------------------------------------------------------------------------------------
insert into public.business_accounts (id, name, reg_no, country, state, city, status) values
  ('00000000-0000-0000-0000-0000000322aa', 'Acme Contoh Sdn Bhd', '202601032201', 'Malaysia', 'Kuala Lumpur', 'Kuala Lumpur', 'active');
insert into public.business_members (account_id, profile_id, phone, name, role, status) values
  ('00000000-0000-0000-0000-0000000322aa', '00000000-0000-0000-0000-0000000322d1', '+60100322031', 'Mei Travel', 'admin', 'active'),
  ('00000000-0000-0000-0000-0000000322aa', '00000000-0000-0000-0000-0000000322d2', '+60100322032', 'Lim Staff', 'booker', 'active'),
  ('00000000-0000-0000-0000-0000000322aa', '00000000-0000-0000-0000-0000000322d3', '+60100322033', 'Tan Staff', 'rider', 'active');
-- A company trip and a personal one, both under way.
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, payment_mode, country,
                                  pickup_name, drop_name)
values ('00000000-0000-0000-0000-0000000322f2', '00000000-0000-0000-0000-0000000322d2', 'open', 3.12, 101.68, 14.2, 14.2,
        'Cash', 'Malaysia', 'Acme, Bangsar South', 'Jalan Ampang'),
       ('00000000-0000-0000-0000-0000000322f3', '00000000-0000-0000-0000-0000000322d2', 'open', 3.12, 101.68, 9, 9,
        'Cash', 'Malaysia', 'Home', 'Gym');
update public.ride_requests set business_account_id = '00000000-0000-0000-0000-0000000322aa', business_note = 'Client visit'
 where id = '00000000-0000-0000-0000-0000000322f2';
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000322b2', status = 'accepted'
 where id in ('00000000-0000-0000-0000-0000000322f2', '00000000-0000-0000-0000-0000000322f3');
update public.ride_requests set status = 'on_trip', started_at = now() - interval '4 minutes', duration_min = 12,
       partner_live_lat = 3.125, partner_live_lng = 101.685, partner_live_at = now()
 where id in ('00000000-0000-0000-0000-0000000322f2', '00000000-0000-0000-0000-0000000322f3');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000322d1');
insert into t_out select 'team', public.rider_live_map_team('{}');
select pg_temp.check((select jsonb_array_length(v->'trips') = 1 and v->'trips'->0->>'name' = 'Lim'
                        and v->'trips'->0->>'purpose' = 'Client visit' and (v->'trips'->0->>'eta')::int = 8
                        and (v->'trips'->0->>'cost')::numeric = 14.2 and v->'trips'->0->>'company' = 'Acme Contoh Sdn Bhd'
                        from t_out where k = 'team'),
  'the travel admin sees the company trip, never the personal one: ' || (select v::text from t_out where k = 'team'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000322d3');
select pg_temp.check(not (public.rider_live_map_team('{}')->>'on')::boolean, 'staff who are not travel admins see nothing');
select pg_temp.as_user('00000000-0000-0000-0000-0000000322d2');
select pg_temp.check((public.rider_live_map_trip_note('00000000-0000-0000-0000-0000000322f2')->>'shown')::boolean
  and public.rider_live_map_trip_note('00000000-0000-0000-0000-0000000322f2')->>'who' = 'admins'
  and public.rider_live_map_trip_note('00000000-0000-0000-0000-0000000322f2')->'seenBy'->0->>'name' = 'Mei',
  'the member''s "Company trip" chip: who can see and who looked');
select pg_temp.check(public.rider_live_map_trip_note('00000000-0000-0000-0000-0000000322f3') = '{}'::jsonb,
  'a personal trip has no chip');
select pg_temp.as_user('00000000-0000-0000-0000-0000000322a4');
select pg_temp.check(public.rider_live_map_trip_note('00000000-0000-0000-0000-0000000322f2') = '{}'::jsonb,
  'someone else learns nothing of the trip');
reset role;
delete from public.rider_live_map_calls;
update public.rider_live_map_rules set team_who = 'staff' where country = 'Malaysia' and state = '';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000322d3');
select pg_temp.check(jsonb_array_length(public.rider_live_map_team('{}')->'trips') = 1, 'all staff, where the rule says so');
reset role;
update public.rider_live_map_rules set team_on = false where country = 'Malaysia' and state = '';
delete from public.rider_live_map_calls;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000322d1');
select pg_temp.check(not (public.rider_live_map_team('{}')->>'on')::boolean, 'off: nobody sees company trips');
reset role;

rollback;
