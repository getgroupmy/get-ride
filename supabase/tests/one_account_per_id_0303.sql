-- ============================================================================
-- Regression test for migration 0303: one account per ID number (M8).
--   * the same number, with or without dashes, is refused on a second live
--     account (ID_NUMBER_TAKEN, with the plain message in the hint);
--   * a deleted account's number can be registered again;
--   * keys under 6 characters are not compared;
--   * changing a number to one that is taken is refused, also for an admin;
--   * bringing a deleted account back with a taken number is refused;
--   * the unique index is there.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/one_account_per_id_0303.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000303a1'),  -- admin
  ('00000000-0000-0000-0000-0000000303b1'),  -- has 930303-14-0303
  ('00000000-0000-0000-0000-0000000303b2'),  -- registers next
  ('00000000-0000-0000-0000-0000000303b3'),  -- another person
  ('00000000-0000-0000-0000-0000000303c1')   -- deleted, had 930303-10-3030
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000303%'
on conflict do nothing;
update public.profiles set ic = '930303-14-0303' where id = '00000000-0000-0000-0000-0000000303b1';
update public.profiles set ic = '930303-10-3030', deleted_at = now(), profile_status = 'Deleted'
 where id = '00000000-0000-0000-0000-0000000303c1';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000303a1', '*', 'edit')
on conflict do nothing;

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
-- The error code, error and hint a statement raises, or 'ok'.
create or replace function pg_temp.error_of(p_sql text) returns text language plpgsql as $$
declare h text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics h = pg_exception_hint;
  return sqlstate || ' ' || sqlerrm || ': ' || coalesce(h, '');
end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.error_of(text)
  to authenticated;

-- 0. The guarantee --------------------------------------------------------------------------------------
select pg_temp.check((select indexdef like '%UNIQUE%reg_id_key(ic)%deleted_at IS NULL%'
                        from pg_indexes where schemaname = 'public' and indexname = 'profiles_ic_key_uidx'),
  'the partial unique index on reg_id_key(ic) is there');

set local role authenticated;

-- 1. Same number, another account -------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000303b2');
select pg_temp.check(pg_temp.error_of($q$update public.profiles set ic = '930303140303'
                                         where id = '00000000-0000-0000-0000-0000000303b2'$q$)
  = '23505 ID_NUMBER_TAKEN: Another GET.ride account uses this ID number. Sign in to that account, or contact support if it isn''t yours.',
  'the same number without dashes is refused, with the plain message');
select pg_temp.check(pg_temp.error_of($q$update public.profiles set ic = '930303 14 0303'
                                         where id = '00000000-0000-0000-0000-0000000303b2'$q$)
  like '23505 ID_NUMBER_TAKEN:%', 'and with spaces');
select pg_temp.check((select ic is null from public.profiles where id = '00000000-0000-0000-0000-0000000303b2'),
  'nothing was saved');

-- 2. A deleted account's number is free ------------------------------------------------------------------
update public.profiles set ic = '930303103030' where id = '00000000-0000-0000-0000-0000000303b2';
select pg_temp.check((select ic = '930303103030' from public.profiles where id = '00000000-0000-0000-0000-0000000303b2'),
  'a deleted account''s number can be registered again');

-- 3. Short keys are not compared -----------------------------------------------------------------------
update public.profiles set ic = 'A-12' where id = '00000000-0000-0000-0000-0000000303b3';
select pg_temp.as_user('00000000-0000-0000-0000-0000000303b1');
select pg_temp.check(pg_temp.error_of($q$update public.profiles set ic = 'a12'
                                         where id = '00000000-0000-0000-0000-0000000303b1'$q$) = 'ok',
  'a key under 6 characters can be on two accounts');
-- Back to the number for the next checks.
update public.profiles set ic = '930303-14-0303' where id = '00000000-0000-0000-0000-0000000303b1';

-- 4. Changing to a taken number ------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000303b3');
select pg_temp.check(pg_temp.error_of($q$update public.profiles set ic = '930303-14-0303'
                                         where id = '00000000-0000-0000-0000-0000000303b3'$q$)
  like '23505 ID_NUMBER_TAKEN:%', 'an update to a taken number is refused');
select pg_temp.as_user('00000000-0000-0000-0000-0000000303b1');
select pg_temp.check(pg_temp.error_of($q$update public.profiles set ic = '930303-14-0303'
                                         where id = '00000000-0000-0000-0000-0000000303b1'$q$) = 'ok',
  'saving one''s own number again is fine');

-- 5. The admin's edit goes through the same rule -------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000303a1');
select pg_temp.check(pg_temp.error_of($q$update public.profiles set ic = '930303-14-0303'
                                         where id = '00000000-0000-0000-0000-0000000303b3'$q$)
  like '23505 ID_NUMBER_TAKEN:%', 'an admin can''t give a taken number to another account');

reset role;

-- 6. Bringing a deleted account back with a taken number ------------------------------------------------
select pg_temp.check(pg_temp.error_of($q$update public.profiles set deleted_at = null, profile_status = 'Un-Approved'
                                         where id = '00000000-0000-0000-0000-0000000303c1'$q$)
  like '23505 ID_NUMBER_TAKEN:%', 'a deleted account can''t come back with a number now in use');
select pg_temp.check(pg_temp.error_of($q$insert into public.profiles (id, ic)
                                         values ('00000000-0000-0000-0000-0000000303a1', '930303-14-0303')
                                         on conflict (id) do update set ic = excluded.ic$q$)
  like '23505 ID_NUMBER_TAKEN:%', 'an upsert is refused too');

rollback;

select 'one_account_per_id_0303: all passed';
