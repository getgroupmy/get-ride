-- ============================================================================
-- Regression test for migration 0338: lawful-request export.
--
-- A full admin can export the data get.ride holds about one user and gets a
-- document with the subject's account (full id number), trips, payments
-- (+ balances) and location counts; the lawful_requests register row and the
-- admin_audit_log row are written; the agency / reference / legal basis are
-- required; a non-admin and a scoped sub-admin (God View edit, not a full
-- admin) are refused; an unknown subject is refused; the register is read
-- only through admin_lawful_requests().
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/lawful_export_0338.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- Grants: the two RPCs are authenticated-only (the body enforces full admin);
-- anon may not call them, and no role may read lawful_requests directly.
do $$
begin
  if has_function_privilege('anon', 'public.admin_lawful_export(uuid, text, text, text, text, text)', 'execute')
     or has_function_privilege('anon', 'public.admin_lawful_requests(integer)', 'execute')
     or not has_function_privilege('authenticated', 'public.admin_lawful_export(uuid, text, text, text, text, text)', 'execute')
     or not has_function_privilege('authenticated', 'public.admin_lawful_requests(integer)', 'execute') then
    raise exception 'FAILED: lawful export function grants';
  end if;
  if has_table_privilege('authenticated', 'public.lawful_requests', 'select')
     or has_table_privilege('anon', 'public.lawful_requests', 'select') then
    raise exception 'FAILED: lawful_requests is not client-readable';
  end if;
end
$$;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000338a1', '60133800001'),  -- full admin
  ('00000000-0000-0000-0000-0000000338a2', '60133800002'),  -- not an admin
  ('00000000-0000-0000-0000-0000000338a3', '60133800003'),  -- God View edit sub-admin
  ('00000000-0000-0000-0000-0000000338b1', '60133800011'),  -- the subject
  ('00000000-0000-0000-0000-0000000338b2', '60133800012')   -- the other party in a trip
on conflict do nothing;

insert into public.profiles (id, name, phone, email, ic, birth_date, nationality, address,
                             id_type, id_number_typed, display_id) values
  ('00000000-0000-0000-0000-0000000338a1', 'Admin Full', '60133800001', null, null, null, null, null, null, null, null),
  ('00000000-0000-0000-0000-0000000338a2', 'Rider Nobody', '60133800002', null, null, null, null, null, null, null, null),
  ('00000000-0000-0000-0000-0000000338a3', 'Sub Godview', '60133800003', null, null, null, null, null, null, null, null),
  ('00000000-0000-0000-0000-0000000338b1', 'Subject One', '60133800011', 'subject@example.com',
   '900101145678', '1990-01-01', 'Malaysia', '1 Jalan Test, KL', 'mykad', '900101145678', 'GR338B1'),
  ('00000000-0000-0000-0000-0000000338b2', 'Other Party', '60133800012', null, null, null, null, null, null, null, null)
on conflict (id) do update set name = excluded.name, phone = excluded.phone, email = excluded.email,
  ic = excluded.ic, birth_date = excluded.birth_date, nationality = excluded.nationality,
  address = excluded.address, id_type = excluded.id_type, id_number_typed = excluded.id_number_typed,
  display_id = excluded.display_id;

insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000338a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000338a3', 'admin-god-view', 'edit')
on conflict do nothing;

-- The other party is a partner (phone NOT NULL, status is the partner_status enum).
insert into public.partners (id, auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-0000000338c2', '00000000-0000-0000-0000-0000000338b2', 'Other Party', '60133800012', 'approved')
on conflict do nothing;

-- Subject data: a session, two trips (one as rider, one as partner), payments,
-- a wallet balance, two location fixes, a safety incident, a deletion request.
insert into public.user_sessions (user_id, event_type, ip_address, network_operator, os_name, os_version,
                                  device_model_name, app_version, app_build_version, captured_at) values
  ('00000000-0000-0000-0000-0000000338b1', 'login', '203.0.113.7', 'Celcom', 'Android', '14',
   'Pixel 8', '2.4.0', '240', now() - interval '2 days');

insert into public.ride_requests (id, rider_id, partner_id, status, service, pickup_name, drop_name, fare, created_at) values
  ('00000000-0000-0000-0000-000000033801', '00000000-0000-0000-0000-0000000338b1',
   '00000000-0000-0000-0000-0000000338b2', 'completed', 'Car', 'Home', 'Office', 12.50, now() - interval '3 days'),
  ('00000000-0000-0000-0000-000000033802', '00000000-0000-0000-0000-0000000338a2',
   '00000000-0000-0000-0000-0000000338b1', 'completed', 'Car', 'Mall', 'Station', 8.00, now() - interval '1 day');

insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note, ride_id, created_at) values
  ('00000000-0000-0000-0000-0000000338b1', 'get_wallet', 'topup', 50.00, 'card', 'Reload', null, now() - interval '5 days'),
  ('00000000-0000-0000-0000-0000000338b1', 'get_wallet', 'ride_payment', -12.50, 'wallet', 'Trip',
   '00000000-0000-0000-0000-000000033801', now() - interval '3 days');

insert into public.wallets (user_id, wallet_type, balance, currency) values
  ('00000000-0000-0000-0000-0000000338b1', 'get_wallet', 37.50, 'RM')
on conflict (user_id, wallet_type) do update set balance = excluded.balance;

insert into public.user_location_history (user_id, latitude, longitude, captured_at) values
  ('00000000-0000-0000-0000-0000000338b1', 3.1390, 101.6869, now() - interval '3 days'),
  ('00000000-0000-0000-0000-0000000338b1', 3.1500, 101.7000, now() - interval '1 day');

insert into public.safety_incidents (id, reporter_id, reporter_role, rider_id, lat, lng, track_until, status) values
  ('00000000-0000-0000-0000-0000000338d1', '00000000-0000-0000-0000-0000000338b1', 'rider',
   '00000000-0000-0000-0000-0000000338b1', 3.14, 101.69, now() + interval '30 minutes', 'resolved');

insert into public.account_deletion_requests (user_id, phone_hash, method, status, reason) values
  ('00000000-0000-0000-0000-0000000338b1', 'hash-338', 'phone_code', 'cancelled', 'Changed my mind');

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
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text)
  to authenticated;

set local role authenticated;

-- 1. A non-admin and a scoped sub-admin are refused -----------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000338a2');
select pg_temp.refused($q$select public.admin_lawful_export('00000000-0000-0000-0000-0000000338b1','PDRM','Insp','REP/1','Court order')$q$,
  'a non-admin exporting');
select pg_temp.refused('select public.admin_lawful_requests()', 'a non-admin reading the register');
select pg_temp.as_user('00000000-0000-0000-0000-0000000338a3');
select pg_temp.refused($q$select public.admin_lawful_export('00000000-0000-0000-0000-0000000338b1','PDRM','Insp','REP/1','Court order')$q$,
  'a God View sub-admin (not a full admin) exporting');
select pg_temp.refused('select public.admin_lawful_requests()', 'a God View sub-admin reading the register');

-- 2. A full admin: required fields, unknown subject -----------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000338a1');
select pg_temp.refused($q$select public.admin_lawful_export('00000000-0000-0000-0000-0000000338b1','','Insp','REP/1','Court order')$q$,
  'an export with a blank agency');
select pg_temp.refused($q$select public.admin_lawful_export('00000000-0000-0000-0000-0000000338b1','PDRM','Insp','  ','Court order')$q$,
  'an export with a blank reference');
select pg_temp.refused($q$select public.admin_lawful_export('00000000-0000-0000-0000-0000000338b1','PDRM','Insp','REP/1','')$q$,
  'an export with a blank legal basis');
select pg_temp.refused($q$select public.admin_lawful_export('00000000-0000-0000-0000-00000003389999','PDRM','Insp','REP/1','Court order')$q$,
  'an export for an unknown subject');

-- 3. A full admin exports, and gets the document --------------------------------------------------
create temp table doc338 as
  select public.admin_lawful_export('00000000-0000-0000-0000-0000000338b1', 'PDRM', 'Insp Rahman',
    'RPT/2026/338', 'CPC s.116', 'Urgent') as d;

select pg_temp.check((select d->'account'->>'id_number' = '900101145678' from doc338),
  'the full id number is disclosed in the document');
select pg_temp.check((select d->'account'->>'name' = 'Subject One'
                        and d->'account'->>'email' = 'subject@example.com'
                        and d->'account'->>'date_of_birth' = '1990-01-01'
                        and d->'account'->>'nationality' = 'Malaysia' from doc338),
  'the account block');
select pg_temp.check((select (d->'trips'->>'total')::int = 2
                        and (d->'trips'->>'returned')::int = 2 from doc338), 'both trips, as rider and as partner');
select pg_temp.check((select exists (
    select 1 from jsonb_array_elements(d->'trips'->'rows') t
     where t->>'role' = 'partner' and t->>'other_party_id' = '00000000-0000-0000-0000-0000000338a2')
  from doc338), 'a trip where the subject was the partner names the other party');
select pg_temp.check((select (d->'payments'->>'total')::int = 2
                        and (d->'payments'->'balances'->0->>'balance')::numeric = 37.50 from doc338),
  'payments and the current balance');
select pg_temp.check((select (d->'location_history'->>'total')::int = 2
                        and d->'location_history'->>'earliest' is not null
                        and d->'location_history'->>'latest' is not null from doc338),
  'location history count and span');
select pg_temp.check((select jsonb_array_length(d->'safety') = 1
                        and d->'safety'->0->>'reporter_role' = 'rider' from doc338), 'the safety incident');
select pg_temp.check((select jsonb_array_length(d->'deletion'->'requests') = 1
                        and (d->'deletion'->>'account_deleted')::boolean = false from doc338),
  'the deletion request and the not-deleted flag');
select pg_temp.check((select d->'meta'->'request'->>'reference' = 'RPT/2026/338'
                        and d->'meta'->>'subject_id' = '00000000-0000-0000-0000-0000000338b1' from doc338),
  'the request meta');

-- 4. The register row and the audit row are written -----------------------------------------------
select pg_temp.check((select exists (
    select 1 from jsonb_array_elements(public.admin_lawful_requests()) r
     where r->>'reference' = 'RPT/2026/338' and r->>'agency' = 'PDRM'
       and r->>'subject_name' = 'Subject One' and r->>'exported_at' is not null)),
  'the register lists the request');
select pg_temp.check((select count(*) = 1 from public.admin_audit_log
                       where actor_id = '00000000-0000-0000-0000-0000000338a1' and action = 'lawful_export'
                         and target_profile_id = '00000000-0000-0000-0000-0000000338b1'
                         and detail->>'reference' = 'RPT/2026/338'),
  'the export is in the admin audit log');
-- The audit detail carries identifiers only, not the exported data.
select pg_temp.check((select not (detail::text like '%900101145678%')
                        from public.admin_audit_log
                       where actor_id = '00000000-0000-0000-0000-0000000338a1' and action = 'lawful_export'),
  'the audit row does not carry the exported id number');

rollback;
