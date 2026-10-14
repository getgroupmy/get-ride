-- ============================================================================
-- Regression test for migration 0186: only an approved vehicle is driven, and
-- a driver who is blocked while online is taken offline.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/driver_eligibility.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000186a1') on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000186a1') on conflict do nothing;
insert into public.partners (id, auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000186b1', '00000000-0000-0000-0000-0000000186a1', 'Dina', '+60110000186', 'approved');
insert into public.vehicle (id, plate, auth_user_id, owner_partner_id, status) values
  ('00000000-0000-0000-0000-0000000186c1', 'TST1861', '00000000-0000-0000-0000-0000000186a1',
   '00000000-0000-0000-0000-0000000186b1', 'unapproved'),
  ('00000000-0000-0000-0000-0000000186c2', 'TST1862', '00000000-0000-0000-0000-0000000186a1',
   '00000000-0000-0000-0000-0000000186b1', 'approved');

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000186a1');
select pg_temp.refused(
  $q$select public.claim_vehicle('00000000-0000-0000-0000-0000000186c1', '00000000-0000-0000-0000-0000000186a1')$q$,
  'driving a vehicle still waiting for approval');
select public.claim_vehicle('00000000-0000-0000-0000-0000000186c2', '00000000-0000-0000-0000-0000000186a1');
select public.set_driver_presence(true, 3.15, 101.71);
reset role;

do $$
begin
  if not (select online from public.driver_presence where profile_id = '00000000-0000-0000-0000-0000000186a1') then
    raise exception 'FAILED: the approved driver is not online';
  end if;
end $$;

-- The admin blocks the driver: offline at once.
update public.partners set status = 'blocked' where id = '00000000-0000-0000-0000-0000000186b1';
do $$
begin
  if (select online from public.driver_presence where profile_id = '00000000-0000-0000-0000-0000000186a1') then
    raise exception 'FAILED: a blocked driver stayed online';
  end if;
end $$;

select 'driver_eligibility: all passed';
rollback;
