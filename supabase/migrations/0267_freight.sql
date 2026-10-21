-- ============================================================================
-- 0267: Freight -- cargo on a ride request, the freight vehicle sizes and the
-- freight options
--
-- A freight request IS a ride request: its service is a Vehicle Service whose
-- Service types include "Freight" (Admin > Services & catalogue; the owner
-- adds the sizes there, none are seeded). Bidding, tracking, chat, calls,
-- payments and the admin pages all work as for a ride. What is new:
--
--   * Vehicle Services keep their values in settings_entries.values (camel
--     case, as every other field there); a freight size may set
--       maxLoadKg, loadLengthM, loadWidthM, loadHeightM (numbers, optional)
--       closedBody (boolean): a covered van or lorry.
--     The server reads Service types and closedBody; the rest is shown.
--   * ride_requests.cargo_description (what is carried, up to 500
--     characters; required on a freight booking from the app) and
--     cargo_photo_path (optional: a photo in the rider's own folder of the
--     private `ride-cargo` bucket, `<rider uid>/cargo-<uuid>.jpg`). Both are
--     set when the request is made (RIDE_CARGO_FIXED). The rider reads and
--     adds to their folder; the driver who takes the ride and admins read
--     the photo that ride names, through signed links. A booking for later
--     keeps both (scheduled_request_clean).
--   * Ride Options by place (0253) gain four options, booked through
--     option_names as the others: 'helper-1' (1 helper), 'helper-2' (2
--     helpers), 'closed-body' (closed body vehicle only) and 'ride-along'
--     (the rider travels with the cargo). Each has a fixed charge per place
--     under its own id in ride_option_places.charges, and is offered /
--     blocked per place like child-seat or pet; nothing set is free and
--     offered. A booking with one not offered at its pickup, or blocked for
--     its service there, is refused (RIDE_OPTION_NOT_OFFERED) by 0253's
--     check. On top of it (freight_problem), an app booking is refused when:
--       - it has a freight option on a service that isn't freight
--         (FREIGHT_OPTION_NOT_FREIGHT);
--       - it is freight without a cargo description (FREIGHT_CARGO_REQUIRED);
--       - it asks for 1 helper and 2 helpers (FREIGHT_HELPERS_ONE);
--       - it asks for a closed body on a size not flagged closedBody
--         (RIDE_OPTION_NOT_OFFERED);
--       - the option_charges line of a freight option (kind = its id) is
--         not the pickup's fixed charge for it, or one is there for an
--         option not booked (RIDE_OPTION_CHARGE_CHANGED). The rider's offer
--         plus these lines is the fare, as 0248 has it.
--   * Who gets it: an open freight request is read by, pushed to and
--     offered to drivers whose vehicle's approved service is a freight one
--     that may take it (service_order_allows: the same size or a higher
--     ranked one), whatever the Service order switch says; Driver Services
--     (0263) switches and locks apply as for any service. The rider, the
--     driver on it, admins and a stand's operators still read it. A GET.now
--     code naming a driver without a freight vehicle is refused
--     (FREIGHT_DRIVER_NO_FREIGHT) and My Ride favourites without one are
--     left out.
--
-- And, as the owner asked next:
--   1. Proof of delivery: the driver's photo at pickup and at drop-off
--      (pickup_proof_path, dropoff_proof_path, the driver's folder of
--      ride-cargo) and the sender's optional signature at drop-off
--      (delivery_signature_path). A freight trip starts only with the pickup
--      photo and ends only with the drop-off one. The sender, the driver and
--      admins read all three.
--   2. Cancel after pickup: the driver asks the sender (cancel_requested_*,
--      as 0191); unanswered, it is approved after the Freight settings'
--      minutes (app_settings 'freight', default 5) by 0191's job.
--   3. Waiting time and the cancel fee, per place as the option charges
--      (ride_option_places.charges 'freight-wait-free-min' default 20,
--      'freight-wait-per-min', 'freight-cancel-arrived'): the waiting fee is
--      added to the fare when the trip starts (freight_waiting_*); the
--      sender cancelling after the driver arrived owes the fee
--      (freight_cancel_fee), billed on their next request and credited to
--      the driver who waited once that one is paid.
--   4. Prohibited items (app_settings 'freight' prohibitedItems, the
--      admin's list) and the declared value: a freight booking needs
--      prohibited_ack and a declared_value no more than the place's cap
--      ('freight-declared-cap', default 500).
--   5. The recipient (recipient_name, recipient_phone; like the declared
--      value, kept aside in ride_request_private while the request is open,
--      so a bidding driver never reads them) is sent the
--      tracking link (0108's share link) when the trip starts, by SMS and/or
--      WhatsApp as the admin chooses: freight_recipient_notices, sent by the
--      freight-notify Edge Function. No new secret goes into a pg_net call.
--   6. A freight size may ask for a goods-vehicle permit (goodsPermitKey on
--      the Vehicle Service: a Permits type key, 0254): without that
--      approved permit on the vehicle, the driver gets none of its requests.
-- ============================================================================

-- ---- 1. Freight vehicle services ----------------------------------------------------------------
-- Whether a Vehicle Service's values name the Freight service type.
create or replace function public.vehicle_service_values_freight(p_values jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select exists (
    select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_values->'serviceTypes') = 'array'
                                                 then p_values->'serviceTypes' else '[]'::jsonb end) t
     where lower(btrim(t)) = 'freight');
$$;

-- The freight Vehicle Services (settings entry ids), active or not.
create or replace function public.freight_service_ids()
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(e.id::text order by e.position), '{}')
    from public.settings_entries e
   where e.category = 'vehicle-services' and public.vehicle_service_values_freight(e.values);
$$;

-- Their names as driver_service_key compares ride_requests.service (0263).
create or replace function public.freight_service_keys()
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(distinct public.driver_service_key(e.values->>'name')), '{}')
    from public.settings_entries e
   where e.category = 'vehicle-services' and public.vehicle_service_values_freight(e.values)
     and coalesce(btrim(e.values->>'name'), '') <> '';
$$;

-- Whether a ride's service (a name) is a freight one.
create or replace function public.vehicle_service_is_freight(p_service text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.vehicle_service_id_of(p_service) = any (public.freight_service_ids()), false);
$$;

-- Whether a ride's service (a name) is flagged closed body.
create or replace function public.vehicle_service_closed_body(p_service text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select e.values->'closedBody' = 'true'::jsonb from public.settings_entries e
                    where e.id::text = public.vehicle_service_id_of(p_service)), false);
$$;

-- The goods-vehicle permit a freight size asks for (header: 6): the key of a
-- Permits type (permit_types.key, the same in every country), kept on the
-- Vehicle Service as goodsPermitKey. None: no permit asked.
create or replace function public.vehicle_service_goods_permit(p_service_id text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select nullif(btrim(e.values->>'goodsPermitKey'), '') from public.settings_entries e
   where e.id::text = p_service_id and e.category = 'vehicle-services';
$$;

-- Whether [p_vehicle] holds an approved, unexpired vehicle permit of the
-- type [p_key] in its registration country (0254's rows).
create or replace function public.vehicle_has_permit(p_vehicle uuid, p_key text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(btrim(p_key), '') = '' or exists (
    select 1 from public.vehicle_permit_rows(p_vehicle) r
      join public.permit_types t on t.id = r.type_id
     where t.key = lower(btrim(p_key)) and r.state = 'with');
$$;

-- The vehicle a driver works with now: the one taken, else their own
-- approved one with a service (as driver_vehicle_service reads it).
create or replace function public.driver_work_vehicle(p_driver uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    public.driver_session_vehicle(p_driver),
    (select v.id from public.vehicle v
      where v.auth_user_id = p_driver and v.status = 'approved' and nullif(v.service_approved_id, '') is not null
      order by v.updated_at desc limit 1));
$$;

-- Whether a driver with a vehicle of the freight size [p_service_id] has
-- the goods-vehicle permit that size asks for.
create or replace function public.driver_goods_permit_ok(p_driver uuid, p_service_id text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_key text := public.vehicle_service_goods_permit(p_service_id);
begin
  if v_key is null then
    return true;
  end if;
  return public.vehicle_has_permit(public.driver_work_vehicle(p_driver), v_key);
end;
$$;
revoke execute on function public.vehicle_service_goods_permit(text), public.vehicle_has_permit(uuid, text),
  public.driver_work_vehicle(uuid), public.driver_goods_permit_ok(uuid, text) from public, anon, authenticated;
grant execute on function public.vehicle_service_goods_permit(text), public.vehicle_has_permit(uuid, text),
  public.driver_work_vehicle(uuid), public.driver_goods_permit_ok(uuid, text) to service_role;

-- Whether [p_driver] may take a request of [p_service]: anyone for a service
-- that isn't freight; else only a driver whose vehicle's approved service is
-- a freight one at least that size (service_order_allows).
create or replace function public.driver_takes_freight(p_driver uuid, p_service text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_mine text;
begin
  if not public.vehicle_service_is_freight(p_service) then
    return true;
  end if;
  v_mine := public.driver_vehicle_service(p_driver);
  return v_mine is not null and v_mine = any (public.freight_service_ids())
     and public.service_order_allows(v_mine, p_service)
     and public.driver_goods_permit_ok(p_driver, v_mine);
end;
$$;

-- The freight service keys the caller may take with the vehicle they drive
-- (none without a freight vehicle): worked out once per query by the read
-- rule below.
create or replace function public.caller_freight_keys()
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_mine text := public.driver_vehicle_service(auth.uid());
begin
  if v_mine is null or not (v_mine = any (public.freight_service_ids()))
     or not public.driver_goods_permit_ok(auth.uid(), v_mine) then
    return '{}';
  end if;
  return coalesce((
    select array_agg(distinct public.driver_service_key(e.values->>'name'))
      from public.settings_entries e
     where e.category = 'vehicle-services' and public.vehicle_service_values_freight(e.values)
       and coalesce(btrim(e.values->>'name'), '') <> ''
       and public.service_order_allows(v_mine, e.values->>'name')), '{}');
end;
$$;

revoke execute on function public.freight_service_ids(), public.freight_service_keys(),
  public.vehicle_service_is_freight(text), public.vehicle_service_closed_body(text),
  public.driver_takes_freight(uuid, text), public.caller_freight_keys() from public, anon;
revoke execute on function public.driver_takes_freight(uuid, text) from authenticated;
grant execute on function public.freight_service_ids(), public.freight_service_keys(),
  public.vehicle_service_is_freight(text), public.vehicle_service_closed_body(text),
  public.caller_freight_keys() to authenticated, service_role;
grant execute on function public.driver_takes_freight(uuid, text) to service_role;

-- ---- 2. The cargo on a request --------------------------------------------------------------------
-- A description of 1 to 500 characters, or none; a photo in [p_rider]'s
-- folder, or none.
create or replace function public.ride_cargo_valid(p_description text, p_photo text, p_rider uuid)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select (p_description is null or char_length(btrim(p_description)) between 1 and 500)
     and (p_photo is null
          or (p_rider is not null and starts_with(p_photo, p_rider::text || '/')
              and char_length(p_photo) <= 300 and position('..' in p_photo) = 0));
$$;

alter table public.ride_requests add column if not exists cargo_description text;
alter table public.ride_requests add column if not exists cargo_photo_path text;
-- Prohibited items and the declared value (header: 4), the recipient (5).
alter table public.ride_requests add column if not exists declared_value numeric;
alter table public.ride_requests add column if not exists prohibited_ack boolean;
alter table public.ride_requests add column if not exists recipient_name text;
alter table public.ride_requests add column if not exists recipient_phone text;
alter table public.ride_requests drop constraint if exists ride_requests_freight_recipient_valid;
alter table public.ride_requests add constraint ride_requests_freight_recipient_valid check (
  (declared_value is null or declared_value between 0 and 1000000)
  and (recipient_name is null or char_length(btrim(recipient_name)) between 1 and 80)
  and (recipient_phone is null or recipient_phone ~ '^\+?[0-9 ()-]{6,24}$'));
alter table public.ride_requests drop constraint if exists ride_requests_cargo_valid;
alter table public.ride_requests
  add constraint ride_requests_cargo_valid check (public.ride_cargo_valid(cargo_description, cargo_photo_path, rider_id));
comment on column public.ride_requests.cargo_description is
  'Freight (0267): what the rider sends, set when the request is made.';
comment on column public.ride_requests.cargo_photo_path is
  'Freight (0267): an optional photo of the cargo in the private ride-cargo bucket (<rider uid>/cargo-<uuid>.jpg).';

-- A booking for later keeps the cargo (0251's list plus the two columns).
create or replace function public.scheduled_request_clean(p_request jsonb, p_fee numeric default null)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select coalesce((
    select jsonb_object_agg(e.key,
      case when e.key = 'charges' then (
        select coalesce(jsonb_agg(
          case when p_fee is not null and c->>'name' = 'Scheduling fee' and c->'value' = to_jsonb(p_fee)
                    and c->>'kind' = 'surcharge'
               then c else c - 'platform' end), '[]'::jsonb)
          from jsonb_array_elements(e.value) c
         where jsonb_typeof(c) = 'object')
      else e.value end)
      from jsonb_each(coalesce(p_request, '{}'::jsonb)) e
     where e.key = any (array[
       'rider_name', 'rider_phone', 'rider_photo', 'service', 'payment_mode',
       'pickup_name', 'pickup_address', 'pickup_lat', 'pickup_lng',
       'drop_name', 'drop_address', 'drop_lat', 'drop_lng', 'stops',
       'distance_km', 'duration_min', 'fare', 'ride_fare', 'currency',
       'passengers', 'luggage', 'note', 'offer_me', 'otp', 'device_os',
       'user_accept_lat', 'user_accept_lng', 'booked_for_name', 'booked_for_phone',
       'country', 'state', 'city', 'suburb', 'full_address', 'ip_address', 'gender',
       'whole_fare', 'tax_name', 'tax_kind', 'tax_value', 'charges', 'timezone',
       'promo_code_id', 'pets', 'assistance', 'option_charges', 'option_names',
       'pickup_door_id', 'drop_door_id',
       -- 0251: a stand's order (kept only on a stand's booking).
       'stand_id', 'ticket_no', 'dispatch_stand_name', 'dispatch_created_by', 'dispatch_mode',
       'dispatch_group_id', 'dispatch_group_name', 'dispatch_group_kind', 'dispatch_driver_id',
       'fare_mode', 'dispatch_payment', 'stand_settlement', 'stand_fee_type', 'stand_fee_value',
       'stand_fee_bearer', 'stand_fee_earner_id', 'stand_fee_amount', 'stand_platform_fee_type',
       'stand_platform_fee_value', 'dispatch_booked_via', 'share_token',
       -- 0267: the cargo of a freight booking, its declared value and
       -- the recipient told when the trip starts.
       'cargo_description', 'cargo_photo_path', 'declared_value', 'prohibited_ack',
       'recipient_name', 'recipient_phone'])
       and (e.key <> 'charges' or jsonb_typeof(e.value) = 'array')
  ), '{}'::jsonb);
$$;

-- ---- 3. The cargo photos --------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ride-cargo', 'ride-cargo', false, 15728640, array['image/*'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Whether the caller may see the cargo photo [p_name]: an admin, or the
-- driver of a ride they have taken that names it. The rider's own folder is
-- the policy's first test.
create or replace function public.ride_cargo_photo_readable(p_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and coalesce(p_name, '') <> '' and (
    public.caller_is_admin()
    or exists (
      select 1 from public.ride_requests r
       where r.partner_id = auth.uid()
         and r.status in ('accepted', 'arrived', 'on_trip', 'completed')
         and r.cargo_photo_path = p_name
    )
  );
$$;
revoke execute on function public.ride_cargo_photo_readable(text) from public, anon;
grant execute on function public.ride_cargo_photo_readable(text) to authenticated;

drop policy if exists "ride cargo owner upload" on storage.objects;
drop policy if exists "ride cargo read" on storage.objects;
drop policy if exists "ride cargo admin delete" on storage.objects;

create policy "ride cargo owner upload"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'ride-cargo'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- The rider's own folder (which storage's upsert needs as well), the ride's
-- driver and admins.
create policy "ride cargo read"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'ride-cargo'
    and ((storage.foldername(name))[1] = (select auth.uid())::text
         or public.ride_cargo_photo_readable(name))
  );

create policy "ride cargo admin delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'ride-cargo' and (select public.caller_admin_can_write('storage:ride-cargo')));

-- Removed from Admin > Rides, as the chat photos (0223).
insert into public.admin_table_pages (target, page) values
  ('storage:ride-cargo', 'admin-rides'),
  ('storage:ride-cargo', 'admin-trace-fraud')
on conflict do nothing;

-- ---- 4. The freight options -------------------------------------------------------------------------
create or replace function public.freight_option_ids()
returns text[]
language sql
immutable
set search_path = ''
as $$ select array['helper-1', 'helper-2', 'closed-body', 'ride-along']; $$;

-- As 0253, with the freight options.
create or replace function public.ride_option_ids()
returns text[]
language sql
immutable
set search_path = ''
as $$ select array['child-seat', 'more-passengers', 'pet', 'assistance'] || public.freight_option_ids(); $$;

-- The freight options a booking has on, in their order.
create or replace function public.ride_freight_kinds(p_names jsonb)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(u.k order by u.n), '{}')
    from unnest(public.freight_option_ids()) with ordinality u(k, n)
   where jsonb_typeof(p_names) = 'object' and p_names ? u.k;
$$;

-- As 0253, then the freight options (named in option_names, as a child seat).
create or replace function public.ride_option_kinds(p_pets jsonb, p_assistance jsonb, p_names jsonb,
                                                    p_passengers integer)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array_remove(array[
    case when jsonb_typeof(p_names) = 'object' and p_names ? 'child-seat' then 'child-seat' end,
    case when (jsonb_typeof(p_names) = 'object' and p_names ? 'more-passengers') or coalesce(p_passengers, 0) > 4
         then 'more-passengers' end,
    case when (jsonb_typeof(p_pets) = 'array' and jsonb_array_length(p_pets) > 0)
              or (jsonb_typeof(p_names) = 'object' and p_names ? 'pet') then 'pet' end,
    case when jsonb_typeof(p_assistance) = 'object' then 'assistance' end], null)
    || public.ride_freight_kinds(p_names);
$$;

-- As 0253, with the freight options' built-in names.
create or replace function public.ride_option_name(p_kind text, p_names jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(case when jsonb_typeof(p_names) = 'object' then nullif(btrim(p_names->>p_kind), '') end,
                  case p_kind when 'child-seat' then 'Child safety seat'
                              when 'more-passengers' then 'More than 4 passengers'
                              when 'pet' then 'Pet with me'
                              when 'assistance' then 'Assistance required'
                              when 'helper-1' then '1 helper'
                              when 'helper-2' then '2 helpers'
                              when 'closed-body' then 'Closed body'
                              when 'ride-along' then 'I''ll ride along'
                              else p_kind end);
$$;

-- Why an app booking of [p_service] with these options, charges and cargo
-- can't go out at its pickup, as {code, hint}; null when it can (see the
-- header).
drop function if exists public.ride_freight_problem(text, jsonb, jsonb, text, double precision, double precision,
                                                    text, text, text);
create or replace function public.ride_freight_problem(
  p_service text, p_names jsonb, p_lines jsonb, p_cargo text, p_declared numeric, p_ack boolean,
  p_lat double precision, p_lng double precision, p_country text, p_state text, p_city text)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_freight boolean := public.vehicle_service_is_freight(p_service);
  v_kinds text[] := public.ride_freight_kinds(p_names);
  v_charges jsonb;
  k text;
  v_want numeric;
  v_have numeric;
begin
  if cardinality(v_kinds) > 0 and not v_freight then
    return array['FREIGHT_OPTION_NOT_FREIGHT',
                 public.ride_option_name(v_kinds[1], p_names) || ' is for Freight only. Turn it off and book again.'];
  end if;
  if not v_freight then
    return null;
  end if;
  if coalesce(btrim(p_cargo), '') = '' then
    return array['FREIGHT_CARGO_REQUIRED', 'Describe your cargo so drivers know what they are carrying.'];
  end if;
  if not coalesce(p_ack, false) then
    return array['FREIGHT_PROHIBITED_ACK', 'Confirm that your cargo has none of the prohibited items.'];
  end if;
  if p_declared is null or p_declared < 0 then
    return array['FREIGHT_DECLARED_VALUE', 'Enter the value of your items.'];
  end if;
  if 'helper-1' = any (v_kinds) and 'helper-2' = any (v_kinds) then
    return array['FREIGHT_HELPERS_ONE', 'Choose 1 helper or 2 helpers, not both.'];
  end if;
  if 'closed-body' = any (v_kinds) and not public.vehicle_service_closed_body(p_service) then
    return array['RIDE_OPTION_NOT_OFFERED',
                 public.ride_option_name('closed-body', p_names) || ' isn''t offered for '
                 || coalesce(nullif(btrim(p_service), ''), 'this service') || '. Choose a closed body vehicle.'];
  end if;
  select public.ride_option_settings_at(p.country, p.state, p.city, p.suburb)->'charges' into v_charges
    from public.ride_option_place(p_lat, p_lng, p_country, p_state, p_city) p;
  -- The declared value is capped per place (Default RM 500).
  if p_declared > public.freight_place_value(v_charges, 'freight-declared-cap') then
    return array['FREIGHT_DECLARED_VALUE_CAP',
                 'The value of your items can be at most '
                 || trim_scale(public.freight_place_value(v_charges, 'freight-declared-cap'))::text
                 || ' here. Send higher-value items another way.'];
  end if;
  foreach k in array public.freight_option_ids() loop
    -- A percentage (never set from the admin page) is not checked.
    continue when k = any (v_kinds) and v_charges->k->>'kind' = 'percent';
    v_want := case when k = any (v_kinds) and jsonb_typeof(v_charges->k->'value') = 'number'
                   then (v_charges->k->>'value')::numeric else 0 end;
    select coalesce(sum((e->>'amount')::numeric), 0) into v_have
      from jsonb_array_elements(case when jsonb_typeof(p_lines) = 'array' then p_lines else '[]'::jsonb end) e
     where e->>'kind' = k and jsonb_typeof(e->'amount') = 'number';
    if abs(v_want - v_have) > 0.005 then
      return array['RIDE_OPTION_CHARGE_CHANGED',
                   public.ride_option_name(k, p_names) || '''s charge here has changed. Check your offer and send it again.'];
    end if;
  end loop;
  return null;
end;
$$;
revoke execute on function public.ride_freight_problem(text, jsonb, jsonb, text, numeric, boolean, double precision,
                                                       double precision, text, text, text) from public, anon, authenticated;

-- App bookings: the checks above, a GET.now code and My Ride's favourites
-- for a freight request; afterwards the cargo stays as booked. After My Ride
-- and GET.now (c_my_ride) have named the targets, beside 0263's c_services.
create or replace function public.ride_requests_freight()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app boolean := coalesce(current_setting('role', true), '') in ('anon', 'authenticated')
                   and not public.caller_admin_can_write('ride_requests');
  v_problem text[];
  v_keep uuid[];
begin
  if tg_op = 'UPDATE' then
    if v_app and (new.cargo_description is distinct from old.cargo_description
                  or new.cargo_photo_path is distinct from old.cargo_photo_path) then
      raise exception 'RIDE_CARGO_FIXED' using errcode = '42501',
        hint = 'The cargo is set when the request is made. Cancel it and make a new one.';
    end if;
    return new;
  end if;
  -- A stand's order and a scheduled booking's release (checked when it was
  -- booked) are not the app's.
  if v_app and new.stand_id is null and new.scheduled_ride_id is null then
    v_problem := public.ride_freight_problem(new.service, new.option_names, new.option_charges, new.cargo_description,
                                             new.declared_value, new.prohibited_ack, new.pickup_lat, new.pickup_lng, new.country, new.state, new.city);
    if v_problem is not null then
      raise exception '%', v_problem[1] using errcode = '22023', hint = v_problem[2];
    end if;
    if new.status = 'open' and new.direct_driver_id is not null
       and not public.driver_takes_freight(new.direct_driver_id, new.service) then
      raise exception 'FREIGHT_DRIVER_NO_FREIGHT' using errcode = '42501',
        hint = 'This driver''s vehicle doesn''t take Freight requests. Book without the code.';
    end if;
  end if;
  if new.direct_driver_id is null and coalesce(cardinality(new.target_driver_ids), 0) > 0
     and public.vehicle_service_is_freight(new.service) then
    select coalesce(array_agg(d), '{}') into v_keep
      from unnest(new.target_driver_ids) d
     where public.driver_takes_freight(d, new.service);
    if cardinality(v_keep) = 0 then
      new.target_driver_ids := null;
      new.targeted_until := null;
    else
      new.target_driver_ids := v_keep;
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_freight() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_c_services_freight on public.ride_requests;
create trigger trg_ride_requests_c_services_freight
  before insert or update of cargo_description, cargo_photo_path on public.ride_requests
  for each row execute function public.ride_requests_freight();

-- A booking for later: the same checks when it is booked, and its cargo.
create or replace function public.scheduled_rides_freight()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  q jsonb := coalesce(new.request, '{}'::jsonb);
  v_problem text[];
begin
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated')
     or public.caller_admin_can_write('scheduled_rides')
     or new.stand_id is not null then
    return new;
  end if;
  if not public.ride_cargo_valid(q->>'cargo_description', q->>'cargo_photo_path', new.rider_id) then
    raise exception 'RIDE_CARGO_INVALID' using errcode = '22023',
      hint = 'Describe the cargo in up to 500 characters; its photo must be your own.';
  end if;
  v_problem := public.ride_freight_problem(new.service, q->'option_names', q->'option_charges', q->>'cargo_description',
                                           case when jsonb_typeof(q->'declared_value') = 'number'
                                                then (q->>'declared_value')::numeric end,
                                           coalesce((q->>'prohibited_ack')::boolean, false), new.pickup_lat, new.pickup_lng, q->>'country', q->>'state', q->>'city');
  if v_problem is not null then
    raise exception '%', v_problem[1] using errcode = '22023', hint = v_problem[2];
  end if;
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_freight() from public, anon, authenticated;

drop trigger if exists trg_scheduled_rides_freight on public.scheduled_rides;
create trigger trg_scheduled_rides_freight
  before insert on public.scheduled_rides
  for each row execute function public.scheduled_rides_freight();

-- ---- 5. Who reads an open freight request ---------------------------------------------------------
-- Restrictive, beside 0250's service order and 0263's driver services, with
-- their exceptions; the caller's freight keys are worked out once per query.
drop policy if exists "ride_requests freight" on public.ride_requests;
create policy "ride_requests freight" on public.ride_requests as restrictive for select to authenticated
  using (status <> 'open'
         or rider_id = (select auth.uid()) or partner_id = (select auth.uid())
         or direct_driver_id = (select auth.uid())
         or (select public.caller_is_admin())
         or (stand_id is not null and array[stand_id] <@ (select public.dispatch_caller_stand_ids()))
         or not (public.driver_service_key(service) = any ((select public.freight_service_keys())::text[]))
         or public.driver_service_key(service) = any ((select public.caller_freight_keys())::text[]));

-- ---- 6. Who is pushed and offered -----------------------------------------------------------------
-- As 0263, the everyone push of a freight request asking every partner and
-- leaving out those without a freight vehicle that may take it.
create or replace function public.ride_request_push_everyone(p_request uuid, p_message jsonb, p_kind text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rider uuid;
  v_service text;
  v_key text;
  v_keys text[];
  v_skip jsonb;
  v_broad boolean;
  v_freight boolean;
begin
  select r.rider_id, r.service, public.ride_extra_keys(r.pets, r.assistance, r.option_names, r.passengers)
    into v_rider, v_service, v_keys
    from public.ride_requests r where r.id = p_request;
  v_key := public.driver_service_key(v_service);
  v_freight := public.vehicle_service_is_freight(v_service);
  -- A lock other than one driver's may cover anybody, and only some
  -- partners take freight: then every partner is asked; else only those
  -- with a switch or a lock of their own.
  v_broad := v_freight
             or exists (select 1 from public.driver_service_locks l
                         where l.scope <> 'driver' and (l.until is null or l.until > now())
                           and (l.service_key = v_key
                                or (cardinality(v_keys) > 0 and l.service_key = any (
                                      array(select 'extra:' || x from unnest(v_keys) x)))));
  select coalesce(jsonb_agg(d), '[]'::jsonb) into v_skip
    from (
      select distinct c.d from (
        select x.driver_id as d from public.driver_ride_extras x where cardinality(v_keys) > 0 and x.off && v_keys
        union
        select p.driver_id from public.driver_service_prefs p where v_key <> '' and p.service_key = v_key and not p.enabled
        union
        select l.driver_id from public.driver_service_locks l
         where l.scope = 'driver' and (l.until is null or l.until > now())
           and (l.service_key = v_key or l.service_key like 'extra:%')
        union
        select pa.auth_user_id from public.partners pa where v_broad and pa.auth_user_id is not null
      ) c
      where c.d is not null
        and not (public.driver_takes_extras(c.d, v_keys) and public.driver_takes_service(c.d, v_service)
                 and (not v_freight or public.driver_takes_freight(c.d, v_service)))
    ) s;
  insert into public.ride_request_pushes (request_id, profile_id, kind) values (p_request, null, p_kind);
  perform public.send_push_webhook(p_message || jsonb_build_object(
    'audience', 'partners',
    'approvedOnly', true,
    'excludeProfileIds', case when v_rider is null then '[]'::jsonb else jsonb_build_array(v_rider) end || v_skip
  ));
end;
$$;
revoke execute on function public.ride_request_push_everyone(uuid, jsonb, text) from public, anon, authenticated;
grant execute on function public.ride_request_push_everyone(uuid, jsonb, text) to service_role;

-- The nearby pushes, a stand group's broadcast, the airport queue and
-- waiting-zone offers and the scheduled rides list, each edited in its
-- current definition (as 0263 did), after 0263's service check.
do $edit$
declare
  e record;
  v_def text;
  v_n int;
begin
  for e in
    select * from (values
      ('ride_request_push_nearby', 'continue when not public.driver_takes_service(v_driver, v_service);',
         'continue when not public.driver_takes_service(v_driver, v_service);' || chr(10)
         || '    continue when not public.driver_takes_freight(v_driver, v_service);'),
      ('dispatch_push', 'and public.driver_takes_service(d.profile_id, r.service)',
         'and public.driver_takes_service(d.profile_id, r.service)' || chr(10)
         || '         and public.driver_takes_freight(d.profile_id, r.service)'),
      ('airport_dispatch', 'and public.driver_takes_service(l.driver_id, r.service)',
         'and public.driver_takes_service(l.driver_id, r.service)' || chr(10)
         || '       and public.driver_takes_freight(l.driver_id, r.service)'),
      ('airport_dispatch', 'and public.driver_takes_service(z.driver_id, r.service)',
         'and public.driver_takes_service(z.driver_id, r.service)' || chr(10)
         || '         and public.driver_takes_freight(z.driver_id, r.service)'),
      ('scheduled_rides_open', 'and public.driver_takes_service(auth.uid(), s.service)',
         'and public.driver_takes_service(auth.uid(), s.service)' || chr(10)
         || '     and public.driver_takes_freight(auth.uid(), s.service)')
    ) as t(fn, anchor, added)
  loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = e.fn;
    if v_def is null then
      raise exception '0267: public.% is missing', e.fn;
    end if;
    -- Run again: a place already edited is left alone.
    continue when position(e.added in v_def) > 0;
    v_n := (length(v_def) - length(replace(v_def, e.anchor, ''))) / length(e.anchor);
    if v_n <> 1 then
      raise exception '0267: public.% should have "%" once (has %); update this migration', e.fn, e.anchor, v_n;
    end if;
    execute replace(v_def, e.anchor, e.added);
  end loop;
end
$edit$;

-- ---- 7. Freight settings (admin) ------------------------------------------------------------------
-- app_settings 'freight': how long a driver's cancel after pickup waits for
-- the sender before it is approved (minutes, default 5), how the recipient
-- is sent the tracking link ('sms', 'whatsapp'; default SMS) and the
-- prohibited items riders confirm they don't send.
insert into public.app_settings (key, value)
values ('freight', jsonb_build_object(
  'cancelApproveMinutes', 5,
  'recipientChannels', jsonb_build_array('sms'),
  'prohibitedItems', jsonb_build_array('Explosives and fireworks', 'Flammable liquids and gas cylinders',
                                       'Weapons and ammunition', 'Illegal drugs', 'Live animals',
                                       'Cash, jewellery and other valuables', 'Hazardous chemicals')))
on conflict (key) do nothing;

create or replace function public.freight_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'cancelApproveMinutes', least(60, greatest(1, coalesce(
      case when jsonb_typeof(v->'cancelApproveMinutes') = 'number' then (v->>'cancelApproveMinutes')::numeric end,
      5)))::int,
    'recipientChannels', coalesce((
      select jsonb_agg(distinct c) from jsonb_array_elements_text(
        case when jsonb_typeof(v->'recipientChannels') = 'array' then v->'recipientChannels' else '["sms"]'::jsonb end) c
       where c in ('sms', 'whatsapp')), '[]'::jsonb),
    'prohibitedItems', coalesce((
      select jsonb_agg(btrim(i) order by n) from jsonb_array_elements_text(
        case when jsonb_typeof(v->'prohibitedItems') = 'array' then v->'prohibitedItems' else '[]'::jsonb end)
        with ordinality x(i, n)
       where char_length(btrim(i)) between 1 and 120 and n <= 200), '[]'::jsonb))
  from (select coalesce((select value from public.app_settings where key = 'freight'), '{}'::jsonb) as v) s;
$$;
revoke execute on function public.freight_config() from public, anon;
grant execute on function public.freight_config() to authenticated, service_role;

-- Admin > Display Settings > Ride Options > Freight settings.
create or replace function public.set_freight_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.caller_admin_can_write('rpc:set_freight_config') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You can''t change the Freight settings.';
  end if;
  insert into public.app_settings (key, value, updated_at) values ('freight', coalesce(p_config, '{}'), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  v := public.freight_config();
  update public.app_settings set value = v where key = 'freight';
  return v;
end;
$$;
revoke execute on function public.set_freight_config(jsonb) from public, anon;
grant execute on function public.set_freight_config(jsonb) to authenticated;

insert into public.admin_table_pages (target, page) values
  ('rpc:set_freight_config', 'admin-settings-display')
on conflict do nothing;

-- ---- 8. Waiting time, the cancel fee and the declared value cap, by place --------------------------
-- Kept in ride_option_places.charges as the option charges are (0253), so
-- each place inherits from the one above:
--   'freight-wait-free-min'  free waiting minutes after the driver arrives (default 20)
--   'freight-wait-per-min'   the fee for each minute after them (default 0)
--   'freight-cancel-arrived' the fee when the sender cancels after the driver arrived (default 0)
--   'freight-declared-cap'   the most a sender may declare (default 500), up to 1,000,000
create or replace function public.freight_place_value(p_charges jsonb, p_key text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    case when jsonb_typeof(p_charges->p_key->'value') = 'number' then (p_charges->p_key->>'value')::numeric end,
    case p_key when 'freight-wait-free-min' then 20 when 'freight-declared-cap' then 500 else 0 end);
$$;

-- As 0253, with the declared value cap allowed up to 1,000,000.
create or replace function public.ride_option_place_valid(p_charges jsonb, p_offered jsonb, p_blocked jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(p_charges) = 'object'
     and jsonb_typeof(p_offered) = 'object'
     and jsonb_typeof(p_blocked) = 'object'
     and pg_column_size(p_charges) <= 65536
     and (select count(*) from jsonb_object_keys(p_charges)) <= 400
     and not exists (
       select 1 from jsonb_each(p_charges) e
        where not coalesce(
          char_length(e.key) between 1 and 120
          and jsonb_typeof(e.value) = 'object'
          and jsonb_typeof(e.value->'value') = 'number'
          and (e.value->>'value')::numeric >= 0
          and (e.value->'kind' is null or e.value->>'kind' in ('fixed', 'percent'))
          and (e.value->>'value')::numeric <= case when e.value->>'kind' = 'percent' then 100
                                                  when e.key = 'freight-declared-cap' then 1000000
                                                  else 10000 end
          and (e.value->'per' is null or e.value->>'per' in ('pet', 'ride')),
          false))
     and not exists (
       select 1 from jsonb_each(p_offered) e
        where not (e.key = any (public.ride_option_ids())) or jsonb_typeof(e.value) <> 'boolean')
     and not exists (
       select 1 from jsonb_each(p_blocked) e
        where not coalesce(
          e.key = any (public.ride_option_ids())
          and jsonb_typeof(e.value) = 'array'
          and jsonb_array_length(e.value) <= 50
          and not exists (select 1 from jsonb_array_elements(e.value) s
                           where jsonb_typeof(s) <> 'string' or char_length(s #>> '{}') not between 1 and 64),
          false));
$$;

-- The values at a ride's pickup.
create or replace function public.freight_charges_at(r public.ride_requests)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.ride_option_settings_at(p.country, p.state, p.city, p.suburb)->'charges'
    from public.ride_option_place(r.pickup_lat, r.pickup_lng, r.country, r.state, r.city) p;
$$;
revoke execute on function public.freight_charges_at(public.ride_requests) from public, anon, authenticated;

alter table public.ride_requests add column if not exists freight_waiting_minutes integer;
alter table public.ride_requests add column if not exists freight_waiting_fee numeric;
alter table public.ride_requests add column if not exists freight_cancel_fee numeric;
alter table public.ride_requests add column if not exists freight_cancel_fee_status text;
alter table public.ride_requests add column if not exists freight_cancel_billed_ride_id uuid;
alter table public.ride_requests drop constraint if exists ride_requests_freight_fees_valid;
alter table public.ride_requests add constraint ride_requests_freight_fees_valid check (
  (freight_waiting_minutes is null or freight_waiting_minutes >= 0)
  and (freight_waiting_fee is null or freight_waiting_fee >= 0)
  and (freight_cancel_fee is null or freight_cancel_fee >= 0)
  and (freight_cancel_fee_status is null or freight_cancel_fee_status in ('due', 'billed', 'paid')));

-- ---- 9. Proof of delivery ---------------------------------------------------------------------------
-- The driver's photos at pickup and at drop-off, in the driver's own folder
-- of ride-cargo (<driver uid>/proof-...); the sender's signature at drop-off
-- in theirs (<rider uid>/signature-...).
alter table public.ride_requests add column if not exists pickup_proof_path text;
alter table public.ride_requests add column if not exists dropoff_proof_path text;
alter table public.ride_requests add column if not exists delivery_signature_path text;

create or replace function public.ride_file_in(p_path text, p_owner uuid)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_path is null
      or (p_owner is not null and starts_with(p_path, p_owner::text || '/')
          and char_length(p_path) <= 300 and position('..' in p_path) = 0);
$$;

alter table public.ride_requests drop constraint if exists ride_requests_freight_proof_valid;
alter table public.ride_requests add constraint ride_requests_freight_proof_valid check (
  public.ride_file_in(pickup_proof_path, partner_id) and public.ride_file_in(dropoff_proof_path, partner_id)
  and public.ride_file_in(delivery_signature_path, rider_id));

-- As above, also the proofs: the ride's rider reads the driver's photos, the
-- driver the rider's signature; admins every one.
create or replace function public.ride_cargo_photo_readable(p_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and coalesce(p_name, '') <> '' and (
    public.caller_is_admin()
    or exists (
      select 1 from public.ride_requests r
       where (r.partner_id = auth.uid() and r.status in ('accepted', 'arrived', 'on_trip', 'completed')
              or r.rider_id = auth.uid())
         and p_name in (r.cargo_photo_path, r.pickup_proof_path, r.dropoff_proof_path, r.delivery_signature_path)
    )
  );
$$;

-- ---- 10. A freight trip, step by step -----------------------------------------------------------------
-- On an update of a freight request's status or proofs, from the app:
--   * the proofs are the driver's (photos) and the sender's (signature)
--     only, while the trip is on (FREIGHT_PROOF_NOT_YOURS);
--   * the trip starts only with the pickup photo, and ends only with the
--     drop-off photo (FREIGHT_PICKUP_PROOF, FREIGHT_DROPOFF_PROOF);
--   * starting it adds the waiting fee: the minutes since the driver arrived
--     past the free ones, times the fee per minute at the pickup;
--   * the sender cancelling after the driver arrived owes the cancel fee,
--     billed on their next request (header: 3);
--   * a driver's cancel after pickup asks the sender (as 0191's requests
--     do); the server approves it once the admin's time has gone by.
create or replace function public.ride_requests_freight_trip()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app boolean := coalesce(current_setting('role', true), '') in ('anon', 'authenticated')
                   and not public.caller_admin_can_write('ride_requests');
  v_charges jsonb;
  v_minutes integer;
  v_fee numeric;
begin
  if old.cargo_description is null then
    return new;
  end if;
  if v_app then
    if (new.pickup_proof_path is distinct from old.pickup_proof_path
        or new.dropoff_proof_path is distinct from old.dropoff_proof_path)
       and (auth.uid() is distinct from old.partner_id or old.status not in ('accepted', 'arrived', 'on_trip')) then
      raise exception 'FREIGHT_PROOF_NOT_YOURS' using errcode = '42501',
        hint = 'Only the driver adds the photos, during the trip.';
    end if;
    if new.delivery_signature_path is distinct from old.delivery_signature_path
       and (auth.uid() is distinct from old.rider_id or old.status not in ('arrived', 'on_trip', 'completed')) then
      raise exception 'FREIGHT_PROOF_NOT_YOURS' using errcode = '42501',
        hint = 'Only the sender signs, at drop-off.';
    end if;
    if new.status = 'on_trip' and old.status is distinct from 'on_trip' and new.pickup_proof_path is null then
      raise exception 'FREIGHT_PICKUP_PROOF' using errcode = '42501',
        hint = 'Take the photo of the cargo at pickup first.';
    end if;
    if new.status = 'completed' and old.status is distinct from 'completed' and new.dropoff_proof_path is null then
      raise exception 'FREIGHT_DROPOFF_PROOF' using errcode = '42501',
        hint = 'Take the photo of the cargo at drop-off first.';
    end if;
  end if;
  if new.status = 'on_trip' and old.status is distinct from 'on_trip' and old.arrived_at is not null then
    v_charges := public.freight_charges_at(old);
    v_minutes := greatest(0, floor(extract(epoch from (now() - old.arrived_at)) / 60))::integer;
    v_fee := round(greatest(0, v_minutes - public.freight_place_value(v_charges, 'freight-wait-free-min'))
                   * public.freight_place_value(v_charges, 'freight-wait-per-min'), 2);
    new.freight_waiting_minutes := v_minutes;
    new.freight_waiting_fee := v_fee;
    if v_fee > 0 then
      new.fare := coalesce(new.fare, 0) + v_fee;
      new.ride_fare := coalesce(new.ride_fare, old.fare, 0) + v_fee;
    end if;
  end if;
  if new.status = 'cancelled' and old.status in ('arrived', 'on_trip') and old.status is distinct from new.status
     and (old.cancel_requested_by = 'rider'
          or (auth.uid() = old.rider_id and old.cancel_requested_by is distinct from 'partner')) then
    v_fee := public.freight_place_value(public.freight_charges_at(old), 'freight-cancel-arrived');
    if v_fee > 0 then
      new.freight_cancel_fee := round(v_fee, 2);
      new.freight_cancel_fee_status := 'due';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_freight_trip() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_d_freight_trip on public.ride_requests;
create trigger trg_ride_requests_d_freight_trip
  before update of status, pickup_proof_path, dropoff_proof_path, delivery_signature_path on public.ride_requests
  for each row execute function public.ride_requests_freight_trip();

-- An owed freight cancel fee goes on the sender's next request, as a late
-- scheduled cancel does (0189): after 0189's own line.
create or replace function public.ride_requests_bill_freight_fees()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owed numeric;
begin
  select coalesce(sum(freight_cancel_fee), 0) into v_owed
    from public.ride_requests where rider_id = new.rider_id and freight_cancel_fee_status = 'due';
  if v_owed > 0 then
    new.charges := case when jsonb_typeof(new.charges) = 'array' then new.charges else '[]'::jsonb end
      || jsonb_build_array(jsonb_build_object(
           'kind', 'surcharge', 'name', 'Freight cancellation fee (earlier request)', 'charge', 'fixed',
           'value', round(v_owed, 2), 'platform', true));
    update public.ride_requests set freight_cancel_fee_status = 'billed', freight_cancel_billed_ride_id = new.id
     where rider_id = new.rider_id and freight_cancel_fee_status = 'due';
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_bill_freight_fees() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_0_bill_owed_freight on public.ride_requests;
create trigger trg_ride_requests_0_bill_owed_freight
  before insert on public.ride_requests
  for each row execute function public.ride_requests_bill_freight_fees();

-- The request that carried it ends: never run, the fee is owed again;
-- completed, it is paid, and the driver who waited is credited with it.
create or replace function public.ride_requests_settle_freight_fees()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  f record;
begin
  if new.status in ('cancelled', 'expired') then
    update public.ride_requests set freight_cancel_fee_status = 'due', freight_cancel_billed_ride_id = null
     where freight_cancel_billed_ride_id = new.id and freight_cancel_fee_status = 'billed';
  elsif new.status = 'completed' then
    for f in
      update public.ride_requests set freight_cancel_fee_status = 'paid'
       where freight_cancel_billed_ride_id = new.id and freight_cancel_fee_status = 'billed'
      returning id, partner_id, freight_cancel_fee
    loop
      continue when f.partner_id is null;
      begin
        insert into public.wallet_transactions (user_id, wallet_type, kind, amount, note)
        values (f.partner_id, 'get_credit', 'freight_cancel_fee', round(f.freight_cancel_fee, 2),
                'Freight cancellation fee: the sender cancelled after you arrived');
      exception when others then
        raise warning 'freight cancel fee of % not credited: %', f.id, sqlerrm;
      end;
    end loop;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_settle_freight_fees() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_freight_fees on public.ride_requests;
create trigger trg_ride_requests_freight_fees
  after update of status on public.ride_requests
  for each row when (new.status in ('cancelled', 'expired', 'completed') and old.status is distinct from new.status)
  execute function public.ride_requests_settle_freight_fees();

-- As 0189, with the freight cancel fees owed.
create or replace function public.my_owed_fees()
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select sum(cancel_fee) from public.scheduled_rides
                    where rider_id = auth.uid() and cancel_fee_status = 'due'), 0)
       + coalesce((select sum(freight_cancel_fee) from public.ride_requests
                    where rider_id = auth.uid() and freight_cancel_fee_status = 'due'), 0);
$$;

-- As 0191, a driver's cancel request on a freight trip after pickup is
-- approved, not lapsed, once the Freight settings' minutes have gone by.
create or replace function public.ride_cancel_requests_lapse()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
  m integer;
begin
  update public.ride_requests
     set status = 'cancelled', cancelled_at = now(),
         cancel_reason = coalesce(cancel_reason, 'Approved automatically: the sender did not answer')
   where cancel_requested_at is not null and cancel_requested_by = 'partner'
     and status = 'on_trip' and cargo_description is not null
     and cancel_requested_at < now() - make_interval(mins => (public.freight_config()->>'cancelApproveMinutes')::int);
  get diagnostics m = row_count;
  perform set_config('getride.cancel_lapsing', '1', true);
  update public.ride_requests
     set cancel_requested_at = null, cancel_requested_by = null
   where cancel_requested_at is not null
     and status in ('accepted', 'arrived', 'on_trip')
     and not (cancel_requested_by = 'partner' and status = 'on_trip' and cargo_description is not null)
     and cancel_requested_at < now() - make_interval(
           secs => (public.ride_cancel_request_config()->>'timeoutSeconds')::int);
  get diagnostics n = row_count;
  perform set_config('getride.cancel_lapsing', '', true);
  return n + m;
end;
$$;
revoke execute on function public.ride_cancel_requests_lapse() from public, anon, authenticated;

-- ---- 11. The recipient's tracking link ----------------------------------------------------------------
-- When a freight trip with a recipient starts, a notice per channel the
-- admin chose waits here; the freight-notify Edge Function sends it (SMS
-- through the outbound support-message gateway route, WhatsApp through the
-- Business Cloud API secrets the function holds) and reports back. The
-- driver's app asks it at once; a job every minute asks it again for any
-- left (with the push webhook's existing secret, nothing new).
create table if not exists public.freight_recipient_notices (
  id         uuid primary key default gen_random_uuid(),
  ride_id    uuid not null references public.ride_requests(id) on delete cascade,
  channel    text not null check (channel in ('sms', 'whatsapp')),
  to_phone   text not null check (char_length(to_phone) between 3 and 32),
  body       text not null check (char_length(body) between 1 and 600),
  status     text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'failed')),
  attempts   integer not null default 0,
  error      text check (error is null or char_length(error) <= 300),
  created_at timestamptz not null default now(),
  sent_at    timestamptz,
  unique (ride_id, channel)
);
create index if not exists freight_recipient_notices_queue_idx
  on public.freight_recipient_notices (status, created_at);
alter table public.freight_recipient_notices enable row level security;
revoke all on public.freight_recipient_notices from anon;
grant select on public.freight_recipient_notices to authenticated;
drop policy if exists "freight_recipient_notices read" on public.freight_recipient_notices;
create policy "freight_recipient_notices read" on public.freight_recipient_notices for select to authenticated
  using ((select public.caller_is_admin())
         or exists (select 1 from public.ride_requests r
                     where r.id = ride_id and (r.rider_id = (select auth.uid()) or r.partner_id = (select auth.uid()))));

-- The trip starts: the share link (0108) and a notice per channel.
create or replace function public.ride_requests_freight_recipient()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c text;
  v_body text;
begin
  if new.cargo_description is null or new.recipient_phone is null
     or new.status <> 'on_trip' or old.status = 'on_trip' then
    return new;
  end if;
  -- The share link is kept aside (0195), as ride_share_link keeps it.
  insert into public.ride_request_private as p (request_id, share_token)
  values (new.id, gen_random_uuid())
  on conflict (request_id) do update set share_token = coalesce(p.share_token, excluded.share_token), updated_at = now();
  v_body := left(format('GET.ride: %s, your delivery from %s is on its way. Track it here: ',
                        coalesce(nullif(btrim(new.recipient_name), ''), 'Hello'),
                        coalesce(nullif(btrim(new.rider_name), ''), 'the sender')), 400);
  for c in select jsonb_array_elements_text(public.freight_config()->'recipientChannels') loop
    insert into public.freight_recipient_notices (ride_id, channel, to_phone, body)
    values (new.id, c, new.recipient_phone, v_body)
    on conflict (ride_id, channel) do nothing;
  end loop;
  return new;
end;
$$;
revoke execute on function public.ride_requests_freight_recipient() from public, anon, authenticated;

-- Last of the before triggers: it reads the recipient once it is back on the row.
drop trigger if exists trg_ride_requests_freight_recipient on public.ride_requests;
drop trigger if exists trg_ride_requests_zzzz_freight_recipient on public.ride_requests;
create trigger trg_ride_requests_zzzz_freight_recipient
  before update of status on public.ride_requests
  for each row execute function public.ride_requests_freight_recipient();

-- For the Edge Function (service role): the notices to send now, for one
-- ride or all, each with its tracking link token; claimed as sending.
create or replace function public.freight_notices_claim(p_ride uuid default null)
returns table (id uuid, channel text, to_phone text, body text, share_token uuid)
language sql
security definer
set search_path = public
as $$
  update public.freight_recipient_notices n
     set status = 'sending', attempts = n.attempts + 1
   where (p_ride is null or n.ride_id = p_ride)
     and (n.status = 'queued' or (n.status = 'failed' and n.attempts < 3))
  returning n.id, n.channel, n.to_phone, n.body,
            (select v.share_token from public.ride_request_private v where v.request_id = n.ride_id);
$$;

create or replace function public.freight_notice_report(p_id uuid, p_ok boolean, p_error text default null)
returns void
language sql
security definer
set search_path = public
as $$
  update public.freight_recipient_notices
     set status = case when p_ok then 'sent' else 'failed' end,
         sent_at = case when p_ok then now() end,
         error = case when p_ok then null else left(p_error, 300) end
   where id = p_id;
$$;

-- Who may make freight-notify send for a ride: its driver or its rider.
create or replace function public.freight_notice_caller_ok(p_ride uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.ride_requests r
                  where r.id = p_ride and p_user is not null and (r.partner_id = p_user or r.rider_id = p_user));
$$;

revoke execute on function public.freight_notices_claim(uuid), public.freight_notice_report(uuid, boolean, text),
  public.freight_notice_caller_ok(uuid, uuid) from public, anon, authenticated;
grant execute on function public.freight_notices_claim(uuid), public.freight_notice_report(uuid, boolean, text),
  public.freight_notice_caller_ok(uuid, uuid) to service_role;

-- Every minute: asks freight-notify for notices left waiting, with the push
-- webhook's Vault secret (0128). A job, not a trigger, and not the clients'.
create or replace function public.freight_notices_kick()
returns void
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url text;
  v_secret text;
begin
  if not exists (select 1 from public.freight_recipient_notices
                  where (status = 'queued' and created_at < now() - interval '20 seconds')
                     or (status = 'failed' and attempts < 3)) then
    return;
  end if;
  begin
    select decrypted_secret into v_url from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_webhook_secret' limit 1;
  exception when others then
    return;
  end;
  if v_url is null or v_secret is null then
    return;
  end if;
  perform net.http_post(
    url     := v_url || '/functions/v1/freight-notify',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body    := '{}'::jsonb);
exception when others then
  null;
end;
$$;
revoke execute on function public.freight_notices_kick() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'freight-recipient-notices';
    perform cron.schedule('freight-recipient-notices', '* * * * *', $job$select public.freight_notices_kick()$job$);
  end if;
end $$;

-- ---- 11b. The recipient and the declared value wait aside --------------------------------------------
-- Ride privacy (0182, 0195) for the sender's freight details: while a
-- request is open, approved drivers read its row to bid, so the recipient's
-- name and phone and the declared value wait in ride_request_private (the
-- rider and admins). When a driver takes it they come back to the row,
-- which only the rider, that driver and admins read; reopened, they move
-- out again. Before 0248's / 0247's / 0195's own (zz_assistance <
-- zz_freight_private < zz_pets < zz_privacy); the booking checks above
-- (c_services_freight) see them first.
alter table public.ride_request_private add column if not exists recipient_name text;
alter table public.ride_request_private add column if not exists recipient_phone text;
alter table public.ride_request_private add column if not exists declared_value numeric;

create or replace function public.ride_requests_freight_private()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ins boolean := tg_op = 'INSERT';
  pv public.ride_request_private;
begin
  if new.status = 'open' then
    if new.recipient_name is not null or new.recipient_phone is not null or new.declared_value is not null then
      insert into public.ride_request_private as p (request_id, recipient_name, recipient_phone, declared_value)
      values (new.id, new.recipient_name, new.recipient_phone, new.declared_value)
      on conflict (request_id) do update set
        recipient_name  = coalesce(excluded.recipient_name, p.recipient_name),
        recipient_phone = coalesce(excluded.recipient_phone, p.recipient_phone),
        declared_value  = coalesce(excluded.declared_value, p.declared_value),
        updated_at      = now();
    end if;
    new.recipient_name := null;
    new.recipient_phone := null;
    new.declared_value := null;
  elsif not ins and old.status = 'open' then
    -- Taken (or ended): they come back to the row.
    select * into pv from public.ride_request_private where request_id = new.id;
    if found then
      new.recipient_name  := coalesce(new.recipient_name, pv.recipient_name);
      new.recipient_phone := coalesce(new.recipient_phone, pv.recipient_phone);
      new.declared_value  := coalesce(new.declared_value, pv.declared_value);
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_freight_private() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_zz_freight_private on public.ride_requests;
create trigger trg_ride_requests_zz_freight_private
  before insert or update on public.ride_requests
  for each row execute function public.ride_requests_freight_private();

-- Requests already open when this runs: their details move aside too.
insert into public.ride_request_private as p (request_id, recipient_name, recipient_phone, declared_value)
select r.id, r.recipient_name, r.recipient_phone, r.declared_value from public.ride_requests r
 where r.status = 'open' and (r.recipient_phone is not null or r.recipient_name is not null or r.declared_value is not null)
on conflict (request_id) do update set
  recipient_name  = coalesce(p.recipient_name, excluded.recipient_name),
  recipient_phone = coalesce(p.recipient_phone, excluded.recipient_phone),
  declared_value  = coalesce(p.declared_value, excluded.declared_value);
update public.ride_requests set recipient_name = null, recipient_phone = null, declared_value = null
 where status = 'open' and (recipient_phone is not null or recipient_name is not null or declared_value is not null);

-- ---- 12. Live ------------------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public'
                    and tablename = 'freight_recipient_notices') then
    alter publication supabase_realtime add table public.freight_recipient_notices;
  end if;
end $$;

notify pgrst, 'reload schema';
