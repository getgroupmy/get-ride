-- ============================================================================
-- Ride requests: extended capture fields
-- ----------------------------------------------------------------------------
-- Adds bidding (OfferMe), detailed fare breakdown, partner/user location
-- checkpoints (accept / arrive / drop), trip OTP, vehicle + full address
-- geography (country → state → city → suburb), and device/identity metadata.
-- All additive and idempotent — safe to re-run.
-- ============================================================================

-- Bidding (OfferMe) -----------------------------------------------------------
alter table public.ride_requests add column if not exists offer_me boolean not null default false;
alter table public.ride_requests add column if not exists offered_fare numeric(10,2);

-- Fare breakdown --------------------------------------------------------------
alter table public.ride_requests add column if not exists ride_fare      numeric(10,2);
alter table public.ride_requests add column if not exists toll_charges   numeric(10,2);
alter table public.ride_requests add column if not exists other_charges  numeric(10,2);

-- Partner location checkpoints ------------------------------------------------
alter table public.ride_requests add column if not exists partner_accept_lat double precision;
alter table public.ride_requests add column if not exists partner_accept_lng double precision;
alter table public.ride_requests add column if not exists partner_arrive_lat double precision;
alter table public.ride_requests add column if not exists partner_arrive_lng double precision;
alter table public.ride_requests add column if not exists partner_drop_lat   double precision;
alter table public.ride_requests add column if not exists partner_drop_lng   double precision;

-- User location checkpoints ---------------------------------------------------
alter table public.ride_requests add column if not exists user_accept_lat double precision;
alter table public.ride_requests add column if not exists user_accept_lng double precision;
alter table public.ride_requests add column if not exists user_arrive_lat double precision;
alter table public.ride_requests add column if not exists user_arrive_lng double precision;
alter table public.ride_requests add column if not exists user_drop_lat   double precision;
alter table public.ride_requests add column if not exists user_drop_lng   double precision;

-- Trip OTP --------------------------------------------------------------------
alter table public.ride_requests add column if not exists otp text;

-- Vehicle + address geography -------------------------------------------------
alter table public.ride_requests add column if not exists vehicle_id   text;
alter table public.ride_requests add column if not exists full_address text;
alter table public.ride_requests add column if not exists country      text;
alter table public.ride_requests add column if not exists state        text;
alter table public.ride_requests add column if not exists city         text;
alter table public.ride_requests add column if not exists suburb       text;

-- Device / identity metadata --------------------------------------------------
alter table public.ride_requests add column if not exists device_os text;
alter table public.ride_requests add column if not exists ip_address text;
alter table public.ride_requests add column if not exists gender text;
