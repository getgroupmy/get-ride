-- ============================================================================
-- 0439 GET eKYC: the identity check run by our own eKYC server
--
-- Why: get.ekyc (the office Mac mini, ekyc.getride.my) runs the whole ID
-- check itself: consent, the ID's front and back, a selfie with head turns
-- (liveness), reading the card, matching the face, sanctions screening. The
-- app shows its page inside the app (never the external browser) and our
-- server receives the signed result. This lands it as ordinary
-- identity_checks rows, so admins review it in the same places as today and
-- the rider auto-verify rule (0343) works unchanged.
--
-- Off until an admin turns it on, per use:
--   riderGate   the rider ID check before booking (0342) instead of the
--               photo + selfie flow;
--   dispatchId  the ID step of the dispatch sign-in checks (0281); the
--               selfie step stays, as it registers the phone.
-- GET eKYC never rejects anyone here: its verdict and reasons are shown to
-- the admin, and a rider is auto-verified only when GET eKYC approved AND
-- the face score meets the country's autoVerifyScore (0343).
--
-- 1. identity_checks accepts GET eKYC rows; GET eKYC's verdict on the row.
-- 2. ekyc_sessions: one per verification started from the app.
-- 3. Settings (app_settings 'ekyc'): ekyc_config(), set_ekyc_config().
-- 4. ekyc_apply(): the webhook's result written as checks (service role).
-- 5. The NAS / Vision reader skips GET eKYC rows (they are read already).
--
-- Re-runnable. supabase/tests/get_ekyc_0439.sql covers it.
-- ============================================================================

-- 1. identity_checks ------------------------------------------------------------------------------
alter table public.identity_checks drop constraint if exists identity_checks_read_source_check;
alter table public.identity_checks add constraint identity_checks_read_source_check
  check (read_source is null or read_source in ('phone', 'vision', 'nas', 'ekyc'));
alter table public.identity_checks drop constraint if exists identity_checks_face_provider_check;
alter table public.identity_checks add constraint identity_checks_face_provider_check
  check (face_provider is null or face_provider in ('aws', 'self_hosted', 'browser', 'ekyc'));
-- A national ID card that is not a MyKad (MyPR, MyTentera, a foreign ID card).
alter table public.identity_checks drop constraint if exists identity_checks_doc_type_check;
alter table public.identity_checks add constraint identity_checks_doc_type_check
  check (doc_type is null or doc_type in ('mykad', 'passport', 'id_card'));

alter table public.identity_checks
  add column if not exists ekyc_verification text
    check (ekyc_verification is null or ekyc_verification ~ '^ver_[0-9a-f]{8,40}$'),
  add column if not exists ekyc_status text
    check (ekyc_status is null or ekyc_status in ('approved', 'review', 'rejected')),
  add column if not exists ekyc_reasons text[] not null default '{}';

-- 2. Sessions -----------------------------------------------------------------------------------------
create table if not exists public.ekyc_sessions (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles(id) on delete cascade,
  purpose         text not null check (purpose in ('rider_gate', 'first')),
  verification_id text not null unique check (verification_id ~ '^ver_[0-9a-f]{8,40}$'),
  test            boolean not null default false,
  state           text not null default 'started' check (state in ('started', 'completed', 'failed')),
  ekyc_status     text check (ekyc_status is null or ekyc_status in ('approved', 'review', 'rejected')),
  check_id        uuid references public.identity_checks(id) on delete set null,
  error           text check (error is null or char_length(error) <= 300),
  created_at      timestamptz not null default now(),
  completed_at    timestamptz
);
create index if not exists ekyc_sessions_user_idx on public.ekyc_sessions (user_id, created_at desc);
create index if not exists ekyc_sessions_check_idx on public.ekyc_sessions (check_id);

alter table public.ekyc_sessions enable row level security;
revoke insert, update, delete on public.ekyc_sessions from anon, authenticated;
drop policy if exists ekyc_sessions_read on public.ekyc_sessions;
create policy ekyc_sessions_read on public.ekyc_sessions
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.identity_admin_reads()));

-- 3. Settings -----------------------------------------------------------------------------------------
-- { on, riderGate, dispatchId, test } with defaults; admins also see whether
-- the server address/key and the webhook secret are in Admin → API Keys.
create or replace function public.ekyc_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb := coalesce((select value from public.app_settings where key = 'ekyc'), '{}'::jsonb);
  v_out jsonb;
begin
  v_out := jsonb_build_object(
    'on', coalesce((v->>'on')::boolean, false),
    'riderGate', coalesce((v->>'riderGate')::boolean, false),
    'dispatchId', coalesce((v->>'dispatchId')::boolean, false),
    'test', coalesce((v->>'test')::boolean, false));
  if auth.uid() is not null and public.identity_admin_reads() then
    v_out := v_out || jsonb_build_object(
      'serverKey', public.identity_key_ready('ekyc', 'server'),
      'webhookKey', public.identity_key_ready('ekyc', 'webhook'));
  end if;
  return v_out;
end;
$$;
revoke execute on function public.ekyc_config() from public, anon;
grant execute on function public.ekyc_config() to authenticated, service_role;

-- Whether GET eKYC runs [p_purpose] ('rider_gate' | 'first') now.
create or replace function public.ekyc_in_use(p_purpose text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((c->>'on')::boolean, false)
         and case p_purpose when 'rider_gate' then coalesce((c->>'riderGate')::boolean, false)
                            when 'first' then coalesce((c->>'dispatchId')::boolean, false)
                            else false end
    from (select coalesce((select value from public.app_settings where key = 'ekyc'), '{}'::jsonb) as c) s;
$$;
revoke execute on function public.ekyc_in_use(text) from public, anon;
grant execute on function public.ekyc_in_use(text) to authenticated, service_role;

create or replace function public.set_ekyc_config(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old jsonb := coalesce((select value from public.app_settings where key = 'ekyc'), '{}'::jsonb);
  v_new jsonb := '{}'::jsonb;
  k text;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:set_ekyc_config') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if jsonb_typeof(p) is distinct from 'object' then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  foreach k in array array['on', 'riderGate', 'dispatchId', 'test'] loop
    if p ? k then
      if jsonb_typeof(p->k) is distinct from 'boolean' then
        raise exception 'EKYC_BAD_SETTING' using errcode = '22023', hint = k || ' must be true or false';
      end if;
      v_new := v_new || jsonb_build_object(k, p->k);
    end if;
  end loop;
  insert into public.app_settings (key, value, updated_at) values ('ekyc', v_old || v_new, now())
  on conflict (key) do update set value = public.app_settings.value || excluded.value, updated_at = now();
  insert into public.admin_audit_log (actor_id, action, detail)
  values (auth.uid(), 'identity.ekyc', v_new);
  return public.ekyc_config();
end;
$$;
revoke execute on function public.set_ekyc_config(jsonb) from public, anon;
grant execute on function public.set_ekyc_config(jsonb) to authenticated;

insert into public.admin_table_pages (target, page) values
  ('rpc:set_ekyc_config', 'admin-dispatch-accounts'),
  ('rpc:set_ekyc_config', 'admin-documents'),
  ('rpc:set_ekyc_config', 'admin-documents-users'),
  ('rpc:set_ekyc_config', 'admin-documents-partners')
on conflict do nothing;

-- 4. The result -------------------------------------------------------------------------------------
-- p (built by the ekyc-webhook function from GET eKYC's answer):
--   { status: 'approved'|'review'|'rejected', reasons: [codes],
--     doc_type: 'mykad'|'passport'|'id_card',
--     front, back?, selfie?   ID_Image paths the function copied the photos to,
--     read: { name, ic, passport, birth, expiry, nationality, gender, address },
--     face: { score 0..100, state 'match'|'no_match'|'no_face'|'not_checked' },
--     liveness: 'passed'|'not_checked' }
-- Writes the ID check (and, for riders, the selfie check) as 'Pending Review',
-- then lets the rider rule auto-verify when GET eKYC approved. Returns
-- { check_id, verified, pending }. Running it twice for a session is harmless.
create or replace function public.ekyc_apply(p_session uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.ekyc_sessions;
  v_read jsonb := coalesce(p->'read', '{}'::jsonb);
  v_status text := p->>'status';
  v_reasons text[] := coalesce(array(select jsonb_array_elements_text(coalesce(p->'reasons', '[]'::jsonb))), '{}');
  v_doc text := nullif(p->>'doc_type', '');
  v_front text := nullif(p->>'front', '');
  v_back text := nullif(p->>'back', '');
  v_selfie text := nullif(p->>'selfie', '');
  v_score numeric := nullif(p#>>'{face,score}', '')::numeric;
  v_face text := nullif(p#>>'{face,state}', '');
  v_live text := case p->>'liveness' when 'passed' then 'passed' else 'not_checked' end;
  v_check uuid;
  v_applied jsonb := jsonb_build_object('verified', false, 'pending', true);
  v_paths_ok boolean;
begin
  select * into s from public.ekyc_sessions where id = p_session for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if s.state = 'completed' then
    return jsonb_build_object('check_id', s.check_id, 'verified', false, 'pending', false, 'repeat', true);
  end if;
  if v_status is null or v_status not in ('approved', 'review', 'rejected') then
    raise exception 'EKYC_BAD_RESULT' using errcode = '22023', hint = 'status';
  end if;
  if v_front is null or v_front !~ ('^' || s.user_id::text || '/') then
    raise exception 'EKYC_BAD_RESULT' using errcode = '22023', hint = 'front photo';
  end if;
  v_paths_ok := (v_back is null or v_back ~ ('^' || s.user_id::text || '/'))
                 and (v_selfie is null or v_selfie ~ ('^' || s.user_id::text || '/'));
  if not v_paths_ok then
    raise exception 'EKYC_BAD_RESULT' using errcode = '22023', hint = 'photo path';
  end if;
  if v_doc is not null and v_doc not in ('mykad', 'passport', 'id_card') then
    v_doc := null;
  end if;
  if v_face is not null and v_face not in ('match', 'no_match', 'no_face', 'not_checked') then
    v_face := 'not_checked';
  end if;
  if v_score is not null and (v_score < 0 or v_score > 100) then
    v_score := null;
  end if;

  insert into public.identity_checks (
    user_id, kind, purpose, doc_type, file_url, file_url_back, liveness, liveness_detail,
    read_name, read_ic, read_passport, read_birth, read_expiry, expiry_date, read_nationality, read_gender, read_address,
    read_source, read_at, mismatch, face_score, face_state, face_provider, face_checked_at,
    status, ekyc_verification, ekyc_status, ekyc_reasons)
  values (
    s.user_id, 'id', s.purpose, v_doc, v_front, v_back, v_live, case when v_live = 'passed' then 'turn' end,
    left(nullif(btrim(v_read->>'name'), ''), 120),
    left(nullif(btrim(v_read->>'ic'), ''), 40),
    left(nullif(btrim(v_read->>'passport'), ''), 40),
    case when v_read->>'birth' ~ '^\d{4}-\d{2}-\d{2}$' then (v_read->>'birth')::date end,
    case when v_read->>'expiry' ~ '^\d{4}-\d{2}-\d{2}$' then (v_read->>'expiry')::date end,
    case when v_read->>'expiry' ~ '^\d{4}-\d{2}-\d{2}$' then (v_read->>'expiry')::date end,
    case when v_read->>'nationality' ~ '^[A-Z]{3}$' then v_read->>'nationality' end,
    case when v_read->>'gender' in ('male', 'female', 'other') then v_read->>'gender' end,
    left(nullif(btrim(v_read->>'address'), ''), 300),
    'ekyc', now(),
    public.identity_read_mismatch(s.user_id, v_read->>'name', coalesce(nullif(v_read->>'ic', ''), v_read->>'passport')),
    v_score, coalesce(v_face, 'not_checked'), 'ekyc', now(),
    'Pending Review', s.verification_id, v_status, v_reasons)
  returning id into v_check;

  -- Riders: the selfie is kept as its own check, as the rider flow does (0343).
  if s.purpose = 'rider_gate' and v_selfie is not null then
    insert into public.identity_checks (
      user_id, kind, purpose, file_url, liveness, liveness_detail, face_score, face_state, face_provider,
      face_checked_at, status, ekyc_verification, ekyc_status, ekyc_reasons)
    values (
      s.user_id, 'selfie', 'rider_gate', v_selfie, v_live, case when v_live = 'passed' then 'turn' end,
      v_score, coalesce(v_face, 'not_checked'), 'ekyc', now(), 'Pending Review', s.verification_id, v_status, v_reasons);
  end if;

  if s.purpose = 'rider_gate' and v_status = 'approved' then
    v_applied := public.rider_id_gate_apply(v_check);
  end if;
  if (v_applied->>'pending')::boolean then
    begin
      perform public.identity_notify_admins(v_check);
    exception when others then
      raise warning 'ekyc_apply notify: %', sqlerrm;
    end;
  end if;

  update public.ekyc_sessions
     set state = 'completed', ekyc_status = v_status, check_id = v_check, completed_at = now(), error = null
   where id = s.id;
  return jsonb_build_object('check_id', v_check, 'verified', (v_applied->>'verified')::boolean,
                            'pending', (v_applied->>'pending')::boolean);
end;
$$;
revoke execute on function public.ekyc_apply(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.ekyc_apply(uuid, jsonb) to service_role;

-- 5. The ID reader leaves GET eKYC rows alone (as 0320, plus that line) ------------------------------
create or replace function public.identity_checks_nas_read()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    if new.kind = 'id' and new.status = 'Pending Review' and new.read_source is distinct from 'ekyc' then
      perform public.identity_read_route(new.id);
    end if;
  exception when others then
    raise warning 'identity_checks_nas_read: %', sqlerrm;
  end;
  return new;
end;
$$;
revoke execute on function public.identity_checks_nas_read() from public, anon, authenticated;

notify pgrst, 'reload schema';
