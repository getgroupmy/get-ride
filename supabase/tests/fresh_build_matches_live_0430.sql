-- ============================================================================
-- Regression test for migration 0430: a database built from the migrations
-- folder has what the live one has.
--   * ride_request_is_freight counts a courier request with nothing written
--     under "what is sent": by its parcel size, or by its courier service;
--   * ride_cancel_terms and ride_offer_make are 0268's courier versions, with
--     0316's GET.Plus line kept and the grants as before (the trip through
--     them is courier_0268.sql's);
--   * the owner of a support ticket overwrites their own attachment, as an
--     upload with upsert does, and nobody else does;
--   * nothing is left of the "fare_ai_responses insert" rule, and no rule
--     lets an app write that table;
--   * the two image buckets take images only.
-- All names are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/fresh_build_matches_live_0430.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000430a1'),  -- has a support ticket
  ('00000000-0000-0000-0000-0000000430b1')   -- somebody else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000430%'
on conflict do nothing;
insert into public.support_tickets (id, profile_id) values
  ('00000000-0000-0000-0000-0000000430e1', '00000000-0000-0000-0000-0000000430a1');

insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-000000043051', 'vehicle-services',
   '{"name": "Moto 430", "serviceTypes": ["Courier"], "maxLoadKg": 10}', 9401),
  ('00000000-0000-0000-0000-000000043052', 'vehicle-services', '{"name": "Car 430", "serviceTypes": ["Car"]}', 9402);

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
-- A request with only these columns set.
create or replace function pg_temp.request(p jsonb) returns public.ride_requests language sql as $$
  select jsonb_populate_record(null::public.ride_requests, p);
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text) to authenticated;

-- ---- 1. What counts as freight ------------------------------------------------------------------------------------
select pg_temp.check(public.ride_request_is_freight(pg_temp.request('{"parcel_size": "S"}')),
  'a parcel size alone makes it a courier request');
select pg_temp.check(public.ride_request_is_freight(pg_temp.request('{"service": "Moto 430"}')),
  'a courier service alone does too');
select pg_temp.check(public.ride_request_is_freight(pg_temp.request('{"cargo_description": "Box"}')),
  'cargo still does');
select pg_temp.check(not public.ride_request_is_freight(pg_temp.request('{"service": "Car 430"}'))
                     and not public.ride_request_is_freight(pg_temp.request('{}')),
  'a ride is not freight');

-- ---- 2. The cancel terms and the offer are the courier versions ---------------------------------------------------
select pg_temp.check(
  pg_get_functiondef('public.ride_cancel_terms(uuid)'::regprocedure) like '%''courier'', r.parcel_size is not null%'
  and pg_get_functiondef('public.ride_cancel_terms(uuid)'::regprocedure) like '%public.delivery_place_key(r, ''cancel-arrived'')%',
  'the cancel terms say courier and read the fee under the request''s own key');
select pg_temp.check(
  pg_get_functiondef('public.ride_cancel_terms(uuid)'::regprocedure) like '%public.plus_cancel_terms(r, v)%',
  'and still count a GET.Plus free cancel (0316)');
select pg_temp.check(
  pg_get_functiondef('public.ride_offer_make(uuid, numeric, integer, double precision, double precision)'::regprocedure)
    like '%COURIER_DRIVER_NO_COURIER%',
  'an offer without a courier vehicle gets the courier reason');
select pg_temp.check(
  has_function_privilege('authenticated', 'public.ride_cancel_terms(uuid)', 'execute')
  and not has_function_privilege('anon', 'public.ride_cancel_terms(uuid)', 'execute')
  and has_function_privilege('authenticated',
        'public.ride_offer_make(uuid, numeric, integer, double precision, double precision)', 'execute')
  and not has_function_privilege('anon',
        'public.ride_offer_make(uuid, numeric, integer, double precision, double precision)', 'execute')
  and not has_function_privilege('authenticated', 'public.ride_request_is_freight(public.ride_requests)', 'execute'),
  'the terms and the offer stay for signed-in callers, the freight test for the server');

-- ---- 3. A support attachment: its owner overwrites it -------------------------------------------------------------
select pg_temp.check((select count(*) = 1 from pg_policies
                       where schemaname = 'storage' and tablename = 'objects'
                         and policyname = 'support-media owner update' and cmd = 'UPDATE'
                         and roles = '{authenticated}'
                         and qual like '%support-media%' and qual like '%storage_owns_ticket_folder%'
                         and qual like '%caller_admin_can_write(''storage:support-media''%'
                         and with_check = qual),
  'the owner''s UPDATE rule is there, for the ticket''s owner and admins');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000430a1');
insert into storage.objects (bucket_id, name, owner)
values ('support-media', '00000000-0000-0000-0000-0000000430e1/image/20261123-a.jpg',
        '00000000-0000-0000-0000-0000000430a1');
-- The update half of Storage's upsert.
with u as (
  update storage.objects set name = name
   where bucket_id = 'support-media' and name = '00000000-0000-0000-0000-0000000430e1/image/20261123-a.jpg'
  returning 1
)
select pg_temp.check((select count(*) = 1 from u), 'the ticket''s owner overwrites their own attachment');
select pg_temp.as_user('00000000-0000-0000-0000-0000000430b1');
with u as (
  update storage.objects set name = name
   where bucket_id = 'support-media' and name = '00000000-0000-0000-0000-0000000430e1/image/20261123-a.jpg'
  returning 1
)
select pg_temp.check((select count(*) = 0 from u), 'somebody else does not');
reset role;

-- ---- 4. Nothing lets an app write fare_ai_responses ---------------------------------------------------------------
select pg_temp.check(not exists (select 1 from pg_policies
                                  where schemaname = 'public' and tablename = 'fare_ai_responses'
                                    and policyname = 'fare_ai_responses insert'),
  'the rule that allowed nothing is gone');
select pg_temp.check((select relrowsecurity from pg_class where oid = 'public.fare_ai_responses'::regclass)
                     and not exists (select 1 from pg_policies
                                      where schemaname = 'public' and tablename = 'fare_ai_responses'
                                        and cmd in ('INSERT', 'UPDATE', 'ALL')),
  'and no rule lets an app add or change a row');

-- ---- 5. The image buckets take images -----------------------------------------------------------------------------
select pg_temp.check((select count(*) = 2 from storage.buckets
                       where id in ('Profile Image', 'Vehicle_Image') and allowed_mime_types = array['image/*']),
  'Profile Image and Vehicle_Image take images only');

select 'fresh_build_matches_live_0430: all passed';
rollback;
