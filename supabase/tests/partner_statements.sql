-- ============================================================================
-- Regression test for migration 0201: partner statements and the Earnings
-- page's totals. Fares and the surcharges an admin marks count as earnings;
-- taxes, tolls and other surcharges pass through; commission and platform
-- fees are deductions; handover shares go both ways; incentives and
-- adjustments are their own lines; periods, revision, verification, online
-- hours and who may do what.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/partner_statements.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
end $$;

create or replace function pg_temp.as_user(p uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', coalesce(p::text, ''), true),
         set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
$$;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'FAILED: % was allowed', p_what;
exception when others then
  if sqlerrm like 'FAILED:%' then raise; end if;
end $$;

-- Moments in Malaysia time.
create or replace function pg_temp.myt(p text) returns timestamptz language sql immutable as $$
  select p::timestamp at time zone 'Asia/Kuala_Lumpur' $$;

grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.refused(text, text),
  pg_temp.myt(text) to authenticated;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000201a1'),  -- partner A
  ('00000000-0000-0000-0000-0000000201b1'),  -- partner B
  ('00000000-0000-0000-0000-0000000201e1'),  -- admin with edit rights
  ('00000000-0000-0000-0000-0000000201f1'),  -- admin who can only read
  ('00000000-0000-0000-0000-0000000201c1')   -- a rider
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000201e1', 'admin-settings-partner-statements', 'edit'),
  ('00000000-0000-0000-0000-0000000201f1', 'admin-settings-partner-statements', 'read');
insert into public.partners (auth_user_id, name, phone, status, display_id, ic, plate, joined_at) values
  ('00000000-0000-0000-0000-0000000201a1', 'Ahmad Bin Ali', '60120000201', 'approved', 'GR201A', '900101-14-5678',
   'WXY 201', '2026-01-01'),
  ('00000000-0000-0000-0000-0000000201b1', 'Bala Kumar', '60120000202', 'approved', 'GR201B', null, 'WXY 202',
   '2026-01-01');

update public.app_settings set value = value || '{"earningSurcharges": ["Airport"], "weekStart": "monday"}'
 where key = 'partner_statement';

-- The week of Monday 7 to Sunday 13 September 2026 (closed).
--   Trip 1: fare 20; Airport RM5 (earnings), Night 10% = 2 (pass-through), Scheduling fee RM2
--           (platform), SST 6% on 29 = 1.74 (tax), toll 3; commission 3; cash, RM4 in GET.coin.
--   Trip 2: fare 30 raised to 28 by bidding (ride_fare); commission 4.20; card.
--   Trip 3: 00:30 on Monday 14th (the next week).
insert into public.ride_requests (status, partner_id, fare, ride_fare, charges, toll_charges, commission_amount,
                                  fare_coins_value, paid_method, completed_at, service, rider_id)
select v.*, '00000000-0000-0000-0000-0000000201c1'::uuid from (values
  ('completed', '00000000-0000-0000-0000-0000000201a1'::uuid, 20::numeric, null::numeric,
   '[{"kind": "surcharge", "name": "Airport", "charge": "fixed", "value": 5},
     {"kind": "surcharge", "name": "Night", "charge": "percent", "value": 10},
     {"kind": "tax", "name": "SST", "charge": "percent", "value": 6},
     {"kind": "surcharge", "name": "Scheduling fee", "charge": "fixed", "value": 2, "platform": true}]'::jsonb,
   3::numeric, 3::numeric, 4::numeric, 'cash', pg_temp.myt('2026-09-08 10:00'), 'car'),
  ('completed', '00000000-0000-0000-0000-0000000201a1', 30, 28, null, null, 4.2, null, 'get_wallet',
   pg_temp.myt('2026-09-12 23:30'), 'car'),
  ('completed', '00000000-0000-0000-0000-0000000201a1', 50, null, null, null, 7.5, null, 'cash',
   pg_temp.myt('2026-09-14 00:30'), 'car'),
  ('cancelled', '00000000-0000-0000-0000-0000000201a1'::uuid, 99, null, null, null, null, null, null,
   pg_temp.myt('2026-09-09 12:00'), 'car')) v;
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, created_at) values
  ('00000000-0000-0000-0000-0000000201a1', 'get_credit', 'incentive', 10, pg_temp.myt('2026-09-09 08:00')),
  ('00000000-0000-0000-0000-0000000201a1', 'get_credit', 'handover_share', 6, pg_temp.myt('2026-09-10 08:00')),
  ('00000000-0000-0000-0000-0000000201a1', 'get_credit', 'handover_share', -1.5, pg_temp.myt('2026-09-11 08:00')),
  ('00000000-0000-0000-0000-0000000201a1', 'get_credit', 'commission', -3, pg_temp.myt('2026-09-08 10:00')),
  ('00000000-0000-0000-0000-0000000201a1', 'get_wallet', 'ride_earning', 99, pg_temp.myt('2026-09-08 10:00'));

-- 1. One trip's lines -----------------------------------------------------------------------
select pg_temp.check((select l = '{"fare": 20, "surcharges": 5, "platformCollected": 2, "surchargesPass": 2,
                                  "taxes": 1.74, "tolls": 3, "otherCharges": 0, "commission": 3, "platformFees": 2,
                                  "coins": 4, "cash": 29.74, "distanceKm": 0}'::jsonb
                        from (select public.statement_ride_lines(r, array['Airport']) l from public.ride_requests r
                               where r.partner_id = '00000000-0000-0000-0000-0000000201a1' and r.fare = 20) s),
  'trip lines: Airport earns, Night passes through, the scheduling fee is collected and deducted, '
  'SST 6% of fare plus surcharges, cash is the total less GET.coin');
select pg_temp.check((select (l->>'surcharges')::numeric = 0 and (l->>'surchargesPass')::numeric = 7
                        from (select public.statement_ride_lines(r, '{}') l from public.ride_requests r
                               where r.partner_id = '00000000-0000-0000-0000-0000000201a1' and r.fare = 20) s),
  'with no surcharge marked, every surcharge passes through');

-- 2. The week's totals ----------------------------------------------------------------------
select pg_temp.check((select (t->>'trips')::int = 2 and (t->>'fare')::numeric = 48 and (t->>'surcharges')::numeric = 5
                         and (t->>'platformCollected')::numeric = 2 and (t->>'taxes')::numeric = 1.74
                         and (t->>'tolls')::numeric = 3 and (t->>'commission')::numeric = 7.2
                         and (t->>'platformFees')::numeric = 2 and (t->>'incentives')::numeric = 10
                         and (t->>'handoverIn')::numeric = 6 and (t->>'handoverOut')::numeric = 1.5
                         and (t->>'adjustments')::numeric = 0
                         and (t->>'totalEarnings')::numeric = 71 and (t->>'totalDeductions')::numeric = 10.7
                         and (t->>'net')::numeric = 60.3 and (t->>'passThrough')::numeric = 6.74
                        from (select public.partner_statement_totals('00000000-0000-0000-0000-0000000201a1',
                                pg_temp.myt('2026-09-07'), pg_temp.myt('2026-09-14')) t) s),
  'week totals: fare uses ride_fare, cancelled and next-week trips left out, taxes and tolls not income, '
  'net = 48 + 5 + 2 + 10 + 6 - 7.20 - 2 - 1.50');

-- 3. Periods --------------------------------------------------------------------------------
select pg_temp.check(public.statement_week_start('2026-09-13') = '2026-09-07'
                     and public.statement_week_start('2026-09-07') = '2026-09-07',
  'weeks run Monday to Sunday by default');
select pg_temp.check(public.statement_period_end('weekly', '2026-09-07') = '2026-09-13'
                     and public.statement_period_end('monthly', '2026-02-01') = '2026-02-28'
                     and public.statement_period_end('annual', '2026-01-01') = '2026-12-31',
  'period ends');
select pg_temp.check(public.statement_period_status('00000000-0000-0000-0000-0000000201a1', 'weekly', '2026-09-07')
                     = 'final', 'a closed week is final');
select pg_temp.check(public.statement_period_status('00000000-0000-0000-0000-0000000201a1', 'weekly',
                       public.statement_week_start((now() at time zone 'Asia/Kuala_Lumpur')::date)) = 'provisional',
  'this week is provisional');
select pg_temp.check(public.statement_period_status('00000000-0000-0000-0000-0000000201a1', 'annual', '2026-01-01')
                     = 'provisional', 'this year is provisional');
select pg_temp.refused($$select public.statement_period_status('00000000-0000-0000-0000-0000000201a1', 'weekly',
                         '2026-09-08')$$, 'a week not starting on its first day');
select pg_temp.refused($$select public.statement_period_status('00000000-0000-0000-0000-0000000201a1', 'monthly',
                         '2025-11-01')$$, 'a month before the partner joined');
select pg_temp.refused($$select public.statement_period_status('00000000-0000-0000-0000-0000000201a1', 'annual',
                         '2030-01-01')$$, 'a year in the future');
select pg_temp.refused($$select public.statement_period_status('00000000-0000-0000-0000-0000000201a1', 'daily',
                         '2026-09-07')$$, 'an unknown period type');

-- 4. Settings: only admins with edit rights; Sunday weeks ------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000201f1');
select pg_temp.refused($$select public.set_partner_statement_config('{"weekStart": "sunday"}')$$,
  'an admin who can only view changing the settings');
select pg_temp.refused($$select public.admin_credit_incentive('GR201A', 5, 'Bonus')$$,
  'an admin who can only view crediting an incentive');
select pg_temp.check((select count(*) >= 2 from public.statement_surcharge_names()),
  'any admin sees the surcharge names to choose from');
select pg_temp.as_user('00000000-0000-0000-0000-0000000201a1');
select pg_temp.refused($$select public.set_partner_statement_config('{"weekStart": "sunday"}')$$,
  'a partner changing the settings');
select pg_temp.refused($$select * from public.statement_surcharge_names()$$, 'a partner listing surcharge names');
select pg_temp.refused($$select public.admin_post_adjustment('GR201A', 50, 'Mine')$$, 'a partner adjusting');

select pg_temp.as_user('00000000-0000-0000-0000-0000000201e1');
select pg_temp.check((select v->>'weekStart' = 'sunday' and v->'earningSurcharges' = '["Airport", "Night"]'
                         and v->>'verifyUrl' = '' and (v->>'showBank')::boolean = false
                         and v->>'companyName' = 'PUNCAK NIAGA BERSAMA SDN. BHD.'
                        from (select public.set_partner_statement_config('{"weekStart": "sunday",
                          "earningSurcharges": ["Night", " Airport", "Airport", ""], "verifyUrl": "http://x",
                          "companyName": " PUNCAK NIAGA BERSAMA SDN. BHD. ", "showBank": "nope"}') v) s),
  'settings cleaned: names trimmed and de-duplicated, only https verify links');
select pg_temp.check(public.statement_week_start('2026-09-13') = '2026-09-13'
                     and public.statement_week_start('2026-09-12') = '2026-09-06',
  'with Sunday weeks, a week runs Sunday to Saturday');
select public.set_partner_statement_config('{"weekStart": "monday", "earningSurcharges": ["Airport"],
  "companyName": "PUNCAK NIAGA BERSAMA SDN. BHD.", "companySsm": "202201025129 (1470826-D)",
  "supportContact": "+6012-5252255"}');

-- 5. Incentives and adjustments; a final statement is revised --------------------------------
insert into public.partner_statements (statement_no, partner_user_id, period_type, period_start, period_end, lang,
                                       is_final, totals, storage_path, data_hash, verify_token)
values ('GR-W-2026-000001', '00000000-0000-0000-0000-0000000201a1', 'weekly', '2026-09-07', '2026-09-13', 'en', true,
        '{"net": 60.3}', 'x/y.pdf', 'abc', 'a1b2c3d4e5f6a1b2c3d4e5f6');
select pg_temp.check((select i.amount = 12.5 and i.label = 'Rainy day bonus'
                        from public.admin_credit_incentive('GR201A', 12.499, ' Rainy day bonus ') i),
  'an incentive is credited by partner ID');
select pg_temp.check(exists (select 1 from public.wallet_transactions where user_id = '00000000-0000-0000-0000-0000000201a1'
                                and wallet_type = 'get_credit' and kind = 'incentive' and amount = 12.5
                                and note = 'Incentive: Rainy day bonus'),
  'the incentive lands on GET credit with its own label');
select pg_temp.check(exists (select 1 from public.notification_outbox where profile_id = '00000000-0000-0000-0000-0000000201a1'
                                and title = 'Incentive credited'), 'the partner is told about the incentive');
select pg_temp.refused($$select public.admin_credit_incentive('nobody', 5, 'x')$$, 'an incentive for no one');
select pg_temp.refused($$select public.admin_credit_incentive('GR201A', -5, 'x')$$, 'a negative incentive');
select pg_temp.refused($$select public.admin_credit_incentive('GR201A', 5, ' ')$$, 'an incentive with no name');

select pg_temp.check((select a.amount = -2 and a.effective_at = pg_temp.myt('2026-09-10 12:00')
                        from public.admin_post_adjustment('60120000201', -2, 'Toll refunded twice', '2026-09-10') a),
  'an adjustment by phone, dated inside the week');
select pg_temp.check((select data_hash = 'stale' from public.partner_statements where statement_no = 'GR-W-2026-000001'),
  'the final statement covering that day is marked for revision');
select pg_temp.check((select (t->>'adjustments')::numeric = -2 and (t->>'net')::numeric = 58.3
                        from (select public.partner_statement_totals('00000000-0000-0000-0000-0000000201a1',
                                pg_temp.myt('2026-09-07'), pg_temp.myt('2026-09-14')) t) s),
  'the adjustment changes the week''s net');
select pg_temp.refused($$select public.admin_post_adjustment('GR201A', 0, 'x')$$, 'a zero adjustment');
select pg_temp.refused($$select public.admin_post_adjustment('GR201A', 5, 'x', '2031-01-01')$$,
  'an adjustment dated in the future');
select pg_temp.check((select count(*) = 2 from public.admin_statement_entries('all', 10)),
  'the admin lists incentives and adjustments');

-- 6. The partner's own reads ----------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000201a1');
select pg_temp.check((select (t->>'net')::numeric = 58.3
                        from (select public.my_earnings(pg_temp.myt('2026-09-07'), pg_temp.myt('2026-09-14')) t) s),
  'the Earnings page reads the same totals');
select pg_temp.check((select count(*) = 7 and sum((totals->>'net')::numeric) = 58.3
                        from public.my_earnings_series(pg_temp.myt('2026-09-07'), pg_temp.myt('2026-09-14'), 'day')),
  'seven days that add up to the week');
select pg_temp.check((select count(*) = 1 and min(bucket_start) = '2026-09-07'
                        from public.my_earnings_series(pg_temp.myt('2026-09-07'), pg_temp.myt('2026-09-14'), 'week')),
  'one week bucket');
select pg_temp.refused($$select public.my_earnings(now(), now() - interval '1 day')$$, 'a backwards period');
select pg_temp.refused($$select public.my_earnings(now() - interval '2 years', now())$$, 'more than a year');

select pg_temp.check((select d->>'status' = 'final' and jsonb_array_length(d->'trips') = 2
                         and jsonb_array_length(d->'breakdown') = 7 and d->'partner'->>'ic' = '******-**-5678'
                         and d->'partner'->>'displayId' = 'GR201A' and d->'partner'->'bank' = 'null'
                         and d->'company'->>'ssm' = '202201025129 (1470826-D)'
                         and (d->'totals'->>'net')::numeric = 58.3 and jsonb_array_length(d->'adjustments') = 1
                        from (select public.partner_statement_data('weekly', '2026-09-07', 'ms') d) s),
  'weekly statement data: trips, seven days, IC masked, no bank line by default');
select pg_temp.check((select jsonb_array_length(d->'breakdown') = 5
                         and (d->'breakdown'->0->>'start') = '2026-09-01' and (d->'breakdown'->0->>'end') = '2026-09-06'
                        from (select public.partner_statement_data('monthly', '2026-09-01') d) s),
  'monthly statement: the weeks, clipped to the month');
select pg_temp.check((select jsonb_array_length(d->'breakdown') = 12
                        from (select public.partner_statement_data('annual', '2026-01-01') d) s),
  'annual statement: twelve months');
select pg_temp.check((select period_start = '2026-09-07' and status = 'final' and net = 58.3 and trips = 2
                        from public.my_statement_periods('weekly', 1, '2026-09-14')),
  'the statements list');
select pg_temp.check((select count(*) = 4 from public.my_statement_periods('monthly', 12, '2026-05-01')),
  'months listed back to when the partner joined, no further');

-- The bank line, when the admin turns it on.
select public.set_my_payout_account('Maybank', '1234-5678 9012', 'Ahmad Bin Ali');
select pg_temp.refused($$select public.set_my_payout_account('Maybank', '12ab', 'Ahmad')$$, 'a bad account number');
update public.app_settings set value = value || '{"showBank": true}' where key = 'partner_statement';
select pg_temp.check((select d->'partner'->'bank' = '{"bank": "Maybank", "account": "****9012", "holder": "Ahmad Bin Ali"}'
                        from (select public.partner_statement_data('weekly', '2026-09-07') d) s),
  'the bank line, account masked');

-- Others are kept out.
select pg_temp.as_user('00000000-0000-0000-0000-0000000201c1');
select pg_temp.refused($$select public.partner_statement_data('weekly', '2026-09-07')$$, 'a rider reading a statement');
select pg_temp.refused($$select * from public.my_statement_periods('weekly')$$, 'a rider listing statements');
select pg_temp.as_user('00000000-0000-0000-0000-0000000201b1');
select pg_temp.check((select (t->>'trips')::int = 0
                        from (select public.my_earnings(pg_temp.myt('2026-09-07'), pg_temp.myt('2026-09-14')) t) s),
  'partner B sees only their own earnings');

-- 7. Verification ---------------------------------------------------------------------------
select pg_temp.check((select v->>'initials' = 'ABA' and v->>'statementNo' = 'GR-W-2026-000001'
                         and (v->>'net')::numeric = 60.3 and (v->>'final')::boolean
                        from (select public.statement_verify('a1b2c3d4e5f6a1b2c3d4e5f6') v) s),
  'verify by token: initials, period and net');
select pg_temp.check(public.statement_verify('a1b2c3d4') is null and public.statement_verify(null) is null,
  'a wrong token shows nothing');
select pg_temp.check(public.statement_next_no('weekly') ~ '^GR-W-\d{4}-\d{6}$', 'statement numbers');
select pg_temp.check(public.statement_take('00000000-0000-0000-0000-0000000201a1'), 'first generation allowed');
select pg_temp.check((select bool_and(public.statement_take('00000000-0000-0000-0000-0000000201a1'))
                        from generate_series(1, 19)), 'twenty an hour');
select pg_temp.check(not public.statement_take('00000000-0000-0000-0000-0000000201a1'), 'the 21st is refused');

-- 8. Online hours ---------------------------------------------------------------------------
insert into public.driver_presence (profile_id, online, lat, lng, updated_at)
values ('00000000-0000-0000-0000-0000000201a1', true, 3.1, 101.6, now());
select pg_temp.check((select count(*) = 1 from public.partner_online_sessions
                       where profile_id = '00000000-0000-0000-0000-0000000201a1' and ended_at is null),
  'going online opens a session');
update public.partner_online_sessions set started_at = now() - interval '2 hours', last_seen_at = now() - interval '10 minutes'
 where profile_id = '00000000-0000-0000-0000-0000000201a1';
update public.driver_presence set updated_at = now() where profile_id = '00000000-0000-0000-0000-0000000201a1';
select pg_temp.check((select count(*) = 2 and count(ended_at) = 1 from public.partner_online_sessions
                       where profile_id = '00000000-0000-0000-0000-0000000201a1'),
  'a gap of more than five minutes ends the session where it was last seen and opens a new one');
select pg_temp.check(public.partner_online_hours('00000000-0000-0000-0000-0000000201a1', now() - interval '1 day',
                       now() + interval '1 minute') between 1.82 and 1.85, 'one hour fifty online');
update public.driver_presence set online = false where profile_id = '00000000-0000-0000-0000-0000000201a1';
select pg_temp.check((select count(*) = 0 from public.partner_online_sessions
                       where profile_id = '00000000-0000-0000-0000-0000000201a1' and ended_at is null),
  'going offline ends the session');

-- 9. The weekly incentive rule --------------------------------------------------------------
select pg_temp.as_user(null);
insert into public.driver_incentive (values, active) values
  ('{"name": "Two-trip week", "minRides": 2, "reward": 15, "active": true}', true),
  ('{"name": "Off", "minRides": 1, "reward": 99, "active": false}', true),
  ('{"name": "Broken", "minRides": "x", "reward": 5}', true);
insert into public.ride_requests (status, partner_id, rider_id, fare, completed_at)
select 'completed', '00000000-0000-0000-0000-0000000201b1', '00000000-0000-0000-0000-0000000201c1', 10,
       (public.statement_week_start((now() at time zone 'Asia/Kuala_Lumpur')::date - 7) + 2)::timestamp
         at time zone 'Asia/Kuala_Lumpur' + g * interval '1 hour'
  from generate_series(1, 2) g;
select pg_temp.check(public.partner_incentives_weekly() >= 1, 'the rule credits drivers who met it last week');
select pg_temp.check(exists (select 1 from public.wallet_transactions where user_id = '00000000-0000-0000-0000-0000000201b1'
                                and kind = 'incentive' and amount = 15 and note = 'Incentive: Two-trip week'),
  'partner B gets the Two-trip week reward');
select pg_temp.check(not exists (select 1 from public.partner_incentives where amount = 99), 'inactive rules skipped');
select pg_temp.check(public.partner_incentives_weekly() = 0, 'running again credits nothing twice');

rollback;
