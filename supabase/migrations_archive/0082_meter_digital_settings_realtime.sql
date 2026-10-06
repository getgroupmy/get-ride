-- ============================================================================
-- 0082 — Meter Digital settings: realtime
-- ----------------------------------------------------------------------------
-- The console panels of a rate card (0081) are applied live: the Show / Tap
-- switches in Admin → Settings → Meter Digital Setting write straight through
-- rather than waiting for a Save, because which tabs a driver's console carries
-- is not a fare and can change under them without anything being mis-billed.
--
-- For that to reach the drivers it has to leave the database on its own, so the
-- table joins the realtime publication. The meter subscribes to it and re-reads
-- its cards on any change (`subscribeMeterSettings`); it keeps a refetch on
-- focus as the backstop for a database where this migration has not been
-- applied.
--
-- Replica identity full so a plain UPDATE of the panel columns carries the
-- whole row, matching the other live tables (wallets, ride_requests).
-- ============================================================================

alter table public.meter_digital_settings replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.meter_digital_settings;
exception
  when duplicate_object then null;
end$$;
