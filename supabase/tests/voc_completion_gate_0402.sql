-- ============================================================================
-- Regression test for migration 0402: the VOC completion gate.
--   * vehicle_voc_state: missing -> present (uploaded) -> approved (verified).
--   * Submit (partners_registration_rules): a vehicle with no VOC uploaded is
--     refused (VOC_REQUIRED); with the VOC uploaded it submits.
--   * Approve (partner_review_approve): an uploaded-but-unverified VOC refuses
--     (PARTNER_RULES_NOT_MET, voc); a reason overrides it (recorded, vehicle
--     approved); a verified VOC approves cleanly.
--   * Legacy-exempt: a vehicle already approved (no VOC) is not re-gated.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/voc_completion_gate_0402.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000402a1'),  -- admin, EDIT on Partners
  ('00000000-0000-0000-0000-0000000402b1'),  -- driver: the VOC gate
  ('00000000-0000-0000-0000-0000000402b2'),  -- driver: the override path
  ('00000000-0000-0000-0000-0000000402b3')   -- driver: legacy-approved vehicle
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000402%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000402a1', 'admin-partners', 'edit')
on conflict do nothing;

-- A VOC document type (as 0388). A plain vehicle type with no other rules, so
-- only the VOC gate can block.
insert into public.required_document (id, values, active) values
  ('00000000-0000-0000-0000-0000000402d1',
   '{"name":"Test0402 VOC","readAs":"voc","active":true,"required":true}', true)
on conflict (id) do nothing;
insert into public.settings_entries (id, category, values, position, active) values
  ('00000000-0000-0000-0000-0000000402e1', 'partner-type',
   '{"name":"Test0402 Car","vehicleRequired":true}', 0, true)
on conflict (id) do nothing;

insert into public.partners (id, auth_user_id, name, phone, status, partner_types,
                             service_countries, service_states, service_cities) values
  ('00000000-0000-0000-0000-0000000402f1', '00000000-0000-0000-0000-0000000402b1', 'Test Driver VOC', '+60100004021',
   'unapproved', '{Test0402 Car}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}'),
  ('00000000-0000-0000-0000-0000000402f2', '00000000-0000-0000-0000-0000000402b2', 'Test Driver Override', '+60100004022',
   'unapproved', '{Test0402 Car}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}'),
  ('00000000-0000-0000-0000-0000000402f3', '00000000-0000-0000-0000-0000000402b3', 'Test Driver Legacy', '+60100004023',
   'unapproved', '{Test0402 Car}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}')
on conflict (id) do nothing;
insert into public.vehicle (id, plate, auth_user_id, owner_partner_id, status, year) values
  ('00000000-0000-0000-0000-0000000402c1', 'VOC 4021', '00000000-0000-0000-0000-0000000402b1',
   '00000000-0000-0000-0000-0000000402f1', 'unapproved', '2022'),
  ('00000000-0000-0000-0000-0000000402c2', 'VOC 4022', '00000000-0000-0000-0000-0000000402b2',
   '00000000-0000-0000-0000-0000000402f2', 'unapproved', '2022'),
  -- Legacy: already approved, no VOC on file.
  ('00000000-0000-0000-0000-0000000402c3', 'VOC 4023', '00000000-0000-0000-0000-0000000402b3',
   '00000000-0000-0000-0000-0000000402f3', 'approved', '2018')
on conflict (id) do nothing;
update public.partners set registration_vehicle_id = '00000000-0000-0000-0000-0000000402c1'
 where id = '00000000-0000-0000-0000-0000000402f1';
update public.partners set registration_vehicle_id = '00000000-0000-0000-0000-0000000402c2'
 where id = '00000000-0000-0000-0000-0000000402f2';
update public.partners set registration_vehicle_id = '00000000-0000-0000-0000-0000000402c3'
 where id = '00000000-0000-0000-0000-0000000402f3';
-- A passed review line, so the approve path's rejected-lines check is clear.
insert into public.partner_review_items (partner_id, item_key, item_group, label, state) values
  ('00000000-0000-0000-0000-0000000402f1', 'details.name', 'details', 'Full name', 'approved'),
  ('00000000-0000-0000-0000-0000000402f2', 'details.name', 'details', 'Full name', 'approved'),
  ('00000000-0000-0000-0000-0000000402f3', 'details.name', 'details', 'Full name', 'approved')
on conflict do nothing;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
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
create or replace function pg_temp.error_of(p_sql text) returns text language plpgsql as $$
declare h text;
begin execute p_sql; return 'ok';
exception when others then
  get stacked diagnostics h = pg_exception_hint;
  return sqlerrm || ': ' || coalesce(h, '');
end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.as_db(),
  pg_temp.error_of(text) to authenticated;

-- A voc doc for a vehicle at a given status.
create or replace function pg_temp.add_voc(p_vehicle uuid, p_status text) returns void language plpgsql as $$
begin
  insert into public.vehicle_documents (vehicle_id, doc_id, doc_name, file_url, status)
  values (p_vehicle, '00000000-0000-0000-0000-0000000402d1', 'Test0402 VOC',
          'https://x.test/voc-' || right(p_vehicle::text, 4) || '.jpg', p_status);
end $$;

-- 1. vehicle_voc_state tracks the certificate ------------------------------------------------------
select pg_temp.check(public.vehicle_voc_state('00000000-0000-0000-0000-0000000402c1') = 'missing',
  'no certificate uploaded: missing');
select pg_temp.add_voc('00000000-0000-0000-0000-0000000402c1', 'Pending Review');
select pg_temp.check(public.vehicle_voc_state('00000000-0000-0000-0000-0000000402c1') = 'present',
  'uploaded but not verified: present');

-- 2. Submit: refused without the VOC, allowed once it is uploaded ----------------------------------
-- A fresh vehicle (c2) with no VOC can't be submitted by its driver.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000402b2');
select pg_temp.check(pg_temp.error_of($q$update public.partners set documents_ok = true
                                        where id = '00000000-0000-0000-0000-0000000402f2'$q$)
                       like 'VOC_REQUIRED:%ownership certificate%',
  'submit refused while the VOC is missing');
reset role;
-- Driver f1's vehicle has the VOC uploaded (step 1), so it submits.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000402b1');
update public.partners set documents_ok = true where id = '00000000-0000-0000-0000-0000000402f1';
select pg_temp.check((select documents_ok from public.partners where id = '00000000-0000-0000-0000-0000000402f1'),
  'with the VOC uploaded, the application submits');
reset role;

-- 3. Approve: an unverified VOC refuses; verifying it lets the approval through --------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000402a1');
select pg_temp.check(pg_temp.error_of($q$select public.partner_review_approve('00000000-0000-0000-0000-0000000402f1')$q$)
                       like 'PARTNER_RULES_NOT_MET:%Vehicle Ownership Certificate missing%',
  'approval refused while the VOC is not verified');
select pg_temp.check((select status::text = 'unapproved' from public.vehicle where id = '00000000-0000-0000-0000-0000000402c1'),
  'the vehicle stays unapproved');
reset role;
-- Verify the VOC.
select pg_temp.as_db();
update public.vehicle_documents set status = 'Approved'
 where vehicle_id = '00000000-0000-0000-0000-0000000402c1' and doc_id = '00000000-0000-0000-0000-0000000402d1';
select pg_temp.check(public.vehicle_voc_state('00000000-0000-0000-0000-0000000402c1') = 'approved',
  'verified: approved');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000402a1');
select public.partner_review_approve('00000000-0000-0000-0000-0000000402f1');
select pg_temp.check((select status::text = 'approved' from public.vehicle where id = '00000000-0000-0000-0000-0000000402c1'),
  'with the VOC verified, the vehicle is approved');
reset role;

-- 4. Override: an admin may force approval past an unverified VOC, recorded ------------------------
select pg_temp.as_db();
update public.partners set documents_ok = true where id = '00000000-0000-0000-0000-0000000402f2';
select pg_temp.add_voc('00000000-0000-0000-0000-0000000402c2', 'Pending Review');  -- present, not verified
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000402a1');
select pg_temp.check(pg_temp.error_of($q$select public.partner_review_approve('00000000-0000-0000-0000-0000000402f2')$q$)
                       like 'PARTNER_RULES_NOT_MET:%',
  'still refused without a reason');
select public.partner_review_approve('00000000-0000-0000-0000-0000000402f2', 'VOC sighted at the counter, ticket 4022 (made up).');
select pg_temp.check((select status::text = 'approved' from public.vehicle where id = '00000000-0000-0000-0000-0000000402c2'),
  'a reason forces the vehicle through');
reset role;
select pg_temp.check((select count(*) = 1 from public.partner_rule_overrides o
                       where o.partner_id = '00000000-0000-0000-0000-0000000402f2'
                         and o.rules @> '[{"rule":"voc"}]'::jsonb),
  'the VOC override is recorded with the failed rule');

-- 5. Legacy-exempt: an already-approved vehicle is not re-gated ------------------------------------
-- f3's vehicle (c3) is already 'approved' with no VOC. Approving the partner
-- does not raise the VOC gate (the vehicle is not transitioning), and the badge
-- still flags it (voc state missing) for the approver to chase.
select pg_temp.check(public.vehicle_voc_state('00000000-0000-0000-0000-0000000402c3') = 'missing',
  'a legacy vehicle with no VOC still reads missing (the soft badge)');
select pg_temp.as_db();
update public.partners set documents_ok = true where id = '00000000-0000-0000-0000-0000000402f3';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000402a1');
select pg_temp.check(pg_temp.error_of($q$select public.partner_review_approve('00000000-0000-0000-0000-0000000402f3')$q$) = 'ok',
  'approving a partner whose vehicle is already approved is not blocked by the VOC gate');
select pg_temp.check((select status::text = 'approved' from public.partners where id = '00000000-0000-0000-0000-0000000402f3'),
  'the legacy partner is approved');
reset role;

rollback;
