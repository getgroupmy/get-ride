-- ============================================================================
-- 0243 — Meter Digital: meter on or off at sign-in
-- ----------------------------------------------------------------------------
-- `auto_launch` (0084) opens the meter console every time a TEKSI driver signs
-- in or reopens the app. Some fleets want the driver to decide once per
-- sign-in instead, and some want the meter on at sign-in without being sent
-- back to it on every reopen. `meter_at_sign_in` says what happens right after
-- a successful sign-in:
--
--   'off'    — nothing new: `auto_launch` alone decides (the default, and what
--              every card that already exists keeps).
--   'ask'    — the driver is asked "Turn the meter on" or "Not now". On lands
--              them on the meter and the launch rules (`auto_launch`) apply
--              for the rest of the session; Not now sends them to the normal
--              app, and the meter does not open on a reopen until they sign
--              in again or turn it on themselves.
--   'always' — the meter is on at every sign-in, with no question. Reopening
--              the app then follows `auto_launch`.
--
-- The driver's answer is kept on the device for that sign-in only (and
-- cleared on sign-out); the driver can switch it from the meter or the driver
-- menu. Scoped like every other field on the card: the narrowest country /
-- state / city / suburb card that matches decides, else the global card.
--
-- The client tolerates this migration being absent: a read or a write that
-- trips on the missing column is retried without it, and the setting reads
-- 'off'.
-- ============================================================================

alter table public.meter_digital_settings
  add column if not exists meter_at_sign_in text not null default 'off';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'meter_digital_settings_meter_at_sign_in_check'
  ) then
    alter table public.meter_digital_settings
      add constraint meter_digital_settings_meter_at_sign_in_check
      check (meter_at_sign_in in ('off','ask','always'));
  end if;
end $$;

comment on column public.meter_digital_settings.meter_at_sign_in is
  'Meter at sign-in for TEKSI drivers: off (auto_launch alone decides), ask (the driver chooses), always (on at every sign-in).';
