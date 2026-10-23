-- ============================================================================
-- Regression test for migration 0278: God View → Movement.
--   * a closed app's background report also lands in user_location_history;
--   * god_view_trail returns the points in the window, oldest first, to an
--     admin with God View; refuses anyone else, a backwards or a longer than
--     48-hour window; thins a long trail keeping the first and last point;
--     logs every call.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/god_view_trail_0278.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if has_function_privilege('anon', 'public.god_view_trail(uuid, timestamptz, timestamptz)', 'execute')
     or not has_function_privilege('authenticated', 'public.god_view_trail(uuid, timestamptz, timestamptz)', 'execute') then
    raise exception 'FAILED: 0278 function grants';
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
create function pg_temp.refused(p_sql text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return true;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated;
grant execute on function pg_temp.refused(text) to authenticated;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000278a1', '60127800001'),  -- full admin
  ('00000000-0000-0000-0000-0000000278b1', '60127800011'),  -- someone else, no admin
  ('00000000-0000-0000-0000-0000000278f1', '60127800021')   -- the person moving
on conflict do nothing;
insert into public.profiles (id, name) select id, 'P278 ' || right(id::text, 2) from auth.users
 where id::text like '00000000-0000-0000-0000-0000000278%'
on conflict (id) do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000278a1', '*', 'edit')
on conflict do nothing;

-- 1. The background report is in the trail --------------------------------------------------
insert into public.push_tokens (profile_id, token, platform, last_lat, last_lng, located_at, located_bg,
                                location_always, bg_key_hash) values
  ('00000000-0000-0000-0000-0000000278f1', 'gv278-f1', 'android', 41.1, 141.1, now() - interval '10 minutes', true,
   true, encode(extensions.digest('k278k278k278k278k278k278k278k278k278k278', 'sha256'), 'hex'));
select pg_temp.check(public.push_background_location('k278k278k278k278k278k278k278k278k278k278', 41.2, 141.2) = 1,
                     'the background report was taken');
select pg_temp.check((select count(*) from public.user_location_history
                       where user_id = '00000000-0000-0000-0000-0000000278f1' and latitude = 41.2 and longitude = 141.2) = 1,
                     'the background report is in the history');

-- 2. The trail ---------------------------------------------------------------------------
insert into public.user_location_history (user_id, latitude, longitude, captured_at)
select '00000000-0000-0000-0000-0000000278f1', 41 + i / 10000.0, 141, now() - interval '6 hours' + i * interval '1 second'
  from generate_series(1, 9000) i;
insert into public.user_location_history (user_id, latitude, longitude, captured_at) values
  ('00000000-0000-0000-0000-0000000278f1', 40, 140, now() - interval '3 days');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000278a1');
do $$
declare
  t jsonb := public.god_view_trail('00000000-0000-0000-0000-0000000278f1', now() - interval '24 hours', now());
  n int := jsonb_array_length(t->'points');
begin
  perform pg_temp.check((t->>'total')::int = 9001, 'all points in the window counted: ' || (t->>'total'));
  perform pg_temp.check((t->>'thinned')::boolean, 'a long trail is thinned');
  perform pg_temp.check(n between 3000 and 4001, 'thinned to at most 4000: ' || n);
  perform pg_temp.check((t->'points'->0->>0)::numeric = 41.0001, 'the first point kept');
  perform pg_temp.check((t->'points'->(n - 1)->>0)::numeric = 41.2, 'the last point kept (the background report)');
  perform pg_temp.check((t->'points'->0->>2)::bigint < (t->'points'->(n - 1)->>2)::bigint, 'oldest first');
end $$;
select pg_temp.check(pg_temp.refused($q$select public.god_view_trail('00000000-0000-0000-0000-0000000278f1', now(), now() - interval '1 hour')$q$),
                     'a backwards window is refused');
select pg_temp.check(pg_temp.refused($q$select public.god_view_trail('00000000-0000-0000-0000-0000000278f1', now() - interval '3 days', now())$q$),
                     'more than 48 hours is refused');
select pg_temp.check(
  (public.god_view_trail('00000000-0000-0000-0000-0000000278f1', now() - interval '4 days', now() - interval '2 days')->>'total')::int = 1,
  'a past window');

select pg_temp.as_user('00000000-0000-0000-0000-0000000278b1');
select pg_temp.check(pg_temp.refused($q$select public.god_view_trail('00000000-0000-0000-0000-0000000278f1', now() - interval '1 hour', now())$q$),
                     'someone without God View is refused');
reset role;

select pg_temp.check((select count(*) from public.admin_audit_log
                       where action = 'god_view.trail' and target_profile_id = '00000000-0000-0000-0000-0000000278f1') = 2,
                     'every trail read is logged');

rollback;
