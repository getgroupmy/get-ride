-- ============================================================================
-- 0288 — Partner registration, part 2: what the new registration order keeps.
--
-- Re-runnable: columns "if not exists", functions "create or replace",
-- triggers and policies dropped first, seed rows "on conflict do nothing".
--
-- The order (lib/src/core/partner_onboarding.dart): profile photo, service
-- area, Partner Service type, National ID, Check your details, Your company,
-- Driver permit, Register vehicle, Vehicle documents, Service documents,
-- Pending admin approval. Each step only when it applies.
--
-- 1. profiles: the National ID (id_type mykad / mypr / passport, the number
--    as typed, the number read off the photo, the name as printed, the back
--    photo). id_mismatch is the server's: true when the typed and the read
--    numbers differ. birth_date, address, nationality, ic and id_image were
--    already there and are reused.
-- 2. partners: registration_steps (the confirmed steps: details, company,
--    driver-permit, vehicle, vehicle-documents), registration_vehicle_id,
--    the company read from the SSM document, the driver permit read from the
--    Kad Pemandu (and the checks the driver confirmed although they failed),
--    selfie_liveness (the server's: how the current profile photo was taken,
--    from identity_checks), and "Needs a closer look" (needs_closer_look,
--    closer_look_reasons; the server's): a selfie taken without the live
--    check, an ID number that doesn't match, a failed permit check confirmed
--    anyway, or a low face match. Never an approval or a rejection.
-- 3. vehicle: the grant / VOC (registration date, engine capacity, owner
--    name and ID, the document's photos), who the owner is (driver /
--    company / other), the owner's authorisation letter and the optional
--    rental or hire-purchase agreement. engine_number and vin (chassis) were
--    already there.
-- 4. vehicle_service_status: per vehicle, per service it was registered for:
--    active, paused_age (over that service's age limit: only that service is
--    paused) or waiting_permit (a vehicle permit GET.ride uploads). An
--    approved vehicle permit upload turns waiting_permit on.
-- 5. document_face_checks: every document with the person's photo (the
--    National ID, the Kad Pemandu, Required Documents marked "Has the
--    person's photo") against their newest live selfie, by the face-compare
--    function (kicked from here); a low score marks the partner "Needs a
--    closer look". No live selfie: 'not_checked', flagged.
-- 6. registration_text_reads: the id-read function's reads for registration
--    documents, to cap them per person per day.
-- 7. A registration vehicle over an age limit is never refused
--    (VEHICLE_TOO_OLD): the service is paused instead. A Kad Pemandu read in
--    the Driver permit step counts as the permit at submit.
-- 8. A service paused for a vehicle is off for it on the server: no open
--    request read, no bid or take (VEHICLE_SERVICE_PAUSED), no push or offer
--    (driver_service_effective, 0263); the Services page says why.
-- ============================================================================

-- ---- 1. profiles ----------------------------------------------------------------------------------
alter table public.profiles
  add column if not exists id_type text,
  add column if not exists id_number_typed text,
  add column if not exists id_number_read text,
  add column if not exists id_mismatch boolean not null default false,
  add column if not exists id_name text,
  add column if not exists id_image_back text;

-- id_type was free text before (0005 wrote 'national_id' for a detected MyKad).
-- Map the old values onto the new ones before the check is added.
update public.profiles
   set id_type = case lower(btrim(id_type))
                   when 'national_id' then 'mykad'
                   when 'mykad' then 'mykad'
                   when 'mypr' then 'mypr'
                   when 'passport' then 'passport'
                 end
 where id_type is not null
   and id_type not in ('mykad', 'mypr', 'passport');

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_id_type_check') then
    alter table public.profiles add constraint profiles_id_type_check
      check (id_type is null or id_type in ('mykad', 'mypr', 'passport'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_id_fields_length') then
    alter table public.profiles add constraint profiles_id_fields_length check (
      char_length(coalesce(id_number_typed, '')) <= 40
      and char_length(coalesce(id_number_read, '')) <= 40
      and char_length(coalesce(id_name, '')) <= 160
      and char_length(coalesce(id_image_back, '')) <= 1000);
  end if;
end $$;

-- Letters and digits only, upper case: 900101-14-5678 = 900101145678.
create or replace function public.reg_id_key(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g'));
$$;
grant execute on function public.reg_id_key(text) to authenticated, service_role;

create or replace function public.profiles_id_mismatch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.id_mismatch := public.reg_id_key(new.id_number_typed) <> ''
    and public.reg_id_key(new.id_number_read) <> ''
    and public.reg_id_key(new.id_number_typed) <> public.reg_id_key(new.id_number_read);
  return new;
end;
$$;
revoke execute on function public.profiles_id_mismatch() from public, anon, authenticated;
drop trigger if exists trg_profiles_d_id_mismatch on public.profiles;
create trigger trg_profiles_d_id_mismatch
  before insert or update on public.profiles
  for each row execute function public.profiles_id_mismatch();

-- ---- 2. partners ----------------------------------------------------------------------------------
alter table public.partners
  add column if not exists registration_steps text[] not null default '{}',
  add column if not exists registration_vehicle_id uuid,
  add column if not exists company_name text,
  add column if not exists company_reg_no text,
  add column if not exists company_type text,
  add column if not exists company_reg_date date,
  add column if not exists company_address text,
  add column if not exists company_directors jsonb not null default '[]'::jsonb,
  add column if not exists company_document_url text,
  add column if not exists company_driver_is_director boolean,
  add column if not exists driver_permit_card_no text,
  add column if not exists driver_permit_valid_from date,
  add column if not exists driver_permit_valid_until date,
  add column if not exists driver_permit_service_type text,
  add column if not exists driver_permit_issuer text,
  add column if not exists driver_permit_name text,
  add column if not exists driver_permit_ic text,
  add column if not exists driver_permit_operator_name text,
  add column if not exists driver_permit_operator_licence text,
  add column if not exists driver_permit_plate text,
  add column if not exists driver_permit_position integer,
  add column if not exists driver_permit_front_url text,
  add column if not exists driver_permit_back_url text,
  add column if not exists driver_permit_flags text[] not null default '{}',
  add column if not exists selfie_liveness text,
  add column if not exists needs_closer_look boolean not null default false,
  add column if not exists closer_look_reasons text[] not null default '{}';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'partners_registration_vehicle_fk') then
    alter table public.partners add constraint partners_registration_vehicle_fk
      foreign key (registration_vehicle_id) references public.vehicle (id) on delete set null;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'partners_registration_fields_check') then
    alter table public.partners add constraint partners_registration_fields_check check (
      cardinality(registration_steps) <= 20
      and cardinality(driver_permit_flags) <= 20
      and jsonb_typeof(company_directors) = 'array'
      and jsonb_array_length(company_directors) <= 30
      and (driver_permit_position is null or driver_permit_position between 1 and 9)
      and (selfie_liveness is null or selfie_liveness in ('passed', 'not_checked'))
      and char_length(coalesce(company_name, '')) <= 200
      and char_length(coalesce(company_reg_no, '')) <= 60
      and char_length(coalesce(company_type, '')) <= 60
      and char_length(coalesce(company_address, '')) <= 400
      and char_length(coalesce(company_document_url, '')) <= 1000
      and char_length(coalesce(driver_permit_card_no, '')) <= 60
      and char_length(coalesce(driver_permit_service_type, '')) <= 60
      and char_length(coalesce(driver_permit_issuer, '')) <= 120
      and char_length(coalesce(driver_permit_name, '')) <= 160
      and char_length(coalesce(driver_permit_ic, '')) <= 40
      and char_length(coalesce(driver_permit_operator_name, '')) <= 200
      and char_length(coalesce(driver_permit_operator_licence, '')) <= 80
      and char_length(coalesce(driver_permit_plate, '')) <= 20
      and char_length(coalesce(driver_permit_front_url, '')) <= 1000
      and char_length(coalesce(driver_permit_back_url, '')) <= 1000);
  end if;
end $$;

create index if not exists partners_needs_closer_look_idx on public.partners (needs_closer_look) where needs_closer_look;

-- ---- 5. Face matches (before the flags that read them) -------------------------------------------
-- Every document with the person's photo on it is compared with their live
-- selfie: the National ID, the Kad Pemandu, and every Required Document the
-- admin marks "Has the person's photo" (values.hasPhoto; unset: on for
-- licences, permits and IDs by name). One row per document, its latest
-- comparison; 'pending' until the face-compare function answers.
create table if not exists public.document_face_checks (
  -- national_id: profiles.id_image (doc_id = the profile id);
  -- driver_permit: partners.driver_permit_front_url (doc_id = the partner id);
  -- provider_document / vehicle_document: that row's front (doc_id = its id).
  doc_kind    text not null check (doc_kind in ('national_id', 'driver_permit', 'provider_document', 'vehicle_document')),
  doc_id      text not null check (char_length(doc_id) <= 60),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  doc_name    text check (doc_name is null or char_length(doc_name) <= 160),
  file_url    text check (file_url is null or char_length(file_url) <= 1000),
  selfie_url  text check (selfie_url is null or char_length(selfie_url) <= 1000),
  state       text not null check (state in ('pending', 'match', 'no_match', 'no_face', 'not_checked', 'error')),
  score       numeric(5, 2) check (score is null or score between 0 and 100),
  provider    text check (provider is null or provider in ('aws', 'self_hosted')),
  -- not_checked: no_live_selfie, off, no_aws_key, no_server, no_provider,
  -- no_photo, too_big; error: what went wrong.
  reason      text check (reason is null or char_length(reason) <= 160),
  checked_at  timestamptz not null default now(),
  primary key (doc_kind, doc_id)
);
comment on table public.document_face_checks is
  'Face match (0288): each document with the person''s photo against their newest live selfie (face-compare). A score for the admin, never a decision; a low one marks the partner "Needs a closer look".';
create index if not exists document_face_checks_user_idx on public.document_face_checks (user_id);

alter table public.document_face_checks enable row level security;
revoke all on public.document_face_checks from public, anon, authenticated;
grant select on public.document_face_checks to authenticated;
grant all on public.document_face_checks to service_role;
drop policy if exists document_face_checks_read on public.document_face_checks;
create policy document_face_checks_read on public.document_face_checks
  for select to authenticated using (user_id = (select auth.uid()) or (select public.caller_is_admin()));

-- Whether a Required Document carries the person's photo: the admin's
-- "Has the person's photo" (hasPhoto), else on for licences, permits and
-- IDs by name (as RequiredDocForm / DocFlags.hasPhoto in the app).
create or replace function public.required_document_has_photo(p_values jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when jsonb_typeof(p_values -> 'hasPhoto') = 'boolean' then (p_values ->> 'hasPhoto')::boolean
    when p_values ->> 'hasPhoto' in ('true', 'false') then (p_values ->> 'hasPhoto')::boolean
    else coalesce((p_values ->> 'isTaxiPermit') in ('true'), false)
      or coalesce(p_values ->> 'name', '') ~* '(licen[cs]e|lesen|permit|kad pemandu|\mpsv\M|\mgdl\M|mykad|mypr|passport|pasport|identity|\mid card|driver card)'
  end;
$$;
grant execute on function public.required_document_has_photo(jsonb) to authenticated, service_role;

-- Below this a face match needs a closer look (the score is 0–100).
create or replace function public.partner_face_low_score()
returns numeric
language sql
immutable
set search_path = ''
as $$ select 60::numeric $$;
grant execute on function public.partner_face_low_score() to authenticated, service_role;

-- How the profile photo [p_avatar] of [p_uid] was taken: the newest profile
-- selfie recorded for that photo, else null (unknown).
create or replace function public.partner_selfie_liveness(p_uid uuid, p_avatar text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select c.liveness
    from public.identity_checks c
   where p_uid is not null and nullif(btrim(coalesce(p_avatar, '')), '') is not null
     and c.user_id = p_uid and c.kind = 'selfie' and c.purpose = 'profile' and c.file_url = p_avatar
   order by c.created_at desc
   limit 1;
$$;
revoke execute on function public.partner_selfie_liveness(uuid, text) from public, anon, authenticated;

-- The server's flags on a partner row: never written by the apps.
create or replace function public.partners_registration_flags()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  reasons text[] := '{}';
begin
  new.selfie_liveness := public.partner_selfie_liveness(new.auth_user_id, new.avatar_url);
  if new.selfie_liveness = 'not_checked' then
    reasons := array_append(reasons, 'selfie_not_live');
  end if;
  if exists (select 1 from public.profiles pr where pr.id = new.auth_user_id and pr.id_mismatch) then
    reasons := array_append(reasons, 'id_number_mismatch');
  end if;
  if cardinality(coalesce(new.driver_permit_flags, '{}')) > 0 then
    reasons := array_append(reasons, 'driver_permit_checks');
  end if;
  if exists (
    select 1 from public.document_face_checks f
     where f.user_id = new.auth_user_id
       and (f.state in ('no_match', 'no_face') or (f.score is not null and f.score < public.partner_face_low_score()))
  ) then
    reasons := array_append(reasons, 'face_low');
  end if;
  if not 'selfie_not_live' = any (reasons) and exists (
    select 1 from public.document_face_checks f
     where f.user_id = new.auth_user_id and f.state = 'not_checked' and f.reason = 'no_live_selfie'
  ) then
    reasons := array_append(reasons, 'selfie_not_live');
  end if;
  new.closer_look_reasons := reasons;
  new.needs_closer_look := cardinality(reasons) > 0;
  return new;
end;
$$;
revoke execute on function public.partners_registration_flags() from public, anon, authenticated;
drop trigger if exists trg_partners_r_registration_flags on public.partners;
create trigger trg_partners_r_registration_flags
  before insert or update on public.partners
  for each row execute function public.partners_registration_flags();

-- Something the flags read changed elsewhere: the partner rows of [p_uid]
-- work them out again.
create or replace function public.partner_flags_touch(p_uid uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.partners set updated_at = now() where auth_user_id = p_uid;
$$;
revoke execute on function public.partner_flags_touch(uuid) from public, anon, authenticated;

create or replace function public.profiles_touch_partner_flags()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.id_mismatch is distinct from old.id_mismatch then
    perform public.partner_flags_touch(new.id);
  end if;
  return null;
end;
$$;
revoke execute on function public.profiles_touch_partner_flags() from public, anon, authenticated;
drop trigger if exists trg_profiles_z_partner_flags on public.profiles;
-- Any update: id_mismatch is set by a before trigger, never in the SET list.
create trigger trg_profiles_z_partner_flags
  after update on public.profiles
  for each row execute function public.profiles_touch_partner_flags();

create or replace function public.identity_checks_touch_partner_flags()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
begin
  if new.kind = 'selfie' and new.purpose = 'profile' then
    perform public.partner_flags_touch(new.user_id);
  end if;
  -- A live selfie at last: the documents that waited for one are compared.
  if new.kind = 'selfie' and new.liveness = 'passed' then
    for r in select f.doc_kind, f.doc_id, f.file_url, f.doc_name from public.document_face_checks f
              where f.user_id = new.user_id and f.state = 'not_checked' and f.reason = 'no_live_selfie' loop
      perform public.document_face_check_queue(r.doc_kind, r.doc_id, new.user_id, r.file_url, r.doc_name);
    end loop;
  end if;
  return null;
end;
$$;
revoke execute on function public.identity_checks_touch_partner_flags() from public, anon, authenticated;
drop trigger if exists trg_identity_checks_partner_flags on public.identity_checks;
create trigger trg_identity_checks_partner_flags
  after insert on public.identity_checks
  for each row execute function public.identity_checks_touch_partner_flags();

-- The person's newest live selfie (liveness passed), or null.
create or replace function public.live_selfie_url(p_uid uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select c.file_url from public.identity_checks c
   where c.user_id = p_uid and c.kind = 'selfie' and c.liveness = 'passed'
   order by c.created_at desc limit 1;
$$;
revoke execute on function public.live_selfie_url(uuid) from public, anon, authenticated;
grant execute on function public.live_selfie_url(uuid) to service_role;

-- Whether the caller has a passed live selfie on record (the app's gate
-- before a document with their photo is sent).
create or replace function public.my_live_selfie_ok()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null and public.live_selfie_url(auth.uid()) is not null;
$$;
revoke execute on function public.my_live_selfie_ok() from public, anon;
grant execute on function public.my_live_selfie_ok() to authenticated;

-- Asks the face-compare function to compare one document (best effort:
-- with no project URL or webhook secret in Vault nothing is sent, and the
-- row stays 'pending' for "Compare again" in the admin).
create or replace function public.document_face_check_kick(p_kind text, p_id text)
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
    url     := v_url || '/functions/v1/face-compare',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body    := jsonb_build_object('document', jsonb_build_object('kind', p_kind, 'id', p_id))
  );
  return true;
exception when others then
  return false;
end;
$$;
revoke execute on function public.document_face_check_kick(text, text) from public, anon, authenticated;

-- A document with the person's photo was added or replaced: its comparison
-- starts again. Without a live selfie it is 'not_checked' (no_live_selfie)
-- at once, and the partner needs a closer look.
create or replace function public.document_face_check_queue(
  p_kind text, p_id text, p_uid uuid, p_file text, p_name text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_selfie text := public.live_selfie_url(p_uid);
begin
  if p_uid is null or nullif(btrim(coalesce(p_file, '')), '') is null then
    return;
  end if;
  insert into public.document_face_checks (doc_kind, doc_id, user_id, doc_name, file_url, selfie_url, state, score, provider, reason, checked_at)
  values (p_kind, p_id, p_uid, left(p_name, 160), p_file, v_selfie,
          case when v_selfie is null then 'not_checked' else 'pending' end, null, null,
          case when v_selfie is null then 'no_live_selfie' end, now())
  on conflict (doc_kind, doc_id) do update
    set user_id = excluded.user_id, doc_name = excluded.doc_name, file_url = excluded.file_url,
        selfie_url = excluded.selfie_url, state = excluded.state, score = null, provider = null,
        reason = excluded.reason, checked_at = now();
  perform public.partner_flags_touch(p_uid);
  if v_selfie is not null then
    perform public.document_face_check_kick(p_kind, p_id);
  end if;
end;
$$;
revoke execute on function public.document_face_check_queue(text, text, uuid, text, text) from public, anon, authenticated;

create or replace function public.profiles_face_check_id()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.id_image is distinct from old.id_image then
    perform public.document_face_check_queue('national_id', new.id::text, new.id, new.id_image, 'National ID');
  end if;
  return null;
end;
$$;
revoke execute on function public.profiles_face_check_id() from public, anon, authenticated;
drop trigger if exists trg_profiles_z_face_check on public.profiles;
create trigger trg_profiles_z_face_check
  after update of id_image on public.profiles
  for each row execute function public.profiles_face_check_id();

create or replace function public.partners_face_check_permit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.driver_permit_front_url is distinct from (case when tg_op = 'UPDATE' then old.driver_permit_front_url end) then
    perform public.document_face_check_queue('driver_permit', new.id::text, new.auth_user_id,
                                             new.driver_permit_front_url, 'Driver permit');
  end if;
  return null;
end;
$$;
revoke execute on function public.partners_face_check_permit() from public, anon, authenticated;
drop trigger if exists trg_partners_z_face_check on public.partners;
create trigger trg_partners_z_face_check
  after insert or update of driver_permit_front_url on public.partners
  for each row execute function public.partners_face_check_permit();

-- provider_documents / vehicle_documents: the uploader is the person
-- (auth_user_id, else the partner's login). Admin uploads count too: they
-- are the partner's documents.
create or replace function public.documents_face_check()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_values jsonb;
  v_uid uuid;
begin
  if new.file_url is not distinct from (case when tg_op = 'UPDATE' then old.file_url end) then
    return null;
  end if;
  select r.values into v_values from public.required_document r where r.id::text = new.doc_id;
  if v_values is null or not public.required_document_has_photo(v_values) then
    return null;
  end if;
  v_uid := coalesce(new.auth_user_id,
                    (select p.auth_user_id from public.partners p where p.id = new.partner_id));
  perform public.document_face_check_queue(
    case when tg_table_name = 'vehicle_documents' then 'vehicle_document' else 'provider_document' end,
    new.id::text, v_uid, new.file_url, new.doc_name);
  return null;
end;
$$;
revoke execute on function public.documents_face_check() from public, anon, authenticated;
drop trigger if exists trg_provider_documents_face_check on public.provider_documents;
create trigger trg_provider_documents_face_check
  after insert or update of file_url on public.provider_documents
  for each row execute function public.documents_face_check();
drop trigger if exists trg_vehicle_documents_face_check on public.vehicle_documents;
create trigger trg_vehicle_documents_face_check
  after insert or update of file_url on public.vehicle_documents
  for each row execute function public.documents_face_check();

-- What the face-compare function needs for one document: the person, the
-- document's photo and their newest live selfie (service role only).
create or replace function public.document_face_check_source(p_kind text, p_id text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('user_id', f.user_id, 'file_url', f.file_url,
                            'selfie_url', public.live_selfie_url(f.user_id), 'state', f.state)
    from public.document_face_checks f
   where f.doc_kind = p_kind and f.doc_id = p_id;
$$;
revoke execute on function public.document_face_check_source(text, text) from public, anon, authenticated;
grant execute on function public.document_face_check_source(text, text) to service_role;

-- The face-compare function keeps one comparison (service role only).
create or replace function public.document_face_check_store(
  p_kind text, p_id text, p_state text, p_score numeric, p_provider text, p_reason text, p_selfie text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid;
begin
  update public.document_face_checks
     set state = p_state, score = p_score, provider = p_provider, reason = left(p_reason, 160),
         selfie_url = coalesce(p_selfie, selfie_url), checked_at = now()
   where doc_kind = p_kind and doc_id = p_id
  returning user_id into v_uid;
  if v_uid is not null then
    perform public.partner_flags_touch(v_uid);
  end if;
end;
$$;
revoke execute on function public.document_face_check_store(text, text, text, numeric, text, text, text) from public, anon, authenticated;
grant execute on function public.document_face_check_store(text, text, text, numeric, text, text, text) to service_role;

-- ---- 3. vehicle ------------------------------------------------------------------------------------
alter table public.vehicle
  add column if not exists registration_date date,
  add column if not exists engine_cc integer,
  add column if not exists grant_owner_name text,
  add column if not exists grant_owner_id text,
  add column if not exists grant_front_url text,
  add column if not exists grant_back_url text,
  add column if not exists owner_match text,
  add column if not exists authorisation_letter_url text,
  add column if not exists hire_agreement_url text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'vehicle_registration_fields_check') then
    alter table public.vehicle add constraint vehicle_registration_fields_check check (
      (owner_match is null or owner_match in ('driver', 'company', 'other'))
      and (engine_cc is null or engine_cc between 0 and 20000)
      and char_length(coalesce(grant_owner_name, '')) <= 200
      and char_length(coalesce(grant_owner_id, '')) <= 60
      and char_length(coalesce(grant_front_url, '')) <= 1000
      and char_length(coalesce(grant_back_url, '')) <= 1000
      and char_length(coalesce(authorisation_letter_url, '')) <= 1000
      and char_length(coalesce(hire_agreement_url, '')) <= 1000);
  end if;
end $$;

-- ---- 4. Per vehicle, per service ------------------------------------------------------------------
create table if not exists public.vehicle_service_status (
  vehicle_id    uuid not null references public.vehicle (id) on delete cascade,
  service       text not null check (char_length(service) between 1 and 80),
  status        text not null check (status in ('active', 'paused_age', 'waiting_permit')),
  -- The age limit that applies (years) and whose it is (the service's own,
  -- or the registered type's that covers it).
  max_age_years integer check (max_age_years is null or max_age_years between 0 and 100),
  limit_type    text check (limit_type is null or char_length(limit_type) <= 80),
  -- The vehicle permit GET.ride uploads (its name, its permit type id).
  permit_name   text check (permit_name is null or char_length(permit_name) <= 120),
  permit_type   text check (permit_type is null or char_length(permit_type) <= 60),
  updated_at    timestamptz not null default now(),
  primary key (vehicle_id, service)
);
comment on table public.vehicle_service_status is
  'Partner registration (0288): per vehicle and service, active / paused_age (over that service''s age limit; only that service is paused) / waiting_permit (GET.ride uploads the vehicle permit).';

alter table public.vehicle_service_status enable row level security;
revoke all on public.vehicle_service_status from public, anon;
grant select, insert, update, delete on public.vehicle_service_status to authenticated;
grant all on public.vehicle_service_status to service_role;

-- The caller owns [p_vehicle] (through its login or its partner).
create or replace function public.reg_owns_vehicle(p_vehicle uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.vehicle v
     where v.id = p_vehicle
       and ((v.auth_user_id is not null and v.auth_user_id = auth.uid())
         or exists (select 1 from public.partners p where p.id = v.owner_partner_id and p.auth_user_id = auth.uid())));
$$;
revoke execute on function public.reg_owns_vehicle(uuid) from public, anon;
grant execute on function public.reg_owns_vehicle(uuid) to authenticated;

-- The owner sets them while registering: until the vehicle is submitted.
create or replace function public.reg_vehicle_draft(p_vehicle uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.vehicle v
     where v.id = p_vehicle and v.status::text in ('unapproved', 'unapproved-docs') and not v.documents_ok);
$$;
revoke execute on function public.reg_vehicle_draft(uuid) from public, anon;
grant execute on function public.reg_vehicle_draft(uuid) to authenticated;

drop policy if exists vehicle_service_status_read on public.vehicle_service_status;
create policy vehicle_service_status_read on public.vehicle_service_status
  for select to authenticated using ((select public.reg_owns_vehicle(vehicle_id)) or (select public.caller_is_admin()));
drop policy if exists vehicle_service_status_owner_insert on public.vehicle_service_status;
create policy vehicle_service_status_owner_insert on public.vehicle_service_status
  for insert to authenticated with check (public.reg_owns_vehicle(vehicle_id) and public.reg_vehicle_draft(vehicle_id));
drop policy if exists vehicle_service_status_owner_update on public.vehicle_service_status;
create policy vehicle_service_status_owner_update on public.vehicle_service_status
  for update to authenticated
  using (public.reg_owns_vehicle(vehicle_id) and public.reg_vehicle_draft(vehicle_id))
  with check (public.reg_owns_vehicle(vehicle_id) and public.reg_vehicle_draft(vehicle_id));
drop policy if exists vehicle_service_status_owner_delete on public.vehicle_service_status;
create policy vehicle_service_status_owner_delete on public.vehicle_service_status
  for delete to authenticated using (public.reg_owns_vehicle(vehicle_id) and public.reg_vehicle_draft(vehicle_id));
drop policy if exists vehicle_service_status_admin_insert on public.vehicle_service_status;
create policy vehicle_service_status_admin_insert on public.vehicle_service_status
  for insert to authenticated with check ((select public.caller_admin_can_write('vehicle_service_status')));
drop policy if exists vehicle_service_status_admin_update on public.vehicle_service_status;
create policy vehicle_service_status_admin_update on public.vehicle_service_status
  for update to authenticated
  using ((select public.caller_admin_can_write('vehicle_service_status')))
  with check ((select public.caller_admin_can_write('vehicle_service_status')));
drop policy if exists vehicle_service_status_admin_delete on public.vehicle_service_status;
create policy vehicle_service_status_admin_delete on public.vehicle_service_status
  for delete to authenticated using ((select public.caller_admin_can_write('vehicle_service_status')));

insert into public.admin_table_pages (target, page) values
  ('vehicle_service_status', 'admin-vehicles'),
  ('vehicle_service_status', 'admin-vehicle-edit'),
  ('vehicle_service_status', 'admin-vehicle-permits'),
  ('vehicle_service_status', 'admin-partners'),
  ('vehicle_service_status', 'admin-partner-edit')
on conflict do nothing;

drop trigger if exists trg_vehicle_service_status_touch on public.vehicle_service_status;
create or replace function public.vehicle_service_status_touch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
revoke execute on function public.vehicle_service_status_touch() from public, anon, authenticated;
create trigger trg_vehicle_service_status_touch
  before insert or update on public.vehicle_service_status
  for each row execute function public.vehicle_service_status_touch();

-- An approved vehicle permit (0254) turns on the services waiting for it.
create or replace function public.vehicle_documents_permit_turns_on()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.permit_type_id is null or new.status <> 'Approved'
     or (new.expiry_date is not null and new.expiry_date < current_date) then
    return null;
  end if;
  update public.vehicle_service_status s
     set status = 'active'
   where s.vehicle_id = new.vehicle_id
     and s.status = 'waiting_permit'
     and (s.permit_type is null or s.permit_type = new.permit_type_id::text);
  return null;
end;
$$;
revoke execute on function public.vehicle_documents_permit_turns_on() from public, anon, authenticated;
drop trigger if exists trg_vehicle_documents_permit_turns_on on public.vehicle_documents;
create trigger trg_vehicle_documents_permit_turns_on
  after insert or update of status, permit_type_id, expiry_date on public.vehicle_documents
  for each row execute function public.vehicle_documents_permit_turns_on();

-- ---- 6. Server reads of registration documents ---------------------------------------------------
create table if not exists public.registration_text_reads (
  id       bigint generated always as identity primary key,
  user_id  uuid not null references public.profiles (id) on delete cascade,
  read_at  timestamptz not null default now()
);
create index if not exists registration_text_reads_user_idx on public.registration_text_reads (user_id, read_at desc);
alter table public.registration_text_reads enable row level security;
revoke all on public.registration_text_reads from public, anon, authenticated;
grant all on public.registration_text_reads to service_role;

-- Spends one of [p_user]'s reads for the day; false when [p_limit] are spent.
create or replace function public.registration_text_read_spend(p_user uuid, p_limit integer default 30)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_user is null then
    return false;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('registration_text_read:' || p_user::text, 0));
  if (select count(*) from public.registration_text_reads r
       where r.user_id = p_user and r.read_at > now() - interval '1 day') >= greatest(p_limit, 0) then
    return false;
  end if;
  insert into public.registration_text_reads (user_id) values (p_user);
  delete from public.registration_text_reads where user_id = p_user and read_at < now() - interval '2 days';
  return true;
end;
$$;
revoke execute on function public.registration_text_read_spend(uuid, integer) from public, anon, authenticated;
grant execute on function public.registration_text_read_spend(uuid, integer) to service_role;

-- Whether [p_uid] owns the stored file [p_bucket]/[p_path]: their ID_Image
-- folder, their partner's provider-documents folder, their vehicle's
-- vehicle-documents folder (the id-read function asks, as the service role).
create or replace function public.registration_file_owned(p_uid uuid, p_bucket text, p_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_uid is not null and position('..' in coalesce(p_path, '')) = 0 and case p_bucket
    when 'ID_Image' then split_part(p_path, '/', 1) = p_uid::text
    when 'provider-documents' then exists (
      select 1 from public.partners p where p.id::text = split_part(p_path, '/', 1) and p.auth_user_id = p_uid)
    when 'vehicle-documents' then split_part(p_path, '/', 2) <> 'permits' and exists (
      select 1 from public.vehicle v
       where v.id::text = split_part(p_path, '/', 1)
         and (v.auth_user_id = p_uid
           or exists (select 1 from public.partners p where p.id = v.owner_partner_id and p.auth_user_id = p_uid)))
    else false
  end;
$$;
revoke execute on function public.registration_file_owned(uuid, text, text) from public, anon, authenticated;
grant execute on function public.registration_file_owned(uuid, text, text) to service_role;

-- ---- 7. Age limits pause a service; the Kad Pemandu counts as the permit ---------------------------
create or replace function public.vehicle_partner_type_rules()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  ctx jsonb;
  fit jsonb;
begin
  -- The owner's own writes from the apps; admins and the server decide freely.
  if coalesce(nullif(current_setting('request.jwt.claims', true), ''), '') = ''
     or coalesce(auth.jwt() ->> 'role', '') not in ('authenticated', 'anon')
     or public.caller_is_admin() then
    return new;
  end if;
  if not ((coalesce(old.documents_ok, false) = false and coalesce(new.documents_ok, false) = true)
          or (new.year is distinct from old.year and btrim(coalesce(new.year, '')) <> '')) then
    return new;
  end if;
  -- Registered in partner registration (0288): a service over its age
  -- limit is paused for this vehicle (vehicle_service_status), never refused.
  if exists (select 1 from public.partners p where p.registration_vehicle_id = new.id) then
    return new;
  end if;
  ctx := public.ptr_vehicle_context(new.id);
  fit := public.ptr_vehicle_fits_types(
    public.ptr_text_array(ctx -> 'types'), new.year,
    case when coalesce(cardinality(new.service_countries), 0) > 0 then new.service_countries
         else public.ptr_text_array(ctx -> 'countries') end,
    case when coalesce(cardinality(new.service_countries), 0) > 0 then new.service_states
         else public.ptr_text_array(ctx -> 'states') end,
    case when coalesce(cardinality(new.service_countries), 0) > 0 then new.service_cities
         else public.ptr_text_array(ctx -> 'cities') end,
    true);
  if not (fit ->> 'ok')::boolean then
    raise exception 'VEHICLE_TOO_OLD' using errcode = '42501', hint = fit ->> 'reason';
  end if;
  return new;
end;
$$;
revoke execute on function public.vehicle_partner_type_rules() from public, anon, authenticated;

create or replace function public.ptr_partner_has_permit(p_partner_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
           select 1 from public.partners p
            where p.id = p_partner_id and p.permit::text = 'verified')
      or exists (
           select 1
             from public.provider_documents d
             join public.required_document r on r.id::text = d.doc_id
            where d.partner_id = p_partner_id
              and public.ptr_bool(r.values -> 'isTaxiPermit', false)
              and coalesce(d.status, '') <> 'Rejected'
              and (d.expiry_date is null or d.expiry_date >= current_date))
      -- The Driver permit step (0288): the Kad Pemandu, read and in date.
      or exists (
           select 1 from public.partners p
            where p.id = p_partner_id
              and nullif(btrim(coalesce(p.driver_permit_card_no, '')), '') is not null
              and nullif(btrim(coalesce(p.driver_permit_front_url, '')), '') is not null
              and (p.driver_permit_valid_until is null or p.driver_permit_valid_until >= current_date));
$$;
revoke all on function public.ptr_partner_has_permit(uuid) from public, anon, authenticated;

-- ---- 8. A paused service is off for that vehicle -------------------------------------------------
-- vehicle_service_status is kept per Partner Service type (eHailing, Teksi);
-- requests name a Vehicle Service (Ride, Premium, Teksi ...), which the
-- types allow (partner_type_services, 0257). A Vehicle Service is paused for
-- a vehicle when every one of its types that allows it is paused there
-- (paused_age or waiting_permit): a taxi with eHailing waiting for its EVP
-- still takes Ride through Teksi. driver_service_effective (0263) then says
-- off, and with it everything that rule enforces: the open requests a
-- driver reads, bids and takes (VEHICLE_SERVICE_PAUSED), direct bookings,
-- My Ride targets, the new-request, widening, everyone, stand and airport
-- pushes and offers, the dispatch tick and the scheduled list. The Services
-- page says why (driver_services_for: vehicle_block).

-- Why [p_service] is paused for [p_vehicle]: {status, type, max_age_years,
-- permit_name} of the first allowing type that is paused, or null when one
-- allowing type is active, none allows it, or nothing is paused.
create or replace function public.vehicle_service_block(p_vehicle uuid, p_service text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_types text[];
  t text;
  r public.vehicle_service_status;
  v_first jsonb;
begin
  if p_vehicle is null or coalesce(btrim(p_service), '') = '' or p_service ~ '^(extra|hail):' then
    return null;
  end if;
  if not exists (select 1 from public.vehicle_service_status s where s.vehicle_id = p_vehicle and s.status <> 'active') then
    return null;
  end if;
  v_types := array(
    select distinct x from (
      select s.service as x from public.vehicle_service_status s where s.vehicle_id = p_vehicle
      union
      select unnest(public.ptr_text_array(public.ptr_vehicle_context(p_vehicle) -> 'types'))
    ) q
    where coalesce(btrim(x), '') <> '');
  foreach t in array v_types loop
    continue when not public.partner_type_allows_service(t, p_service);
    r := null;
    select * into r from public.vehicle_service_status s
     where s.vehicle_id = p_vehicle and public.ptr_key(s.service) = public.ptr_key(t)
     limit 1;
    if r.vehicle_id is null or r.status = 'active' then
      return null;
    end if;
    v_first := coalesce(v_first, jsonb_build_object(
      'status', r.status, 'type', r.service, 'max_age_years', r.max_age_years, 'permit_name', r.permit_name));
  end loop;
  return v_first;
end;
$$;
revoke execute on function public.vehicle_service_block(uuid, text) from public, anon, authenticated;
grant execute on function public.vehicle_service_block(uuid, text) to service_role;

-- The driver's words for a block: "eHailing paused: vehicle over the
-- 15-year limit", "eHailing waiting for the vehicle permit".
create or replace function public.vehicle_service_block_text(p jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p ->> 'status'
    when 'paused_age' then format('%s paused: vehicle over the %s-year limit', p ->> 'type',
                                  coalesce(p ->> 'max_age_years', '?'))
    when 'waiting_permit' then format('%s waiting for the vehicle permit', p ->> 'type')
  end;
$$;
grant execute on function public.vehicle_service_block_text(jsonb) to authenticated, service_role;

create or replace function public.driver_service_effective(p_driver uuid, p_vehicle uuid, p_service text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_key text := public.driver_service_key(p_service);
  l public.driver_service_locks;
begin
  if p_driver is null or coalesce(v_key, '') = '' then
    return true;
  end if;
  -- 0288: paused for this vehicle (over its age limit, or waiting for the
  -- vehicle permit GET.ride uploads): off, whatever the switch or a lock.
  if p_vehicle is not null and v_key !~ '^(extra|hail):'
     and public.vehicle_service_block(p_vehicle, v_key) is not null then
    return false;
  end if;
  l := public.driver_service_lock(p_driver, p_vehicle, v_key);
  if l.id is not null then
    return l.mode = 'on';
  end if;
  return coalesce((select p.enabled from public.driver_service_prefs p
                    where p.driver_id = p_driver and p.vehicle_id = p_vehicle and p.service_key = v_key), true);
end;
$$;


create or replace function public.driver_services_off(p_driver uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_vehicle uuid;
begin
  if p_driver is null then
    return '{}';
  end if;
  v_vehicle := public.driver_session_vehicle(p_driver);
  return coalesce((
    select array_agg(k order by k) from (
      select p.service_key as k from public.driver_service_prefs p
       where p.driver_id = p_driver and p.vehicle_id = v_vehicle and not p.enabled
      union
      select l.service_key from public.driver_service_locks l
       where l.mode = 'off' and (l.until is null or l.until > now())
      union
      -- 0288: the services paused for this vehicle.
      select public.driver_service_key(e.values->>'name') from public.settings_entries e
       where e.category = 'vehicle-services' and coalesce(btrim(e.values->>'name'), '') <> ''
         and exists (select 1 from public.vehicle_service_status s
                      where s.vehicle_id = v_vehicle and s.status <> 'active')
    ) x
    where k !~ '^(extra|hail):' and not public.driver_service_effective(p_driver, v_vehicle, k)), '{}');
end;
$$;


create or replace function public.driver_services_for(p_vehicle uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_vehicle uuid := coalesce(p_vehicle, public.driver_session_vehicle(auth.uid()));
  v public.vehicle;
  v_ctx jsonb;
  v_types text[];
  v_service text;
  v_names jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_vehicle is null then
    return jsonb_build_object('vehicle', null);
  end if;
  if not public.driver_may_drive(v_uid, v_vehicle) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into v from public.vehicle where id = v_vehicle;
  v_ctx := public.ptr_vehicle_context(v_vehicle);
  v_types := public.ptr_text_array(v_ctx -> 'types');
  if coalesce(cardinality(v_types), 0) = 0 then
    select case when coalesce(cardinality(p.partner_types), 0) > 0 then p.partner_types
                when coalesce(btrim(p.partner_type), '') <> '' then array[p.partner_type] else '{}' end
      into v_types
      from public.partners p where p.auth_user_id = v_uid order by p.created_at limit 1;
  end if;
  v_types := coalesce(v_types, '{}');
  v_service := coalesce(nullif(v.service_approved_id, ''), nullif(v.service_id, ''));

  return jsonb_build_object(
    'vehicle', jsonb_build_object(
      'id', v.id, 'plate', v.plate, 'make', v.make, 'model', v.model, 'color', v.color,
      'vehicle_type', v.vehicle_type, 'energy', public.vehicle_energy(v.id), 'service_id', v_service,
      'service_name', (select e.values->>'name' from public.settings_entries e
                        where e.category = 'vehicle-services' and e.id::text = v_service)),
    'types', to_jsonb(v_types),
    'order_enforced', public.service_order_enforced(),
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', e.id, 'name', e.values->>'name', 'key', public.driver_service_key(e.values->>'name'),
               'types', e.values->'serviceTypes',
               'parents', e.values->'parentServices',
               'description', coalesce(e.values->>'shortDescription', e.values->>'description', ''),
               'max_pax', e.values->'maxPax',
               'partner_ok', cardinality(v_types) = 0
                             or exists (select 1 from unnest(v_types) t
                                         where public.partner_type_allows_service(t, e.values->>'name')),
               'order_ok', public.service_order_allows(v_service, e.values->>'name'),
               'permit_missing', exists (
                 select 1 from public.permit_types pt
                  where pt.active and pt.applies_to = 'vehicle' and pt.required
                    and (public.permit_settings_for(pt.country)).enforce
                    and coalesce(cardinality(pt.services), 0) > 0
                    and exists (select 1 from unnest(public.ptr_text_array(v_ctx -> 'countries')) c
                                 where public.ptr_name(c) = public.ptr_name(pt.country))
                    and public.permit_type_covers(pt.partner_types, pt.services, v_types, e.id::text)
                    and coalesce((select v2.permit_bypass_until > now() from public.vehicle v2 where v2.id = v.id), false) = false
                    and coalesce((select public.permit_doc_state(d.status, d.expiry_date) from public.vehicle_documents d
                                   where d.vehicle_id = v.id and d.permit_type_id = pt.id
                                   order by d.uploaded_at desc limit 1), 'without') <> 'with'),
               'pref', (select p.enabled from public.driver_service_prefs p
                         where p.driver_id = v_uid and p.vehicle_id = v.id
                           and p.service_key = public.driver_service_key(e.values->>'name')),
               'lock', public.driver_service_lock_json(v_uid, v.id, e.values->>'name'),
               -- 0288: {status, type, max_age_years, permit_name} when paused for this vehicle.
               'vehicle_block', public.vehicle_service_block(v.id, e.values->>'name'),
               'on', public.driver_service_effective(v_uid, v.id, e.values->>'name'))
             order by coalesce((e.values->>'displayPriority')::numeric, 1e9), e.position, e.created_at)
        from public.settings_entries e
       where e.category = 'vehicle-services'
         and coalesce(btrim(e.values->>'name'), '') <> ''
         and lower(coalesce(e.values->>'status', 'true')) not in ('false', '0', 'off', 'inactive')), '[]'::jsonb),
    'keys', coalesce((
      select jsonb_object_agg(k, jsonb_build_object(
               'pref', (select p.enabled from public.driver_service_prefs p
                         where p.driver_id = v_uid and p.vehicle_id = v.id and p.service_key = k),
               'lock', public.driver_service_lock_json(v_uid, v.id, k),
               'on', public.driver_service_effective(v_uid, v.id, k)))
        from (select 'hail:meter' as k union select 'hail:destination'
              union select p.service_key from public.driver_service_prefs p
                     where p.driver_id = v_uid and p.vehicle_id = v.id and p.service_key ~ '^(extra|hail):'
              union select l.service_key from public.driver_service_locks l
                     where l.service_key ~ '^(extra|hail):' and (l.until is null or l.until > now())) ks), '{}'::jsonb));
end;
$$;


create or replace function public.ride_requests_driver_services()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app boolean := coalesce(current_setting('role', true), '') in ('anon', 'authenticated');
  v_keep uuid[];
  l public.driver_service_locks;
  v_block jsonb;
begin
  if tg_op = 'INSERT' then
    if coalesce(btrim(new.service), '') = '' then
      return new;
    end if;
    if v_app and new.status = 'open' and new.direct_driver_id is not null
       and not public.driver_takes_service(new.direct_driver_id, new.service) then
      raise exception 'DRIVER_SERVICE_OFF_DIRECT' using errcode = '42501',
        hint = format('This driver doesn''t take %s requests right now. Choose another service, or book without the code.',
                      new.service);
    end if;
    if new.direct_driver_id is null and coalesce(cardinality(new.target_driver_ids), 0) > 0 then
      select coalesce(array_agg(d), '{}') into v_keep
        from unnest(new.target_driver_ids) d
       where public.driver_takes_service(d, new.service);
      if cardinality(v_keep) = 0 then
        new.target_driver_ids := null;
        new.targeted_until := null;
      else
        new.target_driver_ids := v_keep;
      end if;
    end if;
    return new;
  end if;
  -- A driver's own bid or take from the app.
  if v_app and old.status = 'open'
     and new.partner_id is not null and new.partner_id is distinct from old.partner_id
     and new.partner_id = auth.uid()
     and not public.driver_takes_service(new.partner_id, old.service) then
    -- 0288: paused for this vehicle.
    v_block := public.vehicle_service_block(public.driver_session_vehicle(new.partner_id), old.service);
    if v_block is not null then
      raise exception 'VEHICLE_SERVICE_PAUSED' using errcode = '42501',
        hint = public.vehicle_service_block_text(v_block);
    end if;
    l := public.driver_service_lock(new.partner_id, public.driver_session_vehicle(new.partner_id), old.service);
    raise exception 'DRIVER_SERVICE_OFF' using errcode = '42501',
      hint = case when l.id is not null
                  then format('get.ride keeps %s off for you. Contact support to change it.', old.service)
                  else format('You turned %s off in Services. Turn it on to take these requests.', old.service) end;
  end if;
  return new;
end;
$$;

revoke execute on function public.driver_service_effective(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.driver_services_off(uuid) from public, anon, authenticated;
grant execute on function public.driver_service_effective(uuid, uuid, text), public.driver_services_off(uuid) to service_role;
revoke execute on function public.driver_services_for(uuid) from public, anon;
grant execute on function public.driver_services_for(uuid) to authenticated;
revoke execute on function public.ride_requests_driver_services() from public, anon, authenticated;

-- The help article on becoming a driver says the new order (only while it
-- still has the old wording an admin hasn't changed).
update public.help_articles
   set answer = 'Open the Drive tab and tap Get started. The application goes in order: a live selfie if you have no profile photo yet, your service area, the Partner Service types you will offer, your national ID (MyKad, MyPR or passport) and the details read from it, then, where your services need them, your company, your driver permit and your vehicle with its documents, and last the service documents. It resumes where you left off. Once submitted, an admin reviews it; you can take jobs once your account is approved.'
 where id = '68656c70-0000-4000-8000-000000000043' and answer like '%The application has six steps%';

-- Backfill the server's flags on existing rows.
update public.partners set updated_at = updated_at;

notify pgrst, 'reload schema';
insert into supabase_migrations.schema_migrations (version, name) values ('20261024180000', '0288_partner_registration_flow') on conflict do nothing;
