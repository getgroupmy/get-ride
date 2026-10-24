-- ============================================================================
-- Regression test for migration 0286: Edit Partner › Change status. Only an
-- admin with EDIT on the Partners pages asks; one open request a partner; a
-- vehicle another driver is online with is refused up front; only the
-- partner themself answers; an answer after 2 minutes finds it expired; the
-- request and each result are in admin_audit_log; done leaves a line in the
-- driver's notifications; the push targets and "sent" are the service
-- role's only.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/partner_remote_actions_0286.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

do $$
begin
  if has_function_privilege('anon', 'public.partner_remote_action_request(uuid, text, uuid)', 'execute')
     or has_function_privilege('anon', 'public.partner_remote_action_report(uuid, text, text, text)', 'execute')
     or has_function_privilege('authenticated', 'public.partner_remote_action_targets(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.partner_remote_action_sent(uuid, integer)', 'execute')
     or has_function_privilege('authenticated', 'public.partner_remote_action_kick(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.partner_remote_actions_expire(uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.partner_remote_action_targets(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.partner_remote_action_request(uuid, text, uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.partner_remote_action_report(uuid, text, text, text)', 'execute')
     or not has_function_privilege('authenticated', 'public.partner_remote_action_status(uuid)', 'execute') then
    raise exception 'FAILED: partner remote action function grants';
  end if;
  if has_table_privilege('authenticated', 'public.partner_remote_actions', 'insert')
     or has_table_privilege('authenticated', 'public.partner_remote_actions', 'update') then
    raise exception 'FAILED: requests are written through the functions only';
  end if;
end
$$;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000286a1', '60128600001'),  -- full admin
  ('00000000-0000-0000-0000-0000000286a2', '60128600002'),  -- Partners edit
  ('00000000-0000-0000-0000-0000000286a3', '60128600003'),  -- Partners read
  ('00000000-0000-0000-0000-0000000286a4', '60128600004'),  -- another page, edit
  ('00000000-0000-0000-0000-0000000286d1', '60128600011'),  -- partner, offline
  ('00000000-0000-0000-0000-0000000286d2', '60128600012'),  -- partner online with v2
  ('00000000-0000-0000-0000-0000000286d3', '60128600013'),  -- partner offline with v3
  ('00000000-0000-0000-0000-0000000286d4', '60128600014'),  -- partner, for the vehicle links
  ('00000000-0000-0000-0000-0000000286f1', '60128600021')   -- a rider
on conflict do nothing;
insert into public.profiles (id, name, phone)
select id, 'PR ' || right(id::text, 2), '+' || phone from auth.users
 where id::text like '00000000-0000-0000-0000-0000000286%'
on conflict (id) do update set name = excluded.name, phone = excluded.phone;

insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000286a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000286a2', 'admin-partners', 'edit'),
  ('00000000-0000-0000-0000-0000000286a3', 'admin-partners', 'read'),
  ('00000000-0000-0000-0000-0000000286a4', 'admin-dashboard', 'edit')
on conflict do nothing;

insert into public.partners (id, auth_user_id, name, phone, status, plate) values
  ('00000000-0000-0000-0000-0000000286e1', '00000000-0000-0000-0000-0000000286d1', 'Hafiz', '60128600011', 'approved', null),
  ('00000000-0000-0000-0000-0000000286e2', '00000000-0000-0000-0000-0000000286d2', 'Siti', '60128600012', 'approved', 'PRA 2862'),
  ('00000000-0000-0000-0000-0000000286e3', '00000000-0000-0000-0000-0000000286d3', 'Kumar', '60128600013', 'approved', 'PRA 2863'),
  ('00000000-0000-0000-0000-0000000286e4', '00000000-0000-0000-0000-0000000286d4', 'Jason', '60128600014', 'approved', null);

insert into public.vehicle (id, plate, auth_user_id, status) values
  ('00000000-0000-0000-0000-0000000286b1', 'PRA 2861', '00000000-0000-0000-0000-0000000286d1', 'approved'),
  ('00000000-0000-0000-0000-0000000286b2', 'PRA 2862', '00000000-0000-0000-0000-0000000286d2', 'approved'),
  ('00000000-0000-0000-0000-0000000286b3', 'PRA 2863', '00000000-0000-0000-0000-0000000286d3', 'approved');
insert into public.vehicle_active_session (vehicle_id, user_id) values
  ('00000000-0000-0000-0000-0000000286b2', '00000000-0000-0000-0000-0000000286d2');

insert into public.driver_presence (profile_id, online, updated_at) values
  ('00000000-0000-0000-0000-0000000286d2', true, now()),
  ('00000000-0000-0000-0000-0000000286d3', false, now() - interval '1 hour')
on conflict (profile_id) do update set online = excluded.online, updated_at = excluded.updated_at;

insert into public.push_tokens (profile_id, token, platform) values
  ('00000000-0000-0000-0000-0000000286d1', 'pra286-d1-android', 'android'),
  ('00000000-0000-0000-0000-0000000286d1', 'ExponentPushToken[pra286]', 'android');

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
  if n > 0 or p_sql ilike 'select%' then
    raise exception 'FAILED: % was allowed', p_what;
  end if;
end $$;
create temporary table t_ids (k text primary key, id uuid);
grant all on t_ids to authenticated, service_role;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text)
  to authenticated, service_role;

set local role authenticated;

-- 1. Only an admin with EDIT on Partners asks -------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000286a3');
select pg_temp.refused($q$select public.partner_remote_action_request('00000000-0000-0000-0000-0000000286d1', 'go_online')$q$,
  'a Partners read-only admin asking');
select pg_temp.as_user('00000000-0000-0000-0000-0000000286a4');
select pg_temp.refused($q$select public.partner_remote_action_request('00000000-0000-0000-0000-0000000286d1', 'go_online')$q$,
  'an admin of another page asking');
select pg_temp.refused($q$select public.partner_remote_action_status('00000000-0000-0000-0000-0000000286d1')$q$,
  'an admin of another page reading the request');
select pg_temp.as_user('00000000-0000-0000-0000-0000000286f1');
select pg_temp.refused($q$select public.partner_remote_action_request('00000000-0000-0000-0000-0000000286d1', 'go_online')$q$,
  'a rider asking');
select pg_temp.as_user('00000000-0000-0000-0000-0000000286d1');
select pg_temp.refused($q$select public.partner_remote_action_request('00000000-0000-0000-0000-0000000286d1', 'go_online')$q$,
  'the partner asking for themself');

select pg_temp.as_user('00000000-0000-0000-0000-0000000286a2');
select pg_temp.refused($q$select public.partner_remote_action_request('00000000-0000-0000-0000-0000000286f1', 'go_online')$q$,
  'asking someone who is not a partner');
select pg_temp.refused($q$select public.partner_remote_action_request('00000000-0000-0000-0000-0000000286d1', 'start_trip')$q$,
  'an action the phone is never asked');
insert into t_ids
select 'online', (public.partner_remote_action_request('00000000-0000-0000-0000-0000000286d1', 'go_online') ->> 'id')::uuid;
select pg_temp.check((select public.partner_remote_action_status('00000000-0000-0000-0000-0000000286d1') ->> 'status') = 'queued',
  'the Partners edit admin''s request is queued');

-- 2. One open request a partner -------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000286a1');
select pg_temp.refused($q$select public.partner_remote_action_request('00000000-0000-0000-0000-0000000286d1', 'go_offline')$q$,
  'a second open request for the same partner');
select pg_temp.as_user('00000000-0000-0000-0000-0000000286a3');
select pg_temp.check((select public.partner_remote_action_status('00000000-0000-0000-0000-0000000286d1') ->> 'id')::uuid
                       = (select id from t_ids where k = 'online'),
  'a Partners read-only admin sees the request on the card');

-- 3. Vehicles: one another driver is online with is refused up front -----------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000286a2');
select pg_temp.refused($q$select public.partner_remote_action_request('00000000-0000-0000-0000-0000000286d4', 'link_vehicle',
  '00000000-0000-0000-0000-0000000286b2')$q$, 'linking a vehicle another driver is online with');
select pg_temp.refused($q$select public.partner_remote_action_request('00000000-0000-0000-0000-0000000286d4', 'link_vehicle',
  '00000000-0000-0000-0000-0000000286ff')$q$, 'linking a vehicle that does not exist');
select pg_temp.refused($q$select public.partner_remote_action_request('00000000-0000-0000-0000-0000000286d4', 'link_vehicle')$q$,
  'linking without a vehicle');
insert into t_ids
select 'link', (public.partner_remote_action_request('00000000-0000-0000-0000-0000000286d4', 'link_vehicle',
  '00000000-0000-0000-0000-0000000286b3') ->> 'id')::uuid;
select pg_temp.check((select id from t_ids where k = 'link') is not null,
  'a vehicle whose other driver is offline can be asked for');

-- 4. Only the partner themself answers ----------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000286d2');
select pg_temp.refused(format($q$select public.partner_remote_action_report(%L, 'done')$q$, (select id from t_ids where k = 'online')),
  'another partner answering');
select pg_temp.check(public.partner_remote_action_mine((select id from t_ids where k = 'online')) is null,
  'another partner does not read it');
select pg_temp.check((select count(*) from public.partner_remote_actions) = 0, 'another partner reads no rows');
select pg_temp.as_user('00000000-0000-0000-0000-0000000286a1');
select pg_temp.refused(format($q$select public.partner_remote_action_report(%L, 'done')$q$, (select id from t_ids where k = 'online')),
  'an admin answering for the phone');
select pg_temp.refused($q$insert into public.partner_remote_actions (profile_id, action)
  values ('00000000-0000-0000-0000-0000000286d1', 'go_online')$q$, 'an admin writing a request directly');

select pg_temp.as_user('00000000-0000-0000-0000-0000000286d1');
select pg_temp.check((public.partner_remote_action_mine() ->> 'action') = 'go_online', 'the partner reads their request');
select pg_temp.check((select count(*) from public.partner_remote_actions) = 1, 'the partner reads their own row');
select public.partner_remote_action_seen((select id from t_ids where k = 'online'), true);
select pg_temp.check((select public.partner_remote_action_mine() ->> 'waiting_driver')::boolean,
  'the phone waits for the driver''s tap');
select pg_temp.check(
  (public.partner_remote_action_report((select id from t_ids where k = 'online'), 'refused',
     'Before you can go online, please update the following: Driving licence') ->> 'status') = 'refused',
  'the partner refuses with the reason');
select pg_temp.check(
  (public.partner_remote_action_report((select id from t_ids where k = 'online'), 'done') ->> 'status') = 'refused',
  'an answered request keeps its first answer');
select pg_temp.check(public.partner_remote_action_mine() is null, 'nothing open after the answer');

select pg_temp.as_user('00000000-0000-0000-0000-0000000286d4');
select pg_temp.check(
  (public.partner_remote_action_report((select id from t_ids where k = 'link'), 'done', null, '3:12 PM') ->> 'status') = 'done',
  'the partner did it');
select pg_temp.check((select body = 'Support linked your vehicle at 3:12 PM.' and mode = 'partner'
                        from public.user_notifications
                       where profile_id = '00000000-0000-0000-0000-0000000286d4' and kind = 'partner_remote_action'),
  'done leaves a line in the driver''s notifications');

-- 5. The push: targets and "sent" are the service role's -----------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000286a2');
insert into t_ids
select 'offline', (public.partner_remote_action_request('00000000-0000-0000-0000-0000000286d1', 'go_offline') ->> 'id')::uuid;
select pg_temp.refused(format($q$select * from public.partner_remote_action_targets(%L)$q$, (select id from t_ids where k = 'offline')),
  'an admin reading the push targets');
reset role;
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
set local role service_role;
select pg_temp.check((select array_agg(token) = array['pra286-d1-android']
                        from public.partner_remote_action_targets((select id from t_ids where k = 'offline'))),
  'the push goes to the partner''s FCM phone, never an Expo token');
select pg_temp.check((select title = 'Support asked you to go offline' and body = 'Tap to confirm'
                        from public.partner_remote_action_targets((select id from t_ids where k = 'offline'))),
  'the notification the phone shows until the driver taps');
select public.partner_remote_action_sent((select id from t_ids where k = 'offline'), 1);
reset role;
select pg_temp.check((select status = 'sent' and sent_at is not null from public.partner_remote_actions
                       where id = (select id from t_ids where k = 'offline')), 'the push out: sent');

-- 6. No answer in 2 minutes: expired, and an answer after it changes nothing -------------------------
update public.partner_remote_actions set expires_at = now() - interval '1 second'
 where id = (select id from t_ids where k = 'offline');
-- One transaction has one now(): the requests made earlier are dated earlier.
update public.partner_remote_actions a
   set created_at = now() - case t.k when 'online' then interval '10 minutes' when 'link' then interval '9 minutes'
                                     else interval '1 minute' end
  from t_ids t
 where t.id = a.id;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000286d1');
select pg_temp.check(
  (public.partner_remote_action_report((select id from t_ids where k = 'offline'), 'done') ->> 'status') = 'expired',
  'an answer after the 2 minutes finds it expired');
select pg_temp.check(not exists (select 1 from public.user_notifications
                                  where profile_id = '00000000-0000-0000-0000-0000000286d1' and kind = 'partner_remote_action'),
  'an expired request leaves no "Support set you" line');
select pg_temp.as_user('00000000-0000-0000-0000-0000000286a2');
select pg_temp.check((public.partner_remote_action_status('00000000-0000-0000-0000-0000000286d1') ->> 'status') = 'expired',
  'the card shows no answer');
select pg_temp.check((public.partner_remote_action_request('00000000-0000-0000-0000-0000000286d1', 'go_offline') ->> 'status') = 'queued',
  'once expired, a new request can be made');
reset role;

-- 7. The audit log --------------------------------------------------------------------------------------
select pg_temp.check((select count(*) from public.admin_audit_log
                       where action = 'partner.remote_action'
                         and target_profile_id::text like '00000000-0000-0000-0000-0000000286%') = 4,
  'every request is logged');
select pg_temp.check((select count(*) from public.admin_audit_log
                       where action = 'partner.remote_action' and actor_id = '00000000-0000-0000-0000-0000000286a2'
                         and detail ->> 'action' = 'link_vehicle'
                         and detail ->> 'vehicle_id' = '00000000-0000-0000-0000-0000000286b3') = 1,
  'the request is logged with who asked and the vehicle');
select pg_temp.check((select array_agg(detail ->> 'result' order by detail ->> 'result') from public.admin_audit_log
                       where action = 'partner.remote_action_result'
                         and target_profile_id::text like '00000000-0000-0000-0000-0000000286%')
                     = array['done', 'expired', 'refused'],
  'each result is logged: done, refused, expired');
select pg_temp.check((select detail ->> 'reason' from public.admin_audit_log
                       where action = 'partner.remote_action_result' and detail ->> 'result' = 'refused'
                         and target_profile_id = '00000000-0000-0000-0000-0000000286d1') like 'Before you can go online%',
  'the refusal is logged with its reason');

rollback;

select 'partner_remote_actions_0286: all passed';
