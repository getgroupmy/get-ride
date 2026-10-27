-- ============================================================================
-- Regression test for migration 0304: renaming a Vehicle Service or a
-- Partner Service type keeps every place that uses the name working.
--   * the preview counts every place (and shows examples); the open
--     requests, bookings for later and finished rides are counted apart;
--   * a name already used (no case, extra spaces or the same key) is refused;
--   * the rename changes the entry and every place at once, finished rides
--     keep the old name, and the history row says who, when and how many;
--   * only the latest rename of an entry is undone, and only once;
--   * a direct name change from the apps is refused (only the RPCs pass),
--     approved partners keep their approval and their own type edits stay
--     locked;
--   * EDIT on the category's page only.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/safe_renames_0304.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up people and names only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000304a1'),  -- admin, EDIT on Vehicle Services
  ('00000000-0000-0000-0000-0000000304a2'),  -- admin, EDIT on Partner Service type
  ('00000000-0000-0000-0000-0000000304a3'),  -- admin, READ on Vehicle Services
  ('00000000-0000-0000-0000-0000000304b1'),  -- driver, approved, pHailing 0304
  ('00000000-0000-0000-0000-0000000304b2'),  -- driver, applying, older type list
  ('00000000-0000-0000-0000-0000000304c1')   -- rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000304%'
on conflict do nothing;
update public.profiles set name = 'Farah Z.' where id = '00000000-0000-0000-0000-0000000304a1';
update public.profiles set name = 'Daniel T.' where id = '00000000-0000-0000-0000-0000000304a2';
update public.profiles set name = 'Aiman R.' where id = '00000000-0000-0000-0000-0000000304b1';
update public.profiles set name = 'Siti N.' where id = '00000000-0000-0000-0000-0000000304b2';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000304a1', 'admin-settings-vehicle-services', 'edit'),
  ('00000000-0000-0000-0000-0000000304a2', 'admin-settings-partner-type', 'edit'),
  ('00000000-0000-0000-0000-0000000304a3', 'admin-settings-vehicle-services', 'read')
on conflict do nothing;

-- The entries.
insert into public.settings_entries (id, category, values) values
  ('00000000-0000-0000-0000-000000030401', 'vehicle-services', '{"name": "Comfort 0304", "seats": 4}'),
  ('00000000-0000-0000-0000-000000030402', 'vehicle-services', '{"name": "Premium 0304"}'),
  ('00000000-0000-0000-0000-000000030411', 'partner-type', '{"name": "pHailing 0304"}'),
  ('00000000-0000-0000-0000-000000030412', 'partner-type',
   '{"name": "Fleet 0304", "vehicleRequired": true, "vehiclePermitAlsoFor": "[\"pHailing 0304\"]",
     "ageLimitCovers": [{"country": "Testland 0304", "types": ["phailing-0304", "Fleet 0304"]}]}'),
  ('00000000-0000-0000-0000-000000030421', 'push-notification',
   '{"title": "Parcel riders 0304", "body": "Hello", "audience": "partners", "partnerTypes": ["pHailing 0304"]}');
insert into public.required_document (id, values) values
  ('00000000-0000-0000-0000-000000030431', '{"name": "Bike licence 0304", "partnerTypes": "[\"pHailing 0304\",\"Fleet 0304\"]"}');

-- Who uses the Vehicle Service.
insert into public.partner_type_services (type_key, type_name, all_services, services) values
  ('test0304a', 'Test0304 A', false, array['Comfort 0304', 'Ride 0304']),
  ('test0304b', 'Test0304 B', false, array['comfort-0304']),
  ('test0304c', 'Test0304 C', false, array['Ride 0304']),
  ('phailing0304', 'pHailing 0304', false, array['Parcel 0304'])
on conflict (type_key) do update set all_services = excluded.all_services, services = excluded.services;

insert into public.partners (id, auth_user_id, name, phone, status, partner_types, partner_type) values
  ('00000000-0000-0000-0000-0000000304e1', '00000000-0000-0000-0000-0000000304b1', 'Aiman R.', '+60100003041',
   'approved', '{pHailing 0304}', null),
  ('00000000-0000-0000-0000-0000000304e2', '00000000-0000-0000-0000-0000000304b2', 'Siti N.', '+60100003042',
   'unapproved', '{}', 'pHailing 0304,Fleet 0304');
insert into public.vehicle (id, auth_user_id, owner_partner_id, plate, make, model, color, status, partner_types) values
  ('00000000-0000-0000-0000-0000000304f1', '00000000-0000-0000-0000-0000000304b1', '00000000-0000-0000-0000-0000000304e1',
   'TST 3041', 'Testmake', 'Alpha', 'White', 'approved', '{pHailing 0304}');
insert into public.vehicle_service_status (vehicle_id, service, status, max_age_years, limit_type, set_by_admin) values
  ('00000000-0000-0000-0000-0000000304f1', 'pHailing 0304', 'paused_age', 10, 'pHailing 0304', true);

insert into public.driver_service_prefs (driver_id, vehicle_id, service_key, enabled) values
  ('00000000-0000-0000-0000-0000000304b1', '00000000-0000-0000-0000-0000000304f1', 'Comfort 0304', false),
  -- Left on the new name by a service removed before: gives way.
  ('00000000-0000-0000-0000-0000000304b1', '00000000-0000-0000-0000-0000000304f1', 'Comfort Plus 0304', true);
insert into public.driver_service_locks (scope, driver_id, partner_type, service_key, mode) values
  ('driver', '00000000-0000-0000-0000-0000000304b2', null, 'Comfort 0304', 'off'),
  ('partner_type', null, 'test0304a', 'Comfort 0304', 'on'),
  ('partner_type', null, 'phailing0304', 'Ride 0304', 'off');

insert into public.promo_codes (code, discount_type, discount_value, services) values
  ('P0304A', 'fixed', 5, array['Comfort 0304', 'Ride 0304']),
  ('P0304B', 'fixed', 5, array['Premium 0304']);
insert into public.commission_promotions (name, rate, starts_at, ends_at, services) values
  ('Promo 0304', 0.05, now(), now() + interval '1 day', array['Comfort 0304']);
insert into public.permit_types (id, country, key, name, applies_to, uploader, partner_types, services) values
  ('00000000-0000-0000-0000-0000000304d1', 'Testland 0304', 'tst-0304', 'Test permit 0304', 'vehicle', 'admin',
   array['pHailing 0304'], array['Comfort 0304']);
insert into public.push_schedules (title, body, audience, partner_types, send_at, status) values
  ('Later 0304', 'Hi', 'partners', '{pHailing 0304}', now() + interval '1 day', 'active'),
  ('Sent 0304', 'Hi', 'partners', '{pHailing 0304}', now() - interval '1 day', 'done');

insert into public.ride_requests (id, rider_id, status, service, fare, ride_fare, pickup_lat, pickup_lng, drop_lat, drop_lng)
values
  ('00000000-0000-0000-0000-000000030491', '00000000-0000-0000-0000-0000000304c1', 'open', 'Comfort 0304', 20, 20,
   3.1, 101.6, 3.2, 101.7),
  ('00000000-0000-0000-0000-000000030492', '00000000-0000-0000-0000-0000000304c1', 'completed', 'Comfort 0304', 20, 20,
   3.1, 101.6, 3.2, 101.7),
  ('00000000-0000-0000-0000-000000030493', '00000000-0000-0000-0000-0000000304c1', 'cancelled', 'comfort 0304', 20, 20,
   3.1, 101.6, 3.2, 101.7);
insert into public.scheduled_rides (id, rider_id, pickup_at, status, request, service, fare) values
  ('00000000-0000-0000-0000-000000030495', '00000000-0000-0000-0000-0000000304c1', now() + interval '1 day', 'scheduled',
   '{"service": "Comfort 0304"}', 'Comfort 0304', 20);

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
-- A place's count in a preview.
create or replace function pg_temp.count_of(p jsonb, p_key text) returns bigint language sql as $$
  select (x ->> 'count')::bigint from jsonb_array_elements(p -> 'places') x where x ->> 'key' = p_key;
$$;
create temp table t_out (k text primary key, v jsonb);
grant all on t_out to authenticated;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.error_of(text),
  pg_temp.count_of(jsonb, text) to authenticated;

-- 1. Who may -------------------------------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('anon', 'public.admin_rename_apply(text, uuid, text)', 'execute'),
  'not for anon');
select pg_temp.check(not has_function_privilege('authenticated', 'public.safe_rename_run(text, uuid, text, text, boolean)',
                                                'execute'), 'the cascade itself is not callable');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000304b1');
select pg_temp.check(pg_temp.error_of($q$select public.admin_rename_preview('vehicle-services',
    '00000000-0000-0000-0000-000000030401', 'Comfort Plus 0304')$q$) like 'not_authorized%', 'a driver can''t preview');
select pg_temp.check(pg_temp.error_of($q$select public.admin_rename_apply('vehicle-services',
    '00000000-0000-0000-0000-000000030401', 'Comfort Plus 0304')$q$) like 'not_authorized%', 'or rename');
select pg_temp.as_user('00000000-0000-0000-0000-0000000304a3');
select pg_temp.check(pg_temp.error_of($q$select public.admin_rename_apply('vehicle-services',
    '00000000-0000-0000-0000-000000030401', 'Comfort Plus 0304')$q$) like 'not_authorized%', 'READ on the page: no');
select pg_temp.as_user('00000000-0000-0000-0000-0000000304a2');
select pg_temp.check(pg_temp.error_of($q$select public.admin_rename_apply('vehicle-services',
    '00000000-0000-0000-0000-000000030401', 'Comfort Plus 0304')$q$) like 'not_authorized%',
  'EDIT on Partner Service type does not rename Vehicle Services');
select pg_temp.as_user('00000000-0000-0000-0000-0000000304a1');
select pg_temp.check(pg_temp.error_of($q$select public.admin_rename_apply('partner-type',
    '00000000-0000-0000-0000-000000030411', 'Parcel 0304')$q$) like 'not_authorized%',
  'nor the other way round');
select pg_temp.check(pg_temp.error_of($q$select public.admin_rename_apply('vehicle-services',
    '00000000-0000-0000-0000-000000030411', 'Parcel 0304')$q$) like 'RENAME_NOT_FOUND%',
  'an entry of another category is not found');

-- 2. A direct name change from the apps -------------------------------------------------------------------
select pg_temp.check(pg_temp.error_of($q$update public.settings_entries
    set values = values || '{"name": "Comfort Plus 0304"}' where id = '00000000-0000-0000-0000-000000030401'$q$)
  like 'RENAME_THROUGH_PREVIEW:%', 'a name saved straight to the table is refused');
select pg_temp.check(pg_temp.error_of($q$update public.settings_entries
    set values = values || '{"name": " Comfort 0304 ", "seats": 5}' where id = '00000000-0000-0000-0000-000000030401'$q$)
  = 'ok', 'the other fields (and the same name with spaces) save as before');
reset role;
select set_config('request.jwt.claims', '', true);
update public.settings_entries set values = values || '{"name": "Premium Max 0304"}'
 where id = '00000000-0000-0000-0000-000000030402';
update public.settings_entries set values = values || '{"name": "Premium 0304"}'
 where id = '00000000-0000-0000-0000-000000030402';
select pg_temp.check((select values ->> 'name' = 'Premium 0304' from public.settings_entries
                       where id = '00000000-0000-0000-0000-000000030402'), 'the server is not held');

-- 3. The preview and the names already used -------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000304a1');
insert into t_out select 'vs', public.admin_rename_preview('vehicle-services', '00000000-0000-0000-0000-000000030401',
                                                        '  Comfort Plus 0304 ');
insert into t_out select 'taken', public.admin_rename_preview('vehicle-services', '00000000-0000-0000-0000-000000030401',
                                                           'premium 0304 ');
insert into t_out select 'taken_key', public.admin_rename_preview('vehicle-services',
                                                               '00000000-0000-0000-0000-000000030401', 'Premium-0304');
select pg_temp.check(pg_temp.error_of($q$select public.admin_rename_apply('vehicle-services',
    '00000000-0000-0000-0000-000000030401', 'PREMIUM 0304')$q$)
  = 'RENAME_NAME_TAKEN: A Vehicle Service named Premium 0304 already exists.', 'a name used already is refused');
select pg_temp.check(pg_temp.error_of($q$select public.admin_rename_apply('vehicle-services',
    '00000000-0000-0000-0000-000000030401', '  ')$q$) like 'RENAME_NAME_EMPTY%', 'an empty name is refused');
select pg_temp.check(pg_temp.error_of($q$select public.admin_rename_apply('vehicle-services',
    '00000000-0000-0000-0000-000000030401', 'Comfort 0304')$q$) like 'RENAME_SAME%', 'the same name is no rename');
reset role;

select pg_temp.check((select v ->> 'old_name' = 'Comfort 0304' and v ->> 'new_name' = 'Comfort Plus 0304'
                             and v -> 'problem' = 'null'::jsonb and not (v ->> 'conflict')::boolean
                        from t_out where k = 'vs'), 'the preview names the old and the new name');
select pg_temp.check((select pg_temp.count_of(v, 'type_services') = 2 and pg_temp.count_of(v, 'driver_switches') = 1
                             and pg_temp.count_of(v, 'service_locks') = 1 and pg_temp.count_of(v, 'partner_type_locks') = 1
                             and pg_temp.count_of(v, 'promo_codes') = 1 and pg_temp.count_of(v, 'commission_promotions') = 1
                             and pg_temp.count_of(v, 'permit_services') = 1 and (v ->> 'total')::int = 8
                        from t_out where k = 'vs'), 'the preview counts every place');
select pg_temp.check((select (v ->> 'open_requests')::int = 1 and (v ->> 'bookings')::int = 1
                             and (v ->> 'finished_rides')::int = 2 from t_out where k = 'vs'),
  'open requests, bookings for later and finished rides are counted apart');
select pg_temp.check((select x -> 'examples' = '["P0304A"]'::jsonb and (x ->> 'more')::int = 0
                        from t_out, jsonb_array_elements(v -> 'places') x where k = 'vs' and x ->> 'key' = 'promo_codes'),
  'with examples');
select pg_temp.check((select x -> 'examples' = '["Siti N. (kept off)"]'::jsonb
                        from t_out, jsonb_array_elements(v -> 'places') x where k = 'vs' and x ->> 'key' = 'service_locks'),
  'a lock says whose it is');
select pg_temp.check((select (v ->> 'conflict')::boolean and v #>> '{problem,code}' = 'RENAME_NAME_TAKEN'
                             and v #>> '{problem,conflict_name}' = 'Premium 0304'
                             and v #>> '{problem,message}' = 'A Vehicle Service named Premium 0304 already exists.'
                             and v -> 'places' = '[]'::jsonb
                        from t_out where k = 'taken'), 'without case or extra spaces: taken');
select pg_temp.check((select (v ->> 'conflict')::boolean from t_out where k = 'taken_key'), 'the same key: taken');

-- 4. Rename a Vehicle Service --------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000304a1');
insert into t_out select 'vs_apply', public.admin_rename_apply('vehicle-services',
  '00000000-0000-0000-0000-000000030401', 'Comfort Plus 0304');
reset role;
select set_config('request.jwt.claims', '', true);

select pg_temp.check((select values ->> 'name' = 'Comfort Plus 0304' and values ->> 'seats' = '5'
                        from public.settings_entries where id = '00000000-0000-0000-0000-000000030401'),
  'the entry has the new name, its other values kept');
select pg_temp.check((select services = array['Comfort Plus 0304', 'Ride 0304'] from public.partner_type_services
                       where type_key = 'test0304a')
                     and (select services = array['Comfort Plus 0304'] from public.partner_type_services
                           where type_key = 'test0304b')
                     and (select services = array['Ride 0304'] from public.partner_type_services
                           where type_key = 'test0304c'), 'the services each type sees');
select pg_temp.check((select count(*) = 1 and bool_and(service_key = 'comfortplus0304' and not enabled)
                        from public.driver_service_prefs where driver_id = '00000000-0000-0000-0000-0000000304b1'),
  'the driver''s switch follows (kept off), the old one on the new key gave way');
select pg_temp.check((select count(*) = 2 from public.driver_service_locks
                       where service_key = 'comfortplus0304' and (driver_id = '00000000-0000-0000-0000-0000000304b2'
                                                                  or partner_type = 'test0304a'))
                     and not exists (select 1 from public.driver_service_locks where service_key = 'comfort0304'),
  'the locks follow');
select pg_temp.check((select services = array['Comfort Plus 0304', 'Ride 0304'] from public.promo_codes where code = 'P0304A')
                     and (select services = array['Premium 0304'] from public.promo_codes where code = 'P0304B'),
  'promo codes follow');
select pg_temp.check((select services = array['comfort plus 0304'] from public.commission_promotions
                       where name = 'Promo 0304'), 'commission promotions follow (lower case)');
select pg_temp.check((select services = array['Comfort Plus 0304'] from public.permit_types
                       where id = '00000000-0000-0000-0000-0000000304d1'), 'the permit type''s services follow');
select pg_temp.check((select service = 'Comfort Plus 0304' from public.ride_requests
                       where id = '00000000-0000-0000-0000-000000030491'), 'the open request keeps running');
select pg_temp.check((select service = 'Comfort Plus 0304' and request ->> 'service' = 'Comfort Plus 0304'
                        from public.scheduled_rides where id = '00000000-0000-0000-0000-000000030495'),
  'the booking for later too');
select pg_temp.check((select service = 'Comfort 0304' from public.ride_requests where id = '00000000-0000-0000-0000-000000030492')
                     and (select service = 'comfort 0304' from public.ride_requests
                           where id = '00000000-0000-0000-0000-000000030493'),
  'finished rides keep the old name');
select pg_temp.check((select r.old_name = 'Comfort 0304' and r.new_name = 'Comfort Plus 0304' and r.total = 8
                             and r.renamed_by = '00000000-0000-0000-0000-0000000304a1' and r.by_name = 'Farah Z.'
                             and (r.places ->> 'driver_switches')::int = 1 and r.undone_at is null
                             and r.id = (o.v ->> 'id')::uuid
                        from public.settings_renames r, t_out o
                       where r.entry_id = '00000000-0000-0000-0000-000000030401' and o.k = 'vs_apply'),
  'the history row: who, the names and the places');
select pg_temp.check((select (v ->> 'total')::int = 8 and (v ->> 'open_requests')::int = 1 from t_out where k = 'vs_apply'),
  'the answer has the counts');
select pg_temp.check(current_setting('app.safe_rename', true) = '', 'the rename flag is off again');

-- The direct change is still refused after an RPC ran in the same transaction.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000304a1');
select pg_temp.check(pg_temp.error_of($q$update public.settings_entries
    set values = values || '{"name": "Sneaky 0304"}' where id = '00000000-0000-0000-0000-000000030401'$q$)
  like 'RENAME_THROUGH_PREVIEW:%', 'the flag does not outlive the rename');

-- 5. Undo: the latest only, once ---------------------------------------------------------------------------
insert into t_out select 'vs_apply2', public.admin_rename_apply('vehicle-services',
  '00000000-0000-0000-0000-000000030401', 'Comfort Max 0304');
select pg_temp.check(pg_temp.error_of(format('select public.admin_rename_undo(%L)',
    (select v ->> 'id' from t_out where k = 'vs_apply'))) like 'RENAME_NOT_LATEST%', 'an older rename is not undone');
select pg_temp.as_user('00000000-0000-0000-0000-0000000304b1');
select pg_temp.check(pg_temp.error_of(format('select public.admin_rename_undo(%L)',
    (select v ->> 'id' from t_out where k = 'vs_apply2'))) like 'not_authorized%', 'a driver can''t undo');
select pg_temp.check((select count(*) = 0 from public.settings_renames), 'nor read the history');
select pg_temp.as_user('00000000-0000-0000-0000-0000000304a1');
insert into t_out select 'vs_undo', public.admin_rename_undo((select (v ->> 'id')::uuid from t_out where k = 'vs_apply2'));
select pg_temp.check(pg_temp.error_of(format('select public.admin_rename_undo(%L)',
    (select v ->> 'id' from t_out where k = 'vs_apply2'))) like 'RENAME_ALREADY_UNDONE%', 'undone once');
select pg_temp.check(pg_temp.error_of(format('select public.admin_rename_undo(%L)',
    (select v ->> 'id' from t_out where k = 'vs_apply'))) like 'RENAME_NOT_LATEST%', 'the one before stays');
reset role;
select set_config('request.jwt.claims', '', true);
select pg_temp.check((select values ->> 'name' = 'Comfort Plus 0304' from public.settings_entries
                       where id = '00000000-0000-0000-0000-000000030401'), 'the undo puts the name back');
select pg_temp.check((select services = array['Comfort Plus 0304', 'Ride 0304'] from public.partner_type_services
                       where type_key = 'test0304a')
                     and (select service_key = 'comfortplus0304' from public.driver_service_prefs
                           where driver_id = '00000000-0000-0000-0000-0000000304b1')
                     and (select services = array['comfort plus 0304'] from public.commission_promotions
                           where name = 'Promo 0304')
                     and (select service = 'Comfort Plus 0304' from public.ride_requests
                           where id = '00000000-0000-0000-0000-000000030491'),
  'and every place with it');
select pg_temp.check((select undone_at is not null from public.settings_renames
                       where id = (select (v ->> 'id')::uuid from t_out where k = 'vs_apply2'))
                     and (select undone_at is null from public.settings_renames
                           where id = (select (v ->> 'id')::uuid from t_out where k = 'vs_apply')),
  'only that row is marked undone');
select pg_temp.check((select (v ->> 'total')::int = 8 from t_out where k = 'vs_undo'), 'the undo changed the same places');

-- 6. Rename a Partner Service type ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000304a2');
insert into t_out select 'pt', public.admin_rename_preview('partner-type', '00000000-0000-0000-0000-000000030411',
                                                        'Parcel Hailing 0304');
select pg_temp.check(pg_temp.error_of($q$select public.admin_rename_apply('partner-type',
    '00000000-0000-0000-0000-000000030411', 'fleet-0304')$q$) like 'RENAME_NAME_TAKEN%', 'a type name used already');
select pg_temp.check(pg_temp.error_of($q$select public.admin_rename_apply('partner-type',
    '00000000-0000-0000-0000-000000030411', 'TEKSI')$q$) like 'RENAME_BUILT_IN%', 'no type becomes Teksi');
select pg_temp.check(pg_temp.error_of($q$select public.admin_rename_apply('partner-type',
    '00000000-0000-0000-0000-000000030411', 'Parcel, Hailing')$q$) like 'RENAME_NAME_COMMA%', 'no comma in a type');
insert into t_out select 'pt_apply', public.admin_rename_apply('partner-type', '00000000-0000-0000-0000-000000030411',
                                                            'Parcel Hailing 0304');
reset role;
select set_config('request.jwt.claims', '', true);
select pg_temp.check(public.safe_rename_problem('partner-type', gen_random_uuid(), 'Teksi', 'Taxi 0304') ->> 'code'
                     = 'RENAME_BUILT_IN', 'Teksi keeps its name');

select pg_temp.check((select pg_temp.count_of(v, 'type_services') = 1 and pg_temp.count_of(v, 'partners') = 2
                             and pg_temp.count_of(v, 'vehicles') = 1 and pg_temp.count_of(v, 'vehicle_checks') = 1
                             and pg_temp.count_of(v, 'permit_types') = 1 and pg_temp.count_of(v, 'push_audiences') = 2
                             and pg_temp.count_of(v, 'document_rules') = 2 and pg_temp.count_of(v, 'driver_locks') = 1
                             and (v ->> 'total')::int = 11
                        from t_out where k = 'pt'), 'the type''s preview counts every place');
select pg_temp.check((select values ->> 'name' = 'Parcel Hailing 0304' and values -> 'vehicleRequired' = 'false'::jsonb
                        from public.settings_entries where id = '00000000-0000-0000-0000-000000030411'),
  'the type is renamed and keeps its "Vehicle required" default');
select pg_temp.check((select type_name = 'Parcel Hailing 0304' and services = array['Parcel 0304']
                        from public.partner_type_services where type_key = 'parcelhailing0304')
                     and not exists (select 1 from public.partner_type_services where type_key = 'phailing0304'),
  'the services it sees follow');
select pg_temp.check((select partner_types = array['Parcel Hailing 0304'] and status::text = 'approved'
                        from public.partners where id = '00000000-0000-0000-0000-0000000304e1'),
  'an approved partner has the new type and keeps the approval');
select pg_temp.check((select partner_type = 'Parcel Hailing 0304,Fleet 0304' from public.partners
                       where id = '00000000-0000-0000-0000-0000000304e2'), 'the older type list follows');
select pg_temp.check((select partner_types = array['Parcel Hailing 0304'] from public.vehicle
                       where id = '00000000-0000-0000-0000-0000000304f1'), 'the vehicle follows');
select pg_temp.check((select service = 'Parcel Hailing 0304' and limit_type = 'Parcel Hailing 0304' and set_by_admin
                             and status = 'paused_age'
                        from public.vehicle_service_status where vehicle_id = '00000000-0000-0000-0000-0000000304f1'),
  'the per-vehicle check follows, still set by the admin');
select pg_temp.check((select partner_types = array['Parcel Hailing 0304'] from public.permit_types
                       where id = '00000000-0000-0000-0000-0000000304d1'), 'the permit type follows');
select pg_temp.check((select values -> 'partnerTypes' = '["Parcel Hailing 0304"]'::jsonb from public.settings_entries
                       where id = '00000000-0000-0000-0000-000000030421')
                     and (select partner_types = array['Parcel Hailing 0304'] from public.push_schedules
                           where title = 'Later 0304')
                     and (select partner_types = array['pHailing 0304'] from public.push_schedules
                           where title = 'Sent 0304'),
  'push audiences follow; a push already sent keeps its audience');
select pg_temp.check((select jsonb_typeof(values -> 'partnerTypes') = 'string'
                             and (values ->> 'partnerTypes')::jsonb = '["Parcel Hailing 0304", "Fleet 0304"]'::jsonb
                        from public.required_document where id = '00000000-0000-0000-0000-000000030431'),
  'the required document follows, kept as JSON text');
select pg_temp.check((select (values ->> 'vehiclePermitAlsoFor')::jsonb = '["Parcel Hailing 0304"]'::jsonb
                             and values #> '{ageLimitCovers,0,types}' = '["Parcel Hailing 0304", "Fleet 0304"]'::jsonb
                             and values #>> '{ageLimitCovers,0,country}' = 'Testland 0304'
                        from public.settings_entries where id = '00000000-0000-0000-0000-000000030412'),
  'the other type''s permit and age-limit rules follow');
select pg_temp.check((select count(*) = 1 from public.driver_service_locks where partner_type = 'parcelhailing0304')
                     and not exists (select 1 from public.driver_service_locks where partner_type = 'phailing0304'),
  'the type''s locks follow');

-- The lock on a partner's own types still holds them.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000304b1');
select pg_temp.check(pg_temp.error_of($q$update public.partners set partner_types = '{Parcel Hailing 0304,Fleet 0304}'
  where id = '00000000-0000-0000-0000-0000000304e1'$q$) like 'PARTNER_TYPES_LOCKED:%',
  'the approved partner still can''t change their own types');
reset role;

rollback;

select 'safe_renames_0304: all passed';
