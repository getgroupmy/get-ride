-- ============================================================================
-- Regression test for migration 0148: who may write and read each document
-- file, by what its first folder is.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/storage_owner_rules.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000148a1'),  -- a driver (owns partner + vehicle + ticket)
  ('00000000-0000-0000-0000-0000000148a2'),  -- a driver assigned to that vehicle
  ('00000000-0000-0000-0000-0000000148b1')   -- somebody else
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000148%'
on conflict do nothing;
insert into public.partners (id, auth_user_id, name, phone) values
  ('00000000-0000-0000-0000-0000000148c1', '00000000-0000-0000-0000-0000000148a1', 'Owner', '+60100000148');
insert into public.vehicle (id, owner_partner_id, plate) values
  ('00000000-0000-0000-0000-0000000148d1', '00000000-0000-0000-0000-0000000148c1', 'TEST148');
insert into public.vehicle_user_assignment (vehicle_id, user_id) values
  ('00000000-0000-0000-0000-0000000148d1', '00000000-0000-0000-0000-0000000148a2');
insert into public.support_tickets (id, profile_id) values
  ('00000000-0000-0000-0000-0000000148e1', '00000000-0000-0000-0000-0000000148a1');

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
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text) to authenticated;

set local role authenticated;

-- 1. The owner ---------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000148a1');
select pg_temp.check(public.storage_owns_partner_folder('00000000-0000-0000-0000-0000000148c1'),
  'a driver owns their partner folder');
select pg_temp.check(public.storage_owns_partner_folder('00000000-0000-0000-0000-0000000148a1'),
  'and an older upload under their own id');
select pg_temp.check(public.storage_owns_vehicle_folder('00000000-0000-0000-0000-0000000148d1'),
  'a driver owns the folder of the vehicle their partner row owns');
select pg_temp.check(public.storage_owns_ticket_folder('00000000-0000-0000-0000-0000000148e1'),
  'a user owns their support ticket folder');

-- 2. A driver assigned to the vehicle -------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000148a2');
select pg_temp.check(public.storage_owns_vehicle_folder('00000000-0000-0000-0000-0000000148d1'),
  'an assigned driver may file the vehicle''s documents');
select pg_temp.check(not public.storage_owns_partner_folder('00000000-0000-0000-0000-0000000148c1'),
  'but not the owner''s own partner documents');
select pg_temp.check(not public.storage_owns_ticket_folder('00000000-0000-0000-0000-0000000148e1'),
  'nor read their support ticket');

-- 3. Somebody else ----------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000148b1');
select pg_temp.check(not public.storage_owns_partner_folder('00000000-0000-0000-0000-0000000148c1')
                 and not public.storage_owns_vehicle_folder('00000000-0000-0000-0000-0000000148d1')
                 and not public.storage_owns_ticket_folder('00000000-0000-0000-0000-0000000148e1'),
  'a stranger owns none of them');
select pg_temp.check(not public.storage_owns_vehicle_folder('not-a-uuid'), 'a junk folder belongs to nobody');

-- An unassigned driver loses the vehicle.
reset role;
update public.vehicle_user_assignment set is_active = false
 where vehicle_id = '00000000-0000-0000-0000-0000000148d1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000148a2');
select pg_temp.check(not public.storage_owns_vehicle_folder('00000000-0000-0000-0000-0000000148d1'),
  'an unassigned driver no longer files for the vehicle');
reset role;

-- 4. The policies ------------------------------------------------------------------------
select pg_temp.check(not exists (
  select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
     and policyname in ('provider-documents auth write', 'provider-documents auth update',
                        'vehicle-documents auth write', 'vehicle-documents auth update',
                        'support-media auth write', 'public read support-media', 'anon upload support-media',
                        'auth update support-media', 'auth delete support-media', 'public read id_image')),
  'no bucket-only or public rule is left');
select pg_temp.check((select count(*) = 9 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                       and policyname in ('provider-documents owner write', 'provider-documents owner update',
                                          'provider-documents owner read', 'vehicle-documents owner write',
                                          'vehicle-documents owner update', 'vehicle-documents owner read',
                                          'support-media owner write', 'support-media owner read',
                                          'ID_Image owner read')),
  'every owner rule is in place');
select pg_temp.check(not has_function_privilege('anon', 'public.storage_owns_vehicle_folder(text)', 'execute'),
  'the ownership checks are not for anonymous callers');

select 'storage_owner_rules: all passed';
rollback;
