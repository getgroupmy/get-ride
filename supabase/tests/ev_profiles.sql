-- ============================================================================
-- Regression test for migration 0202: EV profiles and OBD captures. Only an
-- admin writes profiles; everyone signed in reads the active ones (directly
-- and through ev_profiles_for_app()); profiles are validated on save; a
-- driver uploads and reads only their own captures, an admin reads and
-- deletes all of them; a capture holds at most 2000 entries.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ev_profiles.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
end $$;

create or replace function pg_temp.as_user(p uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p::text, true),
         set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
$$;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'FAILED: % was allowed', p_what;
exception when others then
  if sqlerrm like 'FAILED:%' then raise; end if;
end $$;

-- An update or delete that RLS hides changes no row rather than failing.
create or replace function pg_temp.rows(p_sql text) returns bigint language plpgsql as $$
declare n bigint;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end $$;

grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.refused(text, text),
  pg_temp.rows(text) to authenticated, anon;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000202a1'),  -- admin
  ('00000000-0000-0000-0000-0000000202b1'),  -- driver
  ('00000000-0000-0000-0000-0000000202c1')   -- another driver
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000202a1', 'admin-settings-ev-profiles', 'edit')
on conflict do nothing;

-- 1. Validation --------------------------------------------------------------------------------
select pg_temp.check(cardinality(public.ev_profile_problems('["ATSP6", "ATSH7E4", "1003"]',
                       '{"request": "22F190", "header": "7E4", "expect": "62F190"}',
                       '[{"key": "soc", "header": "7E4", "request": "220105", "start": 4, "length": 1,
                          "signed": false, "scale": 0.5, "offset": 0, "unit": "%"},
                         {"key": "charging", "header": "18DADBF1", "request": "220101", "start": 0, "length": 1,
                          "bit": 3}]', true)) = 0,
  'a well-formed profile has no problems');
select pg_temp.check(cardinality(public.ev_profile_problems('["ATSP6; drop table x"]', null, '[]', false)) = 1,
  'an init entry that is neither AT nor hex is refused');
select pg_temp.check(cardinality(public.ev_profile_problems('[]', null, '[]', true)) = 2,
  'an active profile needs a detect request and a signal');
select pg_temp.check(cardinality(public.ev_profile_problems('[]', '{"request": "22F190"}',
                       '[{"key": "fuel", "header": "7E", "request": "22G1", "start": "x", "length": 6, "bit": 9}]',
                       false)) = 6,
  'unknown key, bad header, bad request, bad start, bad length, bad bit');

-- 2. Profiles: admin writes, others read the active ones ---------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000202a1');
insert into public.ev_profiles (id, make, model, years, active, init, detect, signals) values
  ('00000000-0000-0000-0000-00000002020a', 'Testmake', 'Alpha', '2024-2025', true, '["ATSP6"]',
   '{"request": "22F190", "header": "7E4"}',
   '[{"key": "soc", "header": "7E4", "request": "220105", "start": 4, "length": 1, "scale": 0.5}]'),
  ('00000000-0000-0000-0000-00000002020b', 'Testmake', 'Beta', null, false, '[]', null, '[]');
select pg_temp.check((select updated_by = '00000000-0000-0000-0000-0000000202a1' from public.ev_profiles
                       where id = '00000000-0000-0000-0000-00000002020a'), 'who saved it is kept');
select pg_temp.refused($q$insert into public.ev_profiles (make, model, active, signals)
                          values ('Testmake', 'Gamma', true, '[]')$q$,
  'an admin saving an active profile with no detect request');
select pg_temp.check((select count(*) = 2 from public.ev_profiles where make = 'Testmake'),
  'the admin reads every profile');

select pg_temp.as_user('00000000-0000-0000-0000-0000000202b1');
select pg_temp.check((select count(*) = 1 from public.ev_profiles where make = 'Testmake'),
  'a driver reads only the active profile');
select pg_temp.check((select count(*) = 1 from jsonb_array_elements(public.ev_profiles_for_app()) e
                       where e->>'make' = 'Testmake' and e->>'model' = 'Alpha'),
  'ev_profiles_for_app gives the active profile');
select pg_temp.check((select not exists (select 1 from jsonb_array_elements(public.ev_profiles_for_app()) e
                       where e->>'model' = 'Beta')), 'and not the inactive one');
select pg_temp.refused($q$insert into public.ev_profiles (make, model) values ('Testmake', 'Mine')$q$,
  'a driver adding a profile');
select pg_temp.check(pg_temp.rows($q$update public.ev_profiles set label = 'x'
                                     where id = '00000000-0000-0000-0000-00000002020a'$q$) = 0,
  'a driver changing a profile changes nothing');
select pg_temp.check(pg_temp.rows($q$delete from public.ev_profiles
                                     where id = '00000000-0000-0000-0000-00000002020a'$q$) = 0,
  'a driver deleting a profile deletes nothing');

-- 3. Captures: own only, admin all ---------------------------------------------------------------
insert into public.obd_captures (vehicle, battery_hint, reader, app_version, entries) values
  ('Testmake Alpha 2024', '80%', 'ELM327 v1.5', '1.5.0',
   '[{"header": "7E4", "request": "22F190", "reply": "NO DATA", "ms": 120}]');
select pg_temp.check((select profile_id = '00000000-0000-0000-0000-0000000202b1' from public.obd_captures
                       where vehicle = 'Testmake Alpha 2024'), 'the capture is the driver''s own');
select pg_temp.refused($q$insert into public.obd_captures (profile_id, vehicle)
                          values ('00000000-0000-0000-0000-0000000202c1', 'Someone else')$q$,
  'a driver uploading in another''s name');
select pg_temp.refused($q$insert into public.obd_captures (vehicle, entries)
                          select 'Too long', jsonb_agg(jsonb_build_object('request', '0100')) from generate_series(1, 2001)$q$,
  'a capture of more than 2000 entries');

select pg_temp.as_user('00000000-0000-0000-0000-0000000202c1');
insert into public.obd_captures (vehicle) values ('Other car 2025');
select pg_temp.check((select count(*) = 1 from public.obd_captures), 'another driver sees only their own capture');
select pg_temp.check(pg_temp.rows($q$delete from public.obd_captures where vehicle = 'Other car 2025'$q$) = 0,
  'a driver cannot delete a capture');

select pg_temp.as_user('00000000-0000-0000-0000-0000000202a1');
select pg_temp.check((select count(*) = 2 from public.obd_captures
                       where vehicle in ('Testmake Alpha 2024', 'Other car 2025')), 'the admin reads every capture');
select pg_temp.check(pg_temp.rows($q$delete from public.obd_captures where vehicle = 'Other car 2025'$q$) = 1,
  'and deletes one');
reset role;

-- 4. Anonymous callers ---------------------------------------------------------------------------
set local role anon;
select pg_temp.refused($q$select count(*) from public.ev_profiles$q$, 'an anonymous caller reading profiles');
select pg_temp.refused($q$select public.ev_profiles_for_app()$q$, 'an anonymous caller asking for profiles');
reset role;

select 'ev_profiles: all passed';
rollback;
