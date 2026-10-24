-- ============================================================================
-- Regression test for migration 0283: the face match and ID reading
-- settings, who changes them, the key-or-not flags only admins see, and what
-- Google Vision read stored on the check with the mismatch checked again.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/identity_providers_0283.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id, phone) values
  ('00000000-0000-0000-0000-0000000283a1', '60100002831'),  -- full admin
  ('00000000-0000-0000-0000-0000000283a2', '60100002832'),  -- sub-admin: read Documents only
  ('00000000-0000-0000-0000-0000000283b1', '60100002833')   -- the person sending their ID
on conflict do nothing;
insert into public.profiles (id, name, ic)
select id, case right(id::text, 2) when 'b1' then 'Aina binti Ahmad' else 'P' || right(id::text, 2) end,
       case right(id::text, 2) when 'b1' then '880202-10-1234' end
  from auth.users where id::text like '00000000-0000-0000-0000-0000000283%'
on conflict (id) do update set name = excluded.name, ic = excluded.ic;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000283a1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000283a2', 'admin-documents', 'read')
on conflict do nothing;
delete from public.app_settings where key = 'dispatch_verify';
insert into public.app_settings (key, value) values ('api_providers', jsonb_build_array(
  jsonb_build_object('id', 'aws', 'services', jsonb_build_array(jsonb_build_object('id', 'rekognition', 'keys',
    jsonb_build_array(jsonb_build_object('id', 'k1', 'value', 'AKIA:secret', 'disabled', true))))),
  jsonb_build_object('id', 'face_match', 'services', jsonb_build_array(jsonb_build_object('id', 'server', 'keys',
    jsonb_build_array(jsonb_build_object('id', 'k2', 'value', 'https://face.example:secret')))))))
on conflict (key) do update set value = excluded.value;

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
create temp table ids (k text primary key, id uuid);
grant all on ids to authenticated;
grant execute on function pg_temp.as_user(uuid), pg_temp.check(boolean, text), pg_temp.refused(text, text)
  to authenticated;

-- 0. The helpers are the server's -------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('authenticated', 'public.identity_check_store_read(uuid, jsonb)', 'execute')
                     and has_function_privilege('service_role', 'public.identity_check_store_read(uuid, jsonb)', 'execute')
                     and not has_function_privilege('authenticated', 'public.identity_key_ready(text, text)', 'execute')
                     and not has_function_privilege('authenticated', 'public.identity_read_mismatch(uuid, text, text)', 'execute')
                     and not has_function_privilege('anon', 'public.identity_set_providers(text, text)', 'execute'),
                     'store_read, key_ready and read_mismatch are the server''s');

set local role authenticated;

-- 1. The defaults, and the key flags for admins only -----------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000283b1');
select pg_temp.check(public.dispatch_verify_config()->>'faceProvider' = 'aws', 'AWS is the default face match');
select pg_temp.check(public.dispatch_verify_config()->>'idRead' = 'phone', 'the phone reads the card by default');
select pg_temp.check(not (public.dispatch_verify_config() ? 'awsKey'), 'no key flags for someone who isn''t an admin');
select pg_temp.refused($q$select public.identity_set_providers('off', null)$q$, 'a person changing the face match');

select pg_temp.as_user('00000000-0000-0000-0000-0000000283a2');
select pg_temp.check((public.dispatch_verify_config()->>'awsKey')::boolean = false, 'a switched-off AWS key is no key');
select pg_temp.check((public.dispatch_verify_config()->>'faceServer')::boolean, 'the face server has a key');
select pg_temp.check((public.dispatch_verify_config()->>'visionKey')::boolean = false, 'no Vision key');
select pg_temp.refused($q$select public.identity_set_providers('off', null)$q$, 'a view-only Documents admin changing it');

-- 2. The admin changes them -------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000283a1');
select pg_temp.refused($q$select public.identity_set_providers('elsewhere', null)$q$, 'a face match that isn''t one');
select pg_temp.refused($q$select public.identity_set_providers(null, 'always')$q$, 'an ID reading that isn''t one');
select pg_temp.check(public.identity_set_providers('self_hosted_aws', null)->>'faceProvider' = 'self_hosted_aws',
                     'self-hosted, then AWS');
select pg_temp.check(public.identity_set_providers(null, 'phone_vision')->>'idRead' = 'phone_vision'
                     and public.dispatch_verify_config()->>'faceProvider' = 'self_hosted_aws',
                     'one setting changes, the other stays');
select pg_temp.check((public.dispatch_set_verify_config(12)->>'idRead') = 'phone_vision',
                     'the renewal window keeps them');

-- 3. What the phone read, then what Google Vision read ---------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000283b1');
insert into ids values ('id1', (public.identity_check_submit(jsonb_build_object('kind', 'id', 'doc_type', 'mykad',
  'file_url', 'https://x.supabase.co/storage/v1/object/public/ID_Image/' || auth.uid() || '/signin/front.jpg',
  'file_url_back', 'https://x.supabase.co/storage/v1/object/public/ID_Image/' || auth.uid() || '/signin/back.jpg',
  'read_name', 'SITI NURHALIZA')))->>'id')::uuid);
select pg_temp.check((select mismatch = array['name'] and read_source = 'phone' and read_at is not null
                        from public.identity_checks where id = (select id from ids where k = 'id1')),
                     'the phone''s read, checked against the profile');
insert into ids values ('id2', (public.identity_check_submit(jsonb_build_object('kind', 'id', 'doc_type', 'mykad',
  'file_url', 'https://x.supabase.co/storage/v1/object/public/ID_Image/' || auth.uid() || '/signin/front2.jpg',
  'file_url_back', 'https://x.supabase.co/storage/v1/object/public/ID_Image/' || auth.uid() || '/signin/back2.jpg')))->>'id')::uuid);
select pg_temp.check((select read_source is null and mismatch = '{}' from public.identity_checks
                       where id = (select id from ids where k = 'id2')), 'nothing read, no source');
select pg_temp.refused($q$select public.identity_check_store_read((select id from ids where k = 'id1'),
  '{"name": "AINA BINTI AHMAD"}')$q$, 'the person writing their own read');

reset role;
select pg_temp.check((public.identity_check_store_read((select id from ids where k = 'id1'),
  '{"name": "AINA BINTI AHMAD", "ic": "880202-10-1234", "expiry": "not a date"}')->'mismatch') = '[]'::jsonb,
  'Vision''s read clears the mismatch');
select pg_temp.check((select read_source = 'vision' and read_name = 'AINA BINTI AHMAD' and read_ic = '880202-10-1234'
                             and read_expiry is null
                        from public.identity_checks where id = (select id from ids where k = 'id1')),
                     'kept on the check, a bad date dropped');
select pg_temp.check((public.identity_check_store_read((select id from ids where k = 'id2'),
  '{"ic": "900101-14-5678", "passport": "A12345678"}')->'mismatch') = '["ic"]'::jsonb,
  'a different IC is flagged');
select pg_temp.check((select read_passport = 'A12345678' from public.identity_checks
                       where id = (select id from ids where k = 'id2')), 'the passport number is kept');
select pg_temp.refused($q$select public.identity_check_store_read(gen_random_uuid(), '{}')$q$, 'a check that isn''t there');

select 'identity_providers_0283: all passed';
rollback;
