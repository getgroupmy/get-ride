-- ============================================================================
-- Regression test for migration 0446 (reject → restart): a rejected ID returns
-- to pending when its image changes (rider re-upload or GET.eKYC re-capture); a
-- verified ID is left alone; a statement that itself sets id_verified (admin
-- verify / strong auto-verify) is never undone.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ekyc_reject_restart_0446.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000446a1', '60100004461'),  -- rejected, plain re-upload
  ('00000000-0000-0000-0000-0000000446a2', '60100004462'),  -- verified, image changes
  ('00000000-0000-0000-0000-0000000446a3', '60100004463'),  -- rejected, admin verifies with a new image
  ('00000000-0000-0000-0000-0000000446a4', '60100004464')   -- rejected, GET.eKYC re-capture
on conflict do nothing;
insert into public.profiles (id, name, nationality, id_image, id_verified)
select id, 'Ali bin Abu', 'Malaysia', 'old/' || right(id::text, 2) || '.jpg',
       case right(id::text, 2) when 'a2' then 'Verified' else 'Failed' end::public.id_verification_status
  from auth.users where id::text like '00000000-0000-0000-0000-0000000446%'
on conflict (id) do update set id_image = excluded.id_image, id_verified = excluded.id_verified;

-- 1. A rejected profile whose id_image changes (the rider re-uploads) reopens --
update public.profiles set id_image = 'new/a1.jpg' where id = '00000000-0000-0000-0000-0000000446a1';
select pg_temp.check(
  (select id_verified is null and id_image = 'new/a1.jpg' from public.profiles where id = '00000000-0000-0000-0000-0000000446a1'),
  'a rejected ID returns to pending (id_verified null) when re-uploaded');

-- 2. A verified profile is left alone when its image changes ------------------
update public.profiles set id_image = 'new/a2.jpg' where id = '00000000-0000-0000-0000-0000000446a2';
select pg_temp.check(
  (select id_verified::text = 'Verified' from public.profiles where id = '00000000-0000-0000-0000-0000000446a2'),
  'a verified ID stays verified when its image changes');

-- 3. A statement that itself sets id_verified is never undone -----------------
update public.profiles set id_image = 'new/a3.jpg', id_verified = 'Verified'
  where id = '00000000-0000-0000-0000-0000000446a3';
select pg_temp.check(
  (select id_verified::text = 'Verified' from public.profiles where id = '00000000-0000-0000-0000-0000000446a3'),
  'an admin verify (id_image + id_verified together) is not reopened');

-- 4. A GET.eKYC / face-match re-capture replaces the image and reopens --------
insert into public.identity_checks (user_id, kind, purpose, file_url, status)
  values ('00000000-0000-0000-0000-0000000446a4', 'id', 'rider_gate',
          'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000446a4/signin/ekyc_front.jpg',
          'Pending Review');
select pg_temp.check(
  (select id_verified is null and id_image like '%/ID_Image/%/signin/ekyc_front.jpg'
     from public.profiles where id = '00000000-0000-0000-0000-0000000446a4'),
  'a new rider-gate ID check on a rejected profile replaces the image and reopens the review');

rollback;
