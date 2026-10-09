-- 0119: How a ride's region prices fares, stamped on the ride at booking
-- (Admin → Country / States / Cities → Fare pricing).
--
--   whole_fare  fares are whole amounts: rounded up, shown and offered
--               without decimals (tolls and other charges keep theirs)
--   tax_name    the tax added on top of the fare ("SST"), null for none
--   tax_kind    'percent' of the fare, or a 'fixed' amount
--   tax_value   the percentage or the amount
--
-- Stamped once so every screen after the booking — the driver's request,
-- offers, the trip, the receipt — prices the ride the same way even if the
-- admin changes the region later. The app books without these columns on a
-- database that lacks them.

alter table public.ride_requests
  add column if not exists whole_fare boolean not null default false,
  add column if not exists tax_name text check (tax_name is null or length(tax_name) <= 40),
  add column if not exists tax_kind text check (tax_kind is null or tax_kind in ('percent', 'fixed')),
  add column if not exists tax_value numeric(10, 2) check (tax_value is null or (tax_value >= 0 and tax_value <= 100000));

alter table public.ride_requests drop constraint if exists ride_requests_tax_percent;
alter table public.ride_requests
  add constraint ride_requests_tax_percent check (tax_kind is distinct from 'percent' or tax_value <= 100);
