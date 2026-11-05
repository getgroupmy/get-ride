-- Partner incoming-request alert sound (app config).
-- ============================================================================
-- The driver's incoming-request spotlight (Expo's request modal) now rings a
-- looping alert sound, like the big ride apps. How long it may ring is set by
-- the admin in Admin > App Settings > Ride offers, stored on the existing
-- 'city_ride_offers' app setting as `alertSoundSeconds` (0 = off).
--
-- Only city_ride_config() changes: it adds the new, clamped key to the
-- `offers` object it returns, so set_city_ride_config('offers', ...) keeps it
-- on save (it re-reads through this function). Older apps simply ignore the
-- extra key; an app on this migration gets the default where none is stored.
-- ============================================================================

create or replace function public.city_ride_config()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with v as (
    select coalesce((select s.value from public.app_settings s where s.key = 'city_ride_offers'), '{}'::jsonb) as o,
           coalesce((select s.value from public.app_settings s where s.key = 'rider_rating'), '{}'::jsonb) as r,
           coalesce((select s.value from public.app_settings s where s.key = 'driver_cancel_limit'), '{}'::jsonb) as d
  )
  select jsonb_build_object(
    'offers', jsonb_build_object(
      'shown', least(10, greatest(1, coalesce(
        case when jsonb_typeof(o->'shown') = 'number' then (o->>'shown')::numeric end, 5)))::int,
      'lifetimeSeconds', least(120, greatest(5, coalesce(
        case when jsonb_typeof(o->'lifetimeSeconds') = 'number' then (o->>'lifetimeSeconds')::numeric end, 15)))::int,
      'sort', case when o->>'sort' in ('cheapest', 'nearest', 'rating') then o->>'sort' else 'cheapest' end,
      'reofferAfterDecline', coalesce((o->>'reofferAfterDecline')::boolean, true),
      'alertSoundSeconds', least(120, greatest(0, coalesce(
        case when jsonb_typeof(o->'alertSoundSeconds') = 'number' then (o->>'alertSoundSeconds')::numeric end, 20)))::int),
    'riderRating', jsonb_build_object(
      'window', least(1000, greatest(5, coalesce(
        case when jsonb_typeof(r->'window') = 'number' then (r->>'window')::numeric end, 100)))::int,
      'newBelow', least(50, greatest(0, coalesce(
        case when jsonb_typeof(r->'newBelow') = 'number' then (r->>'newBelow')::numeric end, 5)))::int,
      'lowBelow', round(least(5, greatest(1, coalesce(
        case when jsonb_typeof(r->'lowBelow') = 'number' then (r->>'lowBelow')::numeric end, 4.0))), 1)),
    'driverCancel', jsonb_build_object(
      'limitPercent', least(100, greatest(1, coalesce(
        case when jsonb_typeof(d->'limitPercent') = 'number' then (d->>'limitPercent')::numeric end, 20)))::int,
      'days', least(30, greatest(1, coalesce(
        case when jsonb_typeof(d->'days') = 'number' then (d->>'days')::numeric end, 7)))::int,
      'pauseMinutes', least(1440, greatest(1, coalesce(
        case when jsonb_typeof(d->'pauseMinutes') = 'number' then (d->>'pauseMinutes')::numeric end, 30)))::int,
      'minRides', least(100, greatest(1, coalesce(
        case when jsonb_typeof(d->'minRides') = 'number' then (d->>'minRides')::numeric end, 5)))::int))
  from v;
$$;
