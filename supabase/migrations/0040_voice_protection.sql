-- ============================================================================
-- VoiceProtection (per ride trip audio safeguard)
-- ----------------------------------------------------------------------------
-- When a rider/partner enables VoiceProtection, the app records trip audio with
-- the device microphone while a ride is in progress. The audio is stored on the
-- DEVICE (local file system) and is NOT accessible to the user. Each recording
-- is retained locally for 24 hours then purged.
--
-- This table tracks the metadata for every local recording so that an admin can
-- REQUEST an upload (e.g. when a user opens a support ticket about a ride). When
-- an upload is requested the user's device uploads the still-retained local file
-- to the private `voice-protection` bucket and fills in `media_url`.
--
--   * voice_protection_recordings — metadata + upload request/fulfilment state
--   * storage bucket `voice-protection` (PRIVATE) holds uploaded audio
--
-- RLS is permissive to match the rest of this project (admin uses a non-RLS
-- super session, users access their own rows through the same client).
-- Realtime is enabled so the device reacts to admin upload requests instantly.
-- Safe to re-run.
-- ============================================================================

create table if not exists public.voice_protection_recordings (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  -- Human reference to the trip (booking number) + optional route summary.
  ride_id text,
  ride_label text,
  recorded_at timestamptz not null default now(),
  duration_sec integer not null default 0,
  -- When the local copy is purged from the device (recorded_at + 24h).
  expires_at timestamptz not null default (now() + interval '24 hours'),
  -- Upload request lifecycle (driven by an admin, fulfilled by the device).
  upload_requested boolean not null default false,
  upload_requested_by uuid,
  upload_requested_at timestamptz,
  ticket_id uuid,
  -- Set by the device once the local file has been uploaded.
  uploaded boolean not null default false,
  uploaded_at timestamptz,
  media_url text,
  -- Set by the device when the local file is no longer available (purged /
  -- never captured) so admins know the upload can't be fulfilled.
  unavailable boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists voice_protection_profile_idx
  on public.voice_protection_recordings(profile_id, recorded_at desc);
create index if not exists voice_protection_pending_upload_idx
  on public.voice_protection_recordings(profile_id, upload_requested, uploaded);

-- ---------------------------------------------------------------------------
-- updated_at trigger
-- ---------------------------------------------------------------------------
do $$
begin
  drop trigger if exists trg_voice_protection_updated_at on public.voice_protection_recordings;
  create trigger trg_voice_protection_updated_at before update on public.voice_protection_recordings
    for each row execute function public.set_updated_at();
end$$;

-- ---------------------------------------------------------------------------
-- RLS — permissive
-- ---------------------------------------------------------------------------
alter table public.voice_protection_recordings enable row level security;

drop policy if exists "voice_protection read"   on public.voice_protection_recordings;
drop policy if exists "voice_protection insert" on public.voice_protection_recordings;
drop policy if exists "voice_protection update" on public.voice_protection_recordings;
drop policy if exists "voice_protection delete" on public.voice_protection_recordings;

create policy "voice_protection read"   on public.voice_protection_recordings for select using (true);
create policy "voice_protection insert" on public.voice_protection_recordings for insert to public with check (true);
create policy "voice_protection update" on public.voice_protection_recordings for update to public using (true) with check (true);
create policy "voice_protection delete" on public.voice_protection_recordings for delete to public using (true);

grant select, insert, update, delete on public.voice_protection_recordings to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.voice_protection_recordings;
exception when duplicate_object then null; end$$;
alter table public.voice_protection_recordings replica identity full;

-- ---------------------------------------------------------------------------
-- Storage bucket (PRIVATE — trip audio must not be publicly readable)
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('voice-protection', 'voice-protection', false)
on conflict (id) do nothing;

drop policy if exists "anon read voice-protection"   on storage.objects;
drop policy if exists "anon upload voice-protection" on storage.objects;
drop policy if exists "anon update voice-protection" on storage.objects;
drop policy if exists "anon delete voice-protection" on storage.objects;

-- The app uses the anon/authenticated client for both rider uploads and admin
-- review (admin runs a non-RLS super session), so allow both roles.
create policy "anon read voice-protection"
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'voice-protection');

create policy "anon upload voice-protection"
  on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'voice-protection');

create policy "anon update voice-protection"
  on storage.objects for update to anon, authenticated
  using (bucket_id = 'voice-protection');

create policy "anon delete voice-protection"
  on storage.objects for delete to anon, authenticated
  using (bucket_id = 'voice-protection');
