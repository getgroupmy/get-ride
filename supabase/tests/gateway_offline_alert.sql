-- ============================================================================
-- Regression test for migration 0178: an SMS gateway phone that stops
-- checking in is reported to the admins once, and once more when it is back.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/gateway_offline_alert.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- (No Vault secret in CI, so each push is a no-op; the count is what would
-- have gone out.)
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000178a1'),
  ('00000000-0000-0000-0000-0000000178a2'),
  ('00000000-0000-0000-0000-0000000178a3')
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000178%'
on conflict do nothing;
delete from public.admin_access;
-- a1 has full access, a2 the SMS page; a3 another page only.
insert into public.admin_access (profile_id, page) values
  ('00000000-0000-0000-0000-0000000178a1', '*'),
  ('00000000-0000-0000-0000-0000000178a2', 'admin-settings-messaging'),
  ('00000000-0000-0000-0000-0000000178a3', 'admin-settings-api-keys');

insert into public.messaging_devices (id, user_id, device_id, kind, capabilities, label, last_seen_at) values
  ('00000000-0000-0000-0000-0000000178d1', '00000000-0000-0000-0000-0000000178a1', 'gw-1', 'gateway', '{sms}', 'S25', now()),
  ('00000000-0000-0000-0000-0000000178d2', '00000000-0000-0000-0000-0000000178a1', 'gw-2', 'gateway', '{sms}', 'Spare', now() - interval '3 days');
delete from public.messaging_routes;
-- d1 carries OTP; d2 is on no route, so its outage is nobody's concern.
insert into public.messaging_routes (channel, direction, transport, device_ids, enabled)
values ('otp', 'outbound', 'sms', array['00000000-0000-0000-0000-0000000178d1'::uuid], true);

do $$
declare
  n int;
begin
  if (select count(*) from public.gateway_alert_admins()) <> 2 then
    raise exception 'only admins with SMS / WhatsApp or full access are told';
  end if;

  n := public.gateway_offline_check(now());
  if n <> 0 then raise exception 'a phone that just checked in is not offline: % pushes', n; end if;

  n := public.gateway_offline_check(now() + interval '6 minutes');
  if n <> 2 then raise exception 'offline: one push per admin, got %', n; end if;
  if (select offline_alerted_at from public.messaging_devices where id = '00000000-0000-0000-0000-0000000178d1') is null then
    raise exception 'the outage is remembered';
  end if;
  if (select offline_alerted_at from public.messaging_devices where id = '00000000-0000-0000-0000-0000000178d2') is not null then
    raise exception 'a phone on no route is not reported';
  end if;

  n := public.gateway_offline_check(now() + interval '7 minutes');
  if n <> 0 then raise exception 'still offline: no second push, got %', n; end if;

  update public.messaging_devices set last_seen_at = now() + interval '8 minutes'
   where id = '00000000-0000-0000-0000-0000000178d1';
  n := public.gateway_offline_check(now() + interval '8 minutes');
  if n <> 2 then raise exception 'back online: one push per admin, got %', n; end if;
  if (select offline_alerted_at from public.messaging_devices where id = '00000000-0000-0000-0000-0000000178d1') is not null then
    raise exception 'back online clears the outage';
  end if;

  -- A switched-off route is not watched.
  update public.messaging_routes set enabled = false;
  n := public.gateway_offline_check(now() + interval '20 minutes');
  if n <> 0 then raise exception 'a switched-off route is not watched, got %', n; end if;

  if has_function_privilege('authenticated', 'public.gateway_offline_check(timestamptz)', 'execute')
     or has_function_privilege('anon', 'public.gateway_offline_check(timestamptz)', 'execute')
     or has_function_privilege('authenticated', 'public.gateway_alert_admins()', 'execute') then
    raise exception 'the check must not be callable by clients';
  end if;
end
$$;

rollback;
