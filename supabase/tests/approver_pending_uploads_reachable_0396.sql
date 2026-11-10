-- ============================================================================
-- Regression test for migration 0396: Notify-nudge reachability.
--   * approver_pending_uploads runs (the ORDER BY fix is carried here too) and
--     tags each row with `reachable` — true for a member who has a push token,
--     false for one who has none.
--   * approver_request_document_upload returns `reachable`, and only sends the
--     push when the member can actually receive it.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/approver_pending_uploads_reachable_0396.sql
--
-- Scoped to the fixtures below; runs in one transaction and is rolled back.
-- Made-up people, tokens and documents only.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000396a1'),  -- the approver
  ('00000000-0000-0000-0000-0000000396b1'),  -- Reachable (has a device)
  ('00000000-0000-0000-0000-0000000396b2')   -- Unreachable (no device)
on conflict do nothing;
insert into public.profiles (id, name, phone) values
  ('00000000-0000-0000-0000-0000000396a1', 'Approver Six',   '+60100003961'),
  ('00000000-0000-0000-0000-0000000396b1', 'Reachable Rae',  '+60100003962'),
  ('00000000-0000-0000-0000-0000000396b2', 'Unreachable Uma','+60100003963')
on conflict (id) do update set name = excluded.name, phone = excluded.phone;

-- Only Rae has a registered device.
insert into public.push_tokens (profile_id, token, platform) values
  ('00000000-0000-0000-0000-0000000396b1', 'test-token-0396-rae', 'android')
on conflict (token) do nothing;

-- Rae is a partner serving one city, so the list shows her service location.
insert into public.partners (id, auth_user_id, name, phone, status, service_countries, service_states, service_cities)
values ('00000000-0000-0000-0000-0000039603e1', '00000000-0000-0000-0000-0000000396b1', 'Reachable Rae', '+60100003962',
        'approved', '{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Semenyih}')
on conflict (id) do nothing;

-- A required partner document neither has uploaded.
insert into public.required_document (id, values) values
  ('00000000-0000-0000-0000-0000039602d1',
   '{"name": "Test Partner Doc 396", "active": true, "required": true}')
on conflict (id) do nothing;

insert into public.approvers (profile_id, scope, conflict_guard, use_own_region, regions, doc_types, can_upload)
values ('00000000-0000-0000-0000-0000000396a1', 'all', false, false, '[]'::jsonb, '{}', true)
on conflict (profile_id) do update set
  active = true, ends_at = null, scope = excluded.scope, conflict_guard = excluded.conflict_guard, can_upload = true;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true); end $$;
grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid) to authenticated;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000396a1');

-- The list runs and tags each member's row with the right reachability.
select pg_temp.check(
  (select (e->>'reachable')::boolean
     from jsonb_array_elements(public.approver_pending_uploads(null, 1000)) e
    where e->>'member_id' = '00000000-0000-0000-0000-0000000396b1'
      and e->>'doc_id' = '00000000-0000-0000-0000-0000039602d1'),
  'a member with a device is reachable on the list');
select pg_temp.check(
  (select not (e->>'reachable')::boolean
     from jsonb_array_elements(public.approver_pending_uploads(null, 1000)) e
    where e->>'member_id' = '00000000-0000-0000-0000-0000000396b2'
      and e->>'doc_id' = '00000000-0000-0000-0000-0000039602d1'),
  'a member with no device is not reachable on the list');

-- The service location is formatted most-specific-first and shown on the row.
select pg_temp.check(
  public._service_location_label('{Malaysia}', '{Malaysia|Selangor}', '{Malaysia|Selangor|Semenyih}')
    = 'Semenyih | Selangor | Malaysia',
  'a service area formats as "City | State | Country"');
select pg_temp.check(
  (select e->>'location'
     from jsonb_array_elements(public.approver_pending_uploads(null, 1000)) e
    where e->>'member_id' = '00000000-0000-0000-0000-0000000396b1'
      and e->>'doc_id' = '00000000-0000-0000-0000-0000039602d1') = 'Semenyih | Selangor | Malaysia',
  'the list carries the member''s service location');

-- The nudge reports reachability back.
select pg_temp.check(
  (public.approver_request_document_upload(
     '00000000-0000-0000-0000-0000000396b1', 'partner', '00000000-0000-0000-0000-0000039602d1', 'Test Partner Doc 396')
   ->>'reachable')::boolean,
  'nudging a member with a device reports reachable = true');
select pg_temp.check(
  not (public.approver_request_document_upload(
     '00000000-0000-0000-0000-0000000396b2', 'partner', '00000000-0000-0000-0000-0000039602d1', 'Test Partner Doc 396')
   ->>'reachable')::boolean,
  'nudging a member with no device reports reachable = false');

rollback;
