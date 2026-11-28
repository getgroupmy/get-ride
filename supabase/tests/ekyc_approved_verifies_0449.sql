-- ============================================================================
-- Regression test for migration 0449: a GET.eKYC approval verifies the rider
-- at once, whatever the country's face-score bar; anything else waits.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ekyc_approved_verifies_0449.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000449c1', '60100004491'),  -- approved, face just over get.ekyc's bar (80)
  ('00000000-0000-0000-0000-0000000449c2', '60100004492'),  -- review: a person decides
  ('00000000-0000-0000-0000-0000000449c3', '60100004493')   -- "approved" without liveness: not trusted
on conflict do nothing;
insert into public.profiles (id, name, nationality)
select id, 'Siti Aminah', 'Malaysia' from auth.users where id::text like '00000000-0000-0000-0000-0000000449%'
on conflict (id) do update set name = excluded.name, nationality = excluded.nationality, id_verified = null, id_image = null;
insert into public.app_settings (key, value) values ('rider_id_gate', jsonb_build_object(
  'master', jsonb_build_object('autoVerifyScore', 95, 'idType', 'either')))
on conflict (key) do update set value = excluded.value;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
grant execute on function pg_temp.check(boolean, text) to service_role;
create temp table ids (k text primary key, id uuid);
grant all on ids to service_role;

set local role service_role;
with s as (
  insert into public.ekyc_sessions (user_id, purpose, verification_id) values
    ('00000000-0000-0000-0000-0000000449c1', 'rider_gate', 'ver_0449aaaa0001'),
    ('00000000-0000-0000-0000-0000000449c2', 'rider_gate', 'ver_0449aaaa0002'),
    ('00000000-0000-0000-0000-0000000449c3', 'rider_gate', 'ver_0449aaaa0003')
  returning id, user_id)
insert into ids select right(user_id::text, 2), id from s;

create or replace function pg_temp.apply(p_k text, p_status text, p_live text) returns jsonb language sql as $$
  select public.ekyc_apply((select id from ids where k = p_k), jsonb_build_object(
    'status', p_status, 'doc_type', 'mykad',
    'front', '00000000-0000-0000-0000-0000000449' || p_k || '/signin/ekyc_front.jpg',
    'selfie', '00000000-0000-0000-0000-0000000449' || p_k || '/signin/ekyc_selfie.jpg',
    'read', jsonb_build_object('name', 'SITI AMINAH'),
    'face', jsonb_build_object('score', 80, 'state', 'match'), 'liveness', p_live))
$$;
grant execute on function pg_temp.apply(text, text, text) to service_role;

select pg_temp.check((pg_temp.apply('c1', 'approved', 'passed')->>'verified')::boolean,
  'approved by GET.eKYC with a face of 80 under a bar of 95: verified');
select pg_temp.check((select id_verified = 'Verified' from public.profiles where id = '00000000-0000-0000-0000-0000000449c1'),
  'the profile reads Verified');
select pg_temp.check((select status = 'Approved' from public.identity_checks
                       where user_id = '00000000-0000-0000-0000-0000000449c1' and kind = 'id'), 'the check is Approved');

select pg_temp.check(coalesce((pg_temp.apply('c2', 'review', 'passed')->>'verified')::boolean, false) = false,
  'review is not verified');
select pg_temp.check((select id_verified is null from public.profiles where id = '00000000-0000-0000-0000-0000000449c2'),
  'review leaves the profile pending');

select pg_temp.check((pg_temp.apply('c3', 'approved', 'not_checked')->>'pending')::boolean,
  'an approval without liveness under the bar waits for an admin');
select pg_temp.check((select id_verified is null from public.profiles where id = '00000000-0000-0000-0000-0000000449c3'),
  'and the profile stays pending');

reset role;
rollback;
