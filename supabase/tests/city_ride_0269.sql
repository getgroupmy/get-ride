-- ============================================================================
-- Regression test for migration 0269: city ride rules.
--   1. many offers at once: drivers' offers as rows, the mirror into the old
--      single-bid columns, decline and one more offer, accept by id (the
--      others are taken), an older app's bid, decline and raise, auto-accept,
--      expiry;
--   2. drivers rate riders: only the ride's driver, tags of the stars' list,
--      the average on the profile and stamped on the next request, 24 hours;
--   5. cancel fees by time, the safety reasons, a short wallet carried to the
--      next ride and paid to the first driver, the no-show, the offer pause;
--   6. the checks on by default, the trip shared with the contacts as the
--      rider chose, the unanswered route check raising the SOS incident;
--   and the grants. All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/city_ride_0269.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- ---- Grants -------------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'public.ride_offer_make(uuid, numeric, integer, double precision, double precision)',
    'public.ride_offer_withdraw(uuid)', 'public.ride_offer_accept(uuid)', 'public.ride_offer_decline(uuid)',
    'public.rate_rider(uuid, integer, text[])', 'public.ride_cancel_terms(uuid)', 'public.ride_no_show(uuid)',
    'public.driver_cancel_stats()', 'public.city_ride_config()', 'public.set_city_ride_config(text, jsonb)',
    'public.trip_route_report(uuid, text, text, integer, double precision, double precision)'] loop
    if not has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute') then
      raise exception 'FAILED: % is for signed-in callers only', f;
    end if;
    if not (select p.prosecdef and p.proconfig @> array['search_path=""']
              from pg_proc p where p.oid = f::regprocedure) then
      raise exception 'FAILED: % is security definer with an empty search_path', f;
    end if;
  end loop;
  foreach f in array array[
    'public.ride_offers_mirror(uuid)', 'public.ride_offers_expire()', 'public.ride_offers_close(uuid, text, text, uuid)',
    'public.rider_rating_recompute(uuid)', 'public.ride_fee_take(public.ride_requests, numeric, text)',
    'public.driver_cancel_rate(uuid)', 'public.trip_share_text_contacts(public.ride_requests, text)',
    'public.ride_cancel_rules_at(text, text, text, text)'] loop
    if has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute') then
      raise exception 'FAILED: % is the server''s own', f;
    end if;
  end loop;
end
$$;

-- ---- People -------------------------------------------------------------------------------------
update public.permit_country_settings set enforce = false;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000269a1'),  -- rider, rich enough for two fees
  ('00000000-0000-0000-0000-0000000269a2'),  -- rider with an empty wallet
  ('00000000-0000-0000-0000-0000000269a3'),  -- rider who shares their trips
  ('00000000-0000-0000-0000-0000000269b1'),  -- driver one
  ('00000000-0000-0000-0000-0000000269b2'),  -- driver two
  ('00000000-0000-0000-0000-0000000269b3'),  -- driver three, cancels a lot
  ('00000000-0000-0000-0000-0000000269c1')   -- admin of App Settings
on conflict do nothing;
insert into public.profiles (id, name) select id, 'Test ' || right(id::text, 2) from auth.users
 where id::text like '00000000-0000-0000-0000-0000000269%'
on conflict do nothing;
insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries) values
  ('00000000-0000-0000-0000-0000000269e1', '00000000-0000-0000-0000-0000000269b1', 'Test Driver One', '+60100002691',
   'approved', '{eHailing}', '{Malaysia}'),
  ('00000000-0000-0000-0000-0000000269e2', '00000000-0000-0000-0000-0000000269b2', 'Test Driver Two', '+60100002692',
   'approved', '{eHailing}', '{Malaysia}'),
  ('00000000-0000-0000-0000-0000000269e3', '00000000-0000-0000-0000-0000000269b3', 'Test Driver Three', '+60100002693',
   'approved', '{eHailing}', '{Malaysia}');
insert into public.admin_access (profile_id, page, access_level)
values ('00000000-0000-0000-0000-0000000269c1', 'admin-settings-site', 'edit');

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
-- [p_sql] must fail with an error naming [p_like].
create or replace function pg_temp.refused(p_sql text, p_like text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm like '%' || p_like || '%' then
      return;
    end if;
    raise exception 'FAILED: % refused with "%" instead of %', p_what, sqlerrm, p_like;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
create or replace function pg_temp.wallet(p uuid, p_type text default 'get_wallet') returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p and wallet_type = p_type), 0);
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text, text),
  pg_temp.wallet(uuid, text) to authenticated;
-- The tests' own temporary results.
create temporary table t_ids (k text primary key, id uuid);
grant all on t_ids to authenticated;

-- ---- 0. Settings: the admin of App Settings writes them ---------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b1');
select pg_temp.refused($q$select public.set_city_ride_config('offers', '{"shown": 3}')$q$, 'not_authorized',
  'a driver changing the offer settings');
select pg_temp.as_user('00000000-0000-0000-0000-0000000269c1');
select pg_temp.check((public.set_city_ride_config('offers', '{"shown": 3, "lifetimeSeconds": 999}')->'offers'
                      ->>'lifetimeSeconds')::int = 120, 'the lifetime is held to 120 s');
select public.set_city_ride_config('offers', '{}');
select pg_temp.check(public.city_ride_config()->'offers' = '{"shown": 5, "sort": "cheapest", "lifetimeSeconds": 15,
  "reofferAfterDecline": true}'::jsonb, 'the offer defaults: ' || (public.city_ride_config()->'offers')::text);
select pg_temp.check(public.city_ride_config()->'riderRating' = '{"window": 100, "newBelow": 5, "lowBelow": 4.0}'::jsonb,
  'the rating defaults');
select pg_temp.check(public.city_ride_config()->'driverCancel'
  = '{"limitPercent": 20, "days": 7, "pauseMinutes": 30, "minRides": 5}'::jsonb, 'the cancel limit defaults');
-- Places: the admin's, read by everyone.
insert into public.ride_cancel_places (level, country, rules) values ('country', 'Testland', '{"lateFee": 4}');
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b1');
select pg_temp.refused($q$insert into public.ride_cancel_places (level, country) values ('country', 'Otherland')$q$,
  'row-level security', 'a driver adding cancel rules');
select pg_temp.check((select count(*) from public.ride_cancel_places where country = 'Testland') = 1,
  'everyone reads the cancel rules');
reset role;
select pg_temp.check(public.ride_cancel_rules_at('Testland', '', '', '')
  = '{"freeMinutes": 2, "lateFee": 4, "arrivedFee": 5, "noShowMinutes": 5, "noShowFee": 5}'::jsonb,
  'a country''s late fee over Default''s: ' || public.ride_cancel_rules_at('Testland', '', '', '')::text);
select pg_temp.refused($q$insert into public.ride_cancel_places (level, rules) values ('city', '{"lateFee": -1}')$q$,
  'check', 'a negative fee');

-- ---- 1. Many offers at once ---------------------------------------------------------------------
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare) values
  ('00000000-0000-0000-0000-000000026901', '00000000-0000-0000-0000-0000000269a1', 'open', 3.1, 101.6, 20, 20),
  ('00000000-0000-0000-0000-000000026902', '00000000-0000-0000-0000-0000000269a2', 'open', 3.1, 101.6, 20, 20),
  ('00000000-0000-0000-0000-000000026903', '00000000-0000-0000-0000-0000000269a2', 'open', 3.1, 101.6, 20, 20);

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b1');
insert into t_ids select 'b1', (public.ride_offer_make('00000000-0000-0000-0000-000000026901', 22, 4, 3.11, 101.61)->>'id')::uuid;
select pg_temp.refused($q$select public.ride_offer_make('00000000-0000-0000-0000-000000026901', 19)$q$, 'OFFER_AMOUNT',
  'an offer under the rider''s fare');
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b2');
insert into t_ids select 'b2', (public.ride_offer_make('00000000-0000-0000-0000-000000026901', 21, 2)->>'id')::uuid;
select pg_temp.check((select count(*) from public.ride_offers where request_id = '00000000-0000-0000-0000-000000026901') = 1,
  'a driver reads only their own offer');
select pg_temp.as_user('00000000-0000-0000-0000-0000000269a1');
select pg_temp.check((select count(*) from public.ride_offers
                       where request_id = '00000000-0000-0000-0000-000000026901' and status = 'open') = 2,
  'the rider reads both offers at once');
select pg_temp.check((select partner_name = 'Test Driver One' and eta_min = 4 and partner_trips is not null
                        from public.ride_offers where id = (select id from t_ids where k = 'b1')),
  'the offer carries the driver''s card and ETA');
reset role;
select pg_temp.check((select offered_fare = 21 and partner_id = '00000000-0000-0000-0000-0000000269b2'
                        from public.ride_requests where id = '00000000-0000-0000-0000-000000026901'),
  'the latest offer is mirrored into the single-bid columns');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b1');
select pg_temp.refused(format('select public.ride_offer_decline(%L)', (select id from t_ids where k = 'b2')),
  'not_authorized', 'a driver declining another''s offer');
select pg_temp.as_user('00000000-0000-0000-0000-0000000269a1');
select public.ride_offer_decline((select id from t_ids where k = 'b2'));
reset role;
select pg_temp.check((select offered_fare = 22 and partner_id = '00000000-0000-0000-0000-0000000269b1'
                        from public.ride_requests where id = '00000000-0000-0000-0000-000000026901'),
  'after a decline the mirror moves to the next open offer');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b2');
insert into t_ids select 'b2again', (public.ride_offer_make('00000000-0000-0000-0000-000000026901', 20.5)->>'id')::uuid;
select pg_temp.as_user('00000000-0000-0000-0000-0000000269a1');
select public.ride_offer_decline((select id from t_ids where k = 'b2again'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b2');
select pg_temp.refused($q$select public.ride_offer_make('00000000-0000-0000-0000-000000026901', 20)$q$, 'OFFER_DECLINED',
  'a third offer after two declines');
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b3');
insert into t_ids select 'b3', (public.ride_offer_make('00000000-0000-0000-0000-000000026901', 23)->>'id')::uuid;

select pg_temp.as_user('00000000-0000-0000-0000-0000000269a2');
select pg_temp.refused(format('select public.ride_offer_accept(%L)', (select id from t_ids where k = 'b1')),
  'not_authorized', 'someone else accepting the rider''s offer');
select pg_temp.as_user('00000000-0000-0000-0000-0000000269a1');
select public.ride_offer_accept((select id from t_ids where k = 'b1'));
select pg_temp.refused(format('select public.ride_offer_accept(%L)', (select id from t_ids where k = 'b3')),
  'OFFER_REQUEST_CLOSED', 'a second accept');
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b3');
select pg_temp.check((select status = 'withdrawn' and closed_reason = 'taken' from public.ride_offers
                       where id = (select id from t_ids where k = 'b3')),
  'the other driver sees the ride was taken');
reset role;
select pg_temp.check((select status = 'accepted' and partner_id = '00000000-0000-0000-0000-0000000269b1'
                             and fare = 22 and ride_fare = 22
                        from public.ride_requests where id = '00000000-0000-0000-0000-000000026901'),
  'the accepted offer assigns the driver at its amount');
select pg_temp.check((select status from public.ride_offers where id = (select id from t_ids where k = 'b1')) = 'accepted',
  'the accepted offer is marked');

-- An older driver app's bid on the row becomes an offer; an older rider app's decline declines it.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b3');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000269b3', offered_fare = 25
 where id = '00000000-0000-0000-0000-000000026902';
select pg_temp.check((select count(*) from public.ride_offers where request_id = '00000000-0000-0000-0000-000000026902'
                        and partner_id = '00000000-0000-0000-0000-0000000269b3' and status = 'open' and amount = 25) = 1,
  'an older app''s bid is kept as an offer');
select pg_temp.as_user('00000000-0000-0000-0000-0000000269a2');
update public.ride_requests set partner_id = null, offered_fare = null
 where id = '00000000-0000-0000-0000-000000026902';
select pg_temp.check((select status from public.ride_offers where request_id = '00000000-0000-0000-0000-000000026902'
                        and partner_id = '00000000-0000-0000-0000-0000000269b3') = 'declined',
  'an older rider app''s decline declines the offer');
-- A raise takes every offer off.
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b2');
select public.ride_offer_make('00000000-0000-0000-0000-000000026902', 24);
select pg_temp.as_user('00000000-0000-0000-0000-0000000269a2');
update public.ride_requests set fare = 22, ride_fare = 22 where id = '00000000-0000-0000-0000-000000026902';
select pg_temp.check((select closed_reason from public.ride_offers where request_id = '00000000-0000-0000-0000-000000026902'
                        and partner_id = '00000000-0000-0000-0000-0000000269b2') = 'raised',
  'a raise withdraws the offers');
-- Auto-accept takes an offer at or under the limit as it lands.
update public.ride_requests set auto_accept_fare = 30 where id = '00000000-0000-0000-0000-000000026903';
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b2');
select public.ride_offer_make('00000000-0000-0000-0000-000000026903', 25);
reset role;
select pg_temp.check((select status = 'accepted' and fare = 25 from public.ride_requests
                       where id = '00000000-0000-0000-0000-000000026903'), 'auto-accept took the offer');
select pg_temp.check((select status from public.ride_offers where request_id = '00000000-0000-0000-0000-000000026903')
  = 'accepted', 'the auto-accepted offer is marked accepted');
-- Expiry.
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare) values
  ('00000000-0000-0000-0000-000000026904', '00000000-0000-0000-0000-0000000269a2', 'open', 3.1, 101.6, 20, 20);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b2');
select public.ride_offer_make('00000000-0000-0000-0000-000000026904', 20);
reset role;
update public.ride_offers set expires_at = now() - interval '1 second'
 where request_id = '00000000-0000-0000-0000-000000026904';
select public.ride_offers_expire();
select pg_temp.check((select status from public.ride_offers where request_id = '00000000-0000-0000-0000-000000026904')
  = 'expired', 'a lapsed offer expires');
select pg_temp.check((select offered_fare is null and partner_id is null from public.ride_requests
                       where id = '00000000-0000-0000-0000-000000026904'), 'and leaves the single-bid columns');

-- ---- 2. Drivers rate riders --------------------------------------------------------------------
update public.ride_requests set status = 'completed', completed_at = now()
 where id = '00000000-0000-0000-0000-000000026901';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b2');
select pg_temp.refused($q$select public.rate_rider('00000000-0000-0000-0000-000000026901', 5)$q$, 'not_authorized',
  'a driver rating a rider they didn''t drive');
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b1');
select pg_temp.refused($q$select public.rate_rider('00000000-0000-0000-0000-000000026901', 6)$q$, 'bad_stars',
  'six stars');
select public.rate_rider('00000000-0000-0000-0000-000000026901', 2, array['Rude', 'Polite', 'Made up']);
select pg_temp.check((select tags = array['Rude'] from public.rider_ratings
                       where request_id = '00000000-0000-0000-0000-000000026901'),
  'only the low tags stay on a low rating');
select pg_temp.as_user('00000000-0000-0000-0000-0000000269a1');
select pg_temp.check((select count(*) from public.rider_ratings) = 0, 'a rider doesn''t see who rated them');
select pg_temp.check((select rider_rating = 2 and rider_ratings_count = 1 from public.profiles
                       where id = '00000000-0000-0000-0000-0000000269a1'), 'the average is on the profile');
select pg_temp.refused($q$update public.profiles set rider_rating = 5 where id = '00000000-0000-0000-0000-0000000269a1'$q$,
  'PROFILE_PROTECTED_COLUMN', 'a rider setting their own rating');
-- The app's 5 is replaced by the server's.
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, rider_rating) values
  ('00000000-0000-0000-0000-000000026905', '00000000-0000-0000-0000-0000000269a1', 'open', 3.1, 101.6, 20, 5);
select pg_temp.check((select rider_rating = 2 and rider_ratings_count = 1 and rider_trips = 1
                        from public.ride_requests where id = '00000000-0000-0000-0000-000000026905'),
  'a new request carries the rider''s real rating and trips');
update public.ride_requests set rider_rating = 5 where id = '00000000-0000-0000-0000-000000026905';
select pg_temp.check((select rider_rating = 2 from public.ride_requests where id = '00000000-0000-0000-0000-000000026905'),
  'a rider can''t rewrite the rating on their request');
select pg_temp.refused($q$update public.ride_requests set prior_fees = 0, cancel_fee = 0
                           where id = '00000000-0000-0000-0000-000000026905'$q$, 'RIDE_SERVER_ONLY',
  'a rider rewriting the fees on their request');
reset role;
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-000000026905';
update public.ride_requests set completed_at = now() - interval '25 hours'
 where id = '00000000-0000-0000-0000-000000026901';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b1');
select pg_temp.refused($q$select public.rate_rider('00000000-0000-0000-0000-000000026901', 4)$q$, 'too_late',
  'rating after 24 hours');
reset role;

-- ---- 5. Cancel fees -----------------------------------------------------------------------------
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
values ('00000000-0000-0000-0000-0000000269a1', 'get_wallet', 'topup', 10, 'test');
-- Accepted [mins] ago by driver one (arrived [arr] minutes ago, or not), at 20% commission.
create or replace function pg_temp.taken(p uuid, p_rider uuid, p_mins int, p_arr int default null) returns void
language plpgsql as $$
begin
  insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, partner_id,
                                    accepted_at, arrived_at)
  values (p, p_rider, case when p_arr is null then 'accepted' else 'arrived' end, 3.1, 101.6, 20, 20,
          '00000000-0000-0000-0000-0000000269b1', now() - make_interval(mins => p_mins),
          case when p_arr is not null then now() - make_interval(mins => p_arr) end);
  update public.ride_requests set commission_rate = 0.2 where id = p;
end $$;
-- The rider asks to cancel (why), and driver one agrees.
create or replace function pg_temp.rider_cancels(p uuid, p_rider uuid, p_why text default null) returns void
language plpgsql as $$
begin
  set local role authenticated;
  perform pg_temp.as_user(p_rider);
  update public.ride_requests set cancel_requested_at = now(), cancel_requested_by = 'rider', cancel_reason = p_why
   where id = p;
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000269b1');
  update public.ride_requests set status = 'cancelled', cancelled_at = now() where id = p;
  reset role;
end $$;
create or replace function pg_temp.fee(p uuid) returns text language sql as $$
  select coalesce(cancel_fee::text, '-') || ' ' || coalesce(cancel_fee_status, '-') from public.ride_requests where id = p;
$$;

select pg_temp.taken('00000000-0000-0000-0000-000000026911', '00000000-0000-0000-0000-0000000269a1', 1);
select pg_temp.rider_cancels('00000000-0000-0000-0000-000000026911', '00000000-0000-0000-0000-0000000269a1');
select pg_temp.check(pg_temp.fee('00000000-0000-0000-0000-000000026911') = '0.00 none',
  'free within 2 minutes: ' || pg_temp.fee('00000000-0000-0000-0000-000000026911'));

select pg_temp.taken('00000000-0000-0000-0000-000000026912', '00000000-0000-0000-0000-0000000269a1', 5);
select pg_temp.rider_cancels('00000000-0000-0000-0000-000000026912', '00000000-0000-0000-0000-0000000269a1');
select pg_temp.check(pg_temp.fee('00000000-0000-0000-0000-000000026912') = '3.00 charged',
  'the late fee after 2 minutes: ' || pg_temp.fee('00000000-0000-0000-0000-000000026912'));
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000269a1') = 7, 'taken from the rider''s wallet');
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000269b1') = 2.40,
  'paid to the driver less 20%: ' || pg_temp.wallet('00000000-0000-0000-0000-0000000269b1'));

select pg_temp.taken('00000000-0000-0000-0000-000000026913', '00000000-0000-0000-0000-0000000269a1', 8, 1);
select pg_temp.rider_cancels('00000000-0000-0000-0000-000000026913', '00000000-0000-0000-0000-0000000269a1');
select pg_temp.check(pg_temp.fee('00000000-0000-0000-0000-000000026913') = '5.00 charged',
  'the fee after the driver arrived: ' || pg_temp.fee('00000000-0000-0000-0000-000000026913'));

select pg_temp.taken('00000000-0000-0000-0000-000000026914', '00000000-0000-0000-0000-0000000269a1', 8, 1);
select pg_temp.rider_cancels('00000000-0000-0000-0000-000000026914', '00000000-0000-0000-0000-0000000269a1', 'wrong_car');
select pg_temp.check(pg_temp.fee('00000000-0000-0000-0000-000000026914') = '0.00 none', 'a wrong car is free');

select pg_temp.taken('00000000-0000-0000-0000-000000026915', '00000000-0000-0000-0000-0000000269a1', 6);
select pg_temp.rider_cancels('00000000-0000-0000-0000-000000026915', '00000000-0000-0000-0000-0000000269a1');
select pg_temp.check(pg_temp.fee('00000000-0000-0000-0000-000000026915') = '3.00 due',
  'a short wallet leaves the fee due: ' || pg_temp.fee('00000000-0000-0000-0000-000000026915'));
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000269a1') = 2, 'nothing more taken');

-- The terms the app shows.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000269a1');
select pg_temp.check((select (t->>'lateFee')::numeric = 3 and (t->>'freeUntil') is not null
                        from (select public.ride_cancel_terms('00000000-0000-0000-0000-000000026915') t) x),
  'the rider reads the terms');
select pg_temp.as_user('00000000-0000-0000-0000-0000000269a2');
select pg_temp.refused($q$select public.ride_cancel_terms('00000000-0000-0000-0000-000000026915')$q$, 'not_authorized',
  'someone else reading the terms');
-- The next ride carries it, and its driver passes it on.
select pg_temp.as_user('00000000-0000-0000-0000-0000000269a1');
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, prior_fees) values
  ('00000000-0000-0000-0000-000000026916', '00000000-0000-0000-0000-0000000269a1', 'open', 3.1, 101.6, 20, 20, 99);
reset role;
select pg_temp.check((select prior_fees = 3 and public.ride_amount_due(r) = 23 from public.ride_requests r
                       where id = '00000000-0000-0000-0000-000000026916'),
  'the next ride carries the fee (never the app''s amount) and the rider owes it');
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000269b2',
                                accepted_at = now() where id = '00000000-0000-0000-0000-000000026916';
update public.ride_requests set status = 'completed', completed_at = now() where id = '00000000-0000-0000-0000-000000026916';
select pg_temp.check((select status = 'paid' from public.rider_fee_dues
                       where ride_id = '00000000-0000-0000-0000-000000026915'), 'the due is paid');
select pg_temp.check((select sum(amount) from public.wallet_transactions
                       where user_id = '00000000-0000-0000-0000-0000000269b2' and kind = 'collected_fee') = -3,
  'the driver who collected it passes it on');
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000269b1') = 2.40 + 4.00 + 2.40,
  'the first driver is paid less commission: ' || pg_temp.wallet('00000000-0000-0000-0000-0000000269b1'));

-- No-show.
select pg_temp.taken('00000000-0000-0000-0000-000000026917', '00000000-0000-0000-0000-0000000269a2', 12, 6);
select pg_temp.taken('00000000-0000-0000-0000-000000026918', '00000000-0000-0000-0000-0000000269a2', 12, 2);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b2');
select pg_temp.refused($q$select public.ride_no_show('00000000-0000-0000-0000-000000026917')$q$, 'not_authorized',
  'another driver marking a no-show');
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b1');
select pg_temp.refused($q$select public.ride_no_show('00000000-0000-0000-0000-000000026918')$q$, 'NO_SHOW_TOO_EARLY',
  'a no-show before 5 minutes');
select public.ride_no_show('00000000-0000-0000-0000-000000026917');
reset role;
select pg_temp.check((select status = 'cancelled' and cancel_reason = 'passenger_no_show' from public.ride_requests
                       where id = '00000000-0000-0000-0000-000000026917'), 'the no-show ends the ride');
select pg_temp.check(pg_temp.fee('00000000-0000-0000-0000-000000026917') = '5.00 due',
  'the no-show fee, due from an empty wallet: ' || pg_temp.fee('00000000-0000-0000-0000-000000026917'));

-- Driver three: 2 of 5 rides cancelled this week pauses their offers.
insert into public.ride_requests (rider_id, status, pickup_lat, pickup_lng, fare, partner_id, accepted_at,
                                  cancel_requested_by, cancel_reason)
select '00000000-0000-0000-0000-0000000269a3', s, 3.1, 101.6, 20, '00000000-0000-0000-0000-0000000269b3',
       now() - interval '1 day', case when s = 'cancelled' then 'partner' end,
       case when s = 'cancelled' then 'vehicle_issue' end
  from unnest(array['completed', 'completed', 'completed', 'cancelled']) s;
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, partner_id, accepted_at) values
  ('00000000-0000-0000-0000-000000026919', '00000000-0000-0000-0000-0000000269a3', 'accepted', 3.1, 101.6, 20,
   '00000000-0000-0000-0000-0000000269b3', now());
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare) values
  ('00000000-0000-0000-0000-000000026920', '00000000-0000-0000-0000-0000000269a2', 'open', 3.1, 101.6, 20, 20);
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000269b3');
update public.ride_requests set status = 'cancelled', cancelled_at = now(), cancel_reason = 'traffic_too_far',
                                cancel_requested_by = 'partner', cancel_requested_at = now()
 where id = '00000000-0000-0000-0000-000000026919';
select pg_temp.check((select (s->>'percent')::numeric = 40 and s->>'pausedUntil' is not null
                        from (select public.driver_cancel_stats() s) x),
  'the driver sees their 40% and the pause: ' || public.driver_cancel_stats()::text);
select pg_temp.refused($q$select public.ride_offer_make('00000000-0000-0000-0000-000000026920', 20)$q$, 'OFFERS_PAUSED',
  'an offer while paused');
reset role;
select pg_temp.check(pg_temp.fee('00000000-0000-0000-0000-000000026919') = '- -', 'a driver''s cancel costs the rider nothing');

-- ---- 6. Safety ----------------------------------------------------------------------------------
delete from public.settings_entries where id = '72656c69-6162-4c69-8000-000000000001';
select pg_temp.check((select (s->>'start_check')::boolean and (s->>'separation')::boolean
                             and (s->>'route_check')::boolean and (s->>'route_off_m')::int = 500
                             and (s->>'route_off_min')::int = 2 and (s->>'stopped_min')::int = 5
                             and (s->>'no_answer_s')::int = 60 and not (s->>'lost_items')::boolean
                        from (select public.reliability_safety() s) x),
  'the checks are on by default: ' || public.reliability_safety()::text);
insert into public.settings_entries (id, category, values)
values ('72656c69-6162-4c69-8000-000000000001', 'reliability-messaging',
        '{"safety_start_check": false, "safety_route_off_m": 800}');
select pg_temp.check((select not (s->>'start_check')::boolean and (s->>'route_off_m')::int = 800
                        from (select public.reliability_safety() s) x), 'the admin''s values win');
delete from public.settings_entries where id = '72656c69-6162-4c69-8000-000000000001';

select pg_temp.check(public.trip_share_at_night('2026-10-21 15:30+00', 'Asia/Kuala_Lumpur'), '11:30 pm is night');
select pg_temp.check(not public.trip_share_at_night('2026-10-21 05:00+00', 'Asia/Kuala_Lumpur'), '1 pm is not');
select pg_temp.check(public.trip_share_at_night('2026-10-21 21:59+00', 'Asia/Kuala_Lumpur'), '5:59 am is night');
select pg_temp.check(not public.trip_share_at_night('2026-10-21 22:00+00', 'Asia/Kuala_Lumpur'), '6 am is not');

insert into public.emergency_contacts (profile_id, name, phone) values
  ('00000000-0000-0000-0000-0000000269a3', 'Mum', '+60100000001'),
  ('00000000-0000-0000-0000-0000000269a3', 'Farid', '+60100000002');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000269a3');
update public.profiles set trip_share_mode = 'always' where id = '00000000-0000-0000-0000-0000000269a3';
reset role;
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, partner_id, accepted_at,
                                  drop_name) values
  ('00000000-0000-0000-0000-000000026921', '00000000-0000-0000-0000-0000000269a3', 'arrived', 3.1, 101.6, 20,
   '00000000-0000-0000-0000-0000000269b1', now(), 'Mid Valley');
update public.ride_requests set status = 'on_trip', started_at = now() where id = '00000000-0000-0000-0000-000000026921';
select pg_temp.check((select count(*) from public.sms_outbox
                       where channel = 'trip_share' and body like '%Mid Valley%'
                         and body like '%https://getride.my/share/' || (select share_token from public.ride_request_private
                                                where request_id = '00000000-0000-0000-0000-000000026921') || '%') = 2,
  'both contacts get the live link when the trip starts');
select pg_temp.check((select trip_shared_at is not null from public.ride_requests
                       where id = '00000000-0000-0000-0000-000000026921'), 'and the ride says it was shared');
update public.profiles set trip_share_mode = 'never' where id = '00000000-0000-0000-0000-0000000269a3';
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, partner_id, accepted_at) values
  ('00000000-0000-0000-0000-000000026922', '00000000-0000-0000-0000-0000000269a3', 'arrived', 3.1, 101.6, 20,
   '00000000-0000-0000-0000-0000000269b1', now());
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-000000026922';
select pg_temp.check((select count(*) from public.sms_outbox where channel = 'trip_share') = 2, '"never" shares nothing');

-- The route check: the rider didn't answer.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000269a2');
select pg_temp.refused($q$select public.trip_route_report('00000000-0000-0000-0000-000000026921', 'off_route', 'no_answer')$q$,
  'not_authorized', 'someone else reporting the trip');
select pg_temp.as_user('00000000-0000-0000-0000-0000000269a3');
select public.trip_route_report('00000000-0000-0000-0000-000000026921', 'off_route', 'asked', 620, 3.12, 101.62);
select public.trip_route_report('00000000-0000-0000-0000-000000026921', 'off_route', 'no_answer', 620, 3.12, 101.62);
select public.trip_route_report('00000000-0000-0000-0000-000000026921', 'stopped', 'no_answer', null, 3.12, 101.62);
select public.trip_route_report('00000000-0000-0000-0000-000000026921', 'off_route', 'ok');
reset role;
select pg_temp.check((select count(*) from public.safety_incidents
                       where ride_id = '00000000-0000-0000-0000-000000026921' and reporter_role = 'rider'
                         and note like '%left the planned route%') = 1,
  'no answer raises one SOS incident for support');
select pg_temp.check((select count(*) from public.sms_outbox where channel = 'trip_share'
                       and body like 'GET.ride safety alert%') = 2,
  'and texts the contacts once');
select pg_temp.check((select safety_ack_at is not null from public.ride_requests
                       where id = '00000000-0000-0000-0000-000000026921'), 'I''m OK answers it');
select pg_temp.check((select count(*) from public.trip_route_events
                       where request_id = '00000000-0000-0000-0000-000000026921') = 4, 'each answer is kept');

rollback;
