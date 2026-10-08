-- ============================================================================
-- Regression test for migration 0113: an admin can put a cooling-down fare
-- AI key back into rotation; nobody else can.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fare_ai_reset_cooldown.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000013a1'),  -- admin
  ('00000000-0000-0000-0000-0000000013a2')   -- rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000013%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000013a1', '*', 'edit')
on conflict do nothing;

insert into public.fare_ai_key_states (key_id, provider, fail_count, disabled_until, last_error) values
  ('test-key-1', 'gemini', 3, now() + interval '1 hour', 'HTTP 429'),
  ('test-key-2', 'gemini', 1, now() + interval '1 hour', 'HTTP 500'),
  ('test-key-3', 'gemini', 0, null, null);

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

set local role authenticated;

-- 1. A rider cannot.
select pg_temp.as_user('00000000-0000-0000-0000-0000000013a2');
do $$
begin
  begin
    perform public.fare_ai_reset_cooldown('test-key-1');
    raise exception 'FAILED: a rider reset a cooldown';
  exception when insufficient_privilege then null;
  end;
end $$;

-- 2. An admin resets one key, then the rest.
select pg_temp.as_user('00000000-0000-0000-0000-0000000013a1');
do $$
declare n int;
begin
  n := public.fare_ai_reset_cooldown('test-key-1');
  if n <> 1 then raise exception 'FAILED: one key reset %', n; end if;
  if exists (select 1 from public.fare_ai_key_states where key_id = 'test-key-1' and disabled_until is not null) then
    raise exception 'FAILED: key 1 still cooling down';
  end if;
  if not exists (select 1 from public.fare_ai_key_states where key_id = 'test-key-2' and disabled_until is not null) then
    raise exception 'FAILED: key 2 was reset too';
  end if;
  -- Counters and the last error are kept.
  if not exists (select 1 from public.fare_ai_key_states
                  where key_id = 'test-key-1' and fail_count = 3 and last_error = 'HTTP 429') then
    raise exception 'FAILED: key 1 lost its history';
  end if;

  n := public.fare_ai_reset_cooldown(null);
  if n < 1 then raise exception 'FAILED: reset all touched %', n; end if;
  if exists (select 1 from public.fare_ai_key_states
              where key_id like 'test-key-%' and disabled_until is not null) then
    raise exception 'FAILED: a key is still cooling down';
  end if;
end $$;

select 'fare_ai_reset_cooldown: all passed';
rollback;
