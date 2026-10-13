-- ============================================================================
-- Regression test for migration 0166: a phone records its mode, only for the
-- caller's own tokens.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/push_mode.sql
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000166a1'),
  ('00000000-0000-0000-0000-0000000166a2')
on conflict do nothing;
insert into public.profiles (id) values
  ('00000000-0000-0000-0000-0000000166a1'),
  ('00000000-0000-0000-0000-0000000166a2')
on conflict do nothing;
insert into public.push_tokens (token, profile_id, platform) values
  ('mode-a', '00000000-0000-0000-0000-0000000166a1', 'android'),
  ('mode-b', '00000000-0000-0000-0000-0000000166a2', 'android');

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;

select pg_temp.check((select mode from public.push_tokens where token = 'mode-a') is null, 'a new token has no mode');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000166a1","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.check(public.push_set_mode(array['mode-a', 'mode-b'], 'partner') = 1, 'only the caller''s own token');
reset role;

select pg_temp.check((select mode from public.push_tokens where token = 'mode-a') = 'partner', 'mode not stored');
select pg_temp.check((select mode from public.push_tokens where token = 'mode-b') is null, 'another account''s token changed');

do $$
begin
  perform public.push_set_mode(array['mode-a'], 'driver');
  raise exception 'FAILED: an unknown mode was accepted';
exception when others then
  if sqlerrm like 'FAILED%' then raise; end if;
end $$;

select pg_temp.check(
  not has_function_privilege('anon', 'public.push_set_mode(text[], text)', 'execute')
  and has_function_privilege('authenticated', 'public.push_set_mode(text[], text)', 'execute'),
  'grants');

rollback;

select 'push_mode: all passed';
