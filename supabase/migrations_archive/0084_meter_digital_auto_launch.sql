-- ============================================================================
-- 0084 — Meter Digital: open the console at launch
-- ----------------------------------------------------------------------------
-- A taxi meter is not a screen a driver visits; it is the screen the shift is
-- spent on. So a rate card (0081) can now make it the app's landing screen for
-- the drivers who bill on it: with `auto_launch` on, a partner whose assigned
-- partner_types include TEKSI is taken straight to `/meter-digital` when they
-- sign in and on every relaunch, instead of the passenger map.
--
-- Scoped like every other field on the card — the global row decides unless a
-- narrower country / state / city / suburb card matches where the device is — so
-- an operator can switch the redirect on for one city's fleet and nowhere else.
--
-- Off by default, including for the cards that already exist: a driver taken
-- somewhere they did not ask to go is a worse default than one tap on the
-- console's own button. Two things still outrank it on the client
-- (`hooks/useMeterAutoLaunch.ts`): a ride in progress is restored first, and the
-- redirect fires once per app launch, so a driver who leaves the console for the
-- map is never dragged back into it.
--
-- The client tolerates this migration being absent: a read or a write that trips
-- on the missing column is retried without it and auto-launch defaults to off,
-- rather than the whole rate-card table disappearing over one boolean
-- (`utils/meterSettingsStore.ts`).
-- ============================================================================

alter table public.meter_digital_settings
  add column if not exists auto_launch boolean not null default false;

comment on column public.meter_digital_settings.auto_launch is
  'Open /meter-digital at app launch for partners carrying the TEKSI partner type.';
