-- ============================================================================
-- Regression test for migration 0401: the live-selfie (liveness) gate.
--   * profile_liveness_block is true where the person's country requires a live
--     selfie (profile_selfie_gate) and they have no APPROVED selfie since the
--     requirement; an approved selfie clears them; a country where it is off
--     does not require it.
--   * approver_request_member_liveness deletes the current photo and starts the
--     clock, so a previously-approved selfie no longer clears them until they
--     submit and get a new one approved.
--   * the booking guard raises LIVENESS_REQUIRED for a blocked rider.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/profile_liveness_gate_0401.sql
--
-- Runs in one transaction and is rolled back. Made-up people only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000401a1'),  -- the approver
  ('00000000-0000-0000-0000-0000000401b1'),  -- in Malaysia, no selfie
  ('00000000-0000-0000-0000-0000000401b2'),  -- in Malaysia, has an approved selfie
  ('00000000-0000-0000-0000-0000000401b3')   -- in Singapore (selfie off)
on conflict do nothing;
insert into public.profiles (id, name, phone, nationality, current_country) values
  ('00000000-0000-0000-0000-0000000401a1', 'Approver 401', '+60100004011', 'Malaysia', null),
  ('00000000-0000-0000-0000-0000000401b1', 'Needs Selfie', '+60100004012', 'Malaysia', 'Malaysia'),
  ('00000000-0000-0000-0000-0000000401b2', 'Has Selfie',   '+60100004013', 'Malaysia', 'Malaysia'),
  ('00000000-0000-0000-0000-0000000401b3', 'In Singapore', '+60100004014', 'Malaysia', 'Singapore')
on conflict (id) do update set nationality = excluded.nationality, current_country = excluded.current_country;

-- b2 already has an approved live selfie (taken a while ago).
insert into public.identity_checks (user_id, kind, file_url, status, reviewed_at, created_at) values
  ('00000000-0000-0000-0000-0000000401b2', 'selfie', 'u/b2-selfie.jpg', 'Approved',
   now() - interval '10 days', now() - interval '10 days')
on conflict do nothing;

insert into public.referrals (referrer_user_id, referred_user_id, code) values
  ('00000000-0000-0000-0000-0000000401a1', '00000000-0000-0000-0000-0000000401b1', 'T401CODE1'),
  ('00000000-0000-0000-0000-0000000401a1', '00000000-0000-0000-0000-0000000401b2', 'T401CODE2'),
  ('00000000-0000-0000-0000-0000000401a1', '00000000-0000-0000-0000-0000000401b3', 'T401CODE3')
on conflict (referred_user_id) do nothing;
insert into public.approvers (profile_id, scope, conflict_guard, use_own_region, regions, doc_types, can_edit_profile)
values ('00000000-0000-0000-0000-0000000401a1', 'referral', false, false, '[]'::jsonb, '{}', true)
on conflict (profile_id) do update set
  active = true, ends_at = null, scope = 'referral', conflict_guard = false, can_edit_profile = true;

-- Malaysia requires a live selfie; Singapore does not.
insert into public.app_settings (key, value, updated_at)
values ('profile_selfie_gate', '{"Malaysia": {"require": true}, "Singapore": {"require": false}}'::jsonb, now())
on conflict (key) do update set value = excluded.value, updated_at = now();

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid) to authenticated;

-- 1. The gate: Malaysia requires it and b1 has no selfie → blocked.
select pg_temp.check(public.profile_liveness_block('00000000-0000-0000-0000-0000000401b1'),
  'a user in a country that requires a live selfie, with none, is blocked');
-- 2. b2 has an approved selfie → not blocked.
select pg_temp.check(not public.profile_liveness_block('00000000-0000-0000-0000-0000000401b2'),
  'a user with an approved live selfie is not blocked');
-- 3. b3 is in a country where it is off → not blocked.
select pg_temp.check(not public.profile_liveness_block('00000000-0000-0000-0000-0000000401b3'),
  'a user in a country where the live selfie is off is not blocked');

-- 4. An approver requests a new live selfie from b2: photo cleared, requirement
--    set, and the old approved selfie no longer clears them.
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000401a1');
select pg_temp.check((public.approver_request_member_liveness('00000000-0000-0000-0000-0000000401b2') ->> 'ok')::boolean,
  'the approver can request a fresh live selfie');
reset role;
select pg_temp.check(
  (select avatar_url is null and profile_image is null and selfie_required_at is not null
     from public.profiles where id = '00000000-0000-0000-0000-0000000401b2'),
  'requesting liveness clears the current photo and starts the clock');
select pg_temp.check(public.profile_liveness_block('00000000-0000-0000-0000-0000000401b2'),
  'after a request, the old approved selfie no longer clears them — blocked again');

-- 5. A new approved selfie, taken after the request, clears them.
insert into public.identity_checks (user_id, kind, file_url, status, reviewed_at, created_at) values
  ('00000000-0000-0000-0000-0000000401b2', 'selfie', 'u/b2-selfie-new.jpg', 'Approved', now(), now());
select pg_temp.check(not public.profile_liveness_block('00000000-0000-0000-0000-0000000401b2'),
  'a newly approved live selfie clears the requirement');

-- 6. The booking guard raises LIVENESS_REQUIRED for a blocked rider (b1).
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000401b1');
do $$
declare v_msg text;
begin
  begin
    insert into public.ride_requests (rider_id, status) values ('00000000-0000-0000-0000-0000000401b1', 'open');
    raise exception 'FAILED: the booking guard did not block a rider who owes a live selfie';
  exception
    when others then
      get stacked diagnostics v_msg = message_text;
      if v_msg not like '%LIVENESS_REQUIRED%' then
        raise exception 'FAILED: expected LIVENESS_REQUIRED, got %', v_msg;
      end if;
  end;
end $$;
reset role;

rollback;
