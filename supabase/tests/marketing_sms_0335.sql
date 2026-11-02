-- ============================================================================
-- Regression test for migration 0335: marketing SMS go only to numbers whose
-- account turned News and offers on; the gateway never sends one whose
-- consent went while it waited; the admin's send says how many were left
-- out; a STOP reply turns News and offers off. Other SMS are untouched.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/marketing_sms_0335.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up accounts and numbers only.
-- ============================================================================
begin;

create function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if ok is not true then
    raise exception 'FAILED: %', what;
  end if;
end;
$$;
grant execute on function pg_temp.check(boolean, text) to authenticated;

create function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end;
$$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

-- The error [p_sql] raises, or null.
create function pg_temp.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end;
$$;
grant execute on function pg_temp.error_of(text) to authenticated;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000335a1'),  -- opted in
  ('00000000-0000-0000-0000-0000000335a2'),  -- not opted in
  ('00000000-0000-0000-0000-0000000335a3'),  -- opted in, then deleted
  ('00000000-0000-0000-0000-0000000335c1'),  -- full admin
  ('00000000-0000-0000-0000-0000000335c2'),  -- sub-admin, EDIT on SMS / WhatsApp
  ('00000000-0000-0000-0000-0000000335c3'),  -- sub-admin, READ on SMS / WhatsApp
  ('00000000-0000-0000-0000-0000000335e1')   -- not an admin
on conflict do nothing;
insert into public.profiles (id, phone, news_offers) values
  ('00000000-0000-0000-0000-0000000335a1', '+60120000335', true),
  ('00000000-0000-0000-0000-0000000335a2', '+60130000335', false),
  ('00000000-0000-0000-0000-0000000335a3', '+60140000335', true),
  ('00000000-0000-0000-0000-0000000335c1', null, false),
  ('00000000-0000-0000-0000-0000000335c2', null, false),
  ('00000000-0000-0000-0000-0000000335c3', null, false),
  ('00000000-0000-0000-0000-0000000335e1', null, false)
on conflict (id) do update set phone = excluded.phone, news_offers = excluded.news_offers;
update public.profiles set deleted_at = now() where id = '00000000-0000-0000-0000-0000000335a3';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000335c1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000335c2', 'admin-settings-messaging', 'edit'),
  ('00000000-0000-0000-0000-0000000335c3', 'admin-settings-messaging', 'read')
on conflict do nothing;

-- A gateway phone carrying marketing and support SMS out, and texts in.
insert into public.messaging_devices (id, user_id, device_id, label, platform, kind, capabilities)
values ('00000000-0000-0000-0000-0000003350d1', '00000000-0000-0000-0000-0000000335c1', 'phone-335', 'Gateway',
        'android', 'gateway', '{sms}');
delete from public.messaging_routes where channel in ('marketing', 'support_message');
insert into public.messaging_routes (channel, direction, transport, device_ids) values
  ('marketing', 'outbound', 'sms', array['00000000-0000-0000-0000-0000003350d1'::uuid]),
  ('support_message', 'outbound', 'sms', array['00000000-0000-0000-0000-0000003350d1'::uuid]),
  ('support_message', 'inbound', 'sms', array['00000000-0000-0000-0000-0000003350d1'::uuid]);

-- 1. Who has consented ------------------------------------------------------------------------
do $$
begin
  perform pg_temp.check(public.marketing_sms_consent('+60120000335') = 'opted_in', 'opted in');
  perform pg_temp.check(public.marketing_sms_consent('0120000335') = 'opted_in', 'a Malaysian 0... number reads as 60...');
  perform pg_temp.check(public.marketing_sms_consent('60 12-000 0335') = 'opted_in', 'spaces and dashes are ignored');
  perform pg_temp.check(public.marketing_sms_consent('+60130000335') = 'not_opted_in', 'not opted in');
  perform pg_temp.check(public.marketing_sms_consent('+60140000335') = 'no_account', 'a deleted account counts as none');
  perform pg_temp.check(public.marketing_sms_consent('+60190000335') = 'no_account', 'no account');
  perform pg_temp.check(public.marketing_sms_consent(null) = 'no_account', 'no number');
  perform pg_temp.check(not has_function_privilege('authenticated', 'public.marketing_sms_consent(text)', 'execute'),
    'anyone signed in can test a number');
end $$;

-- 2. The queue: marketing only with consent; everything else as before ------------------------------
do $$
begin
  insert into public.sms_outbox (channel, to_phone, body) values ('marketing', '+60120000335', 'Raya promo');
  perform pg_temp.check(
    pg_temp.error_of($q$insert into public.sms_outbox (channel, to_phone, body) values ('marketing', '+60130000335', 'x')$q$)
      = 'MARKETING_NO_CONSENT', 'marketing to a number that has not opted in');
  perform pg_temp.check(
    pg_temp.error_of($q$insert into public.sms_outbox (channel, to_phone, body) values ('marketing', '+60190000335', 'x')$q$)
      = 'MARKETING_NO_CONSENT', 'marketing to a number with no account');
  perform pg_temp.check(
    pg_temp.error_of($q$insert into public.sms_outbox (channel, to_phone, body) values ('marketing', '+60140000335', 'x')$q$)
      = 'MARKETING_NO_CONSENT', 'marketing to a deleted account');
  -- A queued row can't be pointed at someone else, or turned into marketing.
  perform pg_temp.check(
    pg_temp.error_of($q$update public.sms_outbox set to_phone = '+60130000335' where body = 'Raya promo'$q$)
      = 'MARKETING_NO_CONSENT', 'moving a marketing SMS to a number without consent');
  insert into public.sms_outbox (channel, to_phone, body) values ('support_message', '+60130000335', 'Your ticket');
  perform pg_temp.check(
    pg_temp.error_of($q$update public.sms_outbox set channel = 'marketing' where body = 'Your ticket'$q$)
      = 'MARKETING_NO_CONSENT', 'turning a support SMS into marketing');
  -- Support, trip and sign-in code SMS go to anyone, as before.
  insert into public.sms_outbox (channel, to_phone, body) values
    ('support_message', '+60190000335', 'Support reply'),
    ('otp', '+60190000335', 'Your code is 1234');
  perform pg_temp.check((select count(*) from public.sms_outbox
                          where to_phone = '+60190000335' and status = 'queued') = 2, 'other SMS queued');
end $$;

-- 3. The admin's send: queued with consent, the rest counted -----------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000335c2');
do $$
declare
  r jsonb;
begin
  r := public.admin_queue_marketing_sms(
    array['+60120000335', '0120000335', '+60130000335', '+60190000335', '+60140000335', 'call me', ''],
    '  New: City to City  ');
  perform pg_temp.check(r->>'queued' = '1', format('queued %s', r));
  perform pg_temp.check(r->>'notOptedIn' = '1', format('not opted in %s', r));
  perform pg_temp.check(r->>'noAccount' = '2', format('no account (none, deleted) %s', r));
  perform pg_temp.check(r->>'invalid' = '2', format('not a number %s', r));
  perform pg_temp.check(r->>'leftOut' = '5', format('left out %s', r));

  r := public.admin_marketing_sms_reach();
  perform pg_temp.check((r->>'optedIn')::int >= 1 and (r->>'withPhone')::int >= 2, format('reach %s', r));
end $$;
select pg_temp.check(
  pg_temp.error_of($q$select public.admin_queue_marketing_sms(array['+60120000335'], '   ')$q$) = 'MARKETING_SMS_BODY',
  'an empty message');

select pg_temp.as_user('00000000-0000-0000-0000-0000000335c3');
select pg_temp.check(
  pg_temp.error_of($q$select public.admin_queue_marketing_sms(array['+60120000335'], 'x')$q$) = 'NOT_ALLOWED',
  'a read-only sub-admin sending');
select pg_temp.as_user('00000000-0000-0000-0000-0000000335e1');
select pg_temp.check(
  pg_temp.error_of($q$select public.admin_queue_marketing_sms(array['+60120000335'], 'x')$q$) = 'NOT_ALLOWED',
  'someone who is not an admin sending');
select pg_temp.check(pg_temp.error_of($q$select public.admin_marketing_sms_reach()$q$) = 'NOT_ALLOWED',
  'someone who is not an admin reading the reach');
-- Nor around it: the table's own rule, then the consent.
select pg_temp.check(
  pg_temp.error_of($q$insert into public.sms_outbox (channel, to_phone, body) values ('marketing', '+60120000335', 'x')$q$)
    is not null, 'someone who is not an admin queuing');
select pg_temp.as_user('00000000-0000-0000-0000-0000000335c2');
select pg_temp.check(
  pg_temp.error_of($q$insert into public.sms_outbox (channel, to_phone, body) values ('marketing', '+60130000335', 'x')$q$)
    = 'MARKETING_NO_CONSENT', 'an admin queuing marketing straight into the table without consent');
reset role;

do $$
begin
  perform pg_temp.check((select count(*) from public.sms_outbox where channel = 'marketing'
                          and body = 'New: City to City' and to_phone = '+60120000335'
                          and created_by = '00000000-0000-0000-0000-0000000335c2') = 1,
    'the admin''s send is queued once, trimmed, as theirs');
  perform pg_temp.check(exists (select 1 from public.admin_audit_log
                                 where action = 'marketing_sms.queue'
                                   and actor_id = '00000000-0000-0000-0000-0000000335c2'
                                   and detail->>'queued' = '1' and detail->>'notOptedIn' = '1'),
    'the send is in the audit log');
end $$;

-- 4. Consent withdrawn while waiting: the gateway fails it ---------------------------------------
update public.profiles set news_offers = false where id = '00000000-0000-0000-0000-0000000335a1';
do $$
declare
  jobs public.sms_outbox[];
begin
  select array_agg(j) into jobs from public.gateway_claim_for('00000000-0000-0000-0000-0000003350d1', 50) j;
  perform pg_temp.check(not exists (select 1 from unnest(jobs) j where j.channel = 'marketing'),
    'a marketing SMS without consent was claimed');
  perform pg_temp.check(exists (select 1 from unnest(jobs) j where j.body = 'Support reply'),
    'support SMS are still claimed');
  perform pg_temp.check((select count(*) from public.sms_outbox where channel = 'marketing' and status = 'failed'
                          and error = 'No News and offers consent') = 2, 'withdrawn consent fails the waiting SMS');
end $$;

-- 5. STOP turns News and offers off -----------------------------------------------------------------
update public.profiles set news_offers = true where id = '00000000-0000-0000-0000-0000000335a1';
insert into public.sms_outbox (channel, to_phone, body) values ('marketing', '+60120000335', 'Weekend deal');
do $$
begin
  perform pg_temp.check(public.marketing_sms_is_stop('STOP'), 'STOP');
  perform pg_temp.check(public.marketing_sms_is_stop(' stop. '), 'stop.');
  perform pg_temp.check(public.marketing_sms_is_stop('Stop all'), 'Stop all');
  perform pg_temp.check(public.marketing_sms_is_stop('UNSUBSCRIBE'), 'UNSUBSCRIBE');
  perform pg_temp.check(public.marketing_sms_is_stop('berhenti'), 'berhenti');
  perform pg_temp.check(not public.marketing_sms_is_stop('Please stop at the gate'), 'a sentence with stop in it');
  perform pg_temp.check(not public.marketing_sms_is_stop(''), 'an empty text');

  -- Someone else's text changes nothing.
  perform public.gateway_receive_for('00000000-0000-0000-0000-0000003350d1', '+60130000335', 'STOP', now());
  perform pg_temp.check((select news_offers from public.profiles where id = '00000000-0000-0000-0000-0000000335a1'),
    'another number''s STOP');
  -- A message that is not STOP changes nothing.
  perform public.gateway_receive_for('00000000-0000-0000-0000-0000003350d1', '0120000335', 'Thanks!', now());
  perform pg_temp.check((select news_offers from public.profiles where id = '00000000-0000-0000-0000-0000000335a1'),
    'a reply that is not STOP');

  perform public.gateway_receive_for('00000000-0000-0000-0000-0000003350d1', '0120000335', 'Stop', now());
  perform pg_temp.check(not (select news_offers from public.profiles where id = '00000000-0000-0000-0000-0000000335a1'),
    'STOP turns News and offers off');
  perform pg_temp.check((select status = 'failed' and error = 'Replied STOP' from public.sms_outbox
                          where body = 'Weekend deal'), 'STOP fails the waiting marketing SMS');
  perform pg_temp.check((select count(*) from public.sms_inbox where from_phone = '0120000335') = 2,
    'the texts are still kept in the inbox');
  perform pg_temp.check(public.marketing_sms_consent('+60120000335') = 'not_opted_in', 'no consent after STOP');
end $$;

-- The person turns it on again themselves.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000335a1');
select public.set_news_offers(true);
reset role;
select pg_temp.check(public.marketing_sms_consent('+60120000335') = 'opted_in', 'turned on again in Settings');

rollback;
