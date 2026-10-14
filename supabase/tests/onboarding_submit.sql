-- ============================================================================
-- Regression test for migration 0181: a partner submits their application
-- and their vehicle (documents_ok false -> true) while it waits for review,
-- and nothing more: not someone else's, not after approval, not back.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/onboarding_submit.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000181a1'),  -- the applicant
  ('00000000-0000-0000-0000-0000000181a2'),  -- an approved partner
  ('00000000-0000-0000-0000-0000000181a3')   -- someone else
on conflict do nothing;

insert into public.partners (id, auth_user_id, name, phone, status, documents_ok) values
  ('00000000-0000-0000-0000-0000000181b1', '00000000-0000-0000-0000-0000000181a1', 'Ali', '+60110000181', 'unapproved', false),
  ('00000000-0000-0000-0000-0000000181b2', '00000000-0000-0000-0000-0000000181a2', 'Bob', '+60110000182', 'approved', false);

insert into public.vehicle (id, plate, auth_user_id, owner_partner_id, status, documents_ok) values
  ('00000000-0000-0000-0000-0000000181c1', 'TST1811', '00000000-0000-0000-0000-0000000181a1',
   '00000000-0000-0000-0000-0000000181b1', 'unapproved', false),
  ('00000000-0000-0000-0000-0000000181c2', 'TST1812', '00000000-0000-0000-0000-0000000181a2',
   '00000000-0000-0000-0000-0000000181b2', 'approved', false);

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

-- Refused, or silently matched no row (RLS): either way nothing changed.
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
declare n integer;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    return;
  end;
  if n > 0 then
    raise exception 'FAILED: % was allowed', p_what;
  end if;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

set local role authenticated;

-- 1. Someone else can't submit the applicant's rows ----------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000181a3');
select pg_temp.refused(
  $q$update public.partners set documents_ok = true where id = '00000000-0000-0000-0000-0000000181b1'$q$,
  'submitting someone else''s application');
select pg_temp.refused(
  $q$update public.vehicle set documents_ok = true where id = '00000000-0000-0000-0000-0000000181c1'$q$,
  'submitting someone else''s vehicle');

-- 2. The applicant submits both -------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000181a1');
update public.partners set documents_ok = true where id = '00000000-0000-0000-0000-0000000181b1';
update public.vehicle set documents_ok = true where id = '00000000-0000-0000-0000-0000000181c1';

-- ...but can't take it back, or approve themselves on the way.
select pg_temp.refused(
  $q$update public.partners set documents_ok = false where id = '00000000-0000-0000-0000-0000000181b1'$q$,
  'un-submitting an application');
select pg_temp.refused(
  $q$update public.vehicle set documents_ok = false where id = '00000000-0000-0000-0000-0000000181c1'$q$,
  'un-submitting a vehicle');
select pg_temp.refused(
  $q$update public.partners set status = 'approved' where id = '00000000-0000-0000-0000-0000000181b1'$q$,
  'a partner approving themselves');
select pg_temp.refused(
  $q$update public.vehicle set status = 'approved' where id = '00000000-0000-0000-0000-0000000181c1'$q$,
  'a partner approving their vehicle');

-- 3. An approved partner can't set it: it is the admin's once reviewed --------
select pg_temp.as_user('00000000-0000-0000-0000-0000000181a2');
select pg_temp.refused(
  $q$update public.partners set documents_ok = true where id = '00000000-0000-0000-0000-0000000181b2'$q$,
  'an approved partner setting documents_ok');
select pg_temp.refused(
  $q$update public.vehicle set documents_ok = true where id = '00000000-0000-0000-0000-0000000181c2'$q$,
  'documents_ok on an approved vehicle');

-- 4. A new row still can't start submitted --------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000181a3');
select pg_temp.refused(
  $q$insert into public.partners (auth_user_id, name, phone, status, documents_ok)
     values ('00000000-0000-0000-0000-0000000181a3', 'Cat', '+60110000183', 'unapproved', true)$q$,
  'inserting a partner already submitted');

reset role;
do $$
begin
  if not (select documents_ok from public.partners where id = '00000000-0000-0000-0000-0000000181b1') then
    raise exception 'FAILED: the application was not submitted';
  end if;
  if not (select documents_ok from public.vehicle where id = '00000000-0000-0000-0000-0000000181c1') then
    raise exception 'FAILED: the vehicle was not submitted';
  end if;
  if (select status from public.partners where id = '00000000-0000-0000-0000-0000000181b1') <> 'unapproved' then
    raise exception 'FAILED: the applicant''s status moved';
  end if;
  if (select documents_ok from public.partners where id = '00000000-0000-0000-0000-0000000181b2')
     or (select documents_ok from public.vehicle where id = '00000000-0000-0000-0000-0000000181c2') then
    raise exception 'FAILED: an approved row was changed';
  end if;
end $$;

rollback;
