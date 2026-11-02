-- ============================================================================
-- Regression test for migration 0334: deleting an account from the web page
-- (getride.my/delete-account). No way to tell whether a number has an
-- account; the SMS code is required; rate limits; the grace days, cancelled
-- by signing in; the grace run (waiting out a ride); Sign in and delete; the
-- admin's view and cancel; final deletion empties voice-protection too.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/account_deletion_request_0334.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id, phone, phone_confirmed_at) values
  ('00000000-0000-0000-0000-0000000334a1', '60100000341', now()),  -- asks by phone, signs in again
  ('00000000-0000-0000-0000-0000000334a2', '60100000342', now()),  -- asks by phone, mid-ride, then deleted
  ('00000000-0000-0000-0000-0000000334a3', '60100000343', now()),  -- five wrong codes
  ('00000000-0000-0000-0000-0000000334a4', '60100000344', now()),  -- Sign in and delete
  ('00000000-0000-0000-0000-0000000334a5', '60100000345', now()),  -- an admin cancels theirs
  ('00000000-0000-0000-0000-0000000334c1', null, null),            -- users admin (edit)
  ('00000000-0000-0000-0000-0000000334c2', null, null),            -- users admin (read)
  ('00000000-0000-0000-0000-0000000334c3', null, null),            -- runs the gateway phone (full admin)
  ('00000000-0000-0000-0000-0000000334d1', null, null)             -- an ordinary rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000334%'
on conflict do nothing;
update public.profiles set phone = '+' || u.phone, name = 'Person ' || right(u.id::text, 2)
  from auth.users u
 where u.id = profiles.id and u.id::text like '00000000-0000-0000-0000-0000000334a%';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000334c1', 'admin-user-edit', 'edit'),
  ('00000000-0000-0000-0000-0000000334c2', 'admin-users', 'read'),
  ('00000000-0000-0000-0000-0000000334c3', '*', 'edit')
on conflict do nothing;

create or replace function pg_temp.as_user(p uuid, p_amr jsonb default '[]') returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p, 'role', 'authenticated', 'amr', p_amr)::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_anon(p_ip text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.headers', json_build_object('cf-connecting-ip', p_ip)::text, true);
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
-- The error text a call raises, or null.
create or replace function pg_temp.raised(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end $$;
grant execute on function pg_temp.as_user(uuid, jsonb), pg_temp.as_anon(text), pg_temp.check(boolean, text),
  pg_temp.refused(text, text), pg_temp.raised(text) to anon, authenticated;

-- The code the gateway would text to [p_phone] (read as the server).
create or replace function pg_temp.code_for(p_phone text) returns text language sql as $$
  select substring(s.body from '([0-9]{6})')
    from public.sms_otp_secret s join public.sms_outbox o on o.id = s.outbox_id
   where o.to_phone = p_phone
   order by s.created_at desc limit 1;
$$;
create or replace function pg_temp.req(p uuid) returns public.account_deletion_requests language sql as $$
  select * from public.account_deletion_requests where user_id = p order by created_at desc limit 1;
$$;

create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;
create temp table answers (name text primary key, v jsonb);
grant all on answers to anon, authenticated;

-- A gateway phone on the otp route, so codes are queued (0149/0183).
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000334c3');
insert into ids
select 'gateway', (public.messaging_heartbeat('gw-334', 'Gateway', 'android', 'gateway', '{sms}', '+60111')).id;
reset role;
delete from public.messaging_routes where channel = 'otp' and direction = 'outbound';
insert into public.messaging_routes (channel, direction, transport, device_ids)
values ('otp', 'outbound', 'sms', array[(select id from ids where name = 'gateway')]);

-- 0. The page's facts, without sign-in -------------------------------------------------------
set local role anon;
select pg_temp.as_anon('203.0.113.10');
select pg_temp.check((public.account_deletion_public_info() ->> 'graceDays')::int = 7, 'grace days default to 7');
insert into answers values ('info', public.account_deletion_public_info());
reset role;
select pg_temp.check((select (v ->> 'retentionDays')::int from answers where name = 'info')
                     = (public.account_deletion_config() ->> 'retentionDays')::int, 'retention days are 0194''s');

-- 1. The same answer whether or not the number has an account -------------------------------
set local role anon;
select pg_temp.as_anon('203.0.113.11');
insert into answers values ('has', public.request_account_deletion_code('+60 10-000 0341'));
select pg_temp.as_anon('203.0.113.12');
insert into answers values ('none', public.request_account_deletion_code('+60 10-999 0341'));
select pg_temp.check((select v from answers where name = 'has') = (select v from answers where name = 'none'),
  'a number with an account and one without get the same answer');
select pg_temp.check((select (v ->> 'ok')::boolean from answers where name = 'none'), 'the answer is ok');
select pg_temp.check(pg_temp.raised($q$select public.request_account_deletion_code('12')$q$) = 'DELETION_PHONE',
  'not a phone number at all');
-- The table and the inner functions are closed to the page.
select pg_temp.refused($q$select * from public.account_deletion_requests$q$, 'anon reading the requests');
select pg_temp.refused($q$select public.account_deletion_requests_run()$q$, 'anon running the grace run');
select pg_temp.refused($q$select public.account_deletion_apply('00000000-0000-0000-0000-0000000334a1', null, null)$q$,
  'anon deleting an account directly');
reset role;

select pg_temp.check(pg_temp.code_for('+60100000341') is not null, 'the account''s number got a code');
select pg_temp.check(pg_temp.code_for('+60109990341') is null, 'a number with no account got nothing');
select pg_temp.check((select status = 'requested' and code_hash is not null and code_hash !~ pg_temp.code_for('+60100000341')
                        from pg_temp.req('00000000-0000-0000-0000-0000000334a1')), 'the code is kept as a hash only');
select pg_temp.check(not exists (select 1 from public.account_deletion_requests
                                  where phone_hash = public.account_deletion_phone_hash('+60109990341')),
  'nothing is kept for a number with no account');
select pg_temp.check(exists (select 1 from public.sms_log where phone = '+60100000341' and status = 'queued'),
  'the code went through the sign-in SMS log and queue');

-- 2. The code is required ---------------------------------------------------------------------
set local role anon;
select pg_temp.as_anon('203.0.113.11');
insert into answers values ('wrong', public.confirm_account_deletion_request('+60100000341', '000000'));
insert into answers values ('nobody', public.confirm_account_deletion_request('+60109990341', '123456'));
select pg_temp.check((select v ->> 'error' from answers where name = 'wrong') = 'wrong_code', 'a wrong code');
select pg_temp.check((select v from answers where name = 'wrong') = (select v from answers where name = 'nobody'),
  'a number with no account reads like a wrong code');
reset role;
select pg_temp.check((select status = 'requested' and code_attempts = 1
                        from pg_temp.req('00000000-0000-0000-0000-0000000334a1')), 'the wrong try counts, nothing else');
select pg_temp.check((select deleted_at is null from public.profiles where id = '00000000-0000-0000-0000-0000000334a1'),
  'nothing deleted without the code');

-- A session the account has now, to be ended by the request.
insert into auth.sessions (id, user_id, created_at, updated_at)
values ('00000000-0000-0000-0000-0000000334e1', '00000000-0000-0000-0000-0000000334a1', now(), now());
create temp table codes as select pg_temp.code_for('+60100000341') as a1;
grant select on codes to anon;

set local role anon;
select pg_temp.as_anon('203.0.113.11');
insert into answers values ('right',
  public.confirm_account_deletion_request('+60100000341', (select a1 from codes), 'Not using it'));
select pg_temp.check((select (v ->> 'ok')::boolean and (v ->> 'graceDays')::int = 7 from answers where name = 'right'),
  'the right code: the request is taken');
reset role;
select pg_temp.check((select status = 'in_grace' and code_hash is null and reason = 'Not using it'
                             and grace_until between now() + interval '6 days 23 hours' and now() + interval '7 days 1 hour'
                        from pg_temp.req('00000000-0000-0000-0000-0000000334a1')), 'in grace for 7 days');
select pg_temp.check((select deleted_at is null from public.profiles where id = '00000000-0000-0000-0000-0000000334a1'),
  'not deleted during the grace days');
select pg_temp.check(not exists (select 1 from auth.sessions where user_id = '00000000-0000-0000-0000-0000000334a1'),
  'signed out everywhere');
select pg_temp.check(exists (select 1 from public.account_events
                              where profile_id = '00000000-0000-0000-0000-0000000334a1' and kind = 'deletion_requested'
                                and detail ->> 'source' = 'web'), 'the request is in the account''s log');
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where profile_id = '00000000-0000-0000-0000-0000000334a1'
                                and title = 'Your account will be deleted'), 'the account is told');
set local role anon;
select pg_temp.as_anon('203.0.113.11');
select pg_temp.check(public.confirm_account_deletion_request('+60100000341', (select a1 from codes)) ->> 'error'
                     = 'wrong_code', 'a code works once');
reset role;

-- 3. Signing in during the grace days cancels -------------------------------------------------
update auth.users set last_sign_in_at = now() + interval '1 minute' where id = '00000000-0000-0000-0000-0000000334a1';
select pg_temp.check((select status = 'cancelled' and cancel_reason = 'signed_in'
                        from pg_temp.req('00000000-0000-0000-0000-0000000334a1')), 'signing in cancels it');
select pg_temp.check(exists (select 1 from public.account_events
                              where profile_id = '00000000-0000-0000-0000-0000000334a1' and kind = 'deletion_cancelled'),
  'the cancel is in the log');
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where profile_id = '00000000-0000-0000-0000-0000000334a1' and title = 'Your account is kept'),
  'the account is told it is kept');

-- 4. Five wrong codes end the code -----------------------------------------------------------
set local role anon;
select pg_temp.as_anon('203.0.113.13');
select public.request_account_deletion_code('+60100000343');
reset role;
create temp table code3 as select pg_temp.code_for('+60100000343') as c;
grant select on code3 to anon;
set local role anon;
select pg_temp.as_anon('203.0.113.13');
select public.confirm_account_deletion_request('+60100000343', '00000' || n) from generate_series(1, 5) n;
select pg_temp.check(public.confirm_account_deletion_request('+60100000343', (select c from code3)) ->> 'error'
                     = 'wrong_code', 'the right code after five wrong ones is refused');
reset role;
select pg_temp.check((select status = 'requested' and code_hash is null
                        from pg_temp.req('00000000-0000-0000-0000-0000000334a3')), 'the code is gone');

-- 5. Rate limits, the same for every number -------------------------------------------------
set local role anon;
select pg_temp.as_anon('198.51.100.7');
select public.request_account_deletion_code('+6011000033' || n) from generate_series(1, 5) n;
select pg_temp.check(pg_temp.raised($q$select public.request_account_deletion_code('+60110000336')$q$) like 'RATE_LIMITED:%',
  'six codes from one address in 10 minutes');
-- Per number: three an hour, from any address, account or not.
select pg_temp.as_anon('198.51.100.21');
select public.request_account_deletion_code('+60129990334');
select pg_temp.as_anon('198.51.100.22');
select public.request_account_deletion_code('+60129990334');
select pg_temp.as_anon('198.51.100.23');
select public.request_account_deletion_code('+60129990334');
select pg_temp.as_anon('198.51.100.24');
select pg_temp.check(pg_temp.raised($q$select public.request_account_deletion_code('+60129990334')$q$) like 'RATE_LIMITED:%',
  'a fourth code to one number in an hour');
-- Tries: twenty from one address.
select pg_temp.as_anon('198.51.100.30');
select public.confirm_account_deletion_request('+6013999' || lpad(n::text, 4, '0'), '123456') from generate_series(1, 20) n;
select pg_temp.check(pg_temp.raised($q$select public.confirm_account_deletion_request('+60139990099', '123456')$q$)
                     like 'RATE_LIMITED:%', 'twenty-one tries from one address');
reset role;

-- 6. The grace run: a ride under way waits, then the account is deleted ----------------------
set local role anon;
select pg_temp.as_anon('203.0.113.14');
select public.request_account_deletion_code('+60100000342');
reset role;
create temp table code2 as select pg_temp.code_for('+60100000342') as c;
grant select on code2 to anon;
set local role anon;
select pg_temp.as_anon('203.0.113.14');
select pg_temp.check((public.confirm_account_deletion_request('+60100000342', (select c from code2)) ->> 'ok')::boolean,
  'the second account asks too');
reset role;
insert into public.ride_requests (rider_id, status, rider_name, rider_phone, pickup_lat, pickup_lng, drop_lat, drop_lng)
values ('00000000-0000-0000-0000-0000000334a2', 'accepted', 'Person a2', '+60100000342', 3.15, 101.71, 3.14, 101.69);
select public.account_deletion_requests_run();
select pg_temp.check((select status = 'in_grace' from pg_temp.req('00000000-0000-0000-0000-0000000334a2')),
  'not before the grace days are over');
update public.account_deletion_requests set grace_until = now() - interval '1 minute'
 where user_id = '00000000-0000-0000-0000-0000000334a2' and status = 'in_grace';
select public.account_deletion_requests_run();
select pg_temp.check((select status = 'in_grace' and last_error = 'active_ride'
                        from pg_temp.req('00000000-0000-0000-0000-0000000334a2')), 'a ride under way: it waits');
delete from public.ride_requests where rider_id = '00000000-0000-0000-0000-0000000334a2';
select pg_temp.check(public.account_deletion_requests_run() >= 1, 'the run deletes it');
select pg_temp.check((select status = 'deleted' and deleted_at is not null and last_error is null
                        from pg_temp.req('00000000-0000-0000-0000-0000000334a2')), 'the request is done');
select pg_temp.check((select deleted_at is not null and deleted_phone = '+60100000342' and phone is null
                        from public.profiles where id = '00000000-0000-0000-0000-0000000334a2'),
  '0194''s deletion: the number is released');
select pg_temp.check((select banned_until > now() + interval '50 years' from auth.users
                       where id = '00000000-0000-0000-0000-0000000334a2'), 'the old login is banned');
select pg_temp.check(exists (select 1 from public.account_events
                              where profile_id = '00000000-0000-0000-0000-0000000334a2' and kind = 'deleted'
                                and detail ->> 'method' = 'phone_code' and detail ? 'requestsCancelled'),
  'the deletion is logged like the app''s, with where it came from');
-- The number is free now: asking again gets the same answer and no code.
set local role anon;
select pg_temp.as_anon('203.0.113.15');
select pg_temp.check(public.request_account_deletion_code('+60100000342') = (select v from answers where name = 'none'),
  'a deleted account''s number answers like any other');
reset role;

-- 7. Sign in and delete -----------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000334a4');
select pg_temp.check(public.delete_my_account_web() ->> 'error' = 'confirm_needed', 'the app''s confirm step: a fresh SMS sign-in');
select pg_temp.as_user('00000000-0000-0000-0000-0000000334a4',
  jsonb_build_array(jsonb_build_object('method', 'otp', 'timestamp', extract(epoch from now())::bigint - 30)));
select pg_temp.check((public.delete_my_account_web('Too many apps') ->> 'ok')::boolean, 'deleted from the web at once');
reset role;
select pg_temp.check((select status = 'deleted' and method = 'sign_in' and source = 'web'
                             and phone_hash = public.account_deletion_phone_hash('+60100000344')
                        from pg_temp.req('00000000-0000-0000-0000-0000000334a4')), 'recorded as a web request');
select pg_temp.check((select deleted_at is not null from public.profiles where id = '00000000-0000-0000-0000-0000000334a4'),
  'the account is deleted');

-- 8. The admin sees them and can cancel one --------------------------------------------------
set local role anon;
select pg_temp.as_anon('203.0.113.16');
select public.request_account_deletion_code('+60100000345');
reset role;
create temp table code5 as select pg_temp.code_for('+60100000345') as c;
grant select on code5 to anon;
set local role anon;
select pg_temp.as_anon('203.0.113.16');
select public.confirm_account_deletion_request('+60100000345', (select c from code5));
reset role;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000334c2');
select pg_temp.check((select count(*) from public.admin_account_deletion_requests()
                       where user_id::text like '00000000-0000-0000-0000-0000000334a%') >= 5, 'the read admin sees them');
select pg_temp.check((select array_agg(distinct status order by status) from public.admin_account_deletion_requests()
                       where user_id::text like '00000000-0000-0000-0000-0000000334a%')
                     @> array['cancelled', 'deleted', 'in_grace', 'requested'], 'with every status');
select pg_temp.check((select count(*) from public.admin_account_deletion_requests('00000000-0000-0000-0000-0000000334a5', 'in_grace')) = 1,
  'one account''s, by status');
select pg_temp.refused($q$select public.admin_cancel_account_deletion_request(
  (select id from public.admin_account_deletion_requests('00000000-0000-0000-0000-0000000334a5', 'in_grace')))$q$,
  'a read-only admin cancelling');
select pg_temp.as_user('00000000-0000-0000-0000-0000000334d1');
select pg_temp.refused($q$select * from public.admin_account_deletion_requests()$q$, 'a rider listing requests');
select pg_temp.as_user('00000000-0000-0000-0000-0000000334c1');
select pg_temp.check((public.admin_cancel_account_deletion_request(
  (select id from public.admin_account_deletion_requests('00000000-0000-0000-0000-0000000334a5', 'in_grace'))) ->> 'ok')::boolean,
  'the edit admin cancels it');
select pg_temp.check(pg_temp.raised($q$select public.admin_cancel_account_deletion_request(
  (select id from public.admin_account_deletion_requests('00000000-0000-0000-0000-0000000334a5') limit 1))$q$)
  = 'ACCOUNT_DELETION_NOT_OPEN', 'only once');
select pg_temp.check((public.set_account_deletion_web_config('{"graceDays": 3}') ->> 'graceDays')::int = 3,
  'the edit admin sets the grace days');
select pg_temp.check(pg_temp.raised($q$select public.set_account_deletion_web_config('{"graceDays": 31}')$q$)
  = 'ACCOUNT_DELETION_CONFIG', 'at most 30');
select pg_temp.as_user('00000000-0000-0000-0000-0000000334c2');
select pg_temp.refused($q$select public.set_account_deletion_web_config('{"graceDays": 1}')$q$,
  'a read-only admin changing the grace days');
reset role;
select pg_temp.check((select status = 'cancelled' and cancel_reason = 'admin'
                             and cancelled_by = '00000000-0000-0000-0000-0000000334c1'
                        from pg_temp.req('00000000-0000-0000-0000-0000000334a5')), 'cancelled by the admin');
select pg_temp.check(exists (select 1 from public.admin_audit_log
                              where action = 'account_deletion_request_cancel'
                                and target_profile_id = '00000000-0000-0000-0000-0000000334a5'
                                and actor_id = '00000000-0000-0000-0000-0000000334c1'), 'in the admin audit log');

-- 9. Final deletion empties the voice-protection folder too ----------------------------------
update public.profiles set deleted_at = now() - interval '4000 days'
 where id = '00000000-0000-0000-0000-0000000334a2';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000334c1');
select pg_temp.check(public.admin_final_delete_account('00000000-0000-0000-0000-0000000334a2') -> 'folders'
                     @> jsonb_build_array(jsonb_build_object('bucket', 'voice-protection',
                                                             'folder', '00000000-0000-0000-0000-0000000334a2')),
  'the voice-protection folder is emptied');
reset role;

select 'account_deletion_request_0334: all passed';
rollback;
