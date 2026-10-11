-- ============================================================================
-- 0145: a new request is pushed to the drivers near it, not to every driver
--
-- "New ride request" went to the whole partner audience, wherever they were
-- and whether or not they were taking rides: noise that teaches drivers to
-- ignore pushes. The server did not even know who was online — the Drive
-- tab's switch lived only on the phone.
--
--   * driver_presence: one row per driver, written by the app through
--     set_driver_presence when the switch moves and about once a minute
--     while it is on (online, last position, when);
--   * nearby_online_drivers: drivers online within a radius of a point,
--     seen in the last 3 minutes;
--   * notify_partners_on_ride_request: a new open request (or a raised
--     fare) is pushed to each nearby online driver. Where none is known —
--     no pickup position, or no driver reporting presence yet (an older
--     app build) — it goes to every driver as before, so a request is never
--     left unannounced.
-- ============================================================================

create table if not exists public.driver_presence (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  online     boolean not null default false,
  lat        double precision,
  lng        double precision,
  updated_at timestamptz not null default now()
);

create index if not exists driver_presence_online on public.driver_presence (updated_at) where online;

alter table public.driver_presence enable row level security;

drop policy if exists "driver_presence own or admin read" on public.driver_presence;
create policy "driver_presence own or admin read" on public.driver_presence
  for select using (profile_id = auth.uid() or public.caller_is_admin());
-- Written only through set_driver_presence.

-- How far a driver may be from a pickup to be told about it.
create or replace function public.ride_request_push_radius_km()
returns double precision
language sql
immutable
as $$ select 15::double precision $$;

create or replace function public.set_driver_presence(
  p_online boolean,
  p_lat double precision default null,
  p_lng double precision default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lat double precision := case when p_lat between -90 and 90 then p_lat end;
  v_lng double precision := case when p_lng between -180 and 180 then p_lng end;
begin
  if auth.uid() is null then
    raise exception 'not_authorized';
  end if;
  -- Only a driver has a presence.
  if not exists (select 1 from public.partners where auth_user_id = auth.uid()) then
    return;
  end if;
  insert into public.driver_presence (profile_id, online, lat, lng, updated_at)
  values (auth.uid(), coalesce(p_online, false), v_lat, v_lng, now())
  on conflict (profile_id) do update
    set online = excluded.online,
        -- A report without a fix keeps the last known position.
        lat = coalesce(excluded.lat, driver_presence.lat),
        lng = coalesce(excluded.lng, driver_presence.lng),
        updated_at = now();
end;
$$;

revoke execute on function public.set_driver_presence(boolean, double precision, double precision) from public, anon;
grant execute on function public.set_driver_presence(boolean, double precision, double precision) to authenticated;

-- Drivers online within [p_radius_km] of a point, seen in the last 3 minutes.
create or replace function public.nearby_online_drivers(
  p_lat double precision,
  p_lng double precision,
  p_radius_km double precision default null
)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select d.profile_id
    from public.driver_presence d
   where d.online
     and d.updated_at > now() - interval '3 minutes'
     and d.lat is not null and d.lng is not null
     and p_lat is not null and p_lng is not null
     and 2 * 6371 * asin(sqrt(
           power(sin(radians(d.lat - p_lat) / 2), 2)
           + cos(radians(p_lat)) * cos(radians(d.lat)) * power(sin(radians(d.lng - p_lng) / 2), 2)
         )) <= coalesce(p_radius_km, public.ride_request_push_radius_km());
$$;

revoke execute on function public.nearby_online_drivers(double precision, double precision, double precision)
  from public, anon, authenticated;

create or replace function public.notify_partners_on_ride_request()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_pickup text;
  v_fare   text;
  v_title  text;
  v_body   text;
  v_data   jsonb;
  v_driver uuid;
  v_told   int := 0;
begin
  -- Only ever notify about requests that are still open (biddable).
  if new.status is distinct from 'open' then
    return new;
  end if;

  -- On UPDATE, fire only when the passenger raised their fare on the open row.
  -- Skip every other open-row update so the partner queue isn't spammed.
  if tg_op = 'UPDATE'
     and not (new.fare is distinct from old.fare
              and coalesce(new.fare, 0) > coalesce(old.fare, 0)) then
    return new;
  end if;

  v_pickup := coalesce(nullif(new.pickup_name, ''), nullif(new.pickup_address, ''), 'a nearby location');
  v_fare   := case when new.fare is not null
                   then ' • ' || public.currency_symbol(new.currency) || ' ' || new.fare::text
                   else '' end;
  v_title  := case when tg_op = 'UPDATE' then 'Fare increased' else 'New ride request' end;
  v_body   := case when tg_op = 'UPDATE' then 'Higher fare — pickup at ' else 'Pickup at ' end
              || v_pickup || v_fare;
  v_data   := jsonb_build_object(
    'type', case when tg_op = 'UPDATE' then 'ride_request_fare_raised' else 'ride_request' end,
    'ride_request_id', new.id
  );

  -- The drivers near the pickup who are taking rides.
  for v_driver in select * from public.nearby_online_drivers(new.pickup_lat, new.pickup_lng, null) loop
    continue when v_driver = new.rider_id;
    perform public.send_push_webhook(jsonb_build_object(
      'title', v_title, 'body', v_body, 'profileId', v_driver, 'data', v_data));
    v_told := v_told + 1;
  end loop;

  -- Nobody known nearby: every driver, as before.
  if v_told = 0 then
    perform public.send_push_webhook(jsonb_build_object(
      'title', v_title, 'body', v_body, 'audience', 'partners', 'data', v_data));
  end if;

  return new;
exception when others then
  -- Never let a notification failure block the ride request write.
  return new;
end;
$$;

notify pgrst, 'reload schema';
