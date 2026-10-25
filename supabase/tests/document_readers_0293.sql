-- ============================================================================
-- Regression test for migration 0293: document reading.
-- The reader order and switches (normalised, who may change them); pairing a
-- NAS with a one-time code; photos queued only while a NAS is paired and on;
-- the NAS claims, reports, and passes on what it isn't sure of; stuck jobs
-- go out again and fail after 3 tries; removing a reader ends its key; the
-- reader's calls belong to the edge function only.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/document_readers_0293.sql
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
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'FAILED: % was allowed', p_what;
exception when insufficient_privilege then
  null;
end $$;

delete from public.app_settings where key = 'document_reading';

-- 1. The settings: defaults, every reader once, known readers only ---------------------------
select pg_temp.check(
  (select string_agg(r->>'id', ',') from jsonb_array_elements(public.document_reading_config()->'readers') r)
    = 'phone,nas,gpu,cloud',
  'default order: phone, NAS, GPU PC, cloud');
select pg_temp.check((public.document_reading_config()->>'passOnBelow')::int = 90, 'pass on below 90% by default');
select pg_temp.check(
  (select string_agg((r->>'id') || ':' || (r->>'on'), ',')
     from jsonb_array_elements(public.document_reading_normalize(
       '{"readers":[{"id":"cloud","on":false},{"id":"evil"},{"id":"cloud","on":true},{"id":"phone","on":true}],
         "passOnBelow":12}')->'readers') r)
    = 'cloud:false,phone:true,nas:true,gpu:true',
  'saved order kept, unknown and repeated readers dropped, missing ones added on');
select pg_temp.check(
  (public.document_reading_normalize('{"passOnBelow":12}')->>'passOnBelow')::int = 50
  and (public.document_reading_normalize('{"passOnBelow":"x"}')->>'passOnBelow')::int = 90,
  'pass-on percentage kept between 50 and 100');

-- 2. Who may change them -------------------------------------------------------------------
insert into auth.users (id) values
  ('00000000-0000-0000-0000-000000293a01'),  -- full admin
  ('00000000-0000-0000-0000-000000293a02'),  -- sub-admin with the page
  ('00000000-0000-0000-0000-000000293a03'),  -- rider
  ('00000000-0000-0000-0000-000000293a04')   -- driver
on conflict do nothing;
insert into public.profiles (id) values
  ('00000000-0000-0000-0000-000000293a01'), ('00000000-0000-0000-0000-000000293a02'),
  ('00000000-0000-0000-0000-000000293a03'), ('00000000-0000-0000-0000-000000293a04')
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-000000293a01', '*', 'edit'),
  ('00000000-0000-0000-0000-000000293a02', 'admin-settings-document-reading', 'edit')
on conflict do nothing;

select pg_temp.as_user('00000000-0000-0000-0000-000000293a02');
select pg_temp.check(
  (public.admin_document_reading_set('{"readers":[{"id":"phone","on":true},{"id":"cloud","on":false},{"id":"nas","on":true}]}')
     -> 'readers' -> 1 ->> 'id') = 'cloud',
  'a sub-admin with the page reorders the readers');
select pg_temp.check(not public.document_reader_on('cloud') and public.document_reader_on('nas'), 'switches saved');
select pg_temp.refused($q$select public.admin_doc_reader_pairing_code('nas', 'Office')$q$,
  'a sub-admin connecting a reader');
select pg_temp.as_user('00000000-0000-0000-0000-000000293a03');
select pg_temp.refused($q$select public.admin_document_reading_set('{}')$q$, 'a rider changing document reading');
select pg_temp.refused($q$select public.admin_doc_readers()$q$, 'a rider listing readers');
select pg_temp.check((public.document_reading_config()->'readers'->0->>'id') = 'phone', 'the app reads the order');

-- 3. Nothing is queued before a NAS is paired ---------------------------------------------
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.partners (id, auth_user_id, name, phone, status) values
  ('00000000-0000-0000-0000-000000293b01', '00000000-0000-0000-0000-000000293a04', 'Aina', '+60110000293', 'approved');
insert into public.vehicle (id, auth_user_id, plate, make, model, color, status) values
  ('00000000-0000-0000-0000-000000293c01', '00000000-0000-0000-0000-000000293a04', 'WXY 1234', 'Perodua', 'Bezza',
   'White', 'approved');
insert into public.provider_documents (id, partner_id, auth_user_id, doc_id, doc_name, file_url) values
  ('00000000-0000-0000-0000-000000293d01', '00000000-0000-0000-0000-000000293b01',
   '00000000-0000-0000-0000-000000293a04', 'licence', 'Driving licence', 'https://x/provider-documents/a/licence/front-1.jpg');
select pg_temp.check(not exists (select 1 from public.doc_read_jobs), 'no NAS, nothing queued');

-- 4. Pairing: a full admin's code, traded once for a key -----------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000293a01');
create temp table code_t on commit drop as
  select public.admin_doc_reader_pairing_code('nas', 'DS224+') ->> 'code' as code;
select pg_temp.check((select code ~ '^[A-Z2-9]{4}-[A-Z2-9]{4}$' from code_t), 'code shown as XXXX-XXXX');
reset role;
select set_config('request.jwt.claims', '', true);
select pg_temp.check((public.doc_reader_pair('WRONG-CODE', 'nas-1') ->> 'error') = 'READER_PAIR_CODE', 'a wrong code');
create temp table key_t on commit drop as
  select public.doc_reader_pair((select lower(code) from code_t), 'nas-1', null, 'DS224+ J4125', '1.0.0') as r;
select pg_temp.check((select r ? 'key' and r->>'kind' = 'nas' and r->>'label' = 'DS224+' from key_t),
  'the code (any case) gives a key, with the admin''s label');
select pg_temp.check((public.doc_reader_pair((select code from code_t), 'nas-2') ->> 'error') = 'READER_PAIR_CODE',
  'a code works once');
select pg_temp.check(
  (select key_hash <> (select r->>'key' from key_t) from public.doc_readers where device_id = 'nas-1'),
  'only the key''s hash is kept');
select pg_temp.check((public.doc_reader_heartbeat((select r->>'key' from key_t)) ->> 'on')::boolean,
  'check-in: the NAS is on');
do $$
begin
  perform public.doc_reader_heartbeat('not-a-key');
  raise exception 'FAILED: a made-up key checked in';
exception when insufficient_privilege then
  null;
end $$;

-- 5. Photos are queued per side; plates only on vehicle documents --------------------------
update public.provider_documents
   set file_url = 'https://x/provider-documents/a/licence/front-2.jpg',
       file_url_back = 'https://x/provider-documents/a/licence/back-2.jpg'
 where id = '00000000-0000-0000-0000-000000293d01';
select pg_temp.check((select count(*) from public.doc_read_jobs where doc_table = 'provider_documents') = 2,
  'a new front and back: two jobs');
select pg_temp.check((select bool_and(wants = '{numbers,qr}') from public.doc_read_jobs), 'licence: numbers and QR, no plates');
update public.provider_documents set status = 'Approved' where id = '00000000-0000-0000-0000-000000293d01';
select pg_temp.check((select count(*) from public.doc_read_jobs) = 2, 'other changes queue nothing');
insert into public.vehicle_documents (id, vehicle_id, partner_id, doc_id, doc_name, file_url) values
  ('00000000-0000-0000-0000-000000293e01', '00000000-0000-0000-0000-000000293c01',
   '00000000-0000-0000-0000-000000293b01', 'cover', 'Insurance cover note', 'https://x/vehicle-documents/v/cover/front-1.jpg');
select pg_temp.check((select wants from public.doc_read_jobs where doc_table = 'vehicle_documents') = '{numbers,plates,qr}',
  'vehicle document: plates too');

-- 6. Claim, report, pass on -----------------------------------------------------------------
create temp table job_t on commit drop as
  select * from public.doc_reader_claim((select r->>'key' from key_t), 2);
select pg_temp.check((select count(*) from job_t) = 2, 'two jobs claimed, oldest first');
select pg_temp.check((select count(*) from public.doc_read_jobs where status = 'reading') = 2, 'marked reading');
select pg_temp.check(
  public.doc_reader_report((select r->>'key' from key_t), (select id from job_t order by created_at, side desc limit 1),
    true, '{"numbers":["D1234567"]}', 97, 1200) = 'done',
  'a sure reading is done');
select pg_temp.check(
  public.doc_reader_report((select r->>'key' from key_t), (select id from job_t order by created_at, side limit 1),
    true, '{"numbers":[]}', 40, 2300) = 'passed_on',
  'an unsure reading is passed on');
select pg_temp.check(
  public.doc_reader_report((select r->>'key' from key_t), (select id from job_t limit 1), true, '{}', 99, 1) = 'not_yours',
  'a finished job can''t be reported twice');

-- Failures go back to the queue, then fail after 3 tries.
create temp table v_job on commit drop as select * from public.doc_reader_claim((select r->>'key' from key_t), 1);
select pg_temp.check(
  public.doc_reader_report((select r->>'key' from key_t), (select id from v_job), false, null, null, null, 'crash') = 'queued',
  'a failed reading goes back to the queue');
update public.doc_read_jobs set attempts = 3, status = 'reading', claimed_at = now() - interval '6 minutes',
       reader_id = (select id from public.doc_readers where device_id = 'nas-1')
 where id = (select id from v_job);
select count(*) from public.doc_reader_claim((select r->>'key' from key_t), 1);
select pg_temp.check((select status from public.doc_read_jobs where id = (select id from v_job)) = 'failed',
  'stuck after 3 tries: failed');

-- Today's work, for the admin.
select pg_temp.as_user('00000000-0000-0000-0000-000000293a02');
create temp table list_t on commit drop as select public.admin_doc_readers() as l;
select pg_temp.check((select (l->'readers'->0->'today'->'numbers'->>'done')::int = 1
                         and (l->'readers'->0->'today'->'numbers'->>'passed_on')::int = 1
                         and (l->'readers'->0->>'online')::boolean from list_t),
  'admin sees today''s numbers: one done, one passed on, and the NAS online');

-- 7. Switched off: no claims, nothing queued ------------------------------------------------
reset role;
select set_config('request.jwt.claims', '', true);
update public.app_settings set value = jsonb_set(value, '{readers}', '[{"id":"nas","on":false}]') where key = 'document_reading';
select pg_temp.check(not exists (select 1 from public.doc_reader_claim((select r->>'key' from key_t), 5)),
  'NAS off: no claims');
update public.provider_documents set file_url = 'https://x/provider-documents/a/licence/front-3.jpg'
 where id = '00000000-0000-0000-0000-000000293d01';
select pg_temp.check(not exists (select 1 from public.doc_read_jobs where file_url like '%front-3%'),
  'NAS off: nothing queued');

-- 8. Removing the reader ends its key -------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000293a01');
select public.admin_doc_reader_remove((select id from public.doc_readers where device_id = 'nas-1'));
reset role;
select set_config('request.jwt.claims', '', true);
do $$
begin
  perform public.doc_reader_heartbeat((select r->>'key' from key_t));
  raise exception 'FAILED: a removed reader checked in';
exception when insufficient_privilege then
  null;
end $$;

-- 9. The reader's calls are the edge function's only ---------------------------------------
select pg_temp.check(
  not has_function_privilege('anon', 'public.doc_reader_pair(text, text, text, text, text)', 'execute')
  and not has_function_privilege('authenticated', 'public.doc_reader_claim(text, integer)', 'execute')
  and has_function_privilege('service_role', 'public.doc_reader_report(text, uuid, boolean, jsonb, numeric, integer, text)', 'execute'),
  'pair, claim and report are for the edge function');
select pg_temp.check(not has_table_privilege('authenticated', 'public.doc_read_jobs', 'select'),
  'nobody reads the queue directly');

rollback;
