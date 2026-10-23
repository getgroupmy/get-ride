-- ============================================================================
-- Regression test for migration 0277: the profile is the master copy of the
-- partner record's name, phone, email, IC, address and photo; a change on
-- either side shows on the other; an approved partner's name, IC and photo
-- stay support's to change on the profile too; a partner row can't change
-- the sign-in number.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/partner_profile_sync_0277.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000277a1'),  -- applicant
  ('00000000-0000-0000-0000-0000000277a2'),  -- approved driver
  ('00000000-0000-0000-0000-0000000277a3')   -- claims an admin-added row
on conflict do nothing;
insert into public.profiles (id, name, phone, email, ic, address, avatar_url) values
  ('00000000-0000-0000-0000-0000000277a1', 'Aina', '+60110000277', 'aina@example.test', 'A277', 'Jalan 1',
   'https://cdn.example/aina.jpg'),
  ('00000000-0000-0000-0000-0000000277a2', 'Badrul', '+60110000278', null, 'B278', null,
   'https://cdn.example/badrul.jpg'),
  ('00000000-0000-0000-0000-0000000277a3', 'Chong', '+60110000279', null, null, null, null)
on conflict (id) do update set name = excluded.name, phone = excluded.phone, email = excluded.email,
  ic = excluded.ic, address = excluded.address, avatar_url = excluded.avatar_url;

-- 1. A new partner row fills its blanks from the profile --------------------------
insert into public.partners (id, auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000277b1', '00000000-0000-0000-0000-0000000277a1', '', '+60110000277',
   'unapproved'),
  ('00000000-0000-0000-0000-0000000277b2', '00000000-0000-0000-0000-0000000277a2', 'Badrul', '+60110000278',
   'approved');
insert into public.partners (id, auth_user_id, name, phone, email, ic, status) values
  ('00000000-0000-0000-0000-0000000277b3', null, 'Chong (admin typed)', '+60110000279', 'chong@example.test',
   'C279', 'unapproved');

do $$
declare r record;
begin
  select * into r from public.partners where id = '00000000-0000-0000-0000-0000000277b1';
  if r.name <> 'Aina' or r.email is distinct from 'aina@example.test' or r.ic is distinct from 'A277'
     or r.address is distinct from 'Jalan 1' or r.avatar_url is distinct from 'https://cdn.example/aina.jpg' then
    raise exception 'FAILED: the new partner row did not fill its blanks from the profile (%)', row_to_json(r);
  end if;
end $$;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
declare n integer;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    return;
  end;
  if n > 0 then
    raise exception 'FAILED: % was allowed', p_what;
  end if;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

set local role authenticated;

-- 2. The applicant edits their profile: the partner row follows, and back -----------
select pg_temp.as_user('00000000-0000-0000-0000-0000000277a1');
update public.profiles set name = 'Aina Binti Ali', avatar_url = 'https://cdn.example/aina2.jpg', address = null
 where id = '00000000-0000-0000-0000-0000000277a1';
update public.partners set email = 'aina.work@example.test' where id = '00000000-0000-0000-0000-0000000277b1';

-- 3. The approved driver: name, IC and photo are support's, on the profile too -------
select pg_temp.as_user('00000000-0000-0000-0000-0000000277a2');
select pg_temp.refused(
  $q$update public.profiles set name = 'Someone Else' where id = '00000000-0000-0000-0000-0000000277a2'$q$,
  'an approved driver changing their name on the profile');
select pg_temp.refused(
  $q$update public.profiles set ic = 'X999' where id = '00000000-0000-0000-0000-0000000277a2'$q$,
  'an approved driver changing their IC on the profile');
select pg_temp.refused(
  $q$update public.profiles set avatar_url = 'https://evil.example/stock.jpg' where id = '00000000-0000-0000-0000-0000000277a2'$q$,
  'an approved driver swapping their photo on the profile');
-- Unchanged values and the free fields still save.
update public.profiles set name = 'Badrul', ic = 'B278', address = 'Jalan 2', email = 'badrul@example.test'
 where id = '00000000-0000-0000-0000-0000000277a2';

-- 4. No one changes a sign-in number through the partner row -------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000277a1');
select pg_temp.refused(
  $q$update public.partners set phone = '+60119999999' where id = '00000000-0000-0000-0000-0000000277b1'$q$,
  'a partner changing the phone on their partner row');

reset role;

do $$
declare pa record; pr record;
begin
  select * into pa from public.partners where id = '00000000-0000-0000-0000-0000000277b1';
  select * into pr from public.profiles where id = '00000000-0000-0000-0000-0000000277a1';
  if pa.name <> 'Aina Binti Ali' or pa.avatar_url is distinct from 'https://cdn.example/aina2.jpg'
     or pa.address is not null then
    raise exception 'FAILED: the profile change did not reach the partner row (%)', row_to_json(pa);
  end if;
  if pr.email is distinct from 'aina.work@example.test' then
    raise exception 'FAILED: the partner change did not reach the profile (%)', pr.email;
  end if;
  if pa.phone <> '+60110000277' or pr.phone <> '+60110000277' then
    raise exception 'FAILED: the phone moved (% / %)', pa.phone, pr.phone;
  end if;

  select * into pa from public.partners where id = '00000000-0000-0000-0000-0000000277b2';
  if pa.name <> 'Badrul' or pa.ic is distinct from 'B278' or pa.avatar_url is distinct from 'https://cdn.example/badrul.jpg'
     or pa.address is distinct from 'Jalan 2' or pa.email is distinct from 'badrul@example.test' then
    raise exception 'FAILED: the approved driver''s partner row (%)', row_to_json(pa);
  end if;
end $$;

-- 5. An admin (here the server) changes the approved driver's name on the partner row:
--    the profile follows.
update public.partners set name = 'Badrul Hisham' where id = '00000000-0000-0000-0000-0000000277b2';
do $$
begin
  if (select name from public.profiles where id = '00000000-0000-0000-0000-0000000277a2') <> 'Badrul Hisham' then
    raise exception 'FAILED: the admin''s partner-row change did not reach the profile';
  end if;
end $$;

-- 6. Claiming an admin-added row: the profile wins where it has a value, and fills
--    nothing it already has; its blanks take the row's.
update public.partners set auth_user_id = '00000000-0000-0000-0000-0000000277a3'
 where id = '00000000-0000-0000-0000-0000000277b3';
do $$
declare pa record; pr record;
begin
  select * into pa from public.partners where id = '00000000-0000-0000-0000-0000000277b3';
  select * into pr from public.profiles where id = '00000000-0000-0000-0000-0000000277a3';
  if pa.name <> 'Chong' or pr.name <> 'Chong' then
    raise exception 'FAILED: the profile name did not win the claim (% / %)', pa.name, pr.name;
  end if;
  if pr.email is distinct from 'chong@example.test' or pr.ic is distinct from 'C279' then
    raise exception 'FAILED: the profile''s blanks were not filled from the row (%)', row_to_json(pr);
  end if;
end $$;

rollback;
