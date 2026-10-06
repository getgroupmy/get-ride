-- ============================================================================
-- 0073_device_attestation.sql
-- Server-side log of platform device attestation (Android Play Integrity /
-- iOS App Attest) for the sign-up anti-fraud pipeline.
--
-- Attestation does NOT give a stable cross-reinstall hardware id (neither
-- platform exposes one). What it DOES give is cryptographic proof that a
-- request came from a genuine, unmodified app on a genuine device — which
-- stops the *automated / emulated* mass-registration attack that a plain
-- client-supplied device_id can't. This table records each verdict so admins
-- can see which sessions were attested and so enforcement can be layered on
-- later (see docs/device-attestation.md).
--
-- Rows are written ONLY by the `attest-device` edge function using the service
-- role (which bypasses RLS); clients never write here and only admins read.
-- This migration is inert until that edge function is deployed with the
-- Google / Apple credentials — nothing in the existing flow depends on it.
-- ============================================================================

create table if not exists public.device_attestations (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references auth.users(id) on delete set null,
  device_id     text,
  platform      text not null check (platform in ('android', 'ios')),
  -- iOS App Attest: the hardware-backed key id (stable per app install).
  -- Android Play Integrity: null — its token carries no stable device id.
  attest_key_id text,
  passed        boolean not null default false,
  -- Parsed verdict / integrity details returned by the platform.
  verdict       jsonb,
  created_at    timestamptz not null default now()
);

create index if not exists device_attestations_device_idx
  on public.device_attestations (device_id);
create index if not exists device_attestations_key_idx
  on public.device_attestations (attest_key_id);
create index if not exists device_attestations_user_idx
  on public.device_attestations (user_id);

alter table public.device_attestations enable row level security;

-- Admins read; nobody else. The edge function writes via the service role,
-- which bypasses RLS, so no insert policy is required.
do $attest$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'device_attestations'
      and policyname = 'device_attestations admin read'
  ) then
    create policy "device_attestations admin read" on public.device_attestations
      for select using (public.caller_is_admin());
  end if;
end;
$attest$;

notify pgrst, 'reload schema';
