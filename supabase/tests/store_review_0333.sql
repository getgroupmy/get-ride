-- ============================================================================
-- Regression test for migration 0333: the store review login and its seal.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/store_review_0333.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up accounts only.
-- ============================================================================
begin;

create function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
  if ok is not true then
    raise exception 'FAILED: %', what;
  end if;
end;
$$;

-- Who is calling: [p_user] with [p_meta] as its token's app_metadata, at
-- [p_path] with [p_method], from [p_ip]. Null user: no token (the database).
create function pg_temp.as_caller(p_user text, p_meta jsonb default '{}', p_path text default '/profiles',
                                  p_method text default 'GET', p_ip text default '198.51.100.33')
returns void language plpgsql as $$
begin
  if p_user is null then
    perform set_config('request.jwt.claims', '', true);
  else
    perform set_config('request.jwt.claims',
      json_build_object('sub', p_user, 'role', 'authenticated', 'app_metadata', p_meta)::text, true);
  end if;
  perform set_config('request.jwt.claim.sub', coalesce(p_user, ''), true);
  perform set_config('request.path', p_path, true);
  perform set_config('request.method', p_method, true);
  perform set_config('request.headers', json_build_object('x-real-ip', p_ip)::text, true);
end;
$$;

-- Whether request_guard refuses the current request as the store review seal.
create function pg_temp.sealed() returns boolean language plpgsql as $$
begin
  perform public.request_guard();
  return false;
exception when sqlstate 'PT403' then
  return true;
end;
$$;

-- The error an insert raises, or null.
create function pg_temp.insert_error(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end;
$$;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000333a1', '60100000333'),  -- a rider
  ('00000000-0000-0000-0000-0000000333c1', null),           -- admin, EDIT on App Settings
  ('00000000-0000-0000-0000-0000000333c2', null)            -- admin, READ on App Settings
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000333a1', 'Aina Rider', '+60100000333'),
  ('00000000-0000-0000-0000-0000000333c1', 'Edit Admin', null),
  ('00000000-0000-0000-0000-0000000333c2', 'Read Admin', null)
on conflict (id) do update set name = excluded.name, phone = excluded.phone;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000333c1', 'admin-settings-site', 'edit'),
  ('00000000-0000-0000-0000-0000000333c2', 'admin-settings-site', 'read')
on conflict do nothing;
insert into public.saved_places (user_id, kind, name, lat, lng) values
  ('00000000-0000-0000-0000-0000000333a1', 'other', 'Aina''s office', 3.15, 101.71);

-- ---- The demo account -------------------------------------------------------------------------------
do $$
declare
  demo uuid := public.store_review_user_id();
begin
  perform pg_temp.check(exists (select 1 from auth.users where id = demo
                                  and raw_app_meta_data ->> 'store_review' = 'true'),
    'the demo Auth user exists with store_review in its app_metadata');
  perform pg_temp.check((select store_review from public.profiles where id = demo), 'the demo profile is flagged');
  perform pg_temp.check(public.is_store_review(demo), 'is_store_review knows the demo account');
  perform pg_temp.check(not public.is_store_review('00000000-0000-0000-0000-0000000333a1'), 'a rider is not one');
  perform pg_temp.check(not exists (select 1 from public.partners where id = demo)
                        and not exists (select 1 from public.admin_access where profile_id = demo),
    'the demo account is no partner and no admin');
  perform pg_temp.check((select devices from public.device_allowances where user_id = demo) = 10,
    'several reviewer devices may stay signed in');
  perform pg_temp.check((select pin_hash from public.profiles where id = demo) is null, 'the demo account has no PIN');
end $$;

-- ---- Switch off (the default): refused, and the number is like any other -------------------------
do $$
declare
  r jsonb;
  failed boolean := false;
begin
  perform pg_temp.check(not (select enabled from public.store_review_settings where id = 1), 'off by default');
  perform pg_temp.check((select phone from public.store_review_settings where id = 1) = '60608080', 'the default number');
  r := public.store_review_sign_in('+60608080', '203.0.113.1', 'android', 'Pixel 8', '1.9.0', 'test');
  perform pg_temp.check(r ->> 'outcome' = 'off' and not (r ->> 'ok')::boolean and r ->> 'user_id' is null,
    'off: the route refuses: ' || r::text);
  -- Off, the short number meets the country rules as any number does.
  perform pg_temp.as_caller(null, p_ip => '203.0.113.2');
  begin
    perform * from public.profile_phone_lookup('+60608080');
  exception when others then
    failed := sqlerrm like 'PHONE_LENGTH%';
  end;
  perform pg_temp.check(failed, 'off: +60608080 is too short for Malaysia like any number');
end $$;

-- ---- Admin rights ------------------------------------------------------------------------------------
set local role authenticated;
do $$
begin
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000333a1');
  begin
    perform public.admin_store_review_state();
    raise exception 'FAILED: a rider read the store review login';
  exception when insufficient_privilege then null;
  end;
  perform pg_temp.check((select count(*) from public.store_review_sign_ins) = 0, 'a rider reads no sign-ins');
  begin
    perform 1 from public.store_review_settings;
    raise exception 'FAILED: a rider read the settings table';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.store_review_sign_in('+60608080', 'x');
    raise exception 'FAILED: a rider called the sign-in check';
  exception when insufficient_privilege then null;
  end;

  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000333c2');
  perform pg_temp.check(public.admin_store_review_state() ->> 'enabled' = 'false', 'a read-only admin sees it');
  begin
    perform public.admin_store_review_set(true, '60608080');
    raise exception 'FAILED: a read-only admin switched it on';
  exception when insufficient_privilege then null;
  end;

  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000333c1');
  begin
    perform public.admin_store_review_set(true, '12345');
    raise exception 'FAILED: a 5-digit number was saved';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.admin_store_review_set(true, '+60 10-000 0333');
    raise exception 'FAILED: a live account''s number was saved';
  exception when invalid_parameter_value then
    perform pg_temp.check(sqlerrm like 'STORE_REVIEW_PHONE_TAKEN%', 'a taken number says so');
  end;
  perform pg_temp.check((public.admin_store_review_set(true, '+60 6080 80') ->> 'enabled')::boolean,
    'the edit admin switches it on');
  perform pg_temp.check((public.admin_store_review_state() ->> 'accountReady')::boolean, 'the account is ready');
end $$;
reset role;
select pg_temp.check(
  (select enabled and phone = '60608080' and updated_by = '00000000-0000-0000-0000-0000000333c1'
     from public.store_review_settings where id = 1), 'saved with who changed it');

-- ---- Switch on: only that number ---------------------------------------------------------------------
do $$
declare
  r record;
  j jsonb;
  failed boolean := false;
  i int;
begin
  perform pg_temp.as_caller(null, p_ip => '203.0.113.3');
  select * into r from public.profile_phone_lookup('+60608080');
  perform pg_temp.check(r.store_review and not r.has_profile and not r.has_pin,
    'on: the lookup sends the number to the review sign-in, past the phone rules');
  select * into r from public.profile_phone_lookup('+60100000333');
  perform pg_temp.check(not r.store_review and r.has_profile, 'on: other numbers are as before');
  -- The demo account's own phone is no way in.
  begin
    perform * from public.profile_phone_lookup('+99960608080');
  exception when others then
    failed := sqlerrm like 'PHONE_BLOCKED%';
  end;
  perform pg_temp.check(failed, 'the demo account''s phone is refused at the lookup');

  j := public.store_review_sign_in('+60608081', '203.0.113.4', 'ios', 'iPhone', '1.9.0', 'test');
  perform pg_temp.check(j ->> 'outcome' = 'wrong_number' and j ->> 'user_id' is null, 'on: another number is refused');
  j := public.store_review_sign_in('+60608080', '203.0.113.4', 'android', 'Pixel 8', '1.9.0', 'okhttp');
  perform pg_temp.check(j ->> 'outcome' = 'allowed' and (j ->> 'user_id')::uuid = public.store_review_user_id(),
    'on: the number signs in to the demo account alone');

  -- Rate limited per address.
  for i in 1 .. 40 loop
    j := public.store_review_sign_in('+60608080', '203.0.113.5');
  end loop;
  perform pg_temp.check(j ->> 'outcome' = 'rate_limited' and (j ->> 'retry_after')::int > 0
                        and j ->> 'user_id' is null, 'the route is rate limited: ' || j::text);

  -- Every try is logged.
  perform pg_temp.check((select count(*) from public.store_review_sign_ins where outcome = 'allowed') >= 31,
    'allowed sign-ins are logged');
  perform pg_temp.check(exists (select 1 from public.store_review_sign_ins
                                 where outcome = 'allowed' and ip = '203.0.113.4' and platform = 'android'
                                   and device = 'Pixel 8' and app_version = '1.9.0'),
    'a sign-in row keeps the address, platform, device and version');
  perform pg_temp.check(exists (select 1 from public.store_review_sign_ins where outcome = 'off')
                        and exists (select 1 from public.store_review_sign_ins where outcome = 'wrong_number')
                        and exists (select 1 from public.store_review_sign_ins where outcome = 'rate_limited'),
    'refusals are logged too');
end $$;

set local role authenticated;
do $$
begin
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000333c2');
  perform pg_temp.check(jsonb_array_length(public.admin_store_review_state() -> 'signIns') > 0,
    'admins see the sign-in log');
  perform pg_temp.check((select count(*) from public.store_review_sign_ins) > 0, 'admins read the log table');
end $$;
reset role;

-- ---- No PIN asked of the demo account ---------------------------------------------------------------
do $$
declare
  demo text := public.store_review_user_id()::text;
begin
  perform pg_temp.as_caller(demo, '{"store_review": true}');
  perform pg_temp.check(public.my_sign_in_state() ->> 'pinRequired' = 'false', 'no PIN for the demo account');
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000333a1');
  perform pg_temp.check(public.my_sign_in_state() ->> 'pinRequired' = 'true', 'a rider still needs a PIN');
end $$;

-- ---- The pre-request seal ---------------------------------------------------------------------------
do $$
declare
  demo text := public.store_review_user_id()::text;
  meta jsonb := '{"store_review": true}';
  p text;
begin
  -- Allowed: the session checks, settings, quotes, its own lists, reads.
  foreach p in array array['/rpc/claim_session', '/rpc/session_is_current', '/rpc/my_sign_in_state',
                           '/rpc/scheduled_rides_config', '/rpc/hire_quote', '/rpc/my_premium_status',
                           '/rpc/trip_handovers_mine', '/rpc/pin_policy'] loop
    perform pg_temp.as_caller(demo, meta, p, 'POST');
    perform pg_temp.check(not pg_temp.sealed(), 'the demo account may call ' || p);
  end loop;
  perform pg_temp.as_caller(demo, meta, '/profiles', 'GET');
  perform pg_temp.check(not pg_temp.sealed(), 'the demo account reads tables');
  perform pg_temp.as_caller(demo, meta, '/online_driver_locations', 'GET');
  perform pg_temp.check(not pg_temp.sealed(), 'a view that reads as the caller is a read');

  -- Refused: booking, offers, money, chat, calls, SOS, partner sign-up, admin.
  foreach p in array array['/rpc/ride_offer_make', '/rpc/ride_offer_accept', '/rpc/ride_pay', '/rpc/ride_tip',
                           '/rpc/hire_book', '/rpc/c2c_book_seat', '/rpc/mygig_create', '/rpc/scheduled_ride_accept',
                           '/rpc/wallet_redeem_fare_coins', '/rpc/plus_join', '/rpc/set_my_payout_account',
                           '/rpc/sos_raise', '/rpc/set_driver_presence', '/rpc/set_login_pin',
                           '/rpc/claim_partner_by_phone', '/rpc/family_invite', '/rpc/admin_store_review_state',
                           '/rpc/admin_store_review_set', '/rpc/set_hourly_hire_config', '/rpc/admin_dashboard_live',
                           '/rpc/nearby_driver_etas', '/rpc/rider_live_map_cars', '/rpc/c2c_search_trips',
                           '/rpc/scheduled_rides_open', '/rpc/god_view_trail', '/rpc/my_qr_codes',
                           '/rpc/phone_change_lookup', '/rpc/delete_my_account', '/rpc/resolve'] loop
    perform pg_temp.as_caller(demo, meta, p, 'POST');
    perform pg_temp.check(pg_temp.sealed(), 'the demo account is refused ' || p);
  end loop;
  foreach p in array array['POST', 'PATCH', 'PUT', 'DELETE'] loop
    perform pg_temp.as_caller(demo, meta, '/ride_requests', p);
    perform pg_temp.check(pg_temp.sealed(), 'the demo account may not ' || p || ' a table');
  end loop;
  perform pg_temp.as_caller(demo, meta, '/profiles', 'PATCH');
  perform pg_temp.check(pg_temp.sealed(), 'the demo account may not change its profile (phone)');
  perform pg_temp.as_caller(demo, meta, '/ai_report_v_users', 'GET');
  perform pg_temp.check(pg_temp.sealed(), 'a view that reads as its owner is refused');
  -- The id alone (a token from before the flag) is sealed too.
  perform pg_temp.as_caller(demo, '{}', '/rpc/ride_offer_make', 'POST');
  perform pg_temp.check(pg_temp.sealed(), 'the demo id is sealed without the flag');

  -- Nobody else is touched.
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000333a1', '{}', '/rpc/ride_offer_make', 'POST');
  perform pg_temp.check(not pg_temp.sealed(), 'a rider may make offers');
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000333a1', '{}', '/ride_requests', 'POST');
  perform pg_temp.check(not pg_temp.sealed(), 'a rider may book');
  -- A rider can't make itself one with a token it wrote (app_metadata is
  -- Auth's): nor can it set the profile flag.
end $$;

-- ---- Writes, in depth: each blocked path ------------------------------------------------------------
do $$
declare
  demo text := public.store_review_user_id()::text;
  t text;
  e text;
begin
  -- As the demo account (a definer RPC or the API, whatever the way in).
  perform pg_temp.as_caller(demo, '{"store_review": true}');
  foreach t in array array['ride_requests', 'scheduled_rides', 'scheduled_ride_offers', 'c2c_bookings', 'c2c_trips',
                           'c2c_offers', 'hire_bookings', 'mygig_bookings', 'mygig_deliveries', 'mygig_offers',
                           'ev_orders', 'ride_offers', 'ride_messages', 'ride_calls', 'support_tickets',
                           'support_messages', 'safety_incidents', 'emergency_contacts', 'wallets',
                           'wallet_transactions', 'wallet_transfer_requests', 'payment_intents', 'plus_memberships',
                           'partner_payout_accounts', 'promo_redemptions', 'partners', 'partner_documents',
                           'vehicles', 'driver_presence', 'families', 'family_members', 'favourite_drivers',
                           'personal_qr_codes', 'phone_change_requests', 'sms_outbox', 'admin_access'] loop
    if to_regclass('public.' || t) is null then
      raise exception 'FAILED: % is gone: the seal list needs a look', t;
    end if;
    e := pg_temp.insert_error(format('insert into public.%I default values', t));
    perform pg_temp.check(e like 'STORE_REVIEW_DEMO%', format('the demo account can''t write %s (%s)', t, e));
  end loop;

  -- Naming the demo account, from anywhere (an admin, the service key).
  perform pg_temp.as_caller(null);
  e := pg_temp.insert_error(format(
    'insert into public.admin_access (profile_id, page, access_level) values (%L, ''*'', ''edit'')', demo));
  perform pg_temp.check(e like 'STORE_REVIEW_DEMO%', 'the demo account is never made an admin: ' || coalesce(e, 'ok'));
  e := pg_temp.insert_error(format('insert into public.wallet_transactions (user_id) values (%L)', demo));
  perform pg_temp.check(e like 'STORE_REVIEW_DEMO%', 'no money moves for the demo account: ' || coalesce(e, 'ok'));
  e := pg_temp.insert_error(format('insert into public.payment_intents (user_id, purpose, provider, amount) '
                                   'values (%L, ''topup'', ''test'', 10)', demo));
  perform pg_temp.check(e like 'STORE_REVIEW_DEMO%', 'no top-up for the demo account: ' || coalesce(e, 'ok'));
  e := pg_temp.insert_error(format('insert into public.ride_requests (rider_id) values (%L)', demo));
  perform pg_temp.check(e like 'STORE_REVIEW_DEMO%', 'no real ride for the demo account: ' || coalesce(e, 'ok'));
  e := pg_temp.insert_error(format('insert into public.driver_presence (profile_id) values (%L)', demo));
  perform pg_temp.check(e like 'STORE_REVIEW_DEMO%', 'the demo account never goes online: ' || coalesce(e, 'ok'));
  e := pg_temp.insert_error(format('insert into public.family_members (profile_id) values (%L)', demo));
  perform pg_temp.check(e like 'STORE_REVIEW_DEMO%', 'the demo account joins no family: ' || coalesce(e, 'ok'));
end $$;

-- ---- The account itself -----------------------------------------------------------------------------
do $$
declare
  demo uuid := public.store_review_user_id();
  e text;
begin
  perform pg_temp.as_caller(null);
  e := pg_temp.insert_error(format('update public.profiles set phone = ''+60123456789'' where id = %L', demo));
  perform pg_temp.check(e like 'STORE_REVIEW_DEMO%', 'its phone never changes: ' || coalesce(e, 'ok'));
  e := pg_temp.insert_error(format('update public.profiles set deleted_at = now() where id = %L', demo));
  perform pg_temp.check(e like 'STORE_REVIEW_DEMO%', 'it is never deleted: ' || coalesce(e, 'ok'));
  e := pg_temp.insert_error(format('update auth.users set phone = ''60123456789'' where id = %L', demo));
  perform pg_temp.check(e like 'STORE_REVIEW_DEMO%', 'its Auth phone never changes: ' || coalesce(e, 'ok'));
  e := pg_temp.insert_error(format('update auth.users set phone_change = ''60123456789'' where id = %L', demo));
  perform pg_temp.check(e like 'STORE_REVIEW_DEMO%', 'no phone change is started: ' || coalesce(e, 'ok'));

  -- The flag is the database's: an admin's token can't set or clear it.
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000333c1');
  e := pg_temp.insert_error('update public.profiles set store_review = true where id = ''00000000-0000-0000-0000-0000000333a1''');
  perform pg_temp.check(e like 'STORE_REVIEW_FLAG%', 'no token sets the flag: ' || coalesce(e, 'ok'));
  e := pg_temp.insert_error(format('update public.profiles set store_review = false where id = %L', demo));
  perform pg_temp.check(e like 'STORE_REVIEW_FLAG%', 'no token clears the flag: ' || coalesce(e, 'ok'));
end $$;

-- ---- Reads: nothing of anyone else ------------------------------------------------------------------
set local role authenticated;
do $$
declare
  demo text := public.store_review_user_id()::text;
begin
  perform pg_temp.as_caller(demo, '{"store_review": true}');
  perform pg_temp.check((select count(*) from public.profiles) = 1
                        and (select id from public.profiles) = demo::uuid, 'the demo account reads only its profile');
  perform pg_temp.check((select count(*) from public.saved_places) = 0, 'no one else''s saved places');
  perform pg_temp.check((select count(*) from public.partners) = 0, 'no partners');
  perform pg_temp.check((select count(*) from public.driver_presence) = 0, 'no drivers nearby');
  perform pg_temp.check((select count(*) from public.ride_requests) = 0, 'no ride requests');
  perform pg_temp.check((select count(*) from public.admin_access) = 0, 'no admin rows');
  -- Settings everyone reads still read.
  perform pg_temp.check((select count(*) from public.country_phone_rules) > 100, 'the country list still reads');

  -- The rider still reads their own as before.
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000333a1');
  perform pg_temp.check((select count(*) from public.saved_places) = 1, 'a rider still reads their saved places');
end $$;

-- Storage: nothing uploaded by the demo account.
do $$
declare
  e text;
begin
  perform pg_temp.as_caller(public.store_review_user_id()::text, '{"store_review": true}');
  e := pg_temp.insert_error(format(
    'insert into storage.objects (bucket_id, name, owner_id) values (''business-documents'', %L, %L)',
    public.store_review_user_id()::text || '/x.jpg', public.store_review_user_id()::text));
  perform pg_temp.check(e like '%row-level security%', 'the demo account uploads nothing: ' || coalesce(e, 'ok'));
end $$;
reset role;

-- Every table with a person column has the read seal (a table added after
-- 0333 is named here: give it the policy as 0333 does).
do $$
declare
  missing text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into missing
    from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relrowsecurity
     and cardinality(public.store_review_person_columns(c.oid::regclass)) > 0
     and not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname
                       and p.policyname = 'store review sealed read' and p.permissive = 'RESTRICTIVE');
  if missing is not null then
    raise notice 'store_review_0333: tables without the store review read seal: %', missing;
  end if;
  perform pg_temp.check(exists (select 1 from pg_policies where tablename = 'ride_requests'
                                  and policyname = 'store review sealed read' and permissive = 'RESTRICTIVE'),
    'ride_requests has the restrictive read seal');
end $$;

-- ---- News and offers --------------------------------------------------------------------------------
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000333a2') on conflict do nothing;
insert into public.profiles (id, name) values ('00000000-0000-0000-0000-0000000333a2', 'Bala Rider')
on conflict (id) do update set name = excluded.name;

select pg_temp.check(not (select news_offers from public.profiles where id = '00000000-0000-0000-0000-0000000333a1'),
  'News and offers is off until chosen (opt-in)');
select pg_temp.check(not exists (select 1 from public.profiles where news_offers),
  'nobody is opted in by the migration');

set local role authenticated;
do $$
begin
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000333a1', '{}', '/rpc/set_news_offers', 'POST');
  perform pg_temp.check(public.set_news_offers(true), 'a rider opts in');
  -- Only their own: the RPC knows no other account, and nobody else reads the list.
  begin
    perform public.news_offers_on_ids();
    raise exception 'FAILED: a rider read who opted in to News and offers';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.profiles set news_offers = true where id = '00000000-0000-0000-0000-0000000333a2';
  exception when others then null;
  end;
  -- The demo account's switch works too (and is not sealed).
  perform pg_temp.as_caller(public.store_review_user_id()::text, '{"store_review": true}', '/rpc/set_news_offers', 'POST');
  perform pg_temp.check(not pg_temp.sealed(), 'the demo account may use its News and offers switch');
  perform pg_temp.check(public.set_news_offers(true), 'the demo account opts in');
end $$;
reset role;

do $$
declare
  reach uuid[];
begin
  select array_agg(x) into reach from public.news_offers_on_ids() x;
  perform pg_temp.check('00000000-0000-0000-0000-0000000333a1' = any (reach), 'a broadcast reaches the rider who opted in');
  perform pg_temp.check(not ('00000000-0000-0000-0000-0000000333a2' = any (reach)),
    'a broadcast skips a rider who did not opt in (and another rider could not opt them in)');
  perform pg_temp.check(not (public.store_review_user_id() = any (reach)), 'no real broadcast reaches the demo account');
  -- Trip, money and account messages still go to a rider who never opted in.
  perform pg_temp.as_caller(null);
  perform public.enqueue_notification('00000000-0000-0000-0000-0000000333a2', 'test-333:status', 'ride_status',
                                      'high', 'Your driver has arrived', 'Patrick is waiting', '{"type": "ride_status"}', null);
  perform pg_temp.check(exists (select 1 from public.notification_outbox
                                 where profile_id = '00000000-0000-0000-0000-0000000333a2' and event_id = 'test-333:status'),
    'a trip message is still queued for a rider not opted in');
end $$;

set local role authenticated;
do $$
begin
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000333a1');
  perform pg_temp.check(not public.set_news_offers(false), 'opted out again');
end $$;
reset role;
select pg_temp.check(not (select news_offers from public.profiles where id = '00000000-0000-0000-0000-0000000333a1'),
  'saved off');


-- ---- Passenger location check-ins when the app is closed -----------------------------------------
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000333d1') on conflict do nothing;  -- a driver
insert into public.profiles (id, name) values ('00000000-0000-0000-0000-0000000333d1', 'Dev Driver')
on conflict (id) do update set name = excluded.name;
insert into public.partners (id, auth_user_id, name, phone, status, plate, vehicle, vehicle_type) values
  ('00000000-0000-0000-0000-0000000333e1', '00000000-0000-0000-0000-0000000333d1', 'Dev', '60123330001', 'approved',
   'SR 333', 'Proton Saga', 'Car');
insert into public.push_tokens (profile_id, token, location_always, bg_key_hash) values
  ('00000000-0000-0000-0000-0000000333a1', 'sr333-rider', true,
   encode(extensions.digest(convert_to('rider333rider333rider333rider333rider333', 'UTF8'), 'sha256'), 'hex')),
  ('00000000-0000-0000-0000-0000000333d1', 'sr333-driver', true,
   encode(extensions.digest(convert_to('driver333driver333driver333driver333drv', 'UTF8'), 'sha256'), 'hex'));

create function pg_temp.bg(p_key text) returns int language plpgsql as $$
begin
  -- One report a minute at most: each try counts as the first.
  update public.push_tokens set located_at = null where token like 'sr333-%';
  return public.push_background_location(p_key, 3.15, 101.71);
end;
$$;

do $$
begin
  perform pg_temp.check(not (public.location_checkins_config() ->> 'passengers')::boolean, 'the switch is off by default');
  perform pg_temp.check(not (select location_checkins from public.profiles where id = '00000000-0000-0000-0000-0000000333a1'),
    'a passenger has not opted in by default');
  -- Off: a passenger's closed-app report is ignored; a driver's is kept as before.
  perform pg_temp.check(pg_temp.bg('rider333rider333rider333rider333rider333') = 0, 'switch off: passenger check-in ignored');
  perform pg_temp.check(pg_temp.bg('driver333driver333driver333driver333drv') = 1, 'drivers unchanged');
end $$;

-- Only an admin with edit on App Settings turns it on.
set local role authenticated;
do $$
begin
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000333c2');
  begin
    perform public.set_location_checkins_config('{"passengers": true}');
    raise exception 'FAILED: a read-only admin turned check-ins on';
  exception when insufficient_privilege then null;
  end;
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000333c1');
  perform pg_temp.check((public.set_location_checkins_config('{"passengers": true}') ->> 'passengers')::boolean,
    'the edit admin turns the switch on');
end $$;
reset role;

do $$
begin
  perform pg_temp.as_caller(null);
  perform pg_temp.check(pg_temp.bg('rider333rider333rider333rider333rider333') = 0,
    'switch on, passenger not opted in: still ignored');
end $$;

set local role authenticated;
do $$
begin
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000333a1', '{}', '/rpc/set_location_checkins', 'POST');
  perform pg_temp.check(public.set_location_checkins(true), 'the passenger opts in');
end $$;
reset role;

do $$
begin
  perform pg_temp.as_caller(null);
  perform pg_temp.check(pg_temp.bg('rider333rider333rider333rider333rider333') = 1, 'switch on and opted in: kept');
end $$;

set local role authenticated;
do $$
begin
  perform pg_temp.as_caller('00000000-0000-0000-0000-0000000333a1');
  perform pg_temp.check(not public.set_location_checkins(false), 'the passenger opts out');
end $$;
reset role;

do $$
begin
  perform pg_temp.as_caller(null);
  perform pg_temp.check(pg_temp.bg('rider333rider333rider333rider333rider333') = 0, 'opting out stops it at once');
  perform public.set_location_checkins_config('{"passengers": false}');
  perform pg_temp.check(pg_temp.bg('driver333driver333driver333driver333drv') = 1, 'drivers unchanged with the switch off');
end $$;

select 'store_review_0333: all passed';
rollback;
