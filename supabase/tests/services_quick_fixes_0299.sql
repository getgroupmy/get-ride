-- ============================================================================
-- Regression test for migration 0299: services quick fixes.
--   * no vehicle its driver owns is left without the owner's ID and phone
--     where the driver's are known (H1);
--   * an approved vehicle permit turns on the services waiting for it, by
--     the permit type's key as the app stores it (M5);
--   * a service none of the driver's partner types allows is off for them
--     (H2), and a bid on one says why;
--   * an approved partner can't change their own types; admins and the
--     server can (M7);
--   * the admin's "Same ID as another account" read (M8).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/services_quick_fixes_0299.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up people only.
-- ============================================================================
begin;

-- Permits are 0254's test, the service order 0250's: nobody is held up by them.
update public.permit_country_settings set enforce = false;
update public.service_order_settings set enforce_all = false;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000299a1'),  -- admin, EDIT on Partners
  ('00000000-0000-0000-0000-0000000299b1'),  -- driver: delivery-only type, approved
  ('00000000-0000-0000-0000-0000000299b2'),  -- driver: no type, approved
  ('00000000-0000-0000-0000-0000000299b3'),  -- driver: delivery-only type, still applying
  ('00000000-0000-0000-0000-0000000299c1'),  -- rider
  ('00000000-0000-0000-0000-0000000299c2'),  -- account with the same ID number as driver 1
  ('00000000-0000-0000-0000-0000000299c3')   -- deleted account with the same ID number
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000299%'
on conflict do nothing;
update public.profiles set ic = '900101-14-0299', display_id = 'T0299B1' where id = '00000000-0000-0000-0000-0000000299b1';
update public.profiles set ic = '900101140299', display_id = 'T0299C2' where id = '00000000-0000-0000-0000-0000000299c2';
update public.profiles set ic = '900101 14 0299', display_id = 'T0299C3', deleted_at = now()
 where id = '00000000-0000-0000-0000-0000000299c3';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000299a1', 'admin-partners', 'edit')
on conflict do nothing;

insert into public.partner_type_services (type_key, type_name, all_services, services) values
  ('test0299delivery', 'Test0299 Delivery', false, array['Delivery 0299'])
on conflict (type_key) do update set all_services = excluded.all_services, services = excluded.services;

insert into public.partners (id, auth_user_id, name, phone, status, partner_types) values
  ('00000000-0000-0000-0000-0000000299e1', '00000000-0000-0000-0000-0000000299b1', 'Test Driver One', '+60100002991',
   'approved', '{Test0299 Delivery}'),
  ('00000000-0000-0000-0000-0000000299e2', '00000000-0000-0000-0000-0000000299b2', 'Test Driver Two', '+60100002992',
   'approved', '{}'),
  ('00000000-0000-0000-0000-0000000299e3', '00000000-0000-0000-0000-0000000299b3', 'Test Driver Three', '+60100002993',
   'unapproved', '{Test0299 Delivery}');

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
-- The error and hint a statement raises, or 'ok'.
create or replace function pg_temp.error_of(p_sql text) returns text language plpgsql as $$
declare h text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics h = pg_exception_hint;
  return sqlerrm || ': ' || coalesce(h, '');
end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.error_of(text)
  to authenticated;

-- 1. H1: the owner's details ------------------------------------------------------------------------
select pg_temp.check(not exists (
  select 1 from public.vehicle v
    join public.partners p on p.id = v.owner_partner_id
    left join public.profiles pr on pr.id = p.auth_user_id
   where v.owner_match = 'driver'
     and coalesce(btrim(v.owner_ic), '') = ''
     and coalesce(nullif(btrim(pr.ic), ''), nullif(btrim(p.ic), '')) is not null),
  'no vehicle its driver owns is left without the driver''s ID');

-- 2. M5: an approved permit, by its key ---------------------------------------------------------------
insert into public.permit_types (id, country, key, name, applies_to, uploader) values
  ('00000000-0000-0000-0000-0000000299f9', 'Testland 0299', 'tst-evp', 'Test EVP', 'vehicle', 'admin');
insert into public.vehicle (id, auth_user_id, owner_partner_id, plate, make, model, color, status) values
  ('00000000-0000-0000-0000-0000000299f1', '00000000-0000-0000-0000-0000000299b1', '00000000-0000-0000-0000-0000000299e1',
   'TST 2991', 'Testmake', 'Alpha', 'White', 'approved');
insert into public.vehicle_service_status (vehicle_id, service, status, permit_name, permit_type) values
  ('00000000-0000-0000-0000-0000000299f1', 'eHailing', 'waiting_permit', 'Test EVP', 'tst-evp'),
  ('00000000-0000-0000-0000-0000000299f1', 'Teksi', 'waiting_permit', 'Other permit', 'tst-other');
insert into public.vehicle_documents (vehicle_id, doc_id, doc_name, status, permit_type_id, expiry_date) values
  ('00000000-0000-0000-0000-0000000299f1', 'permit', 'Test EVP', 'Pending Review',
   '00000000-0000-0000-0000-0000000299f9', current_date + 300);
select pg_temp.check((select status = 'waiting_permit' from public.vehicle_service_status
                       where vehicle_id = '00000000-0000-0000-0000-0000000299f1' and service = 'eHailing'),
  'a permit in review turns nothing on');
update public.vehicle_documents set status = 'Approved'
 where vehicle_id = '00000000-0000-0000-0000-0000000299f1' and permit_type_id = '00000000-0000-0000-0000-0000000299f9';
select pg_temp.check((select status = 'active' from public.vehicle_service_status
                       where vehicle_id = '00000000-0000-0000-0000-0000000299f1' and service = 'eHailing'),
  'the approved permit turns its service on (stored by key)');
select pg_temp.check((select status = 'waiting_permit' from public.vehicle_service_status
                       where vehicle_id = '00000000-0000-0000-0000-0000000299f1' and service = 'Teksi'),
  'a service waiting for another permit still waits');

-- 3. H2: the partner type's services --------------------------------------------------------------------
select pg_temp.check(not public.driver_service_effective('00000000-0000-0000-0000-0000000299b1', null, 'Ride 0299'),
  'a delivery-only type: a ride service is off');
select pg_temp.check(not public.driver_takes_service('00000000-0000-0000-0000-0000000299b1', 'Ride 0299'),
  'a delivery-only type doesn''t take a ride');
select pg_temp.check(public.driver_service_effective('00000000-0000-0000-0000-0000000299b1', null, 'Delivery 0299')
                     and public.driver_takes_service('00000000-0000-0000-0000-0000000299b1', 'delivery-0299'),
  'its own service is still on (name or key)');
select pg_temp.check(public.driver_service_effective('00000000-0000-0000-0000-0000000299b1', null, 'hail:meter'),
  'street hail is not a partner type service');
select pg_temp.check(public.driver_takes_service('00000000-0000-0000-0000-0000000299b2', 'Ride 0299'),
  'no type: every service');
select pg_temp.check(public.driver_takes_service('00000000-0000-0000-0000-0000000299b1', ''), 'no service: taken');

insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng, drop_lat, drop_lng)
values ('00000000-0000-0000-0000-000000029901', '00000000-0000-0000-0000-0000000299c1', 'open', 'Ride 0299', 20, 20,
        3.1, 101.6, 3.2, 101.7);

-- A bid, were the request read (the read rules set aside in this
-- transaction only), is refused with the reason.
drop policy if exists "ride_requests partner type services" on public.ride_requests;
drop policy if exists "ride_requests driver services" on public.ride_requests;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000299b1');
select pg_temp.check(pg_temp.error_of($q$update public.ride_requests
    set partner_id = '00000000-0000-0000-0000-0000000299b1', offered_fare = 22
  where id = '00000000-0000-0000-0000-000000029901'$q$)
  = 'DRIVER_SERVICE_OFF: Your Partner Service types don''t take Ride 0299 requests.', 'a bid outside the types is refused');
reset role;

-- 4. M7: an approved partner's types ------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000299b1');
select pg_temp.check(pg_temp.error_of($q$update public.partners set partner_types = '{Test0299 Delivery,eHailing}'
  where id = '00000000-0000-0000-0000-0000000299e1'$q$) like 'PARTNER_TYPES_LOCKED:%', 'an approved partner adding a type');
select pg_temp.check(pg_temp.error_of($q$update public.partners set partner_type = 'eHailing', partner_types = '{}'
  where id = '00000000-0000-0000-0000-0000000299e1'$q$) like 'PARTNER_TYPES_LOCKED:%', 'or swapping it through partner_type');
select pg_temp.check(pg_temp.error_of($q$update public.partners set partner_types = '{test0299-delivery}'
  where id = '00000000-0000-0000-0000-0000000299e1'$q$) = 'ok', 'the same type saved again is no change');
select pg_temp.as_user('00000000-0000-0000-0000-0000000299b3');
select pg_temp.check(pg_temp.error_of($q$update public.partners set partner_types = '{eHailing}'
  where id = '00000000-0000-0000-0000-0000000299e3'$q$) = 'ok', 'an applicant still picks their types');
select pg_temp.as_user('00000000-0000-0000-0000-0000000299a1');
select pg_temp.check(pg_temp.error_of($q$update public.partners set partner_types = '{Test0299 Delivery,eHailing}'
  where id = '00000000-0000-0000-0000-0000000299e1'$q$) = 'ok', 'an admin changes them');
reset role;
select pg_temp.check((select partner_types = array['Test0299 Delivery', 'eHailing'] from public.partners
                       where id = '00000000-0000-0000-0000-0000000299e1'), 'the admin''s change is kept');
select set_config('request.jwt.claims', '', true);
update public.partners set partner_types = '{Test0299 Delivery}' where id = '00000000-0000-0000-0000-0000000299e1';
select pg_temp.check((select partner_types = array['Test0299 Delivery'] from public.partners
                       where id = '00000000-0000-0000-0000-0000000299e1'), 'the server changes them');

-- 5. M8: the same ID number on another account --------------------------------------------------------
select pg_temp.check(not has_function_privilege('anon', 'public.admin_same_ic_accounts(uuid)', 'execute'),
  'not for anon');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000299b1');
select pg_temp.check(pg_temp.error_of($q$select * from public.admin_same_ic_accounts('00000000-0000-0000-0000-0000000299b1')$q$)
                     like 'not_authorized%', 'a driver can''t ask');
select pg_temp.as_user('00000000-0000-0000-0000-0000000299a1');
select pg_temp.check((select array_agg(display_id) = array['T0299C2']
                        from public.admin_same_ic_accounts('00000000-0000-0000-0000-0000000299b1')),
  'the other live account with the same number, not the deleted one or itself');
select pg_temp.check(not exists (select 1 from public.admin_same_ic_accounts('00000000-0000-0000-0000-0000000299b2')),
  'no ID number: nobody');
reset role;

rollback;

select 'services_quick_fixes_0299: all passed';
