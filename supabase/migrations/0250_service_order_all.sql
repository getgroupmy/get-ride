-- ============================================================================
-- 0250 — The service order for every booking
--
-- 0249 ranked the vehicle services lowest to highest
-- (public.vehicle_service_order) for the airport queue: a driver whose
-- vehicle is a higher service may take a lower one's order, never the
-- reverse. This applies it to every booking, behind an admin switch
-- (Admin → Vehicle Services → Service order: "Enforce service order for all
-- bookings", off by default, so drivers whose vehicle has no approved
-- service yet are not cut off before the admin has set theirs).
--
-- A driver's service is the approved service of the vehicle they have taken
-- (vehicle_active_session), else of their own approved vehicle
-- (driver_vehicle_service, 0249). With the switch on:
--   * an open request is read (and so streamed over realtime) only by
--     drivers whose service may take it — a restrictive read policy;
--   * a driver takes or bids on one only then (SERVICE_ORDER_REFUSED);
--   * the new-request and widening pushes go to those drivers only;
--   * GET.now: a code naming a driver whose service may not take the ride
--     is refused (SERVICE_ORDER_DIRECT) rather than sent to anybody else;
--     My Ride: favourites who may not take it are left out of the targets;
--   * scheduled rides: the open list, interest, accepting and being handed
--     or asked to take one follow the same rule.
-- A vehicle without an approved service may take only orders whose service
-- isn't one of the Vehicle Services (as the airport queue). A ride whose
-- service isn't ranked goes to its own service's vehicles only. The
-- everyone-broadcast used when no driver is known nearby is unchanged.
-- ============================================================================

-- ---- The switch -----------------------------------------------------------------------------------
create table if not exists public.service_order_settings (
  id          integer primary key default 1,
  enforce_all boolean not null default false,
  updated_at  timestamptz not null default now(),
  constraint service_order_settings_one check (id = 1)
);
insert into public.service_order_settings (id) values (1) on conflict do nothing;
comment on table public.service_order_settings is
  'Whether the vehicle service order (vehicle_service_order) applies to every booking, not only airports (0250).';

drop trigger if exists trg_service_order_settings_updated_at on public.service_order_settings;
create trigger trg_service_order_settings_updated_at before update on public.service_order_settings
  for each row execute function public.set_updated_at();

alter table public.service_order_settings enable row level security;
revoke all on public.service_order_settings from anon;
grant select, update on public.service_order_settings to authenticated;
drop policy if exists "service_order_settings read" on public.service_order_settings;
create policy "service_order_settings read" on public.service_order_settings
  for select to authenticated using (true);
drop policy if exists "service_order_settings admin update" on public.service_order_settings;
create policy "service_order_settings admin update" on public.service_order_settings for update to authenticated
  using ((select public.caller_admin_can_write('service_order_settings')))
  with check ((select public.caller_admin_can_write('service_order_settings')));

insert into public.admin_table_pages (target, page) values
  ('service_order_settings', 'admin-settings-vehicle-services')
on conflict do nothing;

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public'
                    and tablename = 'service_order_settings') then
    alter publication supabase_realtime add table public.service_order_settings;
  end if;
end $$;

-- ---- The rule -------------------------------------------------------------------------------------
create or replace function public.service_order_enforced()
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select coalesce((select enforce_all from public.service_order_settings where id = 1), false); $$;

-- The caller's vehicle service (null without one).
create or replace function public.caller_vehicle_service()
returns text
language sql
stable
security definer
set search_path = public
as $$ select public.driver_vehicle_service(auth.uid()); $$;

-- Whether a vehicle of [p_driver_service] may take an order of
-- [p_ride_service] (a service name): an order whose service isn't one of
-- the Vehicle Services, anyone; else the same service or a higher-ranked
-- one (airport_line_gap); never without a service.
create or replace function public.service_order_allows(p_driver_service text, p_ride_service text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when public.vehicle_service_id_of(p_ride_service) is null then true
    when nullif(p_driver_service, '') is null then false
    else public.airport_line_gap(p_driver_service, p_ride_service) is not null
  end;
$$;

-- The rule for one driver, with the switch: true while it is off.
create or replace function public.service_order_driver_allows(p_driver uuid, p_ride_service text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not public.service_order_enforced()
      or public.service_order_allows(public.driver_vehicle_service(p_driver), p_ride_service);
$$;

revoke execute on function public.service_order_enforced() from public, anon;
revoke execute on function public.caller_vehicle_service() from public, anon;
revoke execute on function public.service_order_allows(text, text) from public, anon;
revoke execute on function public.service_order_driver_allows(uuid, text) from public, anon;
grant execute on function public.service_order_enforced(), public.caller_vehicle_service(),
  public.service_order_allows(text, text), public.service_order_driver_allows(uuid, text)
  to authenticated, service_role;

-- ---- Who reads an open request ------------------------------------------------------------------
-- Restrictive, on top of "ride_requests read" (and 0249's airport hold).
drop policy if exists "ride_requests service order" on public.ride_requests;
create policy "ride_requests service order" on public.ride_requests as restrictive for select to authenticated
  using (status <> 'open'
         or not (select public.service_order_enforced())
         or rider_id = (select auth.uid()) or partner_id = (select auth.uid())
         or (select public.caller_is_admin())
         or public.service_order_allows((select public.caller_vehicle_service()), service));

-- ---- Who takes it; direct bookings and favourites ------------------------------------------------
-- After My Ride and GET.now (c_my_ride) have named the targets, before the
-- airport step (c_zairport).
create or replace function public.ride_requests_service_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_client boolean := coalesce(current_setting('role', true), '') in ('anon', 'authenticated')
                      and not public.caller_admin_can_write('ride_requests');
  v_keep uuid[];
begin
  if not public.service_order_enforced() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.status = 'open' and new.direct_driver_id is not null
       and not public.service_order_driver_allows(new.direct_driver_id, new.service) then
      raise exception 'SERVICE_ORDER_DIRECT' using errcode = '42501',
        hint = 'This driver''s vehicle can''t take this service. Choose another service, or book without the code.';
    end if;
    if new.direct_driver_id is null and coalesce(cardinality(new.target_driver_ids), 0) > 0 then
      select coalesce(array_agg(d), '{}') into v_keep
        from unnest(new.target_driver_ids) d
       where public.service_order_driver_allows(d, new.service);
      if cardinality(v_keep) = 0 then
        new.target_driver_ids := null;
        new.targeted_until := null;
      else
        new.target_driver_ids := v_keep;
      end if;
    end if;
    return new;
  end if;
  if v_client and old.status = 'open'
     and new.partner_id is not null and new.partner_id is distinct from old.partner_id
     and not public.service_order_driver_allows(new.partner_id, old.service) then
    raise exception 'SERVICE_ORDER_REFUSED' using errcode = '42501',
      hint = 'This ride is for a higher service than your vehicle''s.';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_service_order() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_c_service_order on public.ride_requests;
create trigger trg_ride_requests_c_service_order
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_service_order();

-- ---- Who is pushed ----------------------------------------------------------------------------------
-- As 0160, without the drivers whose service may not take the ride (the new
-- request's push and the widening both come through here).
create or replace function public.ride_request_push_nearby(
  p_request uuid,
  p_rider uuid,
  p_lat double precision,
  p_lng double precision,
  p_radius_km double precision,
  p_message jsonb,
  p_kind text,
  p_once boolean
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_driver uuid;
  v_told int := 0;
  n int;
  v_service text := (select service from public.ride_requests where id = p_request);
  v_enforced boolean := public.service_order_enforced();
begin
  for v_driver in select * from public.nearby_online_drivers(p_lat, p_lng, p_radius_km) loop
    continue when v_driver = p_rider;
    continue when v_enforced
               and not public.service_order_allows(public.driver_vehicle_service(v_driver), v_service);
    insert into public.ride_request_pushes (request_id, profile_id, kind)
    values (p_request, v_driver, p_kind)
    on conflict (request_id, profile_id) where profile_id is not null do nothing;
    get diagnostics n = row_count;
    continue when p_once and n = 0;
    perform public.send_push_webhook(p_message || jsonb_build_object('profileId', v_driver));
    v_told := v_told + 1;
  end loop;
  return v_told;
end;
$$;
revoke execute on function public.ride_request_push_nearby(uuid, uuid, double precision, double precision, double precision, jsonb, text, boolean)
  from public, anon, authenticated;

-- ---- Scheduled rides ---------------------------------------------------------------------------------
-- As 0189, the open list without the rides the caller's service may not take.
create or replace function public.scheduled_rides_open()
returns table (
  id uuid, pickup_at timestamptz, service text, pickup_address text, drop_address text,
  pickup_lat double precision, pickup_lng double precision, drop_lat double precision, drop_lng double precision,
  distance_km numeric, fare numeric, scheduling_fee numeric, currency text)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.pickup_at, s.service, s.pickup_address, s.drop_address,
         s.pickup_lat, s.pickup_lng, s.drop_lat, s.drop_lng, s.distance_km, s.fare,
         case when public.scheduled_rides_config()->>'feeTo' = 'driver' then s.scheduling_fee else 0 end,
         s.currency
    from public.scheduled_rides s
   where s.status = 'scheduled' and s.partner_id is null and s.pickup_at > now()
     and public.caller_is_approved_partner()
     and public.scheduled_rides_config()->>'mode' = 'advance'
     and s.rider_id <> auth.uid()
     and public.service_order_driver_allows(auth.uid(), s.service)
   order by s.pickup_at
   limit 100;
$$;
revoke execute on function public.scheduled_rides_open() from public, anon;
grant execute on function public.scheduled_rides_open() to authenticated;

-- Taking one (accepting, a handover, the passenger's choice of driver), and
-- showing interest, follow the rule.
create or replace function public.scheduled_rides_service_order()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_service text;
begin
  if tg_table_name = 'scheduled_rides' then
    if new.partner_id is not null and new.partner_id is distinct from old.partner_id
       and not public.service_order_driver_allows(new.partner_id, new.service) then
      raise exception 'SERVICE_ORDER_REFUSED' using errcode = '42501',
        hint = 'This ride is for a higher service than the vehicle''s.';
    end if;
    return new;
  end if;
  select service into v_service from public.scheduled_rides where id = new.scheduled_ride_id;
  -- An interest names its driver as partner_id, an offer as to_partner_id.
  if not public.service_order_driver_allows(
       coalesce(to_jsonb(new)->>'to_partner_id', to_jsonb(new)->>'partner_id')::uuid, v_service) then
    raise exception 'SERVICE_ORDER_REFUSED' using errcode = '42501',
      hint = 'This ride is for a higher service than the vehicle''s.';
  end if;
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_service_order() from public, anon, authenticated;

drop trigger if exists trg_scheduled_rides_service_order on public.scheduled_rides;
create trigger trg_scheduled_rides_service_order
  before update of partner_id on public.scheduled_rides
  for each row execute function public.scheduled_rides_service_order();
drop trigger if exists trg_scheduled_ride_interests_service_order on public.scheduled_ride_interests;
create trigger trg_scheduled_ride_interests_service_order
  before insert on public.scheduled_ride_interests
  for each row execute function public.scheduled_rides_service_order();
drop trigger if exists trg_scheduled_ride_offers_service_order on public.scheduled_ride_offers;
create trigger trg_scheduled_ride_offers_service_order
  before insert on public.scheduled_ride_offers
  for each row execute function public.scheduled_rides_service_order();

notify pgrst, 'reload schema';
