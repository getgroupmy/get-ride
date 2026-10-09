-- 0123: Fare tariffs per service.
--
-- 0109's cards priced every service at a place alike (the service's
-- multiplier aside). A card can now be for one Service Settings type
-- (Car, Bike, …) or one Vehicle Services entry (Ride, Premium, …):
--
--   service_type     settings_entries id (category 'service-settings'),
--                    null for every type
--   vehicle_service  settings_entries id (category 'vehicle-services'),
--                    null for every vehicle in the type
--
-- At a place the narrowest region with a card for the service decides;
-- within it a vehicle's own card beats its type's, which beats a card for
-- every service. A vehicle's own card is its fare, so the service
-- multiplier is not applied on top of it. Ids, not names: a renamed
-- service keeps its fares. No foreign key — a deleted service leaves a
-- card that matches nothing rather than a failed delete.

alter table public.fare_tariffs
  add column if not exists service_type text check (service_type is null or char_length(service_type) <= 64),
  add column if not exists vehicle_service text check (vehicle_service is null or char_length(vehicle_service) <= 64);

-- One card per place and service.
drop index if exists public.fare_tariffs_scope_uidx;
create unique index if not exists fare_tariffs_scope_uidx
  on public.fare_tariffs (
    level,
    coalesce(lower(country), ''),
    coalesce(lower(state), ''),
    coalesce(lower(city), ''),
    coalesce(lower(suburb), ''),
    coalesce(service_type, ''),
    coalesce(vehicle_service, '')
  );
