-- ============================================================================
-- Regression test for migration 0441: GET eKYC keeps each identity
-- document's type, and auto-verifies a rider only for an ID card or passport
-- the country's rule accepts; a driving licence, i-Kad or UNHCR card waits
-- for an admin.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/get_ekyc_document_types_0441.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000441b1', '60100004411'),  -- MyPR holder
  ('00000000-0000-0000-0000-0000000441b2', '60100004412'),  -- shows a driving licence
  ('00000000-0000-0000-0000-0000000441b3', '60100004413'),  -- i-Kad
  ('00000000-0000-0000-0000-0000000441b4', '60100004414'),  -- passport, rule says national ID only
  ('00000000-0000-0000-0000-0000000441b5', '60100004415')   -- UNHCR card
on conflict do nothing;
insert into public.profiles (id, name, nationality)
select id, 'Chen Wei Ming', case right(id::text, 2) when 'b4' then 'Testland' else 'Malaysia' end
  from auth.users where id::text like '00000000-0000-0000-0000-0000000441%'
on conflict (id) do update set name = excluded.name, nationality = excluded.nationality, id_verified = null, id_image = null;
insert into public.app_settings (key, value) values ('rider_id_gate', jsonb_build_object(
  'master', jsonb_build_object('autoVerifyScore', 85, 'idType', 'either'),
  'Testland', jsonb_build_object('autoVerifyScore', 85, 'idType', 'national')))
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
    ('00000000-0000-0000-0000-0000000441b1', 'rider_gate', 'ver_0441aaaa0001'),
    ('00000000-0000-0000-0000-0000000441b2', 'rider_gate', 'ver_0441aaaa0002'),
    ('00000000-0000-0000-0000-0000000441b3', 'rider_gate', 'ver_0441aaaa0003'),
    ('00000000-0000-0000-0000-0000000441b4', 'rider_gate', 'ver_0441aaaa0004'),
    ('00000000-0000-0000-0000-0000000441b5', 'rider_gate', 'ver_0441aaaa0005')
  returning id, user_id)
insert into ids select right(user_id::text, 2), id from s;

create or replace function pg_temp.apply(p_k text, p_doc text) returns jsonb language sql as $$
  select public.ekyc_apply((select id from ids where k = p_k), jsonb_build_object(
    'status', 'approved', 'doc_type', p_doc,
    'front', '00000000-0000-0000-0000-0000000441' || p_k || '/signin/ekyc_front.jpg',
    'selfie', '00000000-0000-0000-0000-0000000441' || p_k || '/signin/ekyc_selfie.jpg',
    'read', jsonb_build_object('name', 'CHEN WEI MING'),
    'face', jsonb_build_object('score', 95, 'state', 'match'), 'liveness', 'passed'))
$$;
grant execute on function pg_temp.apply(text, text) to service_role;

select pg_temp.check((pg_temp.apply('b1', 'mypr')->>'verified')::boolean, 'a MyPR is an identity card: verified');
select pg_temp.check((pg_temp.apply('b2', 'driving_licence')->>'pending')::boolean, 'a driving licence waits for an admin');
select pg_temp.check((pg_temp.apply('b3', 'ikad')->>'pending')::boolean, 'an i-Kad waits for an admin');
select pg_temp.check((pg_temp.apply('b4', 'passport')->>'pending')::boolean, 'a passport where the rule wants a national ID waits');
select pg_temp.check((pg_temp.apply('b5', 'unhcr')->>'pending')::boolean, 'a UNHCR card waits for an admin');
reset role;

select pg_temp.check((select doc_type = 'mypr' and status = 'Approved' from public.identity_checks
                       where user_id = '00000000-0000-0000-0000-0000000441b1' and kind = 'id'), 'MyPR kept and approved');
select pg_temp.check((select doc_type = 'driving_licence' and status = 'Pending Review' from public.identity_checks
                       where user_id = '00000000-0000-0000-0000-0000000441b2' and kind = 'id'), 'licence kept, pending');
select pg_temp.check((select doc_type = 'ikad' from public.identity_checks
                       where user_id = '00000000-0000-0000-0000-0000000441b3' and kind = 'id'), 'i-Kad kept');
select pg_temp.check((select id_verified is null from public.profiles where id = '00000000-0000-0000-0000-0000000441b2'),
  'a licence alone does not verify the rider');

do $$ begin raise notice 'get_ekyc_document_types_0441: all checks passed'; end $$;
rollback;
