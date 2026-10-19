-- ============================================================================
-- Regression test for migration 0245: Admin -> Partner Type rules (vehicle
-- age, permit, street hail, availability), their defaults, and who writes
-- them.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/partner_type_rules_0245.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- People: a driver (eHailing), a taxi driver (Teksi), a rider, two sub-admins.
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000245a1'),  -- Aida, eHailing
  ('00000000-0000-0000-0000-0000000245a2'),  -- Badrul, Teksi
  ('00000000-0000-0000-0000-0000000245a3'),  -- rider
  ('00000000-0000-0000-0000-0000000245a4'),  -- sub-admin, Service Settings only
  ('00000000-0000-0000-0000-0000000245a5')   -- sub-admin, Partner Type
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000245a%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000245a4', 'admin-settings-service', 'edit'),
  ('00000000-0000-0000-0000-0000000245a5', 'admin-settings-partner-type', 'edit');

-- A map: Zedland, its North (where the city Alpha is) and its South.
create or replace function pg_temp.square(p_s float8, p_w float8, p_n float8, p_e float8) returns jsonb
language sql as $$
  select jsonb_build_object('boundary', format(
    '{"coords":[{"latitude":%s,"longitude":%s},{"latitude":%s,"longitude":%s},{"latitude":%s,"longitude":%s},{"latitude":%s,"longitude":%s}]}',
    p_s, p_w, p_s, p_e, p_n, p_e, p_n, p_w));
$$;
insert into public.countries (name, values, geofence) values ('Zedland', '{}', pg_temp.square(0, 100, 10, 110));
insert into public.states (country, name, values, geofence) values
  ('Zedland', 'North', '{}', pg_temp.square(5, 100, 10, 110)),
  ('Zedland', 'South', '{}', pg_temp.square(0, 100, 5, 110));
insert into public.cities (country, state, name, values, geofence) values
  ('Zedland', 'North', 'Alpha', '{}', pg_temp.square(6, 104, 9, 106)),
  ('Zedland', 'South', 'Beta', '{}', pg_temp.square(1, 104, 4, 106));

-- The two types as the admin left them before 0245 (no rules).
delete from public.settings_entries where category = 'partner-type' and values ->> 'name' in ('eHailing', 'Teksi');
insert into public.settings_entries (id, category, values, position, active) values
  ('00000000-0000-0000-0000-0000000245e1', 'partner-type',
   '{"name":"eHailing","enabled":true,"isDefault":true,"vehicleRequired":true}', 0, true),
  ('00000000-0000-0000-0000-0000000245e2', 'partner-type',
   '{"name":"Teksi","enabled":true,"isDefault":true,"vehicleRequired":true}', 0, true);

insert into public.partners (id, auth_user_id, name, phone, status, partner_types,
                             service_countries, service_states, service_cities) values
  ('00000000-0000-0000-0000-0000000245b1', '00000000-0000-0000-0000-0000000245a1', 'Aida', '+60110000245', 'approved',
   '{eHailing}', '{Zedland}', '{Zedland|North}', '{Zedland|North|Alpha}'),
  ('00000000-0000-0000-0000-0000000245b2', '00000000-0000-0000-0000-0000000245a2', 'Badrul', '+60110000246', 'unapproved',
   '{Teksi}', '{Zedland}', '{Zedland|North}', '{Zedland|North|Alpha}');

-- Aida's vehicles: 30, 12, 12 (approved) and 5 (approved) years old.
insert into public.vehicle (id, plate, auth_user_id, owner_partner_id, status, year) values
  ('00000000-0000-0000-0000-0000000245c0', 'ZED2450', '00000000-0000-0000-0000-0000000245a1',
   '00000000-0000-0000-0000-0000000245b1', 'unapproved', (extract(year from current_date)::int - 30)::text),
  ('00000000-0000-0000-0000-0000000245c1', 'ZED2451', '00000000-0000-0000-0000-0000000245a1',
   '00000000-0000-0000-0000-0000000245b1', 'unapproved', (extract(year from current_date)::int - 12)::text),
  ('00000000-0000-0000-0000-0000000245c2', 'ZED2452', '00000000-0000-0000-0000-0000000245a1',
   '00000000-0000-0000-0000-0000000245b1', 'approved', (extract(year from current_date)::int - 12)::text),
  ('00000000-0000-0000-0000-0000000245c3', 'ZED2453', '00000000-0000-0000-0000-0000000245a1',
   '00000000-0000-0000-0000-0000000245b1', 'approved', (extract(year from current_date)::int - 5)::text);

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to anon, authenticated;

-- Back to the database's own session (no caller), as an admin's tool would be.
create or replace function pg_temp.as_db() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

-- [p_sql] is refused, with a hint containing [p_hint] when given.
create or replace function pg_temp.refused(p_sql text, p_what text, p_hint text default null) returns void
language plpgsql as $$
declare
  v_hint text;
  v_msg text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint, v_msg = message_text;
    if p_hint is not null and position(p_hint in coalesce(v_hint, '') || ' ' || coalesce(v_msg, '')) = 0 then
      raise exception 'FAILED: % was refused, but with "%" / "%"', p_what, v_msg, v_hint;
    end if;
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text, text) to anon, authenticated;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to anon, authenticated;

-- 1. Defaults: today's behaviour --------------------------------------------------------------
select pg_temp.check((select (r #>> '{age,required}')::boolean = false and (r #>> '{permit,required}')::boolean = false
                              and (r #>> '{availability,all}')::boolean and (r #>> '{hail,allowed}')::boolean = false
                         from public.partner_type_rules('eHailing') r),
                     'eHailing starts with no age limit, no permit, no hail, and everywhere');
select pg_temp.check((select (r #>> '{hail,allowed}')::boolean from public.partner_type_rules('Teksi') r),
                     'TEKSI keeps street hail by default');
select pg_temp.check((select (r #>> '{availability,all}')::boolean from public.partner_type_rules('Not a type') r),
                     'a type with no entry is available everywhere');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000245a1');
update public.vehicle set documents_ok = true where id = '00000000-0000-0000-0000-0000000245c0';
select pg_temp.check((select documents_ok from public.vehicle where id = '00000000-0000-0000-0000-0000000245c0'),
                     'with no rule, a 30-year-old vehicle is submitted as before');
select pg_temp.check((select (r ->> 'ok')::boolean and (r ->> 'hail')::boolean = false
                        from public.partner_type_check(2, 105, false) r),
                     'with no rule, the eHailing driver may work anywhere, without street hail');
reset role;

-- 2. Vehicle age -----------------------------------------------------------------------------
select pg_temp.as_db();
update public.settings_entries set values = values || '{"rules":{"vehicleAge":{"required":true,"rules":[
    {"maxYears":15},
    {"country":"Zedland","state":"North","maxYears":10}]}}}'::jsonb
 where id = '00000000-0000-0000-0000-0000000245e1';

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000245a1');
select pg_temp.refused(
  $q$update public.vehicle set documents_ok = true where id = '00000000-0000-0000-0000-0000000245c1'$q$,
  'submitting a 12-year-old vehicle where the limit is 10',
  'Vehicles for eHailing in North must be at most 10 years old (this one is 12)');
select pg_temp.refused(
  $q$select public.claim_vehicle('00000000-0000-0000-0000-0000000245c2', '00000000-0000-0000-0000-0000000245a1')$q$,
  'taking an approved 12-year-old vehicle to drive', 'at most 10 years old');
update public.vehicle set year = (extract(year from current_date)::int - 8)::text
 where id = '00000000-0000-0000-0000-0000000245c1';
update public.vehicle set documents_ok = true where id = '00000000-0000-0000-0000-0000000245c1';
select pg_temp.check((select documents_ok from public.vehicle where id = '00000000-0000-0000-0000-0000000245c1'),
                     'an 8-year-old vehicle is submitted');
reset role;

-- The narrowest rule wins: in the South only "All regions" (15) applies.
select pg_temp.check(public.ptr_vehicle_age_problem('eHailing', (extract(year from current_date)::int - 12)::text,
                                                    '{Zedland}', '{Zedland|South}', '{Zedland|South|Beta}') is null,
                     'a 12-year-old vehicle is fine in the South (limit 15)');
select pg_temp.check(public.ptr_vehicle_age_problem('eHailing', (extract(year from current_date)::int - 16)::text,
                                                    '{Zedland}', '{Zedland|South}', '{Zedland|South|Beta}')
                       = 'Vehicles for eHailing must be at most 15 years old (this one is 16).',
                     'a 16-year-old vehicle is refused everywhere');
-- A type without "Vehicle required" ignores the age rule.
update public.settings_entries set values = values || '{"vehicleRequired":false}'::jsonb
 where id = '00000000-0000-0000-0000-0000000245e1';
select pg_temp.check(public.ptr_vehicle_age_problem('eHailing', '1990', '{Zedland}', '{Zedland|North}', '{}') is null,
                     'no vehicle required: no age limit');
update public.settings_entries set values = values || '{"vehicleRequired":true}'::jsonb
 where id = '00000000-0000-0000-0000-0000000245e1';

-- 3. Permit --------------------------------------------------------------------------------------
update public.settings_entries set values = values || '{"rules":{"permit":{"required":true,"all":false,
    "regions":[{"country":"Zedland","state":"North"}]}}}'::jsonb
 where id = '00000000-0000-0000-0000-0000000245e2';
insert into public.required_document (id, values, active) values
  ('00000000-0000-0000-0000-0000000245d1', '{"name":"Driver Permit","isTaxiPermit":true,"active":true}', true);

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000245a2');
select pg_temp.refused(
  $q$update public.partners set documents_ok = true where id = '00000000-0000-0000-0000-0000000245b2'$q$,
  'submitting a Teksi application in the North without a permit', 'A permit is required for Teksi in North');
reset role;
-- Serving the South only, no permit is needed.
select pg_temp.as_db();
update public.partners set service_states = '{Zedland|South}', service_cities = '{Zedland|South|Beta}'
 where id = '00000000-0000-0000-0000-0000000245b2';
select pg_temp.check(public.ptr_permit_region('Teksi', '{Zedland}', '{Zedland|South}', '{Zedland|South|Beta}') is null,
                     'no permit is required in the South');
update public.partners set service_states = '{Zedland|North}', service_cities = '{Zedland|North|Alpha}'
 where id = '00000000-0000-0000-0000-0000000245b2';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000245a2');
insert into public.provider_documents (partner_id, auth_user_id, doc_id, doc_name, file_url, status)
values ('00000000-0000-0000-0000-0000000245b2', '00000000-0000-0000-0000-0000000245a2',
        '00000000-0000-0000-0000-0000000245d1', 'Driver Permit', 'https://example.test/permit.jpg', 'Pending Review');
update public.partners set documents_ok = true where id = '00000000-0000-0000-0000-0000000245b2';
select pg_temp.check((select documents_ok from public.partners where id = '00000000-0000-0000-0000-0000000245b2'),
                     'with the permit uploaded, the application is submitted');
reset role;

-- 4. Street hail ----------------------------------------------------------------------------------
select pg_temp.as_db();
update public.partners set status = 'approved' where id = '00000000-0000-0000-0000-0000000245b2';
update public.settings_entries set values = jsonb_set(values, '{rules,hail}',
    '{"allowed":true,"all":false,"regions":[{"country":"Zedland","state":"North"}]}')
 where id = '00000000-0000-0000-0000-0000000245e2';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000245a2');
select pg_temp.check((select (r ->> 'hail')::boolean from public.partner_type_check(7, 105, true) r),
                     'street hail is offered in the North');
select pg_temp.check((select (r ->> 'hail')::boolean = false from public.partner_type_check(2, 105, true) r),
                     'street hail is not offered in the South');
reset role;
select pg_temp.as_db();
update public.settings_entries set values = jsonb_set(values, '{rules,hail}', '{"allowed":false}')
 where id = '00000000-0000-0000-0000-0000000245e2';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000245a2');
select pg_temp.check((select (r ->> 'hail')::boolean = false from public.partner_type_check(7, 105, true) r),
                     'street hail switched off for Teksi is off everywhere');
reset role;

-- 5. Availability -------------------------------------------------------------------------------------
select pg_temp.as_db();
update public.settings_entries set values = jsonb_set(values, '{rules,availability}',
    '{"all":false,"regions":[{"country":"Zedland","state":"North"}]}')
 where id = '00000000-0000-0000-0000-0000000245e1';
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, pickup_lat, pickup_lng) values
  ('00000000-0000-0000-0000-0000000245f1', '00000000-0000-0000-0000-0000000245a3', 'open', 20, 20, 2, 105),
  ('00000000-0000-0000-0000-0000000245f2', '00000000-0000-0000-0000-0000000245a3', 'open', 20, 20, 7, 105);

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000245a1');
select public.claim_vehicle('00000000-0000-0000-0000-0000000245c3', '00000000-0000-0000-0000-0000000245a1');
select public.set_driver_presence(true, 7, 105);
select pg_temp.check((select online from public.driver_presence where profile_id = '00000000-0000-0000-0000-0000000245a1'),
                     'the eHailing driver is online in the North');
select public.set_driver_presence(true, 2, 105);
select pg_temp.check((select not online from public.driver_presence where profile_id = '00000000-0000-0000-0000-0000000245a1'),
                     'the eHailing driver is kept offline in the South');
select pg_temp.check((select (r ->> 'reason') = 'eHailing is not offered in Beta.' from public.partner_type_check(2, 105, false) r),
                     'the app is told why');
select pg_temp.refused(
  $q$update public.ride_requests set offered_fare = 22, partner_id = '00000000-0000-0000-0000-0000000245a1'
      where id = '00000000-0000-0000-0000-0000000245f1'$q$,
  'bidding on a ride starting where eHailing is not offered', 'not offered where this ride starts');
update public.ride_requests set offered_fare = 22, partner_id = '00000000-0000-0000-0000-0000000245a1'
 where id = '00000000-0000-0000-0000-0000000245f2';
select pg_temp.check((select partner_id = '00000000-0000-0000-0000-0000000245a1'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000245f2'),
                     'bidding on a ride in the North');
-- Signing up: eHailing can't be chosen for a South-only service area.
select pg_temp.refused(
  $q$update public.partners set service_states = '{Zedland|South}', service_cities = '{Zedland|South|Beta}'
      where id = '00000000-0000-0000-0000-0000000245b1'$q$,
  'choosing a service area where eHailing is not offered', 'eHailing is not offered in your service area');
reset role;

-- 6. Who writes partner types (RLS) ------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000245a1');
select pg_temp.check((select count(*) = 2 from public.settings_entries
                       where id in ('00000000-0000-0000-0000-0000000245e1', '00000000-0000-0000-0000-0000000245e2')),
                     'partners read the partner types and their rules');
update public.settings_entries set values = values || '{"rules":{}}'::jsonb
 where id = '00000000-0000-0000-0000-0000000245e1';
select pg_temp.as_user('00000000-0000-0000-0000-0000000245a4');
update public.settings_entries set values = values || '{"rules":{}}'::jsonb
 where id = '00000000-0000-0000-0000-0000000245e1';
select pg_temp.as_user('00000000-0000-0000-0000-0000000245a5');
update public.settings_entries set values = values || '{"enabled":false}'::jsonb
 where id = '00000000-0000-0000-0000-0000000245e1';
reset role;
select pg_temp.as_db();
select pg_temp.check((select (values #>> '{rules,availability,all}') = 'false' and (values ->> 'enabled') = 'false'
                        from public.settings_entries where id = '00000000-0000-0000-0000-0000000245e1'),
                     'only the Partner Type page''s editor changed the type (a partner and another settings page could not)');

select 'partner_type_rules_0245: all passed';
rollback;
