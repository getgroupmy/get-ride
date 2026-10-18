-- ============================================================================
-- 0220 — Security fixes from the October review
--
-- 1. The share link no longer reaches the driver. ride_share_link() kept the
--    link's token on ride_requests once a request was accepted (0195 copied
--    it back from ride_request_private), where the driver can read the row.
--    With it the driver opened the shared page and read the trip code that
--    the passenger is meant to give them at pickup. Now:
--      * the token lives only in ride_request_private (rider and admins);
--      * ride_requests.share_token is never written: a value a client sets
--        is dropped, and the two kept today move aside;
--      * the shared page never shows the code to the ride's own driver.
--
-- 2. Gateway pairing counts wrong codes per caller address. One address may
--    get 10 wrong in 10 minutes; all callers together 500 (was 20 for all,
--    which let one stranger stop every admin from pairing).
-- ============================================================================

-- ---- 1. The share link ---------------------------------------------------------------------------
-- The two links kept on the row move aside, so they keep working.
insert into public.ride_request_private as p (request_id, share_token)
select r.id, r.share_token from public.ride_requests r
 where r.share_token is not null
on conflict (request_id) do update set share_token = coalesce(p.share_token, excluded.share_token), updated_at = now();

-- As in 0195, but the share link never comes back to the row.
create or replace function public.ride_requests_privacy()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ins  boolean := tg_op = 'INSERT';
  pv   public.ride_request_private;
  photo boolean := (public.ride_privacy_config() ->> 'showRiderPhoto')::boolean;
begin
  if new.status = 'open' then
    insert into public.ride_request_private as p (request_id, rider_name, rider_phone, rider_photo, booked_for_name,
                                                  booked_for_phone, full_address, ip_address, gender, share_token)
    values (new.id,
      case when ins or new.rider_name is distinct from old.rider_name then new.rider_name end,
      case when ins or new.rider_phone is distinct from old.rider_phone then new.rider_phone end,
      case when ins or new.rider_photo is distinct from old.rider_photo then new.rider_photo end,
      case when ins or new.booked_for_name is distinct from old.booked_for_name then new.booked_for_name end,
      case when ins or new.booked_for_phone is distinct from old.booked_for_phone then new.booked_for_phone end,
      case when ins or new.full_address is distinct from old.full_address then new.full_address end,
      case when ins or new.ip_address is distinct from old.ip_address then new.ip_address end,
      case when ins or new.gender is distinct from old.gender then new.gender end,
      null)
    on conflict (request_id) do update set
      rider_name       = coalesce(excluded.rider_name, p.rider_name),
      rider_phone      = coalesce(excluded.rider_phone, p.rider_phone),
      rider_photo      = coalesce(excluded.rider_photo, p.rider_photo),
      booked_for_name  = coalesce(excluded.booked_for_name, p.booked_for_name),
      booked_for_phone = coalesce(excluded.booked_for_phone, p.booked_for_phone),
      full_address     = coalesce(excluded.full_address, p.full_address),
      ip_address       = coalesce(excluded.ip_address, p.ip_address),
      gender           = coalesce(excluded.gender, p.gender),
      share_token      = coalesce(excluded.share_token, p.share_token),
      updated_at       = now()
    returning * into pv;

    new.booked_for_other := new.booked_for_other or pv.booked_for_phone is not null;
    -- First name only.
    new.rider_name := nullif(split_part(btrim(coalesce(pv.rider_name, '')), ' ', 1), '');
    new.rider_photo := case when photo then pv.rider_photo end;
    new.rider_phone := null;
    new.booked_for_name := null;
    new.booked_for_phone := null;
    new.full_address := null;
    new.ip_address := null;
    new.gender := null;
    new.otp := null;  -- ride_trip_codes has it (0152)
  elsif not ins and old.status = 'open' then
    select * into pv from public.ride_request_private where request_id = new.id;
    if found then
      new.rider_name       := coalesce(pv.rider_name, new.rider_name);
      new.rider_phone      := coalesce(new.rider_phone, pv.rider_phone);
      new.rider_photo      := coalesce(pv.rider_photo, new.rider_photo);
      new.booked_for_name  := coalesce(new.booked_for_name, pv.booked_for_name);
      new.booked_for_phone := coalesce(new.booked_for_phone, pv.booked_for_phone);
      new.full_address     := coalesce(new.full_address, pv.full_address);
      new.ip_address       := coalesce(new.ip_address, pv.ip_address);
      new.gender           := coalesce(new.gender, pv.gender);
    end if;
  end if;
  -- The link is kept aside only (ride_share_link); one a client sets is dropped.
  new.share_token := null;
  return new;
end;
$$;
revoke execute on function public.ride_requests_privacy() from public, anon, authenticated;

update public.ride_requests set share_token = null where share_token is not null;

-- The link is made and kept aside only.
create or replace function public.ride_share_link(p_ride uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  token uuid;
begin
  if auth.uid() is null
     or not exists (select 1 from public.ride_requests where id = p_ride and rider_id = auth.uid()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  token := coalesce((select share_token from public.ride_request_private where request_id = p_ride), gen_random_uuid());
  insert into public.ride_request_private as p (request_id, share_token)
  values (p_ride, token)
  on conflict (request_id) do update set share_token = coalesce(p.share_token, excluded.share_token), updated_at = now()
  returning p.share_token into token;
  return token;
end;
$$;
revoke all on function public.ride_share_link(uuid) from public, anon;
grant execute on function public.ride_share_link(uuid) to authenticated;

-- The shared page: found by the link kept aside; never shows the driver the code.
create or replace function public.ride_share_view(p_token uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'status', r.status,
    'service', r.service,
    'passenger', split_part(coalesce(nullif(trim(coalesce(r.booked_for_name, pv.booked_for_name)), ''),
                                    nullif(trim(coalesce(pv.rider_name, r.rider_name)), ''), 'Passenger'), ' ', 1),
    'booked_for_others', r.booked_for_other or r.booked_for_phone is not null,
    -- Who shared it (the rider, first name only), for the page's footer.
    'rider', split_part(coalesce(nullif(trim(coalesce(pv.rider_name, r.rider_name)), ''), ''), ' ', 1),
    'passengers', r.passengers,
    'pickup_name', r.pickup_name,
    'pickup_address', r.pickup_address,
    'pickup_lat', r.pickup_lat,
    'pickup_lng', r.pickup_lng,
    'drop_name', r.drop_name,
    'drop_address', r.drop_address,
    'drop_lat', r.drop_lat,
    'drop_lng', r.drop_lng,
    'stops', r.stops,
    'distance_km', r.distance_km,
    'duration_min', r.duration_min,
    'fare', coalesce(r.ride_fare, r.fare),
    'currency', r.currency,
    'payment_mode', r.payment_mode,
    'partner_name', r.partner_name,
    'partner_photo', r.partner_photo,
    'partner_vehicle', r.partner_vehicle,
    'partner_plate', r.partner_plate,
    'vehicle_make', coalesce(v.make, p.make),
    'vehicle_model', coalesce(v.model, p.model),
    'vehicle_color', v.color,
    'partner_rating', r.partner_rating,
    'partner_live_lat', r.partner_live_lat,
    'partner_live_lng', r.partner_live_lng,
    'partner_live_heading', r.partner_live_heading,
    'partner_live_at', r.partner_live_at,
    'otp', case when (r.booked_for_other or r.booked_for_phone is not null) and r.status in ('open', 'accepted', 'arrived')
                     and r.partner_id is distinct from auth.uid() then coalesce((select c.code from public.ride_trip_codes c where c.request_id = r.id), r.otp) end,
    'created_at', r.created_at,
    'accepted_at', r.accepted_at,
    'arrived_at', r.arrived_at,
    'started_at', r.started_at,
    'completed_at', r.completed_at,
    'cancelled_at', r.cancelled_at
  )
  from public.ride_requests r
  left join public.ride_request_private pv on pv.request_id = r.id
  -- The driver's partner record, and the car they drive: the one whose plate
  -- the ride carries, else their most recently updated.
  left join lateral (
    select pa.id, pa.make, pa.model
      from public.partners pa
     where r.partner_id is not null and pa.auth_user_id = r.partner_id
     order by pa.updated_at desc
     limit 1
  ) p on true
  left join lateral (
    select ve.make, ve.model, ve.color
      from public.vehicles ve
     where p.id is not null and ve.partner_id = p.id
     order by (upper(regexp_replace(coalesce(ve.plate, ''), '\s', '', 'g'))
               = upper(regexp_replace(coalesce(r.partner_plate, ''), '\s', '', 'g'))) desc,
              ve.updated_at desc
     limit 1
  ) v on true
  where p_token is not null
    and r.id = (select x.request_id from public.ride_request_private x where x.share_token = p_token)
    and (r.status in ('open', 'accepted', 'arrived', 'on_trip') or r.updated_at > now() - interval '24 hours')
$$;
revoke all on function public.ride_share_view(uuid) from public;
grant execute on function public.ride_share_view(uuid) to anon, authenticated;

-- ---- 2. Gateway pairing: wrong codes per address ---------------------------------------------
alter table public.gateway_pair_failures add column if not exists ip text;
create index if not exists gateway_pair_failures_ip_at_idx on public.gateway_pair_failures (ip, at);

create or replace function public.gateway_pair(
  p_code text, p_device_id text, p_label text default null, p_sim_number text default null,
  p_app_version text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_pair public.gateway_pairings;
  v_dev public.messaging_devices;
  v_key text;
  v_ip text := public.request_client_ip();
begin
  if (v_ip is not null
      and (select count(*) from public.gateway_pair_failures where ip = v_ip and at > now() - interval '10 minutes') >= 10)
     or (select count(*) from public.gateway_pair_failures where at > now() - interval '10 minutes') >= 500 then
    raise exception 'GATEWAY_PAIR_BUSY' using errcode = 'P0001',
      hint = 'Too many wrong codes. Wait 10 minutes and try again.';
  end if;
  if coalesce(btrim(p_device_id), '') = '' then
    raise exception 'GATEWAY_PAIR_DEVICE' using errcode = '22023';
  end if;

  select * into v_pair from public.gateway_pairings
   where code_hash = public.gateway_secret_hash(v_code) and used_at is null and expires_at > now()
   for update;
  if not found then
    -- Answered, not raised, so the failure is kept for the limit above.
    insert into public.gateway_pair_failures (ip) values (v_ip);
    return jsonb_build_object('error', 'GATEWAY_PAIR_CODE',
      'hint', 'That code is wrong or has expired. Make a new one in Admin -> SMS / WhatsApp.');
  end if;

  insert into public.messaging_devices
    (user_id, device_id, label, platform, kind, capabilities, sim_number, app_version, last_seen_at)
  values
    (v_pair.created_by, left(p_device_id, 200), coalesce(v_pair.label, left(p_label, 80)), 'android', 'gateway',
     array['sms'], left(p_sim_number, 32), left(p_app_version, 40), now())
  on conflict (user_id, device_id) do update
     set label = coalesce(v_pair.label, public.messaging_devices.label, excluded.label),
         kind = 'gateway',
         capabilities = array['sms'],
         sim_number = coalesce(excluded.sim_number, public.messaging_devices.sim_number),
         app_version = excluded.app_version,
         last_seen_at = now()
  returning * into v_dev;

  v_key := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.gateway_keys (device_row, key_hash, paired_by)
  values (v_dev.id, public.gateway_secret_hash(v_key), v_pair.created_by)
  on conflict (device_row) do update
     set key_hash = excluded.key_hash, paired_by = excluded.paired_by, created_at = now(), last_used_at = null;

  update public.gateway_pairings set used_at = now(), device_row = v_dev.id where id = v_pair.id;
  return jsonb_build_object('key', v_key, 'device', v_dev.id, 'label', v_dev.label);
end;
$$;
revoke execute on function public.gateway_pair(text, text, text, text, text) from public;
grant execute on function public.gateway_pair(text, text, text, text, text) to anon, authenticated;
