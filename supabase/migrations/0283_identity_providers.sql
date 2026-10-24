-- ============================================================================
-- 0283 — Sign-in checks: who compares the faces and who reads the card.
--
-- Re-runnable: columns "if not exists", functions "create or replace".
--
-- Why: 0281 compared a selfie with the ID photo on AWS Rekognition only, and
-- only the phone read the MyKad or passport (web and desktop read nothing).
-- The owner wants a choice, and a self-hosted face server (on the office
-- NAS, deploy/face-server) that costs nothing per check.
--
-- 1. Settings, kept with the renewal window in app_settings 'dispatch_verify'
--    (Admin → Dispatch → Accounts, next to "Ask for a new ID"):
--      faceProvider  off | aws (default) | self_hosted | self_hosted_aws
--                    (the self-hosted server, AWS when it fails);
--      idRead        phone (default: the phone reads the card, as before) |
--                    phone_vision (Google Cloud Vision when the phone reads
--                    nothing, and on web and desktop) | vision (always).
--    dispatch_verify_config() returns them, and for an admin who reads the
--    checks whether each service has a key in Admin → API Keys (yes or no,
--    never the key), so the queue says why a face is "Not checked".
--    identity_set_providers() changes them (Dispatch Accounts or Documents).
-- 2. identity_checks keeps who gave the face score (face_provider: aws,
--    self_hosted), why there is none (face_reason), and who read the card
--    (read_source: phone, vision), with a passport's number and when.
-- 3. The check of what was read against the profile is one function now,
--    identity_read_mismatch, used when the phone sends the ID
--    (identity_check_submit) and when the id-read function stores what
--    Google Vision read (identity_check_store_read, service role only).
-- Face scores are help for the admin only: nothing here approves.
-- ============================================================================

-- 2. The columns ------------------------------------------------------------------------------------
alter table public.identity_checks
  add column if not exists face_provider text check (face_provider is null or face_provider in ('aws', 'self_hosted')),
  add column if not exists face_reason   text check (face_reason is null or char_length(face_reason) <= 40),
  add column if not exists read_source   text check (read_source is null or read_source in ('phone', 'vision')),
  add column if not exists read_passport text check (read_passport is null or char_length(read_passport) <= 40),
  add column if not exists read_at       timestamptz;

insert into public.admin_table_pages (target, page) values
  ('rpc:identity_set_providers', 'admin-dispatch-accounts'),
  ('rpc:identity_set_providers', 'admin-documents'),
  ('rpc:identity_set_providers', 'admin-documents-users'),
  ('rpc:identity_set_providers', 'admin-documents-partners')
on conflict do nothing;

-- 1. The settings ---------------------------------------------------------------------------------
create or replace function public.identity_face_provider()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select s.value->>'faceProvider' from public.app_settings s
     where s.key = 'dispatch_verify'
       and s.value->>'faceProvider' in ('off', 'aws', 'self_hosted', 'self_hosted_aws')), 'aws');
$$;
revoke execute on function public.identity_face_provider() from public, anon, authenticated;

create or replace function public.identity_id_read_mode()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select s.value->>'idRead' from public.app_settings s
     where s.key = 'dispatch_verify'
       and s.value->>'idRead' in ('phone', 'phone_vision', 'vision')), 'phone');
$$;
revoke execute on function public.identity_id_read_mode() from public, anon, authenticated;

-- Whether Admin → API Keys has a usable key (on, with a value) for
-- [p_provider]'s [p_service]. Never the key.
create or replace function public.identity_key_ready(p_provider text, p_service text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with v as (
    select case jsonb_typeof(s.value)
             when 'array' then s.value
             when 'object' then case when jsonb_typeof(s.value->'providers') = 'array' then s.value->'providers' end
           end as list
      from public.app_settings s where s.key = 'api_providers'
  )
  select exists (
    select 1
      from v,
           jsonb_array_elements(coalesce(v.list, '[]'::jsonb)) p,
           jsonb_array_elements(case when jsonb_typeof(p->'services') = 'array' then p->'services' else '[]'::jsonb end) sv,
           jsonb_array_elements(case when jsonb_typeof(sv->'keys') = 'array' then sv->'keys' else '[]'::jsonb end) k
     where p->>'id' = p_provider and sv->>'id' = p_service
       and (k->'disabled') is distinct from 'true'::jsonb
       and nullif(btrim(coalesce(k->>'value', '')), '') is not null);
$$;
revoke execute on function public.identity_key_ready(text, text) from public, anon, authenticated;

create or replace function public.dispatch_verify_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('renewDays', public.identity_renew_days(),
                            'faceProvider', public.identity_face_provider(),
                            'idRead', public.identity_id_read_mode())
         || case when public.identity_admin_reads() then jsonb_build_object(
              'awsKey', public.identity_key_ready('aws', 'rekognition'),
              'faceServer', public.identity_key_ready('face_match', 'server'),
              'visionKey', public.identity_key_ready('google', 'vision'))
            else '{}'::jsonb end;
$$;
revoke execute on function public.dispatch_verify_config() from public, anon;
grant execute on function public.dispatch_verify_config() to authenticated;

-- Null leaves a setting as it is.
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
  on conflict (key) do update set value = public.app_settings.value || excluded.value, updated_at = now();
  insert into public.admin_audit_log (actor_id, action, detail)
  values (auth.uid(), 'identity.providers', jsonb_strip_nulls(jsonb_build_object('face', p_face, 'id_read', p_id_read)));
  return public.dispatch_verify_config();
end;
$$;
revoke execute on function public.identity_set_providers(text, text) from public, anon;
grant execute on function public.identity_set_providers(text, text) to authenticated;

-- 3. What was read against the profile ------------------------------------------------------------
-- 'name': a name neither of which contains the other (letters only);
-- 'ic': a different IC number. Nothing read, or nothing on the profile, is
-- no mismatch. As 0281 had it inside identity_check_submit.
create or replace function public.identity_read_mismatch(p_user uuid, p_read_name text, p_read_ic text)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v text[] := '{}';
  v_name text;
  v_ic text;
  v_read text := regexp_replace(lower(coalesce(p_read_name, '')), '[^a-z]', '', 'g');
begin
  select regexp_replace(lower(coalesce(pr.name, '')), '[^a-z]', '', 'g'),
         regexp_replace(coalesce(pr.ic, ''), '[^0-9A-Za-z]', '', 'g')
    into v_name, v_ic
    from public.profiles pr where pr.id = p_user;
  if nullif(btrim(coalesce(p_read_name, '')), '') is not null and coalesce(v_name, '') <> '' then
    if strpos(v_read, v_name) = 0 and strpos(v_name, v_read) = 0 then
      v := array_append(v, 'name');
    end if;
  end if;
  if nullif(btrim(coalesce(p_read_ic, '')), '') is not null and coalesce(v_ic, '') <> ''
     and upper(regexp_replace(p_read_ic, '[^0-9A-Za-z]', '', 'g')) <> upper(v_ic) then
    v := array_append(v, 'ic');
  end if;
  return v;
end;
$$;
revoke execute on function public.identity_read_mismatch(uuid, text, text) from public, anon, authenticated;

-- As 0281, with the mismatch check above and read_source 'phone' when the
-- phone read something.
create or replace function public.identity_check_submit(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_kind text := p->>'kind';
  v_purpose text := coalesce(nullif(p->>'purpose', ''), 'first');
  v_file text := nullif(btrim(coalesce(p->>'file_url', '')), '');
  v_back text := nullif(btrim(coalesce(p->>'file_url_back', '')), '');
  v_doc text := nullif(p->>'doc_type', '');
  v_live text := coalesce(nullif(p->>'liveness', ''), 'not_checked');
  v_device text := nullif(left(btrim(coalesce(p->>'device', '')), 128), '');
  v_read_name text := nullif(left(btrim(coalesce(p->>'read_name', '')), 120), '');
  v_read_ic text := nullif(left(btrim(coalesce(p->>'read_ic', '')), 40), '');
  v_read_expiry date;
  v_expiry date;
  v_bucket text;
  v_mismatch text[] := '{}';
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_kind not in ('selfie', 'id') or v_purpose not in ('first', 'recheck', 'profile')
     or (v_kind = 'id' and v_purpose <> 'first') then
    raise exception 'IDENTITY_BAD_REQUEST' using errcode = '22023';
  end if;
  v_bucket := case when v_purpose = 'profile' then 'avatars' else 'ID_Image' end;
  if v_file is null or strpos(v_file, '/' || v_bucket || '/' || v_uid::text || '/') = 0
     or (v_back is not null and strpos(v_back, '/' || v_bucket || '/' || v_uid::text || '/') = 0) then
    raise exception 'IDENTITY_FILE' using errcode = '22023', hint = 'Upload the photo again.';
  end if;
  if v_kind = 'id' and (v_doc is null or v_doc not in ('mykad', 'passport') or v_back is null) then
    raise exception 'IDENTITY_ID_SIDES' using errcode = '22023', hint = 'Add the front and the back.';
  end if;
  if v_live not in ('passed', 'not_checked') then
    v_live := 'not_checked';
  end if;
  begin
    v_read_expiry := nullif(p->>'read_expiry', '')::date;
    v_expiry := nullif(p->>'expiry_date', '')::date;
  exception when others then
    raise exception 'IDENTITY_DATE' using errcode = '22023', hint = 'Check the expiry date.';
  end;
  if v_kind = 'id' and v_doc = 'passport' and v_expiry is null then
    raise exception 'IDENTITY_EXPIRY' using errcode = '22023', hint = 'Add the passport''s expiry date.';
  end if;
  if v_expiry is not null and v_expiry < current_date then
    raise exception 'IDENTITY_EXPIRED' using errcode = '22023', hint = 'This ID has run out. Use one that is still valid.';
  end if;
  if (select count(*) from public.identity_checks
       where user_id = v_uid and created_at > now() - interval '1 day') >= 20 then
    raise exception 'IDENTITY_TOO_MANY' using errcode = '22023', hint = 'Too many photos today. Try again tomorrow.';
  end if;

  if v_kind = 'id' then
    v_mismatch := public.identity_read_mismatch(v_uid, v_read_name, v_read_ic);
  end if;

  insert into public.identity_checks (user_id, kind, purpose, doc_type, file_url, file_url_back, liveness,
    liveness_detail, device_key, read_name, read_ic, read_expiry, expiry_date, mismatch, status,
    read_source, read_at)
  values (v_uid, v_kind, v_purpose, case when v_kind = 'id' then v_doc end, v_file,
    case when v_kind = 'id' then v_back end,
    case when v_kind = 'selfie' then v_live end,
    case when v_kind = 'selfie' then nullif(left(coalesce(p->>'liveness_detail', ''), 40), '') end,
    v_device,
    case when v_kind = 'id' then v_read_name end, case when v_kind = 'id' then v_read_ic end,
    case when v_kind = 'id' then v_read_expiry end, case when v_kind = 'id' then v_expiry end,
    v_mismatch, case when v_purpose = 'profile' then null else 'Pending Review' end,
    case when v_kind = 'id' and coalesce(v_read_name, v_read_ic, v_read_expiry::text) is not null then 'phone' end,
    case when v_kind = 'id' and coalesce(v_read_name, v_read_ic, v_read_expiry::text) is not null then now() end)
  returning id into v_id;

  -- A selfie taken on a phone makes it known.
  if v_kind = 'selfie' and v_purpose <> 'profile' and v_device is not null and char_length(v_device) >= 8 then
    insert into public.dispatch_devices (user_id, device_key, known, check_id, seen_at)
    values (v_uid, v_device, true, v_id, clock_timestamp())
    on conflict (user_id, device_key) do update set known = true, check_id = excluded.check_id,
      seen_at = clock_timestamp();
  end if;
  if v_purpose <> 'profile' then
    perform public.identity_notify_admins(v_id);
  end if;
  return jsonb_build_object('id', v_id, 'mismatch', to_jsonb(v_mismatch));
end;
$$;
revoke execute on function public.identity_check_submit(jsonb) from public, anon;
grant execute on function public.identity_check_submit(jsonb) to authenticated;

-- The id-read function: what Google Vision read off an ID's front, kept on
-- the check (what it couldn't read keeps the phone's), and the mismatch
-- checked again. The function decides who may ask; this is its write.
--   p: { name?, ic?, passport?, expiry? (yyyy-mm-dd) }
-- Returns { id, read_name, read_ic, read_passport, read_expiry, mismatch }.
create or replace function public.identity_check_store_read(p_id uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.identity_checks;
  v_expiry date;
begin
  begin
    v_expiry := nullif(p->>'expiry', '')::date;
  exception when others then
    v_expiry := null;
  end;
  update public.identity_checks set
    read_name = coalesce(nullif(left(btrim(coalesce(p->>'name', '')), 120), ''), read_name),
    read_ic = coalesce(nullif(left(btrim(coalesce(p->>'ic', '')), 40), ''), read_ic),
    read_passport = coalesce(nullif(left(btrim(coalesce(p->>'passport', '')), 40), ''), read_passport),
    read_expiry = coalesce(v_expiry, read_expiry),
    read_source = 'vision',
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
                            'mismatch', to_jsonb(c.mismatch));
end;
$$;
revoke execute on function public.identity_check_store_read(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.identity_check_store_read(uuid, jsonb) to service_role;

notify pgrst, 'reload schema';

insert into supabase_migrations.schema_migrations (version, name)
values ('20261024130000', '0283_identity_providers')
on conflict do nothing;
