-- ============================================================================
-- Regression test for migration 0439: GET eKYC results land as identity
-- checks; who may change the settings; a rider is auto-verified only when
-- GET eKYC approved and the face score is strong; dispatch IDs always wait
-- for an admin; a repeated webhook changes nothing; photos must be the
-- person's own.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/get_ekyc_0439.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000439a1', '60100004391'),  -- admin
  ('00000000-0000-0000-0000-0000000439b1', '60100004392'),  -- rider, strong match
  ('00000000-0000-0000-0000-0000000439b2', '60100004393'),  -- rider, GET eKYC says review
  ('00000000-0000-0000-0000-0000000439b3', '60100004394')   -- stand staff (dispatch)
on conflict do nothing;
insert into public.profiles (id, name, ic, nationality)
select id, 'Ali bin Abu',
       case right(id::text, 2) when 'b1' then '900514-10-5231' when 'b2' then '880101-14-1112' end,  -- IC numbers are unique
       'Malaysia'
  from auth.users where id::text like '00000000-0000-0000-0000-0000000439%'
on conflict (id) do update set name = excluded.name, ic = excluded.ic, nationality = excluded.nationality,
  id_verified = null, id_image = null;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000439a1', '*', 'edit')
on conflict do nothing;
delete from public.app_settings where key = 'ekyc';
insert into public.app_settings (key, value) values ('rider_id_gate', '{"master": {"autoVerifyScore": 85}}')
on conflict (key) do update set value = excluded.value;

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
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text)
  to authenticated, service_role;
create temp table ids (k text primary key, id uuid);
grant all on ids to authenticated, service_role;

-- 0. Only the server writes results; only admins change the settings ---------------------------------
select pg_temp.check(not has_function_privilege('authenticated', 'public.ekyc_apply(uuid, jsonb)', 'execute'),
  'a signed-in user cannot write a GET eKYC result');
select pg_temp.check(not has_table_privilege('authenticated', 'public.ekyc_sessions', 'insert'),
  'a signed-in user cannot make a session row');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000439b1');
select pg_temp.check((public.ekyc_config()->>'on')::boolean = false, 'off until an admin turns it on');
select pg_temp.check(not public.ekyc_config() ? 'serverKey', 'riders do not see the key flags');
select pg_temp.refused($$select public.set_ekyc_config('{"on": true}')$$, 'a rider changing the settings');

select pg_temp.as_user('00000000-0000-0000-0000-0000000439a1');
select pg_temp.check(public.ekyc_config() ? 'serverKey', 'admins see whether the keys are set');
select pg_temp.refused($$select public.set_ekyc_config('{"on": "yes"}')$$, 'a setting that is not true/false');
select pg_temp.check((public.set_ekyc_config('{"on": true, "riderGate": true}')->>'riderGate')::boolean,
  'admin turns on GET eKYC for the rider check');
select pg_temp.check(public.ekyc_in_use('rider_gate') and not public.ekyc_in_use('first'),
  'only the uses switched on');
reset role;

-- 1. Sessions (as the ekyc-start function makes them) ------------------------------------------------
set local role service_role;
with s as (
  insert into public.ekyc_sessions (user_id, purpose, verification_id) values
    ('00000000-0000-0000-0000-0000000439b1', 'rider_gate', 'ver_0439aaaa0001'),
    ('00000000-0000-0000-0000-0000000439b2', 'rider_gate', 'ver_0439aaaa0002'),
    ('00000000-0000-0000-0000-0000000439b3', 'first', 'ver_0439aaaa0003')
  returning id, verification_id)
insert into ids
select case verification_id when 'ver_0439aaaa0001' then 's_strong' when 'ver_0439aaaa0002' then 's_review' else 's_staff' end, id
  from s;

-- 2. A rider GET eKYC approved with a strong face match: verified, profile filled where empty ---------
select pg_temp.check((public.ekyc_apply((select id from ids where k = 's_strong'), jsonb_build_object(
  'status', 'approved', 'reasons', '[]'::jsonb, 'doc_type', 'mykad',
  'front', '00000000-0000-0000-0000-0000000439b1/signin/ekyc_front.jpg',
  'back', '00000000-0000-0000-0000-0000000439b1/signin/ekyc_back.jpg',
  'selfie', '00000000-0000-0000-0000-0000000439b1/signin/ekyc_selfie.jpg',
  'read', jsonb_build_object('name', 'ALI BIN ABU', 'ic', '900514-10-5231', 'birth', '1990-05-14',
                             'nationality', 'MYS', 'gender', 'male', 'address', '12 JALAN MAWAR'),
  'face', jsonb_build_object('score', 91.5, 'state', 'match'),
  'liveness', 'passed'))->>'verified')::boolean, 'strong approved rider is verified');
select pg_temp.check((select id_verified::text = 'Verified' and id_image like '%ekyc_front.jpg' and birth_date = '1990-05-14'
                        from public.profiles where id = '00000000-0000-0000-0000-0000000439b1'), 'profile verified and filled');
select pg_temp.check((select status = 'Approved' and read_source = 'ekyc' and face_provider = 'ekyc' and doc_type = 'mykad'
                             and ekyc_status = 'approved' and liveness = 'passed' and file_url_back like '%ekyc_back.jpg'
                        from public.identity_checks
                       where user_id = '00000000-0000-0000-0000-0000000439b1' and kind = 'id'), 'the ID check is approved');
select pg_temp.check(exists (select 1 from public.identity_checks
                              where user_id = '00000000-0000-0000-0000-0000000439b1' and kind = 'selfie'
                                and purpose = 'rider_gate' and ekyc_verification = 'ver_0439aaaa0001'), 'the selfie is kept too');

-- 3. The same webhook again changes nothing ------------------------------------------------------------
select pg_temp.check((public.ekyc_apply((select id from ids where k = 's_strong'), '{"status": "rejected"}')->>'repeat')::boolean,
  'a repeated result is ignored');
select pg_temp.check((select count(*) = 2 from public.identity_checks where ekyc_verification = 'ver_0439aaaa0001'),
  'no extra rows from a repeat');

-- 4. GET eKYC said review: waits for an admin, even with a high face score -----------------------------
select pg_temp.check((public.ekyc_apply((select id from ids where k = 's_review'), jsonb_build_object(
  'status', 'review', 'reasons', '["name_mismatch"]'::jsonb, 'doc_type', 'mykad',
  'front', '00000000-0000-0000-0000-0000000439b2/signin/ekyc_front.jpg',
  'selfie', '00000000-0000-0000-0000-0000000439b2/signin/ekyc_selfie.jpg',
  'read', jsonb_build_object('name', 'SOMEONE ELSE'),
  'face', jsonb_build_object('score', 97, 'state', 'match'), 'liveness', 'passed'))->>'pending')::boolean,
  'a review waits for an admin');
select pg_temp.check((select status = 'Pending Review' and ekyc_reasons = '{name_mismatch}' and 'name' = any(mismatch)
                        from public.identity_checks
                       where user_id = '00000000-0000-0000-0000-0000000439b2' and kind = 'id'),
  'pending, with GET eKYC''s reason and the name mismatch shown');
select pg_temp.check((select id_verified is null from public.profiles where id = '00000000-0000-0000-0000-0000000439b2'),
  'not verified');

-- 5. Dispatch ID: always an admin's decision; no selfie row (the phone's selfie step stays) -----------
select pg_temp.check((public.ekyc_apply((select id from ids where k = 's_staff'), jsonb_build_object(
  'status', 'approved', 'doc_type', 'passport',
  'front', '00000000-0000-0000-0000-0000000439b3/signin/ekyc_front.jpg',
  'read', jsonb_build_object('name', 'ALI BIN ABU', 'passport', 'A12345678', 'expiry', '2031-01-31'),
  'face', jsonb_build_object('score', 95, 'state', 'match')))->>'pending')::boolean, 'dispatch ID waits for an admin');
select pg_temp.check((select purpose = 'first' and status = 'Pending Review' and expiry_date = '2031-01-31'
                        from public.identity_checks where user_id = '00000000-0000-0000-0000-0000000439b3' and kind = 'id'),
  'a first ID check, pending');
select pg_temp.check(not exists (select 1 from public.identity_checks
                                  where user_id = '00000000-0000-0000-0000-0000000439b3' and kind = 'selfie'),
  'no selfie row for dispatch');

-- 6. Photos must be in the person's own folder ---------------------------------------------------------
with s as (insert into public.ekyc_sessions (user_id, purpose, verification_id)
  values ('00000000-0000-0000-0000-0000000439b2', 'rider_gate', 'ver_0439aaaa0004') returning id)
insert into ids select 's_other', id from s;
select pg_temp.refused($$select public.ekyc_apply((select id from ids where k = 's_other'), '{"status": "approved",
  "front": "00000000-0000-0000-0000-0000000439b1/signin/ekyc_front.jpg"}')$$, 'someone else''s photo');
select pg_temp.refused($$select public.ekyc_apply((select id from ids where k = 's_other'), '{"status": "maybe",
  "front": "00000000-0000-0000-0000-0000000439b2/signin/x.jpg"}')$$, 'an unknown status');
reset role;

-- 7. Users see only their own sessions --------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000439b2');
select pg_temp.check((select count(*) = 2 from public.ekyc_sessions), 'a rider sees only their own sessions');
reset role;

do $$ begin raise notice 'get_ekyc_0439: all checks passed'; end $$;
rollback;
