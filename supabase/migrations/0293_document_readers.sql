-- ============================================================================
-- 0293: document reading — who reads, in what order, and the office NAS.
--
-- Admin -> Settings -> Document reading lists the readers in order, each with
-- an on/off switch:
--   phone  the driver's phone reads the photo at upload (free, instant)
--   nas    the office NAS reads plates and document numbers in the background
--   gpu    a GPU reading PC reads whole documents (listed once one is paired)
--   cloud  Google Cloud Vision / the vision AI set in API Keys
-- Each reader does what it can and passes the rest on.
--
-- A NAS (or GPU PC) pairs like the SMS gateway phone (0190): a full admin
-- makes a code good for 10 minutes, the reader trades it once for a key of
-- its own, and only the key's hash is kept. The reader only ever calls out
-- (the doc-reader edge function), so no ports are opened at the office.
--
-- When a partner or vehicle document's photo is saved and a NAS is paired
-- and on, a reading job is queued per side. The NAS claims jobs, reads them
-- and reports what it read and how sure it is; below the admin's "pass on"
-- percentage the job is marked passed on, for the next reader.
-- ============================================================================

-- ---- Settings ------------------------------------------------------------------------------
-- app_settings 'document_reading':
--   readers      [{id, on}] in reading order; every known reader once
--   nasJobs      {plates, numbers, qr, checks}: what the NAS reads
--   passOnBelow  50..100: a NAS reading less sure than this is passed on
create or replace function public.document_reading_normalize(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_known constant text[] := array['phone', 'nas', 'gpu', 'cloud'];
  v_seen text[] := '{}';
  v_readers jsonb := '[]'::jsonb;
  v_r jsonb;
  v_id text;
  v_jobs jsonb := coalesce(p -> 'nasJobs', '{}'::jsonb);
  v_pass numeric;
begin
  if jsonb_typeof(p -> 'readers') = 'array' then
    for v_r in select * from jsonb_array_elements(p -> 'readers') loop
      v_id := v_r ->> 'id';
      if v_id = any(v_known) and not v_id = any(v_seen) then
        v_seen := v_seen || v_id;
        v_readers := v_readers || jsonb_build_object('id', v_id, 'on', coalesce((v_r ->> 'on')::boolean, true));
      end if;
    end loop;
  end if;
  -- A reader missing from the saved list joins at the end, on.
  foreach v_id in array v_known loop
    if not v_id = any(v_seen) then
      v_readers := v_readers || jsonb_build_object('id', v_id, 'on', true);
    end if;
  end loop;

  v_pass := case when (p ->> 'passOnBelow') ~ '^\d+(\.\d+)?$' then (p ->> 'passOnBelow')::numeric end;
  return jsonb_build_object(
    'readers', v_readers,
    'nasJobs', jsonb_build_object(
      'plates',  coalesce((v_jobs ->> 'plates')::boolean, true),
      'numbers', coalesce((v_jobs ->> 'numbers')::boolean, true),
      'qr',      coalesce((v_jobs ->> 'qr')::boolean, true),
      'checks',  coalesce((v_jobs ->> 'checks')::boolean, true)),
    'passOnBelow', greatest(50, least(100, round(coalesce(v_pass, 90)))));
end;
$$;
revoke execute on function public.document_reading_normalize(jsonb) from public, anon, authenticated;

-- The settings as everyone reads them (the app needs the order and switches).
create or replace function public.document_reading_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.document_reading_normalize(
    coalesce((select value from public.app_settings where key = 'document_reading'), '{}'::jsonb));
$$;
revoke execute on function public.document_reading_config() from public, anon;
grant execute on function public.document_reading_config() to authenticated;

-- Whether a reader is switched on.
create or replace function public.document_reader_on(p_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select (r ->> 'on')::boolean
                     from jsonb_array_elements(public.document_reading_config() -> 'readers') r
                    where r ->> 'id' = p_id), false);
$$;
revoke execute on function public.document_reader_on(text) from public, anon, authenticated;

create or replace function public.admin_document_reading_set(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := public.document_reading_normalize(coalesce(p, '{}'::jsonb));
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_document_reading_set') then
    raise exception 'You can''t change document reading.' using errcode = '42501';
  end if;
  insert into public.app_settings (key, value) values ('document_reading', v)
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return v;
end;
$$;
revoke execute on function public.admin_document_reading_set(jsonb) from public, anon;
grant execute on function public.admin_document_reading_set(jsonb) to authenticated;

-- ---- Readers, keys and pairing codes -------------------------------------------------------
create table if not exists public.doc_readers (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('nas', 'gpu')),
  label        text not null,
  device_id    text not null,
  model        text,
  app_version  text,
  key_hash     text not null unique,
  paired_by    uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz,
  unique (kind, device_id)
);
alter table public.doc_readers enable row level security;
revoke all on public.doc_readers from anon, authenticated;

create table if not exists public.doc_reader_pairings (
  id          uuid primary key default gen_random_uuid(),
  code_hash   text not null unique,
  kind        text not null check (kind in ('nas', 'gpu')),
  label       text,
  created_by  uuid not null references auth.users(id) on delete cascade,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  reader_id   uuid references public.doc_readers(id) on delete set null,
  created_at  timestamptz not null default now()
);
alter table public.doc_reader_pairings enable row level security;
revoke all on public.doc_reader_pairings from anon, authenticated;

create table if not exists public.doc_reader_pair_failures (
  at timestamptz not null default now()
);
create index if not exists doc_reader_pair_failures_at_idx on public.doc_reader_pair_failures (at);
alter table public.doc_reader_pair_failures enable row level security;
revoke all on public.doc_reader_pair_failures from anon, authenticated;

-- ---- The reading queue ---------------------------------------------------------------------
create table if not exists public.doc_read_jobs (
  id          uuid primary key default gen_random_uuid(),
  doc_table   text not null check (doc_table in ('provider_documents', 'vehicle_documents')),
  doc_id      uuid not null,
  side        text not null check (side in ('front', 'back')),
  file_url    text not null,
  doc_name    text,
  wants       text[] not null,
  status      text not null default 'queued'
              check (status in ('queued', 'reading', 'done', 'passed_on', 'failed', 'skipped')),
  reader_id   uuid references public.doc_readers(id) on delete set null,
  attempts    integer not null default 0,
  claimed_at  timestamptz,
  result      jsonb,
  confidence  numeric(5, 2),
  ms          integer,
  error       text,
  created_at  timestamptz not null default now(),
  done_at     timestamptz,
  unique (doc_table, doc_id, side, file_url)
);
create index if not exists doc_read_jobs_waiting_idx on public.doc_read_jobs (created_at) where status in ('queued', 'reading');
create index if not exists doc_read_jobs_done_idx on public.doc_read_jobs (done_at) where done_at is not null;
alter table public.doc_read_jobs enable row level security;
revoke all on public.doc_read_jobs from anon, authenticated;

-- What the NAS is asked to read on a document: plates on vehicle documents,
-- numbers on all, QR codes when on. ("checks" is for invoices, not these.)
create or replace function public.doc_read_wants(p_table text)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(x.w order by x.w), '{}')
    from (select public.document_reading_config() -> 'nasJobs' as j) c,
         lateral (
           select 'plates' as w where p_table = 'vehicle_documents' and (c.j ->> 'plates')::boolean
           union all select 'numbers' where (c.j ->> 'numbers')::boolean
           union all select 'qr' where (c.j ->> 'qr')::boolean
         ) x;
$$;
revoke execute on function public.doc_read_wants(text) from public, anon, authenticated;

-- A saved photo is queued for the NAS when one is paired and switched on.
-- Never stands in the way of the save.
create or replace function public.doc_read_enqueue()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wants text[];
begin
  begin
    if not public.document_reader_on('nas')
       or not exists (select 1 from public.doc_readers where kind = 'nas') then
      return new;
    end if;
    v_wants := public.doc_read_wants(tg_table_name);
    if coalesce(array_length(v_wants, 1), 0) = 0 then
      return new;
    end if;
    if coalesce(new.file_url, '') <> ''
       and (tg_op = 'INSERT' or new.file_url is distinct from old.file_url) then
      insert into public.doc_read_jobs (doc_table, doc_id, side, file_url, doc_name, wants)
      values (tg_table_name, new.id, 'front', new.file_url, new.doc_name, v_wants)
      on conflict do nothing;
    end if;
    if coalesce(new.file_url_back, '') <> ''
       and (tg_op = 'INSERT' or new.file_url_back is distinct from old.file_url_back) then
      insert into public.doc_read_jobs (doc_table, doc_id, side, file_url, doc_name, wants)
      values (tg_table_name, new.id, 'back', new.file_url_back, new.doc_name, v_wants)
      on conflict do nothing;
    end if;
  exception when others then
    raise warning 'doc_read_enqueue: %', sqlerrm;
  end;
  return new;
end;
$$;
revoke execute on function public.doc_read_enqueue() from public, anon, authenticated;

drop trigger if exists provider_documents_read_enqueue on public.provider_documents;
create trigger provider_documents_read_enqueue
  after insert or update of file_url, file_url_back on public.provider_documents
  for each row execute function public.doc_read_enqueue();
drop trigger if exists vehicle_documents_read_enqueue on public.vehicle_documents;
create trigger vehicle_documents_read_enqueue
  after insert or update of file_url, file_url_back on public.vehicle_documents
  for each row execute function public.doc_read_enqueue();

-- ---- The admin pairs and removes readers ---------------------------------------------------
create or replace function public.admin_doc_reader_pairing_code(p_kind text default 'nas', p_label text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_bytes bytea := extensions.gen_random_bytes(8);
  v_code text := '';
  v_expires timestamptz := now() + interval '10 minutes';
begin
  -- A reader sees ID cards and licences: only a full admin connects one.
  if not public.caller_is_full_admin() then
    raise exception 'Only a full admin can connect a document reader.' using errcode = '42501';
  end if;
  if p_kind not in ('nas', 'gpu') then
    raise exception 'Unknown reader kind.' using errcode = '22023';
  end if;
  for i in 0..7 loop
    v_code := v_code || substr(v_alphabet, 1 + (get_byte(v_bytes, i) % length(v_alphabet)), 1);
  end loop;
  delete from public.doc_reader_pairings where created_by = auth.uid() and used_at is null;
  insert into public.doc_reader_pairings (code_hash, kind, label, created_by, expires_at)
  values (public.gateway_secret_hash(v_code), p_kind,
          nullif(left(btrim(coalesce(p_label, '')), 80), ''), auth.uid(), v_expires);
  return jsonb_build_object('code', substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4), 'expires_at', v_expires);
end;
$$;
revoke execute on function public.admin_doc_reader_pairing_code(text, text) from public, anon;
grant execute on function public.admin_doc_reader_pairing_code(text, text) to authenticated;

create or replace function public.admin_doc_reader_remove(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_is_full_admin() then
    raise exception 'Only a full admin can disconnect a document reader.' using errcode = '42501';
  end if;
  -- Its key goes with it; waiting jobs go back to the queue.
  update public.doc_read_jobs set status = 'queued', reader_id = null
   where reader_id = p_id and status = 'reading';
  delete from public.doc_readers where id = p_id;
end;
$$;
revoke execute on function public.admin_doc_reader_remove(uuid) from public, anon;
grant execute on function public.admin_doc_reader_remove(uuid) to authenticated;

-- The readers with today's work, for the admin page. Online = heard from in
-- the last 3 minutes (a reader checks in every minute).
create or replace function public.admin_doc_readers()
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
    'waiting', (select count(*) from public.doc_read_jobs where status in ('queued', 'reading')),
    'readers', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', r.id, 'kind', r.kind, 'label', r.label, 'model', r.model,
               'app_version', r.app_version, 'created_at', r.created_at, 'last_seen_at', r.last_seen_at,
               'online', coalesce(r.last_seen_at > now() - interval '3 minutes', false),
               'today', coalesce((
                 select jsonb_object_agg(w, jsonb_build_object(
                          'done', n_done, 'passed_on', n_passed, 'failed', n_failed, 'avg_ms', avg_ms))
                   from (
                     select w,
                            count(*) filter (where j.status = 'done') as n_done,
                            count(*) filter (where j.status = 'passed_on') as n_passed,
                            count(*) filter (where j.status = 'failed') as n_failed,
                            round(avg(j.ms) filter (where j.status in ('done', 'passed_on')))::int as avg_ms
                       from public.doc_read_jobs j, unnest(j.wants) w
                      where j.reader_id = r.id and j.done_at >= v_day
                      group by w
                   ) t), '{}'::jsonb))
             order by r.created_at)
        from public.doc_readers r), '[]'::jsonb));
end;
$$;
revoke execute on function public.admin_doc_readers() from public, anon;
grant execute on function public.admin_doc_readers() to authenticated;

-- ---- The reader's calls (through the doc-reader edge function only) ------------------------
create or replace function public.doc_reader_pair(
  p_code text, p_device_id text, p_label text default null, p_model text default null,
  p_app_version text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_pair public.doc_reader_pairings;
  v_reader public.doc_readers;
  v_key text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  if (select count(*) from public.doc_reader_pair_failures where at > now() - interval '10 minutes') >= 20 then
    return jsonb_build_object('error', 'READER_PAIR_BUSY',
      'hint', 'Too many wrong codes. Wait 10 minutes and try again.');
  end if;
  if coalesce(btrim(p_device_id), '') = '' then
    return jsonb_build_object('error', 'READER_PAIR_DEVICE', 'hint', 'The reader sent no device id.');
  end if;

  select * into v_pair from public.doc_reader_pairings
   where code_hash = public.gateway_secret_hash(v_code) and used_at is null and expires_at > now()
   for update;
  if not found then
    insert into public.doc_reader_pair_failures default values;
    return jsonb_build_object('error', 'READER_PAIR_CODE',
      'hint', 'That code is wrong or has expired. Make a new one in Admin -> Settings -> Document reading.');
  end if;

  insert into public.doc_readers (kind, label, device_id, model, app_version, key_hash, paired_by, last_seen_at)
  values (v_pair.kind,
          coalesce(v_pair.label, nullif(left(btrim(coalesce(p_label, '')), 80), ''),
                   case v_pair.kind when 'nas' then 'Office NAS' else 'GPU reading PC' end),
          left(p_device_id, 200), left(p_model, 120), left(p_app_version, 40),
          public.gateway_secret_hash(v_key), v_pair.created_by, now())
  on conflict (kind, device_id) do update
     set label = coalesce(v_pair.label, public.doc_readers.label),
         model = coalesce(excluded.model, public.doc_readers.model),
         app_version = excluded.app_version,
         key_hash = excluded.key_hash,
         paired_by = excluded.paired_by,
         last_seen_at = now()
  returning * into v_reader;

  update public.doc_reader_pairings set used_at = now(), reader_id = v_reader.id where id = v_pair.id;
  return jsonb_build_object('key', v_key, 'reader', v_reader.id, 'kind', v_reader.kind, 'label', v_reader.label);
end;
$$;

-- The reader a key belongs to; refuses an unknown (or removed) key.
create or replace function public.doc_reader_by_key(p_key text)
returns public.doc_readers
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.doc_readers;
begin
  update public.doc_readers set last_seen_at = now()
   where key_hash = public.gateway_secret_hash(p_key)
  returning * into v;
  if not found then
    raise exception 'READER_KEY_INVALID' using errcode = '42501',
      hint = 'This reader is no longer connected. Connect it again from Admin -> Settings -> Document reading.';
  end if;
  return v;
end;
$$;

-- Check-in: what to read and how often to ask.
create or replace function public.doc_reader_heartbeat(p_key text, p_model text default null, p_app_version text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.doc_readers := public.doc_reader_by_key(p_key);
  v_cfg jsonb := public.document_reading_config();
begin
  update public.doc_readers
     set model = coalesce(left(p_model, 120), model), app_version = coalesce(left(p_app_version, 40), app_version)
   where id = v.id;
  return jsonb_build_object(
    'reader', v.id, 'kind', v.kind, 'label', v.label,
    'on', public.document_reader_on(v.kind),
    'jobs', v_cfg -> 'nasJobs',
    'passOnBelow', v_cfg -> 'passOnBelow');
end;
$$;

-- Up to p_limit jobs for this reader. A job stuck "reading" for 5 minutes is
-- given out again; after 3 tries it fails. Jobs a day old are skipped.
create or replace function public.doc_reader_claim(p_key text, p_limit integer default 1)
returns setof public.doc_read_jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.doc_readers := public.doc_reader_by_key(p_key);
begin
  if v.kind <> 'nas' or not public.document_reader_on('nas') then
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
      where q.status = 'queued'
         or (q.status = 'reading' and q.claimed_at < now() - interval '5 minutes' and q.attempts < 3)
      order by q.created_at
      limit greatest(1, least(coalesce(p_limit, 1), 10))
      for update skip locked)
  returning j.*;
end;
$$;

-- What the reader read. p_result: {plates: [..], numbers: [..], qr: [..], text}
-- and p_confidence 0..100. Less sure than passOnBelow: passed on.
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
  returning status into v_status;
  return coalesce(v_status, 'not_yours');
end;
$$;

-- Only the doc-reader edge function (service role) calls these.
revoke execute on function public.doc_reader_pair(text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.doc_reader_by_key(text) from public, anon, authenticated;
revoke execute on function public.doc_reader_heartbeat(text, text, text) from public, anon, authenticated;
revoke execute on function public.doc_reader_claim(text, integer) from public, anon, authenticated;
revoke execute on function public.doc_reader_report(text, uuid, boolean, jsonb, numeric, integer, text)
  from public, anon, authenticated;
grant execute on function public.doc_reader_pair(text, text, text, text, text) to service_role;
grant execute on function public.doc_reader_heartbeat(text, text, text) to service_role;
grant execute on function public.doc_reader_claim(text, integer) to service_role;
grant execute on function public.doc_reader_report(text, uuid, boolean, jsonb, numeric, integer, text) to service_role;

-- ---- Who may change the settings -----------------------------------------------------------
insert into public.admin_table_pages (target, page) values
  ('rpc:admin_document_reading_set', 'admin-settings-document-reading')
on conflict do nothing;

-- ---- Housekeeping --------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'purge-doc-reading';
    perform cron.schedule('purge-doc-reading', '23 * * * *', $job$
      delete from public.doc_reader_pairings where expires_at < now() - interval '1 day';
      delete from public.doc_reader_pair_failures where at < now() - interval '1 day';
      delete from public.doc_read_jobs where created_at < now() - interval '30 days';
    $job$);
  end if;
end $$;

notify pgrst, 'reload schema';

insert into supabase_migrations.schema_migrations (version, name)
values ('20261025200000', '0293_document_readers')
on conflict (version) do nothing;
