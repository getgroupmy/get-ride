-- ============================================================================
-- Regression test for migration 0346: the "Live selfie required" partner
-- registration rule.
--   * Where a type sets liveSelfie.required, a partner whose onboarding
--     profile selfie was not taken with the live check is refused on Submit
--     (LIVE_SELFIE_REQUIRED): no selfie at all, or a selfie recorded
--     'not_checked'; a selfie recorded 'passed' submits;
--   * approval is refused (PARTNER_RULES_NOT_MET) until the selfie is live, or
--     an admin overrides with a reason;
--   * reg_rule_code maps the rule to its code.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/live_selfie_rule_0346.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000346a1'),  -- admin, EDIT on Partners
  ('00000000-0000-0000-0000-0000000346b1'),  -- driver: live selfie required
  ('00000000-0000-0000-0000-0000000346b2')   -- driver: for the approval path
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000346%'
on conflict do nothing;
-- Both drivers are Malaysian citizens, so only the live-selfie rule can fail.
update public.profiles set id_type = 'mykad', nationality = 'Malaysian', ic = '900101-14-0346'
 where id = '00000000-0000-0000-0000-0000000346b1';
update public.profiles set id_type = 'mykad', nationality = 'Malaysian', ic = '900202-14-0347'
 where id = '00000000-0000-0000-0000-0000000346b2';
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000346a1', 'admin-partners', 'edit')
on conflict do nothing;

-- A type with the live-selfie rule in Malaysia, nothing else.
insert into public.settings_entries (id, category, values, position, active) values
  ('00000000-0000-0000-0000-0000000346e1', 'partner-type',
   '{"name":"Test0346 Hail","vehicleRequired":false,
     "liveSelfie":{"required":true,"all":false,"regions":[{"country":"Malaysia"}]}}', 0, true);

insert into public.partners (id, auth_user_id, name, phone, status, partner_types,
                             service_countries, service_states, service_cities, avatar_url) values
  ('00000000-0000-0000-0000-0000000346f1', '00000000-0000-0000-0000-0000000346b1', 'Test Live Alpha', '+60100003461',
   'unapproved', '{Test0346 Hail}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}', null),
  ('00000000-0000-0000-0000-0000000346f2', '00000000-0000-0000-0000-0000000346b2', 'Test Live Bravo', '+60100003462',
   'unapproved', '{Test0346 Hail}', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Ampang}', null);

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_db() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
create or replace function pg_temp.error_of(p_sql text) returns text language plpgsql as $$
declare h text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics h = pg_exception_hint;
  return sqlerrm || ': ' || coalesce(h, '');
end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.as_db(),
  pg_temp.error_of(text) to authenticated;

-- 0. The code mapping -----------------------------------------------------------------------------------
select pg_temp.check(public.reg_rule_code('live_selfie') = 'LIVE_SELFIE_REQUIRED', 'the rule maps to its code');

-- 1. No selfie at all: Submit refused -------------------------------------------------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000346b1');
select pg_temp.check(pg_temp.error_of($q$update public.partners set documents_ok = true
                                        where id = '00000000-0000-0000-0000-0000000346f1'$q$)
                       like 'LIVE_SELFIE_REQUIRED: Test0346 Hail in Malaysia needs a live selfie.%',
  'no live selfie: refused');
select pg_temp.check((select (c -> 0 ->> 'rule') = 'live_selfie' and (c -> 0 ->> 'status') = 'failed'
                        from public.partner_registration_problems('00000000-0000-0000-0000-0000000346f1') c),
  'the partner reads the live-selfie problem');
reset role;

-- 2. A selfie taken without the live check: still refused -----------------------------------------------
select pg_temp.as_db();
update public.partners set avatar_url = 'https://x.test/selfie-0346.jpg'
 where id = '00000000-0000-0000-0000-0000000346f1';
insert into public.identity_checks (user_id, kind, purpose, file_url, liveness)
values ('00000000-0000-0000-0000-0000000346b1', 'selfie', 'profile', 'https://x.test/selfie-0346.jpg', 'not_checked');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000346b1');
select pg_temp.check(pg_temp.error_of($q$update public.partners set documents_ok = true
                                        where id = '00000000-0000-0000-0000-0000000346f1'$q$)
                       like 'LIVE_SELFIE_REQUIRED:%',
  'a selfie without the live check (not_checked): still refused');
reset role;

-- 3. A live selfie: Submit succeeds ---------------------------------------------------------------------
select pg_temp.as_db();
update public.identity_checks set liveness = 'passed'
 where user_id = '00000000-0000-0000-0000-0000000346b1' and file_url = 'https://x.test/selfie-0346.jpg';
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000346b1');
update public.partners set documents_ok = true where id = '00000000-0000-0000-0000-0000000346f1';
select pg_temp.check((select documents_ok from public.partners where id = '00000000-0000-0000-0000-0000000346f1'),
  'with a live selfie, it is submitted');
reset role;

-- 4. Approval is held until the selfie is live, or overridden -------------------------------------------
select pg_temp.as_db();
update public.partners set avatar_url = 'https://x.test/selfie-0346b.jpg', documents_ok = true
 where id = '00000000-0000-0000-0000-0000000346f2';
insert into public.identity_checks (user_id, kind, purpose, file_url, liveness)
values ('00000000-0000-0000-0000-0000000346b2', 'selfie', 'profile', 'https://x.test/selfie-0346b.jpg', 'not_checked');
insert into public.partner_review_items (partner_id, item_key, item_group, label, state) values
  ('00000000-0000-0000-0000-0000000346f2', 'details.name', 'details', 'Full name', 'approved');
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000346a1');
select pg_temp.check(pg_temp.error_of($q$select public.partner_review_approve('00000000-0000-0000-0000-0000000346f2')$q$)
                       like 'PARTNER_RULES_NOT_MET: Can''t approve: Live selfie missing (Test0346 Hail needs it in Malaysia).%',
  'approval is refused while the selfie is not live');
select public.partner_review_approve('00000000-0000-0000-0000-0000000346f2',
                                     'Verified by video call, ticket 0346 (made up).');
select pg_temp.check((select status::text = 'approved' from public.partners where id = '00000000-0000-0000-0000-0000000346f2'),
  'approved with an override reason');
select pg_temp.check((select count(*) = 1 from public.partner_rule_overrides o
                       where o.partner_id = '00000000-0000-0000-0000-0000000346f2'
                         and o.rules -> 0 ->> 'rule' = 'live_selfie'),
  'the override records the live-selfie failure');
reset role;

rollback;
