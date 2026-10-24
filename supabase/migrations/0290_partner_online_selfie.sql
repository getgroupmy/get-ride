-- ============================================================================
-- 0290 — Partner selfie check when going online.
--
-- Re-runnable: tables and indexes "if not exists", functions "create or
-- replace", triggers and policies dropped first, rows "on conflict do
-- nothing".
--
-- Why: an approved partner's account can be driven by someone else (a
-- friend, a "rented" account). The owner wants a live selfie now and then
-- when a partner goes online on a phone, compared with their approved
-- profile photo and their ID photo, without ever holding a partner back
-- once they have taken it.
--
-- 1. When a check is due (online_selfie_check_start, the app's call before
--    it goes online; phones only, Android and iOS: the web and desktops are
--    never asked):
--      new_device  the phone is not one the partner used before
--                  (dispatch_devices, 0281: the first time, the phones on
--                  record for them are known). Always on.
--      watch_list  the partner is on the watch list (partner_selfie_watch):
--                  their own rule: every go-online, a % with a daily cap, or
--                  every N hours online; an optional end date; a reason.
--      random      the admin's chance per go-online (20%), at most so many a
--                  day (1).
--    The rule itself is online_selfie_pick (pure, tested). The partner is
--    told "new phone" or "random safety check": never that they are watched.
-- 2. partner_online_checks: one row per check asked. 'due' until the selfie
--    is in; "Not now" and running out of time (3 minutes, the admin's) leave
--    it due and the partner offline, and the next go-online asks the same
--    check again (so declining doesn't roll the dice again). A due check
--    older than a day lapses. While one is due, going online is refused on
--    the server (driver_presence_guard_selfie, as the credit and permit
--    guards). The web, while one is due, says to finish it on the phone.
-- 3. online_selfie_check_submit: the live selfie (blink or turn passed; no
--    file) in the partner's own ID_Image folder. The check is answered and
--    the partner goes online whatever the match: never held. The phone is
--    known from then on. The face-compare function is asked over pg_net
--    (x-push-secret, as 0288's documents) to compare the selfie with the
--    approved profile photo and the ID photo; it keeps the scores with
--    online_selfie_check_store (service role). The match is the better of
--    the two. Below the admin's threshold (60%) is a low match: the partner
--    stays online and the admin's chosen recipients get a push (all admins
--    who see Documents, selected admins, or everyone with the Support role)
--    that opens the check.
-- 4. Admin: online_selfie_config / online_selfie_set_config (Admin ›
--    Dispatch › Partner selfie checks, app_settings 'online_selfie');
--    the watch list (online_selfie_watch_list / _set / _remove, each change
--    in admin_audit_log); online_selfie_checks_list (Documents › Sign-in
--    checks: low matches first, "Needs a closer look"), online_selfie_check_get
--    (the alert's page), online_selfie_check_review ("Looked at it"),
--    online_selfie_person (Edit Partner). Writes go through
--    caller_admin_can_write('rpc:…') with admin_table_pages; reads through
--    online_selfie_admin_reads.
-- Face scores help the admin; nothing here approves, rejects or blocks.
-- ============================================================================

-- ---- 1. The tables ----------------------------------------------------------------------------------
create table if not exists public.partner_online_checks (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles (id) on delete cascade,
  partner_id      uuid references public.partners (id) on delete set null,
  reason          text not null check (reason in ('new_device', 'random', 'watch_list')),
  -- due: asked, no selfie yet; answered: the selfie is in; lapsed: a day
  -- went by unanswered.
  state           text not null default 'due' check (state in ('due', 'answered', 'lapsed')),
  platform        text check (platform is null or platform in ('android', 'ios')),
  device_key      text check (device_key is null or char_length(device_key) <= 128),
  device_model    text check (device_model is null or char_length(device_model) <= 80),
  answer_by       timestamptz not null,
  -- "Not now" or the time ran out, how often and the last.
  skips           integer not null default 0,
  last_skip       text check (last_skip is null or last_skip in ('not_now', 'timeout')),
  last_skip_at    timestamptz,
  answered_at     timestamptz,
  file_url        text check (file_url is null or char_length(file_url) <= 1000),
  liveness        text check (liveness is null or liveness in ('passed', 'not_checked')),
  liveness_detail text check (liveness_detail is null or char_length(liveness_detail) <= 40),
  -- The better of the two comparisons, and each.
  face_state      text check (face_state is null or face_state in ('pending', 'match', 'no_match', 'no_face', 'not_checked', 'error')),
  face_score      numeric(5, 2) check (face_score is null or face_score between 0 and 100),
  photo_state     text check (photo_state is null or char_length(photo_state) <= 20),
  photo_score     numeric(5, 2) check (photo_score is null or photo_score between 0 and 100),
  id_state        text check (id_state is null or char_length(id_state) <= 20),
  id_score        numeric(5, 2) check (id_score is null or id_score between 0 and 100),
  face_provider   text check (face_provider is null or face_provider in ('aws', 'self_hosted')),
  face_reason     text check (face_reason is null or char_length(face_reason) <= 160),
  face_checked_at timestamptz,
  low_match       boolean not null default false,
  alerted_at      timestamptz,
  alert_sent      integer not null default 0,
  reviewed_by     uuid references public.profiles (id) on delete set null,
  reviewed_at     timestamptz,
  review_note     text check (review_note is null or char_length(review_note) <= 500),
  created_at      timestamptz not null default now()
);
comment on table public.partner_online_checks is
  'Partner selfie check on going online (0290): why it was asked (new_device / random / watch_list), the phone, the live selfie, the face match against the profile photo and the ID photo, and the alert sent on a low match. Help for the admin; never holds the partner.';
create unique index if not exists partner_online_checks_due_idx
  on public.partner_online_checks (user_id) where state = 'due';
create index if not exists partner_online_checks_user_idx
  on public.partner_online_checks (user_id, created_at desc);
create index if not exists partner_online_checks_closer_idx
  on public.partner_online_checks (created_at desc) where low_match and reviewed_at is null;
create index if not exists partner_online_checks_created_idx
  on public.partner_online_checks (created_at desc);
create index if not exists partner_online_checks_partner_idx on public.partner_online_checks (partner_id);
create index if not exists partner_online_checks_reviewed_by_idx on public.partner_online_checks (reviewed_by);

create table if not exists public.partner_selfie_watch (
  profile_id  uuid primary key references public.profiles (id) on delete cascade,
  -- every: each go-online; percent: [pct]% of go-onlines, at most [cap] a
  -- day; hours: once every [hours] hours online.
  rule        text not null check (rule in ('every', 'percent', 'hours')),
  pct         integer check (pct is null or pct between 1 and 100),
  cap         integer check (cap is null or cap between 1 and 20),
  hours       integer check (hours is null or hours between 1 and 168),
  until       date,
  reason      text not null check (char_length(btrim(reason)) between 1 and 300),
  from_check  uuid references public.partner_online_checks (id) on delete set null,
  added_by    uuid references public.profiles (id) on delete set null,
  added_at    timestamptz not null default now(),
  updated_by  uuid references public.profiles (id) on delete set null,
  updated_at  timestamptz not null default now(),
  check (rule <> 'percent' or (pct is not null and cap is not null)),
  check (rule <> 'hours' or hours is not null)
);
comment on table public.partner_selfie_watch is
  'Selfie watch list (0290): partners checked more often when going online, with their own rule, an optional end date and the reason. Never shown to the partner. Every change is in admin_audit_log.';
create index if not exists partner_selfie_watch_from_check_idx on public.partner_selfie_watch (from_check);
create index if not exists partner_selfie_watch_added_by_idx on public.partner_selfie_watch (added_by);
create index if not exists partner_selfie_watch_updated_by_idx on public.partner_selfie_watch (updated_by);

-- ---- 2. Who reads, who writes -------------------------------------------------------------------------
-- The admin's settings, with the defaults.
create or replace function public.online_selfie_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
           'randomOn', true, 'randomPct', 20, 'randomCap', 1, 'lowBelow', 60,
           'alertTo', 'all', 'alertAdmins', '[]'::jsonb, 'answerSeconds', 180)
         || coalesce((select s.value from public.app_settings s
                       where s.key = 'online_selfie' and jsonb_typeof(s.value) = 'object'), '{}'::jsonb);
$$;
revoke execute on function public.online_selfie_settings() from public, anon, authenticated;

-- Admins who read the checks: the Documents, Partners and Support pages,
-- Dispatch › Partner selfie checks, and the admins picked for the alert.
create or replace function public.online_selfie_admin_reads()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and (
    exists (select 1 from public.admin_access a
             where a.profile_id = auth.uid()
               and a.page in ('*', 'admin-documents', 'admin-documents-users', 'admin-documents-partners',
                              'admin-partners', 'admin-partner-edit', 'admin-dispatch-selfie-checks',
                              'admin-support', 'admin-support-pool', 'admin-support-chat'))
    or (exists (select 1 from public.admin_access a where a.profile_id = auth.uid())
        and auth.uid()::text in (
          select jsonb_array_elements_text(case when jsonb_typeof(public.online_selfie_settings()->'alertAdmins') = 'array'
                                                then public.online_selfie_settings()->'alertAdmins' else '[]'::jsonb end))));
$$;
revoke execute on function public.online_selfie_admin_reads() from public, anon;
grant execute on function public.online_selfie_admin_reads() to authenticated;

alter table public.partner_online_checks enable row level security;
alter table public.partner_selfie_watch enable row level security;
revoke all on public.partner_online_checks, public.partner_selfie_watch from public, anon, authenticated;
grant select on public.partner_online_checks, public.partner_selfie_watch to authenticated;
grant all on public.partner_online_checks, public.partner_selfie_watch to service_role;

-- The partner reads their own checks (the result on screen); the watch list
-- is the admins' only.
drop policy if exists partner_online_checks_read on public.partner_online_checks;
create policy partner_online_checks_read on public.partner_online_checks
  for select to authenticated using (user_id = (select auth.uid()) or (select public.online_selfie_admin_reads()));
drop policy if exists partner_selfie_watch_read on public.partner_selfie_watch;
create policy partner_selfie_watch_read on public.partner_selfie_watch
  for select to authenticated using ((select public.online_selfie_admin_reads()));

insert into public.admin_table_pages (target, page) values
  ('rpc:online_selfie_set_config',   'admin-dispatch-selfie-checks'),
  ('rpc:online_selfie_watch_set',    'admin-dispatch-selfie-checks'),
  ('rpc:online_selfie_watch_set',    'admin-partners'),
  ('rpc:online_selfie_watch_set',    'admin-partner-edit'),
  ('rpc:online_selfie_watch_set',    'admin-documents'),
  ('rpc:online_selfie_watch_set',    'admin-documents-partners'),
  ('rpc:online_selfie_watch_set',    'admin-support'),
  ('rpc:online_selfie_check_review', 'admin-dispatch-selfie-checks'),
  ('rpc:online_selfie_check_review', 'admin-partner-edit'),
  ('rpc:online_selfie_check_review', 'admin-documents'),
  ('rpc:online_selfie_check_review', 'admin-documents-partners'),
  ('rpc:online_selfie_check_review', 'admin-support')
on conflict do nothing;

-- ---- 3. The rule --------------------------------------------------------------------------------------
-- Which check is due, if any. Pure: what it needs is passed in.
--   p_new_device     the phone is not a known one;
--   p_roll_watch,    two dice in [0, 1);
--   p_roll_random
--   p_random_*       the admin's random check: on, %, how many in the last
--                    day, at most a day;
--   p_watch_rule     the partner's watch-list rule (null: not watched, or it
--                    ended), with its %, how many watch-list checks in the
--                    last day, at most a day, every so many hours, and the
--                    hours online since their last answered check (null:
--                    never checked).
create or replace function public.online_selfie_pick(
  p_new_device boolean,
  p_roll_watch double precision,
  p_roll_random double precision,
  p_random_on boolean,
  p_random_pct integer,
  p_random_recent integer,
  p_random_cap integer,
  p_watch_rule text,
  p_watch_pct integer,
  p_watch_recent integer,
  p_watch_cap integer,
  p_watch_hours integer,
  p_hours_since numeric
)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when coalesce(p_new_device, false) then 'new_device'
    when p_watch_rule = 'every' then 'watch_list'
    when p_watch_rule = 'percent' and coalesce(p_watch_recent, 0) < coalesce(p_watch_cap, 1)
         and coalesce(p_roll_watch, 1) * 100 < coalesce(p_watch_pct, 0) then 'watch_list'
    when p_watch_rule = 'hours'
         and (p_hours_since is null or p_hours_since >= coalesce(p_watch_hours, 1)) then 'watch_list'
    when coalesce(p_random_on, false) and coalesce(p_random_recent, 0) < coalesce(p_random_cap, 1)
         and coalesce(p_roll_random, 1) * 100 < coalesce(p_random_pct, 0) then 'random'
  end;
$$;
grant execute on function public.online_selfie_pick(boolean, double precision, double precision, boolean, integer,
  integer, integer, text, integer, integer, integer, integer, numeric) to authenticated, service_role;

-- A check as the partner's phone reads it. A watch-list check reads as a
-- random one.
create or replace function public.online_selfie_due_json(c public.partner_online_checks, p_seconds integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'due', true, 'id', c.id,
    'reason', case when c.reason = 'new_device' then 'new_device' else 'random' end,
    'answer_seconds', p_seconds, 'answer_by', c.answer_by);
$$;
revoke execute on function public.online_selfie_due_json(public.partner_online_checks, integer) from public, anon, authenticated;

-- ---- 4. The phone ---------------------------------------------------------------------------------------
-- Before going online. [p_device]: the app's device key; [p_platform]:
-- android, ios, web or desktop; [p_model]: the phone's make and model.
--   { due: false }
--   { due: false, blocked: true, message }   (web / desktop while one is due)
--   { due: true, id, reason: new_device | random, answer_seconds, answer_by }
create or replace function public.online_selfie_check_start(
  p_device text default null,
  p_platform text default null,
  p_model text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_partner uuid;
  v_cfg jsonb := public.online_selfie_settings();
  v_secs integer;
  v_key text := nullif(left(btrim(coalesce(p_device, '')), 128), '');
  v_model text := nullif(left(btrim(coalesce(p_model, '')), 80), '');
  v_open public.partner_online_checks;
  v_new boolean;
  w public.partner_selfie_watch;
  v_last timestamptz;
  v_reason text;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select p.id into v_partner from public.partners p where p.auth_user_id = v_uid order by p.created_at limit 1;
  if v_partner is null then
    return jsonb_build_object('due', false);
  end if;
  v_secs := least(greatest(coalesce((v_cfg->>'answerSeconds')::integer, 180), 30), 900);
  update public.partner_online_checks set state = 'lapsed'
   where user_id = v_uid and state = 'due' and created_at < now() - interval '1 day';
  select * into v_open from public.partner_online_checks where user_id = v_uid and state = 'due';

  if coalesce(p_platform, '') not in ('android', 'ios') then
    if v_open.id is not null then
      return jsonb_build_object('due', false, 'blocked', true,
        'message', 'A selfie check is waiting on your phone. Open GET.ride on your phone and go online there first.');
    end if;
    return jsonb_build_object('due', false);
  end if;

  -- The phone in hand, as 0281 notes it (the first time, the phones on
  -- record are known). No key: it can't be told apart, so it is new.
  perform public.dispatch_note_device(v_uid, v_key);
  v_new := v_key is null or char_length(v_key) < 8
           or exists (select 1 from public.dispatch_devices d
                       where d.user_id = v_uid and d.device_key = v_key and not d.known);

  if v_open.id is not null then
    update public.partner_online_checks set
      answer_by = now() + make_interval(secs => v_secs),
      reason = case when v_new then 'new_device' else reason end,
      platform = p_platform, device_key = v_key, device_model = coalesce(v_model, device_model)
     where id = v_open.id
    returning * into v_open;
    return public.online_selfie_due_json(v_open, v_secs);
  end if;

  select * into w from public.partner_selfie_watch x
   where x.profile_id = v_uid and (x.until is null or x.until >= current_date);
  select max(c.answered_at) into v_last from public.partner_online_checks c
   where c.user_id = v_uid and c.state = 'answered';
  v_reason := public.online_selfie_pick(
    v_new, random(), random(),
    coalesce((v_cfg->>'randomOn')::boolean, true),
    coalesce((v_cfg->>'randomPct')::integer, 20),
    (select count(*)::integer from public.partner_online_checks c
      where c.user_id = v_uid and c.reason = 'random' and c.created_at > now() - interval '1 day'),
    coalesce((v_cfg->>'randomCap')::integer, 1),
    w.rule, w.pct,
    (select count(*)::integer from public.partner_online_checks c
      where c.user_id = v_uid and c.reason = 'watch_list' and c.created_at > now() - interval '1 day'),
    w.cap, w.hours,
    case when w.rule = 'hours' and v_last is not null then public.partner_online_hours(v_uid, v_last, now()) end);
  if v_reason is null then
    return jsonb_build_object('due', false);
  end if;
  insert into public.partner_online_checks (user_id, partner_id, reason, platform, device_key, device_model, answer_by)
  values (v_uid, v_partner, v_reason, p_platform, v_key, v_model, now() + make_interval(secs => v_secs))
  returning * into v_open;
  return public.online_selfie_due_json(v_open, v_secs);
end;
$$;
revoke execute on function public.online_selfie_check_start(text, text, text) from public, anon;
grant execute on function public.online_selfie_check_start(text, text, text) to authenticated;

-- "Not now" or the time ran out: the check stays due, the partner offline.
create or replace function public.online_selfie_check_skip(p_id uuid, p_why text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  update public.partner_online_checks set
    skips = skips + 1,
    last_skip = case when p_why = 'timeout' then 'timeout' else 'not_now' end,
    last_skip_at = now()
   where id = p_id and user_id = auth.uid() and state = 'due';
end;
$$;
revoke execute on function public.online_selfie_check_skip(uuid, text) from public, anon;
grant execute on function public.online_selfie_check_skip(uuid, text) to authenticated;

-- Asks the face-compare function to compare one check (best effort: with no
-- project URL or webhook secret in Vault nothing is sent).
create or replace function public.online_selfie_face_kick(p_id uuid)
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
    body    := jsonb_build_object('online_check', jsonb_build_object('id', p_id))
  );
  return true;
exception when others then
  return false;
end;
$$;
revoke execute on function public.online_selfie_face_kick(uuid) from public, anon, authenticated;

-- The live selfie, already in the partner's own ID_Image folder.
--   p: { file_url, liveness: 'passed', liveness_detail?, model? }
-- Returns { id, state: 'answered', face_state }. The partner goes online
-- whatever the match.
create or replace function public.online_selfie_check_submit(p_id uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  c public.partner_online_checks;
  v_file text := nullif(btrim(coalesce(p->>'file_url', '')), '');
  v_sent boolean;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into c from public.partner_online_checks where id = p_id and user_id = v_uid for update;
  if not found then
    raise exception 'ONLINE_SELFIE_NOT_FOUND' using errcode = '22023', hint = 'Tap Go online to start again.';
  end if;
  if c.state = 'answered' then
    return jsonb_build_object('id', c.id, 'state', c.state, 'face_state', c.face_state);
  end if;
  if c.state <> 'due' or now() > c.answer_by + interval '1 minute' then
    raise exception 'ONLINE_SELFIE_LATE' using errcode = '22023',
      hint = 'The time to answer ran out. Tap Go online to try again.';
  end if;
  if v_file is null or strpos(v_file, '/ID_Image/' || v_uid::text || '/') = 0 then
    raise exception 'IDENTITY_FILE' using errcode = '22023', hint = 'Upload the photo again.';
  end if;
  if coalesce(p->>'liveness', '') <> 'passed' then
    raise exception 'ONLINE_SELFIE_LIVE' using errcode = '22023',
      hint = 'Take the selfie with the live check: blink or turn your head.';
  end if;
  update public.partner_online_checks set
    state = 'answered', answered_at = now(), file_url = v_file, liveness = 'passed',
    liveness_detail = nullif(left(coalesce(p->>'liveness_detail', ''), 40), ''),
    device_model = coalesce(nullif(left(btrim(coalesce(p->>'model', '')), 80), ''), device_model),
    face_state = 'pending'
   where id = c.id
  returning * into c;
  -- The phone is known from now on (one selfie answers 0281's re-check too).
  if c.device_key is not null and char_length(c.device_key) >= 8 then
    insert into public.dispatch_devices (user_id, device_key, known, seen_at)
    values (v_uid, c.device_key, true, clock_timestamp())
    on conflict (user_id, device_key) do update set known = true, seen_at = clock_timestamp();
  end if;
  v_sent := public.online_selfie_face_kick(c.id);
  if not v_sent then
    update public.partner_online_checks set face_state = 'not_checked', face_reason = 'not_sent', face_checked_at = now()
     where id = c.id
    returning * into c;
  end if;
  return jsonb_build_object('id', c.id, 'state', c.state, 'face_state', c.face_state);
end;
$$;
revoke execute on function public.online_selfie_check_submit(uuid, jsonb) from public, anon;
grant execute on function public.online_selfie_check_submit(uuid, jsonb) to authenticated;

-- Going online while a check is due is kept offline (as the credit and
-- permit guards). A check left a day lapses and no longer holds.
create or replace function public.driver_presence_guard_selfie()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.online and exists (select 1 from public.partner_online_checks c
                             where c.user_id = new.profile_id and c.state = 'due'
                               and c.created_at > now() - interval '1 day') then
    new.online := false;
  end if;
  return new;
end;
$$;
revoke execute on function public.driver_presence_guard_selfie() from public, anon, authenticated;
drop trigger if exists trg_driver_presence_guard_selfie on public.driver_presence;
create trigger trg_driver_presence_guard_selfie
  before insert or update on public.driver_presence
  for each row execute function public.driver_presence_guard_selfie();

-- ---- 5. The face match (face-compare, service role) --------------------------------------------------
-- What to compare: the selfie, the approved profile photo (the partner's,
-- else the profile's) and the ID photo (the National ID on the profile,
-- else the newest approved sign-in ID).
create or replace function public.online_selfie_face_source(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'user_id', c.user_id,
    'selfie_url', c.file_url,
    'photo_url', coalesce(nullif(btrim(pa.avatar_url), ''), nullif(btrim(pr.avatar_url), '')),
    'id_url', coalesce(nullif(btrim(pr.id_image), ''),
                       (select i.file_url from public.identity_checks i
                         where i.user_id = c.user_id and i.kind = 'id' and i.status = 'Approved'
                         order by i.created_at desc limit 1)))
    from public.partner_online_checks c
    join public.profiles pr on pr.id = c.user_id
    left join public.partners pa on pa.id = c.partner_id
   where c.id = p_id;
$$;
revoke execute on function public.online_selfie_face_source(uuid) from public, anon, authenticated;
grant execute on function public.online_selfie_face_source(uuid) to service_role;

-- Who gets the low-match push: all admins who see Documents (default),
-- the selected admins, or everyone with the Support role (a Support page,
-- or a support-queue priority). Never the partner themself.
create or replace function public.online_selfie_alert_recipients(p_partner uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  with cfg as (select public.online_selfie_settings() as v)
  select distinct a.profile_id
    from public.admin_access a, cfg
   where a.profile_id is distinct from p_partner
     and case coalesce(cfg.v->>'alertTo', 'all')
           when 'selected' then a.profile_id::text in (
             select jsonb_array_elements_text(case when jsonb_typeof(cfg.v->'alertAdmins') = 'array'
                                                   then cfg.v->'alertAdmins' else '[]'::jsonb end))
           when 'support' then a.page in ('admin-support', 'admin-support-pool', 'admin-support-chat')
                               or a.support is not null
           else a.page in ('*', 'admin-documents', 'admin-documents-users', 'admin-documents-partners')
         end;
$$;
revoke execute on function public.online_selfie_alert_recipients(uuid) from public, anon, authenticated;

-- "Low selfie match: <name>, 41%, new phone".
create or replace function public.online_selfie_alert_text(p_name text, p_score numeric, p_reason text)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'Low selfie match: ' || coalesce(nullif(btrim(p_name), ''), 'A partner') || ', '
         || coalesce(round(p_score)::text, '?') || '%, '
         || case p_reason when 'new_device' then 'new phone' when 'random' then 'random check'
                          else 'watch list' end;
$$;

create or replace function public.online_selfie_alert(p_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.partner_online_checks;
  v_name text;
  v_body text;
  n integer := 0;
  r uuid;
begin
  select * into c from public.partner_online_checks where id = p_id;
  if not found or not c.low_match then
    return 0;
  end if;
  select coalesce(nullif(btrim(pa.name), ''), nullif(btrim(pr.name), ''), pr.phone)
    into v_name
    from public.profiles pr left join public.partners pa on pa.id = c.partner_id
   where pr.id = c.user_id;
  v_body := public.online_selfie_alert_text(v_name, c.face_score, c.reason);
  for r in select * from public.online_selfie_alert_recipients(c.user_id) loop
    perform public.approval_push_send(r,
      jsonb_build_object('title', 'Selfie check', 'body', v_body),
      jsonb_build_object('type', 'online_selfie_check', 'check_id', c.id, 'for', 'admin'));
    n := n + 1;
  end loop;
  update public.partner_online_checks set alerted_at = now(), alert_sent = n where id = c.id;
  return n;
end;
$$;
revoke execute on function public.online_selfie_alert(uuid) from public, anon, authenticated;

-- The face-compare function keeps the comparison. A low match (below the
-- admin's threshold) alerts the recipients once.
--   p: { state, score, provider, reason, photo: {state, score}, id: {state, score} }
create or replace function public.online_selfie_check_store(p_id uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.partner_online_checks;
  v_low numeric := coalesce((public.online_selfie_settings()->>'lowBelow')::numeric, 60);
  v_state text := p->>'state';
  v_score numeric;
begin
  begin
    v_score := least(greatest((p->>'score')::numeric, 0), 100);
  exception when others then
    v_score := null;
  end;
  if v_state is null or v_state not in ('match', 'no_match', 'no_face', 'not_checked', 'error') then
    v_state := 'error';
  end if;
  update public.partner_online_checks set
    face_state = v_state,
    face_score = v_score,
    photo_state = left(p->'photo'->>'state', 20),
    photo_score = case when jsonb_typeof(p->'photo'->'score') = 'number'
                       then least(greatest((p->'photo'->>'score')::numeric, 0), 100) end,
    id_state = left(p->'id'->>'state', 20),
    id_score = case when jsonb_typeof(p->'id'->'score') = 'number'
                    then least(greatest((p->'id'->>'score')::numeric, 0), 100) end,
    face_provider = case when p->>'provider' in ('aws', 'self_hosted') then p->>'provider' end,
    face_reason = left(nullif(p->>'reason', ''), 160),
    face_checked_at = now(),
    low_match = v_score is not null and v_score < v_low
   where id = p_id and state = 'answered'
  returning * into c;
  if not found then
    raise exception 'ONLINE_SELFIE_NOT_FOUND' using errcode = '22023';
  end if;
  if c.low_match and c.alerted_at is null then
    perform public.online_selfie_alert(c.id);
  end if;
  return jsonb_build_object('id', c.id, 'face_state', c.face_state, 'face_score', c.face_score,
                            'low_match', c.low_match);
end;
$$;
revoke execute on function public.online_selfie_check_store(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.online_selfie_check_store(uuid, jsonb) to service_role;

-- ---- 6. The admin --------------------------------------------------------------------------------------
create or replace function public.online_selfie_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.online_selfie_admin_reads() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return public.online_selfie_settings();
end;
$$;
revoke execute on function public.online_selfie_config() from public, anon;
grant execute on function public.online_selfie_config() to authenticated;

-- Admin › Dispatch › Partner selfie checks. A key left out keeps its value.
--   p: { randomOn, randomPct (0-100), randomCap (1-20), lowBelow (1-99),
--        alertTo: all | selected | support, alertAdmins: [profile ids],
--        answerSeconds (30-900) }
create or replace function public.online_selfie_set_config(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := '{}'::jsonb;
  v_admins jsonb;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:online_selfie_set_config') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'ONLINE_SELFIE_BAD_REQUEST' using errcode = '22023';
  end if;
  if p ? 'randomOn' then
    if jsonb_typeof(p->'randomOn') <> 'boolean' then
      raise exception 'ONLINE_SELFIE_BAD_REQUEST' using errcode = '22023';
    end if;
    v := v || jsonb_build_object('randomOn', (p->>'randomOn')::boolean);
  end if;
  if p ? 'randomPct' then
    if jsonb_typeof(p->'randomPct') <> 'number' or (p->>'randomPct')::numeric not between 0 and 100 then
      raise exception 'ONLINE_SELFIE_PCT' using errcode = '22023', hint = 'Give a chance from 0 to 100%.';
    end if;
    v := v || jsonb_build_object('randomPct', round((p->>'randomPct')::numeric)::integer);
  end if;
  if p ? 'randomCap' then
    if jsonb_typeof(p->'randomCap') <> 'number' or (p->>'randomCap')::numeric not between 1 and 20 then
      raise exception 'ONLINE_SELFIE_CAP' using errcode = '22023', hint = 'Give 1 to 20 checks a day.';
    end if;
    v := v || jsonb_build_object('randomCap', round((p->>'randomCap')::numeric)::integer);
  end if;
  if p ? 'lowBelow' then
    if jsonb_typeof(p->'lowBelow') <> 'number' or (p->>'lowBelow')::numeric not between 1 and 99 then
      raise exception 'ONLINE_SELFIE_LOW' using errcode = '22023', hint = 'Give a match from 1 to 99%.';
    end if;
    v := v || jsonb_build_object('lowBelow', round((p->>'lowBelow')::numeric)::integer);
  end if;
  if p ? 'answerSeconds' then
    if jsonb_typeof(p->'answerSeconds') <> 'number' or (p->>'answerSeconds')::numeric not between 30 and 900 then
      raise exception 'ONLINE_SELFIE_TIME' using errcode = '22023', hint = 'Give 30 seconds to 15 minutes.';
    end if;
    v := v || jsonb_build_object('answerSeconds', round((p->>'answerSeconds')::numeric)::integer);
  end if;
  if p ? 'alertTo' then
    if coalesce(p->>'alertTo', '') not in ('all', 'selected', 'support') then
      raise exception 'ONLINE_SELFIE_BAD_REQUEST' using errcode = '22023';
    end if;
    v := v || jsonb_build_object('alertTo', p->>'alertTo');
  end if;
  if p ? 'alertAdmins' then
    if jsonb_typeof(p->'alertAdmins') <> 'array' or jsonb_array_length(p->'alertAdmins') > 50 then
      raise exception 'ONLINE_SELFIE_BAD_REQUEST' using errcode = '22023';
    end if;
    -- Only people who are admins, each once.
    select coalesce(jsonb_agg(distinct x), '[]'::jsonb) into v_admins
      from jsonb_array_elements_text(p->'alertAdmins') x
     where x ~* '^[0-9a-f-]{36}$'
       and exists (select 1 from public.admin_access a where a.profile_id = x::uuid);
    v := v || jsonb_build_object('alertAdmins', v_admins);
  end if;
  if coalesce((public.online_selfie_settings() || v)->>'alertTo', 'all') = 'selected'
     and jsonb_array_length(coalesce((public.online_selfie_settings() || v)->'alertAdmins', '[]'::jsonb)) = 0 then
    raise exception 'ONLINE_SELFIE_NO_ADMINS' using errcode = '22023', hint = 'Pick at least one admin for the alert.';
  end if;
  insert into public.app_settings (key, value) values ('online_selfie', v)
  on conflict (key) do update set value = public.app_settings.value || excluded.value, updated_at = now();
  insert into public.admin_audit_log (actor_id, action, detail)
  values (auth.uid(), 'online_selfie.config', v);
  return public.online_selfie_settings();
end;
$$;
revoke execute on function public.online_selfie_set_config(jsonb) from public, anon;
grant execute on function public.online_selfie_set_config(jsonb) to authenticated;

-- A watch-list entry as the admin reads it.
create or replace function public.online_selfie_watch_json(w public.partner_selfie_watch)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when w.profile_id is null then null else
    to_jsonb(w) || jsonb_build_object(
      'active', w.until is null or w.until >= current_date,
      'added_by_name', public.dispatch_actor_name(w.added_by),
      'updated_by_name', public.dispatch_actor_name(w.updated_by)) end;
$$;
revoke execute on function public.online_selfie_watch_json(public.partner_selfie_watch) from public, anon, authenticated;

create or replace function public.online_selfie_watch_list()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.online_selfie_admin_reads() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(public.online_selfie_watch_json(w) || jsonb_build_object(
             'name', coalesce(nullif(btrim(pa.name), ''), pr.name), 'phone', pr.phone, 'partner_id', pa.id)
           order by w.added_at desc)
      from public.partner_selfie_watch w
      join public.profiles pr on pr.id = w.profile_id
      left join lateral (select x.id, x.name from public.partners x where x.auth_user_id = w.profile_id
                          order by x.created_at limit 1) pa on true), '[]'::jsonb);
end;
$$;
revoke execute on function public.online_selfie_watch_list() from public, anon;
grant execute on function public.online_selfie_watch_list() to authenticated;

-- Puts [p_user] on the watch list, or changes their rule. [p_check]: the
-- check it was set from (the alert).
create or replace function public.online_selfie_watch_set(
  p_user uuid,
  p_rule text,
  p_pct integer default null,
  p_cap integer default null,
  p_hours integer default null,
  p_until date default null,
  p_reason text default null,
  p_check uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reason text := nullif(left(btrim(coalesce(p_reason, '')), 300), '');
  v_had boolean;
  w public.partner_selfie_watch;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:online_selfie_watch_set') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if not exists (select 1 from public.partners p where p.auth_user_id = p_user) then
    raise exception 'ONLINE_SELFIE_NOT_PARTNER' using errcode = '22023', hint = 'Only partners go online.';
  end if;
  if p_rule is null or p_rule not in ('every', 'percent', 'hours') then
    raise exception 'ONLINE_SELFIE_BAD_REQUEST' using errcode = '22023';
  end if;
  if p_rule = 'percent' and (p_pct is null or p_pct not between 1 and 100 or p_cap is null or p_cap not between 1 and 20) then
    raise exception 'ONLINE_SELFIE_PCT' using errcode = '22023', hint = 'Give a chance from 1 to 100% and 1 to 20 checks a day.';
  end if;
  if p_rule = 'hours' and (p_hours is null or p_hours not between 1 and 168) then
    raise exception 'ONLINE_SELFIE_HOURS' using errcode = '22023', hint = 'Give 1 to 168 hours.';
  end if;
  if p_until is not null and p_until < current_date then
    raise exception 'ONLINE_SELFIE_UNTIL' using errcode = '22023', hint = 'The end date is in the past.';
  end if;
  if v_reason is null then
    raise exception 'ONLINE_SELFIE_REASON' using errcode = '22023', hint = 'Say why they are on the watch list.';
  end if;
  if p_check is not null and not exists (select 1 from public.partner_online_checks c
                                          where c.id = p_check and c.user_id = p_user) then
    p_check := null;
  end if;
  v_had := exists (select 1 from public.partner_selfie_watch where profile_id = p_user);
  insert into public.partner_selfie_watch as x (profile_id, rule, pct, cap, hours, until, reason, from_check,
                                                added_by, updated_by)
  values (p_user, p_rule,
          case when p_rule = 'percent' then p_pct end, case when p_rule = 'percent' then p_cap end,
          case when p_rule = 'hours' then p_hours end, p_until, v_reason, p_check, auth.uid(), auth.uid())
  on conflict (profile_id) do update set
    rule = excluded.rule, pct = excluded.pct, cap = excluded.cap, hours = excluded.hours,
    until = excluded.until, reason = excluded.reason, from_check = coalesce(excluded.from_check, x.from_check),
    updated_by = auth.uid(), updated_at = now()
  returning * into w;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), case when v_had then 'online_selfie.watch_change' else 'online_selfie.watch_add' end, p_user,
          jsonb_strip_nulls(jsonb_build_object('rule', w.rule, 'pct', w.pct, 'cap', w.cap, 'hours', w.hours,
                                               'until', w.until, 'reason', w.reason, 'check_id', p_check)));
  return public.online_selfie_watch_json(w);
end;
$$;
revoke execute on function public.online_selfie_watch_set(uuid, text, integer, integer, integer, date, text, uuid)
  from public, anon;
grant execute on function public.online_selfie_watch_set(uuid, text, integer, integer, integer, date, text, uuid)
  to authenticated;

-- Back on the normal rule.
create or replace function public.online_selfie_watch_remove(p_user uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  w public.partner_selfie_watch;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:online_selfie_watch_set') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  delete from public.partner_selfie_watch where profile_id = p_user returning * into w;
  if not found then
    return false;
  end if;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'online_selfie.watch_remove', p_user,
          jsonb_strip_nulls(jsonb_build_object('rule', w.rule, 'reason', w.reason)));
  return true;
end;
$$;
revoke execute on function public.online_selfie_watch_remove(uuid) from public, anon;
grant execute on function public.online_selfie_watch_remove(uuid) to authenticated;

-- A check as the admin reads it: who, and whether it needs a closer look.
create or replace function public.online_selfie_check_json(c public.partner_online_checks)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select to_jsonb(c) - 'device_key' || jsonb_build_object(
    'name', coalesce(nullif(btrim(pa.name), ''), pr.name),
    'phone', pr.phone,
    'partner_id', coalesce(c.partner_id, pa.id),
    'closer', c.low_match and c.reviewed_at is null,
    'reviewer', public.dispatch_actor_name(c.reviewed_by),
    'watched', exists (select 1 from public.partner_selfie_watch w
                        where w.profile_id = c.user_id and (w.until is null or w.until >= current_date)))
    from public.profiles pr
    left join public.partners pa on pa.id = c.partner_id
   where pr.id = c.user_id;
$$;
revoke execute on function public.online_selfie_check_json(public.partner_online_checks) from public, anon, authenticated;

-- Documents › Sign-in checks: [p_filter] 'closer' (low matches not looked
-- at yet) or 'all'. Low matches not looked at first, then the newest.
create or replace function public.online_selfie_checks_list(p_filter text default 'all')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.online_selfie_admin_reads() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(public.online_selfie_check_json(c)
                     order by (c.low_match and c.reviewed_at is null) desc, c.created_at desc)
      from (select * from public.partner_online_checks x
             where x.state <> 'lapsed'
               and (coalesce(p_filter, 'all') <> 'closer' or (x.low_match and x.reviewed_at is null))
             order by (x.low_match and x.reviewed_at is null) desc, x.created_at desc
             limit 300) c), '[]'::jsonb);
end;
$$;
revoke execute on function public.online_selfie_checks_list(text) from public, anon;
grant execute on function public.online_selfie_checks_list(text) to authenticated;

-- How many need a closer look, for the Sign-in checks count.
create or replace function public.online_selfie_closer_count()
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select case when public.online_selfie_admin_reads()
              then (select count(*)::integer from public.partner_online_checks
                     where low_match and reviewed_at is null) end;
$$;
revoke execute on function public.online_selfie_closer_count() from public, anon;
grant execute on function public.online_selfie_closer_count() to authenticated;

-- The alert's page: the check, the photos it was compared with, the watch
-- list entry, and whether the partner is online now.
create or replace function public.online_selfie_check_get(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c public.partner_online_checks;
begin
  if not public.online_selfie_admin_reads() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into c from public.partner_online_checks where id = p_id;
  if not found then
    return null;
  end if;
  return public.online_selfie_check_json(c)
    || jsonb_build_object(
         'photo_url', public.online_selfie_face_source(c.id)->>'photo_url',
         'id_url', public.online_selfie_face_source(c.id)->>'id_url',
         'watch', (select public.online_selfie_watch_json(w) from public.partner_selfie_watch w
                    where w.profile_id = c.user_id),
         'online_now', exists (select 1 from public.driver_presence d
                                where d.profile_id = c.user_id and d.online
                                  and d.updated_at > now() - interval '3 minutes'),
         'low_below', (public.online_selfie_settings()->>'lowBelow')::integer);
end;
$$;
revoke execute on function public.online_selfie_check_get(uuid) from public, anon;
grant execute on function public.online_selfie_check_get(uuid) to authenticated;

-- "Looked at it": the check leaves "Needs a closer look".
create or replace function public.online_selfie_check_review(p_id uuid, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c public.partner_online_checks;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:online_selfie_check_review') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  update public.partner_online_checks set
    reviewed_by = auth.uid(), reviewed_at = now(), review_note = nullif(left(btrim(coalesce(p_note, '')), 500), '')
   where id = p_id and state = 'answered'
  returning * into c;
  if not found then
    raise exception 'ONLINE_SELFIE_NOT_FOUND' using errcode = '22023';
  end if;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (auth.uid(), 'online_selfie.review', c.user_id,
          jsonb_strip_nulls(jsonb_build_object('check_id', c.id, 'score', c.face_score, 'note', c.review_note)));
  return public.online_selfie_check_json(c);
end;
$$;
revoke execute on function public.online_selfie_check_review(uuid, text) from public, anon;
grant execute on function public.online_selfie_check_review(uuid, text) to authenticated;

-- Edit Partner: the partner's last checks and their watch-list entry.
create or replace function public.online_selfie_person(p_user uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.online_selfie_admin_reads() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'checks', coalesce((
      select jsonb_agg(public.online_selfie_check_json(c) order by c.created_at desc)
        from (select * from public.partner_online_checks x
               where x.user_id = p_user order by x.created_at desc limit 10) c), '[]'::jsonb),
    'watch', (select public.online_selfie_watch_json(w) from public.partner_selfie_watch w where w.profile_id = p_user));
end;
$$;
revoke execute on function public.online_selfie_person(uuid) from public, anon;
grant execute on function public.online_selfie_person(uuid) to authenticated;

notify pgrst, 'reload schema';

insert into supabase_migrations.schema_migrations (version, name)
values ('20261024200000', '0290_partner_online_selfie')
on conflict do nothing;
