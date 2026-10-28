-- ============================================================================
-- Regression test for migration 0317: Family, the shared layer every booking
-- module uses.
--   0. who may call what;
--   1. the module registry (an unknown module is off; registering again is
--      harmless) and the values and switches by place;
--   2. an invite: nothing is shared or paid before the member joins;
--   3. who pays: a member's own ride with Family, the per-trip and monthly
--      limits, the host's GET.wallet charged through the payment layer for
--      the fare and a cancel fee, over the limit the member's own wallet,
--      the member paying themselves, City to City's fee, a scheduled ride's
--      release;
--   4. location: only the disclosed ways (a shared trip under way, "always"
--      only once the admin allows, the host asks and the member accepts and
--      turns it on), less at once, leaving stops it;
--   5. a child: too young alone, women drivers, the pickup code with tries,
--      the lock and a new code, the start held for the code, the host told;
--   6. the member cap, a request and the admin's decision;
--   7. God View: a reason, the log, the member's log;
--   8. the host booking for a member.
-- All names and numbers are made up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/family_core_0317.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- ---- 0. Grants -----------------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'public.family_payer_for(text, uuid, uuid, numeric, jsonb, jsonb)', 'public.family_mine(jsonb)',
    'public.family_invite(jsonb, text, text, text, numeric, numeric, text[], text)',
    'public.family_add_child(jsonb, text, date, text, text, text[])', 'public.family_update_member(uuid, jsonb)',
    'public.family_remove_member(uuid)', 'public.family_respond(uuid, boolean, jsonb)', 'public.family_leave()',
    'public.family_member_consent(boolean, boolean)', 'public.family_pay_option(text, jsonb, numeric)',
    'public.family_passengers(text, jsonb)', 'public.family_trip_status(uuid)', 'public.family_live()',
    'public.family_child_code(uuid)', 'public.family_child_code_new(uuid)', 'public.family_driver_child(uuid)',
    'public.family_verify_pickup_code(uuid, text)', 'public.family_my_view_log()',
    'public.family_admin_view(uuid, text, text)', 'public.family_admin_list(text, integer, integer)'] loop
    if not has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute') then
      raise exception 'FAILED: % is for signed-in callers only', f;
    end if;
  end loop;
  foreach f in array array[
    'public.family_attach_trip(text, uuid, uuid, uuid, numeric, jsonb, jsonb, boolean)',
    'public.family_charge(uuid, numeric, text, uuid)', 'public.family_wallet_owner(uuid, uuid, numeric)',
    'public.family_can_view_location(uuid, uuid)', 'public.family_register_module(text, text, text)',
    'public.ride_fee_take(public.ride_requests, numeric, text)', 'public.family_release_trip(uuid)'] loop
    if has_function_privilege('authenticated', f, 'execute') or has_function_privilege('anon', f, 'execute') then
      raise exception 'FAILED: % is the server''s own', f;
    end if;
  end loop;
  if has_table_privilege('authenticated', 'public.family_members', 'select')
     or has_table_privilege('authenticated', 'public.family_trips', 'select') then
    raise exception 'FAILED: family rows are read through the functions only';
  end if;
end
$$;

-- ---- People -------------------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.permit_country_settings') is not null then
    execute 'update public.permit_country_settings set enforce = false';
  end if;
end
$$;
insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000317a1'),  -- host
  ('00000000-0000-0000-0000-0000000317a2'),  -- member
  ('00000000-0000-0000-0000-0000000317a3'),  -- invited later
  ('00000000-0000-0000-0000-0000000317a4'),  -- somebody else
  ('00000000-0000-0000-0000-0000000317b1'),  -- driver, a woman
  ('00000000-0000-0000-0000-0000000317b2'),  -- driver, a man
  ('00000000-0000-0000-0000-0000000317c1'),  -- admin of the Family page
  ('00000000-0000-0000-0000-0000000317c2')   -- full admin
on conflict do nothing;
insert into public.profiles (id, name, phone, gender) values
  ('00000000-0000-0000-0000-0000000317a1', 'Karpal Contoh', '+60100317001', null),
  ('00000000-0000-0000-0000-0000000317a2', 'Aisha Contoh', '+60100317002', null),
  ('00000000-0000-0000-0000-0000000317a3', 'Raj Contoh', '+60100317003', null),
  ('00000000-0000-0000-0000-0000000317a4', 'Other Person', '+60100317004', null),
  ('00000000-0000-0000-0000-0000000317b1', 'Siti Sample', '+60100317011', 'female'),
  ('00000000-0000-0000-0000-0000000317b2', 'Ahmad Sample', '+60100317012', 'male'),
  ('00000000-0000-0000-0000-0000000317c1', 'Test Admin', '+60100317021', null),
  ('00000000-0000-0000-0000-0000000317c2', 'Test Full Admin', '+60100317022', null)
on conflict (id) do update set name = excluded.name, phone = excluded.phone, gender = excluded.gender;
insert into public.partners (id, auth_user_id, name, phone, status, partner_types, service_countries) values
  ('00000000-0000-0000-0000-0000000317e1', '00000000-0000-0000-0000-0000000317b1', 'Siti Sample', '+60100317011',
   'approved', '{eHailing}', '{Malaysia}'),
  ('00000000-0000-0000-0000-0000000317e2', '00000000-0000-0000-0000-0000000317b2', 'Ahmad Sample', '+60100317012',
   'approved', '{eHailing}', '{Malaysia}');
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000317c1', 'admin-settings-family', 'edit'),
  ('00000000-0000-0000-0000-0000000317c2', '*', 'edit');

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
create or replace function pg_temp.wallet(p uuid) returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p and wallet_type = 'get_wallet'), 0);
$$;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text, text),
  pg_temp.wallet(uuid) to authenticated;
create temporary table t_ids (k text primary key, id uuid);
grant all on t_ids to authenticated;

-- ---- 1. The registry and the values by place ----------------------------------------------------
select pg_temp.check(public.family_module_rule_at('no_such_module', '{}')
  = '{"familyPays": false, "bookForMember": false, "childAllowed": false, "liveShare": false}'::jsonb,
  'a module not in the registry is all off');
select pg_temp.check(not (public.family_module_rule_at('seat_trip', '{}')->>'familyPays')::boolean,
  'a registered module with no rule is off until the admin turns it on');
select public.family_register_module('ride', 'Something else');
select pg_temp.check((select name = 'Ride' from public.booking_modules where key = 'ride'),
  'registering a key again changes nothing');
select pg_temp.check((public.family_module_rule_at('ride', '{"country": "Malaysia"}')->>'familyPays')::boolean
  and not (public.family_module_rule_at('freight', '{}')->>'familyPays')::boolean
  and not (public.family_module_rule_at('city_to_city', '{}')->>'childAllowed')::boolean,
  'the approved matrix for today''s modules');
select pg_temp.check((select count(*) from jsonb_array_elements(public.family_modules_at('{}')))
                     = (select count(*) from public.booking_modules), 'the matrix lists every registered module');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a4');
select pg_temp.refused($q$insert into public.family_module_rules (level, country, module_key, family_pays)
                          values ('country', 'Testland', 'ride', false)$q$, 'row-level security',
  'someone who is not an admin changing a module rule');
select pg_temp.as_user('00000000-0000-0000-0000-0000000317c1');
insert into public.family_module_rules (level, country, module_key, family_pays) values ('country', 'Testland', 'ride', false);
insert into public.family_places (level, country, rules) values ('country', 'Testland', '{"maxMembers": 2, "aloneAge": 10}');
reset role;
select pg_temp.check(not (public.family_module_rule_at('ride', '{"country": "Testland", "city": "X"}')->>'familyPays')::boolean
  and (public.family_module_rule_at('ride', '{"country": "Testland", "city": "X"}')->>'bookForMember')::boolean,
  'a place''s switch overrides only what it sets');
select pg_temp.check((public.family_settings_at('{"country": "Testland"}')->>'maxMembers')::int = 2
  and (public.family_settings_at('{"country": "Testland"}')->>'codeTries')::int = 3
  and (public.family_settings_at('{"country": "Malaysia"}')->>'maxMembers')::int = 6,
  'a place''s values over Default, key by key');
select pg_temp.refused($q$insert into public.family_places (level, country, rules) values ('country', 'Badland', '{"maxMembers": 0}')$q$,
  'family_places_valid', 'a member cap of 0');

-- ---- 2. An invite: nothing before the member joins ---------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a1');
insert into t_ids select 'm1', (public.family_invite('{"country": "Malaysia", "state": "Kuala Lumpur"}', '0100317002',
  'Aisha', 'daughter', 50, 20, null, 'ride')->>'id')::uuid;
select pg_temp.refused($q$select public.family_invite('{}', '+60 10-031 7002', 'Aisha')$q$, 'FAMILY_ALREADY_INVITED',
  'the same number twice');
select pg_temp.refused($q$select public.family_invite('{}', '+60100317003', 'Raj', null, 5000)$q$, 'FAMILY_MONTH_CAP',
  'a monthly limit above the region''s highest');
select pg_temp.refused($q$select public.family_invite('{}', '+60100317003', 'Raj', null, null, 30)$q$,
  'FAMILY_PER_RIDE_CHOICE', 'a per-trip limit not offered');
select pg_temp.refused($q$select public.family_invite('{}', '+60100317003', 'Raj', null, null, null, null, 'always')$q$,
  'FAMILY_LOCATION_NOT_ALLOWED', 'more location than the admin allows');
select pg_temp.refused($q$select public.family_invite('{}', '+60100317001', 'Me')$q$, 'FAMILY_CANT_INVITE',
  'inviting yourself');
select pg_temp.check((public.family_mine('{}')->>'role') = 'host'
  and jsonb_array_length(public.family_mine('{}')->'members') = 1, 'the host sees the invite');
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a4');
select pg_temp.check(jsonb_array_length(public.family_my_invites()) = 0, 'somebody else sees no invite');
select pg_temp.refused(format('select public.family_respond(%L, true)', (select id from t_ids where k = 'm1')),
  'FAMILY_INVITE_GONE', 'somebody else joining with the invite');
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a2');
select pg_temp.check(jsonb_array_length(public.family_my_invites()) = 1
  and (public.family_my_invites()->0->>'hostName') = 'Karpal Contoh'
  and (public.family_my_invites()->0->'modules') ? 'Ride', 'the invited member reads the invite and what it covers');
select pg_temp.check((public.family_payer_for('ride', '00000000-0000-0000-0000-0000000317a2', null, 10)->>'code')
  = 'FAMILY_NOT_MEMBER', 'no family payment before joining');
reset role;
select pg_temp.check(not public.family_can_view_location('00000000-0000-0000-0000-0000000317a1',
  '00000000-0000-0000-0000-0000000317a2'), 'no location before joining');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a2');
select public.family_respond((select id from t_ids where k = 'm1'), true, '{"shown": ["payments", "location"]}');
select pg_temp.check((public.family_mine('{}')->>'role') = 'member'
  and (public.family_mine('{}')->'me'->>'left')::numeric = 50, 'joined: a member with RM 50 a month');

-- ---- 3. Who pays ---------------------------------------------------------------------------------
select pg_temp.check((public.family_payer_for('ride', '00000000-0000-0000-0000-0000000317a2', null, 10,
                        '{"country": "Malaysia"}')->>'payer') = '00000000-0000-0000-0000-0000000317a1',
  'the host pays the member''s ride');
select pg_temp.check((public.family_payer_for('freight', '00000000-0000-0000-0000-0000000317a2', null, 10)->>'code')
  = 'FAMILY_MODULE_OFF', 'Freight is off for families');
select pg_temp.check((public.family_payer_for('seat_trip', '00000000-0000-0000-0000-0000000317a2', null, 10)->>'code')
  = 'FAMILY_MODULE_OFF', 'a module being built is off until the admin turns it on');
select pg_temp.check((public.family_payer_for('ride', '00000000-0000-0000-0000-0000000317a2', null, 25)->>'code')
  = 'FAMILY_RIDE_LIMIT', 'over the per-trip limit');
select pg_temp.check((public.family_pay_option('ride', '{}', 10)->>'available')::boolean
  and (public.family_pay_option('ride', '{}', 10)->>'hostName') = 'Karpal Contoh', 'the booking screen''s Family row');
reset role;

insert into t_ids select 'f', id from public.families where host_id = '00000000-0000-0000-0000-0000000317a1';
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
values ('00000000-0000-0000-0000-0000000317a1', 'get_wallet', 'topup', 100, 'test', 'test');

-- A ride the member books with Family.
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, payment_mode, country)
values ('00000000-0000-0000-0000-0000000317d1', '00000000-0000-0000-0000-0000000317a2', 'open', 3.1, 101.6, 15, 15,
        'Family', 'Malaysia');
select pg_temp.check((select family_pays and payer_id = '00000000-0000-0000-0000-0000000317a1' and live_share
                        from public.family_trips where trip_id = '00000000-0000-0000-0000-0000000317d1'),
  'the ride is registered as family-paid');
select pg_temp.refused($q$insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare,
                            payment_mode, country)
                          values ('00000000-0000-0000-0000-0000000317d2', '00000000-0000-0000-0000-0000000317a2', 'open',
                                  3.1, 101.6, 25, 25, 'Family', 'Malaysia')$q$, 'FAMILY_RIDE_LIMIT',
  'a ride over the per-trip limit');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000317b1', status = 'accepted'
 where id = '00000000-0000-0000-0000-0000000317d1';
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-0000000317d1';
select pg_temp.check(public.family_can_view_location('00000000-0000-0000-0000-0000000317a1',
  '00000000-0000-0000-0000-0000000317a2'), 'the host follows the shared ride under way');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a2');
select pg_temp.check((public.family_trip_status('00000000-0000-0000-0000-0000000317d1')->>'shared')::boolean
  and jsonb_array_length(public.family_trip_status('00000000-0000-0000-0000-0000000317d1')->'viewers') = 1,
  'the member''s chip shows, with who can see');
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a4');
select pg_temp.check(not (public.family_trip_status('00000000-0000-0000-0000-0000000317d1')->>'family')::boolean,
  'somebody else learns nothing of the trip');
reset role;
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000317d1';
select pg_temp.check(not public.family_can_view_location('00000000-0000-0000-0000-0000000317a1',
  '00000000-0000-0000-0000-0000000317a2'), 'the trip over, nothing is shared');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a2');
select public.ride_pay('00000000-0000-0000-0000-0000000317d1', 'family');
reset role;
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000317a1') = 85, 'the fare from the host''s wallet: '
  || pg_temp.wallet('00000000-0000-0000-0000-0000000317a1'));
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000317a2') = 0, 'nothing from the member''s');
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000317b1') = 15, 'the driver is paid');
select pg_temp.check((select sum(amount) from public.family_spend
                       where trip_id = '00000000-0000-0000-0000-0000000317d1') = 15, 'counted on the member''s limit');

-- A cancel fee on a family-paid trip goes the same way (the payment layer, no code of its own).
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, payment_mode, country)
values ('00000000-0000-0000-0000-0000000317d3', '00000000-0000-0000-0000-0000000317a2', 'open', 3.1, 101.6, 10, 10,
        'Family', 'Malaysia');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000317b1', status = 'accepted'
 where id = '00000000-0000-0000-0000-0000000317d3';
update public.ride_requests set commission_rate = 0.2 where id = '00000000-0000-0000-0000-0000000317d3';
select pg_temp.check(public.ride_fee_take(r, 3, 'late_cancel') = 'charged', 'the late fee is charged')
  from public.ride_requests r where id = '00000000-0000-0000-0000-0000000317d3';
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000317d3';
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000317a1') = 82, 'the fee from the host''s wallet: '
  || pg_temp.wallet('00000000-0000-0000-0000-0000000317a1'));
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000317b1') = 17.40, 'the driver gets it less commission');
select pg_temp.check((select note like 'Family · Aisha%' from public.wallet_transactions
                       where ride_id = '00000000-0000-0000-0000-0000000317d3'
                         and user_id = '00000000-0000-0000-0000-0000000317a1'), 'the host''s statement names the member');

-- The host lowers the monthly limit: RM 2 left.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a1');
select public.family_update_member((select id from t_ids where k = 'm1'), '{"monthlyLimit": 20}');
reset role;
select pg_temp.refused($q$insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare,
                            payment_mode, country)
                          values ('00000000-0000-0000-0000-0000000317d4', '00000000-0000-0000-0000-0000000317a2', 'open',
                                  3.1, 101.6, 10, 10, 'Family', 'Malaysia')$q$, 'FAMILY_LIMIT_REACHED',
  'a ride over what is left this month');
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, payment_mode, country)
values ('00000000-0000-0000-0000-0000000317d5', '00000000-0000-0000-0000-0000000317a2', 'open', 3.1, 101.6, 2, 2,
        'Family', 'Malaysia');
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
values ('00000000-0000-0000-0000-0000000317a2', 'get_wallet', 'topup', 10, 'test', 'test');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000317b1', status = 'accepted'
 where id = '00000000-0000-0000-0000-0000000317d5';
update public.ride_requests set commission_rate = 0.2 where id = '00000000-0000-0000-0000-0000000317d5';
select pg_temp.check(public.ride_fee_take(r, 5, 'late_cancel') = 'charged', 'the fee over the limit is charged')
  from public.ride_requests r where id = '00000000-0000-0000-0000-0000000317d5';
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000317a1') = 82
  and pg_temp.wallet('00000000-0000-0000-0000-0000000317a2') = 5,
  'over the limit, the member''s own wallet pays');
-- The member pays the trip themselves: nothing more goes to the host.
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-0000000317d5';
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000317d5';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a2');
select public.ride_pay('00000000-0000-0000-0000-0000000317d5', 'get_wallet');
reset role;
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000317a2') = 3
  and pg_temp.wallet('00000000-0000-0000-0000-0000000317a1') = 82
  and (select released_at is not null from public.family_trips where trip_id = '00000000-0000-0000-0000-0000000317d5'),
  'paid with their own GET.wallet, the trip is theirs');

-- City to City's cancel fee (0307), the same layer.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a1');
select public.family_update_member((select id from t_ids where k = 'm1'), '{"monthlyLimit": 50}');
reset role;
select public.family_attach_trip('city_to_city', '00000000-0000-0000-0000-0000000317f1',
  '00000000-0000-0000-0000-0000000317a2', null, 18, '{"country": "Malaysia"}', '{}', true);
select pg_temp.check(public.c2c_fee_take(jsonb_populate_record(null::public.c2c_bookings, jsonb_build_object(
  'id', '00000000-0000-0000-0000-0000000317f1', 'ref', 'CC-1', 'rider_id', '00000000-0000-0000-0000-0000000317a2',
  'driver_id', '00000000-0000-0000-0000-0000000317b1', 'commission_rate', 0)), 4) = 'charged', 'the City to City fee');
select pg_temp.check(pg_temp.wallet('00000000-0000-0000-0000-0000000317a1') = 78, 'from the host''s wallet: '
  || pg_temp.wallet('00000000-0000-0000-0000-0000000317a1'));

-- A scheduled booking made with Family carries on to its ride at release.
select public.family_attach_trip('scheduled_ride', '00000000-0000-0000-0000-0000000317f2',
  '00000000-0000-0000-0000-0000000317a2', null, 5, '{"country": "Malaysia"}', '{}', true);
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, payment_mode,
                                  scheduled_ride_id)
values ('00000000-0000-0000-0000-0000000317d6', '00000000-0000-0000-0000-0000000317a2', 'open', 3.1, 101.6, 5, 5,
        'Family', '00000000-0000-0000-0000-0000000317f2');
select pg_temp.check((select family_pays and module_key = 'scheduled_ride' from public.family_trips
                       where trip_id = '00000000-0000-0000-0000-0000000317d6'), 'the released ride is family-paid');
update public.ride_requests set status = 'cancelled' where id = '00000000-0000-0000-0000-0000000317d6';

-- ---- 4. Location: the disclosed ways only -------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a1');
select pg_temp.refused(format('select public.family_update_member(%L, %L)', (select id from t_ids where k = 'm1'),
  '{"location": "always"}'), 'FAMILY_LOCATION_NOT_ALLOWED', '"always" while the admin allows "while on a ride"');
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a4');
update public.family_places set rules = rules || '{"locationRule": "always"}' where level = 'default';
reset role;
select pg_temp.check((public.family_settings_at('{}')->>'locationRule') = 'ride', 'only the admin changes the rule');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317c1');
update public.family_places set rules = rules || '{"locationRule": "always"}' where level = 'default';
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a1');
select pg_temp.check((public.family_update_member((select id from t_ids where k = 'm1'), '{"location": "always"}')
                      ->>'locationPending') = 'always', 'the host''s raise waits for the member');
reset role;
select pg_temp.check(public.family_location_rule((select id from t_ids where k = 'm1')) = 'ride'
  and not public.family_can_view_location('00000000-0000-0000-0000-0000000317a1', '00000000-0000-0000-0000-0000000317a2'),
  'nothing more before the member accepts');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a2');
select public.family_member_consent(true, null);
reset role;
select pg_temp.check(not public.family_can_view_location('00000000-0000-0000-0000-0000000317a1',
  '00000000-0000-0000-0000-0000000317a2'), '"always" also needs the member''s own switch');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a2');
select public.family_member_consent(null, true);
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a1');
select pg_temp.check(jsonb_array_length(public.family_live()) = 1, 'the host''s Family viewer lists the member');
reset role;
select pg_temp.check(public.family_can_view_location('00000000-0000-0000-0000-0000000317a1',
  '00000000-0000-0000-0000-0000000317a2'), 'accepted and turned on: the host sees');
select pg_temp.check(not public.family_can_view_location('00000000-0000-0000-0000-0000000317a4',
  '00000000-0000-0000-0000-0000000317a2'), 'nobody else ever does');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a1');
select public.family_update_member((select id from t_ids where k = 'm1'), '{"location": "never"}');
reset role;
select pg_temp.check(not public.family_can_view_location('00000000-0000-0000-0000-0000000317a1',
  '00000000-0000-0000-0000-0000000317a2'), 'less applies at once');

-- ---- 5. A child ----------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a1');
insert into t_ids select 'c1', (public.family_add_child('{}', 'Iman Contoh', (current_date - interval '8 years 2 months')::date,
  null, 'son')->>'id')::uuid;
select pg_temp.check((select (x->>'allowed')::boolean and (x->>'needsAdult')::boolean
                        from jsonb_array_elements(public.family_passengers('ride', '{}')) x
                       where x->>'kind' = 'child'), 'a child of 8 can be booked with an adult');
select pg_temp.check((public.family_payer_for('city_to_city', '00000000-0000-0000-0000-0000000317a1',
  (select id from t_ids where k = 'c1'), 30)->>'code') = 'FAMILY_CHILD_NOT_ALLOWED', 'no children on City to City');
reset role;
select pg_temp.refused(format($q$insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare,
                                   ride_fare, family, booked_for_name)
                                 values ('00000000-0000-0000-0000-0000000317d7', '00000000-0000-0000-0000-0000000317a1',
                                         'open', 3.1, 101.6, 12, 12, %L, 'Iman')$q$,
                              jsonb_build_object('passenger', (select id from t_ids where k = 'c1'))),
  'FAMILY_CHILD_TOO_YOUNG', 'a child of 8 alone');
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, family, booked_for_name)
values ('00000000-0000-0000-0000-0000000317d7', '00000000-0000-0000-0000-0000000317a1', 'open', 3.1, 101.6, 12, 12,
        jsonb_build_object('passenger', (select id from t_ids where k = 'c1'), 'withAdult', true), 'Iman');
select pg_temp.check((select child and with_adult and not family_pays from public.family_trips
                       where trip_id = '00000000-0000-0000-0000-0000000317d7'), 'the child''s trip, the host pays');
select pg_temp.check(exists (select 1 from public.family_pickup_codes where trip_id = '00000000-0000-0000-0000-0000000317d7'),
  'with a pickup code');
select pg_temp.refused($q$update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000317b2', status = 'accepted'
                           where id = '00000000-0000-0000-0000-0000000317d7'$q$, 'FAMILY_WOMEN_DRIVERS_ONLY',
  'a man taking a child''s trip');
update public.ride_requests set partner_id = '00000000-0000-0000-0000-0000000317b1', status = 'accepted'
 where id = '00000000-0000-0000-0000-0000000317d7';
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where profile_id = '00000000-0000-0000-0000-0000000317a1'
                                and event_id = 'family:00000000-0000-0000-0000-0000000317d7:accepted'),
  'the host hears the driver is on the way');
select pg_temp.refused($q$update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-0000000317d7'$q$,
  'FAMILY_PICKUP_CODE_NEEDED', 'starting without the code');
create temporary table t_code as select code from public.family_pickup_codes
 where trip_id = '00000000-0000-0000-0000-0000000317d7';
grant select on t_code to authenticated;
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317b2');
select pg_temp.check(public.family_driver_child('00000000-0000-0000-0000-0000000317d7') is null,
  'another driver learns nothing of the child');
select pg_temp.refused($q$select public.family_verify_pickup_code('00000000-0000-0000-0000-0000000317d7', '1234')$q$,
  'not_authorized', 'another driver trying codes');
select pg_temp.as_user('00000000-0000-0000-0000-0000000317b1');
select pg_temp.check((public.family_driver_child('00000000-0000-0000-0000-0000000317d7')->>'name') = 'Iman Contoh'
  and (public.family_driver_child('00000000-0000-0000-0000-0000000317d7')->>'bookedBy') = 'Karpal Contoh',
  'the driver sees who the child is and who booked');
select pg_temp.check((public.family_verify_pickup_code('00000000-0000-0000-0000-0000000317d7',
  lpad(((select code::int from t_code) + 1) % 10000 || '', 4, '0'))->>'triesLeft')::int = 2, 'a wrong code: 2 tries left');
select public.family_verify_pickup_code('00000000-0000-0000-0000-0000000317d7',
  lpad(((select code::int from t_code) + 2) % 10000 || '', 4, '0'));
select pg_temp.check((public.family_verify_pickup_code('00000000-0000-0000-0000-0000000317d7',
  lpad(((select code::int from t_code) + 3) % 10000 || '', 4, '0'))->>'locked')::boolean, 'three wrong: locked');
select pg_temp.check(not (public.family_verify_pickup_code('00000000-0000-0000-0000-0000000317d7',
  (select code from t_code))->>'ok')::boolean, 'locked, even the right code waits');
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a1');
select pg_temp.check((public.family_child_code_new('00000000-0000-0000-0000-0000000317d7')->>'triesLeft')::int = 3,
  'the parent gives a new code');
reset role;
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where profile_id = '00000000-0000-0000-0000-0000000317a1'
                                and event_id like 'family:00000000-0000-0000-0000-0000000317d7:code-locked%'
                                and priority = 'critical'), 'the parent was called about the lock');
truncate t_code;
insert into t_code select code from public.family_pickup_codes where trip_id = '00000000-0000-0000-0000-0000000317d7';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317b1');
select pg_temp.check((public.family_verify_pickup_code('00000000-0000-0000-0000-0000000317d7',
  (select code from t_code))->>'ok')::boolean, 'the right code');
reset role;
update public.ride_requests set status = 'on_trip' where id = '00000000-0000-0000-0000-0000000317d7';
update public.ride_requests set status = 'completed' where id = '00000000-0000-0000-0000-0000000317d7';
select pg_temp.check((select count(*) from public.notification_outbox
                       where profile_id = '00000000-0000-0000-0000-0000000317a1'
                         and event_id in ('family:00000000-0000-0000-0000-0000000317d7:on_trip',
                                          'family:00000000-0000-0000-0000-0000000317d7:completed')) = 2,
  'the parent hears of pickup and drop-off');

-- ---- 6. The member cap ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a4');
select pg_temp.refused(format('select public.family_admin_set_cap(%L, 2)',
  (select id from t_ids where k = 'f')), 'not_authorized',
  'somebody else raising a cap');
select pg_temp.as_user('00000000-0000-0000-0000-0000000317c1');
select public.family_admin_set_cap((select id from t_ids where k = 'f'), 2);
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a1');
select pg_temp.refused($q$select public.family_invite('{}', '+60100317003', 'Raj')$q$, 'FAMILY_FULL', 'a third member over a cap of 2');
select public.family_request_cap(4, 'Grandparents too');
select pg_temp.as_user('00000000-0000-0000-0000-0000000317c1');
select pg_temp.check(jsonb_array_length(public.family_admin_requests('pending')) = 1, 'the admin sees the request');
select public.family_admin_decide((public.family_admin_requests('pending')->0->>'id')::uuid, true, null);
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a1');
select pg_temp.check((public.family_mine('{}')->'family'->>'cap')::int = 4, 'approved: room for 4');
select public.family_invite('{}', '+60100317003', 'Raj');

-- ---- 7. God View, logged -------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000317c1');
select pg_temp.refused(format('select public.family_admin_view(%L, %L, %L)',
  (select id from t_ids where k = 'f'), 'report',
  'Rider report about a trip'), 'not_authorized', 'an admin without God View looking');
select pg_temp.as_user('00000000-0000-0000-0000-0000000317c2');
select pg_temp.refused(format('select public.family_admin_view(%L, %L, %L)',
  (select id from t_ids where k = 'f'), 'report', 'short'),
  'FAMILY_REASON_NEEDED', 'a look without a reason');
select pg_temp.check(jsonb_array_length(public.family_admin_view(
  (select id from t_ids where k = 'f'), 'report',
  'Rider report about a late pickup')->'members') = 3, 'with a reason, the admin sees the family');
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a2');
select pg_temp.check(jsonb_array_length(public.family_my_view_log()) = 1
  and (public.family_my_view_log()->0->>'reason') = 'Rider report about a late pickup', 'the member reads their log');
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a4');
select pg_temp.check(jsonb_array_length(public.family_my_view_log()) = 0, 'nobody else does');
reset role;
select pg_temp.check(exists (select 1 from public.admin_audit_log where action = 'family.view'
                              and actor_id = '00000000-0000-0000-0000-0000000317c2'), 'and the audit log has it');

-- ---- 8. The host books for a member --------------------------------------------------------------
select pg_temp.refused(format($q$insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare,
                                   ride_fare, payment_mode, family)
                                 values ('00000000-0000-0000-0000-0000000317d8', '00000000-0000-0000-0000-0000000317a1',
                                         'open', 3.1, 101.6, 12, 12, 'Family', %L)$q$,
                              jsonb_build_object('passenger', (select id from t_ids where k = 'm1'))),
  'FAMILY_ONLY_FOR_MEMBER', 'Family payment on a trip the host books for someone');
insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare, family,
                                  booked_for_name, booked_for_phone, country)
values ('00000000-0000-0000-0000-0000000317d8', '00000000-0000-0000-0000-0000000317a1', 'open', 3.1, 101.6, 12, 12,
        jsonb_build_object('passenger', (select id from t_ids where k = 'm1')), 'Aisha', '+60100317002', 'Malaysia');
select pg_temp.check((select not family_pays and not child from public.family_trips
                       where trip_id = '00000000-0000-0000-0000-0000000317d8'), 'booked for the member, the host pays');
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where profile_id = '00000000-0000-0000-0000-0000000317a2'
                                and event_id = 'family:00000000-0000-0000-0000-0000000317d8:booked'),
  'and the member is told');
select pg_temp.refused($q$insert into public.ride_requests (id, rider_id, status, pickup_lat, pickup_lng, fare, ride_fare,
                            family, country)
                          values ('00000000-0000-0000-0000-0000000317d9', '00000000-0000-0000-0000-0000000317a4', 'open',
                                  3.1, 101.6, 12, 12, '{"passenger": "00000000-0000-0000-0000-0000000317a2"}', 'Malaysia')$q$,
  'FAMILY_NOT_MEMBER', 'booking someone who is not your family member');

-- ---- Leaving stops everything at once ------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000317a2');
select public.family_member_consent(null, true);
select public.family_leave();
select pg_temp.check((public.family_mine('{}')->>'role') = 'none', 'the member has left');
reset role;
select pg_temp.check(not public.family_can_view_location('00000000-0000-0000-0000-0000000317a1',
  '00000000-0000-0000-0000-0000000317a2'), 'nothing is shared after leaving');
select pg_temp.check((public.family_payer_for('ride', '00000000-0000-0000-0000-0000000317a2', null, 1)->>'code')
  = 'FAMILY_NOT_MEMBER', 'and the family pays nothing more');

rollback;
