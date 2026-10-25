-- ============================================================================
-- Regression test for migration 0294: what the partner confirmed at upload.
-- read_fields is kept on both document tables, an object of at most 20 kB;
-- the owner writes it with their upload.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/document_read_fields_0294.sql
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
create or replace function pg_temp.rejected(p_sql text, p_what text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'FAILED: % was accepted', p_what;
exception when check_violation then
  null;
end $$;

insert into auth.users (id) values ('00000000-0000-0000-0000-000000294a01') on conflict do nothing;
insert into public.partners (id, auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-000000294b01', '00000000-0000-0000-0000-000000294a01', 'Aina', '+60110000294', 'approved');

-- The owner, signed in, uploads with what they confirmed.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-000000294a01', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000294a01', true);
insert into public.provider_documents (id, partner_id, auth_user_id, doc_id, doc_name, file_url, read_fields) values
  ('00000000-0000-0000-0000-000000294d01', '00000000-0000-0000-0000-000000294b01', '00000000-0000-0000-0000-000000294a01',
   'licence', 'Driving licence', 'https://x/provider-documents/a/licence/front-1.jpg',
   '{"kind":"licence","fields":{"fullName":"AINA BINTI RAHMAN"},"changed":[],"photo":{"sharp":true,"glare":false,"corners":true}}');
select pg_temp.check(
  (select read_fields #>> '{fields,fullName}' from public.provider_documents where id = '00000000-0000-0000-0000-000000294d01')
    = 'AINA BINTI RAHMAN',
  'the owner keeps what they confirmed');
reset role;
select set_config('request.jwt.claims', '', true);

-- Only an object, and not a large one.
select pg_temp.rejected($q$update public.provider_documents set read_fields = '["x"]'
  where id = '00000000-0000-0000-0000-000000294d01'$q$, 'a list');
select pg_temp.rejected($q$update public.provider_documents set read_fields = jsonb_build_object('fields', repeat('x', 20001))
  where id = '00000000-0000-0000-0000-000000294d01'$q$, 'over 20 kB');
select pg_temp.check(
  exists (select 1 from information_schema.columns where table_name = 'vehicle_documents' and column_name = 'read_fields'),
  'vehicle documents keep it too');

rollback;
