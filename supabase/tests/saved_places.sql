-- ============================================================================
-- Regression test for migration 0116: saved places are the owner's alone.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/saved_places.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000116a1'),  -- owner
  ('00000000-0000-0000-0000-0000000116a2')   -- somebody else
on conflict do nothing;

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

-- 1. The owner saves Home and an other place; a second Home is refused -------
select pg_temp.as_user('00000000-0000-0000-0000-0000000116a1');
insert into public.saved_places (kind, name, address, lat, lng, entrance)
values ('home', 'Home', '25, Jalan Eco Majestic 1/2C', 2.93, 101.83, 'Gate B'),
       ('other', 'KLCC', 'KLCC', 3.158, 101.712, '');
select pg_temp.refused(
  $q$insert into public.saved_places (kind, name, lat, lng) values ('home', 'Home 2', 3, 101)$q$,
  'a second Home');
select pg_temp.refused(
  $q$insert into public.saved_places (user_id, kind, name, lat, lng)
     values ('00000000-0000-0000-0000-0000000116a2', 'other', 'Theirs', 3, 101)$q$,
  'saving a place for somebody else');
do $$
begin
  if (select count(*) from public.saved_places) <> 2 then
    raise exception 'FAILED: the owner should see their two places';
  end if;
end $$;

-- 2. Somebody else sees, changes and deletes none of them --------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000116a2');
do $$
begin
  if (select count(*) from public.saved_places) <> 0 then
    raise exception 'FAILED: another account can see the owner''s places';
  end if;
end $$;
update public.saved_places set name = 'Mine now';
delete from public.saved_places;

select pg_temp.as_user('00000000-0000-0000-0000-0000000116a1');
do $$
begin
  if (select count(*) from public.saved_places where name in ('Home', 'KLCC')) <> 2 then
    raise exception 'FAILED: another account changed or deleted the owner''s places';
  end if;
end $$;

rollback;
