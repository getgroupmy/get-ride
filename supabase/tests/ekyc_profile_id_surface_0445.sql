-- ============================================================================
-- Regression test for migration 0445: a GET.eKYC photo is bound to its owner
-- whether a bare ID_Image path or the bucket's public URL; a pending rider ID
-- check seeds profiles.id_image (so it shows on User ID Documents' Pending tab)
-- without overwriting an existing image; dispatch and selfie rows leave it be.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ekyc_profile_id_surface_0445.sql
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
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000445a1', '60100004451'),  -- rider, pending eKYC, no prior image
  ('00000000-0000-0000-0000-0000000445a2', '60100004452'),  -- rider, already has an image
  ('00000000-0000-0000-0000-0000000445a3', '60100004453'),  -- dispatch / selfie only
  ('00000000-0000-0000-0000-0000000445a4', '60100004454')   -- rider, eKYC via a public URL
on conflict do nothing;
insert into public.profiles (id, name, nationality)
select id, 'Ali bin Abu', 'Malaysia' from auth.users where id::text like '00000000-0000-0000-0000-0000000445%'
on conflict (id) do update set id_image = null, id_verified = null;

-- 0. ekyc_photo_bound: a photo is bound to its owner, as a bare path or a URL --------------------------
select pg_temp.check(
  public.ekyc_photo_bound('00000000-0000-0000-0000-0000000445a1/signin/ekyc_front.jpg',
                          '00000000-0000-0000-0000-0000000445a1'), 'a bare ID_Image path of the owner is bound');
select pg_temp.check(
  public.ekyc_photo_bound('https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000445a1/signin/ekyc_front.jpg',
                          '00000000-0000-0000-0000-0000000445a1'), 'the bucket public URL of the owner is bound');
select pg_temp.check(
  not public.ekyc_photo_bound('00000000-0000-0000-0000-0000000445a2/signin/ekyc_front.jpg',
                              '00000000-0000-0000-0000-0000000445a1'), 'someone else''s bare path is not bound');
select pg_temp.check(
  not public.ekyc_photo_bound('https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000445a2/signin/x.jpg',
                              '00000000-0000-0000-0000-0000000445a1'), 'someone else''s URL is not bound');
select pg_temp.check(not public.ekyc_photo_bound(null, '00000000-0000-0000-0000-0000000445a1'), 'a null photo is not bound');

-- 1. A pending rider_gate ID check seeds profiles.id_image, left as pending ---------------------------
insert into public.identity_checks (user_id, kind, purpose, file_url, status)
  values ('00000000-0000-0000-0000-0000000445a1', 'id', 'rider_gate',
          'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000445a1/signin/ekyc_front.jpg',
          'Pending Review');
select pg_temp.check(
  (select id_image from public.profiles where id = '00000000-0000-0000-0000-0000000445a1')
    = 'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000445a1/signin/ekyc_front.jpg',
  'a pending rider_gate ID check seeds profiles.id_image');
select pg_temp.check(
  (select id_verified from public.profiles where id = '00000000-0000-0000-0000-0000000445a1') is null,
  'id_verified stays null, so it reads as pending on User ID Documents');

-- 2. An existing id_image is never overwritten -------------------------------------------------------
update public.profiles set id_image = 'kept/by/the/user.jpg' where id = '00000000-0000-0000-0000-0000000445a2';
insert into public.identity_checks (user_id, kind, purpose, file_url, status)
  values ('00000000-0000-0000-0000-0000000445a2', 'id', 'rider_gate', 'a2/signin/ekyc_front.jpg', 'Pending Review');
select pg_temp.check(
  (select id_image from public.profiles where id = '00000000-0000-0000-0000-0000000445a2') = 'kept/by/the/user.jpg',
  'an existing id_image is kept, not overwritten');

-- 3. A dispatch ('first') ID check and a rider selfie do not touch id_image ---------------------------
insert into public.identity_checks (user_id, kind, purpose, file_url, status)
  values ('00000000-0000-0000-0000-0000000445a3', 'id', 'first', 'a3/signin/ekyc_front.jpg', 'Pending Review');
insert into public.identity_checks (user_id, kind, purpose, file_url, status)
  values ('00000000-0000-0000-0000-0000000445a3', 'selfie', 'rider_gate', 'a3/signin/ekyc_selfie.jpg', 'Pending Review');
select pg_temp.check(
  (select id_image from public.profiles where id = '00000000-0000-0000-0000-0000000445a3') is null,
  'a dispatch ID check and a rider selfie leave id_image untouched');

-- 4. ekyc_apply accepts the public-URL photo form and seeds the profile -------------------------------
insert into public.ekyc_sessions (user_id, purpose, verification_id)
  values ('00000000-0000-0000-0000-0000000445a4', 'rider_gate', 'ver_0445aaaa0001');
select pg_temp.check((public.ekyc_apply((select id from public.ekyc_sessions where verification_id = 'ver_0445aaaa0001'),
  jsonb_build_object(
    'status', 'review', 'doc_type', 'mykad',
    'front', 'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000445a4/signin/ekyc_front.jpg',
    'selfie', 'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000445a4/signin/ekyc_selfie.jpg',
    'face', jsonb_build_object('score', 70, 'state', 'match')))->>'pending')::boolean,
  'ekyc_apply accepts a public-URL photo and leaves a review pending');
select pg_temp.check(
  (select id_image from public.profiles where id = '00000000-0000-0000-0000-0000000445a4') like '%/ID_Image/%/signin/ekyc_front.jpg',
  'the pending eKYC URL is on the profile for review');

rollback;
