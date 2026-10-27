-- ============================================================================
-- Regression test for migration 0297: tags on the rider's rating of the
-- driver, the driver's own totals, and the admin's flag.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/driver_rating_tags_0297.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000297a1'),  -- rider 1
  ('00000000-0000-0000-0000-0000000297a2'),  -- rider 2
  ('00000000-0000-0000-0000-0000000297a3'),  -- rider 3
  ('00000000-0000-0000-0000-0000000297b1'),  -- the driver
  ('00000000-0000-0000-0000-0000000297c1'),  -- admin, EDIT on Partners
  ('00000000-0000-0000-0000-0000000297c2')   -- admin, READ on Partners
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000297%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000297c1', 'admin-partners', 'edit'),
  ('00000000-0000-0000-0000-0000000297c2', 'admin-partners', 'read')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone) values
  ('00000000-0000-0000-0000-0000000297b1', 'Dan', '+60110000297');

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
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
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.refused(text, text)
  to authenticated;

insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name, completed_at) values
  ('00000000-0000-0000-0000-0000000297e1', '00000000-0000-0000-0000-0000000297a1',
   '00000000-0000-0000-0000-0000000297b1', 'completed', 20, 20, 'KLCC', now()),
  ('00000000-0000-0000-0000-0000000297e2', '00000000-0000-0000-0000-0000000297a2',
   '00000000-0000-0000-0000-0000000297b1', 'completed', 20, 20, 'Mid Valley', now()),
  ('00000000-0000-0000-0000-0000000297e3', '00000000-0000-0000-0000-0000000297a3',
   '00000000-0000-0000-0000-0000000297b1', 'completed', 20, 20, 'Bangsar', now());

select pg_temp.check((select count(*) = 10 from public.driver_rating_tags where active), 'ten tags to start with');

set local role authenticated;

-- 1. Tags with the rating ---------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000297a1');
select pg_temp.check(
  (public.rate_ride('00000000-0000-0000-0000-0000000297e1', 5, null, array['Clean car', 'Rude', 'Made up', 'Clean car'])
     ->'tags') = '["Clean car"]'::jsonb,
  'only the 4-5 star list''s tags are kept, each once');
-- An app from before 0297 (no tags) keeps the tags given.
select public.rate_ride('00000000-0000-0000-0000-0000000297e1', 4, 'Nice');
select pg_temp.check((select tags = array['Clean car'] from public.ride_ratings
                       where request_id = '00000000-0000-0000-0000-0000000297e1'), 'no tags sent: the tags stay');
-- Down to 2 stars: the 4-5 star tags go.
select public.rate_ride('00000000-0000-0000-0000-0000000297e1', 2, null, array['Unsafe driving', 'Clean car']);
select pg_temp.check((select tags = array['Unsafe driving'] from public.ride_ratings
                       where request_id = '00000000-0000-0000-0000-0000000297e1'), 'a low rating keeps the low tags only');

select pg_temp.as_user('00000000-0000-0000-0000-0000000297a2');
select public.rate_ride('00000000-0000-0000-0000-0000000297e2', 1, null, array['Unsafe driving', 'Rude']);
select pg_temp.as_user('00000000-0000-0000-0000-0000000297a3');
select public.rate_ride('00000000-0000-0000-0000-0000000297e3', 2, null, array['Unsafe driving']);

-- 2. The driver's totals: counts only ------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000297b1');
select pg_temp.check((select count(*) = 0 from public.ride_ratings), 'the driver reads no rating rows');
select pg_temp.check((public.my_driver_rating_tags(30)->>'rated')::int = 3, 'three rated trips');
select pg_temp.check(
  (select (x->>'n')::int = 3 from jsonb_array_elements(public.my_driver_rating_tags(30)->'tags') x
    where x->>'tag' = 'Unsafe driving'),
  'Unsafe driving: 3');
select pg_temp.check(not (public.my_driver_rating_tags(30) ? 'flags'), 'the driver is not shown the flag');
select pg_temp.refused($q$select public.admin_driver_rating_tags('00000000-0000-0000-0000-0000000297b1')$q$,
                       'the driver reading the admin view');
select pg_temp.refused($q$select * from public.admin_rating_flags()$q$, 'the driver reading the flags');
select pg_temp.refused($q$select public.driver_rating_tags_set(array['A'], array['B'])$q$, 'the driver changing tags');

-- 3. The flag: 3 in 30 days by default ----------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000297c2');
select pg_temp.check(
  (public.admin_driver_rating_tags('00000000-0000-0000-0000-0000000297b1')->'flags') = '[{"n": 3, "tag": "Unsafe driving"}]'::jsonb,
  'flagged for Unsafe driving, 3 times');
select pg_temp.check((select count(*) = 1 from public.admin_rating_flags()), 'one flag on the Partners list');
select pg_temp.refused($q$select public.driver_rating_flag_rule_set(5, 30)$q$, 'a read-only admin changing the rule');
select pg_temp.refused($q$select public.admin_rating_flag_review('00000000-0000-0000-0000-0000000297b1', 'Unsafe driving')$q$,
                       'a read-only admin marking reviewed');

select pg_temp.as_user('00000000-0000-0000-0000-0000000297c1');
select public.driver_rating_flag_rule_set(4, 30);
select pg_temp.check(
  (public.admin_driver_rating_tags('00000000-0000-0000-0000-0000000297b1')->'flags') = '[]'::jsonb,
  'at 4 times, not flagged');
select pg_temp.refused($q$select public.driver_rating_flag_rule_set(0, 30)$q$, 'a rule of 0 times');
select pg_temp.refused($q$select public.driver_rating_flag_rule_set(3, 91)$q$, 'a rule over 90 days');
select public.driver_rating_flag_rule_set(3, 30);
select public.admin_rating_flag_review('00000000-0000-0000-0000-0000000297b1', 'Unsafe driving');
select pg_temp.check(
  (public.admin_driver_rating_tags('00000000-0000-0000-0000-0000000297b1')->'flags') = '[]'::jsonb,
  'marked reviewed: counted afresh');

-- 4. The admin edits the tags ----------------------------------------------------------------------
select public.driver_rating_tags_set(array['Smooth ride', 'Clean car'], array['Unsafe driving']);
select pg_temp.check((select array_agg(tag order by low, position) = array['Smooth ride', 'Clean car', 'Unsafe driving']
                        from public.driver_rating_tags where active), 'the new lists are the active tags');
select pg_temp.check((select not active from public.driver_rating_tags where tag = 'Rude'),
                     'a removed tag is kept, inactive');
select pg_temp.refused($q$select public.driver_rating_tags_set(array['Late'], array['late'])$q$, 'the same tag twice');
select pg_temp.as_user('00000000-0000-0000-0000-0000000297b1');
select pg_temp.check(
  (select (x->>'n')::int = 1 from jsonb_array_elements(public.my_driver_rating_tags(30)->'tags') x where x->>'tag' = 'Rude'),
  'a removed tag''s totals still show');

reset role;
rollback;

select 'driver_rating_tags_0297: all passed';
