-- ============================================================================
-- Regression test for migration 0235: geo_take2 takes the user's and the
-- address's rate limits in one call, counting as two geo_take calls would
-- (the address only when the user is under their limit), says which one
-- refused, and only the service role may call it.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/geo_take_pair.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
end $$;

create or replace function pg_temp.hits(p_bucket text) returns integer language sql as $$
  select coalesce((select hits from public.geo_rate where bucket = p_bucket), 0);
$$;

-- 1. Who may call it -----------------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('anon', 'public.geo_take2(text, integer, text, integer)', 'execute'),
  'anon may not take');
select pg_temp.check(not has_function_privilege('authenticated', 'public.geo_take2(text, integer, text, integer)',
                       'execute'), 'a signed-in user may not take');
select pg_temp.check(has_function_privilege('service_role', 'public.geo_take2(text, integer, text, integer)', 'execute'),
  'the geo function (service role) may');
select pg_temp.check((select p.prosecdef and p.proconfig @> array['search_path=public']
                        from pg_proc p where p.oid = 'public.geo_take2(text, integer, text, integer)'::regprocedure),
  'security definer with its search_path set, as geo_take');

-- 2. Both under their limits ---------------------------------------------------------------------
delete from public.geo_rate where bucket in ('user:t235', 'ip:t235', 'user:t235b');
select pg_temp.check(public.geo_take2('user:t235', 2, 'ip:t235', 3) is null, 'first call allowed');
select pg_temp.check(pg_temp.hits('user:t235') = 1 and pg_temp.hits('ip:t235') = 1, 'both buckets counted once');
select pg_temp.check(public.geo_take2('user:t235', 2, 'ip:t235', 3) is null, 'second call allowed');

-- 3. The user over their limit: the address is not counted ---------------------------------------
select pg_temp.check(public.geo_take2('user:t235', 2, 'ip:t235', 3) = 'user', 'the third call is over the user''s 2');
select pg_temp.check(pg_temp.hits('user:t235') = 3 and pg_temp.hits('ip:t235') = 2,
  'the refused call counts for the user, as geo_take does, and not for the address');

-- 4. The address over its limit -------------------------------------------------------------------
select pg_temp.check(public.geo_take2('user:t235b', 10, 'ip:t235', 3) is null, 'another user, the address''s third');
select pg_temp.check(public.geo_take2('user:t235b', 10, 'ip:t235', 3) = 'ip', 'the address''s fourth is refused');
select pg_temp.check(pg_temp.hits('user:t235b') = 2 and pg_temp.hits('ip:t235') = 4,
  'the user was counted before the address refused, as with two geo_take calls');

-- 5. A new minute starts again --------------------------------------------------------------------
update public.geo_rate set window_start = now() - interval '2 minutes' where bucket in ('user:t235', 'ip:t235');
select pg_temp.check(public.geo_take2('user:t235', 2, 'ip:t235', 3) is null, 'allowed in a new minute');
select pg_temp.check(pg_temp.hits('user:t235') = 1 and pg_temp.hits('ip:t235') = 1, 'both windows restarted');

select 'geo_take_pair: all passed';
rollback;
