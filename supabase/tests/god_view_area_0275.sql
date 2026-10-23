-- ============================================================================
-- Regression test for migration 0275: God View. The phone's area follows its
-- position, and the people with no location are listed.
--   * push_set_location records where (and when) the area was set;
--   * a check-in or background report that hardly moved leaves the area
--     alone, without a lookup;
--   * past 1 km (or 200 m once the area is 30 minutes old) the names come
--     from the regions: the most specific mapped region holding the point,
--     the smaller of two states (the enclave), and open levels keep the old
--     name only nearby, under the same region and not outside its mapped
--     boundary; a far-away suburb is cleared, never kept;
--   * an area set before 0275 (no area point) is refreshed on the next move;
--   * God View reads the refreshed area;
--   * nobody but the definer functions calls the helpers;
--   * god_view_unlocated lists everyone God View cannot place (no app, never
--     located, located before the 7-day window), partner or user, never a
--     phone number, searchable, and a sub-admin only those who can be
--     placed in their region.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/god_view_area_0275.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if has_function_privilege('anon', 'public.push_area_lookup(double precision, double precision, double precision, double precision, text, text, text, text)', 'execute')
     or has_function_privilege('authenticated', 'public.push_area_lookup(double precision, double precision, double precision, double precision, text, text, text, text)', 'execute')
     or has_function_privilege('anon', 'public.push_area_refresh(uuid, double precision, double precision)', 'execute')
     or has_function_privilege('authenticated', 'public.push_area_refresh(uuid, double precision, double precision)', 'execute')
     or has_function_privilege('anon', 'public.push_checkin(text[], double precision, double precision, boolean, boolean, text)', 'execute')
     or not has_function_privilege('authenticated', 'public.push_checkin(text[], double precision, double precision, boolean, boolean, text)', 'execute')
     or not has_function_privilege('anon', 'public.push_background_location(text, double precision, double precision)', 'execute')
     or has_function_privilege('anon', 'public.push_set_location(text[], double precision, double precision, text, text, text, text)', 'execute')
     or not has_function_privilege('authenticated', 'public.push_set_location(text[], double precision, double precision, text, text, text, text)', 'execute') then
    raise exception 'FAILED: 0275 function grants';
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
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
create function pg_temp.area(p_token text) returns text language sql as $$
  select concat_ws(' / ', coalesce(area_country, '-'), coalesce(area_state, '-'), coalesce(area_city, '-'),
                   coalesce(area_suburb, '-'))
    from public.push_tokens where token = p_token
$$;
-- The open app moves on (the 3-minute hold on background reports is 0272's).
create function pg_temp.idle(p_token text) returns void language sql as $$
  update public.push_tokens set located_at = now() - interval '4 minutes' where token = p_token
$$;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000275a1', '60127500001'),  -- full admin
  ('00000000-0000-0000-0000-0000000275f1', '60127500011'),  -- always on
  ('00000000-0000-0000-0000-0000000275f2', '60127500012')   -- area set before 0275
on conflict do nothing;
insert into public.profiles (id, name, phone)
select id, 'PA275 ' || right(id::text, 2), '+' || phone from auth.users
 where id::text like '00000000-0000-0000-0000-0000000275%'
on conflict (id) do update set name = excluded.name, phone = excluded.phone;
insert into public.admin_access (profile_id, page, access_level, region) values
  ('00000000-0000-0000-0000-0000000275a1', '*', 'edit', null)
on conflict do nothing;

-- Arealand 275: lng 140..142, lat 40..42. West 275 and East 275 split it at
-- lng 141; Inner 275 is a state inside East's outline (the enclave); Port
-- 275 is a city in East; Kampung 275 is only the geocoder's suburb name.
insert into public.countries (name) values ('Arealand 275') on conflict do nothing;
insert into public.states (country, name) values
  ('Arealand 275', 'West 275'), ('Arealand 275', 'East 275'), ('Arealand 275', 'Inner 275')
on conflict do nothing;
insert into public.cities (country, state, name) values ('Arealand 275', 'East 275', 'Port 275')
on conflict do nothing;
update public.countries set boundary_polys = array['((140,40),(142,40),(142,42),(140,42))'::polygon]
 where name = 'Arealand 275';
update public.states set boundary_polys = array['((140,40),(141,40),(141,42),(140,42))'::polygon]
 where country = 'Arealand 275' and name = 'West 275';
update public.states set boundary_polys = array['((141,40),(142,40),(142,42),(141,42))'::polygon]
 where country = 'Arealand 275' and name = 'East 275';
update public.states set boundary_polys = array['((141.6,41.6),(141.8,41.6),(141.8,41.8),(141.6,41.8))'::polygon]
 where country = 'Arealand 275' and name = 'Inner 275';
update public.cities set boundary_polys = array['((141,40),(141.5,40),(141.5,40.5),(141,40.5))'::polygon]
 where country = 'Arealand 275' and state = 'East 275' and name = 'Port 275';

insert into public.push_tokens (profile_id, token, platform, last_lat, last_lng, located_at, located_bg,
                                location_always, area_country, area_state, area_city, area_suburb) values
  ('00000000-0000-0000-0000-0000000275f1', 'pa275-f1', 'android', null, null, null, false, false, null, null, null, null),
  -- Before 0275: named at the last position, in West 275, with no area point.
  ('00000000-0000-0000-0000-0000000275f2', 'pa275-f2', 'android', 40.3, 140.99, now() - interval '20 minutes', true, true,
   'Arealand 275', 'West 275', 'Hill 275', 'Lane 275');
update public.push_tokens
   set bg_key_hash = encode(extensions.digest('m275m275m275m275m275m275m275m275m275m275', 'sha256'), 'hex')
 where token = 'pa275-f2';

-- 1. The open app names the area ----------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000275f1');
select pg_temp.check(public.push_set_location(array['pa275-f1'], 40.1, 141.1,
                       'Arealand 275', 'East 275', 'Port 275', 'Kampung 275') = 1, 'push_set_location');
reset role;
select pg_temp.check((select area_lat = 40.1 and area_lng = 141.1 and area_set_at = now() from public.push_tokens
                       where token = 'pa275-f1'), 'push_set_location records where and when the area was set');
update public.push_tokens set area_set_at = now() - interval '5 minutes' where token = 'pa275-f1';

-- 2. Hardly moved: left alone --------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000275f1');
select pg_temp.check(public.push_checkin(array['pa275-f1'], 40.1009, 141.1, false, true,
                       'k275k275k275k275k275k275k275k275k275k275') = 1, 'a check-in 100 m on');
reset role;
select pg_temp.check((select last_lat = 40.1009 and area_lat = 40.1 and area_set_at = now() - interval '5 minutes'
                        from public.push_tokens where token = 'pa275-f1')
                     and pg_temp.area('pa275-f1') = 'Arealand 275 / East 275 / Port 275 / Kampung 275',
  'a check-in 100 m on leaves the area alone');
-- 500 m, the area 5 minutes old: still left alone.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000275f1');
select public.push_checkin(array['pa275-f1'], 40.1045, 141.1, false, true, 'k275k275k275k275k275k275k275k275k275k275');
reset role;
select pg_temp.check((select area_lat = 40.1 from public.push_tokens where token = 'pa275-f1'),
  'a fresh area is kept within 1 km');
-- The same 500 m with the area 40 minutes old: looked up, the suburb kept
-- (under the same city, within 1 km).
update public.push_tokens set area_set_at = now() - interval '40 minutes' where token = 'pa275-f1';
select pg_temp.idle('pa275-f1');
set local role anon;
select pg_temp.as_anon();
select pg_temp.check(public.push_background_location('k275k275k275k275k275k275k275k275k275k275', 40.1046, 141.1) = 1,
  'a background report 500 m on');
reset role;
select pg_temp.check((select area_lat = 40.1046 and area_set_at = now() from public.push_tokens where token = 'pa275-f1')
                     and pg_temp.area('pa275-f1') = 'Arealand 275 / East 275 / Port 275 / Kampung 275',
  'an old area 500 m on: refreshed, the nearby suburb kept: ' || pg_temp.area('pa275-f1'));

-- 3. Further: the regions decide -------------------------------------------------------------------
-- 3 km on, still in Port 275: the suburb is no longer right.
select pg_temp.idle('pa275-f1');
set local role anon;
select pg_temp.as_anon();
select public.push_background_location('k275k275k275k275k275k275k275k275k275k275', 40.13, 141.1);
reset role;
select pg_temp.check(pg_temp.area('pa275-f1') = 'Arealand 275 / East 275 / Port 275 / -',
  '3 km on: the city from its region, the far-away suburb cleared: ' || pg_temp.area('pa275-f1'));
-- Out of Port 275 (40 km): East 275 only.
select pg_temp.idle('pa275-f1');
set local role anon;
select pg_temp.as_anon();
select public.push_background_location('k275k275k275k275k275k275k275k275k275k275', 40.8, 141.3);
reset role;
select pg_temp.check(pg_temp.area('pa275-f1') = 'Arealand 275 / East 275 / - / -',
  'out of the city: the state, no city: ' || pg_temp.area('pa275-f1'));
-- Into Inner 275, inside East 275's outline: the smaller state wins.
select pg_temp.idle('pa275-f1');
set local role anon;
select pg_temp.as_anon();
select public.push_background_location('k275k275k275k275k275k275k275k275k275k275', 41.7, 141.7);
reset role;
select pg_temp.check(pg_temp.area('pa275-f1') = 'Arealand 275 / Inner 275 / - / -',
  'the enclave: the smaller state wins: ' || pg_temp.area('pa275-f1'));
-- Not moved since: one distance check, nothing rewritten.
update public.push_tokens set area_set_at = now() - interval '2 hours' where token = 'pa275-f1';
select pg_temp.idle('pa275-f1');
set local role anon;
select pg_temp.as_anon();
select public.push_background_location('k275k275k275k275k275k275k275k275k275k275', 41.7001, 141.7);
reset role;
select pg_temp.check((select area_set_at = now() - interval '2 hours' and area_lat = 41.7 from public.push_tokens
                       where token = 'pa275-f1'), 'a phone that has not moved keeps its area as it was');
-- Out of every mapped region: Arealand 275's boundary leaves the point out,
-- so not even the country is kept.
select pg_temp.idle('pa275-f1');
set local role anon;
select pg_temp.as_anon();
select public.push_background_location('k275k275k275k275k275k275k275k275k275k275', 43, 141.7);
reset role;
select pg_temp.check(pg_temp.area('pa275-f1') = '- / - / - / -',
  'outside the mapped country: no area: ' || pg_temp.area('pa275-f1'));

-- 4. Nothing mapped there: the old names, nearby only ------------------------------------------------
select pg_temp.check((select country = 'Nowhere 275' and state = 'Far 275' and city = 'Town 275' and suburb is null
                        from public.push_area_lookup(-60, -60.02, -60, -60, 'Nowhere 275', 'Far 275', 'Town 275', 'Spot 275')),
  'unmapped, 1.1 km on: country, state and city kept, the suburb cleared');
select pg_temp.check((select country = 'Nowhere 275' and state is null and city is null and suburb is null
                        from public.push_area_lookup(-60, -61.2, -60, -60, 'Nowhere 275', 'Far 275', 'Town 275', 'Spot 275')),
  'unmapped, 67 km on: the country only');
select pg_temp.check((select country is null and state is null
                        from public.push_area_lookup(-60, -61.2, null, null, 'Nowhere 275', 'Far 275', null, null)),
  'unmapped, from nowhere known: nothing kept');

-- 5. An area set before 0275 --------------------------------------------------------------------------
-- Named in West 275 (Hill 275, Lane 275), now reported 1.7 km east, in Port 275.
set local role anon;
select pg_temp.as_anon();
select pg_temp.check(public.push_background_location('m275m275m275m275m275m275m275m275m275m275', 40.3, 141.01) = 1,
  'a background report from an area without an area point');
reset role;
select pg_temp.check((select area_lat = 40.3 and area_lng = 141.01 and area_set_at = now() from public.push_tokens
                       where token = 'pa275-f2')
                     and pg_temp.area('pa275-f2') = 'Arealand 275 / East 275 / Port 275 / -',
  'an area set before 0275 is refreshed on the next move: ' || pg_temp.area('pa275-f2'));

-- 6. God View reads the refreshed area --------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000275a1');
select pg_temp.check((select x->>'status' = 'always_on' and x->>'area' = 'Port 275'
                        from jsonb_array_elements(public.god_view_snapshot()->'people') x
                       where x->>'id' = '00000000-0000-0000-0000-0000000275f2'),
  'God View shows the refreshed area');
reset role;

-- 7. The people with no location --------------------------------------------------------------------------
insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000275a2', '60127500002'),  -- God View, Arealand 275 (country only)
  ('00000000-0000-0000-0000-0000000275a3', '60127500003'),  -- God View, East 275
  ('00000000-0000-0000-0000-0000000275a4', '60127500004'),  -- God View, no region
  ('00000000-0000-0000-0000-0000000275b1', '60127500021'),  -- user, no token, from Arealand 275
  ('00000000-0000-0000-0000-0000000275b2', '60127500022'),  -- user, a token never located
  ('00000000-0000-0000-0000-0000000275b3', '60127500023'),  -- partner serving East 275, no token
  ('00000000-0000-0000-0000-0000000275b4', '60127500024'),  -- user located 10 days ago in East 275
  ('00000000-0000-0000-0000-0000000275b5', '60127500025')   -- user located yesterday: on the map
on conflict do nothing;
insert into public.profiles (id, name, phone)
select id, 'PA275 ' || right(id::text, 2), '+' || phone from auth.users
 where id::text like '00000000-0000-0000-0000-0000000275%'
on conflict (id) do update set name = excluded.name, phone = excluded.phone;
update public.profiles set nationality = 'Arealand 275' where id = '00000000-0000-0000-0000-0000000275b1';
update public.profiles set app_version = '1.2.0', app_platform = 'android' where id = '00000000-0000-0000-0000-0000000275b2';
insert into public.admin_access (profile_id, page, access_level, region) values
  ('00000000-0000-0000-0000-0000000275a2', 'admin-god-view', 'read', '{"country": "Arealand 275"}'),
  ('00000000-0000-0000-0000-0000000275a3', 'admin-god-view', 'read', '{"country": "Arealand 275", "state": "East 275"}'),
  ('00000000-0000-0000-0000-0000000275a4', 'admin-god-view', 'read', null)
on conflict do nothing;
insert into public.partners (id, auth_user_id, name, phone, status, plate, vehicle, vehicle_type,
                             service_countries, service_states) values
  ('00000000-0000-0000-0000-0000000275e3', '00000000-0000-0000-0000-0000000275b3', 'Nur', '60127500023', 'approved',
   'NL 275', 'Proton Saga', 'Car', array['Arealand 275'], array['East 275']);
insert into public.push_tokens (profile_id, token, platform, last_lat, last_lng, located_at,
                                area_country, area_state, area_city) values
  ('00000000-0000-0000-0000-0000000275b2', 'pa275-b2', 'android', null, null, null, null, null, null),
  ('00000000-0000-0000-0000-0000000275b4', 'pa275-b4', 'ios', 40.3, 141.2, now() - interval '10 days',
   'Arealand 275', 'East 275', 'Port 275'),
  ('00000000-0000-0000-0000-0000000275b5', 'pa275-b5', 'ios', 40.3, 141.2, now() - interval '1 day',
   'Arealand 275', 'East 275', 'Port 275');

create function pg_temp.unlocated(p_query text default null) returns jsonb language sql as $$
  select coalesce(jsonb_object_agg(right(u.id::text, 2), to_jsonb(u)), '{}'::jsonb)
    from public.god_view_unlocated(p_query) u
   where u.id::text like '00000000-0000-0000-0000-0000000275%'
$$;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000275a1');
create temp table u0275 as select pg_temp.unlocated() as a1;
reset role;
select pg_temp.check((select (a1->'b1'->>'reason') = 'no_app' and (a1->'b1'->>'kind') = 'user'
                         and (a1->'b2'->>'reason') = 'never_located' and (a1->'b2'->>'app_version') = '1.2.0'
                         and (a1->'b2'->>'token_platform') = 'android'
                         and (a1->'b3'->>'reason') = 'no_app' and (a1->'b3'->>'kind') = 'partner'
                         and (a1->'b3'->>'plate') = 'NL 275'
                         and (a1->'b3'->>'partner_row_id') = '00000000-0000-0000-0000-0000000275e3'
                         and (a1->'b4'->>'reason') = 'stale'
                         and (a1->'b4'->>'last_seen_at')::timestamptz = now() - interval '10 days'
                         and not (a1 ? 'b5') and not (a1 ? 'f1') and not (a1 ? 'f2')
                         and not (a1->'b1' ? 'phone') from u0275),
  'a full admin sees everyone with no location, with the reason: ' || (select a1::text from u0275));
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000275a1');
select pg_temp.check((select array_agg(k order by k) = array['b3'] from jsonb_object_keys(pg_temp.unlocated('nl275')) k),
  'search by plate');
select pg_temp.check((select array_agg(k order by k) = array['b2'] from jsonb_object_keys(pg_temp.unlocated('7500022')) k),
  'search by phone digits');
select pg_temp.as_user('00000000-0000-0000-0000-0000000275a2');
select pg_temp.check((select array_agg(k order by k) = array['b1', 'b3', 'b4'] from jsonb_object_keys(pg_temp.unlocated()) k),
  'a country-wide sub-admin: the profile''s country, the partner''s service area, the old position; '
  || (select pg_temp.unlocated()::text));
select pg_temp.as_user('00000000-0000-0000-0000-0000000275a3');
select pg_temp.check((select array_agg(k order by k) = array['b3', 'b4'] from jsonb_object_keys(pg_temp.unlocated()) k),
  'a state sub-admin: the partner serving it and the old position in it, no country-only match');
select pg_temp.as_user('00000000-0000-0000-0000-0000000275a4');
select pg_temp.check(pg_temp.unlocated() = '{}'::jsonb, 'a sub-admin with no region sees nobody');
select pg_temp.as_user('00000000-0000-0000-0000-0000000275b1');
do $$
begin
  perform public.god_view_unlocated();
  raise exception 'FAILED: a non-admin read the no-location list';
exception when insufficient_privilege then null;
end $$;
reset role;
set local role anon;
select pg_temp.as_anon();
do $$
begin
  perform public.god_view_unlocated();
  raise exception 'FAILED: anon read the no-location list';
exception when insufficient_privilege then null;
end $$;
reset role;

rollback;
