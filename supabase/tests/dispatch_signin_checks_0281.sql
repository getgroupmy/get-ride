-- ============================================================================
-- Regression test for migration 0281: what a dispatch ID does when they sign
-- in — a selfie, their ID, a new phone, the deadline — and that the server
-- keeps the role shut until they have.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/dispatch_signin_checks_0281.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000281a1', '60100002811'),  -- full admin
  ('00000000-0000-0000-0000-0000000281a2', '60100002812'),  -- sub-admin: edit on Documents
  ('00000000-0000-0000-0000-0000000281a3', '60100002813'),  -- stand admin: selfie + ID, 7 days
  ('00000000-0000-0000-0000-0000000281a4', '60100002814'),  -- fleet owner: nothing asked
  ('00000000-0000-0000-0000-0000000281b1', '60100002815')   -- a rider
on conflict do nothing;
insert into public.profiles (id, name, ic, pin_hash)
select id, case right(id::text, 2) when 'a3' then 'Aina binti Ahmad' else 'P' || right(id::text, 2) end,
       case right(id::text, 2) when 'a3' then '880202-10-1234' end, 'hash'
  from auth.users where id::text like '00000000-0000-0000-0000-0000000281%'
on conflict (id) do update set name = excluded.name, ic = excluded.ic, pin_hash = excluded.pin_hash;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000281a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000281a2', 'admin-documents', 'edit')
on conflict do nothing;
insert into public.dispatch_stands (id, name, kind, code, lat, lng, allow_fixed_fare, settlement,
                                    fee_type, fee_value, fee_bearer, platform_fee_type, platform_fee_value) values
  ('00000000-0000-0000-0000-0000000281e1', 'Mid Valley', 'mall', 'MVM', 3.118, 101.677, true, 'wallet',
   'fixed', 2, 'customer', 'percent', 20);
insert into public.dispatch_groups (id, name, kind, members_first_sec) values
  ('00000000-0000-0000-0000-0000000281f1', 'Moonlight Taxi', 'fleet', 0);

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
create or replace function pg_temp.needs(p_device text default null) returns text language sql as $$
  select coalesce((select string_agg(x, ',' order by x) from jsonb_array_elements_text(
    public.dispatch_my_checks(p_device)->'needs') x), '');
$$;
-- A file in the signed-in person's own folder.
create or replace function pg_temp.file(p_bucket text, p_name text) returns text language sql as $$
  select 'https://x.supabase.co/storage/v1/object/public/' || p_bucket || '/' || auth.uid() || '/signin/' || p_name;
$$;
create temp table ids (k text primary key, id uuid);
grant all on ids to authenticated;
create or replace function pg_temp.id(p_k text) returns uuid language sql as $$ select id from ids where k = p_k $$;
create or replace function pg_temp.sent(p_k text, p jsonb) returns void language sql as $$
  insert into ids values (p_k, (public.identity_check_submit(p)->>'id')::uuid);
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text),
  pg_temp.needs(text), pg_temp.file(text, text), pg_temp.id(text), pg_temp.sent(text, jsonb) to authenticated;

select public.dispatch_grant('00000000-0000-0000-0000-0000000281a1', '00000000-0000-0000-0000-0000000281a3',
  'stand_admin', 'Aina', '60100002813', array['00000000-0000-0000-0000-0000000281e1'::uuid], null,
  '{"verify_selfie": true, "verify_id": true, "verify_days": 7}');
select public.dispatch_grant('00000000-0000-0000-0000-0000000281a1', '00000000-0000-0000-0000-0000000281a4',
  'fleet_owner', 'Moonlight', '60100002814', '{}', '00000000-0000-0000-0000-0000000281f1', '{}');
select pg_temp.check((select verify_selfie and verify_id and verify_days = 7
                             and verify_by between now() + interval '6 days' and now() + interval '8 days'
                        from public.dispatch_stand_people where user_id = '00000000-0000-0000-0000-0000000281a3'),
                     'the grant keeps its switches and deadline');

-- 0. Clients can't reach the inner workings -------------------------------------------------------
select pg_temp.check(not has_function_privilege('authenticated', 'public.dispatch_role_needs(uuid, boolean, boolean)', 'execute')
                     and not has_function_privilege('authenticated', 'public.dispatch_note_device(uuid, text)', 'execute')
                     and not has_function_privilege('authenticated', 'public.identity_notify_admins(uuid)', 'execute')
                     and not has_function_privilege('anon', 'public.dispatch_my_checks(text)', 'execute')
                     and not has_function_privilege('anon', 'public.identity_check_submit(jsonb)', 'execute'),
                     'the helpers are the server''s');

set local role authenticated;

-- 1. A new stand admin: the role is shut until they have sent both --------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000281a3');
select pg_temp.check(pg_temp.needs('phone-aaaaaaaa-1') = 'id,selfie', 'a selfie and an ID are asked');
select pg_temp.check((public.dispatch_my_checks('phone-aaaaaaaa-1')->>'holds')::boolean, 'they hold a role');
select pg_temp.check(jsonb_array_length(public.dispatch_my_stands()) = 0, 'no stand opens yet');
select pg_temp.check(cardinality(public.dispatch_caller_stand_ids()) = 0, 'no stand for RLS either');
select pg_temp.check(not public.dispatch_caller_can('00000000-0000-0000-0000-0000000281e1', 'use'), 'the console is shut');
select pg_temp.refused($q$insert into public.identity_checks (user_id, kind, file_url, status)
  values (auth.uid(), 'selfie', 'x', 'Approved')$q$, 'writing a check straight into the table');
select pg_temp.refused($q$select public.identity_check_submit(jsonb_build_object('kind', 'selfie',
  'file_url', 'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-0000000281a4/s.jpg'))$q$,
  'sending someone else''s photo');

select pg_temp.sent('selfie1', jsonb_build_object('kind', 'selfie', 'file_url', pg_temp.file('ID_Image', 'selfie.jpg'),
  'liveness', 'passed', 'liveness_detail', 'blink', 'device', 'phone-aaaaaaaa-1'));
select pg_temp.check(pg_temp.needs('phone-aaaaaaaa-1') = 'id', 'a selfie received is enough for the photo');

select pg_temp.refused($q$select public.identity_check_submit(jsonb_build_object('kind', 'id', 'doc_type', 'mykad',
  'file_url', pg_temp.file('ID_Image', 'front.jpg')))$q$, 'an ID without its back');
select pg_temp.refused($q$select public.identity_check_submit(jsonb_build_object('kind', 'id', 'doc_type', 'passport',
  'file_url', pg_temp.file('ID_Image', 'front.jpg'), 'file_url_back', pg_temp.file('ID_Image', 'back.jpg')))$q$,
  'a passport without its expiry');
select pg_temp.sent('id1', jsonb_build_object('kind', 'id', 'doc_type', 'mykad',
  'file_url', pg_temp.file('ID_Image', 'front.jpg'), 'file_url_back', pg_temp.file('ID_Image', 'back.jpg'),
  'read_name', 'SITI NURHALIZA', 'read_ic', '900101-14-5678'));
select pg_temp.check((select mismatch = array['name', 'ic'] from public.identity_checks where id = pg_temp.id('id1')),
                     'what was read is checked against the profile');
select pg_temp.check(pg_temp.needs('phone-aaaaaaaa-1') = 'pending', 'then they wait for approval');
select pg_temp.check(public.dispatch_my_checks('phone-aaaaaaaa-1')->'id'->>'state' = 'pending', 'the ID is waiting');
select pg_temp.check(jsonb_array_length(public.dispatch_my_stands()) = 0, 'still shut while it waits');

-- 2. Reviewing: Documents admins only, with a reason from the list --------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000281b1');
select pg_temp.refused($q$select public.identity_checks_list('waiting')$q$, 'a rider listing the uploads');
select pg_temp.refused($q$select public.identity_check_review(pg_temp.id('id1'), 'Approved')$q$, 'a rider approving');
select pg_temp.check((select count(*) = 0 from public.identity_checks), 'a rider reads no one''s checks');

select pg_temp.as_user('00000000-0000-0000-0000-0000000281a2');
select pg_temp.check((select count(*) = 2 from jsonb_array_elements(public.identity_checks_list('waiting')) x
                       where x->>'user_id' = '00000000-0000-0000-0000-0000000281a3'), 'both wait for review');
select pg_temp.check(public.identity_checks_waiting() >= 2, 'the count of what waits');
select pg_temp.refused($q$select public.identity_check_review(pg_temp.id('id1'), 'Rejected')$q$, 'rejecting with no reason');
select pg_temp.refused($q$select public.identity_check_review(pg_temp.id('id1'), 'Rejected', 'other')$q$,
  'Other with no note');
select pg_temp.refused($q$select public.identity_check_review(pg_temp.id('id1'), 'Rejected', 'smudge')$q$,
  'a reason not on the list');
select public.identity_check_review(pg_temp.id('id1'), 'Rejected', 'name_mismatch', 'Use your own MyKad');
select pg_temp.refused($q$select public.dispatch_set_verify('00000000-0000-0000-0000-0000000281a3', 'stand_admin', false, false)$q$,
  'a Documents admin changing the switches');

select pg_temp.as_user('00000000-0000-0000-0000-0000000281a3');
select pg_temp.check(pg_temp.needs('phone-aaaaaaaa-1') = 'id', 'a rejected ID is asked again');
select pg_temp.check(public.dispatch_my_checks()->'id'->>'reason' = 'name_mismatch'
                     and public.dispatch_my_checks()->'id'->>'note' = 'Use your own MyKad', 'with the reason');
select pg_temp.sent('id2', jsonb_build_object('kind', 'id', 'doc_type', 'passport',
  'file_url', pg_temp.file('ID_Image', 'front2.jpg'), 'file_url_back', pg_temp.file('ID_Image', 'back2.jpg'),
  'expiry_date', (current_date + 400)::text, 'read_name', 'AINA BINTI AHMAD'));
select pg_temp.check((select mismatch = '{}' from public.identity_checks where id = pg_temp.id('id2')), 'the name matches');

select pg_temp.as_user('00000000-0000-0000-0000-0000000281a2');
select public.identity_check_review(pg_temp.id('id2'), 'Approved');

select pg_temp.as_user('00000000-0000-0000-0000-0000000281a3');
select pg_temp.check(pg_temp.needs('phone-aaaaaaaa-1') = '', 'nothing left');
select pg_temp.check(jsonb_array_length(public.dispatch_my_stands()) = 1, 'the stand opens');
select pg_temp.check(public.dispatch_caller_can('00000000-0000-0000-0000-0000000281e1', 'assign'), 'and its console');
reset role;
select pg_temp.check((select id_verified::text = 'Verified' and id_expiry_date = current_date + 400
                        from public.profiles where id = '00000000-0000-0000-0000-0000000281a3'),
                     'the approved ID is the profile''s');
set local role authenticated;

-- 3. A new phone: a live selfie again before the role opens ---------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000281a3');
select pg_temp.check(pg_temp.needs('phone-bbbbbbbb-2') = 'recheck', 'a phone not seen before asks for a selfie');
select pg_temp.check(jsonb_array_length(public.dispatch_my_stands()) = 0, 'and shuts the role till then');
select pg_temp.sent('re1', jsonb_build_object('kind', 'selfie', 'purpose', 'recheck',
  'file_url', pg_temp.file('ID_Image', 'again.jpg'), 'liveness', 'not_checked', 'device', 'phone-bbbbbbbb-2'));
select pg_temp.check(pg_temp.needs('phone-bbbbbbbb-2') = '', 'the selfie makes it known');
select pg_temp.check(pg_temp.needs('phone-aaaaaaaa-1') = '', 'the first phone stays known');
select pg_temp.check(jsonb_array_length(public.dispatch_my_stands()) = 1, 'the role opens again');

-- 4. An ID running out ------------------------------------------------------------------------------
reset role;
update public.identity_checks set expiry_date = current_date + 10 where id = (select id from ids where k = 'id2');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000281a3');
select pg_temp.check(public.dispatch_my_checks()->'id'->>'state' = 'renew' and pg_temp.needs() = '',
                     'asked for a new one before it runs out, the role still open');
reset role;
update public.identity_checks set expiry_date = current_date - 1 where id = (select id from ids where k = 'id2');
update public.profiles set id_verified = null where id = '00000000-0000-0000-0000-0000000281a3';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000281a3');
select pg_temp.check(public.dispatch_my_checks()->'id'->>'state' = 'expired' and pg_temp.needs() = 'id',
                     'run out is as good as none');
select pg_temp.refused($q$select public.identity_check_submit(jsonb_build_object('kind', 'id', 'doc_type', 'passport',
  'file_url', pg_temp.file('ID_Image', 'f.jpg'), 'file_url_back', pg_temp.file('ID_Image', 'b.jpg'),
  'expiry_date', (current_date - 3)::text))$q$, 'sending an ID that has run out');

-- 5. The switches afterwards, and the deadline ------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000281a4');
select pg_temp.check(pg_temp.needs('phone-cccccccc-3') = '', 'a grant asking nothing is open');
select pg_temp.check(cardinality(public.dispatch_caller_fleet_ids()) = 1, 'the fleet is theirs');

select pg_temp.as_user('00000000-0000-0000-0000-0000000281a1');
select public.dispatch_set_verify('00000000-0000-0000-0000-0000000281a4', 'fleet_owner', true, false, 3);
select pg_temp.refused($q$select public.dispatch_set_verify('00000000-0000-0000-0000-0000000281a4', 'fleet_owner', true, false, 0)$q$,
  'a deadline of no days');
reset role;
update public.dispatch_fleet_owners set verify_by = now() - interval '1 hour'
 where user_id = '00000000-0000-0000-0000-0000000281a4';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000281a1');
select pg_temp.check((select (x->'verify'->>'paused')::boolean from jsonb_array_elements(public.dispatch_accounts()) x
                       where x->>'user_id' = '00000000-0000-0000-0000-0000000281a4'), 'past the deadline: paused');
select pg_temp.check((select x->'verify'->'needs' = '["selfie"]'::jsonb from jsonb_array_elements(public.dispatch_accounts()) x
                       where x->>'user_id' = '00000000-0000-0000-0000-0000000281a4'), 'with what is left');
select pg_temp.check(jsonb_array_length(public.identity_person('00000000-0000-0000-0000-0000000281a3')->'checks') = 4,
                     'the admin sees the person''s checks');

select pg_temp.as_user('00000000-0000-0000-0000-0000000281a4');
select pg_temp.check(cardinality(public.dispatch_caller_fleet_ids()) = 0, 'the fleet is shut');
select pg_temp.check((public.dispatch_my_checks()->>'paused')::boolean, 'and they are told');

-- 6. A profile selfie is kept for its liveness, never queued ---------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000281b1');
select pg_temp.sent('p1', jsonb_build_object('kind', 'selfie', 'purpose', 'profile',
  'file_url', pg_temp.file('avatars', 'avatar.jpg'), 'liveness', 'passed', 'liveness_detail', 'turn'));
select pg_temp.check((select status is null and liveness = 'passed' from public.identity_checks where id = pg_temp.id('p1')),
                     'a profile photo: its liveness, no review');
select pg_temp.check(public.dispatch_my_checks()->>'holds' = 'false', 'a rider holds no role');

-- 7. Users → ID documents: a reason from the list there too ------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000281a2');
select pg_temp.refused($q$select public.profile_id_review('00000000-0000-0000-0000-0000000281b1', 'Failed')$q$,
  'rejecting a profile ID with no reason');
select public.profile_id_review('00000000-0000-0000-0000-0000000281b1', 'Failed', 'blurry', 'Use daylight');
select pg_temp.as_user('00000000-0000-0000-0000-0000000281b1');
select pg_temp.refused($q$select public.profile_id_review('00000000-0000-0000-0000-0000000281b1', 'Verified')$q$,
  'a rider verifying their own ID');
reset role;
select pg_temp.check((select id_verified::text = 'Failed' from public.profiles
                       where id = '00000000-0000-0000-0000-0000000281b1'), 'the profile ID is marked rejected');
set local role authenticated;

-- 8. The renewal window --------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000281a2');
select pg_temp.refused($q$select public.dispatch_set_verify_config(10)$q$, 'a Documents admin changing the window');
select pg_temp.as_user('00000000-0000-0000-0000-0000000281a1');
select pg_temp.check((public.dispatch_set_verify_config(10)->>'renewDays')::int = 10, 'the admin sets it');

reset role;
select 'dispatch_signin_checks_0281: all passed';
rollback;
