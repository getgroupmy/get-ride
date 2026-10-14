-- ============================================================================
-- Regression test for migration 0194: deleting your own account, an admin
-- linking it to the new one, and the final deletion.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/account_deletion.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id, phone, phone_confirmed_at) values
  ('00000000-0000-0000-0000-0000000194a1', '60100000194', now()),  -- rider who deletes
  ('00000000-0000-0000-0000-0000000194a2', '60100000195', now()),  -- rider mid-ride
  ('00000000-0000-0000-0000-0000000194a3', null, null),            -- the rider's new account
  ('00000000-0000-0000-0000-0000000194b1', '60110000194', now()),  -- driver who deletes
  ('00000000-0000-0000-0000-0000000194c1', null, null),            -- users admin
  ('00000000-0000-0000-0000-0000000194c2', null, null)             -- support admin, read only
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000194%'
on conflict do nothing;
update public.profiles set phone = '+' || u.phone, name = 'Person ' || right(u.id::text, 2),
       ic = '900101-14-0194', referral_code = 'REF' || right(u.id::text, 2)
  from auth.users u
 where u.id = profiles.id and u.id::text like '00000000-0000-0000-0000-0000000194%';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000194c1', 'admin-user-edit', 'edit'),
  ('00000000-0000-0000-0000-0000000194c2', 'admin-users', 'read')
on conflict do nothing;
insert into public.partners (auth_user_id, name, phone, ic, status) values
  ('00000000-0000-0000-0000-0000000194b1', 'Badrul', '+60110000194', '880202-10-0194', 'approved');
insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note) values
  ('00000000-0000-0000-0000-0000000194a1', 'get_wallet', 'topup', 30, 'test', 'test'),
  ('00000000-0000-0000-0000-0000000194b1', 'get_credit', 'commission', -12.5, 'test', 'test');
insert into public.saved_places (user_id, kind, name, address, lat, lng) values
  ('00000000-0000-0000-0000-0000000194a1', 'home', 'Home', 'Jalan 1', 3.1, 101.6),
  ('00000000-0000-0000-0000-0000000194a1', 'work', 'Office', 'Jalan 2', 3.1, 101.6),
  ('00000000-0000-0000-0000-0000000194a3', 'home', 'New home', 'Jalan 3', 3.1, 101.6);
insert into public.emergency_contacts (profile_id, name, phone) values
  ('00000000-0000-0000-0000-0000000194a1', 'Mum', '+60120000194');
insert into public.push_tokens (profile_id, token) values
  ('00000000-0000-0000-0000-0000000194a1', 'token-0194-a1');

create or replace function pg_temp.as_user(p uuid, p_amr jsonb default '[]') returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p, 'role', 'authenticated', 'amr', p_amr)::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
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
create or replace function pg_temp.balance(p uuid, t text) returns numeric language sql as $$
  select coalesce((select balance from public.wallets where user_id = p and wallet_type = t), 0);
$$;
grant execute on function pg_temp.as_user(uuid, jsonb), pg_temp.check(boolean, text),
  pg_temp.refused(text, text), pg_temp.balance(uuid, text) to authenticated;

-- PINs for the two who delete.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000194a1');
select public.set_login_pin('246810', null);
select pg_temp.as_user('00000000-0000-0000-0000-0000000194b1');
select public.set_login_pin('135790', null);
reset role;

-- A ride the deleting rider already took, with the driver; one still open.
insert into public.ride_requests (rider_id, partner_id, status, rider_name, rider_phone, partner_name, partner_phone,
                                  pickup_lat, pickup_lng, drop_lat, drop_lng)
values ('00000000-0000-0000-0000-0000000194a1', '00000000-0000-0000-0000-0000000194b1', 'completed',
        'Person a1', '+60100000194', 'Badrul', '+60110000194', 3.15, 101.71, 3.14, 101.69),
       ('00000000-0000-0000-0000-0000000194a1', null, 'open', 'Person a1', '+60100000194', null, null,
        3.15, 101.71, 3.14, 101.69),
       ('00000000-0000-0000-0000-0000000194a2', null, 'accepted', 'Person a2', '+60100000195', null, null,
        3.15, 101.71, 3.14, 101.69);
insert into public.scheduled_rides (rider_id, pickup_at, status, request, fare, partner_id) values
  ('00000000-0000-0000-0000-0000000194a1', now() + interval '20 minutes', 'assigned', '{}', 20,
   '00000000-0000-0000-0000-0000000194b1');

-- 1. Confirmation and refusals ---------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000194a1');
select pg_temp.check(public.delete_my_account() ->> 'error' = 'confirm_needed', 'no PIN and no fresh SMS code');
select pg_temp.as_user('00000000-0000-0000-0000-0000000194a1',
  jsonb_build_array(jsonb_build_object('method', 'otp', 'timestamp', extract(epoch from now())::bigint - 3600)));
select pg_temp.check(public.delete_my_account() ->> 'error' = 'confirm_needed', 'an SMS sign-in an hour ago is not enough');
select pg_temp.as_user('00000000-0000-0000-0000-0000000194a1');
select pg_temp.check(public.delete_my_account('111111') ->> 'error' = 'wrong_pin', 'a wrong PIN');
reset role;
select pg_temp.check((select pin_failed_attempts from public.profiles
                       where id = '00000000-0000-0000-0000-0000000194a1') = 1, 'the wrong PIN still counts');
select pg_temp.check((select deleted_at from public.profiles
                       where id = '00000000-0000-0000-0000-0000000194a1') is null, 'nothing deleted yet');

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000194a2',
  jsonb_build_array(jsonb_build_object('method', 'otp', 'timestamp', extract(epoch from now())::bigint - 30)));
select pg_temp.check((public.my_account_deletion_check() ->> 'activeRide')::boolean, 'the check sees the ride');
select pg_temp.check(public.delete_my_account() ->> 'error' = 'active_ride', 'not during a ride');

-- 2. Deleting with the PIN -------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000194a1');
select pg_temp.check((public.my_account_deletion_check() ->> 'bookings')::int = 1, 'one booking to cancel');
select pg_temp.check((public.delete_my_account('246810', 'Moving away') ->> 'ok')::boolean, 'deleted with the PIN');
select pg_temp.check(public.delete_my_account('246810') ->> 'error' = 'already_deleted', 'only once');
reset role;

select pg_temp.check((select deleted_at is not null and deleted_phone = '+60100000194' and phone is null
                             and profile_status = 'Deleted' and deletion_reason = 'Moving away'
                        from public.profiles where id = '00000000-0000-0000-0000-0000000194a1'),
  'the profile is marked, its number kept aside');
select pg_temp.check((select phone is null and banned_until > now() + interval '50 years'
                        from auth.users where id = '00000000-0000-0000-0000-0000000194a1'),
  'the login gives up its number and is banned');
select pg_temp.check(not exists (select 1 from public.ride_requests
                                  where rider_id = '00000000-0000-0000-0000-0000000194a1' and status = 'open'),
  'the open request is cancelled');
select pg_temp.check((select status = 'cancelled' and cancel_fee = 0 and cancel_fee_status = 'none'
                             and cancelled_by = 'system'
                        from public.scheduled_rides where rider_id = '00000000-0000-0000-0000-0000000194a1'),
  'the booking is cancelled with no fee, even inside the late window');
select pg_temp.check(exists (select 1 from public.notification_outbox
                              where profile_id = '00000000-0000-0000-0000-0000000194b1'
                                and title = 'Scheduled ride cancelled'), 'the driver is told');
select pg_temp.check(not exists (select 1 from public.push_tokens
                                  where profile_id = '00000000-0000-0000-0000-0000000194a1'), 'no more pushes');
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000194a1', 'get_wallet') = 30, 'the balance is kept');
select pg_temp.check(exists (select 1 from public.account_events
                              where profile_id = '00000000-0000-0000-0000-0000000194a1' and kind = 'deleted'),
  'the deletion is recorded');

-- Frozen: nothing moves the balance.
select pg_temp.refused($q$insert into public.wallet_transactions (user_id, wallet_type, kind, amount)
  values ('00000000-0000-0000-0000-0000000194a1', 'get_wallet', 'topup', 5)$q$, 'topping up a deleted account');

-- The number is free: the lookup no longer finds an account.
select pg_temp.check(not (select has_profile from public.profile_phone_lookup('+60100000194')),
  'the number reads as new');
-- And a leftover token is refused.
select pg_temp.as_user('00000000-0000-0000-0000-0000000194a1');
select pg_temp.refused($q$select public.request_guard()$q$, 'a deleted account''s token');
select set_config('request.jwt.claims', '', true);

-- 3. A driver deletes with an SMS code just verified -----------------------------------------
-- Their assigned booking goes back to be matched.
update public.scheduled_rides set status = 'assigned', partner_id = '00000000-0000-0000-0000-0000000194b1',
       rider_id = '00000000-0000-0000-0000-0000000194a2'
 where rider_id = '00000000-0000-0000-0000-0000000194a1';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000194b1',
  jsonb_build_array(jsonb_build_object('method', 'otp', 'timestamp', extract(epoch from now())::bigint - 60)));
select pg_temp.check((public.delete_my_account() ->> 'ok')::boolean, 'deleted with a fresh SMS code');
reset role;
select pg_temp.check((select status = 'scheduled' and partner_id is null from public.scheduled_rides
                        where rider_id = '00000000-0000-0000-0000-0000000194a2'), 'the booking is re-matched');
select pg_temp.check((select status = 'blocked' from public.partners
                        where auth_user_id = '00000000-0000-0000-0000-0000000194b1'), 'the partner stops driving');
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000194b1', 'get_credit') = -12.5, 'the debt stays');

-- 4. Linking ----------------------------------------------------------------------------------
-- The rider came back with the same number as a new account.
update public.profiles set phone = '+60100000194' where id = '00000000-0000-0000-0000-0000000194a3';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000194c2');
select pg_temp.refused($q$select public.admin_link_account('00000000-0000-0000-0000-0000000194a1',
  '00000000-0000-0000-0000-0000000194a3', array['trips'])$q$, 'a read-only admin linking');
select pg_temp.as_user('00000000-0000-0000-0000-0000000194c1');
select pg_temp.refused($q$select public.admin_link_account('00000000-0000-0000-0000-0000000194a3',
  '00000000-0000-0000-0000-0000000194a1', array['trips'])$q$, 'linking the wrong way round');
select pg_temp.refused($q$select public.admin_link_account('00000000-0000-0000-0000-0000000194a1',
  '00000000-0000-0000-0000-0000000194a3', array['photos'])$q$, 'an unknown category');
select pg_temp.check((public.admin_link_account('00000000-0000-0000-0000-0000000194a1',
  '00000000-0000-0000-0000-0000000194a3', array['trips', 'wallet', 'places', 'referral']) ->> 'ridesAsPassenger')::int = 2,
  'two rides move');
select pg_temp.refused($q$select public.admin_link_account('00000000-0000-0000-0000-0000000194a1',
  '00000000-0000-0000-0000-0000000194a3', array['wallet'])$q$, 'moving the wallet twice');
reset role;
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000194a3', 'get_wallet') = 30
                     and pg_temp.balance('00000000-0000-0000-0000-0000000194a1', 'get_wallet') = 0,
  'the balance moved through the ledger');
select pg_temp.check((select count(*) from public.wallet_transactions where kind = 'account_link'
                        and user_id in ('00000000-0000-0000-0000-0000000194a1', '00000000-0000-0000-0000-0000000194a3')) = 2,
  'both histories show the move');
select pg_temp.check((select string_agg(name, ',' order by name) from public.saved_places
                        where user_id = '00000000-0000-0000-0000-0000000194a3') = 'New home,Office',
  'saved places moved, the new Home kept');
select pg_temp.check((select referral_code from public.profiles where id = '00000000-0000-0000-0000-0000000194a3') = 'REFa1',
  'the referral code moved');
select pg_temp.check((select categories @> array['trips', 'wallet'] and actor_id = '00000000-0000-0000-0000-0000000194c1'
                        from public.account_events where profile_id = '00000000-0000-0000-0000-0000000194a1'
                         and kind = 'linked'), 'the link is recorded with who did it');

-- The driver's partner profile goes back for review.
update public.profiles set phone = '+60110000194' where id = '00000000-0000-0000-0000-0000000194a2';
select public.admin_link_account('00000000-0000-0000-0000-0000000194b1', '00000000-0000-0000-0000-0000000194a2',
  array['partner', 'wallet']);
select pg_temp.check((select status = 'unapproved' and phone = '+60110000194' from public.partners
                        where auth_user_id = '00000000-0000-0000-0000-0000000194a2'), 'the partner is under review');
select pg_temp.check(pg_temp.balance('00000000-0000-0000-0000-0000000194a2', 'get_credit') = -12.5,
  'the debt follows');

-- 5. Final deletion ---------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000194c1');
select pg_temp.refused($q$select public.admin_final_delete_account('00000000-0000-0000-0000-0000000194a1')$q$,
  'final deletion before the retention days');
select pg_temp.check(not exists (select 1 from public.accounts_due_final_deletion()), 'nothing is due yet');
reset role;
update public.profiles set deleted_at = now() - interval '400 days' where id = '00000000-0000-0000-0000-0000000194a1';
select pg_temp.check(public.account_deletion_remind() = 1, 'the users admin is reminded');
select pg_temp.check(public.account_deletion_remind() = 1
                     and (select count(*) from public.notification_outbox
                           where profile_id = '00000000-0000-0000-0000-0000000194c1'
                             and title = 'Accounts due for final deletion') = 1, 'once a week');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000194c2');
select pg_temp.check(not exists (select 1 from public.accounts_due_final_deletion()), 'not shown to a read-only admin');
select pg_temp.refused($q$select public.admin_final_delete_account('00000000-0000-0000-0000-0000000194a1')$q$,
  'a read-only admin approving');
select pg_temp.as_user('00000000-0000-0000-0000-0000000194c1');
select pg_temp.check((select count(*) from public.accounts_due_final_deletion()) = 1, 'one account due');
select pg_temp.check(jsonb_array_length(public.admin_final_delete_account('00000000-0000-0000-0000-0000000194a1')
                       -> 'folders') = 3, 'the folders to empty');
select pg_temp.check(jsonb_array_length(public.admin_final_delete_account('00000000-0000-0000-0000-0000000194a1')
                       -> 'folders') = 3, 'safe to run again');
reset role;
select pg_temp.check((select name = 'Deleted user' and ic is null and pin_hash is null and deleted_phone is null
                             and final_deleted_at is not null
                        from public.profiles where id = '00000000-0000-0000-0000-0000000194a1'), 'personal data wiped');
select pg_temp.check(not exists (select 1 from public.emergency_contacts
                                  where profile_id = '00000000-0000-0000-0000-0000000194a1'), 'contacts removed');
select pg_temp.check(exists (select 1 from public.wallet_transactions
                              where user_id = '00000000-0000-0000-0000-0000000194a1'), 'the ledger stays');
select pg_temp.check((select count(*) from public.account_events
                       where profile_id = '00000000-0000-0000-0000-0000000194a1' and kind = 'final_deleted') = 1,
  'recorded once');

-- 6. Settings ---------------------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000194c2');
select pg_temp.refused($q$select public.set_account_deletion_config('{"retentionDays":90}')$q$,
  'a read-only admin changing retention');
select pg_temp.as_user('00000000-0000-0000-0000-0000000194c1');
select pg_temp.refused($q$select public.set_account_deletion_config('{"retentionDays":5}')$q$, 'too short');
select pg_temp.check((public.set_account_deletion_config('{"retentionDays":90}') ->> 'retentionDays')::int = 90,
  'retention saved');
reset role;

rollback;
