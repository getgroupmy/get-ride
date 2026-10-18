-- ============================================================================
-- Regression test for migration 0161: My QR (GET.Referral, GET.me, GET.now).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/my_qr.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000161a1'),  -- rider Aminah
  ('00000000-0000-0000-0000-0000000161a2'),  -- rider Badrul (hidden by Dan)
  ('00000000-0000-0000-0000-0000000161b1'),  -- driver Dan (approved)
  ('00000000-0000-0000-0000-0000000161b2'),  -- driver Eve (approved, online nearby)
  ('00000000-0000-0000-0000-0000000161b3'),  -- driver Fay (blocked)
  ('00000000-0000-0000-0000-0000000161b4')   -- driver Gus (unapproved)
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000161%'
on conflict do nothing;
update public.profiles set name = 'Aminah Binti Abu' where id = '00000000-0000-0000-0000-0000000161a1';
update public.profiles set name = 'Daniel Lee', phone = '+60110000161' where id = '00000000-0000-0000-0000-0000000161b1';
update public.profiles set referral_code = 'amin-22' where id = '00000000-0000-0000-0000-0000000161a1';
insert into public.partners (auth_user_id, name, phone, status, plate) values
  ('00000000-0000-0000-0000-0000000161b1', 'Dan', '+60110000161', 'approved', 'WXY 1610'),
  ('00000000-0000-0000-0000-0000000161b2', 'Eve', '+60110000162', 'approved', null),
  ('00000000-0000-0000-0000-0000000161b3', 'Fay', '+60110000163', 'blocked', null),
  ('00000000-0000-0000-0000-0000000161b4', 'Gus', '+60110000164', 'unapproved', null);
-- Dan hid Badrul.
insert into public.favourite_drivers (rider_id, driver_id, hidden_by_driver, hidden_at)
values ('00000000-0000-0000-0000-0000000161a2', '00000000-0000-0000-0000-0000000161b1', true, now());
-- Eve is online right by the pickup used below (so an ordinary request would reach her).
insert into public.driver_presence (profile_id, online, lat, lng)
values ('00000000-0000-0000-0000-0000000161b2', true, 3.1580, 101.7110)
on conflict (profile_id) do update set online = true, lat = 3.1580, lng = 101.7110, updated_at = now();

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated, anon;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
grant execute on function pg_temp.as_anon() to anon, authenticated;

-- The error a statement raises ('' when it doesn't).
create or replace function pg_temp.error_of(p_sql text) returns text language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return sqlerrm;
  end;
  return '';
end $$;
grant execute on function pg_temp.error_of(text) to authenticated, anon;

create temp table qr (name text primary key, id uuid, token text);
grant select, insert, update, delete on qr to authenticated, anon;

-- 1. Grants: no direct client writes; anon may only resolve --------------------------------
select pg_temp.check(not has_function_privilege('anon', f, 'execute'), 'anon cannot execute ' || f)
  from unnest(array[
    'public.my_qr_codes()', 'public.generate_my_qr(text, integer)', 'public.expire_my_qr(uuid)',
    'public.reactivate_my_qr(uuid, integer)', 'public.add_favourite_driver_by_qr(text)'
  ]) f;
select pg_temp.check(has_function_privilege('anon', 'public.resolve_qr(text)', 'execute'), 'anon can resolve');
select pg_temp.check(not has_function_privilege('authenticated', f, 'execute'), 'clients cannot execute ' || f)
  from unnest(array[
    'public.personal_qr_new_token()', 'public.personal_qr_retire_live(uuid, text, uuid)',
    'public.personal_qr_referral_code(uuid)', 'public.personal_qr_record_miss(uuid, text)'
  ]) f;

set local role authenticated;

-- 2. Generating: one active per kind; a new one retires the old -----------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000161b1');
insert into qr select 'dan_now1', (j->'qr'->>'id')::uuid, j->'qr'->>'token'
  from (select public.generate_my_qr('now', 3600) j) s;
select pg_temp.check((select token ~ '^[A-Za-z0-9_-]{22}$' from qr where name = 'dan_now1'), 'a token is 22 base64url characters');
select pg_temp.check(pg_temp.error_of($q$insert into public.personal_qr_codes (owner_id, kind, token)
                                        values (auth.uid(), 'me', 'AAAAAAAAAAAAAAAAAAAAAA')$q$) <> '',
                     'no direct client insert');
select pg_temp.check(pg_temp.error_of($q$update public.personal_qr_codes set revoked_at = null$q$) = ''
                     and (select count(*) from public.personal_qr_codes where revoked_at is null) = 1,
                     'a client update changes nothing (no write policy)');
insert into qr select 'dan_now2', (j->'qr'->>'id')::uuid, j->'qr'->>'token'
  from (select public.generate_my_qr('NOW') j) s;
select pg_temp.check((select count(*) = 2 from public.personal_qr_codes where kind = 'now'), 'two now codes exist');
select pg_temp.check((select count(*) = 1 from public.my_qr_codes() where kind = 'now' and status = 'active'),
                     'only one active now code');
select pg_temp.check((select status = 'revoked' and reactivatable from public.my_qr_codes()
                       where id = (select id from qr where name = 'dan_now1')),
                     'generating retires the previous code, which can be revived');
select pg_temp.check((select expires_at is null from public.my_qr_codes() where id = (select id from qr where name = 'dan_now2')),
                     'no ttl = never expires');
insert into qr select 'dan_me', (j->'qr'->>'id')::uuid, j->'qr'->>'token'
  from (select public.generate_my_qr('me', 86400) j) s;
insert into qr select 'dan_ref', (j->'qr'->>'id')::uuid, j->'qr'->>'token'
  from (select public.generate_my_qr('referral', 604800) j) s;
select pg_temp.check((select count(*) = 3 from public.my_qr_codes() where status = 'active'), 'one active per kind, three kinds');
select pg_temp.check((select (array_agg(status))[1] = 'active' from public.my_qr_codes()), 'active codes are listed first');
select pg_temp.check(public.generate_my_qr('me', 120)->>'error' = 'invalid_ttl', 'only the offered ttls');
select pg_temp.check(public.generate_my_qr('vip')->>'error' = 'invalid_kind', 'unknown kinds are refused');

-- me / now are for drivers only (and not blocked ones); referral is for anyone.
select pg_temp.as_user('00000000-0000-0000-0000-0000000161a1');
select pg_temp.check(public.generate_my_qr('me')->>'error' = 'not_a_driver', 'a rider cannot make a GET.me code');
select pg_temp.check(public.generate_my_qr('now')->>'error' = 'not_a_driver', 'a rider cannot make a GET.now code');
insert into qr select 'amin_ref', (j->'qr'->>'id')::uuid, j->'qr'->>'token'
  from (select public.generate_my_qr('referral') j) s;
select pg_temp.check((select id is not null from qr where name = 'amin_ref'), 'a rider makes a referral code');
select pg_temp.check(not exists (select 1 from public.personal_qr_codes where owner_id <> auth.uid()),
                     'the owner reads only their own codes');
select pg_temp.check(public.expire_my_qr((select id from qr where name = 'dan_me'))->>'error' = 'not_found',
                     'nobody else can expire a code');
select pg_temp.check(public.reactivate_my_qr((select id from qr where name = 'dan_now1'))->>'error' = 'not_found',
                     'nobody else can revive a code');
select pg_temp.as_user('00000000-0000-0000-0000-0000000161b3');
select pg_temp.check(public.generate_my_qr('now')->>'error' = 'driver_unavailable', 'a blocked driver cannot');
select pg_temp.check(public.generate_my_qr('referral')->>'ok' = 'true', 'a blocked driver still has a referral code');

-- 3. Reactivating: the old token works again, the current one is retired -------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000161b1');
select pg_temp.check(public.resolve_qr((select token from qr where name = 'dan_now1'))->>'status' = 'expired',
                     'a retired token resolves as expired');
select pg_temp.check((public.reactivate_my_qr((select id from qr where name = 'dan_now1'), 3600)->'qr'->>'status') = 'active',
                     'reactivate brings the old code back');
select pg_temp.check((select status = 'revoked' from public.my_qr_codes() where id = (select id from qr where name = 'dan_now2')),
                     'reactivating retires the current one');
select pg_temp.check((select token = (select token from qr where name = 'dan_now1') from public.my_qr_codes()
                       where kind = 'now' and status = 'active'),
                     'the same token is live again');
select pg_temp.check(public.reactivate_my_qr((select id from qr where name = 'dan_now1'), 7)->>'error' = 'invalid_ttl',
                     'reactivate checks the ttl too');

-- Expire by hand.
select pg_temp.check(public.expire_my_qr((select id from qr where name = 'dan_me'))->'qr'->>'status' = 'revoked',
                     'the owner expires a code');
select pg_temp.check(public.resolve_qr((select token from qr where name = 'dan_me'))->>'status' = 'expired',
                     'an expired me code resolves as expired');
select pg_temp.check((public.reactivate_my_qr((select id from qr where name = 'dan_me'), 86400)->'qr'->>'status') = 'active',
                     'and can be revived');

-- Only the last 10 of a kind can be revived.
select count(*) from (select public.generate_my_qr('referral') from generate_series(1, 11)) s;
select pg_temp.check(public.reactivate_my_qr((select id from qr where name = 'dan_ref'))->>'error' = 'not_reactivatable',
                     'a code older than the last 10 cannot be revived');
select pg_temp.check((select count(*) = 12 from public.my_qr_codes() where kind = 'referral'), 'history is listed');

reset role;

-- 4. Auto-expiry: resolves as expired, does not block a new code ------------------------------
update public.personal_qr_codes set expires_at = now() - interval '1 second'
 where id = (select id from qr where name = 'dan_now1');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000161a1');
select pg_temp.check(public.resolve_qr((select token from qr where name = 'dan_now1')) = '{"status":"expired"}'::jsonb,
                     'a lapsed token resolves as expired, and nothing else');
select pg_temp.as_user('00000000-0000-0000-0000-0000000161b1');
select pg_temp.check((select status = 'expired' from public.my_qr_codes() where id = (select id from qr where name = 'dan_now1')),
                     'a lapsed code lists as expired');
insert into qr select 'dan_now3', (j->'qr'->>'id')::uuid, j->'qr'->>'token'
  from (select public.generate_my_qr('now') j) s;
select pg_temp.check((select id is not null from qr where name = 'dan_now3'), 'a lapsed code does not block a new one');
select pg_temp.check((select status = 'expired' from public.my_qr_codes() where id = (select id from qr where name = 'dan_now1')),
                     'a lapsed code retired later still reads expired');

-- 5. Resolving --------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000161a2');
select pg_temp.check((select r->>'status' = 'active' and r->>'kind' = 'referral' and r->>'referral_code' = 'AMIN22'
                             and r->>'owner_name' = 'Aminah A.' and r->>'own' = 'false'
                        from (select public.resolve_qr('https://getride.my/q/ref/' || (select token from qr where name = 'amin_ref')) r) s),
                     'referral: code and masked name (https payload accepted)');
select pg_temp.check((select r->>'kind' = 'me' and r#>>'{driver,driver_id}' = '00000000-0000-0000-0000-0000000161b1'
                             and r->>'available' = 'false' and r::text not like '%+6011%'
                        from (select public.resolve_qr('getride://me/' || (select token from qr where name = 'dan_me')) r) s),
                     'me: a driver card without a phone; unavailable to a hidden rider');
select pg_temp.as_user('00000000-0000-0000-0000-0000000161a1');
select pg_temp.check((select r->>'kind' = 'now' and r->>'available' = 'true' and r->>'online' = 'false'
                             and r->>'own' = 'false' and r::text not like '%+6011%'
                        from (select public.resolve_qr((select token from qr where name = 'dan_now3')) r) s),
                     'now: driver card, available, offline');
select pg_temp.check(public.resolve_qr('ZZZZZZZZZZZZZZZZZZZZZZ')->>'status' = 'unknown', 'an unknown token');
select pg_temp.check(public.resolve_qr('not a token')->>'status' = 'unknown', 'garbage is unknown');
-- Unknown tokens are rate limited per account.
select count(*) from (select public.resolve_qr('Unknown' || lpad(i::text, 15, '0')) from generate_series(1, 20) i) s;
select pg_temp.check(public.resolve_qr((select token from qr where name = 'dan_now3'))->>'status' = 'rate_limited',
                     'too many unknown tokens: no lookups for a while');
reset role;
delete from public.auth_rate_counts where bucket like 'my_qr_miss%';

-- Anon: referral code only; nothing of a driver.
set local role anon;
select pg_temp.as_anon();
select pg_temp.check(public.resolve_qr((select token from qr where name = 'amin_ref'))
                       = '{"status":"active","kind":"referral","referral_code":"AMIN22"}'::jsonb,
                     'anon gets only the referral code');
select pg_temp.check(public.resolve_qr((select token from qr where name = 'dan_now3'))
                       = '{"status":"sign_in_required","kind":"now"}'::jsonb,
                     'anon gets nothing of a driver');
select pg_temp.check(public.resolve_qr((select token from qr where name = 'dan_now1')) = '{"status":"expired"}'::jsonb,
                     'anon: expired');
select pg_temp.check(pg_temp.error_of($q$select public.generate_my_qr('referral')$q$) <> '', 'anon cannot generate');
select pg_temp.check(pg_temp.error_of($q$select count(*) from public.personal_qr_codes$q$) <> '', 'anon cannot read the table');
reset role;

-- 6. GET.me adds the driver as a favourite ------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000161a1');
select pg_temp.check((public.add_favourite_driver_by_qr('https://getride.my/q/me/' || (select token from qr where name = 'dan_me'))
                       #>>'{driver,driver_id}') = '00000000-0000-0000-0000-0000000161b1',
                     'a GET.me code adds the driver');
select pg_temp.check(exists (select 1 from public.favourite_drivers where rider_id = auth.uid()
                              and driver_id = '00000000-0000-0000-0000-0000000161b1'),
                     'the favourite is stored');
select pg_temp.check(public.resolve_qr((select token from qr where name = 'dan_me'))->>'already_favourite' = 'true',
                     'resolve says already a favourite');
select pg_temp.check(public.add_favourite_driver_by_qr((select token from qr where name = 'dan_now3'))->>'error' = 'wrong_kind',
                     'a GET.now code is not a GET.me code');
select pg_temp.check(public.add_favourite_driver_by_qr((select token from qr where name = 'dan_now1'))->>'error' = 'expired',
                     'an expired code adds nobody');
select pg_temp.as_user('00000000-0000-0000-0000-0000000161b1');
select pg_temp.check(public.add_favourite_driver_by_qr((select token from qr where name = 'dan_me'))->>'error' = 'own_code',
                     'a driver cannot add themselves');

-- 7. GET.now books that driver only, with no automatic fallback -----------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000161a1');
insert into public.ride_requests (id, rider_id, status, fare, service, pickup_name, pickup_lat, pickup_lng,
                                  target_driver_ids, direct_qr_token)
values ('00000000-0000-0000-0000-0000000161e1', '00000000-0000-0000-0000-0000000161a1', 'open', 20, 'Car', 'KLCC',
        3.1579, 101.7116, array['00000000-0000-0000-0000-0000000161b2']::uuid[],
        'https://getride.my/q/now/' || (select token from qr where name = 'dan_now3'));
reset role;
select pg_temp.check((select target_driver_ids = array['00000000-0000-0000-0000-0000000161b1']::uuid[]
                             and direct_driver_id = '00000000-0000-0000-0000-0000000161b1'
                             and direct_qr_id = (select id from qr where name = 'dan_now3')
                             and direct_qr_token is null
                             and targeted_until > now() + interval '9 minutes'
                             and my_ride_max_km is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000161e1'),
                     'targets only the driver, past the request''s expiry; favourites sent are dropped; token not stored');
select pg_temp.check((select array_agg(profile_id) = array['00000000-0000-0000-0000-0000000161b1']::uuid[]
                        from public.ride_request_pushes where request_id = '00000000-0000-0000-0000-0000000161e1'),
                     'only the driver is pushed (not Eve, online next to the pickup)');
select pg_temp.check((select kind = 'my_ride' from public.ride_request_pushes
                       where request_id = '00000000-0000-0000-0000-0000000161e1'), 'pushed as a targeted request');
select pg_temp.check(public.ride_request_push_message(gen_random_uuid(), 'KLCC', null, 20, 'MYR', 'direct')->>'title'
                       = 'Passenger booked you directly', 'the direct push title');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000161b2');
select pg_temp.check(not exists (select 1 from public.ride_requests where id = '00000000-0000-0000-0000-0000000161e1'),
                     'other drivers cannot see it');
select pg_temp.as_user('00000000-0000-0000-0000-0000000161b1');
select pg_temp.check(exists (select 1 from public.ride_requests where id = '00000000-0000-0000-0000-0000000161e1'),
                     'the driver sees it');
-- (Refused or silently kept: either way nothing changes, checked below.)
select pg_temp.error_of($q$update public.ride_requests set direct_driver_id = null, targeted_until = now()
                           where id = '00000000-0000-0000-0000-0000000161e1'$q$);
select pg_temp.as_user('00000000-0000-0000-0000-0000000161a1');
update public.ride_requests set direct_driver_id = null, targeted_until = now()
 where id = '00000000-0000-0000-0000-0000000161e1';
select pg_temp.check(pg_temp.error_of($q$select public.ride_request_add_targets('00000000-0000-0000-0000-0000000161e1',
                                         array['00000000-0000-0000-0000-0000000161b2']::uuid[])$q$) like '%direct_booking%',
                     'no favourites can be added to a direct booking');
-- Un-favouriting the driver does not open it to everybody.
select public.remove_favourite_driver('00000000-0000-0000-0000-0000000161b1');
reset role;
select pg_temp.check((select direct_driver_id = '00000000-0000-0000-0000-0000000161b1'
                             and target_driver_ids = array['00000000-0000-0000-0000-0000000161b1']::uuid[]
                             and targeted_until > now() + interval '9 minutes' and fallback_pushed_at is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000161e1'),
                     'clients cannot change the direct columns; removing a favourite leaves it alone');

-- The dispatch tick leaves it alone, even once the window is over.
update public.ride_requests set created_at = now() - interval '6 minutes', targeted_until = now() - interval '1 second'
 where id = '00000000-0000-0000-0000-0000000161e1';
select public.ride_requests_dispatch_tick();
select pg_temp.check((select fallback_pushed_at is null and widened_pushed_at is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000161e1'),
                     'no automatic fallback');
select pg_temp.check((select count(*) = 1 from public.ride_request_pushes
                       where request_id = '00000000-0000-0000-0000-0000000161e1'),
                     'nobody else is pushed');
update public.ride_requests set created_at = now(), targeted_until = now() + interval '10 minutes'
 where id = '00000000-0000-0000-0000-0000000161e1';

-- The rider may still offer it to all nearby, explicitly.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000161a1');
select pg_temp.check(public.ride_request_offer_to_all('00000000-0000-0000-0000-0000000161e1')->>'opened' = 'true',
                     'the rider can open it to all');
reset role;
select pg_temp.check((select fallback_pushed_at is not null from public.ride_requests
                       where id = '00000000-0000-0000-0000-0000000161e1'), 'opened by the rider');
select pg_temp.check(exists (select 1 from public.ride_request_pushes where request_id = '00000000-0000-0000-0000-0000000161e1'
                              and profile_id = '00000000-0000-0000-0000-0000000161b2'),
                     'then nearby drivers are pushed');
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000161e1';

-- Refusals: nothing is written.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000161a1');
select pg_temp.check(pg_temp.error_of(format($q$insert into public.ride_requests (rider_id, status, fare, service, pickup_lat, pickup_lng, direct_qr_token)
                                               values (auth.uid(), 'open', 20, 'Car', 3.1579, 101.7116, %L)$q$,
                                              (select token from qr where name = 'dan_now1'))) like '%QR_EXPIRED%',
                     'an expired GET.now code refuses the insert');
select pg_temp.check(pg_temp.error_of(format($q$insert into public.ride_requests (rider_id, status, fare, service, pickup_lat, pickup_lng, direct_qr_token)
                                               values (auth.uid(), 'open', 20, 'Car', 3.1579, 101.7116, %L)$q$,
                                              (select token from qr where name = 'dan_me'))) like '%QR_EXPIRED%',
                     'a GET.me code does not book');
select pg_temp.check(pg_temp.error_of($q$insert into public.ride_requests (rider_id, status, fare, service, pickup_lat, pickup_lng, direct_qr_token)
                                        values (auth.uid(), 'open', 20, 'Car', 3.1579, 101.7116, 'ZZZZZZZZZZZZZZZZZZZZZZ')$q$)
                       like '%QR_EXPIRED%',
                     'an unknown code refuses the insert');
select pg_temp.as_user('00000000-0000-0000-0000-0000000161a2');
select pg_temp.check(pg_temp.error_of(format($q$insert into public.ride_requests (rider_id, status, fare, service, pickup_lat, pickup_lng, direct_qr_token)
                                               values (auth.uid(), 'open', 20, 'Car', 3.1579, 101.7116, %L)$q$,
                                              (select token from qr where name = 'dan_now3'))) like '%QR_DRIVER_UNAVAILABLE%',
                     'a rider the driver hid cannot book them');
select pg_temp.as_user('00000000-0000-0000-0000-0000000161b1');
select pg_temp.check(pg_temp.error_of(format($q$insert into public.ride_requests (rider_id, status, fare, service, pickup_lat, pickup_lng, direct_qr_token)
                                               values (auth.uid(), 'open', 20, 'Car', 3.1579, 101.7116, %L)$q$,
                                              (select token from qr where name = 'dan_now3'))) like '%QR_SELF_BOOKING%',
                     'a driver cannot book themselves');
reset role;
select pg_temp.check(not exists (select 1 from public.ride_requests
                                  where rider_id in ('00000000-0000-0000-0000-0000000161a2', '00000000-0000-0000-0000-0000000161b1')),
                     'refused inserts wrote nothing');

-- The code is not consumed: the same GET.now code books again.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000161a1');
insert into public.ride_requests (id, rider_id, status, fare, service, pickup_lat, pickup_lng, direct_qr_token)
values ('00000000-0000-0000-0000-0000000161e2', auth.uid(), 'open', 20, 'Car', 3.1579, 101.7116,
        (select token from qr where name = 'dan_now3'));
reset role;
select pg_temp.check((select direct_driver_id = '00000000-0000-0000-0000-0000000161b1'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000161e2'),
                     'the code books again');

-- An ordinary request is untouched.
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000161e2';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000161a1');
insert into public.ride_requests (id, rider_id, status, fare, service, pickup_lat, pickup_lng)
values ('00000000-0000-0000-0000-0000000161e3', auth.uid(), 'open', 20, 'Car', 3.1579, 101.7116);
reset role;
select pg_temp.check((select direct_driver_id is null and target_driver_ids is null and targeted_until is null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000161e3'),
                     'a request without a code is ordinary');

select 'my_qr: all passed';
rollback;
