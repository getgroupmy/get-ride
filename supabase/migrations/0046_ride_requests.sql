-- ============================================================================
-- Ride requests: real passenger → partner ride hailing
-- ----------------------------------------------------------------------------
-- A passenger creates a row here when searching for a driver. Online partners
-- subscribe to `status = 'open'` rows in realtime, can ACCEPT one (claims it),
-- then progress it through arrived → on_trip → completed. The passenger watches
-- their own row for the partner's acceptance and live status.
--
-- RLS is permissive to match the rest of this project (admin uses a non-RLS
-- super session; the app uses the anon/auth client). Safe to re-run.
-- ============================================================================

create table if not exists public.ride_requests (
  id uuid primary key default gen_random_uuid(),

  -- Passenger (rider) ----------------------------------------------------------
  rider_id      uuid references public.profiles(id) on delete set null,
  rider_name    text,
  rider_phone   text,
  rider_photo   text,
  rider_rating  numeric(3,2) not null default 5,

  -- Trip details ---------------------------------------------------------------
  service       text,
  payment_mode  text not null default 'Cash',
  pickup_name   text,
  pickup_address text,
  pickup_lat    double precision,
  pickup_lng    double precision,
  drop_name     text,
  drop_address  text,
  drop_lat      double precision,
  drop_lng      double precision,
  distance_km   numeric(10,2),
  duration_min  integer,
  fare          numeric(10,2),
  currency      text not null default 'MYR',
  passengers    integer not null default 1,
  luggage       integer not null default 0,
  note          text,

  -- Lifecycle ------------------------------------------------------------------
  -- open → accepted → arrived → on_trip → completed | cancelled | expired
  status        text not null default 'open'
    check (status in ('open','accepted','arrived','on_trip','completed','cancelled','expired')),

  -- Assigned partner (driver) --------------------------------------------------
  partner_id        uuid,
  partner_name      text,
  partner_phone     text,
  partner_photo     text,
  partner_vehicle   text,
  partner_plate     text,
  partner_rating    numeric(3,2),

  -- Timestamps -----------------------------------------------------------------
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  accepted_at   timestamptz,
  arrived_at    timestamptz,
  started_at    timestamptz,
  completed_at  timestamptz,
  cancelled_at  timestamptz
);

create index if not exists ride_requests_status_idx       on public.ride_requests(status);
create index if not exists ride_requests_rider_idx        on public.ride_requests(rider_id);
create index if not exists ride_requests_partner_idx      on public.ride_requests(partner_id);
create index if not exists ride_requests_open_created_idx on public.ride_requests(created_at desc) where status = 'open';

-- updated_at trigger ---------------------------------------------------------
do $$
begin
  drop trigger if exists trg_ride_requests_updated_at on public.ride_requests;
  create trigger trg_ride_requests_updated_at before update on public.ride_requests
    for each row execute function public.set_updated_at();
end$$;

-- RLS (permissive) -----------------------------------------------------------
alter table public.ride_requests enable row level security;

drop policy if exists "ride_requests read"   on public.ride_requests;
drop policy if exists "ride_requests insert" on public.ride_requests;
drop policy if exists "ride_requests update" on public.ride_requests;
drop policy if exists "ride_requests delete" on public.ride_requests;

create policy "ride_requests read"   on public.ride_requests for select using (true);
create policy "ride_requests insert" on public.ride_requests for insert to public with check (true);
create policy "ride_requests update" on public.ride_requests for update to public using (true) with check (true);
create policy "ride_requests delete" on public.ride_requests for delete to public using (true);

grant select, insert, update, delete on public.ride_requests to anon, authenticated;

-- Realtime -------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.ride_requests;
exception when duplicate_object then null; end$$;
alter table public.ride_requests replica identity full;
