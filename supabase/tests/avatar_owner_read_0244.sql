-- ============================================================================
-- Regression test for migration 0244: a user re-uploads their own profile
-- photo (Storage's upsert, INSERT ... ON CONFLICT DO UPDATE) without the old
-- broad "public read avatars" policy, and still cannot read anyone else's.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/avatar_owner_read_0244.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- As live: only the owner and admin reads remain.
drop policy if exists "public read avatars" on storage.objects;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000244a1'),
  ('00000000-0000-0000-0000-0000000244a2')
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000244%'
on conflict do nothing;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text) to authenticated;

set local role authenticated;

-- 1. The owner uploads, then upserts the same path --------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000244a1');
insert into storage.objects (bucket_id, name, owner)
values ('avatars', '00000000-0000-0000-0000-0000000244a1/avatar_1.jpg', '00000000-0000-0000-0000-0000000244a1')
on conflict (bucket_id, name) do update set updated_at = now();
insert into storage.objects (bucket_id, name, owner)
values ('avatars', '00000000-0000-0000-0000-0000000244a1/avatar_1.jpg', '00000000-0000-0000-0000-0000000244a1')
on conflict (bucket_id, name) do update set updated_at = now();
select pg_temp.check(
  (select count(*) = 1 from storage.objects
    where bucket_id = 'avatars' and name = '00000000-0000-0000-0000-0000000244a1/avatar_1.jpg'),
  'the owner reads (and so upserts) their own avatar');

-- 2. Another user can't list or read it ---------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000244a2');
select pg_temp.check(
  (select count(*) = 0 from storage.objects
    where bucket_id = 'avatars' and name like '00000000-0000-0000-0000-0000000244a1/%'),
  'another user cannot list someone else''s avatar folder');

-- 3. Nor upload into it ----------------------------------------------------------------------------
do $$
begin
  begin
    insert into storage.objects (bucket_id, name)
    values ('avatars', '00000000-0000-0000-0000-0000000244a1/avatar_2.jpg');
    raise exception 'FAILED: another user uploaded into someone else''s folder';
  exception when insufficient_privilege then
    null;
  end;
end $$;

rollback;
