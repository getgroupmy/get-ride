-- ============================================================================
-- Regression test for migration 0438: an empty photos line is decided without
-- a view, while a line that really has a photo still needs one.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/partner_review_empty_photos_0438.sql
--
-- 0296 held every "document" line (its photo or file) back from Approve or
-- Reject until the admin had opened it. A line whose value is an array of URLs
-- with none uploaded — vehicle photos — is jsonb [null,null,null,null]: a
-- non-null array, so the old gate fired, yet there was nothing to open,
-- locking the admin out of both. 0438's partner_review_has_file() makes an
-- all-null or empty array nothing to view, so the line decides; a populated
-- photos array still needs a view.
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up people and vehicles only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000438a1'),  -- admin, EDIT on Partners
  ('00000000-0000-0000-0000-0000000438b1')   -- the driver
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000438%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000438a1', 'admin-partners', 'edit')
on conflict do nothing;

-- A registration vehicle with no photos: image_front/left/right/back all null.
insert into public.vehicle (id, auth_user_id, plate, year, color, status, documents_ok) values
  ('00000000-0000-0000-0000-0000000438f1', '00000000-0000-0000-0000-0000000438b1', 'TST 438', '2019', 'BLACK',
   'unapproved', true);
insert into public.partners (id, auth_user_id, name, phone, status, documents_ok, partner_types, registration_vehicle_id) values
  ('00000000-0000-0000-0000-000000043801', '00000000-0000-0000-0000-0000000438b1', 'Photos Test Driver', '+60110000438',
   'unapproved', true, array['TEKSI'], '00000000-0000-0000-0000-0000000438f1');

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
create or replace function pg_temp.raises(p_sql text, p_code text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm not like '%' || p_code || '%' then
      raise exception 'FAILED: % raised "%" instead of %', p_what, sqlerrm, p_code;
    end if;
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text),
  pg_temp.raises(text, text, text) to authenticated;

-- 0. partner_review_has_file: an array needs a real entry; a scalar or object keeps its meaning.
select pg_temp.check(public.partner_review_has_file(jsonb_build_array(null, null, null, null)) = false,
  'an all-null photos array is nothing to view');
select pg_temp.check(public.partner_review_has_file('[]'::jsonb) = false,
  'an empty array is nothing to view');
select pg_temp.check(public.partner_review_has_file(jsonb_build_array('https://x.test/car-front.jpg', null, null, null)) = true,
  'a photos array with one photo has a file');
select pg_temp.check(public.partner_review_has_file(to_jsonb('https://x.test/a.jpg'::text)) = true,
  'a scalar url has a file');
select pg_temp.check(public.partner_review_has_file('null'::jsonb) = false,
  'a JSON null is nothing to view');
select pg_temp.check(public.partner_review_has_file(null) = false,
  'a SQL null is nothing to view');
select pg_temp.check(public.partner_review_has_file(jsonb_build_object('file_url', 'https://x.test/a.jpg')) = true,
  'a document object has a file');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000438a1');

-- 1. The empty vehicle-photos line is rejected without opening it first.
select public.partner_review_set('00000000-0000-0000-0000-000000043801', 'vehicle.photos', 'vehicle', 'Vehicle photos',
  'rejected', 'No photos uploaded.');
select pg_temp.check((select state = 'rejected' from public.partner_review_items
  where partner_id = '00000000-0000-0000-0000-000000043801' and item_key = 'vehicle.photos'),
  'the empty photos line rejects with no view');

-- 2. Once a photo is uploaded, the line needs a view again, and decides after it.
update public.vehicle set image_front = 'https://x.test/car-front.jpg'
 where id = '00000000-0000-0000-0000-0000000438f1';
select pg_temp.raises($q$select public.partner_review_set('00000000-0000-0000-0000-000000043801', 'vehicle.photos',
  'vehicle', 'Vehicle photos', 'approved')$q$, 'REVIEW_VIEW_FIRST', 'a populated photos line is decided unseen');
select public.partner_review_view('00000000-0000-0000-0000-000000043801', 'vehicle.photos');
select public.partner_review_set('00000000-0000-0000-0000-000000043801', 'vehicle.photos', 'vehicle', 'Vehicle photos', 'approved');
select pg_temp.check((select state = 'approved' from public.partner_review_items
  where partner_id = '00000000-0000-0000-0000-000000043801' and item_key = 'vehicle.photos'),
  'with the photo viewed, the line decides');

reset role;
select 'partner_review_empty_photos_0438: all passed';
rollback;
