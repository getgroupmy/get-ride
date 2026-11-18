-- ============================================================================
-- 0422: one push call per ring, not one per driver
--
-- ride_request_push_nearby (0253) -- every ring of the dispatch ladder
-- (0417), the legacy min/max push and the favourites fallback -- told the
-- drivers it found one at a time: for each driver a row in
-- ride_request_pushes, two Vault reads and one queued HTTP call to send-push,
-- which then started, read that one driver's phones and sent. A ring of 40
-- drivers was 40 calls.
--
-- Now the drivers are picked by exactly the same rules, their rows are
-- written in one statement (the same once-per-request rule: with p_once a
-- driver already told is not told again), and ONE call to send-push carries
-- them all in `profileIds` (up to 1,000 a call; more go in further calls).
-- Same drivers, same message, same return value (how many were told).
--
-- send-push learned `profileIds` in the same change and must be deployed
-- first. Should an older send-push get a batch, it reads only `profileId`,
-- which carries the batch's first driver: one driver told, never everyone.
-- ============================================================================

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
  v_service text;
  v_keys text[];
  v_enforced boolean := public.service_order_enforced();
  v_ids uuid[];
  v_batch uuid[];
  i int;
begin
  select r.service, public.ride_extra_keys(r.pets, r.assistance, r.option_names, r.passengers)
    into v_service, v_keys
    from public.ride_requests r where r.id = p_request;

  -- The drivers to tell: as 0253 picked them, each recorded once per request.
  with picked as (
    select d.d
      from public.nearby_online_drivers(p_lat, p_lng, p_radius_km) as d(d)
     where d.d is distinct from p_rider
       and (not v_enforced
            or public.service_order_allows(public.driver_vehicle_service(d.d), v_service))
       and public.driver_takes_extras(d.d, v_keys)
  ),
  recorded as (
    insert into public.ride_request_pushes (request_id, profile_id, kind)
    select p_request, picked.d, p_kind from picked
    on conflict (request_id, profile_id) where profile_id is not null do nothing
    returning profile_id
  )
  select coalesce(array_agg(picked.d), '{}')
    into v_ids
    from picked
   where not p_once or picked.d in (select profile_id from recorded);

  -- One call per thousand drivers (send-push's MAX_TARGETS).
  i := 1;
  while i <= coalesce(cardinality(v_ids), 0) loop
    v_batch := v_ids[i : i + 999];
    perform public.send_push_webhook(p_message || jsonb_build_object(
      'profileId', v_batch[1],
      'profileIds', to_jsonb(v_batch)));
    i := i + 1000;
  end loop;

  return coalesce(cardinality(v_ids), 0);
end;
$$;

revoke execute on function public.ride_request_push_nearby(uuid, uuid, double precision, double precision, double precision, jsonb, text, boolean)
  from public, anon, authenticated;
