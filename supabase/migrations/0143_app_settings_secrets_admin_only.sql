-- ============================================================================
-- 0143: setting rows that hold keys are readable by admins only
--
-- `app_settings` had one permissive SELECT policy that hid only
-- `fare_ai_provider` and a restrictive one that hid only
-- `elife_api_connection`, so `api_providers` (the provider keys the admin
-- API Keys screen manages, a Google Places key among them) was readable by
-- anyone holding the public anon key.
--
-- One restrictive policy now covers every row that holds credentials. The
-- apps read these rows only from admin screens; the Expo app's map-key
-- rotation falls back to its built-in key when it can't read them.
-- ============================================================================

drop policy if exists "app_settings secrets admin only select" on public.app_settings;
create policy "app_settings secrets admin only select"
  on public.app_settings
  as restrictive
  for select
  to public
  using (
    key not in ('api_providers', 'fare_ai_provider', 'elife_api_connection')
    or public.caller_is_admin()
  );

notify pgrst, 'reload schema';
