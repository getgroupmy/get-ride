-- ============================================================================
-- Regression test for migration 0223 (part 1): a sub-admin writes only what
-- their pages edit.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/admin_page_scope.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000223a1'),  -- sub-admin, READ on IP access
  ('00000000-0000-0000-0000-0000000223a2'),  -- sub-admin, EDIT on IP access
  ('00000000-0000-0000-0000-0000000223a3'),  -- sub-admin, EDIT on the Settings hub
  ('00000000-0000-0000-0000-0000000223a4'),  -- full admin
  ('00000000-0000-0000-0000-0000000223b1')   -- a rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000223%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000223a1', 'admin-settings-ip-access', 'read'),
  ('00000000-0000-0000-0000-0000000223a2', 'admin-settings-ip-access', 'edit'),
  ('00000000-0000-0000-0000-0000000223a3', 'admin-settings', 'edit'),
  ('00000000-0000-0000-0000-0000000223a4', '*', 'edit')
on conflict do nothing;

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
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text)
  to authenticated;

set local role authenticated;

-- 1. Read on a page writes nothing ----------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000223a1');
select pg_temp.refused($q$insert into public.ip_access_rules (ip_address, list_type) values ('198.51.100.1', 'blacklist')$q$,
  'a read-only sub-admin writing their own page''s table');
select pg_temp.refused($q$insert into public.app_settings (key, value) values ('test_0223', '1')$q$,
  'a read-only sub-admin writing app settings');

-- 2. Edit on a page writes that page's table, and nothing else --------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000223a2');
insert into public.ip_access_rules (ip_address, list_type) values ('198.51.100.2', 'blacklist');
select pg_temp.check((select count(*) = 1 from public.ip_access_rules where ip_address = '198.51.100.2'),
  'the edit sub-admin writes their own page''s table');
select pg_temp.refused($q$insert into public.app_settings (key, value) values ('test_0223', '1')$q$,
  'an IP-access sub-admin writing app settings');
select pg_temp.refused($q$insert into public.messaging_routes (channel, direction, transport) values ('otp', 'outbound', 'sms')$q$,
  'an IP-access sub-admin writing a messaging route');
select pg_temp.refused($q$update public.settings_entries set position = position where true$q$,
  'an IP-access sub-admin writing settings entries');
select pg_temp.refused($q$insert into storage.objects (bucket_id, name) values ('app-branding', 'x-0223.png')$q$,
  'an IP-access sub-admin uploading branding');
select pg_temp.refused($q$select public.wallet_topup('00000000-0000-0000-0000-0000000223b1', 100)$q$,
  'a sub-admin topping up a wallet');
select pg_temp.refused($q$select public.set_sign_in_config('{"oneDevice": false}')$q$,
  'a sub-admin changing the sign-in switches');
select pg_temp.refused($q$select public.set_ride_privacy_config('{}')$q$,
  'a sub-admin changing another page''s settings');
select pg_temp.refused($q$select public.admin_sign_out_everywhere('00000000-0000-0000-0000-0000000223b1')$q$,
  'a sub-admin signing a user out everywhere');

-- 3. The Settings hub grant edits settings pages, as the panel does -----------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000223a3');
insert into public.ip_access_rules (ip_address, list_type) values ('198.51.100.3', 'blacklist');
select pg_temp.check((select count(*) = 1 from public.ip_access_rules where ip_address = '198.51.100.3'),
  'the Settings hub editor writes a settings page''s table');
select pg_temp.refused($q$select public.wallet_topup('00000000-0000-0000-0000-0000000223b1', 100)$q$,
  'the Settings hub editor topping up a wallet');
select pg_temp.refused($q$update public.profiles set name = 'X' where id = '00000000-0000-0000-0000-0000000223b1'$q$,
  'the Settings hub editor editing a user');

-- 4. A full admin still writes everything ---------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000223a4');
insert into public.app_settings (key, value) values ('test_0223', '1');
insert into public.messaging_routes (channel, direction, transport) values ('marketing', 'inbound', 'sms')
on conflict (channel, direction) do update set enabled = excluded.enabled;
select pg_temp.check((select count(*) = 1 from public.app_settings where key = 'test_0223'),
  'a full admin writes app settings');
select pg_temp.check(public.caller_admin_can_write('rpc:wallet_topup'), 'a full admin may top up');

-- 5. A rider's own rows are as before ------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000223b1');
insert into public.emergency_contacts (profile_id, name, phone)
values ('00000000-0000-0000-0000-0000000223b1', 'Mum', '+60120000223');
select pg_temp.refused($q$insert into public.emergency_contacts (profile_id, name, phone)
  values ('00000000-0000-0000-0000-0000000223a4', 'Stranger', '+60120000224')$q$,
  'a rider writing someone else''s contacts');
select pg_temp.check(not public.caller_admin_can_write('ip_access_rules'), 'a rider is no admin');
reset role;

-- 6. Nothing writes on caller_is_admin() alone any more ----------------------------------------
do $$
declare bad text;
begin
  select string_agg(format('%s.%s "%s" (%s)', schemaname, tablename, policyname, cmd), '; ')
    into bad
    from pg_policies
   where (schemaname = 'public' or (schemaname = 'storage' and tablename = 'objects'))
     and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
     and (coalesce(qual, '') ~ 'caller_is_admin\(\)' or coalesce(with_check, '') ~ 'caller_is_admin\(\)');
  if bad is not null then
    raise exception 'FAILED: write policies still allow any admin: %', bad;
  end if;

  select string_agg(p.proname, ', ')
    into bad
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname = any (array[
       'admin_sign_out_everywhere', 'claim_vehicle', 'device_guard_set_config', 'fare_ai_reset_cooldown',
       'messaging_heartbeat', 'release_vehicle', 'set_map_config', 'set_permission_rules', 'set_pin_policy',
       'set_ride_cancel_request_config', 'set_ride_privacy_config', 'set_scheduled_rides_config',
       'set_sign_in_config', 'set_sos_ops_config', 'set_trip_handover_config', 'sos_acknowledge',
       'sos_resolve', 'touch_vehicle_session', 'wallet_topup'])
     and p.prosrc like '%caller_is_admin()%';
  if bad is not null then
    raise exception 'FAILED: admin RPCs still allow any admin: %', bad;
  end if;

  -- A table whose writes nobody's page covers is for full admins only: say so.
  select string_agg(distinct t, ', ')
    into bad
    from (select (regexp_matches(coalesce(qual, '') || ' ' || coalesce(with_check, ''),
                                 'caller_admin_can_write\(''([^'']+)''', 'g'))[1] as t
            from pg_policies) x
   where not exists (select 1 from public.admin_table_pages m where m.target = x.t);
  if bad is not null then
    raise notice 'admin_page_scope: written by full admins only (no page mapped): %', bad;
  end if;
end $$;

select 'admin_page_scope: all passed';
rollback;
