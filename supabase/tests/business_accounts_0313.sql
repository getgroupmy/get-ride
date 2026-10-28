-- ============================================================================
-- Regression test for migration 0313: Business accounts.
--   * the settings: the Default rule, a region rule that sets only some
--     values, a narrower one, an inactive one, the account's overrides;
--     the Default can't be deleted, only admins with the page write rules;
--   * applying (the document, the phone, one account per SSM number), the
--     admin's approval (EDIT only), suspension;
--   * members invited by phone, joining, roles, the last Admin;
--   * booking: membership, the account active, the hours, the note, the
--     approval asked, approved and used once, the member's limit, the
--     company's cap, the credit limit, the wallet, the roles and Freight,
--     the overdue pause; the server's columns, the payment mode, no promo;
--     a booking for later checked at its pickup time;
--   * settlement: the driver paid in full as in-app, the company charged
--     less the discount (invoice accrued, or the wallet debited), once;
--     the business commission %;
--   * invoices issued when the month ends, marked paid by an admin, the
--     lines for the PDF and CSV; who may read and call what.
-- The settings resolution is also in test/business_accounts_test.dart.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/business_accounts_0313.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up companies, places and people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000313a1'),  -- admin, EDIT on Business accounts
  ('00000000-0000-0000-0000-0000000313a2'),  -- admin, READ on Business accounts
  ('00000000-0000-0000-0000-0000000313c1'),  -- applicant, the company's Admin
  ('00000000-0000-0000-0000-0000000313c2'),  -- invited: Rider
  ('00000000-0000-0000-0000-0000000313c3'),  -- invited: Booker
  ('00000000-0000-0000-0000-0000000313c4'),  -- not a member
  ('00000000-0000-0000-0000-0000000313d1')   -- driver
on conflict do nothing;
insert into public.profiles (id, name, phone)
select u.id, 'Test 313 ' || right(u.id::text, 2), '+601003131' || lpad((row_number() over (order by u.id))::text, 2, '0')
  from auth.users u where u.id::text like '00000000-0000-0000-0000-0000000313%'
on conflict (id) do update set name = excluded.name, phone = excluded.phone;
-- The phones: c1 +60100313101, c2 …102, c3 …103, c4 …104.
update public.profiles p set phone = '+6010031310' || right(p.id::text, 1)
 where p.id::text like '00000000-0000-0000-0000-0000000313c%';
update public.profiles p set phone = case right(p.id::text, 2) when 'a1' then '+60100313201' when 'a2' then '+60100313202'
                                                      else '+60100313301' end
 where p.id::text like '00000000-0000-0000-0000-0000000313a%' or p.id::text like '00000000-0000-0000-0000-0000000313d%';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000313a1', 'admin-business-accounts', 'edit'),
  ('00000000-0000-0000-0000-0000000313a2', 'admin-business-accounts', 'read')
on conflict do nothing;
insert into public.settings_entries (id, category, values, position) values
  ('00000000-0000-0000-0000-000000031351', 'vehicle-services', '{"name": "Van 313", "serviceTypes": ["Freight"]}', 9313);

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_server() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
-- What [p_sql] does as [p_user] in the app's role: 'ok <rows>' or the error.
create or replace function pg_temp.run_as(p_user uuid, p_sql text) returns text language plpgsql as $$
declare n integer;
begin
  perform set_config('role', 'authenticated', true);
  perform pg_temp.as_user(p_user);
  execute p_sql;
  get diagnostics n = row_count;
  perform pg_temp.as_server();
  return 'ok ' || n;
exception when others then
  perform pg_temp.as_server();
  return sqlerrm;
end $$;
-- A booking by [p_rider] (inserted as the server, the rider's claims set).
create or replace function pg_temp.book(p_rider uuid, p_account uuid, p_fare numeric, p_extra jsonb default '{}')
returns text language plpgsql as $$
declare v uuid := coalesce((p_extra->>'id')::uuid, gen_random_uuid());
begin
  perform pg_temp.as_user(p_rider);
  insert into public.ride_requests (id, rider_id, status, service, pickup_lat, pickup_lng, fare, ride_fare,
                                    pickup_name, drop_name, business_account_id, business_note, booked_for_name,
                                    payment_mode, promo_code_id)
  values (v, p_rider, 'open', coalesce(p_extra->>'service', 'Car'), 3.1, 101.6, p_fare, p_fare,
          'Office 313', 'Client 313', p_account, p_extra->>'note', p_extra->>'for', 'Cash',
          (p_extra->>'promo')::uuid);
  perform pg_temp.as_server();
  return v::text;
exception when others then
  perform pg_temp.as_server();
  return sqlerrm;
end $$;
create temp table t_ids (k text primary key, id uuid);
grant all on t_ids to authenticated;

-- ---- The settings ------------------------------------------------------------------------------------
select pg_temp.check((select count(*) from public.business_region_rules where country = '') = 1, 'the Default rule is seeded');
select pg_temp.check(public.business_rule_settings('Nowhere 313', '', '') ?& array['creditLimit', 'dueDays', 'overdueDays',
  'discountPct', 'commissionPct', 'memberLimit', 'terms', 'services'], 'the Default answers every value everywhere');
-- Leave the Default as seeded for this test whatever the database holds.
update public.business_region_rules set credit_limit = 10000, due_days = 30, overdue_days = 14, discount_pct = 5,
       commission_pct = 15, member_limit = 500, terms = 'invoice', services = array['ride', 'scheduled', 'freight', 'courier']
 where country = '';
delete from public.business_region_rules where country like 'Bizland%';
insert into public.business_region_rules (country, state, city, credit_limit, due_days, terms, position) values
  ('Bizland 313', '', '', 2000, null, null, 1),
  ('Bizland 313', 'North 313', '', null, 14, 'wallet', 1),
  ('Bizland 313', 'North 313', 'Port 313', 9000, null, null, 1);
insert into public.business_region_rules (country, state, city, discount_pct, active) values
  ('Bizland 313', 'South 313', '', 40, false);
select pg_temp.check((public.business_rule_settings('Bizland 313', 'North 313', '')->>'creditLimit')::numeric = 2000,
  'a state rule leaves the country''s credit limit');
select pg_temp.check(public.business_rule_settings('Bizland 313', 'North 313', '')->>'terms' = 'wallet'
  and (public.business_rule_settings('Bizland 313', 'North 313', '')->>'dueDays')::int = 14, 'and sets its own values');
select pg_temp.check((public.business_rule_settings('bizland 313', 'north 313', 'port 313')->>'creditLimit')::numeric = 9000,
  'the narrowest rule wins, names in any case');
select pg_temp.check((public.business_rule_settings('Bizland 313', 'South 313', '')->>'discountPct')::numeric = 5,
  'an inactive rule is skipped');
select pg_temp.check((public.business_rule_settings('Elsewhere', '', '')->>'creditLimit')::numeric = 10000, 'no rule: the Default');

-- Who writes the rules.
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313a2',
  $q$update public.business_region_rules set credit_limit = 1 where country = 'Bizland 313' and state = ''$q$) = 'ok 0',
  'a READ admin changes no rule');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313a1',
  $q$update public.business_region_rules set credit_limit = 2500 where country = 'Bizland 313' and state = ''$q$) = 'ok 1',
  'an EDIT admin changes a rule');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313a1',
  $q$delete from public.business_region_rules where country = ''$q$) = 'ok 0', 'the Default can''t be deleted');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313c1',
  $q$insert into public.business_region_rules (country, credit_limit) values ('Bizland 313b', 1)$q$) like '%row-level security%'
  or pg_temp.run_as('00000000-0000-0000-0000-0000000313c1',
  $q$insert into public.business_region_rules (country, credit_limit) values ('Bizland 313b', 1)$q$) like '%permission denied%',
  'a member of the public writes no rule');

-- ---- Applying -----------------------------------------------------------------------------------------
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313c1',
  $q$select public.business_apply('Contoh 313 Sdn Bhd', '202301031300', 'Sdn. Bhd.', 'Lot 1', 'Malaysia', 'Selangor', '', null)$q$)
  like 'BUSINESS_DOCUMENT%', 'the SSM document is needed');
select pg_temp.as_user('00000000-0000-0000-0000-0000000313c1');
insert into t_ids select 'acc', public.business_apply('Contoh 313 Sdn Bhd', '202301031300', 'Sdn. Bhd.', 'Lot 1, Jalan 313',
  'Malaysia', 'Selangor', 'Shah Alam', 'https://x.supabase.co/storage/v1/object/business-documents/00000000-0000-0000-0000-0000000313c1/ssm.pdf');
select pg_temp.as_server();
select pg_temp.check((select status = 'pending' and applied_by = '00000000-0000-0000-0000-0000000313c1'
                        from public.business_accounts where id = (select id from t_ids where k = 'acc')), 'the account waits');
select pg_temp.check((select role = 'admin' and status = 'active' from public.business_members
                       where account_id = (select id from t_ids where k = 'acc')), 'the applicant is its Admin');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313c4',
  $q$select public.business_apply('Copy 313', '2023 0103 1300', null, null, 'Malaysia', 'Selangor', '', 'https://x/y')$q$)
  like 'BUSINESS_EXISTS%', 'one account per SSM number');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c1', (select id from t_ids where k = 'acc'), 20)
  like 'BUSINESS_ACCOUNT%', 'no booking while it waits');

-- The admin approves (READ can't).
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313a2',
  format('select public.admin_business_set_status(%L, %L)', (select id from t_ids where k = 'acc'), 'active'))
  like 'not_authorized%', 'a READ admin approves nothing');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313a1',
  format('select public.admin_business_set_status(%L, %L)', (select id from t_ids where k = 'acc'), 'active'))
  = 'ok 1', 'an EDIT admin approves');
select pg_temp.check((select status = 'active' and approved_at is not null from public.business_accounts
                       where id = (select id from t_ids where k = 'acc')), 'the account is active');
select pg_temp.check(exists (select 1 from public.admin_audit_log where action = 'business_account_status'
                              and detail->>'account_id' = (select id from t_ids where k = 'acc')::text), 'and logged');
-- The account's own overrides on top of the rules.
select pg_temp.as_user('00000000-0000-0000-0000-0000000313a1');
select public.admin_business_save((select id from t_ids where k = 'acc'),
  '{"creditLimit": 100, "discountPct": 10, "commissionPct": 12, "memberLimit": 60}');
select pg_temp.as_server();
select pg_temp.check((public.business_settings_for((select id from t_ids where k = 'acc'))->>'creditLimit')::numeric = 100
  and (public.business_settings_for((select id from t_ids where k = 'acc'))->>'dueDays')::int = 30,
  'an override sets its value; the rest follow the rules');

-- ---- Members ------------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000313c1');
insert into t_ids select 'rider', public.business_member_invite((select id from t_ids where k = 'acc'),
  '+60 10-031 3102', 'Daniel', 'rider', 'Sales', null);
insert into t_ids select 'booker', public.business_member_invite((select id from t_ids where k = 'acc'),
  '+601003131 03', 'Ravi', 'booker', 'Logistics', 0);
select pg_temp.as_server();
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313c1',
  format('select public.business_member_invite(%L, %L, null, %L)', (select id from t_ids where k = 'acc'), '+60100313102', 'rider'))
  like 'BUSINESS_MEMBER_EXISTS%', 'a number is invited once');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313c2',
  format('select public.business_member_invite(%L, %L, null, %L)', (select id from t_ids where k = 'acc'), '+60100313199', 'rider'))
  like 'not_authorized%', 'only its Admins invite');
select pg_temp.check(exists (select 1 from public.notification_outbox where profile_id = '00000000-0000-0000-0000-0000000313c2'
                              and event_id like 'business-invite-%'), 'the invited person is told');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c2', (select id from t_ids where k = 'acc'), 20)
  like 'BUSINESS_NOT_MEMBER%', 'an invitation books nothing until joined');
select pg_temp.as_user('00000000-0000-0000-0000-0000000313c2');
select pg_temp.check(jsonb_array_length(public.business_my_accounts()) = 1
  and public.business_my_accounts()->0->>'memberStatus' = 'invited', 'the invitation is listed');
select public.business_join((select id from t_ids where k = 'acc'));
select pg_temp.as_user('00000000-0000-0000-0000-0000000313c3');
select public.business_join((select id from t_ids where k = 'acc'));
select pg_temp.as_server();
select pg_temp.check((select count(*) = 2 from public.business_members
                       where account_id = (select id from t_ids where k = 'acc') and status = 'active'
                         and profile_id in ('00000000-0000-0000-0000-0000000313c2', '00000000-0000-0000-0000-0000000313c3')),
  'both joined, matched by the phone''s digits');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313c1',
  format('select public.business_leave(%L)', (select id from t_ids where k = 'acc'))) like 'BUSINESS_LAST_ADMIN%',
  'the last Admin stays');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c4', (select id from t_ids where k = 'acc'), 20)
  like 'BUSINESS_NOT_MEMBER%', 'a stranger can''t book on it');

-- ---- Booking ------------------------------------------------------------------------------------------
-- The rider: RM 20, 10% off: RM 18 against a RM 60 limit and RM 100 credit.
insert into t_ids select 'r1', pg_temp.book('00000000-0000-0000-0000-0000000313c2', (select id from t_ids where k = 'acc'), 20,
  '{"promo": "00000000-0000-0000-0000-000000031399"}')::uuid;
select pg_temp.check((select payment_mode = 'Business: Contoh 313 Sdn Bhd' and business_terms = 'invoice'
                             and business_discount_pct = 10 and business_commission_pct = 12 and promo_code_id is null
                             and business_member_id = (select id from t_ids where k = 'rider')
                        from public.ride_requests where id = (select id from t_ids where k = 'r1')),
  'the ride carries the server''s business columns, no promo');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c2', (select id from t_ids where k = 'acc'), 50)
  like 'BUSINESS_MEMBER_LIMIT%', 'the member''s monthly limit counts trips under way');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c2', (select id from t_ids where k = 'acc'), 20,
  '{"for": "Guest"}') like 'BUSINESS_ROLE%', 'a Rider books for themselves only');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c2', (select id from t_ids where k = 'acc'), 20,
  '{"service": "Van 313"}') like 'BUSINESS_ROLE%', 'a Rider books no Freight');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c3', (select id from t_ids where k = 'acc'), 95)
  like 'BUSINESS_CREDIT%', 'the credit limit counts what is under way');
-- The rules.
update public.business_accounts set bookers_freight = false where id = (select id from t_ids where k = 'acc');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c3', (select id from t_ids where k = 'acc'), 10,
  '{"service": "Van 313"}') like 'BUSINESS_ROLE%', 'Bookers book Freight only when the rule allows');
select pg_temp.as_user('00000000-0000-0000-0000-0000000313c1');
select public.business_rules_set((select id from t_ids where k = 'acc'), jsonb_build_object(
  'hoursOn', true,
  'hoursFrom', (extract(hour from now() at time zone 'Asia/Kuala_Lumpur')::int + 2) % 24,
  'hoursUntil', case when (extract(hour from now() at time zone 'Asia/Kuala_Lumpur')::int + 3) % 24 = 0 then 24
                     else (extract(hour from now() at time zone 'Asia/Kuala_Lumpur')::int + 3) % 24 end,
  'bookersFreight', true));
select pg_temp.as_server();
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c3', (select id from t_ids where k = 'acc'), 10)
  like 'BUSINESS_HOURS%', 'outside the booking hours');
select pg_temp.as_user('00000000-0000-0000-0000-0000000313c1');
select public.business_rules_set((select id from t_ids where k = 'acc'), jsonb_build_object(
  'hoursFrom', extract(hour from now() at time zone 'Asia/Kuala_Lumpur')::int,
  'hoursUntil', extract(hour from now() at time zone 'Asia/Kuala_Lumpur')::int + 1,
  'noteRequired', true, 'approvalOn', true, 'approvalOver', 15));
select pg_temp.as_server();
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c3', (select id from t_ids where k = 'acc'), 10)
  like 'BUSINESS_NOTE%', 'a trip note is required');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c3', (select id from t_ids where k = 'acc'), 20,
  '{"note": "Client visit"}') like 'BUSINESS_APPROVAL%', 'above RM 15 needs an approval');
select pg_temp.as_user('00000000-0000-0000-0000-0000000313c3');
select pg_temp.check((public.business_booking_check((select id from t_ids where k = 'acc'), 'Car', 20, null, 'x')->>'needsApproval')::boolean,
  'the app''s check says so');
insert into t_ids select 'appr', public.business_approval_request((select id from t_ids where k = 'acc'), 22, 'Car',
  'Office 313', 'Client 313', 'Client visit');
select pg_temp.check((public.business_booking_check((select id from t_ids where k = 'acc'), 'Car', 20, null, 'x')->>'approvalPending')::boolean,
  'and that one is waiting');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313c3',
  format('select public.business_approval_decide(%L, true)', (select id from t_ids where k = 'appr'))) like 'not_authorized%',
  'a Booker approves nothing');
select pg_temp.as_user('00000000-0000-0000-0000-0000000313c1');
select public.business_approval_decide((select id from t_ids where k = 'appr'), true);
select pg_temp.as_server();
insert into t_ids select 'r2', pg_temp.book('00000000-0000-0000-0000-0000000313c3', (select id from t_ids where k = 'acc'), 20,
  '{"note": "Client visit"}')::uuid;
select pg_temp.check((select status = 'used' and ride_id = (select id from t_ids where k = 'r2')
                        from public.business_approvals where id = (select id from t_ids where k = 'appr')),
  'the approval is used by the trip');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c3', (select id from t_ids where k = 'acc'), 20,
  '{"note": "Again"}') like 'BUSINESS_APPROVAL%', 'once');
-- The company's cap: RM 18 + RM 18 under way; RM 40 cap.
select pg_temp.as_user('00000000-0000-0000-0000-0000000313c1');
select public.business_rules_set((select id from t_ids where k = 'acc'), '{"approvalOn": false, "capOn": true, "monthlyCap": 40}');
select pg_temp.as_server();
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c1', (select id from t_ids where k = 'acc'), 10,
  '{"note": "x"}') like 'BUSINESS_CAP%', 'the monthly spend cap');

-- The server's columns stay.
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313c2',
  format('update public.ride_requests set business_discount_pct = 90 where id = %L', (select id from t_ids where k = 'r1')))
  like '%RIDE_SERVER_ONLY%' or pg_temp.run_as('00000000-0000-0000-0000-0000000313c2',
  format('update public.ride_requests set business_discount_pct = 90 where id = %L', (select id from t_ids where k = 'r1')))
  like 'ok 0%', 'the rider changes no business column');

-- ---- Settlement ---------------------------------------------------------------------------------------
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000313d1'
 where id = (select id from t_ids where k = 'r1');
select pg_temp.check((select commission_rate = 0.12 from public.ride_requests where id = (select id from t_ids where k = 'r1')),
  'the business commission % is locked on accept');
update public.ride_requests set status = 'completed', completed_at = now() where id = (select id from t_ids where k = 'r1');
select pg_temp.check((select payment_status = 'paid' and paid_method = 'business' and paid_amount = 20
                        from public.ride_requests where id = (select id from t_ids where k = 'r1')),
  'the trip is paid by the business');
select pg_temp.check((select sum(amount) = 20 from public.wallet_transactions
                       where ride_id = (select id from t_ids where k = 'r1') and kind = 'ride_earning' and method = 'business'),
  'the driver has the full RM 20 as an in-app payment');
select pg_temp.check((select commission_amount = 2.40 from public.ride_requests where id = (select id from t_ids where k = 'r1')),
  'and pays 12% commission');
select pg_temp.check((select gross = 20 and discount = 2 and charged = 18 and terms = 'invoice' and invoice_id is not null
                             and member_name = 'Daniel' and team = 'Sales'
                        from public.business_trips where ride_id = (select id from t_ids where k = 'r1')),
  'the business trip is recorded');
select pg_temp.check((select amount = 18 and trips = 1 and status = 'open' from public.business_invoices
                       where account_id = (select id from t_ids where k = 'acc')), 'and added to the month''s invoice');
select public.business_settle_ride((select id from t_ids where k = 'r1'));
select pg_temp.check((select count(*) = 1 from public.business_trips where ride_id = (select id from t_ids where k = 'r1'))
  and (select count(*) = 1 from public.wallet_transactions where ride_id = (select id from t_ids where k = 'r1')
         and kind = 'ride_earning'), 'settled once');
select pg_temp.as_user('00000000-0000-0000-0000-0000000313c2');
select pg_temp.check((public.business_my_accounts()->0->>'mySpend')::numeric = 18, 'the member sees their spend');
select pg_temp.as_server();

-- ---- Invoices -----------------------------------------------------------------------------------------
update public.ride_requests set status = 'cancelled' where id = (select id from t_ids where k = 'r2');
update public.business_invoices
   set period_start = (date_trunc('month', now() at time zone 'Asia/Kuala_Lumpur') - interval '1 month')::date,
       period_end = (date_trunc('month', now() at time zone 'Asia/Kuala_Lumpur') - interval '1 day')::date
 where account_id = (select id from t_ids where k = 'acc');
select pg_temp.check(public.business_invoices_tick() >= 1, 'last month''s invoice is issued');
select pg_temp.check((select status = 'issued' and due_date = period_end + 30 from public.business_invoices
                       where account_id = (select id from t_ids where k = 'acc')), 'due after the due days');
select pg_temp.check(exists (select 1 from public.notification_outbox where profile_id = '00000000-0000-0000-0000-0000000313c1'
                              and event_id like 'business-invoice-%'), 'the company''s Admin is told');
select pg_temp.as_user('00000000-0000-0000-0000-0000000313c1');
select pg_temp.check(jsonb_array_length(public.business_invoice_lines(
  (select id from public.business_invoices where account_id = (select id from t_ids where k = 'acc')))->'lines') = 1,
  'its lines for the PDF and CSV');
select pg_temp.as_server();
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313c2',
  format('select public.business_invoice_lines(%L)', (select id from public.business_invoices
                                                        where account_id = (select id from t_ids where k = 'acc'))))
  like 'not_authorized%', 'a Rider reads no invoice');
-- Overdue by the overdue days: bookings pause.
update public.business_accounts set cap_on = false, note_required = false, hours_on = false
 where id = (select id from t_ids where k = 'acc');
update public.business_invoices set due_date = public.business_today() - 14
 where account_id = (select id from t_ids where k = 'acc');
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c1', (select id from t_ids where k = 'acc'), 10)
  like 'BUSINESS_OVERDUE%', 'an invoice 14 days overdue pauses bookings');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313a2',
  format('select public.admin_business_invoice_paid(%L)', (select id from public.business_invoices
                                                             where account_id = (select id from t_ids where k = 'acc'))))
  like 'not_authorized%', 'a READ admin marks nothing paid');
select pg_temp.as_user('00000000-0000-0000-0000-0000000313a1');
select public.admin_business_invoice_paid((select id from public.business_invoices
                                            where account_id = (select id from t_ids where k = 'acc')), 'Bank transfer');
select pg_temp.as_server();
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c1', (select id from t_ids where k = 'acc'), 10)
  ~ '^[0-9a-f-]{36}$', 'paid: bookings go on');

-- ---- The prepaid wallet ----------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000313a1');
select public.admin_business_save((select id from t_ids where k = 'acc'), '{"terms": "wallet", "creditLimit": null}');
select pg_temp.as_server();
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c3', (select id from t_ids where k = 'acc'), 10)
  like 'BUSINESS_WALLET%', 'an empty wallet books nothing');
select pg_temp.as_user('00000000-0000-0000-0000-0000000313a1');
select pg_temp.check(public.admin_business_wallet_adjust((select id from t_ids where k = 'acc'), 50, 'Transfer 313') = 50,
  'a top-up is recorded');
select pg_temp.as_server();
insert into t_ids select 'r3', pg_temp.book('00000000-0000-0000-0000-0000000313c3', (select id from t_ids where k = 'acc'), 10)::uuid;
update public.ride_requests set status = 'accepted', partner_id = '00000000-0000-0000-0000-0000000313d1'
 where id = (select id from t_ids where k = 'r3');
update public.ride_requests set status = 'completed', completed_at = now() where id = (select id from t_ids where k = 'r3');
select pg_temp.check((select wallet_balance = 41 from public.business_accounts where id = (select id from t_ids where k = 'acc')),
  'the trip, RM 9 after 10% off, is taken from the wallet');
select pg_temp.check((select count(*) = 1 from public.business_wallet_entries
                       where ride_id = (select id from t_ids where k = 'r3') and amount = -9), 'once');

-- ---- A booking for later ---------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000313c3');
insert into public.scheduled_rides (rider_id, pickup_at, request, service, fare)
values ('00000000-0000-0000-0000-0000000313c3', now() + interval '1 day',
        jsonb_build_object('business_account_id', (select id from t_ids where k = 'acc'), 'business_approval_id',
                           '00000000-0000-0000-0000-000000031398', 'promo_code_id', '00000000-0000-0000-0000-000000031399',
                           'payment_mode', 'Cash'),
        'Car', 10);
select pg_temp.as_server();
select pg_temp.check((select request->>'payment_mode' = 'Business: Contoh 313 Sdn Bhd'
                             and not (request ? 'business_approval_id') and not (request ? 'promo_code_id')
                        from public.scheduled_rides where rider_id = '00000000-0000-0000-0000-0000000313c3'),
  'a booking for later is checked and carries the business payment');
update public.business_accounts set hours_on = true,
       hours_from = (extract(hour from (now() + interval '1 day') at time zone 'Asia/Kuala_Lumpur')::int + 2) % 24,
       hours_until = case when (extract(hour from (now() + interval '1 day') at time zone 'Asia/Kuala_Lumpur')::int + 3) % 24 = 0
                          then 24 else (extract(hour from (now() + interval '1 day') at time zone 'Asia/Kuala_Lumpur')::int + 3) % 24 end
 where id = (select id from t_ids where k = 'acc');
do $$
begin
  perform pg_temp.as_user('00000000-0000-0000-0000-0000000313c3');
  insert into public.scheduled_rides (rider_id, pickup_at, request, service, fare)
  values ('00000000-0000-0000-0000-0000000313c3', now() + interval '1 day',
          jsonb_build_object('business_account_id', (select id from t_ids where k = 'acc')), 'Car', 10);
  raise exception 'FAILED (not refused): a booking for later outside the hours at its pickup time';
exception when others then
  if sqlerrm not like 'BUSINESS_HOURS%' then
    raise exception 'FAILED: refused with %', sqlerrm;
  end if;
end $$;
select pg_temp.as_server();

-- Its release (the server, at the time): only the account and the member are checked again.
insert into t_ids select 'r4', gen_random_uuid();
insert into public.ride_requests (id, rider_id, status, service, pickup_lat, pickup_lng, fare, ride_fare,
                                  scheduled_ride_id, business_account_id, business_approval_id)
select (select id from t_ids where k = 'r4'), s.rider_id, 'open', 'Car', 3.1, 101.6, 10, 10, s.id,
       (s.request->>'business_account_id')::uuid, '00000000-0000-0000-0000-000000031398'
  from public.scheduled_rides s where s.rider_id = '00000000-0000-0000-0000-0000000313c3';
select pg_temp.check((select business_member_id = (select id from t_ids where k = 'booker') and business_terms = 'wallet'
                             and business_approval_id is null
                        from public.ride_requests where id = (select id from t_ids where k = 'r4')),
  'the released ride is the business''s, outside the hours checked when it was booked');
update public.ride_requests set status = 'cancelled' where id = (select id from t_ids where k = 'r4');

-- ---- Suspension ------------------------------------------------------------------------------------------
update public.business_accounts set hours_on = false where id = (select id from t_ids where k = 'acc');
select pg_temp.as_user('00000000-0000-0000-0000-0000000313a1');
select public.admin_business_set_status((select id from t_ids where k = 'acc'), 'suspended', 'Checking documents');
select pg_temp.as_server();
select pg_temp.check(pg_temp.book('00000000-0000-0000-0000-0000000313c1', (select id from t_ids where k = 'acc'), 5)
  like 'BUSINESS_ACCOUNT%', 'a suspended account books nothing');

-- ---- Reads, writes and grants ----------------------------------------------------------------------------
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313c1',
  format('update public.business_accounts set wallet_balance = 99999 where id = %L', (select id from t_ids where k = 'acc')))
  like '%permission denied%' or pg_temp.run_as('00000000-0000-0000-0000-0000000313c1',
  format('update public.business_accounts set wallet_balance = 99999 where id = %L', (select id from t_ids where k = 'acc')))
  = 'ok 0', 'nobody writes an account directly');
select pg_temp.check(pg_temp.run_as('00000000-0000-0000-0000-0000000313c1', 'select * from public.business_accounts') = 'ok 0',
  'members read the tables only through the functions');
select pg_temp.check(public.registration_file_owned('00000000-0000-0000-0000-0000000313c1', 'business-documents',
  '00000000-0000-0000-0000-0000000313c1/ssm.pdf'), 'the applicant owns their SSM document for reading');
select pg_temp.check(not public.registration_file_owned('00000000-0000-0000-0000-0000000313c2', 'business-documents',
  '00000000-0000-0000-0000-0000000313c1/ssm.pdf'), 'nobody else does');
do $$
declare
  f text;
begin
  foreach f in array array[
    'public.business_apply(text, text, text, text, text, text, text, text)', 'public.business_my_accounts()',
    'public.business_join(uuid)', 'public.business_leave(uuid)', 'public.business_account_detail(uuid)',
    'public.business_member_invite(uuid, text, text, text, text, numeric)',
    'public.business_member_update(uuid, text, text, numeric, boolean)', 'public.business_member_remove(uuid)',
    'public.business_rules_set(uuid, jsonb)', 'public.business_approval_request(uuid, numeric, text, text, text, text)',
    'public.business_approval_decide(uuid, boolean)',
    'public.business_booking_check(uuid, text, numeric, timestamptz, text, boolean, text)',
    'public.business_invoice_lines(uuid)', 'public.business_rule_settings(text, text, text)',
    'public.admin_business_set_status(uuid, text, text)', 'public.admin_business_save(uuid, jsonb)',
    'public.admin_business_wallet_adjust(uuid, numeric, text)', 'public.admin_business_invoice_paid(uuid, text)',
    'public.admin_business_issue_invoices()'] loop
    perform pg_temp.check(has_function_privilege('authenticated', f, 'execute'), f || ' for the apps');
    perform pg_temp.check(not has_function_privilege('anon', f, 'execute'), f || ' not for anon');
  end loop;
  foreach f in array array[
    'public.business_check(uuid, uuid, text, numeric, timestamptz, text, text, boolean, text, uuid)',
    'public.business_settle_ride(uuid)', 'public.business_invoices_tick()', 'public.business_settings_for(uuid)',
    'public.business_open_invoice(uuid, text, timestamptz)'] loop
    perform pg_temp.check(not has_function_privilege('authenticated', f, 'execute'), f || ' is the server''s');
  end loop;
end $$;

rollback;
