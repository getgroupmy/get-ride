-- ============================================================================
-- Regression test for migration 0133: support_agents() answers admins only.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/support_agents_admin_only.sql
--
-- Runs in one transaction and rolls back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000000b1'),
  ('00000000-0000-0000-0000-0000000000b2')
on conflict do nothing;
insert into public.profiles (id, phone) values
  ('00000000-0000-0000-0000-0000000000b1', '+60100000001'),
  ('00000000-0000-0000-0000-0000000000b2', '+60100000002')
on conflict (id) do nothing;
insert into public.admin_access (profile_id, page, access_level)
values ('00000000-0000-0000-0000-0000000000b1', '*', 'edit');

create or replace function pg_temp.agents_as(p_uid uuid) returns integer
language plpgsql as $$
declare n integer;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into n from public.support_agents();
  reset role;
  return n;
end;
$$;

do $$
begin
  if pg_temp.agents_as('00000000-0000-0000-0000-0000000000b1') < 1 then
    raise exception 'an admin should see the support roster';
  end if;
  if pg_temp.agents_as('00000000-0000-0000-0000-0000000000b2') <> 0 then
    raise exception 'a non-admin must get an empty support roster';
  end if;
end
$$;

select 'support_agents_admin_only: all passed';
rollback;
