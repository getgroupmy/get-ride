-- ============================================================================
-- Regression test for migration 0432: who may change the protected columns of
-- a partner row, and of what is reviewed with it (the profile, the vehicle,
-- the documents).
--   * Through the API they are changed by an admin who may edit the table,
--     and by nobody else: not the row's owner, not an admin who may only
--     read the table, not an admin whose pages edit something else.
--   * An approved partner's Partner Service types: also an approver who is
--     also an admin, from My Team (renaming a type is covered in
--     safe_renames_0304.sql).
--   * The server changes them as before.
--   * A signed-in user still does what is theirs: fills in and submits an
--     application, replaces a document.
-- All names are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/people_guards_page_scope_0432.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000432a1'),  -- applies to be a partner
  ('00000000-0000-0000-0000-0000000432a2'),  -- an account with no partner row
  ('00000000-0000-0000-0000-0000000432a3'),  -- an approved partner, on an approver's team
  ('00000000-0000-0000-0000-0000000432b1'),  -- back office: may only read partners; an approved partner
  ('00000000-0000-0000-0000-0000000432b2'),  -- back office: edits another page; an applicant
  ('00000000-0000-0000-0000-0000000432b3'),  -- back office: reads another page; no partner row yet
  ('00000000-0000-0000-0000-0000000432b4'),  -- back office: may edit vehicles, not partners; an applicant
  ('00000000-0000-0000-0000-0000000432b5'),  -- back office: may only read users; an approver; an approved partner
  ('00000000-0000-0000-0000-0000000432c1'),  -- back office: may edit partners
  ('00000000-0000-0000-0000-0000000432c2'),  -- back office: may edit users
  ('00000000-0000-0000-0000-0000000432c3')   -- back office: full admin
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000432%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000432b1', 'admin-partners', 'read'),
  ('00000000-0000-0000-0000-0000000432b2', 'admin-settings-ip-access', 'edit'),
  ('00000000-0000-0000-0000-0000000432b3', 'admin-settings-ip-access', 'read'),
  ('00000000-0000-0000-0000-0000000432b4', 'admin-vehicle-edit', 'edit'),
  ('00000000-0000-0000-0000-0000000432b5', 'admin-users', 'read'),
  ('00000000-0000-0000-0000-0000000432c1', 'admin-partner-edit', 'edit'),
  ('00000000-0000-0000-0000-0000000432c2', 'admin-user-edit', 'edit'),
  ('00000000-0000-0000-0000-0000000432c3', '*', 'edit')
on conflict do nothing;

-- Partner sign-up open, as shipped.
insert into public.admin_display_settings (id, settings) values ('global', '{}'::jsonb)
on conflict (id) do update set settings = public.admin_display_settings.settings
  - 'registrationEnabled' - 'passengerRegistrationEnabled' - 'driverRegistrationEnabled';

insert into public.partners (id, auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000432d1', '00000000-0000-0000-0000-0000000432a1', 'Applicant 0432', '+60100004321', 'unapproved'),
  ('00000000-0000-0000-0000-0000000432e1', '00000000-0000-0000-0000-0000000432b1', 'Reads Partners 0432', '+60100004322', 'approved'),
  ('00000000-0000-0000-0000-0000000432e2', '00000000-0000-0000-0000-0000000432b2', 'Other Page 0432', '+60100004323', 'unapproved'),
  ('00000000-0000-0000-0000-0000000432e4', '00000000-0000-0000-0000-0000000432b4', 'Edits Vehicles 0432', '+60100004324', 'unapproved'),
  ('00000000-0000-0000-0000-0000000432e5', '00000000-0000-0000-0000-0000000432b5', 'Approver 0432', '+60100004328', 'approved'),
  ('00000000-0000-0000-0000-0000000432d3', '00000000-0000-0000-0000-0000000432a3', 'Team Member 0432', '+60100004329', 'approved'),
  ('00000000-0000-0000-0000-0000000432f1', '00000000-0000-0000-0000-0000000432c1', 'Edits Partners 0432', '+60100004325', 'unapproved');
-- An approver who may edit their team's profiles, everybody's but their own.
insert into public.approvers (profile_id, scope, conflict_guard, use_own_region, regions, doc_types, can_edit_profile)
values ('00000000-0000-0000-0000-0000000432b5', 'all', true, false, '[]'::jsonb, '{}', true);
insert into public.vehicle (id, plate, auth_user_id, owner_partner_id, status) values
  ('00000000-0000-0000-0000-0000004320e1', 'TST4321', '00000000-0000-0000-0000-0000000432b1',
   '00000000-0000-0000-0000-0000000432e1', 'approved'),
  ('00000000-0000-0000-0000-0000004320e4', 'TST4324', '00000000-0000-0000-0000-0000000432b4',
   '00000000-0000-0000-0000-0000000432e4', 'unapproved');
insert into public.provider_documents (id, partner_id, auth_user_id, doc_id, doc_name, status) values
  ('00000000-0000-0000-0000-0000004321e1', '00000000-0000-0000-0000-0000000432e1',
   '00000000-0000-0000-0000-0000000432b1', 'licence', 'Driving licence', 'Pending Review'),
  ('00000000-0000-0000-0000-0000004321e4', '00000000-0000-0000-0000-0000000432e4',
   '00000000-0000-0000-0000-0000000432b4', 'licence', 'Driving licence', 'Pending Review');
insert into public.vehicle_documents (id, vehicle_id, auth_user_id, doc_id, doc_name, status) values
  ('00000000-0000-0000-0000-0000004322e1', '00000000-0000-0000-0000-0000004320e1',
   '00000000-0000-0000-0000-0000000432b1', 'insurance', 'Insurance', 'Pending Review'),
  ('00000000-0000-0000-0000-0000004322e4', '00000000-0000-0000-0000-0000004320e4',
   '00000000-0000-0000-0000-0000000432b4', 'insurance', 'Insurance', 'Pending Review');

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated, service_role;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

-- [p_sql] must be refused, and with [p_error]: a refusal for any other reason
-- (a policy, another rule) is not the rule under test.
create or replace function pg_temp.refused(p_sql text, p_error text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm = p_error then
      return;
    end if;
    raise exception 'FAILED: % was refused with "%", not "%"', p_what, sqlerrm, p_error;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text, text) to authenticated;

-- Each "column = value" of [p_sets], put into [p_sql] at %s, must be refused
-- with [p_tag]:<that column>.
create or replace function pg_temp.each_refused(p_sql text, p_tag text, p_sets text[], p_who text)
returns void language plpgsql as $$
declare
  s text;
begin
  foreach s in array p_sets loop
    perform pg_temp.refused(format(p_sql, s), p_tag || ':' || btrim(split_part(s, '=', 1)), p_who || ' setting ' || s);
  end loop;
end $$;
grant execute on function pg_temp.each_refused(text, text, text[], text) to authenticated;

set local role authenticated;

-- ============================ public.partners ==================================================

-- 1. A signed-in user and their own application ------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000432a1');
select pg_temp.each_refused(
  $q$update public.partners set %s where auth_user_id = auth.uid()$q$, 'PARTNERS_PROTECTED_COLUMN',
  array[$v$rating = 5$v$, $v$status = 'approved'$v$, $v$phone = '+60100004390'$v$, $v$driving_since = '2001-01-01'$v$],
  'an applicant');
update public.partners set address = '1 Jalan Ujian', documents_ok = true where auth_user_id = auth.uid();
select pg_temp.check((select address = '1 Jalan Ujian' and documents_ok and status = 'unapproved'
                        from public.partners where id = '00000000-0000-0000-0000-0000000432d1'),
  'an applicant still fills in and submits their own application');

-- 2. An admin who may only read partners, on their own approved row: every column ----------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000432b1');
select pg_temp.check(public.caller_is_admin() and not public.caller_admin_can_write('partners'),
  'reading partners is not editing them');
select pg_temp.each_refused(
  $q$update public.partners set %s where auth_user_id = auth.uid()$q$, 'PARTNERS_PROTECTED_COLUMN',
  array[
    $v$id = '00000000-0000-0000-0000-0000004329f1'$v$,
    $v$auth_user_id = '00000000-0000-0000-0000-0000000432a2'$v$,
    $v$display_id = 'PR-0432-X'$v$,
    $v$status = 'blocked'$v$,
    $v$permit = 'verified'$v$,
    $v$rating = 5$v$,
    $v$total_rides = 99$v$,
    $v$joined_at = '2020-01-01'$v$,
    $v$created_at = '2020-01-01'$v$,
    $v$status_note = 'Looks fine'$v$,
    $v$resubmitted_at = '2026-01-01'$v$,
    $v$documents_ok = true$v$,
    -- Approved: the person who was reviewed.
    $v$name = 'Somebody Else'$v$,
    $v$phone = '+60100004391'$v$,
    $v$ic = '900101-01-0432'$v$,
    $v$avatar_url = 'https://cdn.example/other-0432.jpg'$v$,
    $v$driving_since = '2001-01-01'$v$],
  'an admin who may only read partners');
select pg_temp.refused($q$update public.partners set partner_types = array['Teksi 0432'] where auth_user_id = auth.uid()$q$,
  'PARTNER_TYPES_LOCKED', 'an admin who may only read partners changing their approved Partner Service types');
select pg_temp.refused($q$update public.partners set partner_type = 'Teksi 0432' where auth_user_id = auth.uid()$q$,
  'PARTNER_TYPES_LOCKED', 'or their single type');
update public.partners set my_ride_code = 'MINE0432', address = '2 Jalan Ujian' where auth_user_id = auth.uid();
select pg_temp.check((select address = '2 Jalan Ujian' and my_ride_code <> 'MINE0432'
                        from public.partners where id = '00000000-0000-0000-0000-0000000432e1'),
  'their My Ride code stays the server''s; their address is theirs');

-- 3. An admin whose pages edit something else, on their own application --------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000432b2');
select pg_temp.each_refused(
  $q$update public.partners set %s where auth_user_id = auth.uid()$q$, 'PARTNERS_PROTECTED_COLUMN',
  array[$v$status = 'rejected'$v$, $v$status = 'approved'$v$, $v$rating = 5$v$, $v$total_rides = 99$v$,
        $v$permit = 'verified'$v$, $v$status_note = 'Looks fine'$v$,
        -- While it waits: the phone has its own rule (0277).
        $v$phone = '+60100004392'$v$, $v$driving_since = '2001-01-01'$v$],
  'an admin whose pages edit something else');
update public.partners set documents_ok = true where auth_user_id = auth.uid();
select pg_temp.check((select documents_ok and status = 'unapproved' from public.partners
                       where id = '00000000-0000-0000-0000-0000000432e2'),
  'they submit their own application like any applicant');
select pg_temp.refused($q$update public.partners set documents_ok = false where auth_user_id = auth.uid()$q$,
  'PARTNERS_PROTECTED_COLUMN:documents_ok', 'and taking it back');

-- 4. A new row: an admin without a partner row starts like anybody -------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000432b3');
select pg_temp.refused($q$insert into public.partners (id, auth_user_id, name, phone, status)
  values ('00000000-0000-0000-0000-0000000432e3', auth.uid(), 'Reads Another 0432', '+60100004326', 'approved')$q$,
  'PARTNERS_PROTECTED_COLUMN:status', 'a new row that starts approved');
select pg_temp.refused($q$insert into public.partners (id, auth_user_id, name, phone, status, permit)
  values ('00000000-0000-0000-0000-0000000432e3', auth.uid(), 'Reads Another 0432', '+60100004326', 'unapproved', 'verified')$q$,
  'PARTNERS_PROTECTED_COLUMN:permit', 'a new row with a verified permit');
select pg_temp.refused($q$insert into public.partners (id, auth_user_id, name, phone, status, rating)
  values ('00000000-0000-0000-0000-0000000432e3', auth.uid(), 'Reads Another 0432', '+60100004326', 'unapproved', 5)$q$,
  'PARTNERS_PROTECTED_COLUMN:rating', 'a new row with a rating');
select pg_temp.refused($q$insert into public.partners (id, auth_user_id, name, phone, status, total_rides)
  values ('00000000-0000-0000-0000-0000000432e3', auth.uid(), 'Reads Another 0432', '+60100004326', 'unapproved', 99)$q$,
  'PARTNERS_PROTECTED_COLUMN:total_rides', 'a new row with trips');
select pg_temp.refused($q$insert into public.partners (id, auth_user_id, name, phone, status, status_note)
  values ('00000000-0000-0000-0000-0000000432e3', auth.uid(), 'Reads Another 0432', '+60100004326', 'unapproved', 'Looks fine')$q$,
  'PARTNERS_PROTECTED_COLUMN:status_note', 'a new row with a status note');
select pg_temp.refused($q$insert into public.partners (id, auth_user_id, name, phone, status, documents_ok)
  values ('00000000-0000-0000-0000-0000000432e3', auth.uid(), 'Reads Another 0432', '+60100004326', 'unapproved', true)$q$,
  'PARTNERS_PROTECTED_COLUMN:documents_ok', 'a new row already submitted');
select pg_temp.refused($q$insert into public.partners (id, auth_user_id, name, phone, status, driving_since)
  values ('00000000-0000-0000-0000-0000000432e3', auth.uid(), 'Reads Another 0432', '+60100004326', 'unapproved', '2001-01-01')$q$,
  'PARTNERS_PROTECTED_COLUMN:driving_since', 'a new row with a driving date');
insert into public.partners (id, auth_user_id, name, phone, status, my_ride_code)
values ('00000000-0000-0000-0000-0000000432e3', auth.uid(), 'Reads Another 0432', '+60100004326', 'unapproved', 'MINE0432');
select pg_temp.check((select status = 'unapproved' and rating = 0 and my_ride_code <> 'MINE0432'
                        from public.partners where id = '00000000-0000-0000-0000-0000000432e3'),
  'their application is made like anybody''s, with the server''s My Ride code');

-- 5. An admin who may edit vehicles is not one who may edit partners ------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000432b4');
select pg_temp.each_refused(
  $q$update public.partners set %s where auth_user_id = auth.uid()$q$, 'PARTNERS_PROTECTED_COLUMN',
  array[$v$rating = 5$v$, $v$status = 'blocked'$v$, $v$phone = '+60100004393'$v$],
  'an admin who may edit vehicles');

-- 6. The back office: an admin who may edit partners ----------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000432c1');
select pg_temp.check(public.caller_admin_can_write('partners'), 'the Edit Partner page edits partners');
-- Somebody's row ...
update public.partners
   set rating = 4.5, total_rides = 12, display_id = 'PR-0432-A', permit = 'verified', status = 'blocked',
       status_note = 'Test note 0432', phone = '+60100004394', driving_since = '2015-06-01', my_ride_code = 'code0432'
 where id = '00000000-0000-0000-0000-0000000432d1';
-- ... an approved partner's name, photo and types ...
update public.partners
   set name = 'Reads Partners Renamed', avatar_url = 'https://cdn.example/reviewed-0432.jpg',
       partner_types = array['Courier 0432']
 where id = '00000000-0000-0000-0000-0000000432e1';
-- ... their own ...
update public.partners set rating = 4, status_note = 'Own row 0432' where auth_user_id = auth.uid();
-- ... and a new partner, approved as it is added (Admin > Partner Add).
insert into public.partners (id, auth_user_id, display_id, name, phone, status, permit)
values ('00000000-0000-0000-0000-0000000432f2', '00000000-0000-0000-0000-0000000432a2', 'PR-0432-B',
        'Added 0432', '+60100004327', 'approved', 'verified');
reset role;
select pg_temp.check((select rating = 4.5 and total_rides = 12 and display_id = 'PR-0432-A' and permit = 'verified'
                             and status = 'blocked' and status_note = 'Test note 0432' and phone = '+60100004394'
                             and driving_since = '2015-06-01' and my_ride_code = 'CODE0432'
                        from public.partners where id = '00000000-0000-0000-0000-0000000432d1'),
  'an admin who may edit partners changes a partner''s protected columns');
select pg_temp.check((select name = 'Reads Partners Renamed' and avatar_url = 'https://cdn.example/reviewed-0432.jpg'
                             and partner_types = array['Courier 0432']
                        from public.partners where id = '00000000-0000-0000-0000-0000000432e1'),
  'and an approved partner''s name, photo and types');
select pg_temp.check((select rating = 4 and status_note = 'Own row 0432'
                        from public.partners where id = '00000000-0000-0000-0000-0000000432f1'),
  'and their own row');
select pg_temp.check((select status = 'approved' and permit = 'verified' and display_id = 'PR-0432-B'
                        from public.partners where id = '00000000-0000-0000-0000-0000000432f2'),
  'and adds a partner already approved');

-- A full admin.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000432c3');
update public.partners set rating = 3.5, status = 'rejected', status_note = 'Full admin 0432'
 where id = '00000000-0000-0000-0000-0000000432e2';
reset role;
select pg_temp.check((select rating = 3.5 and status = 'rejected' and status_note = 'Full admin 0432'
                        from public.partners where id = '00000000-0000-0000-0000-0000000432e2'),
  'a full admin changes them too');

-- 7. An approved member's types, from My Team ---------------------------------------------------
-- An approver who is also an admin changes them there, though their admin
-- pages do not edit partners: that step marks its own write. Their own types
-- they change like anybody else: not by writing the row, even straight after.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000432b5');
select pg_temp.check(public.caller_is_admin() and not public.caller_admin_can_write('partners'),
  'the approver is an admin who may not edit partners');
select pg_temp.check((public.approver_edit_profile('00000000-0000-0000-0000-0000000432a3',
                        '{"partner_types": ["Teksi 0432", "Courier 0432"]}'::jsonb) ->> 'ok') = 'true',
  'an approver who is also an admin changes an approved member''s types from My Team');
select pg_temp.check(coalesce(current_setting('app.approver_edit_profile', true), '') = '',
  'the step''s mark ends with its write');
select pg_temp.refused($q$update public.partners set partner_types = array['Teksi 0432'] where auth_user_id = auth.uid()$q$,
  'PARTNER_TYPES_LOCKED', 'the approver changing their own approved types by writing the row');
reset role;
select pg_temp.check((select partner_types = array['Teksi 0432', 'Courier 0432']
                        from public.partners where id = '00000000-0000-0000-0000-0000000432d3'),
  'the member''s types are written');
select pg_temp.check((select partner_types = '{}'::text[]
                        from public.partners where id = '00000000-0000-0000-0000-0000000432e5'),
  'the approver''s own types are as they were');

-- 8. The server's own writes are not checked ------------------------------------------------------
-- A direct session (migrations, cron, the SQL editor): no role, nobody signed in ...
select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
update public.partners
   set rating = 4.8, total_rides = 321, status = 'approved', phone = '+60100004395', driving_since = '2010-01-01',
       my_ride_code = 'srv0432'
 where id = '00000000-0000-0000-0000-0000000432e4';
select pg_temp.check((select rating = 4.8 and total_rides = 321 and status = 'approved' and phone = '+60100004395'
                             and driving_since = '2010-01-01' and my_ride_code = 'SRV0432'
                        from public.partners where id = '00000000-0000-0000-0000-0000000432e4'),
  'a direct session writes as before');
update public.partners set partner_types = array['Server 0432'] where id = '00000000-0000-0000-0000-0000000432d3';
select pg_temp.check((select partner_types = array['Server 0432']
                        from public.partners where id = '00000000-0000-0000-0000-0000000432d3'),
  'and an approved partner''s types');
-- ... and the service role (edge functions).
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true), set_config('request.jwt.claim.sub', '', true);
update public.partners set rating = 4.9, status = 'unapproved', status_note = 'Service 0432'
 where id = '00000000-0000-0000-0000-0000000432e4';
select pg_temp.check((select rating = 4.9 and status = 'unapproved' and status_note = 'Service 0432'
                        from public.partners where id = '00000000-0000-0000-0000-0000000432e4'),
  'the service role writes as before');
reset role;
select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);

-- What the refused writes left behind: nothing.
select pg_temp.check((select status = 'approved' and rating = 0 and total_rides = 0 and permit = 'pending'
                             and display_id is null and status_note is null and resubmitted_at is null
                             and not documents_ok and phone = '+60100004322' and ic is null and driving_since is null
                             and auth_user_id = '00000000-0000-0000-0000-0000000432b1'
                        from public.partners where id = '00000000-0000-0000-0000-0000000432e1'),
  'the row of the admin who may only read partners is as it was');

-- ============================ public.profiles ==================================================
set local role authenticated;

-- 9. An admin who may not edit profiles, on their own profile -------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000432b1');
select pg_temp.check(not public.caller_admin_can_write('profiles'), 'reading partners does not edit profiles');
select pg_temp.each_refused(
  $q$update public.profiles set %s where id = auth.uid()$q$, 'PROFILE_PROTECTED_COLUMN',
  array[
    $v$id = '00000000-0000-0000-0000-0000004329f2'$v$,
    $v$phone = '+60100004396'$v$,
    $v$status = 'blocked'$v$,
    $v$profile_status = 'Approved'$v$,
    $v$id_verified = 'Verified'$v$,
    $v$id_expiry_date = '2040-01-01'$v$,
    $v$documents_ok = true$v$,
    $v$total_rides = 99$v$,
    $v$display_id = 'US-0432-X'$v$,
    $v$referral_code = 'REF0432'$v$,
    $v$device_count = 9$v$,
    $v$joined_at = '2020-01-01'$v$,
    $v$created_at = '2020-01-01'$v$,
    $v$pin_hash = 'x'$v$,
    $v$pin_failed_attempts = 3$v$,
    $v$pin_locked_until = '2040-01-01'$v$,
    $v$mcash_wallet_id = 'W-0432'$v$,
    $v$mcash_ekyc_status = 'verified'$v$,
    $v$mcash_customer_status = 'active'$v$,
    -- An approved partner: the person who was reviewed (0277), and their gender (0310).
    $v$name = 'Somebody Else'$v$,
    $v$ic = '900101-01-0432'$v$,
    $v$avatar_url = 'https://cdn.example/other-0432.jpg'$v$,
    $v$gender = 'female'$v$,
    -- The rider's rating (0269).
    $v$rider_rating = 5$v$],
  'an admin who may not edit profiles');
select pg_temp.refused($q$update public.profiles set rider_ratings_count = 50 where id = auth.uid()$q$,
  'PROFILE_PROTECTED_COLUMN:rider_rating', 'their count of ratings');
select pg_temp.refused($q$update public.profiles set offers_paused_until = null, rider_rating = 1 where id = auth.uid()$q$,
  'PROFILE_PROTECTED_COLUMN:rider_rating', 'their rating, the other way');
update public.profiles set address = '3 Jalan Ujian' where id = auth.uid();
select pg_temp.check((select address = '3 Jalan Ujian' from public.profiles where id = auth.uid()),
  'their address is theirs');

-- An admin who may edit vehicles, likewise.
select pg_temp.as_user('00000000-0000-0000-0000-0000000432b4');
select pg_temp.each_refused(
  $q$update public.profiles set %s where id = auth.uid()$q$, 'PROFILE_PROTECTED_COLUMN',
  array[$v$phone = '+60100004397'$v$, $v$status = 'approved'$v$, $v$id_verified = 'Verified'$v$, $v$rider_rating = 5$v$],
  'an admin who may edit vehicles');

-- 10. An admin who may edit users ------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000432c2');
select pg_temp.check(public.caller_admin_can_write('profiles') and not public.caller_admin_can_write('partners'),
  'the Edit User page edits profiles, not partners');
update public.profiles
   set status = 'blocked', id_verified = 'Verified', total_rides = 7, referral_code = 'REF0432A', rider_rating = 4.5,
       gender = 'female'
 where id = '00000000-0000-0000-0000-0000000432a1';
-- An approved partner's reviewed name, on the profile.
update public.profiles set name = 'Renamed On Profile' where id = '00000000-0000-0000-0000-0000000432b1';
reset role;
select pg_temp.check((select status = 'blocked' and id_verified = 'Verified' and total_rides = 7
                             and referral_code = 'REF0432A' and rider_rating = 4.5 and gender = 'female'
                        from public.profiles where id = '00000000-0000-0000-0000-0000000432a1'),
  'an admin who may edit users changes a profile''s protected columns');
select pg_temp.check((select name = 'Renamed On Profile' from public.profiles
                       where id = '00000000-0000-0000-0000-0000000432b1'),
  'and an approved partner''s name on the profile');

-- 11. The server ------------------------------------------------------------------------------------
update public.profiles set status = 'approved', id_verified = 'Expired', rider_rating = 3, gender = 'male'
 where id = '00000000-0000-0000-0000-0000000432a1';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true), set_config('request.jwt.claim.sub', '', true);
update public.profiles set total_rides = 8, referral_code = 'REF0432B' where id = '00000000-0000-0000-0000-0000000432a1';
reset role;
select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
select pg_temp.check((select status = 'approved' and id_verified = 'Expired' and rider_rating = 3 and gender = 'male'
                             and total_rides = 8 and referral_code = 'REF0432B'
                        from public.profiles where id = '00000000-0000-0000-0000-0000000432a1'),
  'the server writes profiles as before');

-- ============================ public.vehicle ===================================================
set local role authenticated;

-- 12. An admin who may not edit vehicles, on their own vehicle ------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000432b1');
select pg_temp.check(not public.caller_admin_can_write('vehicle'), 'reading partners does not edit vehicles');
select pg_temp.each_refused(
  $q$update public.vehicle set %s where id = '00000000-0000-0000-0000-0000004320e1'$q$, 'VEHICLE_PROTECTED_COLUMN',
  array[
    $v$id = '00000000-0000-0000-0000-0000004329f3'$v$,
    $v$display_id = 'VH-0432-X'$v$,
    $v$status = 'blocked'$v$,
    $v$permit = 'verified'$v$,
    $v$joined_at = '2020-01-01'$v$,
    $v$created_at = '2020-01-01'$v$,
    $v$documents_ok = true$v$,
    $v$auth_user_id = '00000000-0000-0000-0000-0000000432a2'$v$,
    $v$owner_partner_id = '00000000-0000-0000-0000-0000000432d1'$v$],
  'an admin who may not edit vehicles');
update public.vehicle set color = 'Blue' where id = '00000000-0000-0000-0000-0000004320e1';
select pg_temp.check((select color = 'Blue' from public.vehicle where id = '00000000-0000-0000-0000-0000004320e1'),
  'their vehicle''s colour is theirs');
select pg_temp.as_user('00000000-0000-0000-0000-0000000432b3');
select pg_temp.refused($q$insert into public.vehicle (id, plate, auth_user_id, status)
  values ('00000000-0000-0000-0000-0000004320e3', 'TST4323', auth.uid(), 'approved')$q$,
  'VEHICLE_PROTECTED_COLUMN:status', 'a new vehicle that starts approved');
select pg_temp.refused($q$insert into public.vehicle (id, plate, auth_user_id, status, permit)
  values ('00000000-0000-0000-0000-0000004320e3', 'TST4323', auth.uid(), 'unapproved', 'verified')$q$,
  'VEHICLE_PROTECTED_COLUMN:permit', 'a new vehicle with a verified permit');
select pg_temp.refused($q$insert into public.vehicle (id, plate, auth_user_id, status, documents_ok)
  values ('00000000-0000-0000-0000-0000004320e3', 'TST4323', auth.uid(), 'unapproved', true)$q$,
  'VEHICLE_PROTECTED_COLUMN:documents_ok', 'a new vehicle already submitted');

-- 13. An admin who may edit vehicles ---------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000432b4');
select pg_temp.check(public.caller_admin_can_write('vehicle') and public.caller_admin_can_write('vehicle_documents')
                     and not public.caller_admin_can_write('provider_documents'),
  'the Edit Vehicle page edits vehicles and their documents');
update public.vehicle set status = 'blocked', permit = 'verified', display_id = 'VH-0432-A'
 where id = '00000000-0000-0000-0000-0000004320e1';
update public.vehicle set permit = 'non-verified', display_id = 'VH-0432-B'
 where id = '00000000-0000-0000-0000-0000004320e4';
reset role;
select pg_temp.check((select status = 'blocked' and permit = 'verified' and display_id = 'VH-0432-A'
                        from public.vehicle where id = '00000000-0000-0000-0000-0000004320e1'),
  'an admin who may edit vehicles changes a vehicle''s protected columns');
select pg_temp.check((select permit = 'non-verified' and display_id = 'VH-0432-B'
                        from public.vehicle where id = '00000000-0000-0000-0000-0000004320e4'),
  'and their own vehicle''s');

-- 14. The server ------------------------------------------------------------------------------------
select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
update public.vehicle set status = 'approved', permit = 'pending' where id = '00000000-0000-0000-0000-0000004320e1';
select pg_temp.check((select status = 'approved' and permit = 'pending'
                        from public.vehicle where id = '00000000-0000-0000-0000-0000004320e1'),
  'the server writes vehicles as before');

-- ============================ the documents ====================================================
set local role authenticated;

-- 15. An admin who may not edit documents, on their own documents ----------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000432b1');
select pg_temp.each_refused(
  $q$update public.provider_documents set %s where id = '00000000-0000-0000-0000-0000004321e1'$q$,
  'PROVIDER_DOCUMENTS_PROTECTED_COLUMN',
  array[$v$status = 'Approved'$v$, $v$reviewer_notes = 'Checked'$v$, $v$reviewed_at = '2026-01-01'$v$,
        $v$partner_id = '00000000-0000-0000-0000-0000000432d1'$v$,
        $v$auth_user_id = '00000000-0000-0000-0000-0000000432a2'$v$],
  'an admin who may not edit documents');
select pg_temp.each_refused(
  $q$update public.vehicle_documents set %s where id = '00000000-0000-0000-0000-0000004322e1'$q$,
  'VEHICLE_DOCUMENTS_PROTECTED_COLUMN',
  array[$v$status = 'Approved'$v$, $v$reviewer_notes = 'Checked'$v$, $v$reviewed_at = '2026-01-01'$v$,
        $v$vehicle_id = '00000000-0000-0000-0000-0000004320e4'$v$],
  'an admin who may not edit documents');
select pg_temp.refused($q$insert into public.provider_documents (partner_id, auth_user_id, doc_id, doc_name, status)
  values ('00000000-0000-0000-0000-0000000432e1', auth.uid(), 'permit', 'Permit', 'Approved')$q$,
  'PROVIDER_DOCUMENTS_PROTECTED_COLUMN:status', 'a new document that starts approved');
select pg_temp.refused($q$insert into public.vehicle_documents (vehicle_id, auth_user_id, doc_id, doc_name, status, reviewer_notes)
  values ('00000000-0000-0000-0000-0000004320e1', auth.uid(), 'puspakom', 'Inspection', 'Pending Review', 'Checked')$q$,
  'VEHICLE_DOCUMENTS_PROTECTED_COLUMN:reviewer_notes', 'a new document with a reviewer''s note');

-- 16. The table the document is in ------------------------------------------------------------------
-- An admin who may edit vehicles reviews a vehicle's document, not a partner's.
select pg_temp.as_user('00000000-0000-0000-0000-0000000432b4');
select pg_temp.refused($q$update public.provider_documents set status = 'Approved'
  where id = '00000000-0000-0000-0000-0000004321e4'$q$,
  'PROVIDER_DOCUMENTS_PROTECTED_COLUMN:status', 'an admin who may edit vehicles approving their own partner document');
update public.vehicle_documents set status = 'Approved', reviewer_notes = 'Checked 0432', reviewed_at = now()
 where id = '00000000-0000-0000-0000-0000004322e1';
-- An admin who may edit partners reviews both.
select pg_temp.as_user('00000000-0000-0000-0000-0000000432c1');
update public.provider_documents set status = 'Approved', reviewer_notes = 'Checked 0432', reviewed_at = now()
 where id = '00000000-0000-0000-0000-0000004321e1';
update public.vehicle_documents set status = 'Rejected', reviewer_notes = 'Blurred 0432', reviewed_at = now()
 where id = '00000000-0000-0000-0000-0000004322e4';
reset role;
select pg_temp.check((select status = 'Approved' and reviewer_notes = 'Checked 0432' and reviewed_at is not null
                        from public.vehicle_documents where id = '00000000-0000-0000-0000-0000004322e1'),
  'an admin who may edit vehicles reviews a vehicle''s document');
select pg_temp.check((select status = 'Approved' and reviewer_notes = 'Checked 0432'
                        from public.provider_documents where id = '00000000-0000-0000-0000-0000004321e1')
                     and (select status = 'Rejected' and reviewer_notes = 'Blurred 0432'
                            from public.vehicle_documents where id = '00000000-0000-0000-0000-0000004322e4'),
  'an admin who may edit partners reviews a partner''s document and a vehicle''s');

-- 17. The owner replaces a reviewed document: back to review ---------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000432b1');
update public.provider_documents set file_url = 'https://cdn.example/licence-0432-new.jpg'
 where id = '00000000-0000-0000-0000-0000004321e1';
update public.vehicle_documents set document_number = 'INS-0432-NEW'
 where id = '00000000-0000-0000-0000-0000004322e1';
reset role;
select pg_temp.check((select status = 'Pending Review' and reviewer_notes is null and reviewed_at is null
                        from public.provider_documents where id = '00000000-0000-0000-0000-0000004321e1')
                     and (select status = 'Pending Review' and reviewer_notes is null and reviewed_at is null
                            from public.vehicle_documents where id = '00000000-0000-0000-0000-0000004322e1'),
  'a replaced document goes back to review, whoever its owner is');

-- 18. The server ------------------------------------------------------------------------------------
select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
update public.provider_documents set status = 'Approved', reviewer_notes = 'Server 0432', reviewed_at = now()
 where id = '00000000-0000-0000-0000-0000004321e4';
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true), set_config('request.jwt.claim.sub', '', true);
update public.vehicle_documents set status = 'Expired' where id = '00000000-0000-0000-0000-0000004322e4';
reset role;
select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
select pg_temp.check((select status = 'Approved' and reviewer_notes = 'Server 0432'
                        from public.provider_documents where id = '00000000-0000-0000-0000-0000004321e4')
                     and (select status = 'Expired' from public.vehicle_documents
                           where id = '00000000-0000-0000-0000-0000004322e4'),
  'the server reviews documents as before');

-- ============================ the guards themselves ============================================

-- 19. Each is on its table, enabled -----------------------------------------------------------------
select pg_temp.check((select count(*) = 12
                        from pg_trigger t join pg_proc p on p.oid = t.tgfoid
                       where not t.tgisinternal and t.tgenabled = 'O'
                         and (t.tgrelid::regclass::text, t.tgname, p.proname) in (
                           ('partners', 'trg_partners_a_guard', 'partners_guard_protected_columns'),
                           ('partners', 'trg_partners_a_guard_phone', 'partners_guard_phone'),
                           ('partners', 'trg_partners_guard_driving_since', 'partners_guard_driving_since'),
                           ('partners', 'trg_partners_my_ride_code', 'partners_my_ride_code_guard'),
                           ('partners', 'trg_partners_a_types_locked', 'partners_types_locked'),
                           ('profiles', 'trg_profiles_a_guard', 'profiles_guard_protected_columns'),
                           ('profiles', 'trg_profiles_c_partner_identity', 'profiles_guard_partner_identity'),
                           ('profiles', 'trg_profiles_b_guard_city_ride', 'profiles_guard_city_ride'),
                           ('profiles', 'trg_profiles_d_verified_gender', 'profiles_guard_verified_gender'),
                           ('vehicle', 'trg_vehicle_a_guard', 'vehicle_guard_protected_columns'),
                           ('provider_documents', 'provider_documents_a_guard', 'documents_guard_review_columns'),
                           ('vehicle_documents', 'vehicle_documents_a_guard', 'documents_guard_review_columns'))),
  'the guards are on their tables and enabled');

-- 20. A guard on these tables asks about its table --------------------------------------------------
-- A rule that tells the apps' roles from the server's by current_user lets
-- the back office through with public.caller_admin_can_write('<its table>'),
-- the test the table's admin policies make.
do $$
declare
  bad text;
begin
  select string_agg(distinct format('%s (on %s)', p.proname, t.tgrelid::regclass), ', ')
    into bad
    from pg_trigger t
    join pg_proc p on p.oid = t.tgfoid
   where not t.tgisinternal
     and t.tgrelid in ('public.partners'::regclass, 'public.profiles'::regclass, 'public.vehicle'::regclass,
                       'public.provider_documents'::regclass, 'public.vehicle_documents'::regclass)
     and not p.prosecdef
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~ 'current_user'
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~ 'caller_is_admin\(\)';
  if bad is not null then
    raise exception 'FAILED: guards that ask caller_is_admin(), not about their table: %', bad;
  end if;
end $$;

rollback;

select 'people_guards_page_scope_0432: all passed';
