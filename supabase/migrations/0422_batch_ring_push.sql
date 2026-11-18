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
-- The final "everyone" step (ride_request_push_everyone) is already one call,
-- but first lists who to leave out, judging candidates one by one through
-- the partner-type and registration rules (~7 ms a partner). For a freight
-- or courier ride, or under a lock that is not one driver's, every partner
-- was judged: ~220 ms live with 33 partners, and growing with them. The push
-- goes to approved partners only (`approvedOnly`, as send-push reads it:
-- partners.status = 'approved'), so judging anyone else changed nothing:
-- now only approved partners are judged. Same skip list for everyone the
-- push can reach.
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

-- 0268's ride_request_push_everyone, judging approved partners only.
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
  -- The candidates, cut to those the push can reach (send-push's
  -- approvedOnly) BEFORE the per-partner rules run: materialized, so the
  -- planner cannot push those checks down into the union.
  with cand as materialized (
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
      and exists (select 1 from public.partners ap where ap.auth_user_id = c.d and ap.status::text = 'approved')
  )
  select coalesce(jsonb_agg(cand.d), '[]'::jsonb) into v_skip
    from cand
   where not (public.driver_takes_extras(cand.d, v_keys) and public.driver_takes_service(cand.d, v_service)
              and (not v_freight or public.driver_takes_freight(cand.d, v_service)));
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
