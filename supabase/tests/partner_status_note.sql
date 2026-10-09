-- ============================================================================
-- Regression test for migration 0118: the admin's reason is the admin's, and
-- only a rejected partner can send their own application back for review.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/partner_status_note.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000118a1'),  -- the rejected partner
  ('00000000-0000-0000-0000-0000000118a2')   -- a blocked one
on conflict do nothing;

insert into public.partners (id, auth_user_id, name, phone, status, status_note) values
  ('00000000-0000-0000-0000-0000000118b1', '00000000-0000-0000-0000-0000000118a1', 'Ali', '+60110000118', 'rejected',
   'Your permit photo is unreadable.'),
  ('00000000-0000-0000-0000-0000000118b2', '00000000-0000-0000-0000-0000000118a2', 'Bob', '+60110000119', 'blocked',
   'Repeated complaints.');

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

do $$
begin
  if has_function_privilege('anon', 'public.partner_request_review()', 'execute') then
    raise exception 'FAILED: anon can call partner_request_review';
  end if;
end $$;

set local role authenticated;

-- 1. The partner reads the reason but cannot rewrite it or their status ---------
select pg_temp.as_user('00000000-0000-0000-0000-0000000118a1');
select pg_temp.refused(
  $q$update public.partners set status_note = null where id = '00000000-0000-0000-0000-0000000118b1'$q$,
  'a partner clearing the admin''s reason');
select pg_temp.refused(
  $q$update public.partners set status = 'unapproved' where id = '00000000-0000-0000-0000-0000000118b1'$q$,
  'a partner changing their own status');

-- 2. A rejected partner sends the application back once ------------------------
do $$
declare p public.partners;
begin
  p := public.partner_request_review();
  if p.status <> 'unapproved' or p.resubmitted_at is null then
    raise exception 'FAILED: review not requested: % %', p.status, p.resubmitted_at;
  end if;
end $$;
select pg_temp.refused($q$select public.partner_request_review()$q$, 'asking again while under review');

-- 3. A blocked partner cannot ---------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000118a2');
select pg_temp.refused($q$select public.partner_request_review()$q$, 'a blocked partner asking for review');

reset role;
do $$
begin
  if (select status from public.partners where id = '00000000-0000-0000-0000-0000000118b2') <> 'blocked' then
    raise exception 'FAILED: the blocked partner was moved';
  end if;
end $$;

rollback;
