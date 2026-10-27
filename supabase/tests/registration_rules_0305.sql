-- ============================================================================
-- Regression test for migration 0305: the partner registration rules
-- checked by the server.
--   * Citizens only, Business registration and Driver permit refuse the
--     partner's Submit with their own code (CITIZENS_ONLY,
--     BUSINESS_REGISTRATION_REQUIRED, DRIVER_PERMIT_REQUIRED), and a change
--     of types of a submitted application;
--   * an expired driver permit, or one without an expiry date, counts as
--     missing; the old rules.permit (0245) still refuses without a permit;
--   * an admin's own edits are not held;
--   * approval is refused (PARTNER_RULES_NOT_MET) unless the admin gives a
--     reason, which is recorded (partner_rule_overrides, admin_audit_log);
--   * vehicle permits and age limits are reported, never refused;
--   * who may read the checks, the overrides and the "would fail now" list.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/registration_rules_0305.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000305a1'),  -- admin, EDIT on Partners
  ('00000000-0000-0000-0000-0000000305a2'),  -- admin, EDIT on Partner Service type
  ('00000000-0000-0000-0000-0000000305a3'),  -- admin, READ on Partners
  ('00000000-0000-0000-0000-0000000305b1'),  -- driver: citizens-only type
  ('00000000-0000-0000-0000-0000000305b2'),  -- driver: business registration
  ('00000000-0000-0000-0000-0000000305b3'),  -- driver: driver permit
  ('00000000-0000-0000-0000-0000000305b4'),  -- driver: old rules.permit
  ('00000000-0000-0000-0000-0000000305b5'),  -- driver: approved past the rules
  ('00000000-0000-0000-0000-0000000305b6')   -- driver: nothing missing
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000305%'
on conflict do nothing;
update public.profiles set id_type = 'passport', nationality = 'Indonesian', ic = 'P0305771'
 where id = '00000000-0000-0000-0000-0000000305b1';
update public.profiles set id_type = 'passport', nationality = 'Indonesian', ic = 'P0305772'
 where id = '00000000-0000-0000-0000-0000000305b2';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000305a1', 'admin-partners', 'edit'),
  ('00000000-0000-0000-0000-0000000305a2', 'admin-settings-partner-type', 'edit'),
  ('00000000-0000-0000-0000-0000000305a3', 'admin-partners', 'read')
on conflict do nothing;

-- The types, with their Partner registration settings.
insert into public.settings_entries (id, category, values, position, active) values
  ('00000000-0000-0000-0000-0000000305e1', 'partner-type',
   '{"name":"Test0305 Hail","vehicleRequired":false,
     "citizensOnly":{"required":true,"all":false,"regions":[{"country":"Malaysia"}]}}', 0, true),
  ('00000000-0000-0000-0000-0000000305e2', 'partner-type',
   '{"name":"Test0305 Dealer","vehicleRequired":false,
     "businessRegistration":{"required":true,"all":true,"regions":[]}}', 0, true),
  ('00000000-0000-0000-0000-0000000305e3', 'partner-type',
   '{"name":"Test0305 Taxi","vehicleRequired":true,
     "driverPermit":{"required":true,"rules":[{"country":"Malaysia","name":"Kad Pemandu","issuer":"APAD"}]}}', 0, true),
  ('00000000-0000-0000-0000-0000000305e4', 'partner-type',
   '{"name":"Test0305 Old","vehicleRequired":true,"rules":{"permit":{"required":true,"all":true}}}', 0, true);
insert into public.required_document (id, values, active) values
  ('00000000-0000-0000-0000-0000000305d1', '{"name":"Test0305 Permit","isTaxiPermit":true,"active":true}', true);

insert into public.partners (id, auth_user_id, name, phone, status, partner_types,
                             service_countries, service_states, service_cities) values
  ('00000000-0000-0000-0000-0000000305f1', '00000000-0000-0000-0000-0000000305b1', 'Test Driver Alpha', '+60100003051',
   'unapproved', '{Test0305 Hail}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}'),
  ('00000000-0000-0000-0000-0000000305f2', '00000000-0000-0000-0000-0000000305b2', 'Test Driver Bravo', '+60100003052',
   'unapproved', '{Test0305 Dealer}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}'),
  ('00000000-0000-0000-0000-0000000305f3', '00000000-0000-0000-0000-0000000305b3', 'Test Driver Charlie', '+60100003053',
   'unapproved', '{Test0305 Taxi}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}'),
  ('00000000-0000-0000-0000-0000000305f4', '00000000-0000-0000-0000-0000000305b4', 'Test Driver Delta', '+60100003054',
   'unapproved', '{Test0305 Old}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}'),
  ('00000000-0000-0000-0000-0000000305f5', '00000000-0000-0000-0000-0000000305b5', 'Test Driver Echo', '+60100003055',
   'unapproved', '{Test0305 Dealer}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}'),
  ('00000000-0000-0000-0000-0000000305f6', '00000000-0000-0000-0000-0000000305b6', 'Test Driver Foxtrot', '+60100003056',
   'unapproved', '{Test0305 Dealer}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}');

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
create or replace function pg_temp.as_db() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
-- The error code and hint a statement raises, or 'ok'.
create or replace function pg_temp.error_of(p_sql text) returns text language plpgsql as $$
declare h text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics h = pg_exception_hint;
  return sqlerrm || ': ' || coalesce(h, '');
end $$;
-- The JSON detail a statement raises with, or null.
create or replace function pg_temp.detail_of(p_sql text) returns jsonb language plpgsql as $$
declare d text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics d = pg_exception_detail;
  return nullif(d, '')::jsonb;
end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.as_db(),
  pg_temp.error_of(text), pg_temp.detail_of(text) to authenticated;

-- 1. Citizens only ------------------------------------------------------------------------------------
select pg_temp.check(public.reg_citizen_of('mykad', '', 'Malaysia'), 'a MyKad is a Malaysian citizen ID');
select pg_temp.check(public.reg_citizen_of('mykad', 'Warganegara', 'Malaysia'), 'Warganegara is a citizen');
select pg_temp.check(not public.reg_citizen_of('mypr', 'Malaysian', 'Malaysia'), 'a MyPR is not a citizen ID');
select pg_temp.check(not public.reg_citizen_of('passport', 'Indonesian', 'Malaysia'), 'an Indonesian passport is not');
select pg_temp.check(public.reg_citizen_of('passport', 'Malaysian', 'Malaysia'), 'a Malaysian passport is');
select pg_temp.check(public.reg_citizen_of('passport', 'Singaporean', 'Singapore'), 'a Singaporean passport, in Singapore');
select pg_temp.check(not public.reg_citizen_of('mykad', 'Malaysian', 'Singapore'), 'a MyKad is not Singapore''s');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000305b1');
select pg_temp.check(pg_temp.error_of($q$update public.partners set documents_ok = true
                                        where id = '00000000-0000-0000-0000-0000000305f1'$q$)
                       like 'CITIZENS_ONLY: Test0305 Hail in Malaysia is for citizens only. Your ID is a passport.%',
  'a passport holder submitting a citizens-only type is refused');
select pg_temp.check((select (d -> 0 ->> 'rule') = 'citizens_only' and (d -> 0 ->> 'place') = 'Malaysia'
                             and (d -> 0 ->> 'id_type') = 'passport'
                        from pg_temp.detail_of($q$update public.partners set documents_ok = true
                                                 where id = '00000000-0000-0000-0000-0000000305f1'$q$) d),
  'the refusal carries the problems as JSON');
select pg_temp.check((select (c -> 0 ->> 'status') = 'failed'
                        from public.partner_registration_problems('00000000-0000-0000-0000-0000000305f1') c),
  'the partner reads their own problems');
reset role;
select pg_temp.as_db();
update public.profiles set id_type = 'mykad', nationality = 'Malaysian', ic = '900101-14-0305'
 where id = '00000000-0000-0000-0000-0000000305b1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000305b1');
update public.partners set documents_ok = true where id = '00000000-0000-0000-0000-0000000305f1';
select pg_temp.check((select documents_ok from public.partners where id = '00000000-0000-0000-0000-0000000305f1'),
  'with a MyKad, it is submitted');
select pg_temp.check(pg_temp.error_of($q$select public.partner_registration_checks('00000000-0000-0000-0000-0000000305f2')$q$)
                       <> 'ok',
  'a driver can''t read another partner''s checks');
reset role;

-- 2. Business registration ----------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000305b2');
select pg_temp.check(pg_temp.error_of($q$update public.partners set documents_ok = true
                                        where id = '00000000-0000-0000-0000-0000000305f2'$q$)
                       like 'BUSINESS_REGISTRATION_REQUIRED: Test0305 Dealer in Malaysia needs a company number%',
  'no company: refused');
reset role;
select pg_temp.as_db();
update public.partners set company_reg_no = '202601030501' where id = '00000000-0000-0000-0000-0000000305f2';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000305b2');
select pg_temp.check((select d -> 0 -> 'missing' = '["registration document"]'
                        from pg_temp.detail_of($q$update public.partners set documents_ok = true
                                                 where id = '00000000-0000-0000-0000-0000000305f2'$q$) d),
  'a number without the document: still refused, the document missing');
reset role;
select pg_temp.as_db();
update public.partners set company_document_url = 'https://x.test/ssm-0305.pdf'
 where id = '00000000-0000-0000-0000-0000000305f2';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000305b2');
update public.partners set documents_ok = true where id = '00000000-0000-0000-0000-0000000305f2';
select pg_temp.check((select documents_ok from public.partners where id = '00000000-0000-0000-0000-0000000305f2'),
  'with number and document, it is submitted');
-- Submitted, adding a citizens-only type with a passport: refused.
select pg_temp.check(pg_temp.error_of($q$update public.partners set partner_types = '{Test0305 Dealer,Test0305 Hail}'
                                        where id = '00000000-0000-0000-0000-0000000305f2'$q$) like 'CITIZENS_ONLY:%',
  'a submitted application can''t take a type it fails');
reset role;

-- 3. Driver permit ------------------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000305b3');
select pg_temp.check(pg_temp.error_of($q$update public.partners set documents_ok = true
                                        where id = '00000000-0000-0000-0000-0000000305f3'$q$)
                       like 'DRIVER_PERMIT_REQUIRED: Test0305 Taxi in Malaysia needs a Kad Pemandu.%',
  'no permit: refused');
reset role;
select pg_temp.as_db();
update public.partners
   set driver_permit_card_no = 'KP0305', driver_permit_front_url = 'https://x.test/kp-0305.jpg',
       driver_permit_valid_until = current_date - 10
 where id = '00000000-0000-0000-0000-0000000305f3';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000305b3');
select pg_temp.check(pg_temp.error_of($q$update public.partners set documents_ok = true
                                        where id = '00000000-0000-0000-0000-0000000305f3'$q$)
                       like 'DRIVER_PERMIT_REQUIRED: Your Kad Pemandu expired on %',
  'an expired permit counts as missing');
reset role;
select pg_temp.as_db();
update public.partners set driver_permit_valid_until = null where id = '00000000-0000-0000-0000-0000000305f3';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000305b3');
select pg_temp.check(pg_temp.error_of($q$update public.partners set documents_ok = true
                                        where id = '00000000-0000-0000-0000-0000000305f3'$q$)
                       like 'DRIVER_PERMIT_REQUIRED: Type the expiry date of your Kad Pemandu%',
  'a permit without its expiry date: refused');
reset role;
select pg_temp.as_db();
update public.partners set driver_permit_valid_until = current_date + 200 where id = '00000000-0000-0000-0000-0000000305f3';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000305b3');
update public.partners set documents_ok = true where id = '00000000-0000-0000-0000-0000000305f3';
select pg_temp.check((select documents_ok from public.partners where id = '00000000-0000-0000-0000-0000000305f3'),
  'with the permit in date, it is submitted');
reset role;

-- The old rules.permit (0245) still holds, under the new code.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000305b4');
select pg_temp.check(pg_temp.error_of($q$update public.partners set documents_ok = true
                                        where id = '00000000-0000-0000-0000-0000000305f4'$q$)
                       like 'DRIVER_PERMIT_REQUIRED: A permit is required for Test0305 Old. Upload it before submitting.',
  'the old permit rule refuses without a permit');
insert into public.provider_documents (partner_id, auth_user_id, doc_id, doc_name, file_url, status)
values ('00000000-0000-0000-0000-0000000305f4', '00000000-0000-0000-0000-0000000305b4',
        '00000000-0000-0000-0000-0000000305d1', 'Test0305 Permit', 'https://x.test/permit-0305.jpg', 'Pending Review');
update public.partners set documents_ok = true where id = '00000000-0000-0000-0000-0000000305f4';
select pg_temp.check((select documents_ok from public.partners where id = '00000000-0000-0000-0000-0000000305f4'),
  'with the permit document, it is submitted');
reset role;

-- 4. Vehicle permit and age: reported, never refused ----------------------------------------------------
select pg_temp.as_db();
insert into public.vehicle (id, plate, auth_user_id, owner_partner_id, status, year) values
  ('00000000-0000-0000-0000-0000000305c3', 'TST 3053', '00000000-0000-0000-0000-0000000305b3',
   '00000000-0000-0000-0000-0000000305f3', 'unapproved', '2010');
update public.partners set registration_vehicle_id = '00000000-0000-0000-0000-0000000305c3'
 where id = '00000000-0000-0000-0000-0000000305f3';
delete from public.vehicle_service_status where vehicle_id = '00000000-0000-0000-0000-0000000305c3';
insert into public.vehicle_service_status (vehicle_id, service, status, max_age_years, limit_type, permit_name) values
  ('00000000-0000-0000-0000-0000000305c3', 'Test0305 Taxi', 'waiting_permit', 20, 'Test0305 Taxi', 'Test EVP');
select pg_temp.check((select bool_or(c ->> 'rule' = 'vehicle_permit' and c ->> 'status' = 'paused')
                             and bool_or(c ->> 'rule' = 'vehicle_age' and c ->> 'status' = 'passed')
                        from jsonb_array_elements(public.partner_registration_checks('00000000-0000-0000-0000-0000000305f3')) c),
  'the vehicle''s permit wait and age limit are reported');
select pg_temp.check(jsonb_array_length(public.partner_registration_problems('00000000-0000-0000-0000-0000000305f3')) = 0,
  'a paused service is not a problem');

-- 5. Admins' own edits are free ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000305a1');
update public.partners set documents_ok = true where id = '00000000-0000-0000-0000-0000000305f5';
select pg_temp.check((select documents_ok from public.partners where id = '00000000-0000-0000-0000-0000000305f5'),
  'an admin submits for the partner without the company');
reset role;

-- 6. Approval -----------------------------------------------------------------------------------------------
select pg_temp.as_db();
insert into public.partner_review_items (partner_id, item_key, item_group, label, state) values
  ('00000000-0000-0000-0000-0000000305f5', 'details.name', 'details', 'Full name', 'approved'),
  ('00000000-0000-0000-0000-0000000305f6', 'details.name', 'details', 'Full name', 'approved');
update public.partners set documents_ok = true, company_reg_no = '202601030506',
                           company_document_url = 'https://x.test/ssm-0306.pdf'
 where id = '00000000-0000-0000-0000-0000000305f6';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000305a1');
select pg_temp.check(pg_temp.error_of($q$select public.partner_review_approve('00000000-0000-0000-0000-0000000305f5')$q$)
                       like 'PARTNER_RULES_NOT_MET: Can''t approve: Business registration missing (Test0305 Dealer needs it in Malaysia).%',
  'approval is refused while a rule fails');
select pg_temp.check(pg_temp.error_of($q$select public.partner_review_approve('00000000-0000-0000-0000-0000000305f5', '  ')$q$)
                       like 'PARTNER_RULES_NOT_MET:%',
  'an empty reason is no override');
select pg_temp.check((select status::text = 'unapproved' from public.partners where id = '00000000-0000-0000-0000-0000000305f5'),
  'still waiting for review');
select public.partner_review_approve('00000000-0000-0000-0000-0000000305f5',
                                     'SSM certificate received by email, ticket 4821 (made up).');
select pg_temp.check((select status::text = 'approved' from public.partners where id = '00000000-0000-0000-0000-0000000305f5'),
  'approved with a reason');
select pg_temp.check((select count(*) = 1 from public.partner_rule_overrides o
                       where o.partner_id = '00000000-0000-0000-0000-0000000305f5'
                         and o.admin_id = '00000000-0000-0000-0000-0000000305a1'
                         and o.reason like 'SSM certificate received%'
                         and o.rules -> 0 ->> 'rule' = 'business_registration'),
  'the override is recorded with the admin, the reason and the failed rules');
select pg_temp.check(exists (select 1 from public.admin_audit_log
                              where action = 'partner.review_approve'
                                and detail ->> 'partner_id' = '00000000-0000-0000-0000-0000000305f5'
                                and detail ? 'override_reason'),
  'and in the audit log');
-- The old one-argument call still approves a partner passing every rule.
select public.partner_review_approve('00000000-0000-0000-0000-0000000305f6');
select pg_temp.check((select status::text = 'approved' from public.partners where id = '00000000-0000-0000-0000-0000000305f6'),
  'the one-argument approval still works');
select pg_temp.check(not exists (select 1 from public.partner_rule_overrides
                                  where partner_id = '00000000-0000-0000-0000-0000000305f6'),
  'no override when nothing failed');
reset role;

-- 7. Who reads what -------------------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000305b5');
select pg_temp.check((select count(*) = 0 from public.partner_rule_overrides),
  'a driver doesn''t read the overrides');
select pg_temp.check(pg_temp.error_of($q$select * from public.admin_partner_rule_failures('Test0305 Dealer')$q$) <> 'ok',
  'a driver can''t list who would fail');
select pg_temp.as_user('00000000-0000-0000-0000-0000000305a3');
select pg_temp.check((select count(*) = 1 from public.partner_rule_overrides
                       where partner_id = '00000000-0000-0000-0000-0000000305f5'),
  'an admin reads the overrides');
select pg_temp.check(pg_temp.error_of($q$select * from public.admin_partner_rule_failures('Test0305 Dealer')$q$) <> 'ok',
  'an admin with READ only can''t list who would fail');
select pg_temp.check(pg_temp.error_of($q$select public.partner_review_approve('00000000-0000-0000-0000-0000000305f2', 'x')$q$)
                       <> 'ok',
  'an admin with READ only can''t approve');
select pg_temp.as_user('00000000-0000-0000-0000-0000000305a2');
select pg_temp.check((select count(*) = 1 and bool_and(f.partner_id = '00000000-0000-0000-0000-0000000305f5'
                                                       and f.status = 'approved'
                                                       and f.problems -> 0 ->> 'rule' = 'business_registration')
                        from public.admin_partner_rule_failures('Test0305 Dealer') f),
  'the Partner Service type admin sees the one Dealer that would fail now');
select pg_temp.check((select count(*) = 0 from public.admin_partner_rule_failures('Test0305 Hail')),
  'nobody fails the citizens-only type now');
reset role;

rollback;
