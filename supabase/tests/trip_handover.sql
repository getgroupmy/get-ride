-- ============================================================================
-- Regression test for migration 0199: handing a trip to another driver
-- mid-trip, with the passenger's approval, by code or to nearby partners,
-- and the first driver's share of the net earnings at completion.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/trip_handover.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000199a1'),  -- passenger
  ('00000000-0000-0000-0000-0000000199b1'),  -- driver on the trip
  ('00000000-0000-0000-0000-0000000199b2'),  -- partner named by code
  ('00000000-0000-0000-0000-0000000199b3'),  -- partner nearby, free
  ('00000000-0000-0000-0000-0000000199b4'),  -- partner nearby, on a trip of their own
  ('00000000-0000-0000-0000-0000000199b5')   -- partner far away
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000199%'
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, status, my_ride_code) values
  ('00000000-0000-0000-0000-0000000199b1', 'Amin', '+60110000301', 'approved', 'BZ99AAAA'),
  ('00000000-0000-0000-0000-0000000199b2', 'Bella', '+60110000302', 'approved', 'CZ99BBBB'),
  ('00000000-0000-0000-0000-0000000199b3', 'Chong', '+60110000303', 'approved', 'DZ99CCCC'),
  ('00000000-0000-0000-0000-0000000199b4', 'Dina', '+60110000304', 'approved', 'EZ99DDDD'),
  ('00000000-0000-0000-0000-0000000199b5', 'Eddie', '+60110000305', 'approved', 'FZ99EEEE');

update public.app_settings
   set value = '{"enabled": true, "sharePercent": 10, "nearbyRadiusKm": 5, "answerMinutes": 5}'::jsonb
 where key = 'trip_handover';

-- Online: two near the car (KLCC), one 40 km away.
insert into public.driver_presence (profile_id, online, lat, lng, updated_at) values
  ('00000000-0000-0000-0000-0000000199b3', true, 3.158, 101.713, now()),
  ('00000000-0000-0000-0000-0000000199b4', true, 3.159, 101.714, now()),
  ('00000000-0000-0000-0000-0000000199b5', true, 3.500, 101.713, now())
on conflict (profile_id) do update set online = true, lat = excluded.lat, lng = excluded.lng, updated_at = now();

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
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
create or replace function pg_temp.told(p uuid, p_event text) returns int language sql as $$
  select count(*)::int from public.notification_outbox where profile_id = p and event_id like p_event
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text)
  to authenticated;

-- Trips under way with Amin; one of Dina's own; one not started.
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, currency, country, state,
                                  partner_live_lat, partner_live_lng, drop_address) values
  ('00000000-0000-0000-0000-0000000199e1', '00000000-0000-0000-0000-0000000199a1', '00000000-0000-0000-0000-0000000199b1',
   'on_trip', 100, 100, 'RM', 'Testland199', 'Utara', 3.157, 101.712, 'KLIA'),
  ('00000000-0000-0000-0000-0000000199e2', '00000000-0000-0000-0000-0000000199a1', '00000000-0000-0000-0000-0000000199b1',
   'accepted', 40, 40, 'RM', null, null, null, null, null),
  ('00000000-0000-0000-0000-0000000199e3', '00000000-0000-0000-0000-0000000199b2', '00000000-0000-0000-0000-0000000199b4',
   'on_trip', 30, 30, 'RM', null, null, null, null, null);
-- The region's own share: 20%.
insert into public.states (country, name, "values") values ('Testland199', 'Utara', '{"handoverSharePercent": 20}');

-- 1. Only the driver, only under way ---------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000199b2');
select pg_temp.refused($q$select public.trip_handover_request('00000000-0000-0000-0000-0000000199e1')$q$,
  'another driver asking');
select pg_temp.as_user('00000000-0000-0000-0000-0000000199b1');
select pg_temp.refused($q$select public.trip_handover_request('00000000-0000-0000-0000-0000000199e2')$q$,
  'a trip not yet started');
select pg_temp.refused($q$select public.trip_handover_request('00000000-0000-0000-0000-0000000199e1', 'BZ99AAAA')$q$,
  'your own code');

-- 2. By code: the passenger first, then the driver named ---------------------------------------
create temp table ids (k text primary key, id uuid);
grant all on ids to authenticated;
insert into ids select 'h1', (public.trip_handover_request('00000000-0000-0000-0000-0000000199e1', 'cz99-bbbb', 'Car trouble')).id;
select pg_temp.refused($q$select public.trip_handover_request('00000000-0000-0000-0000-0000000199e1')$q$,
  'a second request while one waits');
select pg_temp.as_user('00000000-0000-0000-0000-0000000199b2');
select pg_temp.check(not exists (select 1 from public.trip_handover_offers_for_me()), 'nothing before the passenger approves');
select pg_temp.refused($q$select public.trip_handover_accept((select id from ids where k = 'h1'))$q$,
  'accepting before the passenger approves');
reset role;
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000199a1', 'handover-ask-%') = 1, 'the passenger is asked');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000199b1');
select pg_temp.refused($q$select public.trip_handover_rider_answer((select id from ids where k = 'h1'), true)$q$,
  'the driver approving for the passenger');
select pg_temp.as_user('00000000-0000-0000-0000-0000000199a1');
select public.trip_handover_rider_answer((select id from ids where k = 'h1'), true);
select pg_temp.as_user('00000000-0000-0000-0000-0000000199b2');
select pg_temp.check((select from_name = 'Amin' and share_percent = 20 and drop_address = 'KLIA' and meet_lat = 3.157
                        from public.trip_handover_offers_for_me()), 'the partner sees who, where the car is, and the region''s share');
select public.trip_handover_decline((select id from ids where k = 'h1'));
reset role;
select pg_temp.check((select status = 'declined_driver' from public.trip_handovers where id = (select id from ids where k = 'h1')),
  'the only one asked declined');
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000199b1', 'handover-driver-no-%') = 1, 'the driver is told');
select pg_temp.check((select partner_id = '00000000-0000-0000-0000-0000000199b1' from public.ride_requests
                       where id = '00000000-0000-0000-0000-0000000199e1'), 'still Amin''s trip');

-- The passenger declining.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000199b1');
insert into ids select 'h2', (public.trip_handover_request('00000000-0000-0000-0000-0000000199e1', 'CZ99BBBB')).id;
select pg_temp.as_user('00000000-0000-0000-0000-0000000199a1');
select public.trip_handover_rider_answer((select id from ids where k = 'h2'), false);
reset role;
select pg_temp.check((select status = 'declined_rider' from public.trip_handovers where id = (select id from ids where k = 'h2')),
  'declined by the passenger');
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000199b2', 'handover-offer-' ||
                       (select id from ids where k = 'h2') || '%') = 0, 'and the partner never asked');

-- 3. Nearby: free partners within the radius; the first to accept takes over -------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000199b1');
insert into ids select 'h3', (public.trip_handover_request('00000000-0000-0000-0000-0000000199e1')).id;
select pg_temp.as_user('00000000-0000-0000-0000-0000000199a1');
select public.trip_handover_rider_answer((select id from ids where k = 'h3'), true);
reset role;
select pg_temp.check((select array_agg(partner_id order by partner_id) from public.trip_handover_candidates
                       where handover_id = (select id from ids where k = 'h3'))
                     = array['00000000-0000-0000-0000-0000000199b3'::uuid],
  'only the free partner nearby is asked (not one on a trip, not one far away)');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000199b5');
select pg_temp.refused($q$select public.trip_handover_accept((select id from ids where k = 'h3'))$q$,
  'a partner not asked accepting');
select pg_temp.as_user('00000000-0000-0000-0000-0000000199b3');
select public.trip_handover_accept((select id from ids where k = 'h3'));
reset role;
select pg_temp.check((select partner_id = '00000000-0000-0000-0000-0000000199b3' and partner_name = 'Chong'
                             and status = 'on_trip' and handover_meet_lat = 3.157 and handed_over_at is not null
                        from public.ride_requests where id = '00000000-0000-0000-0000-0000000199e1'),
  'the trip is Chong''s, meeting at the car');
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000199a1', 'handover-taken-%') = 1, 'the passenger is told');
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000199b1', 'handover-accepted-%') = 1, 'Amin is told');
select pg_temp.check((select bool_and(closed) from public.trip_handover_candidates
                       where handover_id = (select id from ids where k = 'h3')),
  'the offer is closed for the partners asked');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000199b1');
select pg_temp.check((select status = 'accepted' and to_name = 'Chong' and share_percent = 20
                        from public.trip_handovers_mine('00000000-0000-0000-0000-0000000199e1')
                       where id = (select id from ids where k = 'h3')),
  'Amin still sees how the handover went');
select pg_temp.as_user('00000000-0000-0000-0000-0000000199b3');
select public.trip_handover_boarded((select id from ids where k = 'h3'));
reset role;
select pg_temp.check((select handover_boarded_at is not null from public.ride_requests
                       where id = '00000000-0000-0000-0000-0000000199e1'), 'the passenger is with Chong');

-- 4. Completion: Chong pays the commission; Amin gets 20% of the net from Chong's credit -----
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000199e1';
select pg_temp.check((select share_amount = round((100 - (select commission_amount from public.ride_requests
                                                          where id = '00000000-0000-0000-0000-0000000199e1')) * 0.20, 2)
                        from public.trip_handovers where id = (select id from ids where k = 'h3')),
  '20% of the fare less commission');
select pg_temp.check((select sum(amount) from public.wallet_transactions
                       where user_id = '00000000-0000-0000-0000-0000000199b1' and kind = 'handover_share')
                     = (select share_amount from public.trip_handovers where id = (select id from ids where k = 'h3')),
  'Amin''s GET credit gets the share');
select pg_temp.check((select sum(amount) from public.wallet_transactions
                       where user_id = '00000000-0000-0000-0000-0000000199b3' and kind = 'handover_share')
                     = -(select share_amount from public.trip_handovers where id = (select id from ids where k = 'h3')),
  'from Chong''s');
select pg_temp.check(exists (select 1 from public.wallet_transactions
                              where user_id = '00000000-0000-0000-0000-0000000199b3' and kind = 'commission'),
  'Chong pays the commission');

-- 5. Withdrawn, and no answer in time ----------------------------------------------------------
update public.ride_requests set status = 'on_trip', partner_id = '00000000-0000-0000-0000-0000000199b1'
 where id = '00000000-0000-0000-0000-0000000199e2';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000199b1');
insert into ids select 'h4', (public.trip_handover_request('00000000-0000-0000-0000-0000000199e2', 'CZ99BBBB')).id;
select public.trip_handover_cancel((select id from ids where k = 'h4'));
insert into ids select 'h5', (public.trip_handover_request('00000000-0000-0000-0000-0000000199e2', 'CZ99BBBB')).id;
reset role;
select pg_temp.check((select status = 'cancelled' from public.trip_handovers where id = (select id from ids where k = 'h4')),
  'withdrawn');
update public.trip_handovers set answer_by = now() - interval '1 minute' where id = (select id from ids where k = 'h5');
select public.trip_handovers_tick();
select pg_temp.check((select status = 'expired' from public.trip_handovers where id = (select id from ids where k = 'h5')),
  'lapsed');
select pg_temp.check(pg_temp.told('00000000-0000-0000-0000-0000000199b1', 'handover-lapsed-%') = 1, 'the driver is told');

-- 6. Nothing readable by others ----------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000199b5');
select pg_temp.check(not exists (select 1 from public.trip_handovers), 'handovers of others are hidden');
select pg_temp.check(not exists (select 1 from public.trip_handovers_mine()), 'and not listed');
select pg_temp.check(not exists (select 1 from public.trip_handover_candidates), 'nor who was asked');
reset role;

select 'trip_handover: all passed';
rollback;
