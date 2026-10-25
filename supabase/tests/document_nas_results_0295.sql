-- ============================================================================
-- Regression test for migration 0295: what the office NAS read, for admins.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/document_nas_results_0295.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

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

insert into auth.users (id) values ('00000000-0000-0000-0000-000000295a01'), ('00000000-0000-0000-0000-000000295a02')
on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-000000295a01'), ('00000000-0000-0000-0000-000000295a02')
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-000000295a01', 'admin-documents', 'read') on conflict do nothing;

insert into public.doc_readers (id, kind, label, device_id, key_hash) values
  ('00000000-0000-0000-0000-000000295c01', 'nas', 'DS224+', 'nas-295', 'hash-295');
insert into public.doc_read_jobs (doc_table, doc_id, side, file_url, wants, status, reader_id, result, confidence, ms, done_at) values
  ('vehicle_documents', '00000000-0000-0000-0000-000000295d01', 'front', 'u1', '{plates}', 'done',
   '00000000-0000-0000-0000-000000295c01', '{"plates":["WXY 1234"]}', 97, 1200, now() - interval '1 hour'),
  ('vehicle_documents', '00000000-0000-0000-0000-000000295d01', 'front', 'u2', '{plates}', 'passed_on',
   '00000000-0000-0000-0000-000000295c01', '{"plates":[]}', 40, 1300, now()),
  ('vehicle_documents', '00000000-0000-0000-0000-000000295d01', 'back', 'u3', '{numbers}', 'queued',
   null, null, null, null, null);

select pg_temp.as_user('00000000-0000-0000-0000-000000295a01');
create temp table r_t on commit drop as
  select * from public.admin_doc_read_results('vehicle_documents', array['00000000-0000-0000-0000-000000295d01'::uuid]);
select pg_temp.check((select count(*) from r_t) = 1, 'one finished reading per side; waiting ones left out');
select pg_temp.check((select status = 'passed_on' and reader_label = 'DS224+' from r_t), 'the newest, with the reader''s name');
select pg_temp.check(
  not exists (select 1 from public.admin_doc_read_results('provider_documents', array['00000000-0000-0000-0000-000000295d01'::uuid])),
  'by table');

select pg_temp.as_user('00000000-0000-0000-0000-000000295a02');
do $$
begin
  perform public.admin_doc_read_results('vehicle_documents', array[gen_random_uuid()]);
  raise exception 'FAILED: a non-admin read the NAS results';
exception when insufficient_privilege then
  null;
end $$;

rollback;
