-- ============================================================================
-- 0268 — Courier: parcels by walker, bicycle, motorcycle or car, bid on as
-- rides, with a confirmation code at drop-off and the recipient able to pay.
--
-- Applied by hand as version 20261021032600 (0268_courier in
-- supabase_migrations.schema_migrations). Re-runnable: every object is
-- created with "if not exists" / "or replace", the seeds only add what is
-- missing. 0268 was kept for this; it runs after 0272 (live already has
-- 0266, 0267 and 0269 to 0272), so each function it changes is copied from
-- its latest definition (0267, or 0271 where 0271 redefined it). In a
-- fresh replay in file order (CI, a new project) it runs before 0269:
-- ride_offer_make and ride_cancel_terms need 0269's tables, so they are
-- redefined here only when 0269 is there; otherwise 0269 and 0271 define
-- them afterwards (a driver who can't take a courier request is then
-- refused with 0271's FREIGHT_DRIVER_NO_FREIGHT, and the terms show the
-- freight cancel fee's number instead of the courier one).
--
-- A courier request IS a ride request, built on Freight's parts (0267): its
-- service is a Vehicle Service whose Service types include "Courier", it
-- carries cargo_description (what is sent), and so it gets 0267's proof of
-- delivery photos and signature, sender-approved cancel after pickup,
-- waiting and cancel fees, prohibited items and declared value, the
-- recipient's tracking link and 0271's freight-only fees. What is new:
--
-- 1. The four courier vehicles, seeded INACTIVE (status false) so nothing
--    goes live until the owner switches them on, under a "Courier" entry in
--    Service Settings (added when missing):
--      Courier Walker      up to 5 kg,  30 x 30 x 30 cm
--      Courier Bicycle     up to 8 kg,  40 x 40 x 40 cm
--      Courier Motorcycle  up to 10 kg, 50 x 50 x 50 cm
--      Courier Car         up to 20 kg, 70 x 50 x 50 cm
--    as 0267's maxLoadKg / loadLengthM / loadWidthM / loadHeightM, editable
--    in Admin > Vehicle Services. Named "Courier ..." because a ride's
--    service is matched by name (vehicle_service_id_of) and "Car" or
--    "Motorcycle" is usually a ride service already. No goods-vehicle permit.
--    A driver whose vehicle's approved service is a courier one takes a
--    courier request its vehicle can carry: the same service, a higher one
--    in the service order, or one with at least that load
--    (courier_vehicle_carries). driver_takes_freight, which every push,
--    dispatch, airport, scheduled list and offer check already calls (0267,
--    0271), now answers for courier too; ride_offer_make says why
--    (COURIER_DRIVER_NO_COURIER).
-- 2. ride_requests.parcel_size ('S', 'M', 'L'; the kilos per size are the
--    Courier settings', 5 / 15 / 20 by default) and payer ('sender' or
--    'recipient'): the recipient pays the courier in cash on delivery and
--    the sender nothing up front. Both are fixed once booked
--    (COURIER_FIXED). An app booking is refused when (ride_courier_problem):
--      - a parcel size or recipient-pays is on a service that isn't courier
--        (COURIER_SIZE_NOT_COURIER, COURIER_RECIPIENT_PAYS_ONLY);
--      - it is courier without a size (COURIER_PARCEL_SIZE), with a parcel
--        heavier than the vehicle's load (COURIER_TOO_HEAVY), without what
--        is sent (COURIER_ITEM_REQUIRED), the prohibited items confirmed
--        (COURIER_PROHIBITED_ACK), a declared value (COURIER_DECLARED_VALUE)
--        within the place's cap (COURIER_DECLARED_VALUE_CAP, 'courier-
--        declared-cap', default 500), or the recipient's phone
--        (COURIER_RECIPIENT_REQUIRED);
--      - the recipient pays by anything but cash (COURIER_RECIPIENT_PAYS_CASH).
--    A GET.now code naming a driver who can't take it is refused
--    (COURIER_DRIVER_NO_COURIER); My Ride favourites who can't are left out.
-- 3. The confirmation code: every courier request gets a 4-digit code
--    (ride_delivery_codes, as 0152's ride_trip_codes; nobody reads the
--    table). The Courier settings' codeChannels say who gets it: 'sms' and
--    'whatsapp' send it to the recipient with the tracking link (the
--    freight-notify Edge Function adds it; the notice row the driver can
--    read never holds it), 'sender' shows it to the sender in the app
--    (courier_delivery_code). The sender also sees it when no message
--    channel is chosen or every message failed. The courier types it in
--    (courier_code_check: 5 tries per 10 minutes) and only then can finish
--    the trip (COURIER_CODE_REQUIRED).
-- 4. Courier settings (app_settings 'courier', set_courier_config):
--    codeChannels, cancelApproveMinutes (a courier's cancel after pickup),
--    prohibitedItems and parcelSizes. Waiting, the cancel fee and the
--    declared value cap are per place as Freight's: 'courier-wait-free-min'
--    (default 10), 'courier-wait-per-min', 'courier-cancel-arrived',
--    'courier-declared-cap' (default 500).
-- 5. Courier is exempt from the city cancel fees as freight is
--    (ride_request_is_freight), and ride_cancel_terms gives its own fee.
-- ============================================================================

-- ---- 1. Courier vehicle services --------------------------------------------------------------------
-- Whether a Vehicle Service's values name the Courier service type.
create or replace function public.vehicle_service_values_courier(p_values jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select exists (
    select 1 from jsonb_array_elements_text(case when jsonb_typeof(p_values->'serviceTypes') = 'array'
                                                 then p_values->'serviceTypes' else '[]'::jsonb end) t
     where lower(btrim(t)) = 'courier');
$$;

-- The courier Vehicle Services (settings entry ids), active or not.
create or replace function public.courier_service_ids()
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(e.id::text order by e.position), '{}')
    from public.settings_entries e
   where e.category = 'vehicle-services' and public.vehicle_service_values_courier(e.values);
$$;

-- Their names as driver_service_key compares ride_requests.service (0263).
create or replace function public.courier_service_keys()
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(distinct public.driver_service_key(e.values->>'name')), '{}')
    from public.settings_entries e
   where e.category = 'vehicle-services' and public.vehicle_service_values_courier(e.values)
     and coalesce(btrim(e.values->>'name'), '') <> '';
$$;

-- Whether a ride's service (a name) is a courier one.
create or replace function public.vehicle_service_is_courier(p_service text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.vehicle_service_id_of(p_service) = any (public.courier_service_ids()), false);
$$;

-- The most a Vehicle Service carries (maxLoadKg, 0267); null when not set.
create or replace function public.vehicle_service_load_kg(p_service_id text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case when jsonb_typeof(e.values->'maxLoadKg') = 'number' and (e.values->>'maxLoadKg')::numeric > 0
              then (e.values->>'maxLoadKg')::numeric end
    from public.settings_entries e
   where e.id::text = p_service_id and e.category = 'vehicle-services';
$$;

-- Whether a vehicle of the courier service [p_mine] may take a request of
-- the courier service [p_want] (both settings entry ids): the same one, a
-- higher one in the service order, or one that carries at least as much.
create or replace function public.courier_vehicle_carries(p_mine text, p_want text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select nullif(p_mine, '') is not null and p_mine = any (public.courier_service_ids())
     and (p_mine = p_want
          or public.service_order_allows(p_mine, (select e.values->>'name' from public.settings_entries e
                                                   where e.id::text = p_want))
             and public.vehicle_service_rank(p_want) is not null
          or coalesce(public.vehicle_service_load_kg(p_mine), 0) >= coalesce(public.vehicle_service_load_kg(p_want), 1e12));
$$;

-- As 0267, and for a courier service: a driver whose vehicle's approved
-- service is a courier one that carries it (no goods-vehicle permit).
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
  if public.vehicle_service_is_courier(p_service) then
    return public.courier_vehicle_carries(public.driver_vehicle_service(p_driver), public.vehicle_service_id_of(p_service));
  end if;
  if not public.vehicle_service_is_freight(p_service) then
    return true;
  end if;
  v_mine := public.driver_vehicle_service(p_driver);
  return v_mine is not null and v_mine = any (public.freight_service_ids())
     and public.service_order_allows(v_mine, p_service)
     and public.driver_goods_permit_ok(p_driver, v_mine);
end;
$$;

-- The courier service keys the caller may take with the vehicle they drive.
create or replace function public.caller_courier_keys()
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_mine text := public.driver_vehicle_service(auth.uid());
begin
  if v_mine is null or not (v_mine = any (public.courier_service_ids())) then
    return '{}';
  end if;
  return coalesce((
    select array_agg(distinct public.driver_service_key(e.values->>'name'))
      from public.settings_entries e
     where e.category = 'vehicle-services' and public.vehicle_service_values_courier(e.values)
       and coalesce(btrim(e.values->>'name'), '') <> ''
       and public.courier_vehicle_carries(v_mine, e.id::text)), '{}');
end;
$$;

revoke execute on function public.courier_service_ids(), public.courier_service_keys(),
  public.vehicle_service_is_courier(text), public.vehicle_service_load_kg(text),
  public.courier_vehicle_carries(text, text), public.caller_courier_keys() from public, anon;
revoke execute on function public.courier_vehicle_carries(text, text) from authenticated;
revoke execute on function public.driver_takes_freight(uuid, text) from public, anon, authenticated;
grant execute on function public.courier_service_ids(), public.courier_service_keys(),
  public.vehicle_service_is_courier(text), public.vehicle_service_load_kg(text),
  public.caller_courier_keys() to authenticated, service_role;
grant execute on function public.courier_vehicle_carries(text, text), public.driver_takes_freight(uuid, text)
  to service_role;

-- ---- 2. The seeds ----------------------------------------------------------------------------------------
-- The "Courier" service type, when Service Settings has none by that name.
insert into public.settings_entries (id, category, values, position)
select '636f7572-6965-4000-8000-000000000000', 'service-settings',
       jsonb_build_object('name', 'Courier', 'description', 'Parcels by walker, bicycle, motorcycle or car.',
                          'iconUri', '', 'active', true, 'isDefault', false,
                          'displayPriority', coalesce((select count(*) from public.settings_entries
                                                        where category = 'service-settings'), 0) + 1),
       coalesce((select max(position) from public.settings_entries where category = 'service-settings'), 0) + 1
 where not exists (select 1 from public.settings_entries
                    where category = 'service-settings' and lower(btrim(values->>'name')) = 'courier')
on conflict (id) do nothing;

-- The four vehicles, inactive, each added only when no Vehicle Service has
-- its name. Fares are the owner's to set (Fare tariffs, or these).
insert into public.settings_entries (id, category, values, position)
select s.id::uuid, 'vehicle-services',
       jsonb_build_object(
         'name', s.name, 'description', s.description, 'shortDescription', s.short,
         'serviceTypes', jsonb_build_array('Courier'), 'parentServices', '[]'::jsonb, 'fuelTypes', '[]'::jsonb,
         'status', false,
         'iconUri', '', 'heroImageUri', '', 'mapIconUri', '', 'mapIconColor', '',
         'costPerKm', s.per_km, 'costPerMin', s.per_min, 'minFareAmount', s.min_fare,
         'displayPriority', 900 + s.n,
         'maxLoadKg', s.kg, 'loadLengthM', s.l, 'loadWidthM', s.w, 'loadHeightM', s.h),
       coalesce((select max(position) from public.settings_entries where category = 'vehicle-services'), 0) + s.n
  from (values
    (1, '636f7572-6965-4000-8000-000000000001', 'Courier Walker', 'A courier on foot, for small parcels nearby.',
        'On foot, small parcels', 0.5, 0.1, 5, 5, 0.3, 0.3, 0.3),
    (2, '636f7572-6965-4000-8000-000000000002', 'Courier Bicycle', 'A courier by bicycle, for small parcels.',
        'By bicycle', 0.6, 0.1, 5, 8, 0.4, 0.4, 0.4),
    (3, '636f7572-6965-4000-8000-000000000003', 'Courier Motorcycle', 'A courier by motorcycle.',
        'By motorcycle', 0.8, 0.15, 6, 10, 0.5, 0.5, 0.5),
    (4, '636f7572-6965-4000-8000-000000000004', 'Courier Car', 'A courier by car, for larger parcels.',
        'By car, larger parcels', 1.2, 0.2, 8, 20, 0.7, 0.5, 0.5)
  ) as s(n, id, name, description, short, per_km, per_min, min_fare, kg, l, w, h)
 where not exists (select 1 from public.settings_entries e
                    where e.category = 'vehicle-services' and lower(btrim(e.values->>'name')) = lower(s.name))
on conflict (id) do nothing;

-- ---- 3. The parcel, who pays and the code -----------------------------------------------------------------
alter table public.ride_requests add column if not exists parcel_size text;
alter table public.ride_requests add column if not exists payer text;
alter table public.ride_requests add column if not exists delivery_code_ok_at timestamptz;
alter table public.ride_requests drop constraint if exists ride_requests_courier_valid;
alter table public.ride_requests add constraint ride_requests_courier_valid check (
  (parcel_size is null or parcel_size in ('S', 'M', 'L'))
  and (payer is null or payer in ('sender', 'recipient')));
comment on column public.ride_requests.parcel_size is
  'Courier (0268): the parcel size the sender picked, S / M / L (kilos per size in the Courier settings).';
comment on column public.ride_requests.payer is
  'Courier (0268): who pays, the sender (null or ''sender'') or the recipient, in cash on delivery.';
comment on column public.ride_requests.delivery_code_ok_at is
  'Courier (0268): when the courier entered the recipient''s confirmation code (courier_code_check).';

create table if not exists public.ride_delivery_codes (
  request_id uuid primary key
             references public.ride_requests(id) on delete cascade deferrable initially deferred,
  code       text not null check (code ~ '^[0-9]{4}$'),
  created_at timestamptz not null default now()
);
alter table public.ride_delivery_codes enable row level security;
revoke all on public.ride_delivery_codes from anon, authenticated;

-- ---- 4. Courier settings (admin) ------------------------------------------------------------------------
insert into public.app_settings (key, value)
values ('courier', jsonb_build_object(
  'codeChannels', jsonb_build_array('sms', 'sender'),
  'cancelApproveMinutes', 5,
  'parcelSizes', jsonb_build_object('S', 5, 'M', 15, 'L', 20),
  'prohibitedItems', jsonb_build_array('Explosives and fireworks', 'Flammable liquids and gas cylinders',
                                       'Weapons and ammunition', 'Illegal drugs', 'Live animals',
                                       'Cash, jewellery and other valuables', 'Hazardous chemicals')))
on conflict (key) do nothing;

-- One size's kilos: a number from 0.1 to 1,000, else [p_default].
create or replace function public.courier_size_kg_of(p_sizes jsonb, p_size text, p_default numeric)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select case when jsonb_typeof(p_sizes) = 'object' and jsonb_typeof(p_sizes->p_size) = 'number'
                   and (p_sizes->>p_size)::numeric between 0.1 and 1000
              then round((p_sizes->>p_size)::numeric, 1) else p_default end;
$$;

create or replace function public.courier_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'codeChannels', coalesce((
      select jsonb_agg(c order by array_position(array['sms', 'whatsapp', 'sender'], c))
        from (select distinct c from jsonb_array_elements_text(
               case when jsonb_typeof(v->'codeChannels') = 'array' then v->'codeChannels'
                    else '["sms", "sender"]'::jsonb end) c
              where c in ('sms', 'whatsapp', 'sender')) x), '["sender"]'::jsonb),
    'cancelApproveMinutes', least(60, greatest(1, coalesce(
      case when jsonb_typeof(v->'cancelApproveMinutes') = 'number' then (v->>'cancelApproveMinutes')::numeric end,
      5)))::int,
    'parcelSizes', jsonb_build_object(
      'S', public.courier_size_kg_of(v->'parcelSizes', 'S', 5),
      'M', public.courier_size_kg_of(v->'parcelSizes', 'M', 15),
      'L', public.courier_size_kg_of(v->'parcelSizes', 'L', 20)),
    'prohibitedItems', coalesce((
      select jsonb_agg(btrim(i) order by n) from jsonb_array_elements_text(
        case when jsonb_typeof(v->'prohibitedItems') = 'array' then v->'prohibitedItems' else '[]'::jsonb end)
        with ordinality x(i, n)
       where char_length(btrim(i)) between 1 and 120 and n <= 200), '[]'::jsonb))
  from (select coalesce((select value from public.app_settings where key = 'courier'), '{}'::jsonb) as v) s;
$$;

-- The kilos a parcel of [p_size] may weigh; null for no size.
create or replace function public.courier_parcel_kg(p_size text)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case when p_size in ('S', 'M', 'L') then (public.courier_config()->'parcelSizes'->>p_size)::numeric end;
$$;

revoke execute on function public.courier_config(), public.courier_parcel_kg(text) from public, anon;
grant execute on function public.courier_config(), public.courier_parcel_kg(text) to authenticated, service_role;

-- Admin > Display Settings > Ride Options > Courier settings.
create or replace function public.set_courier_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.caller_admin_can_write('rpc:set_courier_config') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You can''t change the Courier settings.';
  end if;
  insert into public.app_settings (key, value, updated_at) values ('courier', coalesce(p_config, '{}'), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  v := public.courier_config();
  update public.app_settings set value = v where key = 'courier';
  return v;
end;
$$;
revoke execute on function public.set_courier_config(jsonb) from public, anon;
grant execute on function public.set_courier_config(jsonb) to authenticated;

insert into public.admin_table_pages (target, page) values
  ('rpc:set_courier_config', 'admin-settings-display')
on conflict do nothing;

-- ---- 5. Waiting, the cancel fee and the declared value cap, by place ---------------------------------------
-- As 0267, with the courier values beside the freight ones:
--   'courier-wait-free-min' (default 10), 'courier-wait-per-min',
--   'courier-cancel-arrived', 'courier-declared-cap' (default 500).
create or replace function public.freight_place_value(p_charges jsonb, p_key text)
returns numeric
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    case when jsonb_typeof(p_charges->p_key->'value') = 'number' then (p_charges->p_key->>'value')::numeric end,
    case p_key when 'freight-wait-free-min' then 20 when 'courier-wait-free-min' then 10
               when 'freight-declared-cap' then 500 when 'courier-declared-cap' then 500 else 0 end);
$$;

-- As 0267, with the courier declared value cap allowed up to 1,000,000 too.
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
                                                  when e.key in ('freight-declared-cap', 'courier-declared-cap') then 1000000
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

-- The place value [p_name] ('wait-free-min', 'wait-per-min',
-- 'cancel-arrived', 'declared-cap') of a ride's kind: courier or freight.
create or replace function public.delivery_place_key(r public.ride_requests, p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when r.parcel_size is not null then 'courier-' else 'freight-' end || p_name;
$$;

-- ---- 6. Bookings -----------------------------------------------------------------------------------------
-- Why an app booking of [p_service] with this parcel, payer and cargo can't
-- go out at its pickup, as {code, hint}; null when it can (header: 2).
create or replace function public.ride_courier_problem(
  p_service text, p_size text, p_payer text, p_payment text, p_recipient_phone text, p_cargo text,
  p_declared numeric, p_ack boolean,
  p_lat double precision, p_lng double precision, p_country text, p_state text, p_city text)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_charges jsonb;
  v_kg numeric;
  v_load numeric;
  v_cap numeric;
begin
  if not public.vehicle_service_is_courier(p_service) then
    if p_size is not null then
      return array['COURIER_SIZE_NOT_COURIER', 'A parcel size is for Courier only. Book it from the Courier page.'];
    end if;
    if p_payer = 'recipient' then
      return array['COURIER_RECIPIENT_PAYS_ONLY', 'Only a courier delivery can be paid by the recipient.'];
    end if;
    return null;
  end if;
  if p_size is null then
    return array['COURIER_PARCEL_SIZE', 'Choose the parcel size.'];
  end if;
  v_kg := public.courier_parcel_kg(p_size);
  v_load := public.vehicle_service_load_kg(public.vehicle_service_id_of(p_service));
  if v_load is not null and v_kg > v_load then
    return array['COURIER_TOO_HEAVY',
                 format('A %s parcel (up to %s kg) is too heavy for %s. Choose a bigger vehicle.',
                        p_size, trim_scale(v_kg), btrim(p_service))];
  end if;
  if coalesce(btrim(p_cargo), '') = '' then
    return array['COURIER_ITEM_REQUIRED', 'Say what you are sending.'];
  end if;
  if not coalesce(p_ack, false) then
    return array['COURIER_PROHIBITED_ACK', 'Confirm that your parcel has none of the prohibited items.'];
  end if;
  if p_declared is null or p_declared < 0 then
    return array['COURIER_DECLARED_VALUE', 'Enter the value of your items.'];
  end if;
  select public.ride_option_settings_at(p.country, p.state, p.city, p.suburb)->'charges' into v_charges
    from public.ride_option_place(p_lat, p_lng, p_country, p_state, p_city) p;
  v_cap := public.freight_place_value(v_charges, 'courier-declared-cap');
  if p_declared > v_cap then
    return array['COURIER_DECLARED_VALUE_CAP',
                 'The value of your items can be at most ' || trim_scale(v_cap)::text
                 || ' here. Send higher-value items another way.'];
  end if;
  if coalesce(btrim(p_recipient_phone), '') = '' then
    return array['COURIER_RECIPIENT_REQUIRED', 'Add the recipient''s phone number.'];
  end if;
  if p_payer = 'recipient' and position('cash' in lower(coalesce(p_payment, ''))) = 0 then
    return array['COURIER_RECIPIENT_PAYS_CASH', 'The recipient pays the courier in cash. Choose Cash.'];
  end if;
  return null;
end;
$$;
revoke execute on function public.ride_courier_problem(text, text, text, text, text, text, numeric, boolean,
                                                       double precision, double precision, text, text, text)
  from public, anon, authenticated;

-- App bookings: the checks above, a GET.now code and My Ride's favourites
-- for a courier request, and its code; afterwards the parcel and the payer
-- stay as booked and only courier_code_check stamps the code. Before 0267's
-- c_services_freight, after My Ride (c_my_ride) and the service order.
create or replace function public.ride_requests_courier()
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
    if v_app and (new.parcel_size is distinct from old.parcel_size or new.payer is distinct from old.payer) then
      raise exception 'COURIER_FIXED' using errcode = '42501',
        hint = 'The parcel and who pays are set when the request is made. Cancel it and make a new one.';
    end if;
    if v_app and new.delivery_code_ok_at is distinct from old.delivery_code_ok_at
       and coalesce(current_setting('getride.courier_code_ok', true), '') <> '1' then
      raise exception 'COURIER_CODE_NOT_YOURS' using errcode = '42501',
        hint = 'The courier enters the recipient''s code to finish the delivery.';
    end if;
    return new;
  end if;
  if v_app then
    new.delivery_code_ok_at := null;
  end if;
  -- A stand's order and a scheduled booking's release (checked when it was
  -- booked) are not the app's.
  if v_app and new.stand_id is null and new.scheduled_ride_id is null then
    v_problem := public.ride_courier_problem(new.service, new.parcel_size, new.payer, new.payment_mode,
                                             new.recipient_phone, new.cargo_description, new.declared_value,
                                             new.prohibited_ack, new.pickup_lat, new.pickup_lng,
                                             new.country, new.state, new.city);
    if v_problem is not null then
      raise exception '%', v_problem[1] using errcode = '22023', hint = v_problem[2];
    end if;
    if new.status = 'open' and new.direct_driver_id is not null
       and public.vehicle_service_is_courier(new.service)
       and not public.driver_takes_freight(new.direct_driver_id, new.service) then
      raise exception 'COURIER_DRIVER_NO_COURIER' using errcode = '42501',
        hint = 'This driver''s vehicle doesn''t take this courier request. Book without the code.';
    end if;
  end if;
  if new.direct_driver_id is null and coalesce(cardinality(new.target_driver_ids), 0) > 0
     and public.vehicle_service_is_courier(new.service) then
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
  -- The confirmation code (header: 3), kept where nobody reads it.
  if new.parcel_size is not null then
    insert into public.ride_delivery_codes (request_id, code) values (new.id, public.new_trip_code())
    on conflict (request_id) do nothing;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_courier() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_c_services_courier on public.ride_requests;
create trigger trg_ride_requests_c_services_courier
  before insert or update of parcel_size, payer, delivery_code_ok_at on public.ride_requests
  for each row execute function public.ride_requests_courier();

-- A booking for later: the same checks when it is booked.
create or replace function public.scheduled_rides_courier()
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
  v_problem := public.ride_courier_problem(new.service, q->>'parcel_size', q->>'payer', q->>'payment_mode',
                                           q->>'recipient_phone', q->>'cargo_description',
                                           case when jsonb_typeof(q->'declared_value') = 'number'
                                                then (q->>'declared_value')::numeric end,
                                           coalesce((q->>'prohibited_ack')::boolean, false),
                                           new.pickup_lat, new.pickup_lng, q->>'country', q->>'state', q->>'city');
  if v_problem is not null then
    raise exception '%', v_problem[1] using errcode = '22023', hint = v_problem[2];
  end if;
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_courier() from public, anon, authenticated;

drop trigger if exists trg_scheduled_rides_courier on public.scheduled_rides;
create trigger trg_scheduled_rides_courier
  before insert on public.scheduled_rides
  for each row execute function public.scheduled_rides_courier();

-- As 0267, a booking for later keeps the parcel and who pays too.
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
       'recipient_name', 'recipient_phone',
       -- 0268: a courier booking's parcel size and who pays.
       'parcel_size', 'payer'])
       and (e.key <> 'charges' or jsonb_typeof(e.value) = 'array')
  ), '{}'::jsonb);
$$;

-- ---- 7. Who reads, is pushed and offers on an open courier request ------------------------------------------
-- Restrictive, beside 0267's freight one, with the same exceptions.
drop policy if exists "ride_requests courier" on public.ride_requests;
create policy "ride_requests courier" on public.ride_requests as restrictive for select to authenticated
  using (status <> 'open'
         or rider_id = (select auth.uid()) or partner_id = (select auth.uid())
         or direct_driver_id = (select auth.uid())
         or (select public.caller_is_admin())
         or (stand_id is not null and array[stand_id] <@ (select public.dispatch_caller_stand_ids()))
         or not (public.driver_service_key(service) = any ((select public.courier_service_keys())::text[]))
         or public.driver_service_key(service) = any ((select public.caller_courier_keys())::text[]));

-- As 0267, a courier request asks every partner too and leaves out those
-- whose vehicle can't take it.
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
  -- Freight or courier: only some partners take it.
  v_freight := public.vehicle_service_is_freight(v_service) or public.vehicle_service_is_courier(v_service);
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

-- As 0271, with the courier reason after the freight one.
do $do$
begin
  -- 0269's offers: in a fresh replay (file order) 0269 and 0271 come after this and define it themselves.
  if to_regclass('public.ride_offers') is null then
    return;
  end if;
  execute $fn$
create or replace function public.ride_offer_make(p_request uuid, p_amount numeric, p_eta_min int default null,
                                                 p_lat double precision default null,
                                                 p_lng double precision default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  c jsonb := public.city_ride_config()->'offers';
  r public.ride_requests;
  card record;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_declines int;
  v_paused timestamptz;
  o public.ride_offers;
  l public.driver_service_locks;
  v_mine text;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.status <> 'open' then
    raise exception 'OFFER_REQUEST_CLOSED' using errcode = 'P0001', hint = 'This request is no longer open.';
  end if;
  if r.rider_id = v_uid then
    raise exception 'RIDE_CLAIM_OWN_RIDE' using errcode = '42501', hint = 'You can''t take a ride you booked.';
  end if;
  if not public.caller_is_approved_partner() then
    raise exception 'RIDE_CLAIM_REQUIRES_APPROVED_PARTNER' using errcode = '42501',
      hint = 'Only partners approved by an administrator can accept or bid on rides.';
  end if;
  if not public.ptr_caller_available_at(r.pickup_lat, r.pickup_lng) then
    raise exception 'RIDE_TYPE_NOT_AVAILABLE' using errcode = '42501',
      hint = 'Your partner type is not offered where this ride starts.';
  end if;
  if not public.driver_takes_service(v_uid, r.service) then
    l := public.driver_service_lock(v_uid, public.driver_session_vehicle(v_uid), r.service);
    raise exception 'DRIVER_SERVICE_OFF' using errcode = '42501',
      hint = case when l.id is not null
                  then format('get.ride keeps %s off for you. Contact support to change it.', r.service)
                  else format('You turned %s off in Services. Turn it on to take these requests.', r.service) end;
  end if;
  if not public.driver_takes_freight(v_uid, r.service) then
    if public.vehicle_service_is_courier(r.service) then
      raise exception 'COURIER_DRIVER_NO_COURIER' using errcode = '42501',
        hint = 'Your vehicle doesn''t take this courier request.';
    end if;
    v_mine := public.driver_vehicle_service(v_uid);
    if v_mine is not null and v_mine = any (public.freight_service_ids())
       and public.service_order_allows(v_mine, r.service) then
      raise exception 'FREIGHT_GOODS_PERMIT_REQUIRED' using errcode = '42501',
        hint = 'This Freight size needs an approved goods-vehicle permit on your vehicle.';
    end if;
    raise exception 'FREIGHT_DRIVER_NO_FREIGHT' using errcode = '42501',
      hint = 'Your vehicle doesn''t take this Freight request.';
  end if;
  v_paused := public.driver_offers_paused_until(v_uid);
  if v_paused is not null then
    raise exception 'OFFERS_PAUSED' using errcode = 'P0001',
      hint = 'You cancelled too many rides this week. You can send offers again at '
             || to_char(v_paused at time zone coalesce(r.timezone, 'Asia/Kuala_Lumpur'), 'HH24:MI') || '.';
  end if;
  if v_amount < round(coalesce(r.ride_fare, r.fare, 0), 2) or v_amount > round(coalesce(r.ride_fare, r.fare, 0) * 4, 2)
     or v_amount <= 0 then
    raise exception 'OFFER_AMOUNT' using errcode = '22023',
      hint = 'Offer the rider''s fare or more, up to 4 times it.';
  end if;
  select count(*) into v_declines from public.ride_offers x
   where x.request_id = p_request and x.partner_id = v_uid and x.status = 'declined';
  if v_declines > (case when (c->>'reofferAfterDecline')::boolean then 1 else 0 end) then
    raise exception 'OFFER_DECLINED' using errcode = 'P0001', hint = 'The rider declined your offer.';
  end if;
  if public.auth_rate_take('ride_offer', p_request::text || ':' || v_uid::text, 10, interval '1 hour') > 0 then
    raise exception 'too_many' using errcode = 'P0001';
  end if;

  -- Their earlier open offer gives way to this one.
  update public.ride_offers set status = 'withdrawn', closed_reason = 'replaced', closed_at = now()
   where request_id = p_request and partner_id = v_uid and status = 'open';

  select * into card from public.ride_partner_card(v_uid);
  insert into public.ride_offers (request_id, partner_id, amount, eta_min, from_lat, from_lng, partner_name,
                                  partner_photo, partner_rating, partner_trips, partner_vehicle, partner_plate,
                                  expires_at)
  values (p_request, v_uid, v_amount, case when p_eta_min between 0 and 240 then p_eta_min end, p_lat, p_lng,
          card.name, card.photo, card.rating, card.trips, card.vehicle, card.plate,
          clock_timestamp() + make_interval(secs => (c->>'lifetimeSeconds')::int))
  returning * into o;

  perform public.ride_offers_mirror(p_request);
  -- The vehicle session's plate and car, and their colours (0254, 0260),
  -- as stamped on the row by its own triggers.
  update public.ride_offers x
     set partner_plate = coalesce(q.partner_plate, x.partner_plate),
         partner_vehicle = coalesce(q.partner_vehicle, x.partner_vehicle),
         partner_plate_colours = q.partner_plate_colours
    from public.ride_requests q
   where x.id = o.id and q.id = p_request and q.partner_id = v_uid
  returning x.* into o;
  select * into o from public.ride_offers where id = o.id;
  return to_jsonb(o);
end;
$$
  $fn$;
  execute $fn$revoke execute on function public.ride_offer_make(uuid, numeric, int, double precision, double precision)
  from public, anon$fn$;
  execute $fn$grant execute on function public.ride_offer_make(uuid, numeric, int, double precision, double precision)
  to authenticated$fn$;
end
$do$;

-- ---- 8. The trip ---------------------------------------------------------------------------------------------
-- As 0267, a courier trip reads its own place values (courier-...) and ends
-- only once the courier entered the recipient's code.
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
    if new.status = 'completed' and old.status is distinct from 'completed' and old.parcel_size is not null
       and new.delivery_code_ok_at is null then
      raise exception 'COURIER_CODE_REQUIRED' using errcode = '42501',
        hint = 'Enter the recipient''s confirmation code first.';
    end if;
  end if;
  if new.status = 'on_trip' and old.status is distinct from 'on_trip' and old.arrived_at is not null then
    v_charges := public.freight_charges_at(old);
    v_minutes := greatest(0, floor(extract(epoch from (now() - old.arrived_at)) / 60))::integer;
    v_fee := round(greatest(0, v_minutes - public.freight_place_value(v_charges, public.delivery_place_key(old, 'wait-free-min')))
                   * public.freight_place_value(v_charges, public.delivery_place_key(old, 'wait-per-min')), 2);
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
    v_fee := public.freight_place_value(public.freight_charges_at(old), public.delivery_place_key(old, 'cancel-arrived'));
    if v_fee > 0 then
      new.freight_cancel_fee := round(v_fee, 2);
      new.freight_cancel_fee_status := 'due';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_freight_trip() from public, anon, authenticated;

-- The courier's code at drop-off: the ride's driver, on the trip; the
-- server checks it (5 tries per 10 minutes per trip) and stamps the ride.
-- Answers 'ok', 'wrong_code' or 'rate_limited:<seconds>'.
create or replace function public.courier_code_check(p_request uuid, p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_code text;
  v_wait integer;
begin
  if auth.uid() is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.partner_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.delivery_code_ok_at is not null then
    return 'ok';  -- already confirmed (a retry after a dropped reply)
  end if;
  if r.status <> 'on_trip' then
    raise exception 'wrong_status:%', r.status;
  end if;
  select c.code into v_code from public.ride_delivery_codes c where c.request_id = p_request;
  if v_code is not null then
    -- Answered, not raised: an exception would roll back the try counted.
    v_wait := public.auth_rate_take('delivery_code', p_request::text, 5, interval '10 minutes');
    if v_wait > 0 then
      return 'rate_limited:' || v_wait;
    end if;
    if coalesce(btrim(p_code), '') <> v_code then
      return 'wrong_code';
    end if;
  end if;
  perform set_config('getride.courier_code_ok', '1', true);
  update public.ride_requests set delivery_code_ok_at = now() where id = p_request;
  perform set_config('getride.courier_code_ok', '', true);
  return 'ok';
end;
$$;
revoke execute on function public.courier_code_check(uuid, text) from public, anon;
grant execute on function public.courier_code_check(uuid, text) to authenticated;

-- The code for the sender to pass on (header: 3): the ride's rider, when
-- the Courier settings show it to the sender, send it nowhere else, or
-- every message to the recipient failed; admins always. Null otherwise.
create or replace function public.courier_delivery_code(p_ride uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_channels jsonb := public.courier_config()->'codeChannels';
begin
  select * into r from public.ride_requests where id = p_ride;
  if not found or auth.uid() is null or r.parcel_size is null then
    return null;
  end if;
  if not (public.caller_is_admin()
          or (r.rider_id = auth.uid()
              and (v_channels ? 'sender'
                   or not (v_channels ? 'sms' or v_channels ? 'whatsapp')
                   or (exists (select 1 from public.freight_recipient_notices n where n.ride_id = p_ride)
                       and not exists (select 1 from public.freight_recipient_notices n
                                        where n.ride_id = p_ride
                                          and (n.status in ('queued', 'sending', 'sent')
                                               or (n.status = 'failed' and n.attempts < 3))))))) then
    return null;
  end if;
  return (select c.code from public.ride_delivery_codes c where c.request_id = p_ride);
end;
$$;
revoke execute on function public.courier_delivery_code(uuid) from public, anon;
grant execute on function public.courier_delivery_code(uuid) to authenticated;

-- As 0267, a courier's cancel after pickup waits the Courier settings'
-- minutes, a freight one the Freight settings'.
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
     and cancel_requested_at < now() - make_interval(mins => case
           when parcel_size is not null then (public.courier_config()->>'cancelApproveMinutes')::int
           else (public.freight_config()->>'cancelApproveMinutes')::int end);
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

-- ---- 9. The recipient's message ---------------------------------------------------------------------------------
-- A courier notice carries the code (added by freight-notify, never kept
-- in the row the driver reads).
alter table public.freight_recipient_notices add column if not exists with_code boolean not null default false;

-- As 0267; a courier trip goes by the Courier settings' message channels,
-- says what the recipient pays, and asks for the code.
create or replace function public.ride_requests_freight_recipient()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c text;
  v_body text;
  v_channels jsonb;
  v_courier boolean := new.parcel_size is not null;
begin
  if new.cargo_description is null or new.recipient_phone is null
     or new.status <> 'on_trip' or old.status = 'on_trip' then
    return new;
  end if;
  -- The share link is kept aside (0195), as ride_share_link keeps it.
  insert into public.ride_request_private as p (request_id, share_token)
  values (new.id, gen_random_uuid())
  on conflict (request_id) do update set share_token = coalesce(p.share_token, excluded.share_token), updated_at = now();
  if v_courier then
    v_channels := public.courier_config()->'codeChannels';
    v_body := left(format('GET.ride: %s, a parcel from %s is on its way to you.%s Track it here: ',
                          coalesce(nullif(btrim(new.recipient_name), ''), 'Hello'),
                          coalesce(nullif(btrim(new.rider_name), ''), 'the sender'),
                          case when new.payer = 'recipient'
                               then format(' Please pay the courier %s %s in cash.', coalesce(new.currency, 'RM'),
                                           to_char(coalesce(new.fare, 0), 'FM999990.00'))
                               else '' end), 400);
  else
    v_channels := public.freight_config()->'recipientChannels';
    v_body := left(format('GET.ride: %s, your delivery from %s is on its way. Track it here: ',
                          coalesce(nullif(btrim(new.recipient_name), ''), 'Hello'),
                          coalesce(nullif(btrim(new.rider_name), ''), 'the sender')), 400);
  end if;
  for c in select x from jsonb_array_elements_text(v_channels) x where x in ('sms', 'whatsapp') loop
    insert into public.freight_recipient_notices (ride_id, channel, to_phone, body, with_code)
    values (new.id, c, new.recipient_phone, v_body, v_courier)
    on conflict (ride_id, channel) do nothing;
  end loop;
  return new;
end;
$$;
revoke execute on function public.ride_requests_freight_recipient() from public, anon, authenticated;

-- As 0267, with the code a courier notice asks for.
drop function if exists public.freight_notices_claim(uuid);
create function public.freight_notices_claim(p_ride uuid default null)
returns table (id uuid, channel text, to_phone text, body text, share_token uuid, delivery_code text)
language sql
security definer
set search_path = public
as $$
  update public.freight_recipient_notices n
     set status = 'sending', attempts = n.attempts + 1
   where (p_ride is null or n.ride_id = p_ride)
     and (n.status = 'queued' or (n.status = 'failed' and n.attempts < 3))
  returning n.id, n.channel, n.to_phone, n.body,
            (select v.share_token from public.ride_request_private v where v.request_id = n.ride_id),
            case when n.with_code then (select d.code from public.ride_delivery_codes d where d.request_id = n.ride_id) end;
$$;
revoke execute on function public.freight_notices_claim(uuid) from public, anon, authenticated;
grant execute on function public.freight_notices_claim(uuid) to service_role;

-- ---- 10. Fees: courier is exempt from the city fees, as freight -------------------------------------------------
-- As 0271, a courier request counts too.
create or replace function public.ride_request_is_freight(r public.ride_requests)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select r.cargo_description is not null or r.parcel_size is not null
      or coalesce(public.vehicle_service_is_freight(r.service), false)
      or coalesce(public.vehicle_service_is_courier(r.service), false);
$$;
revoke execute on function public.ride_request_is_freight(public.ride_requests) from public, anon, authenticated;
grant execute on function public.ride_request_is_freight(public.ride_requests) to service_role;

-- As 0271; the fee after the driver arrived is the courier one on a courier
-- request ('courier': true says which).
do $do$
begin
  -- 0269's cancel terms: as ride_offer_make above.
  if to_regclass('public.ride_offers') is null then
    return;
  end if;
  execute $fn$
create or replace function public.ride_cancel_terms(p_ride uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  r public.ride_requests;
  v jsonb;
  v_freight boolean;
begin
  select * into r from public.ride_requests where id = p_ride;
  if not found or auth.uid() is null or auth.uid() not in (r.rider_id, r.partner_id) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  v := public.ride_cancel_rules_for(r);
  v_freight := public.ride_request_is_freight(r);
  if v_freight then
    v := v || jsonb_build_object('freeMinutes', 0, 'lateFee', 0, 'arrivedFee', 0, 'noShowFee', 0);
  end if;
  return v || jsonb_build_object(
    'currency', r.currency,
    'freeUntil', r.accepted_at + make_interval(secs => (v->>'freeMinutes')::numeric * 60),
    'noShowAt', r.arrived_at + make_interval(secs => (v->>'noShowMinutes')::numeric * 60),
    'scheduled', r.scheduled_ride_id is not null,
    'freight', v_freight,
    'courier', r.parcel_size is not null,
    -- What 0267's trip trigger bills (a request with cargo) when the sender
    -- cancels after the driver arrived.
    'freightArrivedFee', case when v_freight and r.cargo_description is not null
                              then public.freight_place_value(public.freight_charges_at(r),
                                                              public.delivery_place_key(r, 'cancel-arrived'))
                              else 0 end);
end;
$$
  $fn$;
  execute $fn$revoke execute on function public.ride_cancel_terms(uuid) from public, anon$fn$;
  execute $fn$grant execute on function public.ride_cancel_terms(uuid) to authenticated$fn$;
end
$do$;

notify pgrst, 'reload schema';
