-- ============================================================================
-- 0320 — Office NAS, ID and face: the NAS reads MyKad and passports for the
-- sign-in checks, and the admin's browser compares faces as the last
-- fallback. (docs/NAS.md, docs/KIV.md "ID card reading on the NAS" and "the
-- in-browser check (human)".)
--
-- Version 20261028130000 (0320_nas_id_face). Re-runnable: columns "if not
-- exists", constraints and triggers dropped first, functions "create or
-- replace".
--
-- 1. Two ordered lists with a switch each, kept in app_settings
--    'dispatch_verify' next to 0283's settings (Admin › Dispatch › Accounts,
--    Documents › Sign-in checks, Settings › Office NAS › ID and face):
--      idReaders  who reads the MyKad or passport: phone, nas, vision
--                 (default Phone, then NAS; Google Vision off, as 0283's
--                 "On the phone only" default kept it);
--      faceOrder  who compares the selfie with the ID photo: aws, nas (the
--                 self-hosted face server, deploy/face-server), browser
--                 (default NAS, then AWS, then in-browser: the free check first);
--      faceLowScore  below it a sign-in check's face match "Needs a closer
--                 look" and is listed first (30..95, default 60).
--    Without a saved list, 0283's faceProvider / idRead give it, so nothing
--    changes until the admin saves; saving also writes those two (closest
--    match) for apps and functions that still read them. identity_set_order
--    saves; 0283's identity_set_providers drops the list it replaces.
-- 2. The NAS reads an ID: when an ID is sent and, walking idReaders, the
--    phone (on) read nothing and the NAS (on) is next and online (heard from
--    in 3 minutes), a reading job is queued for it (doc_read_jobs, 0293, now
--    also for 'identity_checks', wanting 'id_card'). The doc-reader on the
--    NAS claims it with a 5-minute link to the front (the ID_Image bucket,
--    for these jobs only), reads it in memory and sends back only the name,
--    IC, passport number, birth date, nationality and expiry. Sure enough
--    (Document reading's "pass on" percentage) it is kept on the check
--    (read_source 'nas', checked against the profile as before). Less sure,
--    failed, or not claimed in 5 minutes: it is handed on, to Google Vision
--    when that is on after the NAS (the id-read function, asked by the
--    database with the webhook secret), else the NAS's reading is kept as
--    it is. ID jobs are claimed before document jobs, and are claimed while
--    the NAS is on here even when Document reading has it off.
-- 3. The in-browser check (vladmandic/human, in the admin web app only):
--    identity_face_browser_queue() gives the admin's page the waiting
--    selfie/ID pairs no server has scored; identity_face_browser_save()
--    keeps the score with face_provider 'browser'. Never over a server's
--    score, never a decision: nothing here approves or rejects.
-- 4. admin_nas_id_face(): the Office NAS › ID and face tab (the NAS reader,
--    today's ID reads, today's face scores by source).
-- 5. nas_services: the shared heartbeat table of the NAS's services (the
--    Overview tab's cards); the doc-reader's check-in keeps its row.
-- ============================================================================

-- ---- 1. Columns ------------------------------------------------------------------------------------
alter table public.identity_checks
  add column if not exists read_birth date,
  add column if not exists read_nationality text
    check (read_nationality is null or read_nationality ~ '^[A-Z]{3}$');

alter table public.identity_checks drop constraint if exists identity_checks_read_source_check;
alter table public.identity_checks add constraint identity_checks_read_source_check
  check (read_source is null or read_source in ('phone', 'vision', 'nas'));
alter table public.identity_checks drop constraint if exists identity_checks_face_provider_check;
alter table public.identity_checks add constraint identity_checks_face_provider_check
  check (face_provider is null or face_provider in ('aws', 'self_hosted', 'browser'));

alter table public.doc_read_jobs drop constraint if exists doc_read_jobs_doc_table_check;
alter table public.doc_read_jobs add constraint doc_read_jobs_doc_table_check
  check (doc_table in ('provider_documents', 'vehicle_documents', 'identity_checks'));
-- When an ID job the NAS couldn't finish was handed to the next reader.
alter table public.doc_read_jobs add column if not exists handed_on_at timestamptz;
create index if not exists doc_read_jobs_identity_idx on public.doc_read_jobs (doc_id)
  where doc_table = 'identity_checks';

-- ---- 1. The two orders and the low score --------------------------------------------------------
-- [p] cleaned: each known id once, in the saved order, with its switch; one
-- missing from it joins where [p_fallback] has it last-in, with its switch.
create or replace function public.identity_order_clean(p jsonb, p_known text[], p_fallback jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_seen text[] := '{}';
  v_out jsonb := '[]'::jsonb;
  v_r jsonb;
  v_id text;
begin
  if p is not null and jsonb_typeof(p) = 'array' then
    for v_r in select * from jsonb_array_elements(p) loop
      continue when jsonb_typeof(v_r) <> 'object';
      v_id := v_r ->> 'id';
      if v_id = any(p_known) and not v_id = any(v_seen) then
        v_seen := v_seen || v_id;
        v_out := v_out || jsonb_build_array(jsonb_build_object('id', v_id,
          'on', case when jsonb_typeof(v_r -> 'on') = 'boolean' then (v_r ->> 'on')::boolean else true end));
      end if;
    end loop;
  end if;
  for v_r in select * from jsonb_array_elements(p_fallback) loop
    v_id := v_r ->> 'id';
    if v_id = any(p_known) and not v_id = any(v_seen) then
      v_seen := v_seen || v_id;
      v_out := v_out || jsonb_build_array(v_r);
    end if;
  end loop;
  return v_out;
end;
$$;
revoke execute on function public.identity_order_clean(jsonb, text[], jsonb) from public, anon, authenticated;

create or replace function public.identity_verify_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select s.value from public.app_settings s
                    where s.key = 'dispatch_verify' and jsonb_typeof(s.value) = 'object'), '{}'::jsonb);
$$;
revoke execute on function public.identity_verify_settings() from public, anon, authenticated;

-- Who compares the faces, in order. Without a saved list, 0283's choice.
create or replace function public.identity_face_order()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with v as (select public.identity_verify_settings() as s)
  select public.identity_order_clean(v.s -> 'faceOrder', array['aws', 'nas', 'browser'],
           case v.s ->> 'faceProvider'
             when 'off' then '[{"id":"aws","on":false},{"id":"nas","on":false},{"id":"browser","on":false}]'
             when 'aws' then '[{"id":"aws","on":true},{"id":"nas","on":false},{"id":"browser","on":true}]'
             when 'self_hosted' then '[{"id":"nas","on":true},{"id":"aws","on":false},{"id":"browser","on":true}]'
             when 'self_hosted_aws' then '[{"id":"nas","on":true},{"id":"aws","on":true},{"id":"browser","on":true}]'
             else '[{"id":"nas","on":true},{"id":"aws","on":true},{"id":"browser","on":true}]'
           end::jsonb)
    from v;
$$;
revoke execute on function public.identity_face_order() from public, anon, authenticated;

-- Who reads the card, in order. Without a saved list, 0283's choice, with
-- the NAS (the owner's own box) after the phone.
create or replace function public.identity_id_readers()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with v as (select public.identity_verify_settings() as s)
  select public.identity_order_clean(v.s -> 'idReaders', array['phone', 'nas', 'vision'],
           case v.s ->> 'idRead'
             when 'phone_vision' then '[{"id":"phone","on":true},{"id":"nas","on":true},{"id":"vision","on":true}]'
             when 'vision' then '[{"id":"vision","on":true},{"id":"phone","on":true},{"id":"nas","on":true}]'
             else '[{"id":"phone","on":true},{"id":"nas","on":true},{"id":"vision","on":false}]'
           end::jsonb)
    from v;
$$;
revoke execute on function public.identity_id_readers() from public, anon, authenticated;

-- Whether [p_id] is switched on in [p_order].
create or replace function public.identity_order_on(p_order jsonb, p_id text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select coalesce((select (r ->> 'on')::boolean from jsonb_array_elements(p_order) r where r ->> 'id' = p_id limit 1), false);
$$;
revoke execute on function public.identity_order_on(jsonb, text) from public, anon, authenticated;

create or replace function public.identity_face_low_score()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select greatest(30, least(95, coalesce(
    case when (public.identity_verify_settings() ->> 'faceLowScore') ~ '^\d{1,3}$'
         then (public.identity_verify_settings() ->> 'faceLowScore')::integer end, 60)));
$$;
revoke execute on function public.identity_face_low_score() from public, anon, authenticated;

-- A NAS reader is paired and heard from in the last 3 minutes (it checks in
-- every minute; 0293's "online").
create or replace function public.identity_nas_reader_ready()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.doc_readers r
                  where r.kind = 'nas' and r.last_seen_at > now() - interval '3 minutes');
$$;
revoke execute on function public.identity_nas_reader_ready() from public, anon, authenticated;

-- As 0283, with the orders, the low score and, for an admin who reads the
-- checks, the NAS reader (paired, online) next to the keys.
create or replace function public.dispatch_verify_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('renewDays', public.identity_renew_days(),
                            'faceProvider', public.identity_face_provider(),
                            'idRead', public.identity_id_read_mode(),
                            'faceOrder', public.identity_face_order(),
                            'idReaders', public.identity_id_readers(),
                            'faceLowScore', public.identity_face_low_score())
         || case when public.identity_admin_reads() then jsonb_build_object(
              'awsKey', public.identity_key_ready('aws', 'rekognition'),
              'faceServer', public.identity_key_ready('face_match', 'server'),
              'visionKey', public.identity_key_ready('google', 'vision'),
              'nasReader', exists (select 1 from public.doc_readers r where r.kind = 'nas'),
              'nasOnline', public.identity_nas_reader_ready())
            else '{}'::jsonb end;
$$;
revoke execute on function public.dispatch_verify_config() from public, anon;
grant execute on function public.dispatch_verify_config() to authenticated;

-- Saves the orders and the low score (a part left out stays as it is), and
-- 0283's two settings as near as they go, for what still reads them.
--   p: { faceOrder?: [{id, on}], idReaders?: [{id, on}], faceLowScore?: 30..95 }
create or replace function public.identity_set_order(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_face jsonb;
  v_read jsonb;
  v_low integer;
  v_set jsonb := '{}'::jsonb;
  v_servers text[];
  v_vision_at integer;
  v_phone_at integer;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:identity_set_order') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'IDENTITY_BAD_REQUEST' using errcode = '22023';
  end if;
  if p ? 'faceOrder' then
    if jsonb_typeof(p -> 'faceOrder') <> 'array' then
      raise exception 'IDENTITY_BAD_REQUEST' using errcode = '22023';
    end if;
    v_face := public.identity_order_clean(p -> 'faceOrder', array['aws', 'nas', 'browser'], public.identity_face_order());
    select array_agg(r ->> 'id' order by o) into v_servers
      from jsonb_array_elements(v_face) with ordinality x(r, o)
     where (r ->> 'on')::boolean and r ->> 'id' in ('aws', 'nas');
    v_set := v_set || jsonb_build_object('faceOrder', v_face, 'faceProvider',
      case coalesce(array_to_string(v_servers, ','), '')
        when '' then 'off' when 'nas' then 'self_hosted' when 'nas,aws' then 'self_hosted_aws' else 'aws' end);
  end if;
  if p ? 'idReaders' then
    if jsonb_typeof(p -> 'idReaders') <> 'array' then
      raise exception 'IDENTITY_BAD_REQUEST' using errcode = '22023';
    end if;
    v_read := public.identity_order_clean(p -> 'idReaders', array['phone', 'nas', 'vision'], public.identity_id_readers());
    select min(o) filter (where r ->> 'id' = 'vision' and (r ->> 'on')::boolean),
           min(o) filter (where r ->> 'id' = 'phone' and (r ->> 'on')::boolean)
      into v_vision_at, v_phone_at
      from jsonb_array_elements(v_read) with ordinality x(r, o);
    v_set := v_set || jsonb_build_object('idReaders', v_read, 'idRead',
      case when v_vision_at is null then 'phone'
           when v_phone_at is null or v_vision_at < v_phone_at then 'vision'
           else 'phone_vision' end);
  end if;
  if p ? 'faceLowScore' then
    v_low := case when (p ->> 'faceLowScore') ~ '^\d{1,3}$' then (p ->> 'faceLowScore')::integer end;
    if v_low is null or v_low not between 30 and 95 then
      raise exception 'IDENTITY_LOW_SCORE' using errcode = '22023', hint = 'Give 30 to 95.';
    end if;
    v_set := v_set || jsonb_build_object('faceLowScore', v_low);
  end if;
  insert into public.app_settings (key, value) values ('dispatch_verify', v_set)
  on conflict (key) do update set value = public.app_settings.value || excluded.value, updated_at = now();
  insert into public.admin_audit_log (actor_id, action, detail)
  values (auth.uid(), 'identity.order', v_set - 'faceProvider' - 'idRead');
  return public.dispatch_verify_config();
end;
$$;
revoke execute on function public.identity_set_order(jsonb) from public, anon;
grant execute on function public.identity_set_order(jsonb) to authenticated;

-- As 0283; a choice made here replaces the saved order it stands for, so an
-- older admin app's change takes.
create or replace function public.identity_set_providers(p_face text default null, p_id_read text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:identity_set_providers') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if (p_face is not null and p_face not in ('off', 'aws', 'self_hosted', 'self_hosted_aws'))
     or (p_id_read is not null and p_id_read not in ('phone', 'phone_vision', 'vision')) then
    raise exception 'IDENTITY_BAD_REQUEST' using errcode = '22023';
  end if;
  insert into public.app_settings (key, value)
  values ('dispatch_verify', jsonb_strip_nulls(jsonb_build_object('faceProvider', p_face, 'idRead', p_id_read)))
  on conflict (key) do update
    set value = (public.app_settings.value
                 - case when p_face is not null then 'faceOrder' else '' end
                 - case when p_id_read is not null then 'idReaders' else '' end) || excluded.value,
        updated_at = now();
  insert into public.admin_audit_log (actor_id, action, detail)
  values (auth.uid(), 'identity.providers', jsonb_strip_nulls(jsonb_build_object('face', p_face, 'id_read', p_id_read)));
  return public.dispatch_verify_config();
end;
$$;
revoke execute on function public.identity_set_providers(text, text) from public, anon;
grant execute on function public.identity_set_providers(text, text) to authenticated;

insert into public.admin_table_pages (target, page) values
  ('rpc:identity_set_order', 'admin-dispatch-accounts'),
  ('rpc:identity_set_order', 'admin-documents'),
  ('rpc:identity_set_order', 'admin-documents-users'),
  ('rpc:identity_set_order', 'admin-documents-partners'),
  ('rpc:identity_set_order', 'admin-settings-office-nas'),
  ('rpc:identity_face_browser_save', 'admin-documents'),
  ('rpc:identity_face_browser_save', 'admin-documents-users'),
  ('rpc:identity_face_browser_save', 'admin-documents-partners')
on conflict do nothing;

-- ---- 2. What was read is kept -------------------------------------------------------------------
-- As 0283 (the id-read function's write), now for the NAS too, with the
-- birth date and nationality.
--   p: { name?, ic?, passport?, expiry?, birth? (yyyy-mm-dd), nationality? (MYS),
--        source?: 'vision' (default) | 'nas' }
create or replace function public.identity_check_store_read(p_id uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.identity_checks;
  v_expiry date;
  v_birth date;
  v_nat text := upper(btrim(coalesce(p->>'nationality', '')));
  v_source text := case when p->>'source' = 'nas' then 'nas' else 'vision' end;
begin
  begin
    v_expiry := nullif(p->>'expiry', '')::date;
  exception when others then
    v_expiry := null;
  end;
  begin
    v_birth := nullif(p->>'birth', '')::date;
  exception when others then
    v_birth := null;
  end;
  update public.identity_checks set
    read_name = coalesce(nullif(left(btrim(coalesce(p->>'name', '')), 120), ''), read_name),
    read_ic = coalesce(nullif(left(btrim(coalesce(p->>'ic', '')), 40), ''), read_ic),
    read_passport = coalesce(nullif(left(btrim(coalesce(p->>'passport', '')), 40), ''), read_passport),
    read_expiry = coalesce(v_expiry, read_expiry),
    read_birth = coalesce(v_birth, read_birth),
    read_nationality = coalesce(case when v_nat ~ '^[A-Z]{3}$' then v_nat end, read_nationality),
    read_source = v_source,
    read_at = now()
   where id = p_id and kind = 'id'
  returning * into c;
  if not found then
    raise exception 'IDENTITY_NOT_FOUND' using errcode = '22023';
  end if;
  update public.identity_checks set mismatch = public.identity_read_mismatch(c.user_id, c.read_name, c.read_ic)
   where id = c.id
  returning * into c;
  return jsonb_build_object('id', c.id, 'read_name', c.read_name, 'read_ic', c.read_ic,
                            'read_passport', c.read_passport, 'read_expiry', c.read_expiry,
                            'read_birth', c.read_birth, 'read_nationality', c.read_nationality,
                            'read_source', c.read_source, 'mismatch', to_jsonb(c.mismatch));
end;
$$;
revoke execute on function public.identity_check_store_read(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.identity_check_store_read(uuid, jsonb) to service_role;

-- ---- 2. The NAS reads an ID ---------------------------------------------------------------------
-- Asks the id-read function to read [p_check] with Google Vision (best
-- effort, as 0288's document_face_check_kick: with no project URL or
-- webhook secret in Vault nothing is sent and "Read card again" is there).
create or replace function public.identity_read_kick(p_check uuid)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url    text;
  v_secret text;
begin
  begin
    select decrypted_secret into v_url from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_webhook_secret' limit 1;
  exception when others then
    return false;
  end;
  if v_url is null or v_secret is null then
    return false;
  end if;
  perform net.http_post(
    url     := v_url || '/functions/v1/id-read',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body    := jsonb_build_object('check_id', p_check, 'by', 'database')
  );
  return true;
exception when others then
  return false;
end;
$$;
revoke execute on function public.identity_read_kick(uuid) from public, anon, authenticated;

-- Who reads [p_check] next, walking the order: 'nas' (queued for it now),
-- 'vision', or 'none' (the phone read it, or nobody else is on).
create or replace function public.identity_read_route(p_check uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.identity_checks;
  r jsonb;
begin
  select * into c from public.identity_checks where id = p_check;
  if not found or c.kind <> 'id' or c.status is distinct from 'Pending Review' then
    return 'none';
  end if;
  for r in select * from jsonb_array_elements(public.identity_id_readers()) loop
    continue when not (r ->> 'on')::boolean;
    case r ->> 'id'
      when 'phone' then
        if c.read_source = 'phone' then return 'none'; end if;
      when 'nas' then
        if public.identity_nas_reader_ready() then
          insert into public.doc_read_jobs (doc_table, doc_id, side, file_url, doc_name, wants)
          values ('identity_checks', c.id, 'front', c.file_url,
                  case c.doc_type when 'passport' then 'Passport' else 'MyKad' end, array['id_card'])
          on conflict do nothing;
          return 'nas';
        end if;
      when 'vision' then
        return 'vision';
      else
        null;
    end case;
  end loop;
  return 'none';
end;
$$;
revoke execute on function public.identity_read_route(uuid) from public, anon, authenticated;

-- An ID sent for review: queued for the NAS when it is next. Never stands in
-- the way of the upload.
create or replace function public.identity_checks_nas_read()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    if new.kind = 'id' and new.status = 'Pending Review' then
      perform public.identity_read_route(new.id);
    end if;
  exception when others then
    raise warning 'identity_checks_nas_read: %', sqlerrm;
  end;
  return new;
end;
$$;
revoke execute on function public.identity_checks_nas_read() from public, anon, authenticated;
drop trigger if exists trg_identity_checks_nas_read on public.identity_checks;
create trigger trg_identity_checks_nas_read
  after insert on public.identity_checks
  for each row execute function public.identity_checks_nas_read();

-- Whether the NAS has [p_check] queued or in hand (the id-read function then
-- leaves the person's own read to it).
create or replace function public.identity_nas_reading(p_check uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.doc_read_jobs j
                  where j.doc_table = 'identity_checks' and j.doc_id = p_check
                    and j.status in ('queued', 'reading'));
$$;
revoke execute on function public.identity_nas_reading(uuid) from public, anon, authenticated;
grant execute on function public.identity_nas_reading(uuid) to service_role;

-- An ID job the NAS couldn't finish (passed on, failed, skipped, or not
-- claimed in 5 minutes) goes to Google Vision when that is on after the NAS;
-- else what the NAS read, if anything, is kept as it is. Once per job.
create or replace function public.identity_nas_hand_on(p_job uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  j public.doc_read_jobs;
  v_next text := 'none';
  v_seen_nas boolean := false;
  r jsonb;
begin
  update public.doc_read_jobs set handed_on_at = now()
   where id = p_job and doc_table = 'identity_checks' and handed_on_at is null
     and status in ('passed_on', 'failed', 'skipped')
  returning * into j;
  if not found then
    return 'none';
  end if;
  for r in select * from jsonb_array_elements(public.identity_id_readers()) loop
    if r ->> 'id' = 'nas' then
      v_seen_nas := true;
    elsif v_seen_nas and r ->> 'id' = 'vision' and (r ->> 'on')::boolean then
      v_next := 'vision';
    end if;
  end loop;
  if v_next = 'vision' and exists (select 1 from public.identity_checks c
                                     where c.id = j.doc_id and c.status = 'Pending Review') then
    perform public.identity_read_kick(j.doc_id);
    return 'vision';
  end if;
  if j.status = 'passed_on' and jsonb_typeof(j.result -> 'id') = 'object'
     and exists (select 1 from public.identity_checks c where c.id = j.doc_id and c.read_source is null) then
    perform public.identity_check_store_read(j.doc_id, (j.result -> 'id') || '{"source":"nas"}'::jsonb);
    return 'kept';
  end if;
  return 'none';
end;
$$;
revoke execute on function public.identity_nas_hand_on(uuid) from public, anon, authenticated;

-- The sweep (every 2 minutes): ID jobs not claimed in 5 minutes are passed
-- on, and every finished-but-unread one is handed on.
create or replace function public.identity_nas_sweep()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job uuid;
  n integer := 0;
begin
  update public.doc_read_jobs set status = 'passed_on', done_at = now(),
         error = coalesce(error, 'The NAS didn''t read it within 5 minutes')
   where doc_table = 'identity_checks' and status = 'queued' and created_at < now() - interval '5 minutes';
  for v_job in select id from public.doc_read_jobs
                where doc_table = 'identity_checks' and handed_on_at is null
                  and status in ('passed_on', 'failed', 'skipped')
                order by created_at limit 50 loop
    perform public.identity_nas_hand_on(v_job);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.identity_nas_sweep() from public, anon, authenticated;

-- ---- 2. The reader's calls (as 0293, with ID jobs) ----------------------------------------------
-- 5. The heartbeat table every NAS service checks in to (the Overview cards).
create table if not exists public.nas_services (
  service   text primary key,
  last_seen timestamptz,
  status    text,
  detail    jsonb,
  version   text
);
alter table public.nas_services enable row level security;
revoke all on public.nas_services from anon, authenticated;
grant select on public.nas_services to authenticated;
drop policy if exists "nas_services admin read" on public.nas_services;
create policy "nas_services admin read" on public.nas_services
  for select to authenticated using ((select public.caller_is_admin()));

-- As 0293: on while Document reading has the NAS on, or the ID readers do
-- (it then reads IDs only); and the doc-reader's row in nas_services.
create or replace function public.doc_reader_heartbeat(p_key text, p_model text default null, p_app_version text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.doc_readers := public.doc_reader_by_key(p_key);
  v_cfg jsonb := public.document_reading_config();
  v_id_cards boolean := v.kind = 'nas' and public.identity_order_on(public.identity_id_readers(), 'nas');
begin
  update public.doc_readers
     set model = coalesce(left(p_model, 120), model), app_version = coalesce(left(p_app_version, 40), app_version)
   where id = v.id;
  if v.kind = 'nas' then
    begin
      insert into public.nas_services (service, last_seen, status, detail, version)
      values ('doc-reader', now(), 'ok',
              jsonb_build_object('label', v.label, 'model', coalesce(left(p_model, 120), v.model)),
              coalesce(left(p_app_version, 40), v.app_version))
      on conflict (service) do update
        set last_seen = excluded.last_seen, status = excluded.status, detail = excluded.detail,
            version = excluded.version;
    exception when others then
      raise warning 'doc_reader_heartbeat: %', sqlerrm;
    end;
  end if;
  return jsonb_build_object(
    'reader', v.id, 'kind', v.kind, 'label', v.label,
    'on', public.document_reader_on(v.kind) or v_id_cards,
    'jobs', v_cfg -> 'nasJobs',
    'idCards', v_id_cards,
    'passOnBelow', v_cfg -> 'passOnBelow');
end;
$$;

-- As 0293, with ID jobs: claimed first (someone is waiting to sign in),
-- while the NAS is on in the ID readers; document jobs while Document
-- reading has it on.
create or replace function public.doc_reader_claim(p_key text, p_limit integer default 1)
returns setof public.doc_read_jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.doc_readers := public.doc_reader_by_key(p_key);
  v_docs boolean := public.document_reader_on('nas');
  v_ids boolean := public.identity_order_on(public.identity_id_readers(), 'nas');
begin
  if v.kind <> 'nas' or not (v_docs or v_ids) then
    return;
  end if;
  update public.doc_read_jobs set status = 'skipped', done_at = now()
   where status = 'queued' and created_at < now() - interval '1 day';
  update public.doc_read_jobs set status = 'failed', done_at = now(), error = coalesce(error, 'gave up after 3 tries')
   where status = 'reading' and claimed_at < now() - interval '5 minutes' and attempts >= 3;

  return query
  update public.doc_read_jobs j
     set status = 'reading', reader_id = v.id, claimed_at = now(), attempts = j.attempts + 1
   where j.id in (
     select q.id from public.doc_read_jobs q
      where (q.status = 'queued'
             or (q.status = 'reading' and q.claimed_at < now() - interval '5 minutes' and q.attempts < 3))
        and case when q.doc_table = 'identity_checks' then v_ids else v_docs end
      order by (q.doc_table = 'identity_checks') desc, q.created_at
      limit greatest(1, least(coalesce(p_limit, 1), 10))
      for update skip locked)
  returning j.*;
end;
$$;

-- As 0293; an ID job's reading is then kept on the check (sure enough) or
-- handed on (less sure, or failed for good).
create or replace function public.doc_reader_report(
  p_key text, p_id uuid, p_ok boolean, p_result jsonb default null, p_confidence numeric default null,
  p_ms integer default null, p_error text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.doc_readers := public.doc_reader_by_key(p_key);
  v_pass numeric := (public.document_reading_config() ->> 'passOnBelow')::numeric;
  v_conf numeric := greatest(0, least(100, coalesce(p_confidence, 0)));
  v_status text;
  v_table text;
  v_doc uuid;
begin
  if p_result is not null and length(p_result::text) > 20000 then
    p_result := jsonb_build_object('error', 'result too large');
  end if;
  update public.doc_read_jobs
     set status = case
                    when p_ok and v_conf >= v_pass then 'done'
                    when p_ok then 'passed_on'
                    when attempts >= 3 then 'failed'
                    else 'queued' end,
         result = case when p_ok then p_result else result end,
         confidence = case when p_ok then v_conf else confidence end,
         ms = case when p_ok then greatest(0, p_ms) else ms end,
         error = case when p_ok then null else left(p_error, 500) end,
         done_at = case when p_ok or attempts >= 3 then now() else null end,
         reader_id = case when p_ok or attempts >= 3 then reader_id else null end
   where id = p_id and reader_id = v.id and status = 'reading'
  returning status, doc_table, doc_id into v_status, v_table, v_doc;

  if v_table = 'identity_checks' then
    begin
      if v_status = 'done' and jsonb_typeof(p_result -> 'id') = 'object' then
        perform public.identity_check_store_read(v_doc, (p_result -> 'id') || '{"source":"nas"}'::jsonb);
        update public.doc_read_jobs set handed_on_at = now() where id = p_id;
      elsif v_status in ('passed_on', 'failed') then
        perform public.identity_nas_hand_on(p_id);
      end if;
    exception when others then
      raise warning 'doc_reader_report: %', sqlerrm;
    end;
  end if;
  return coalesce(v_status, 'not_yours');
end;
$$;

revoke execute on function public.doc_reader_heartbeat(text, text, text) from public, anon, authenticated;
revoke execute on function public.doc_reader_claim(text, integer) from public, anon, authenticated;
revoke execute on function public.doc_reader_report(text, uuid, boolean, jsonb, numeric, integer, text)
  from public, anon, authenticated;
grant execute on function public.doc_reader_heartbeat(text, text, text) to service_role;
grant execute on function public.doc_reader_claim(text, integer) to service_role;
grant execute on function public.doc_reader_report(text, uuid, boolean, jsonb, numeric, integer, text) to service_role;

-- ---- 3. The in-browser check ----------------------------------------------------------------------
-- The waiting selfie/ID pairs no server has scored, for the admin's browser
-- (the Sign-in checks queue, open in the admin web app). Empty when the
-- in-browser check is off. At most 20, the oldest first.
create or replace function public.identity_face_browser_queue()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.identity_admin_reads() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if not public.identity_order_on(public.identity_face_order(), 'browser') then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', q.id, 'other_id', q.other_id,
                                        'selfie_url', q.selfie_url, 'card_url', q.card_url)
                     order by q.created_at)
      from (
        select c.id, c.created_at, o.id as other_id,
               case when c.kind = 'selfie' then c.file_url else o.file_url end as selfie_url,
               case when c.kind = 'id' then c.file_url else o.file_url end as card_url
          from public.identity_checks c
          cross join lateral (
            select x.id, x.file_url from public.identity_checks x
             where x.user_id = c.user_id and x.kind <> c.kind
               and x.purpose <> 'profile' and x.status is distinct from 'Rejected'
             order by x.created_at desc limit 1) o
         where c.status = 'Pending Review' and c.purpose <> 'profile'
           and (c.face_state is null or c.face_state in ('not_checked', 'error'))
         order by c.created_at
         limit 20) q), '[]'::jsonb);
end;
$$;
revoke execute on function public.identity_face_browser_queue() from public, anon;
grant execute on function public.identity_face_browser_queue() to authenticated;

-- Keeps the browser's score on the check and the one it was compared with
-- (as face-compare keeps a server's on both). Never over a server's score:
-- a check scored by AWS or the NAS keeps it. Returns how many were kept.
create or replace function public.identity_face_browser_save(
  p_id uuid, p_other uuid, p_state text, p_score numeric default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
  n integer;
begin
  if auth.uid() is null or not public.identity_admin_reads()
     or not public.caller_admin_can_write('rpc:identity_face_browser_save') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_state not in ('match', 'no_match', 'no_face')
     or (p_score is not null and (p_score < 0 or p_score > 100))
     or (p_state <> 'no_face' and p_score is null) then
    raise exception 'IDENTITY_BAD_REQUEST' using errcode = '22023';
  end if;
  if not public.identity_order_on(public.identity_face_order(), 'browser') then
    raise exception 'IDENTITY_BROWSER_OFF' using errcode = '22023',
      hint = 'The in-browser check is off in the face match order.';
  end if;
  select user_id into v_user from public.identity_checks where id = p_id;
  if v_user is null then
    raise exception 'IDENTITY_NOT_FOUND' using errcode = '22023';
  end if;
  update public.identity_checks
     set face_state = p_state,
         face_score = case when p_state = 'no_face' then null else round(p_score, 2) end,
         face_provider = 'browser', face_reason = null, face_checked_at = now()
   where id in (p_id, p_other) and user_id = v_user and purpose <> 'profile'
     and (face_state is null or face_state in ('not_checked', 'error') or face_provider = 'browser');
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke execute on function public.identity_face_browser_save(uuid, uuid, text, numeric) from public, anon;
grant execute on function public.identity_face_browser_save(uuid, uuid, text, numeric) to authenticated;

-- ---- 4. Office NAS › ID and face -----------------------------------------------------------------
create or replace function public.admin_nas_id_face()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_day timestamptz := date_trunc('day', now());
begin
  if not public.caller_is_admin() then
    raise exception 'Admins only.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'config', public.dispatch_verify_config(),
    'reader', (select jsonb_build_object('label', r.label, 'model', r.model, 'app_version', r.app_version,
                                         'last_seen_at', r.last_seen_at,
                                         'online', coalesce(r.last_seen_at > now() - interval '3 minutes', false))
                 from public.doc_readers r where r.kind = 'nas'
                order by r.last_seen_at desc nulls last limit 1),
    'reads', (select jsonb_build_object(
                       'done', count(*) filter (where j.status = 'done'),
                       'passed_on', count(*) filter (where j.status = 'passed_on'),
                       'failed', count(*) filter (where j.status = 'failed'),
                       'avg_ms', round(avg(j.ms) filter (where j.status in ('done', 'passed_on')))::int)
                from public.doc_read_jobs j
               where j.doc_table = 'identity_checks' and j.done_at >= v_day),
    'waiting', (select count(*) from public.doc_read_jobs j
                 where j.doc_table = 'identity_checks' and j.status in ('queued', 'reading')),
    'faces', coalesce((select jsonb_object_agg(p, n)
                         from (select c.face_provider as p, count(*) as n from public.identity_checks c
                                where c.face_checked_at >= v_day and c.face_provider is not null
                                group by c.face_provider) t), '{}'::jsonb),
    'closer', (select count(*) from public.identity_checks c
                where c.status = 'Pending Review'
                  and (c.face_state in ('no_match', 'no_face')
                       or (c.face_score is not null and c.face_score < public.identity_face_low_score()))));
end;
$$;
revoke execute on function public.admin_nas_id_face() from public, anon;
grant execute on function public.admin_nas_id_face() to authenticated;

-- ---- Housekeeping --------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'nas-id-read-hand-on';
    perform cron.schedule('nas-id-read-hand-on', '*/2 * * * *', $job$ select public.identity_nas_sweep(); $job$);
  end if;
end $$;

notify pgrst, 'reload schema';
