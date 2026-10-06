-- ============================================================================
-- 0085 — Meter Digital: what the two "leave the meter" keys do
-- ----------------------------------------------------------------------------
-- A back press on an idle meter is a *mode change*, not a step back, so the
-- console asks which mode: passenger, e-hailing, or stay. Which of those makes
-- sense is the operator's business, and two fleets want different things out of
-- the same two keys:
--
--   * a fleet whose drivers never ride as passengers on the shift phone wants
--     the passenger key to *close the app* instead — without signing the driver
--     out, so the next shift opens straight back onto the meter rather than
--     through the PIN (`leave_passenger_action = 'exit'`);
--   * a taxi company dispatched through somebody else's driver app wants the
--     e-hailing key to open *that* app rather than a screen it never uses
--     (`leave_ehailing_action = 'link'` plus the app link, and optionally what
--     to call the key on the console).
--
-- Scoped like every other field on the card — the global row decides unless a
-- narrower country / state / city / suburb card matches where the device is.
--
-- Defaults are exactly what the console did before this migration: passenger
-- mode and the in-app e-hailing screen. The link is only ever used when it names
-- a scheme the device could act on; the client refuses to store one that does
-- not, and falls back to the in-app screen for any row that carries one anyway,
-- so a key is never drawn that cannot be pressed (`utils/meterLeave.ts`).
--
-- The client tolerates this migration being absent: a read or a write that trips
-- on the missing columns is retried without them and both keys default to
-- in-app, rather than the whole rate-card table disappearing over four columns
-- it can default (`utils/meterSettingsStore.ts`, same path as 0084).
-- ============================================================================

alter table public.meter_digital_settings
  add column if not exists leave_passenger_action text not null default 'passenger',
  add column if not exists leave_ehailing_action  text not null default 'app',
  add column if not exists leave_ehailing_url     text,
  add column if not exists leave_ehailing_label   text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'meter_digital_settings_leave_passenger_action_check'
  ) then
    alter table public.meter_digital_settings
      add constraint meter_digital_settings_leave_passenger_action_check
      check (leave_passenger_action in ('passenger','exit'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'meter_digital_settings_leave_ehailing_action_check'
  ) then
    alter table public.meter_digital_settings
      add constraint meter_digital_settings_leave_ehailing_action_check
      check (leave_ehailing_action in ('app','link'));
  end if;
end $$;

comment on column public.meter_digital_settings.leave_passenger_action is
  'Leave-the-meter passenger key: open passenger mode, or close the app without signing out.';
comment on column public.meter_digital_settings.leave_ehailing_action is
  'Leave-the-meter e-hailing key: open /partner-ehailing, or the app named by leave_ehailing_url.';
comment on column public.meter_digital_settings.leave_ehailing_url is
  'App link the e-hailing key opens under ''link'', e.g. driverapp:// or an https:// universal link.';
comment on column public.meter_digital_settings.leave_ehailing_label is
  'Optional caption for the e-hailing key on the console. Defaults to E-HAILING.';
