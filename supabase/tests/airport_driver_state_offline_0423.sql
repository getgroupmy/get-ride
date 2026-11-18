-- ============================================================================
-- Regression test for migration 0423: airport_driver_state answers for a
-- driver who is not online with a fresh position (no presence row, switched
-- off, or a position older than 3 minutes) instead of failing with
-- "record z is not assigned yet".
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/airport_driver_state_offline_0423.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000423d1'),  -- never online
  ('00000000-0000-0000-0000-0000000423d2'),  -- switched off
  ('00000000-0000-0000-0000-0000000423d3')   -- online, but last seen 10 minutes ago
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000423%'
on conflict do nothing;
alter table public.driver_presence disable trigger user;
insert into public.driver_presence (profile_id, online, lat, lng, updated_at) values
  ('00000000-0000-0000-0000-0000000423d2', false, 3.139, 101.687, now()),
  ('00000000-0000-0000-0000-0000000423d3', true, 3.139, 101.687, now() - interval '10 minutes')
on conflict (profile_id) do update set online = excluded.online, lat = excluded.lat, lng = excluded.lng,
  updated_at = excluded.updated_at;
alter table public.driver_presence enable trigger user;

select pg_temp.as_user('00000000-0000-0000-0000-0000000423d1');
select pg_temp.check(public.airport_driver_state()->>'state' = 'outside', 'never online: outside');
select pg_temp.as_user('00000000-0000-0000-0000-0000000423d2');
select pg_temp.check(public.airport_driver_state()->>'state' = 'outside', 'switched off: outside');
select pg_temp.as_user('00000000-0000-0000-0000-0000000423d3');
select pg_temp.check(public.airport_driver_state()->>'state' = 'outside', 'a stale position: outside');

rollback;

select 'airport_driver_state_offline_0423: all passed';
