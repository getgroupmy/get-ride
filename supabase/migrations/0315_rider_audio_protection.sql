-- ============================================================================
-- 0315 — Rider audio protection: the rider's side of the driver's
-- VoiceProtection (0040 / 0223). docs/KIV.md: "Rider-side audio recording".
--
-- Version 20261028080000 (0315_rider_audio_protection). Re-runnable: the
-- table, columns and indexes "if not exists", functions "create or
-- replace", policies and triggers dropped first, the Default row only where
-- missing.
--
-- How it works (lib/src/core/rider_audio.dart is the app's half):
--   * The rider turns "Audio protection" on (off until they do; the phone
--     remembers it). On a phone app, while their ride is under way (Start
--     trip to the end), the phone records the trip with its microphone,
--     keeps the file encrypted in the app's private folder for the hours
--     the admin set, and never plays it back. A metadata row in
--     voice_protection_recordings (recorded_by 'rider') lets support ask for
--     it from a support ticket or the ride's page; the rider's phone then
--     uploads it to the private voice-protection bucket (the owner's folder,
--     as the driver's), and only admins with Support or Rides can play it.
--   * The driver sees "Audio protection on (rider)": ride_requests.rider_audio.
--
-- 1. rider_audio_rules: Admin → Services & catalogue → Rider audio
--    protection. A Default row (everywhere) and a row per country, state,
--    city or suburb, named as the region tables name them (as
--    ride_option_places, 0253). Each part is set or left to the place
--    above: enabled (on / off), keep_hours (1 to 168, how long the phone
--    keeps a recording). Default: on, 24 hours. For a pickup the smallest
--    place that sets a part decides it. Admins with EDIT on
--    admin-settings-rider-audio write it (admin_table_pages, 0223);
--    everyone signed in reads it. These keys are kept apart from any other
--    city-ride settings so the page can later move under "City ride extras".
-- 2. rider_audio_settings_at(country, state, city, suburb) → {enabled,
--    keepHours} (the server's), and rider_audio_at(lat, lng, country, state,
--    city) for the app: the same at the place the server reads a pickup at
--    (ride_option_place, 0253).
-- 3. ride_requests.rider_audio (default false): the rider has audio
--    protection on for this ride. A booking sent with it where it is off is
--    booked with it off (never refused). The rider changes it on their own
--    ride, while it is under way, with ride_set_rider_audio(ride, on): on
--    only where it is on at the pickup; off any time. Nobody else changes
--    it but admins and the server.
-- 4. voice_protection_recordings.recorded_by ('driver' | 'rider', default
--    'driver': every row so far is a driver's). A rider's row must name the
--    rider's own ride, with rider_audio on and audio protection on at its
--    pickup (RIDER_AUDIO_NOT_ALLOWED); the server sets expires_at to the
--    recording time plus the hours at the pickup, so the phone and support
--    agree on when it is gone. recorded_by is the server's after insert.
--    The request / upload flow, the bucket and its rules, and account
--    deletion (0194) are the driver's, unchanged.
-- ============================================================================

-- ---- 1. The settings by place -------------------------------------------------------------------
create table if not exists public.rider_audio_rules (
  id         uuid primary key default gen_random_uuid(),
  level      text not null check (level in ('default', 'country', 'state', 'city', 'suburb')),
  country    text check (country is null or char_length(btrim(country)) between 1 and 120),
  state      text check (state is null or char_length(btrim(state)) between 1 and 120),
  city       text check (city is null or char_length(btrim(city)) between 1 and 120),
  suburb     text check (suburb is null or char_length(btrim(suburb)) between 1 and 120),
  place_key  text generated always as (public.ride_option_place_key(level, country, state, city, suburb)) stored,
  -- Null: the place above decides.
  enabled    boolean,
  keep_hours integer check (keep_hours is null or keep_hours between 1 and 168),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- A place names every level above its own.
  constraint rider_audio_rules_names check (
    (level = 'default' and country is null and state is null and city is null and suburb is null)
    or (level = 'country' and country is not null and state is null and city is null and suburb is null)
    or (level = 'state' and country is not null and state is not null and city is null and suburb is null)
    or (level = 'city' and country is not null and state is not null and city is not null and suburb is null)
    or (level = 'suburb' and country is not null and state is not null and city is not null and suburb is not null)),
  -- Default sets both parts.
  constraint rider_audio_rules_default_full check (
    level <> 'default' or (enabled is not null and keep_hours is not null))
);
create unique index if not exists rider_audio_rules_key_uidx on public.rider_audio_rules (place_key);
comment on table public.rider_audio_rules is
  'Rider audio protection by place (0315): on/off and the hours a recording stays on the rider''s phone, for Default or a country / state / city / suburb. The smallest place that sets a part decides it.';

drop trigger if exists trg_rider_audio_rules_updated_at on public.rider_audio_rules;
create trigger trg_rider_audio_rules_updated_at before update on public.rider_audio_rules
  for each row execute function public.set_updated_at();

-- Default stays: it can be changed, not deleted.
create or replace function public.rider_audio_rules_keep_default()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.level = 'default' then
    raise exception 'RIDER_AUDIO_DEFAULT_STAYS' using errcode = '42501',
      hint = 'The Default rule can be changed but not deleted.';
  end if;
  return old;
end;
$$;
revoke execute on function public.rider_audio_rules_keep_default() from public, anon, authenticated;

drop trigger if exists trg_rider_audio_rules_keep_default on public.rider_audio_rules;
create trigger trg_rider_audio_rules_keep_default before delete on public.rider_audio_rules
  for each row execute function public.rider_audio_rules_keep_default();

alter table public.rider_audio_rules enable row level security;
revoke all on public.rider_audio_rules from anon;
grant select, insert, update, delete on public.rider_audio_rules to authenticated;

drop policy if exists "rider_audio_rules read" on public.rider_audio_rules;
drop policy if exists "rider_audio_rules admin insert" on public.rider_audio_rules;
drop policy if exists "rider_audio_rules admin update" on public.rider_audio_rules;
drop policy if exists "rider_audio_rules admin delete" on public.rider_audio_rules;
create policy "rider_audio_rules read" on public.rider_audio_rules for select to authenticated
  using ((select auth.uid()) is not null);
create policy "rider_audio_rules admin insert" on public.rider_audio_rules for insert to authenticated
  with check ((select public.caller_admin_can_write('rider_audio_rules')));
create policy "rider_audio_rules admin update" on public.rider_audio_rules for update to authenticated
  using ((select public.caller_admin_can_write('rider_audio_rules')))
  with check ((select public.caller_admin_can_write('rider_audio_rules')));
create policy "rider_audio_rules admin delete" on public.rider_audio_rules for delete to authenticated
  using ((select public.caller_admin_can_write('rider_audio_rules')));

insert into public.admin_table_pages (target, page) values
  ('rider_audio_rules', 'admin-settings-rider-audio')
on conflict do nothing;

insert into public.rider_audio_rules (level, enabled, keep_hours)
values ('default', true, 24)
on conflict (place_key) do nothing;

-- ---- 2. What holds at a place -------------------------------------------------------------------
-- {enabled, keepHours}: each part from the smallest place (of Default, the
-- country, state, city and suburb named) that sets it; nothing anywhere:
-- on, 24 hours.
create or replace function public.rider_audio_settings_at(p_country text, p_state text, p_city text, p_suburb text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.rider_audio_rules;
  v_on boolean := true;
  v_hours integer := 24;
  k text[] := array[''];
  c text := lower(btrim(coalesce(p_country, '')));
  s text := lower(btrim(coalesce(p_state, '')));
  t text := lower(btrim(coalesce(p_city, '')));
  b text := lower(btrim(coalesce(p_suburb, '')));
begin
  if c <> '' then
    k := k || c;
    if s <> '' then
      k := k || (c || '|' || s);
      if t <> '' then
        k := k || (c || '|' || s || '|' || t);
        if b <> '' then
          k := k || (c || '|' || s || '|' || t || '|' || b);
        end if;
      end if;
    end if;
  end if;
  for r in
    select p.* from public.rider_audio_rules p
     where p.place_key = any (k)
     order by case p.level when 'default' then 0 when 'country' then 1 when 'state' then 2
                           when 'city' then 3 else 4 end
  loop
    v_on := coalesce(r.enabled, v_on);
    v_hours := coalesce(r.keep_hours, v_hours);
  end loop;
  return jsonb_build_object('enabled', v_on, 'keepHours', v_hours);
end;
$$;
revoke execute on function public.rider_audio_settings_at(text, text, text, text) from public, anon, authenticated;

-- What holds at a ride's pickup.
create or replace function public.rider_audio_settings_for_ride(p_ride uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.rider_audio_settings_at(p.country, p.state, p.city, p.suburb)
    from public.ride_requests r
   cross join lateral public.ride_option_place(r.pickup_lat, r.pickup_lng, r.country, r.state, r.city) p
   where r.id = p_ride;
$$;
revoke execute on function public.rider_audio_settings_for_ride(uuid) from public, anon, authenticated;

-- For the app: what holds at a pickup, read at the place the server will.
create or replace function public.rider_audio_at(p_lat double precision, p_lng double precision,
                                                 p_country text default null, p_state text default null,
                                                 p_city text default null)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.rider_audio_settings_at(p.country, p.state, p.city, p.suburb)
    from public.ride_option_place(p_lat, p_lng, p_country, p_state, p_city) p;
$$;
revoke execute on function public.rider_audio_at(double precision, double precision, text, text, text)
  from public, anon;
grant execute on function public.rider_audio_at(double precision, double precision, text, text, text)
  to authenticated;

-- ---- 3. The ride says whether the rider has it on -----------------------------------------------
alter table public.ride_requests add column if not exists rider_audio boolean not null default false;
comment on column public.ride_requests.rider_audio is
  'The rider has audio protection on for this ride (0315): their phone records the trip. Shown to the driver.';

-- App bookings and changes: on only where it is on at the pickup; a change
-- only by the ride's rider, while the ride is under way. A booking is never
-- refused for it: it is booked with it off.
create or replace function public.ride_requests_rider_audio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- The session's role, as 0253: this runs as its owner.
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated')
     or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.rider_audio then
      select coalesce((public.rider_audio_settings_at(p.country, p.state, p.city, p.suburb)->>'enabled')::boolean, false)
        into new.rider_audio
        from public.ride_option_place(new.pickup_lat, new.pickup_lng, new.country, new.state, new.city) p;
      new.rider_audio := coalesce(new.rider_audio, false);
    end if;
    return new;
  end if;
  if new.rider_audio is distinct from old.rider_audio then
    if auth.uid() is distinct from old.rider_id then
      raise exception 'RIDER_AUDIO_RIDER_ONLY' using errcode = '42501',
        hint = 'Only the rider turns their audio protection on or off.';
    end if;
    if new.rider_audio and (old.status not in ('open', 'accepted', 'arrived', 'on_trip')
       or not coalesce((public.rider_audio_settings_for_ride(old.id)->>'enabled')::boolean, false)) then
      raise exception 'RIDER_AUDIO_OFF_HERE' using errcode = '42501',
        hint = 'Audio protection isn''t offered for this ride.';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_rider_audio() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_zz_rider_audio on public.ride_requests;
create trigger trg_ride_requests_zz_rider_audio
  before insert or update of rider_audio on public.ride_requests
  for each row execute function public.ride_requests_rider_audio();

-- The rider turns it on or off for their ride under way. Answers what the
-- ride now says.
create or replace function public.ride_set_rider_audio(p_ride uuid, p_on boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  r public.ride_requests;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_ride for update;
  if not found or r.rider_id is distinct from v_uid then
    raise exception 'RIDER_AUDIO_RIDER_ONLY' using errcode = '42501',
      hint = 'Only the rider turns their audio protection on or off.';
  end if;
  if coalesce(p_on, false) = r.rider_audio then
    return r.rider_audio;
  end if;
  if coalesce(p_on, false) and (r.status not in ('open', 'accepted', 'arrived', 'on_trip')
     or not coalesce((public.rider_audio_settings_for_ride(r.id)->>'enabled')::boolean, false)) then
    raise exception 'RIDER_AUDIO_OFF_HERE' using errcode = '42501',
      hint = 'Audio protection isn''t offered for this ride.';
  end if;
  update public.ride_requests set rider_audio = coalesce(p_on, false) where id = p_ride;
  return coalesce(p_on, false);
end;
$$;
revoke execute on function public.ride_set_rider_audio(uuid, boolean) from public, anon;
grant execute on function public.ride_set_rider_audio(uuid, boolean) to authenticated;

-- ---- 4. Whose recording it is -------------------------------------------------------------------
alter table public.voice_protection_recordings
  add column if not exists recorded_by text not null default 'driver';
do $c$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'voice_protection_recordings_recorded_by_check'
                    and conrelid = 'public.voice_protection_recordings'::regclass) then
    alter table public.voice_protection_recordings
      add constraint voice_protection_recordings_recorded_by_check check (recorded_by in ('driver', 'rider'));
  end if;
end;
$c$;
comment on column public.voice_protection_recordings.recorded_by is
  'Whose phone recorded it (0315): the driver''s VoiceProtection or the rider''s audio protection.';
-- Support opens a ride's recordings (the driver's and the rider's).
create index if not exists voice_protection_ride_idx
  on public.voice_protection_recordings (ride_id) where ride_id is not null;

-- A rider's recording: their own ride, with audio protection on for it and
-- at its pickup; kept for the hours set there. recorded_by is fixed.
create or replace function public.voice_protection_rider_audio()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_set jsonb;
begin
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated')
     or public.caller_admin_can_write('voice_protection_recordings') then
    return new;
  end if;
  if tg_op = 'UPDATE' then
    if new.recorded_by is distinct from old.recorded_by then
      raise exception 'VOICE_RECORDING_SERVER_ONLY' using errcode = '42501',
        hint = 'Whose recording it is is the server''s.';
    end if;
    return new;
  end if;
  if new.recorded_by is distinct from 'rider' then
    return new;
  end if;
  if new.ride_id is not null and new.ride_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into r from public.ride_requests where id = new.ride_id::uuid;
  end if;
  if r.id is null or r.rider_id is distinct from auth.uid() or new.profile_id is distinct from auth.uid()
     or not r.rider_audio then
    raise exception 'RIDER_AUDIO_NOT_ALLOWED' using errcode = '42501',
      hint = 'A rider''s recording is of their own ride with audio protection on.';
  end if;
  v_set := public.rider_audio_settings_for_ride(r.id);
  if not coalesce((v_set->>'enabled')::boolean, false) then
    raise exception 'RIDER_AUDIO_NOT_ALLOWED' using errcode = '42501',
      hint = 'Audio protection isn''t offered for this ride.';
  end if;
  new.recorded_at := least(coalesce(new.recorded_at, now()), now());
  new.expires_at := new.recorded_at + make_interval(hours => coalesce((v_set->>'keepHours')::integer, 24));
  return new;
end;
$$;
revoke execute on function public.voice_protection_rider_audio() from public, anon, authenticated;

drop trigger if exists trg_voice_protection_rider_audio on public.voice_protection_recordings;
create trigger trg_voice_protection_rider_audio
  before insert or update on public.voice_protection_recordings
  for each row execute function public.voice_protection_rider_audio();

notify pgrst, 'reload schema';
