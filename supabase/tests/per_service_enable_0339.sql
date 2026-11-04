-- ============================================================================
-- Regression test for migration 0339: per-service enabling. Runs against the
-- full schema (all migrations applied), in one transaction that is rolled
-- back, like the other tests here.
--
-- A partner picks two Partner Service types: a Taxi type that requires a
-- driver permit (none uploaded → its driver_permit rule fails → blocked) and
-- a Hail type with no requirements (ready). We assert:
--   * reg_type_blocked_keys names only the Taxi type;
--   * reg_has_ready_type is true (the Hail type is ready), so submit/approval
--     no longer refuse the whole application;
--   * partner_type_ready is true for Hail, false for Taxi;
--   * once the driver permit is on the partner row, the Taxi type turns ready
--     by itself (automatic enabling) — nothing else changes.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/per_service_enable_0339.sql
--
-- The driver_partner_service_ok dispatch gate composes this readiness with the
-- existing partner_type_allows_service (config-driven) check; that composition
-- is covered where that config is seeded. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000339b1')  -- driver: Hail (ready) + Taxi (permit missing)
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000339%'
on conflict do nothing;
update public.profiles set id_type = 'mykad', nationality = 'Malaysian', ic = '900101-14-0339'
 where id = '00000000-0000-0000-0000-0000000339b1';

-- Two types: Hail needs nothing; Taxi needs a driver permit.
insert into public.settings_entries (id, category, values, position, active) values
  ('00000000-0000-0000-0000-0000000339e1', 'partner-type',
   '{"name":"Test0339 Hail","vehicleRequired":false}', 0, true),
  ('00000000-0000-0000-0000-0000000339e2', 'partner-type',
   '{"name":"Test0339 Taxi","vehicleRequired":false,
     "driverPermit":{"required":true,"rules":[{"country":"Malaysia","name":"Kad Pemandu","issuer":"APAD"}]}}', 0, true);

insert into public.partners (id, auth_user_id, name, phone, status, partner_types,
                             service_countries, service_states, service_cities) values
  ('00000000-0000-0000-0000-0000000339f1', '00000000-0000-0000-0000-0000000339b1', 'Test Driver 0339', '+60100003391',
   'unapproved', '{Test0339 Hail,Test0339 Taxi}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}');

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;

-- ---- With the Taxi permit missing: Taxi blocked, Hail ready ----------------
select pg_temp.check(
  public.reg_type_blocked_keys((select to_jsonb(p) from public.partners p where id = '00000000-0000-0000-0000-0000000339f1'))
    = array[public.ptr_key('Test0339 Taxi')],
  'only the Taxi type is blocked (its driver permit is missing)');

select pg_temp.check(
  public.reg_has_ready_type((select to_jsonb(p) from public.partners p where id = '00000000-0000-0000-0000-0000000339f1')),
  'at least one type (Hail) is ready, so the application is not refused outright');

select pg_temp.check(
  public.partner_type_ready('00000000-0000-0000-0000-0000000339b1', 'Test0339 Hail'),
  'the Hail type, which needs nothing, is ready');

select pg_temp.check(
  not public.partner_type_ready('00000000-0000-0000-0000-0000000339b1', 'Test0339 Taxi'),
  'the Taxi type is not ready while its driver permit is missing');

-- ---- Add the driver permit: the Taxi type turns ready by itself ------------
update public.partners
   set driver_permit_card_no = 'KP/0339', driver_permit_front_url = 'https://example.test/permit.jpg',
       driver_permit_valid_until = (current_date + 365)
 where id = '00000000-0000-0000-0000-0000000339f1';

select pg_temp.check(
  public.reg_type_blocked_keys((select to_jsonb(p) from public.partners p where id = '00000000-0000-0000-0000-0000000339f1')) = '{}',
  'with the permit on file, no type is blocked');

select pg_temp.check(
  public.partner_type_ready('00000000-0000-0000-0000-0000000339b1', 'Test0339 Taxi'),
  'the Taxi type is ready once its driver permit is on file (automatic)');

select pg_temp.check(
  public.reg_has_ready_type((select to_jsonb(p) from public.partners p where id = '00000000-0000-0000-0000-0000000339f1')),
  'both types ready');

rollback;
