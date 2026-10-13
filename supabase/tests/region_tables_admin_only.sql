-- ============================================================================
-- Regression test: the admin's region tables (countries, states, cities,
-- suburbs) can be read by anyone but written only by admins. Their rows set
-- pricing (whole fares, tax), bidding, services and Block, so an open write
-- would let any app key change fares or block a country.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/region_tables_admin_only.sql
--
-- Runs in one transaction and rolls back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000170a1'),
  ('00000000-0000-0000-0000-0000000170a2')
on conflict do nothing;
insert into public.profiles (id, phone) values
  ('00000000-0000-0000-0000-0000000170a1', '+60100000171'),
  ('00000000-0000-0000-0000-0000000170a2', '+60100000172')
on conflict (id) do nothing;
insert into public.admin_access (profile_id, page, access_level)
values ('00000000-0000-0000-0000-0000000170a1', '*', 'edit');

insert into public.countries (name, values) values ('Regionland', '{"wholeFare": true}');
insert into public.states (country, name) values ('Regionland', 'North');

-- Runs p_sql as p_role (and, for authenticated, as p_uid); true when it
-- changed at least one row, false when RLS filtered it out or refused it.
create or replace function pg_temp.writes(p_role text, p_uid uuid, p_sql text) returns boolean
language plpgsql as $$
declare n integer := 0;
begin
  perform set_config('request.jwt.claims',
    case when p_uid is null then json_build_object('role', p_role)::text
         else json_build_object('sub', p_uid, 'role', p_role)::text end, true);
  execute format('set local role %I', p_role);
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when insufficient_privilege or check_violation then
    n := 0;
  end;
  reset role;
  return n > 0;
end;
$$;

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;

-- Anyone reads.
select set_config('request.jwt.claims', '{"role":"anon"}', true);
set local role anon;
select pg_temp.check((select count(*) from public.countries where name = 'Regionland') = 1, 'anon can read regions');
reset role;

-- Nobody but an admin writes, in any of the four tables.
do $$
declare
  who record;
begin
  for who in
    select * from (values ('anon', null::uuid), ('authenticated', '00000000-0000-0000-0000-0000000170a2'::uuid)) v(r, uid)
  loop
    if pg_temp.writes(who.r, who.uid, $q$update public.countries set values = '{"wholeFare": false}' where name = 'Regionland'$q$) then
      raise exception 'FAILED: % changed a country', who.r;
    end if;
    if pg_temp.writes(who.r, who.uid, $q$insert into public.countries (name) values ('Fakeland')$q$) then
      raise exception 'FAILED: % added a country', who.r;
    end if;
    if pg_temp.writes(who.r, who.uid, $q$delete from public.states where country = 'Regionland'$q$) then
      raise exception 'FAILED: % deleted a state', who.r;
    end if;
    if pg_temp.writes(who.r, who.uid, $q$insert into public.cities (country, state, name) values ('Regionland', 'North', 'X')$q$) then
      raise exception 'FAILED: % added a city', who.r;
    end if;
    if pg_temp.writes(who.r, who.uid, $q$insert into public.suburbs (country, state, city, name) values ('Regionland', 'North', 'X', 'Y')$q$) then
      raise exception 'FAILED: % added a suburb', who.r;
    end if;
  end loop;
end $$;

select pg_temp.check((select values->>'wholeFare' = 'true' from public.countries where name = 'Regionland'),
  'the country''s pricing survived');

-- An admin does.
select pg_temp.check(
  pg_temp.writes('authenticated', '00000000-0000-0000-0000-0000000170a1',
    $q$update public.countries set values = '{"wholeFare": false}' where name = 'Regionland'$q$),
  'an admin can edit a country');
select pg_temp.check(
  pg_temp.writes('authenticated', '00000000-0000-0000-0000-0000000170a1',
    $q$delete from public.states where country = 'Regionland'$q$),
  'an admin can delete a state');

rollback;

select 'region_tables_admin_only: all passed';
