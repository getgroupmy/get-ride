-- ============================================================================
-- Regression test for migration 0433: who may change the server's side of a
-- ride request.
--   * Through the API the rules on a ride hold for everybody but an admin
--     who may edit rides: for the rider and the driver, and for an admin who
--     may only read rides, or whose pages edit something else, on the rides
--     they book and drive.
--   * Who the rider of a ride is, is changed by an admin who may edit rides
--     and by the account link (covered in account_deletion.sql), nobody else.
--   * The server writes as before.
--   * A rider still books, prices and cancels their request; an approved
--     driver still bids.
-- All names are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_guards_page_scope_0433.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000433a1'),  -- a rider
  ('00000000-0000-0000-0000-0000000433d1'),  -- an approved driver
  ('00000000-0000-0000-0000-0000000433b1'),  -- back office: may only read rides; books rides
  ('00000000-0000-0000-0000-0000000433b2'),  -- back office: edits another page; an approved driver
  ('00000000-0000-0000-0000-0000000433c1')   -- back office: may edit rides
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000433%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000433b1', 'admin-rides', 'read'),
  ('00000000-0000-0000-0000-0000000433b2', 'admin-settings-ip-access', 'edit'),
  ('00000000-0000-0000-0000-0000000433c1', 'admin-rides', 'edit')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000433d1', 'Driver 0433', '+60100004331', 'approved'),
  ('00000000-0000-0000-0000-0000000433b2', 'Other Page 0433', '+60100004332', 'approved');

-- GET.credit may not go below zero, and the driver from the back office owes RM 10.
insert into public.app_settings (key, value) values ('commission', '{"allowNegativeCredit": false}'::jsonb)
on conflict (key) do update set value = public.app_settings.value || excluded.value;
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note) values
  ('00000000-0000-0000-0000-0000000433b2', 'get_credit', 'commission', -10, 'Test debt 0433');

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to authenticated, service_role;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

-- [p_sql] must be refused, and with [p_error]: a refusal for any other reason
-- (a policy, another rule) is not the rule under test.
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

-- 1. A new request, from an admin who may only read rides ------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000433b1');
select pg_temp.check(public.caller_is_admin() and not public.caller_admin_can_write('ride_requests'),
  'reading rides is not editing them');
select pg_temp.refused($q$insert into public.ride_requests (rider_id, partner_id, status, fare, ride_fare, pickup_name, pickup_lat, pickup_lng)
  values (auth.uid(), '00000000-0000-0000-0000-0000000433d1', 'open', 20, 20, 'KLCC', 3.15, 101.71)$q$,
  'RIDE_PARTNER_SERVER_ONLY', 'a new request that names its driver');
select pg_temp.refused($q$insert into public.ride_requests (rider_id, status, fare, ride_fare, pickup_name, pickup_lat, pickup_lng)
  values (auth.uid(), 'completed', 20, 20, 'KLCC', 3.15, 101.71)$q$,
  'RIDE_STATUS_TRANSITION', 'a new request that starts completed');
select pg_temp.refused($q$insert into public.ride_requests (rider_id, status, fare, ride_fare, payment_status, paid_amount, pickup_name, pickup_lat, pickup_lng)
  values (auth.uid(), 'open', 20, 20, 'paid', 20, 'KLCC', 3.15, 101.71)$q$,
  'RIDE_SERVER_ONLY', 'a new request that starts paid');
select pg_temp.refused($q$insert into public.ride_requests (rider_id, status, fare, ride_fare, toll_charges, pickup_name, pickup_lat, pickup_lng)
  values (auth.uid(), 'open', 20, 20, 5, 'KLCC', 3.15, 101.71)$q$,
  'RIDE_CHARGES_DRIVER_ONLY', 'a new request with tolls');
select pg_temp.refused($q$insert into public.ride_requests (rider_id, status, fare, ride_fare, waiting_charge, pickup_name, pickup_lat, pickup_lng)
  values (auth.uid(), 'open', 20, 20, 1, 'KLCC', 3.15, 101.71)$q$,
  'RIDE_SERVER_ONLY', 'a new request with a waiting charge');
select pg_temp.refused($q$insert into public.ride_requests (rider_id, status, fare, ride_fare, mygig, pickup_name, pickup_lat, pickup_lng)
  values (auth.uid(), 'open', 20, 20, '{}'::jsonb, 'KLCC', 3.15, 101.71)$q$,
  'RIDE_SERVER_ONLY', 'a new request with myGiG terms');
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, pickup_name, pickup_lat, pickup_lng)
values ('00000000-0000-0000-0000-0000000433e1', auth.uid(), 'open', 20, 20, 'KLCC', 3.15, 101.71);
select pg_temp.refused($q$insert into public.ride_requests (rider_id, status, fare, ride_fare, pickup_name, pickup_lat, pickup_lng)
  values (auth.uid(), 'open', 20, 20, 'KLCC', 3.15, 101.71)$q$,
  'RIDE_REQUEST_DUPLICATE', 'a second request while one is on the go');

-- 2. Their own open request -------------------------------------------------------------------------
select pg_temp.refused($q$update public.ride_requests set commission_rate = 0, commission_amount = 0
  where id = '00000000-0000-0000-0000-0000000433e1'$q$, 'RIDE_SERVER_ONLY', 'the commission on their ride');
select pg_temp.refused($q$update public.ride_requests set status = 'completed'
  where id = '00000000-0000-0000-0000-0000000433e1'$q$, 'RIDE_STATUS_TRANSITION', 'completing their own open request');
select pg_temp.refused($q$update public.ride_requests set payment_status = 'paid', paid_amount = 20, paid_at = now()
  where id = '00000000-0000-0000-0000-0000000433e1'$q$, 'RIDE_PAYMENT_SERVER_ONLY', 'marking their ride paid');
select pg_temp.refused($q$update public.ride_requests set platform_fees_charged_at = now()
  where id = '00000000-0000-0000-0000-0000000433e1'$q$, 'RIDE_SERVER_ONLY', 'the platform fees stamp');
select pg_temp.refused($q$update public.ride_requests set luggage = 9
  where id = '00000000-0000-0000-0000-0000000433e1'$q$, 'RIDE_LUGGAGE_FIXED', 'the bags, after booking');
select pg_temp.refused($q$update public.ride_requests set waiting_minutes = 0, waiting_charge = 0
  where id = '00000000-0000-0000-0000-0000000433e1'$q$, 'RIDE_SERVER_ONLY', 'the waiting charge');
select pg_temp.refused($q$update public.ride_requests set fare_coins_used = 5, fare_coins_value = 5
  where id = '00000000-0000-0000-0000-0000000433e1'$q$, 'RIDE_FARE_COINS_SERVER_ONLY', 'fare coins');
select pg_temp.refused($q$update public.ride_requests set toll_charges = 5
  where id = '00000000-0000-0000-0000-0000000433e1'$q$, 'RIDE_CHARGES_DRIVER_ONLY', 'tolls, by the rider');
select pg_temp.refused($q$update public.ride_requests set mygig = '{}'::jsonb
  where id = '00000000-0000-0000-0000-0000000433e1'$q$, 'RIDE_SERVER_ONLY', 'myGiG terms');
select pg_temp.refused($q$update public.ride_requests set promo_discount = 19, promo_payable = 1
  where id = '00000000-0000-0000-0000-0000000433e1'$q$, 'RIDE_SERVER_ONLY', 'a promo discount');
select pg_temp.refused($q$update public.ride_requests set rider_trips = 500
  where id = '00000000-0000-0000-0000-0000000433e1'$q$, 'RIDE_SERVER_ONLY', 'the rider''s trips shown on the ride');
select pg_temp.refused($q$update public.ride_requests set plus_discount = 19
  where id = '00000000-0000-0000-0000-0000000433e1'$q$, 'RIDE_SERVER_ONLY', 'a GET.Plus discount');
-- Columns the server keeps without a word: they stay as they were.
update public.ride_requests set cancel_request_outcome = 'declined', my_ride_max_km = 99, dispatch_step = 3
 where id = '00000000-0000-0000-0000-0000000433e1';
select pg_temp.check((select cancel_request_outcome is null and my_ride_max_km is null and dispatch_step = 0
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000433e1'),
  'the cancellation outcome, My Ride''s reach and the dispatch step stay the server''s');
-- What is theirs: the price of their open request, and cancelling it.
update public.ride_requests set fare = 22, ride_fare = 22 where id = '00000000-0000-0000-0000-0000000433e1';
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000433e1';
select pg_temp.check((select fare = 22 and status = 'cancelled' and cancelled_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000433e1'),
  'they price and cancel their own request like any rider');
reset role;

-- 3. A ride they are on, as its rider ---------------------------------------------------------------
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name) values
  ('00000000-0000-0000-0000-0000000433e3', '00000000-0000-0000-0000-0000000433b1',
   '00000000-0000-0000-0000-0000000433d1', 'accepted', 20, 20, 'KLCC');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000433b1');
select pg_temp.refused($q$update public.ride_requests set partner_live_lat = 3.1, partner_live_lng = 101.7
  where id = '00000000-0000-0000-0000-0000000433e3'$q$, 'RIDE_PARTNER_ONLY', 'the driver''s position, by the rider');
select pg_temp.refused($q$update public.ride_requests set safety_ack_at = now()
  where id = '00000000-0000-0000-0000-0000000433e3'$q$, 'RIDE_SERVER_ONLY', 'the safety check''s answer');
select pg_temp.refused($q$update public.ride_requests set partner_id = null
  where id = '00000000-0000-0000-0000-0000000433e3'$q$, 'RIDE_DRIVER_KEPT', 'dropping the driver of a ride that was taken');
select pg_temp.refused($q$update public.ride_requests set fare = 1, ride_fare = 1
  where id = '00000000-0000-0000-0000-0000000433e3'$q$, 'RIDE_FARE_LOCKED', 'the fare, once a driver has accepted');
reset role;

-- 4. Rides they drive: an admin whose pages edit something else, an approved partner ---------------
insert into public.ride_requests (id, rider_id, status, fare, ride_fare, pickup_name) values
  ('00000000-0000-0000-0000-0000000433e4', '00000000-0000-0000-0000-0000000433b2', 'open', 20, 20, 'KLCC'),
  ('00000000-0000-0000-0000-0000000433e5', '00000000-0000-0000-0000-0000000433a1', 'open', 20, 20, 'KLCC');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000433b2');
select pg_temp.check(public.caller_is_admin() and not public.caller_admin_can_write('ride_requests'),
  'editing another page is not editing rides');
select pg_temp.refused($q$update public.ride_requests set partner_id = auth.uid(), offered_fare = 25
  where id = '00000000-0000-0000-0000-0000000433e4'$q$, 'RIDE_CLAIM_OWN_RIDE', 'taking a ride they booked');
select pg_temp.refused($q$update public.ride_requests set rider_id = auth.uid()
  where id = '00000000-0000-0000-0000-0000000433e5'$q$, 'rider_immutable', 'making somebody''s open request their own');
select pg_temp.refused($q$update public.ride_requests set partner_id = auth.uid(), offered_fare = 25
  where id = '00000000-0000-0000-0000-0000000433e5'$q$, 'GET_CREDIT_TOO_LOW', 'bidding with GET.credit under the floor');
reset role;
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note) values
  ('00000000-0000-0000-0000-0000000433b2', 'get_credit', 'topup', 50, 'Test top-up 0433');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000433b2');
update public.ride_requests set partner_id = auth.uid(), offered_fare = 25
 where id = '00000000-0000-0000-0000-0000000433e5';
select pg_temp.check((select partner_id = '00000000-0000-0000-0000-0000000433b2' and offered_fare = 25
                             and partner_name = 'Other Page 0433'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000433e5'),
  'with credit they bid like any approved driver, and the card is the server''s');
reset role;
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name) values
  ('00000000-0000-0000-0000-0000000433e2', '00000000-0000-0000-0000-0000000433a1',
   '00000000-0000-0000-0000-0000000433b2', 'accepted', 20, 20, 'KLCC');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000433b2');
select pg_temp.refused($q$update public.ride_requests set rider_name = 'Somebody Else'
  where id = '00000000-0000-0000-0000-0000000433e2'$q$, 'RIDE_RIDER_ONLY', 'the rider''s name, by the driver');
select pg_temp.refused($q$update public.ride_requests set rider_id = '00000000-0000-0000-0000-0000000433b1'
  where id = '00000000-0000-0000-0000-0000000433e2'$q$, 'rider_immutable', 'who the rider is, by the driver');
select pg_temp.refused($q$update public.ride_requests set commission_rate = 0, commission_amount = 0
  where id = '00000000-0000-0000-0000-0000000433e2'$q$, 'RIDE_SERVER_ONLY', 'the commission on a ride they drive');
select pg_temp.refused($q$update public.ride_requests set payment_status = 'paid', paid_method = 'cash', paid_amount = 20
  where id = '00000000-0000-0000-0000-0000000433e2'$q$, 'RIDE_PAYMENT_SERVER_ONLY', 'marking a ride they drive paid');

-- 5. The back office: an admin who may edit rides ---------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000433c1');
select pg_temp.check(public.caller_admin_can_write('ride_requests'), 'the Rides page edits rides');
update public.ride_requests
   set payment_status = 'paid', paid_method = 'cash', paid_amount = 20, paid_at = now(),
       luggage = 2, waiting_minutes = 3, waiting_charge = 1.5, toll_charges = 4, fare_coins_used = 0,
       plus_discount = 1, promo_discount = 1, rider_trips = 7, platform_fees_charged_at = now(),
       cancel_request_outcome = 'declined', my_ride_max_km = 12, partner_live_lat = 3.1, safety_ack_at = now()
 where id = '00000000-0000-0000-0000-0000000433e3';
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, pickup_name) values
  ('00000000-0000-0000-0000-0000000433e6', '00000000-0000-0000-0000-0000000433a1',
   '00000000-0000-0000-0000-0000000433d1', 'accepted', 30, 30, 'KLCC');
update public.ride_requests set rider_id = '00000000-0000-0000-0000-0000000433b1'
 where id = '00000000-0000-0000-0000-0000000433e6';
reset role;
select pg_temp.check((select payment_status = 'paid' and paid_method = 'cash' and paid_amount = 20 and luggage = 2
                             and waiting_minutes = 3 and waiting_charge = 1.5 and toll_charges = 4
                             and plus_discount = 1 and promo_discount = 1 and rider_trips = 7
                             and platform_fees_charged_at is not null and cancel_request_outcome = 'declined'
                             and my_ride_max_km = 12 and partner_live_lat = 3.1 and safety_ack_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000433e3'),
  'an admin who may edit rides changes the server''s side of a ride');
select pg_temp.check((select status = 'accepted' and partner_id = '00000000-0000-0000-0000-0000000433d1'
                             and rider_id = '00000000-0000-0000-0000-0000000433b1'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000433e6'),
  'and writes a ride with its driver, and moves it to another rider');

-- 6. The server's own writes are not checked --------------------------------------------------------
-- A direct session (migrations, cron, the SQL editor): no role, nobody signed in ...
select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
update public.ride_requests
   set payment_status = 'paid', paid_method = 'get_wallet', paid_amount = 20, luggage = 1, rider_trips = 3, plus_discount = 2
 where id = '00000000-0000-0000-0000-0000000433e2';
update public.ride_requests set rider_id = '00000000-0000-0000-0000-0000000433a1'
 where id = '00000000-0000-0000-0000-0000000433e6';
-- ... and the service role (edge functions).
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true), set_config('request.jwt.claim.sub', '', true);
update public.ride_requests set promo_discount = 3, waiting_charge = 2, my_ride_max_km = 8
 where id = '00000000-0000-0000-0000-0000000433e2';
reset role;
select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);
select pg_temp.check((select payment_status = 'paid' and paid_method = 'get_wallet' and luggage = 1 and rider_trips = 3
                             and plus_discount = 2 and promo_discount = 3 and waiting_charge = 2 and my_ride_max_km = 8
                             and rider_name is distinct from 'Somebody Else'
                             and rider_id = '00000000-0000-0000-0000-0000000433a1'
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000433e2')
                     and (select rider_id = '00000000-0000-0000-0000-0000000433a1'
                            from public.ride_requests where id = '00000000-0000-0000-0000-0000000433e6'),
  'the server writes as before, the rider of a ride too');

-- 7. Each guard is on the table, enabled ------------------------------------------------------------
select pg_temp.check((select count(*) = 17
                        from pg_trigger t join pg_proc p on p.oid = t.tgfoid
                       where not t.tgisinternal and t.tgenabled = 'O' and t.tgrelid = 'public.ride_requests'::regclass
                         and (t.tgname, p.proname) in (
                           ('trg_ride_requests_a_guard_claim', 'ride_requests_guard_partner_claim'),
                           ('trg_ride_requests_a_guard_credit', 'ride_requests_guard_credit'),
                           ('trg_ride_requests_a_one_active', 'ride_requests_one_active_request'),
                           ('trg_ride_requests_b_guard_charges', 'ride_requests_guard_charges'),
                           ('trg_ride_requests_b_guard_city_extras', 'ride_requests_guard_city_extras'),
                           ('trg_ride_requests_b_guard_fare', 'ride_requests_guard_fare'),
                           ('trg_ride_requests_b_guard_payment', 'ride_requests_guard_payment'),
                           ('trg_ride_requests_b_guard_platform_fees', 'ride_requests_guard_platform_fees'),
                           ('trg_ride_requests_b_luggage_fixed', 'ride_requests_luggage_fixed'),
                           ('trg_ride_requests_b_mygig_guard', 'ride_requests_mygig_guard'),
                           ('trg_ride_requests_c_cancel_outcome', 'ride_requests_cancel_outcome'),
                           ('trg_ride_requests_c_my_ride_guard', 'ride_requests_my_ride_guard'),
                           ('trg_ride_requests_d_guard_sides', 'ride_requests_guard_sides'),
                           ('trg_ride_requests_d_promo', 'ride_requests_promo_guard'),
                           ('trg_ride_requests_guard_city_ride', 'ride_requests_guard_city_ride'),
                           ('trg_ride_requests_plus_guard', 'ride_requests_plus_guard'),
                           ('trg_ride_requests_protect_rider', 'ride_requests_protect_rider'))),
  'the guards are on the table and enabled');

-- 8. A guard on the table asks about the table ------------------------------------------------------
-- A rule that tells the apps' roles from the server's by current_user lets
-- the back office through with public.caller_admin_can_write('ride_requests'),
-- the test the table's admin policies make.
do $$
declare
  bad text;
begin
  select string_agg(distinct p.proname, ', ')
    into bad
    from pg_trigger t
    join pg_proc p on p.oid = t.tgfoid
   where not t.tgisinternal
     and t.tgrelid = 'public.ride_requests'::regclass
     and not p.prosecdef
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~ 'current_user'
     and regexp_replace(p.prosrc, '--[^\n]*', '', 'g') ~ 'caller_is_admin\(\)';
  if bad is not null then
    raise exception 'FAILED: guards that ask caller_is_admin(), not about their table: %', bad;
  end if;
end $$;

rollback;

select 'ride_guards_page_scope_0433: all passed';
