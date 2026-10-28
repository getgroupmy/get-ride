-- ============================================================================
-- Regression test for migration 0320: Office NAS, ID and face.
--   * the two orders and the low score: defaults, 0283's choices when none
--     is saved, who may save them, 0283's two settings written alongside,
--     identity_set_providers replacing a saved order;
--   * an ID sent for review is queued for the NAS only when the phone read
--     nothing, the NAS is on and online; the NAS claims ID jobs first, even
--     with Document reading's NAS off; a sure reading is kept on the check
--     (read_source 'nas', birth date, nationality, checked against the
--     profile); a less sure one goes on to Google Vision when that is next,
--     else is kept as read; one not claimed in 5 minutes is handed on;
--   * the doc-reader's check-in says on for ID cards, and keeps its
--     nas_services row;
--   * the in-browser check: the waiting pairs no server scored, the score
--     kept on both as 'browser', never over a server's score, refused when
--     off or for someone without a Documents page; nothing approved;
--   * the Office NAS › ID and face numbers; the grants.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/nas_id_face_0320.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- Made-up people and numbers only.
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
create or replace function pg_temp.order_text(p jsonb) returns text language sql as $$
  select string_agg((r->>'id') || ':' || (r->>'on'), ',' order by o) from jsonb_array_elements(p) with ordinality x(r, o)
$$;

delete from public.app_settings where key in ('dispatch_verify', 'document_reading');
delete from public.doc_readers;

-- 1. The orders: defaults and 0283's choices -----------------------------------------------------
select pg_temp.check(pg_temp.order_text(public.identity_face_order()) = 'nas:true,aws:true,browser:true',
  'face match: NAS, then AWS, then in-browser by default');
select pg_temp.check(pg_temp.order_text(public.identity_id_readers()) = 'phone:true,nas:true,vision:false',
  'ID reading: phone, then NAS; Google Vision off by default');
select pg_temp.check(public.identity_face_low_score() = 60, 'needs a closer look below 60% by default');

insert into public.app_settings (key, value) values ('dispatch_verify', '{"faceProvider":"self_hosted","idRead":"vision"}');
select pg_temp.check(pg_temp.order_text(public.identity_face_order()) = 'nas:true,aws:false,browser:true',
  '0283 self-hosted: the NAS only, then in-browser');
select pg_temp.check(pg_temp.order_text(public.identity_id_readers()) = 'vision:true,phone:true,nas:true',
  '0283 Google Vision always: Vision first');
update public.app_settings set value = '{"faceProvider":"off"}' where key = 'dispatch_verify';
select pg_temp.check(not public.identity_order_on(public.identity_face_order(), 'browser'), '0283 off: nothing compares');
select pg_temp.check(
  pg_temp.order_text(public.identity_order_clean('[{"id":"browser","on":false},{"id":"x"},{"id":"browser"},{"id":"aws","on":"yes"}]',
    array['aws', 'nas', 'browser'], '[{"id":"aws","on":true},{"id":"nas","on":true},{"id":"browser","on":true}]'))
    = 'browser:false,aws:true,nas:true',
  'saved order kept; unknown and repeated dropped; a missing one joins');

-- 1. Who saves them -------------------------------------------------------------------------------
insert into auth.users (id) values
  ('00000000-0000-0000-0000-000000320a01'),  -- full admin
  ('00000000-0000-0000-0000-000000320a02'),  -- sub-admin with Office NAS
  ('00000000-0000-0000-0000-000000320a03'),  -- rider
  ('00000000-0000-0000-0000-000000320b01'),  -- stand admin sending an ID
  ('00000000-0000-0000-0000-000000320b02')   -- another
on conflict do nothing;
insert into public.profiles (id, name, ic) values
  ('00000000-0000-0000-0000-000000320a01', 'Admin 320', null),
  ('00000000-0000-0000-0000-000000320a02', 'Sub 320', null),
  ('00000000-0000-0000-0000-000000320a03', 'Rider 320', null),
  ('00000000-0000-0000-0000-000000320b01', 'Aina binti Contoh', '900101-14-5678'),
  ('00000000-0000-0000-0000-000000320b02', 'Ravi Contoh', null)
on conflict (id) do update set name = excluded.name, ic = excluded.ic;  -- sign-up may have made the rows
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-000000320a01', '*', 'edit'),
  ('00000000-0000-0000-0000-000000320a02', 'admin-settings-office-nas', 'edit')
on conflict do nothing;

select pg_temp.as_user('00000000-0000-0000-0000-000000320a02');
select pg_temp.check(
  (public.identity_set_order('{"faceOrder":[{"id":"aws","on":true},{"id":"nas","on":true},{"id":"browser","on":true}],
                               "idReaders":[{"id":"phone","on":true},{"id":"nas","on":true},{"id":"vision","on":true}],
                               "faceLowScore":70}') ->> 'faceLowScore')::int = 70,
  'a sub-admin with Office NAS saves the orders');
select pg_temp.check(
  (select value->>'faceProvider' = 'aws' and value->>'idRead' = 'phone_vision'
     from public.app_settings where key = 'dispatch_verify'),
  '0283''s settings written as near as they go');
select pg_temp.as_user('00000000-0000-0000-0000-000000320a01');
do $$
begin
  perform public.identity_set_order('{"faceLowScore":10}');
  raise exception 'FAILED: a low score of 10 was taken';
exception when invalid_parameter_value then
  null;
end $$;
select public.identity_set_order('{"faceOrder":[{"id":"nas","on":true},{"id":"aws","on":true}]}');
select pg_temp.check(
  public.identity_face_order() -> 2 ->> 'id' = 'browser'
  and (select value->>'faceProvider' from public.app_settings where key = 'dispatch_verify') = 'self_hosted_aws',
  'NAS then AWS is 0283''s self-hosted, then AWS; the in-browser check stays in the list');
select public.identity_set_providers('aws', null);
select pg_temp.check(
  not (select value ? 'faceOrder' from public.app_settings where key = 'dispatch_verify')
  and (select value ? 'idReaders' from public.app_settings where key = 'dispatch_verify')
  and pg_temp.order_text(public.identity_face_order()) = 'aws:true,nas:false,browser:true',
  'an older app''s face choice replaces the saved face order only');
select pg_temp.as_user('00000000-0000-0000-0000-000000320a03');
select pg_temp.refused($q$select public.identity_set_order('{"faceLowScore":60}')$q$, 'a rider changing the order');
select pg_temp.refused($q$select public.identity_face_browser_queue()$q$, 'a rider reading the browser queue');
select pg_temp.refused($q$select public.admin_nas_id_face()$q$, 'a rider reading the NAS tab');
select pg_temp.as_user('00000000-0000-0000-0000-000000320a01');
select public.identity_set_order('{"faceOrder":[{"id":"aws","on":true},{"id":"nas","on":true},{"id":"browser","on":true}],
                                   "idReaders":[{"id":"phone","on":true},{"id":"nas","on":true},{"id":"vision","on":true}],
                                   "faceLowScore":60}');

-- 2. An ID is queued for the NAS only when it is next -------------------------------------------
-- Document reading has the NAS off: ID cards are still read.
insert into public.app_settings (key, value)
values ('document_reading', '{"readers":[{"id":"phone","on":true},{"id":"nas","on":false}],"passOnBelow":90}')
on conflict (key) do update set value = excluded.value;

insert into public.identity_checks (id, user_id, kind, purpose, doc_type, file_url, file_url_back, status)
values ('00000000-0000-0000-0000-000000320c01', '00000000-0000-0000-0000-000000320b01', 'id', 'first', 'mykad',
        'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-000000320b01/signin/id_front_1.jpg',
        'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-000000320b01/signin/id_back_1.jpg',
        'Pending Review');
select pg_temp.check(not exists (select 1 from public.doc_read_jobs where doc_table = 'identity_checks'),
  'no NAS paired: nothing queued');

insert into public.doc_readers (id, kind, label, device_id, key_hash, last_seen_at)
values ('00000000-0000-0000-0000-000000320d01', 'nas', 'DS224+ test', 'nas-320',
        public.gateway_secret_hash(repeat('k', 64)), now());
select pg_temp.check(public.identity_nas_reader_ready(), 'the NAS is online');

-- The phone read it: the NAS isn't asked.
insert into public.identity_checks (id, user_id, kind, purpose, doc_type, file_url, file_url_back, status,
                                    read_name, read_source, read_at)
values ('00000000-0000-0000-0000-000000320c02', '00000000-0000-0000-0000-000000320b02', 'id', 'first', 'passport',
        'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-000000320b02/signin/id_front_1.jpg',
        'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-000000320b02/signin/id_back_1.jpg',
        'Pending Review', 'RAVI CONTOH', 'phone', now());
select pg_temp.check(not exists (select 1 from public.doc_read_jobs where doc_id = '00000000-0000-0000-0000-000000320c02'),
  'read on the phone: the NAS is not asked');

-- The phone read nothing: queued for the NAS.
insert into public.identity_checks (id, user_id, kind, purpose, doc_type, file_url, file_url_back, status)
values ('00000000-0000-0000-0000-000000320c03', '00000000-0000-0000-0000-000000320b01', 'id', 'first', 'mykad',
        'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-000000320b01/signin/id_front_2.jpg',
        'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-000000320b01/signin/id_back_2.jpg',
        'Pending Review');
select pg_temp.check(
  (select wants = array['id_card'] and doc_name = 'MyKad' and side = 'front' and status = 'queued'
     from public.doc_read_jobs where doc_id = '00000000-0000-0000-0000-000000320c03'),
  'queued for the NAS: the front, the ID fields only');
select pg_temp.check(public.identity_nas_reading('00000000-0000-0000-0000-000000320c03'),
  'the id-read function sees the NAS has it');
select pg_temp.check(public.identity_read_route('00000000-0000-0000-0000-000000320c02') = 'none',
  'read on the phone: nobody else');

-- The NAS goes quiet: the next ID goes to Google Vision.
update public.doc_readers set last_seen_at = now() - interval '10 minutes';
select pg_temp.check(public.identity_read_route('00000000-0000-0000-0000-000000320c01') = 'vision',
  'NAS offline: Google Vision is next');
update public.doc_readers set last_seen_at = now();

-- 2. The NAS claims, ID jobs first, and reports --------------------------------------------------
insert into public.doc_read_jobs (doc_table, doc_id, side, file_url, doc_name, wants, created_at)
values ('provider_documents', gen_random_uuid(), 'front',
        'https://x.supabase.co/storage/v1/object/public/provider-documents/p/1.jpg', 'Licence', array['numbers'],
        now() - interval '1 hour');
select pg_temp.check(
  (select string_agg(doc_table, ',') from public.doc_reader_claim(repeat('k', 64), 5)) = 'identity_checks',
  'Document reading off: only the ID job is claimed');
select pg_temp.check(
  public.doc_reader_report(repeat('k', 64), (select id from public.doc_read_jobs where doc_id = '00000000-0000-0000-0000-000000320c03'),
    true, '{"id":{"name":"AINA BINTI CONTOH","ic":"900101-14-9999","birth":"1990-01-01","nationality":"MYS",
                 "passport":null,"expiry":null}}', 96, 2100) = 'done',
  'a sure reading is done');
select pg_temp.check(
  (select read_source = 'nas' and read_name = 'AINA BINTI CONTOH' and read_birth = '1990-01-01'
          and read_nationality = 'MYS' and mismatch = array['ic'] and status = 'Pending Review'
     from public.identity_checks where id = '00000000-0000-0000-0000-000000320c03'),
  'kept on the check, checked against the profile, still waiting for the admin');

-- With both on, ID jobs come first.
update public.app_settings set value = '{"readers":[{"id":"phone","on":true},{"id":"nas","on":true}],"passOnBelow":90}'
 where key = 'document_reading';
insert into public.identity_checks (id, user_id, kind, purpose, doc_type, file_url, file_url_back, status)
values ('00000000-0000-0000-0000-000000320c04', '00000000-0000-0000-0000-000000320b02', 'id', 'first', 'passport',
        'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-000000320b02/signin/id_front_2.jpg',
        'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-000000320b02/signin/id_back_2.jpg',
        'Pending Review');
select pg_temp.check(
  (select doc_table from public.doc_reader_claim(repeat('k', 64), 1)) = 'identity_checks',
  'the waiting ID before an older document');
-- Less sure: handed on to Google Vision (after the NAS, on).
select pg_temp.check(
  public.doc_reader_report(repeat('k', 64), (select id from public.doc_read_jobs where doc_id = '00000000-0000-0000-0000-000000320c04'),
    true, '{"id":{"name":"RAVI CONTOH","passport":"A1234567"}}', 40, 1800) = 'passed_on',
  'a less sure reading is passed on');
select pg_temp.check(
  (select handed_on_at is not null from public.doc_read_jobs where doc_id = '00000000-0000-0000-0000-000000320c04')
  and (select read_source is null from public.identity_checks where id = '00000000-0000-0000-0000-000000320c04'),
  'handed to Google Vision; the unsure reading is not kept');

-- Vision off: the NAS's reading is kept as it is.
select public.identity_set_order('{"idReaders":[{"id":"phone","on":true},{"id":"nas","on":true},{"id":"vision","on":false}]}');
update public.doc_read_jobs set status = 'passed_on', handed_on_at = null
 where doc_id = '00000000-0000-0000-0000-000000320c04';
select pg_temp.check(
  public.identity_nas_hand_on((select id from public.doc_read_jobs where doc_id = '00000000-0000-0000-0000-000000320c04')) = 'kept',
  'no reader after the NAS: handed on to nobody');
select pg_temp.check(
  (select read_source = 'nas' and read_passport = 'A1234567' from public.identity_checks
        where id = '00000000-0000-0000-0000-000000320c04'),
  'no reader after the NAS: its reading is kept');
select pg_temp.check(
  public.identity_nas_hand_on((select id from public.doc_read_jobs where doc_id = '00000000-0000-0000-0000-000000320c04')) = 'none',
  'handed on once');

-- Not claimed in 5 minutes: the sweep passes it on.
select public.identity_set_order('{"idReaders":[{"id":"phone","on":true},{"id":"nas","on":true},{"id":"vision","on":true}]}');
insert into public.doc_read_jobs (id, doc_table, doc_id, side, file_url, doc_name, wants, created_at)
values ('00000000-0000-0000-0000-000000320e01', 'identity_checks', '00000000-0000-0000-0000-000000320c01', 'front',
        'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-000000320b01/signin/id_front_1.jpg',
        'MyKad', array['id_card'], now() - interval '10 minutes');
select public.identity_nas_sweep();
select pg_temp.check(
  (select status = 'passed_on' and handed_on_at is not null and error like '%5 minutes%'
     from public.doc_read_jobs where id = '00000000-0000-0000-0000-000000320e01'),
  'an ID the NAS did not take in 5 minutes goes on');

-- The check-in.
update public.app_settings set value = '{"readers":[{"id":"nas","on":false}]}' where key = 'document_reading';
select pg_temp.check(
  (public.doc_reader_heartbeat(repeat('k', 64), 'DS224+ · J4125', '1.1.0') ->> 'on')::boolean,
  'on for ID cards with Document reading''s NAS off');
select pg_temp.check(
  (select version = '1.1.0' and status = 'ok' and last_seen > now() - interval '1 minute'
     from public.nas_services where service = 'doc-reader'),
  'the doc-reader''s heartbeat row');

-- 3. The in-browser check ------------------------------------------------------------------------
insert into public.identity_checks (id, user_id, kind, purpose, file_url, liveness, status, face_state, face_score, face_provider)
values ('00000000-0000-0000-0000-000000320c05', '00000000-0000-0000-0000-000000320b01', 'selfie', 'first',
        'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-000000320b01/signin/selfie_1.jpg',
        'passed', 'Pending Review', null, null, null),
       ('00000000-0000-0000-0000-000000320c06', '00000000-0000-0000-0000-000000320b02', 'selfie', 'first',
        'https://x.supabase.co/storage/v1/object/public/ID_Image/00000000-0000-0000-0000-000000320b02/signin/selfie_1.jpg',
        'passed', 'Pending Review', 'match', 91, 'aws');
update public.identity_checks set face_state = 'match', face_score = 91, face_provider = 'aws'
 where user_id = '00000000-0000-0000-0000-000000320b02';
select pg_temp.as_user('00000000-0000-0000-0000-000000320a01');
-- (In one transaction now() is one time: the IDs are given their order.)
update public.identity_checks set created_at = now() - interval '2 hours' where id = '00000000-0000-0000-0000-000000320c01';
update public.identity_checks set created_at = now() - interval '1 hour' where id = '00000000-0000-0000-0000-000000320c03';
select pg_temp.check(
  exists (select 1 from jsonb_array_elements(public.identity_face_browser_queue()) e
           where e->>'id' = '00000000-0000-0000-0000-000000320c05'
             and e->>'other_id' = '00000000-0000-0000-0000-000000320c03'
             and e->>'selfie_url' like '%selfie_1.jpg' and e->>'card_url' like '%id_front_2.jpg'),
  'the selfie with the newest ID front, waiting, unscored');
select pg_temp.check(
  not exists (select 1 from jsonb_array_elements(public.identity_face_browser_queue()) e
               where e->>'id' in ('00000000-0000-0000-0000-000000320c06', '00000000-0000-0000-0000-000000320c02')),
  'a pair AWS scored is not listed');
select pg_temp.check(
  public.identity_face_browser_save('00000000-0000-0000-0000-000000320c05', '00000000-0000-0000-0000-000000320c03', 'match', 72.456) = 2,
  'kept on the selfie and the ID');
select pg_temp.check(
  (select bool_and(face_provider = 'browser' and face_score = 72.46 and status = 'Pending Review')
     from public.identity_checks where id in ('00000000-0000-0000-0000-000000320c05', '00000000-0000-0000-0000-000000320c03')),
  'marked browser; nothing approved');
select pg_temp.check(
  public.identity_face_browser_save('00000000-0000-0000-0000-000000320c06', '00000000-0000-0000-0000-000000320c04', 'no_match', 10) = 0,
  'a server''s score is not touched');
select pg_temp.check(
  (select face_provider = 'aws' and face_score = 91 from public.identity_checks where id = '00000000-0000-0000-0000-000000320c06'),
  'never over a server''s score');
do $$
begin
  perform public.identity_face_browser_save('00000000-0000-0000-0000-000000320c05', null, 'match', 140);
  raise exception 'FAILED: a score of 140 was taken';
exception when invalid_parameter_value then
  null;
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-000000320a02');
select pg_temp.refused(
  $q$select public.identity_face_browser_save('00000000-0000-0000-0000-000000320c05', null, 'match', 50)$q$,
  'a sub-admin without a Documents page saving a score');

-- 4. The tab ------------------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000320a01');
select pg_temp.check(
  (select (x->'reads'->>'done')::int = 1 and (x->'reads'->>'passed_on')::int >= 2 and x->'reader'->>'label' = 'DS224+ test'
          and (x->'reader'->>'online')::boolean and (x->'faces'->>'browser')::int = 2
          and (x->'config'->>'nasReader')::boolean
     from (select public.admin_nas_id_face() as x) t),
  'the tab: the reader, today''s reads and face scores by source');

select public.identity_set_order('{"faceOrder":[{"id":"aws","on":true},{"id":"nas","on":true},{"id":"browser","on":false}]}');
select pg_temp.check(public.identity_face_browser_queue() = '[]'::jsonb, 'in-browser off: nothing to score');
do $$
begin
  perform public.identity_face_browser_save('00000000-0000-0000-0000-000000320c05', null, 'match', 50);
  raise exception 'FAILED: a browser score was taken while it is off';
exception when invalid_parameter_value then
  null;
end $$;

-- 5. The grants ---------------------------------------------------------------------------------
select pg_temp.check(
  not has_function_privilege('authenticated', 'public.identity_check_store_read(uuid, jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'public.identity_nas_reading(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.identity_read_route(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.identity_nas_sweep()', 'execute')
  and not has_function_privilege('authenticated', 'public.doc_reader_claim(text, integer)', 'execute')
  and not has_function_privilege('anon', 'public.identity_set_order(jsonb)', 'execute')
  and has_function_privilege('authenticated', 'public.identity_set_order(jsonb)', 'execute')
  and has_function_privilege('authenticated', 'public.identity_face_browser_save(uuid, uuid, text, numeric)', 'execute')
  and has_function_privilege('service_role', 'public.identity_nas_reading(uuid)', 'execute'),
  'the reader''s and the store''s functions are the server''s; the admin''s are the admin''s');

select 'nas_id_face_0320: all checks passed' as result;
rollback;
