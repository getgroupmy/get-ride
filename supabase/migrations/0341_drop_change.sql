-- Mid-ride drop-off change.
-- ============================================================================
-- A passenger can move the drop-off during an ongoing ride. The fare is
-- re-computed. A change that is cheaper, or whose increase is within the
-- admin's auto-approve threshold, applies at once; a bigger increase is held
-- pending and the driver accepts or rejects it (mirrors the mid-trip
-- cancellation-request flow, migrations 0053/0191/0223).
--
-- Trust: the request and the auto-approve decision run in a SECURITY DEFINER
-- RPC that checks the caller is the ride's rider; the driver's accept/reject
-- RPC checks the caller is the ride's partner. The new fare the client passes
-- is the amount the driver is shown and consents to on the pending path, and
-- for an auto-applied change it only ever lowers the fare or raises it within
-- the admin's threshold.
-- ============================================================================

-- ---- 0. Columns -----------------------------------------------------------------------------------
alter table public.ride_requests
  add column if not exists drop_change_requested_at timestamptz,
  add column if not exists drop_change_requested_by text,
  add column if not exists drop_change_name text,
  add column if not exists drop_change_address text,
  add column if not exists drop_change_lat double precision,
  add column if not exists drop_change_lng double precision,
  add column if not exists drop_change_distance_km numeric,
  add column if not exists drop_change_duration_min numeric,
  add column if not exists drop_change_fare numeric,
  add column if not exists drop_change_outcome text,
  add column if not exists drop_change_outcome_by text,
  add column if not exists drop_change_outcome_at timestamptz,
  add column if not exists drop_change_count integer not null default 0;

alter table public.ride_requests drop constraint if exists ride_requests_drop_change_outcome_check;
alter table public.ride_requests add constraint ride_requests_drop_change_outcome_check
  check (drop_change_outcome is null or drop_change_outcome in ('accepted', 'declined', 'expired'));

-- ---- 1. Admin rules (city_ride_config 'dropChange') -----------------------------------------------
-- city_ride_config() is re-created in full so it keeps 0340's alertSoundSeconds
-- and gains the dropChange object, cleaned and defaulted like the others.
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
           coalesce((select s.value from public.app_settings s where s.key = 'driver_cancel_limit'), '{}'::jsonb) as d,
           coalesce((select s.value from public.app_settings s where s.key = 'drop_change_rules'), '{}'::jsonb) as c
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
        case when jsonb_typeof(d->'minRides') = 'number' then (d->>'minRides')::numeric end, 5)))::int),
    'dropChange', jsonb_build_object(
      'allow', coalesce((c->>'allow')::boolean, true),
      'autoApproveCheaper', coalesce((c->>'autoApproveCheaper')::boolean, true),
      'autoApproveRm', least(50, greatest(0, coalesce(
        case when jsonb_typeof(c->'autoApproveRm') = 'number' then (c->>'autoApproveRm')::numeric end, 3)))::int,
      'autoApprovePct', least(100, greatest(0, coalesce(
        case when jsonb_typeof(c->'autoApprovePct') = 'number' then (c->>'autoApprovePct')::numeric end, 15)))::int,
      'responseWindowSec', least(120, greatest(10, coalesce(
        case when jsonb_typeof(c->'responseWindowSec') = 'number' then (c->>'responseWindowSec')::numeric end, 30)))::int,
      'maxChangesPerRide', least(10, greatest(1, coalesce(
        case when jsonb_typeof(c->'maxChangesPerRide') = 'number' then (c->>'maxChangesPerRide')::numeric end, 2)))::int))
  from v;
$$;

-- set_city_ride_config() gains the dropChange section → drop_change_rules key.
create or replace function public.set_city_ride_config(p_section text, p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text := case p_section when 'offers' then 'city_ride_offers'
                               when 'riderRating' then 'rider_rating'
                               when 'driverCancel' then 'driver_cancel_limit'
                               when 'dropChange' then 'drop_change_rules' end;
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:set_city_ride_config') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_key is null or jsonb_typeof(p_config) is distinct from 'object' then
    raise exception 'bad_section' using errcode = '22023';
  end if;
  insert into public.app_settings (key, value, updated_at) values (v_key, p_config, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  update public.app_settings set value = public.city_ride_config()->p_section where key = v_key;
  return public.city_ride_config();
end;
$$;
revoke execute on function public.set_city_ride_config(text, jsonb) from public, anon;
grant execute on function public.set_city_ride_config(text, jsonb) to authenticated;

-- ---- 2. Rider requests a new drop -----------------------------------------------------------------
-- Returns {applied, pending, fare}. Applied at once when cheaper or within the
-- admin threshold; otherwise held pending for the driver.
create or replace function public.ride_drop_change_request(
  p_ride uuid,
  p_name text,
  p_address text,
  p_lat double precision,
  p_lng double precision,
  p_distance_km numeric,
  p_duration_min numeric,
  p_new_fare numeric
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ride public.ride_requests;
  v_cfg jsonb;
  v_old numeric;
  v_delta numeric;
  v_thresh numeric;
  v_auto boolean;
begin
  select * into v_ride from public.ride_requests where id = p_ride;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_ride.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_ride.status not in ('accepted', 'arrived', 'on_trip') then
    raise exception 'not_ongoing' using errcode = '22023';
  end if;
  if p_new_fare is null or p_new_fare < 0 or p_lat is null or p_lng is null then
    raise exception 'bad_request' using errcode = '22023';
  end if;

  v_cfg := public.city_ride_config()->'dropChange';
  if not (v_cfg->>'allow')::boolean then
    raise exception 'drop_change_off' using errcode = '22023';
  end if;
  if coalesce(v_ride.drop_change_count, 0) >= (v_cfg->>'maxChangesPerRide')::int then
    raise exception 'drop_change_limit' using errcode = '22023';
  end if;

  v_old := coalesce(v_ride.ride_fare, v_ride.fare, 0);
  v_delta := p_new_fare - v_old;
  v_thresh := greatest((v_cfg->>'autoApproveRm')::numeric, v_old * (v_cfg->>'autoApprovePct')::numeric / 100.0);
  v_auto := (v_delta <= 0 and (v_cfg->>'autoApproveCheaper')::boolean)
            or (v_delta > 0 and v_delta <= v_thresh);

  if v_auto then
    update public.ride_requests set
      drop_name = p_name,
      drop_address = p_address,
      drop_lat = p_lat,
      drop_lng = p_lng,
      distance_km = coalesce(p_distance_km, distance_km),
      duration_min = coalesce(round(p_duration_min)::int, duration_min),
      ride_fare = p_new_fare,
      drop_change_count = coalesce(drop_change_count, 0) + 1,
      drop_change_requested_at = null,
      drop_change_requested_by = null,
      drop_change_name = null, drop_change_address = null,
      drop_change_lat = null, drop_change_lng = null,
      drop_change_distance_km = null, drop_change_duration_min = null, drop_change_fare = null,
      drop_change_outcome = 'accepted',
      drop_change_outcome_by = 'auto',
      drop_change_outcome_at = now()
    where id = p_ride;
    return jsonb_build_object('applied', true, 'pending', false, 'fare', p_new_fare);
  end if;

  update public.ride_requests set
    drop_change_requested_at = now(),
    drop_change_requested_by = 'rider',
    drop_change_name = p_name,
    drop_change_address = p_address,
    drop_change_lat = p_lat,
    drop_change_lng = p_lng,
    drop_change_distance_km = p_distance_km,
    drop_change_duration_min = p_duration_min,
    drop_change_fare = p_new_fare,
    drop_change_outcome = null,
    drop_change_outcome_by = null,
    drop_change_outcome_at = null
  where id = p_ride;
  return jsonb_build_object('applied', false, 'pending', true, 'fare', p_new_fare);
end;
$$;
revoke execute on function public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric) from public, anon;
grant execute on function public.ride_drop_change_request(uuid, text, text, double precision, double precision, numeric, numeric, numeric) to authenticated;

-- ---- 3. Driver accepts or rejects a pending change ------------------------------------------------
create or replace function public.ride_drop_change_resolve(p_ride uuid, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ride public.ride_requests;
begin
  select * into v_ride from public.ride_requests where id = p_ride;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from public.partners p where p.id = v_ride.partner_id and p.auth_user_id = auth.uid()
  ) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_ride.drop_change_requested_at is null then
    raise exception 'no_pending' using errcode = '22023';
  end if;

  if p_accept then
    update public.ride_requests set
      drop_name = drop_change_name,
      drop_address = drop_change_address,
      drop_lat = drop_change_lat,
      drop_lng = drop_change_lng,
      distance_km = coalesce(drop_change_distance_km, distance_km),
      duration_min = coalesce(round(drop_change_duration_min)::int, duration_min),
      ride_fare = coalesce(drop_change_fare, ride_fare),
      drop_change_count = coalesce(drop_change_count, 0) + 1,
      drop_change_requested_at = null,
      drop_change_requested_by = null,
      drop_change_name = null, drop_change_address = null,
      drop_change_lat = null, drop_change_lng = null,
      drop_change_distance_km = null, drop_change_duration_min = null, drop_change_fare = null,
      drop_change_outcome = 'accepted',
      drop_change_outcome_by = 'partner',
      drop_change_outcome_at = now()
    where id = p_ride;
    return jsonb_build_object('accepted', true);
  end if;

  update public.ride_requests set
    drop_change_requested_at = null,
    drop_change_requested_by = null,
    drop_change_name = null, drop_change_address = null,
    drop_change_lat = null, drop_change_lng = null,
    drop_change_distance_km = null, drop_change_duration_min = null, drop_change_fare = null,
    drop_change_outcome = 'declined',
    drop_change_outcome_by = 'partner',
    drop_change_outcome_at = now()
  where id = p_ride;
  return jsonb_build_object('accepted', false);
end;
$$;
revoke execute on function public.ride_drop_change_resolve(uuid, boolean) from public, anon;
grant execute on function public.ride_drop_change_resolve(uuid, boolean) to authenticated;

-- ---- 4. Rider withdraws a pending change (cancel, or client-side timeout) --------------------------
create or replace function public.ride_drop_change_withdraw(p_ride uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ride public.ride_requests;
begin
  select * into v_ride from public.ride_requests where id = p_ride;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_ride.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_ride.drop_change_requested_at is null then
    return jsonb_build_object('withdrawn', false);
  end if;
  update public.ride_requests set
    drop_change_requested_at = null,
    drop_change_requested_by = null,
    drop_change_name = null, drop_change_address = null,
    drop_change_lat = null, drop_change_lng = null,
    drop_change_distance_km = null, drop_change_duration_min = null, drop_change_fare = null,
    drop_change_outcome = 'expired',
    drop_change_outcome_by = 'rider',
    drop_change_outcome_at = now()
  where id = p_ride;
  return jsonb_build_object('withdrawn', true);
end;
$$;
revoke execute on function public.ride_drop_change_withdraw(uuid) from public, anon;
grant execute on function public.ride_drop_change_withdraw(uuid) to authenticated;

notify pgrst, 'reload schema';
