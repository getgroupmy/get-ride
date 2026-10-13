-- ============================================================================
-- Regression test for migration 0168: a phone records where it is, only for
-- the caller's own tokens, and nonsense positions are refused.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/push_location.sql
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000168a1'),
  ('00000000-0000-0000-0000-0000000168a2')
on conflict do nothing;
insert into public.profiles (id) values
  ('00000000-0000-0000-0000-0000000168a1'),
  ('00000000-0000-0000-0000-0000000168a2')
on conflict do nothing;
insert into public.push_tokens (token, profile_id, platform) values
  ('loc-a', '00000000-0000-0000-0000-0000000168a1', 'android'),
  ('loc-b', '00000000-0000-0000-0000-0000000168a2', 'android');

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000168a1","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.check(
  public.push_set_location(array['loc-a', 'loc-b'], 3.139, 101.687, 'Malaysia', ' Kuala Lumpur ', 'Kuala Lumpur', '') = 1,
  'only the caller''s own token');
reset role;

select pg_temp.check(
  (select last_lat = 3.139 and area_state = 'Kuala Lumpur' and area_suburb is null and located_at is not null
     from public.push_tokens where token = 'loc-a'),
  'location not stored as given (trimmed, blanks as null)');
select pg_temp.check((select located_at from public.push_tokens where token = 'loc-b') is null,
  'another account''s token changed');

do $$
begin
  perform public.push_set_location(array['loc-a'], 95, 10);
  raise exception 'FAILED: a latitude past the pole was accepted';
exception when others then
  if sqlerrm like 'FAILED%' then raise; end if;
end $$;

select pg_temp.check(
  not has_function_privilege('anon',
    'public.push_set_location(text[], double precision, double precision, text, text, text, text)', 'execute'),
  'anon can set a location');
select pg_temp.check(
  exists (select 1 from information_schema.columns where table_name = 'push_notifications' and column_name = 'target'),
  'push_notifications.target missing');

rollback;

select 'push_location: all passed';
