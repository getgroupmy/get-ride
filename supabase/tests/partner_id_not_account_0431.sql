-- ============================================================================
-- Regression test for migration 0431: a partner row's id cannot be an account
-- id.
--   * a signed-in user creates their own partner row with a new id, as the app
--     does, and the row keeps the id that was sent;
--   * the same insert is refused when the id is another account's id, or the
--     user's own, whichever way it is sent;
--   * a row's id cannot be changed to an account's id: its owner cannot change
--     it at all (the column guard, 0185), and an admin who may only read
--     partners is refused by 0431, on an insert and on a change of id alike;
--   * the back office (an admin who may edit partners) and the server's own
--     writes are not checked.
-- All names are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/partner_id_not_account_0431.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000431a1'),  -- applies to be a partner
  ('00000000-0000-0000-0000-0000000431b1'),  -- another account
  ('00000000-0000-0000-0000-0000000431b2'),  -- and another
  ('00000000-0000-0000-0000-0000000431c1'),  -- back office: may edit partners
  ('00000000-0000-0000-0000-0000000431c2')   -- back office: may only read them
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000431%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000431c1', 'admin-partners', 'edit'),
  ('00000000-0000-0000-0000-0000000431c2', 'admin-partners', 'read')
on conflict do nothing;

-- Partner sign-up open, as shipped.
insert into public.admin_display_settings (id, settings) values ('global', '{}'::jsonb)
on conflict (id) do update set settings = public.admin_display_settings.settings
  - 'registrationEnabled' - 'passengerRegistrationEnabled' - 'driverRegistrationEnabled';

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

-- [p_sql] must be refused, and with [p_error]: a refusal for any other reason
-- (a policy, another guard) is not the rule under test.
create or replace function pg_temp.refused(p_sql text, p_error text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm = p_error then
      return;
    end if;
    raise exception 'FAILED: % was refused with "%", not "%"', p_what, sqlerrm, p_error;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text, text) to authenticated;

set local role authenticated;

-- 1. A new partner row, as the app makes it: its own new id ------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000431a1');
with made as (
  insert into public.partners (id, auth_user_id, name, phone, status)
  values ('00000000-0000-0000-0000-0000000431d1', auth.uid(), 'Test Partner 0431', '+60100004311', 'unapproved')
  returning id, auth_user_id, status)
select pg_temp.check((select count(*) = 1 from made
                       where id = '00000000-0000-0000-0000-0000000431d1'
                         and auth_user_id = '00000000-0000-0000-0000-0000000431a1'
                         and status = 'unapproved'),
  'a signed-in user creates their own partner row, and it keeps the id that was sent');
-- The owner goes on filling it in: by an update, or by sending the row again
-- with its own id (an upsert names every column it sends, the id too).
update public.partners set address = '1 Jalan Ujian' where id = '00000000-0000-0000-0000-0000000431d1';
insert into public.partners (id, auth_user_id, name, phone, status, email)
values ('00000000-0000-0000-0000-0000000431d1', auth.uid(), 'Test Partner 0431', '+60100004311', 'unapproved',
        'partner0431@example.com')
on conflict (id) do update set id = excluded.id, email = excluded.email;
select pg_temp.check((select address = '1 Jalan Ujian' and email = 'partner0431@example.com' from public.partners
                       where id = '00000000-0000-0000-0000-0000000431d1'),
  'the owner still edits the row they made, and sending it again with its own id is not a change of id');

-- 2. A new row whose id is an account's id is refused ------------------------------------------
select pg_temp.refused($q$insert into public.partners (id, auth_user_id, name, phone, status)
  values ('00000000-0000-0000-0000-0000000431b1', auth.uid(), 'Test Partner 0431', '+60100004311', 'unapproved')$q$,
  'PARTNERS_ID_IS_ACCOUNT_ID', 'a partner row whose id is another account''s id');
select pg_temp.refused($q$insert into public.partners (id, auth_user_id, name, phone, status)
  values (auth.uid(), auth.uid(), 'Test Partner 0431', '+60100004311', 'unapproved')$q$,
  'PARTNERS_ID_IS_ACCOUNT_ID', 'a partner row whose id is the user''s own account id');
select pg_temp.refused($q$insert into public.partners (id, auth_user_id, name, phone, status)
  values ('00000000-0000-0000-0000-0000000431b1', auth.uid(), 'Test Partner 0431', '+60100004311', 'unapproved')
  on conflict (id) do update set name = excluded.name$q$,
  'PARTNERS_ID_IS_ACCOUNT_ID', 'the same row sent as an upsert');
select pg_temp.refused($q$insert into public.partners (id, auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000431d2', auth.uid(), 'Test Partner 0431', '+60100004311', 'unapproved'),
  ('00000000-0000-0000-0000-0000000431b2', auth.uid(), 'Test Partner 0431', '+60100004311', 'unapproved')$q$,
  'PARTNERS_ID_IS_ACCOUNT_ID', 'an account''s id among several rows sent at once');

-- 3. A row's id cannot be changed to an account's id --------------------------------------------
-- Its owner cannot change it at all: the column guard (0185) answers first.
select pg_temp.refused($q$update public.partners set id = '00000000-0000-0000-0000-0000000431b1'
  where id = '00000000-0000-0000-0000-0000000431d1'$q$,
  'PARTNERS_PROTECTED_COLUMN:id', 'the owner changing their row''s id to an account''s id');
select pg_temp.refused($q$insert into public.partners (id, auth_user_id, name, phone, status)
  values ('00000000-0000-0000-0000-0000000431d1', auth.uid(), 'Test Partner 0431', '+60100004311', 'unapproved')
  on conflict (id) do update set id = '00000000-0000-0000-0000-0000000431b1'$q$,
  'PARTNERS_PROTECTED_COLUMN:id', 'the owner changing it through an upsert of the row');

-- An admin who may only read partners is not the back office here: their own
-- row, made like anybody's, and checked by 0431 like anybody's.
select pg_temp.as_user('00000000-0000-0000-0000-0000000431c2');
insert into public.partners (id, auth_user_id, name, phone, status)
values ('00000000-0000-0000-0000-0000000431d3', auth.uid(), 'Read Only 0431', '+60100004314', 'unapproved');
select pg_temp.refused($q$insert into public.partners (id, auth_user_id, name, phone, status)
  values ('00000000-0000-0000-0000-0000000431b1', auth.uid(), 'Read Only 0431', '+60100004314', 'unapproved')$q$,
  'PARTNERS_ID_IS_ACCOUNT_ID', 'an admin who may only read partners creating a row under an account''s id');
select pg_temp.refused($q$update public.partners set id = '00000000-0000-0000-0000-0000000431b1'
  where id = '00000000-0000-0000-0000-0000000431d3'$q$,
  'PARTNERS_ID_IS_ACCOUNT_ID', 'an admin who may only read partners changing their row''s id to an account''s id');
select pg_temp.refused($q$update public.partners set id = auth.uid()
  where id = '00000000-0000-0000-0000-0000000431d3'$q$,
  'PARTNERS_ID_IS_ACCOUNT_ID', 'or to their own account id');
select pg_temp.refused($q$insert into public.partners (id, auth_user_id, name, phone, status)
  values ('00000000-0000-0000-0000-0000000431d3', auth.uid(), 'Read Only 0431', '+60100004314', 'unapproved')
  on conflict (id) do update set id = '00000000-0000-0000-0000-0000000431b1'$q$,
  'PARTNERS_ID_IS_ACCOUNT_ID', 'or through an upsert of the row');

-- 4. The back office writes as before ------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000431c1');
insert into public.partners (id, auth_user_id, name, phone, status)
values ('00000000-0000-0000-0000-0000000431b1', '00000000-0000-0000-0000-0000000431b1', 'Back Office 0431',
        '+60100004312', 'unapproved');
reset role;
select pg_temp.check((select count(*) = 1 from public.partners
                       where id = '00000000-0000-0000-0000-0000000431b1'
                         and auth_user_id = '00000000-0000-0000-0000-0000000431b1'),
  'an admin who may edit partners writes as before');

-- 5. The server's own writes are not checked ----------------------------------------------------
-- A direct session (migrations, cron, the SQL editor): no role, nobody signed in ...
select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
insert into public.partners (id, auth_user_id, name, phone, status)
values ('00000000-0000-0000-0000-0000000431b2', '00000000-0000-0000-0000-0000000431b2', 'Server 0431',
        '+60100004313', 'unapproved');
delete from public.partners where id = '00000000-0000-0000-0000-0000000431b2';
-- ... and the service role (edge functions).
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true), set_config('request.jwt.claim.sub', '', true);
insert into public.partners (id, auth_user_id, name, phone, status)
values ('00000000-0000-0000-0000-0000000431b2', '00000000-0000-0000-0000-0000000431b2', 'Server 0431',
        '+60100004313', 'unapproved');
reset role;
select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
select pg_temp.check((select count(*) = 1 from public.partners
                       where id = '00000000-0000-0000-0000-0000000431b2'),
  'the server writes as before');

-- 6. What the refused writes left behind: nothing -----------------------------------------------
select pg_temp.check((select count(*) = 1 and bool_and(p.id = '00000000-0000-0000-0000-0000000431d1')
                        from public.partners p
                       where p.auth_user_id = '00000000-0000-0000-0000-0000000431a1'),
  'the applicant has the one row they made, under its own id');
select pg_temp.check((select count(*) = 1 and bool_and(p.id = '00000000-0000-0000-0000-0000000431d3')
                        from public.partners p
                       where p.auth_user_id = '00000000-0000-0000-0000-0000000431c2'),
  'so has the admin who may only read partners');
select pg_temp.check((select count(*) = 0 from public.partners
                       where id = '00000000-0000-0000-0000-0000000431d2'),
  'a statement with one refused row keeps none of its rows');

-- 7. The guard is the table's own: not something the apps call ----------------------------------
select pg_temp.check(not has_function_privilege('anon', 'public.partners_guard_id()', 'execute')
                     and not has_function_privilege('authenticated', 'public.partners_guard_id()', 'execute'),
  'partners_guard_id is not open to anon or authenticated');
select pg_temp.check(exists (select 1 from pg_trigger t
                              where t.tgrelid = 'public.partners'::regclass
                                and t.tgname = 'trg_partners_a_guard_id' and t.tgenabled = 'O'),
  'the guard is on the table and enabled');

rollback;

select 'partner_id_not_account_0431: all passed';
