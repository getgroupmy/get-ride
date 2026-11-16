-- ============================================================================
-- Staged dispatch ladder, per service AND per region (migration 0417)
--
-- Until now an open ride request was pushed to online drivers in two rings:
-- the vehicle service's MIN search radius first, then its MAX after
-- searchWidenAfterSec, then everybody (migration 0160). This generalises that
-- into an N-step ladder an operator sets per service type AND per region,
-- scoped exactly like a commission rate (Country / State / City / Suburb, plus
-- one master default), resolved narrowest-first:
--
--     Step 1: 2 km           (hold 5 s)
--     Step 2: 5 km           (hold 5 s)
--     Step 3: 10 km          (hold 5 s)
--     then everybody         (offer_everyone)
--
-- The ladder is resolved once per request from the pickup point and FROZEN
-- onto the row (dispatch_ladder, dispatch_opened_at) so BOTH halves read the
-- same thing: the server walks it to decide who gets a PUSH at each step, and
-- the partner app reads it to decide when the offer may appear ON SCREEN -- the
-- two widen together. When no rule matches, the row falls back to the legacy
-- per-service min/max/widen config, so existing behaviour is unchanged and the
-- feature is purely additive. A fully additive migration: older app builds that
-- don't read the new columns keep seeing every open request as before.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- The rule table: a row is one service (or NULL = every service) in one region.
-- ----------------------------------------------------------------------------
create table if not exists public.dispatch_ladder_rules (
  id             uuid primary key default gen_random_uuid(),
  level          text not null check (level in ('master', 'country', 'state', 'city', 'suburb')),
  country        text check (country is null or char_length(btrim(country)) between 1 and 120),
  state          text check (state is null or char_length(btrim(state)) between 1 and 120),
  city           text check (city is null or char_length(btrim(city)) between 1 and 120),
  suburb         text check (suburb is null or char_length(btrim(suburb)) between 1 and 120),
  service        text check (service is null or char_length(btrim(service)) between 1 and 120),
  -- Ordered rings: [{ "radius_km": <0-200>, "hold_sec": <0-3600> }, ...]. The
  -- first ring is pushed at once; each hold_sec is how long to wait at that
  -- ring before the next is pushed.
  steps          jsonb not null,
  -- After the last ring's hold, push everybody (audience 'partners').
  offer_everyone boolean not null default true,
  active         boolean not null default true,
  priority       integer not null default 0,
  note           text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint dispatch_ladder_names check (
    (level = 'master' and country is null and state is null and city is null and suburb is null)
    or (level = 'country' and country is not null and state is null and city is null and suburb is null)
    or (level = 'state' and country is not null and state is not null and city is null and suburb is null)
    or (level = 'city' and country is not null and state is not null and city is not null and suburb is null)
    or (level = 'suburb' and country is not null and state is not null and city is not null and suburb is not null))
);

comment on table public.dispatch_ladder_rules is
  'Staged dispatch ladder (0417): per service type and Country/State/City/Suburb (+ master), an '
  'ordered list of {radius_km, hold_sec} rings plus offer_everyone. Resolved narrowest-first with a '
  'service-specific row beating an all-service one; falls back to the vehicle service min/max/widen config.';

-- Whether a steps array is well formed (1-8 rings, each a positive radius <=200
-- km and a whole hold of 0-3600 s). Immutable so a CHECK can call it.
create or replace function public.dispatch_ladder_steps_ok(p_steps jsonb)
returns boolean
language sql
immutable
as $$
  select jsonb_typeof(p_steps) = 'array'
     and jsonb_array_length(p_steps) between 1 and 8
     and not exists (
       select 1 from jsonb_array_elements(p_steps) e
        where not (
          jsonb_typeof(e->'radius_km') = 'number'
          and (e->>'radius_km')::numeric > 0 and (e->>'radius_km')::numeric <= 200
          and jsonb_typeof(e->'hold_sec') = 'number'
          and (e->>'hold_sec')::numeric >= 0 and (e->>'hold_sec')::numeric <= 3600
          and (e->>'hold_sec')::numeric = floor((e->>'hold_sec')::numeric)
        )
     );
$$;

alter table public.dispatch_ladder_rules
  drop constraint if exists dispatch_ladder_steps_shape;
alter table public.dispatch_ladder_rules
  add constraint dispatch_ladder_steps_shape check (public.dispatch_ladder_steps_ok(steps));

drop trigger if exists trg_dispatch_ladder_updated_at on public.dispatch_ladder_rules;
create trigger trg_dispatch_ladder_updated_at before update on public.dispatch_ladder_rules
  for each row execute function public.set_updated_at();

-- Page-scoped edit check (migration 0223 convention): a sub-admin writes this
-- table only with edit on its page (or the Settings hub). Not caller_is_admin().
create or replace function public.dispatch_ladder_caller_can_edit()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and (public.admin_can_edit(auth.uid(), 'admin-settings-dispatch-ladder')
          or public.admin_can_edit(auth.uid(), 'admin-settings'));
$$;

revoke execute on function public.dispatch_ladder_caller_can_edit() from public, anon;
grant execute on function public.dispatch_ladder_caller_can_edit() to authenticated;

alter table public.dispatch_ladder_rules enable row level security;
revoke all on public.dispatch_ladder_rules from anon;
grant select, insert, update, delete on public.dispatch_ladder_rules to authenticated;

drop policy if exists "dispatch_ladder read" on public.dispatch_ladder_rules;
drop policy if exists "dispatch_ladder admin insert" on public.dispatch_ladder_rules;
drop policy if exists "dispatch_ladder admin update" on public.dispatch_ladder_rules;
drop policy if exists "dispatch_ladder admin delete" on public.dispatch_ladder_rules;

-- Every signed-in partner reads the rules (the on-screen gate runs on the
-- device from the stamped ladder; the rules themselves back the admin editor).
create policy "dispatch_ladder read"
  on public.dispatch_ladder_rules for select to authenticated
  using (true);
create policy "dispatch_ladder admin insert"
  on public.dispatch_ladder_rules for insert to authenticated
  with check ((select public.dispatch_ladder_caller_can_edit()));
create policy "dispatch_ladder admin update"
  on public.dispatch_ladder_rules for update to authenticated
  using ((select public.dispatch_ladder_caller_can_edit()))
  with check ((select public.dispatch_ladder_caller_can_edit()));
create policy "dispatch_ladder admin delete"
  on public.dispatch_ladder_rules for delete to authenticated
  using ((select public.dispatch_ladder_caller_can_edit()));

-- Live: the admin editor refetches the moment a rule is saved.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'dispatch_ladder_rules'
  ) then
    alter publication supabase_realtime add table public.dispatch_ladder_rules;
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- Expand stored rings into the runtime ladder the server and app both read:
-- an ordered array of { after_sec, radius_km } where after_sec is seconds from
-- the moment the request opened to all, and radius_km NULL means "everybody".
-- Pure; tested in supabase/tests/dispatch_ladder_0417.sql.
-- ----------------------------------------------------------------------------
create or replace function public.dispatch_ladder_expand(p_steps jsonb, p_offer_everyone boolean)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_out jsonb := '[]'::jsonb;
  v_acc int := 0;
  e     jsonb;
  v_r   numeric;
  v_h   int;
begin
  if jsonb_typeof(p_steps) <> 'array' or jsonb_array_length(p_steps) = 0 then
    return '[]'::jsonb;
  end if;
  for e in select value from jsonb_array_elements(p_steps) loop
    v_r := case when jsonb_typeof(e->'radius_km') = 'number' then (e->>'radius_km')::numeric end;
    v_h := coalesce(case when jsonb_typeof(e->'hold_sec') = 'number' then (e->>'hold_sec')::int end, 0);
    v_out := v_out || jsonb_build_array(jsonb_build_object('after_sec', v_acc, 'radius_km', v_r));
    v_acc := v_acc + greatest(v_h, 0);
  end loop;
  if coalesce(p_offer_everyone, false) then
    v_out := v_out || jsonb_build_array(jsonb_build_object('after_sec', v_acc, 'radius_km', null));
  end if;
  return v_out;
end;
$$;

revoke execute on function public.dispatch_ladder_expand(jsonb, boolean) from public, anon;
grant execute on function public.dispatch_ladder_expand(jsonb, boolean) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- Resolver (region already named): the expanded ladder for [p_service] in the
-- given region. A service-specific row beats an all-service one at the same
-- level; the narrowest region wins; when nothing matches it falls back to the
-- vehicle service's legacy min/max/widen config (so behaviour is unchanged).
-- The coordinate wrapper below names the region from the pickup point.
-- ----------------------------------------------------------------------------
create or replace function public.dispatch_ladder_at(
  p_service text,
  p_country text,
  p_state text,
  p_city text,
  p_suburb text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_service text := nullif(btrim(p_service), '');
  v_country text := nullif(btrim(p_country), '');
  v_state   text := nullif(btrim(p_state), '');
  v_city    text := nullif(btrim(p_city), '');
  v_suburb  text := nullif(btrim(p_suburb), '');
  v_steps   jsonb;
  v_every   boolean;
  cfg       jsonb;
begin
  select d.steps, d.offer_everyone into v_steps, v_every
    from public.dispatch_ladder_rules d
   where d.active
     and (d.service is null or lower(btrim(d.service)) = lower(coalesce(v_service, '')))
     and case d.level
       when 'suburb' then public.commission_place_matches(d.suburb, v_suburb)
         and public.commission_parent_ok(d.city, v_city)
         and public.commission_parent_ok(d.state, v_state)
         and public.commission_parent_ok(d.country, v_country)
       when 'city' then public.commission_place_matches(d.city, v_city)
         and public.commission_parent_ok(d.state, v_state)
         and public.commission_parent_ok(d.country, v_country)
       when 'state' then public.commission_place_matches(d.state, v_state)
         and public.commission_parent_ok(d.country, v_country)
       when 'country' then public.commission_place_matches(d.country, v_country)
       when 'master' then true
       else false
     end
   order by
     case d.level
       when 'suburb' then 5 when 'city' then 4 when 'state' then 3 when 'country' then 2 else 1
     end desc,
     (d.service is not null)::int desc,            -- a service-specific row wins
     d.priority desc,
     (d.country is not null)::int + (d.state is not null)::int + (d.city is not null)::int desc,
     d.updated_at desc nulls last,
     d.id
   limit 1;

  if found then
    return public.dispatch_ladder_expand(v_steps, v_every);
  end if;

  -- No ladder configured here: the legacy per-service two-ring behaviour as a
  -- ladder -- min, then max after widenAfter, then everybody.
  cfg := public.vehicle_service_dispatch_config(v_service);
  return public.dispatch_ladder_expand(
    jsonb_build_array(
      jsonb_build_object('radius_km', (cfg->>'search_radius_min_km')::numeric, 'hold_sec', (cfg->>'widen_after_sec')::int),
      jsonb_build_object('radius_km', (cfg->>'search_radius_max_km')::numeric, 'hold_sec', (cfg->>'widen_after_sec')::int)),
    true);
end;
$$;

revoke execute on function public.dispatch_ladder_at(text, text, text, text, text) from public, anon;
grant execute on function public.dispatch_ladder_at(text, text, text, text, text) to authenticated, service_role;

-- Coordinate wrapper: name the region from the pickup point (narrowest-first,
-- like commission_resolve) where the admin mapped outlines, then resolve.
create or replace function public.dispatch_ladder_for(
  p_service text,
  p_lat double precision,
  p_lng double precision
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_country text;
  v_state   text;
  v_city    text;
  v_suburb  text;
  g         record;
begin
  if p_lat is not null and p_lng is not null then
    for g in
      select distinct on (a.region_table) a.region_table, a.country, a.state, a.city, a.suburb
        from public.regions_at(p_lat, p_lng) a
       where a.inside
       order by a.region_table, a.area asc nulls last
    loop
      case g.region_table
        when 'countries' then v_country := g.country;
        when 'states' then v_state := g.state; v_country := coalesce(nullif(g.country, ''), v_country);
        when 'cities' then v_city := g.city; v_state := coalesce(nullif(g.state, ''), v_state);
        when 'suburbs' then v_suburb := g.suburb; v_city := coalesce(nullif(g.city, ''), v_city);
        else null;
      end case;
    end loop;
  end if;
  return public.dispatch_ladder_at(p_service, v_country, v_state, v_city, v_suburb);
end;
$$;

revoke execute on function public.dispatch_ladder_for(text, double precision, double precision) from public, anon;
grant execute on function public.dispatch_ladder_for(text, double precision, double precision) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- The request carries its resolved ladder, frozen once, so the push path and
-- the on-screen gate read the same steps and the same clock.
--   dispatch_ladder     the expanded ladder (array of {after_sec, radius_km})
--   dispatch_opened_at  when step timing starts (insert, or the end of the
--                       favourites window for a My Ride request)
--   dispatch_step       how many rings have been pushed
-- ----------------------------------------------------------------------------
alter table public.ride_requests add column if not exists dispatch_ladder    jsonb;
alter table public.ride_requests add column if not exists dispatch_opened_at timestamptz;
alter table public.ride_requests add column if not exists dispatch_step       smallint not null default 0;

-- The highest radius a ladder has reached by [p_elapsed_sec] seconds: a
-- positive km, -1 for "everybody" (a null-radius ring reached), or NULL when no
-- ring is due yet. Pure; tested.
create or replace function public.dispatch_ladder_reached_km(p_ladder jsonb, p_elapsed_sec double precision)
returns double precision
language plpgsql
immutable
as $$
declare
  e        jsonb;
  v_reach  double precision;   -- NULL = nothing due yet
  v_every  boolean := false;
begin
  if jsonb_typeof(p_ladder) <> 'array' then return null; end if;
  for e in select value from jsonb_array_elements(p_ladder) loop
    if (e->>'after_sec')::double precision <= coalesce(p_elapsed_sec, 0) then
      if e->>'radius_km' is null then
        v_every := true;
      else
        v_reach := greatest(coalesce(v_reach, 0), (e->>'radius_km')::double precision);
      end if;
    end if;
  end loop;
  if v_every then return -1; end if;
  return v_reach;
end;
$$;

revoke execute on function public.dispatch_ladder_reached_km(jsonb, double precision) from public, anon;
grant execute on function public.dispatch_ladder_reached_km(jsonb, double precision) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- Walk the ladder for one open request: push every ring now due (and, while
-- nobody has been reached yet, keep widening past the clock so an empty inner
-- ring never strands a request), advancing dispatch_step. Resolves and freezes
-- the ladder if the row has none yet. Returns how many rings it pushed, or -1
-- when there was nothing to do (still inside the favourites window, or done).
-- ----------------------------------------------------------------------------
create or replace function public.ride_request_dispatch_advance(p_request uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r         public.ride_requests;
  v_ladder  jsonb;
  v_opened  timestamptz;
  v_elapsed double precision;
  v_n       int;
  v_msg     jsonb;
  v_any     boolean;
  v_pushed  int := 0;
  v_told    int;
  i         int;
  v_radius  text;
  v_due     boolean;
begin
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.status <> 'open' then
    return -1;
  end if;
  -- Still inside the favourites window: open_to_all handles its end.
  if r.targeted_until is not null and r.targeted_until > now() and r.fallback_pushed_at is null then
    return -1;
  end if;

  v_ladder := r.dispatch_ladder;
  v_opened := r.dispatch_opened_at;
  if v_ladder is null then
    v_opened := coalesce(r.fallback_pushed_at, r.dispatch_opened_at, r.created_at, now());
    v_ladder := public.dispatch_ladder_for(r.service, r.pickup_lat, r.pickup_lng);
    update public.ride_requests
       set dispatch_ladder = v_ladder, dispatch_opened_at = v_opened
     where id = p_request;
  end if;

  v_n := jsonb_array_length(coalesce(v_ladder, '[]'::jsonb));
  if r.dispatch_step >= v_n then
    return -1;
  end if;

  v_elapsed := extract(epoch from (now() - coalesce(v_opened, now())));
  v_msg := public.ride_request_push_message(r.id, r.pickup_name, r.pickup_address, r.fare, r.currency, 'new');
  v_any := exists (select 1 from public.ride_request_pushes
                    where request_id = p_request and coalesce(kind, '') <> 'my_ride');

  i := r.dispatch_step;      -- 0-based index of the next unpushed ring
  while i < v_n loop
    v_due := (v_ladder->i->>'after_sec')::double precision <= v_elapsed;
    -- A future ring, and somebody is already in play: wait for its clock.
    exit when (not v_due) and v_any;

    v_radius := v_ladder->i->>'radius_km';
    if v_radius is null then
      perform public.ride_request_push_everyone(r.id, v_msg, 'everyone');
      v_any := true;
    else
      v_told := public.ride_request_push_nearby(
        r.id, r.rider_id, r.pickup_lat, r.pickup_lng, v_radius::double precision, v_msg, 'ladder', true);
      if v_told > 0 then v_any := true; end if;
    end if;

    i := i + 1;
    v_pushed := v_pushed + 1;
    update public.ride_requests
       set dispatch_step = i,
           widened_pushed_at = case when i > 1 then coalesce(widened_pushed_at, now()) else widened_pushed_at end
     where id = p_request;

    -- A ring we pushed early (empty inner ring): stop once someone is reached.
    exit when (not v_due) and v_any;
  end loop;

  return v_pushed;
exception when others then
  -- A push failure must never wedge the request.
  return v_pushed;
end;
$$;

revoke execute on function public.ride_request_dispatch_advance(uuid) from public, anon, authenticated;
grant execute on function public.ride_request_dispatch_advance(uuid) to service_role;

-- ----------------------------------------------------------------------------
-- Insert / fare-raise push, now ladder-driven. A brand-new open-to-all request
-- walks its (already stamped) ladder; a fare raise re-pings whoever the ladder
-- has reached so far; the favourites window is unchanged.
-- ----------------------------------------------------------------------------
create or replace function public.notify_partners_on_ride_request()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_raised  boolean := tg_op = 'UPDATE';
  v_msg     jsonb;
  v_driver  uuid;
  v_reach   double precision;
  v_elapsed double precision;
begin
  if new.status is distinct from 'open' then
    return new;
  end if;
  -- Held for the airport's waiting drivers (0249).
  if new.airport_hold then
    return new;
  end if;
  -- A stand order goes to the drivers it is offered to (dispatch_push, 0251).
  if new.stand_id is not null and new.dispatch_mode is distinct from 'nearby' then
    return new;
  end if;

  -- On UPDATE, only when the passenger raised their fare on the open row.
  if tg_op = 'UPDATE'
     and not (new.fare is distinct from old.fare
              and coalesce(new.fare, 0) > coalesce(old.fare, 0)) then
    return new;
  end if;

  -- Inside the favourites / direct window: the targeted drivers, wherever they are.
  if public.ride_request_targeting(new.target_driver_ids, new.targeted_until) then
    v_msg := public.ride_request_push_message(new.id, new.pickup_name, new.pickup_address, new.fare, new.currency,
                                              case when v_raised then 'raised'
                                                   when new.direct_driver_id is not null then 'direct'
                                                   else 'my_ride' end);
    if v_raised then
      foreach v_driver in array new.target_driver_ids loop
        continue when v_driver = new.rider_id;
        perform public.send_push_webhook(v_msg || jsonb_build_object('profileId', v_driver));
      end loop;
    else
      perform public.ride_request_push_targets(new.id, new.target_driver_ids, v_msg);
    end if;
    return new;
  end if;

  -- Open to all.
  if not v_raised then
    -- Fresh request: walk the ladder frozen on the row by the insert trigger.
    perform public.ride_request_dispatch_advance(new.id);
    return new;
  end if;

  -- Fare raised: re-ping whoever the ladder has already reached.
  v_msg := public.ride_request_push_message(new.id, new.pickup_name, new.pickup_address, new.fare, new.currency, 'raised');
  v_elapsed := extract(epoch from (now() - coalesce(new.dispatch_opened_at, new.created_at)));
  v_reach := public.dispatch_ladder_reached_km(new.dispatch_ladder, v_elapsed);
  if v_reach = -1 or new.dispatch_ladder is null then
    perform public.ride_request_push_everyone(new.id, v_msg, 'raised');
  elsif v_reach is not null and v_reach > 0 then
    perform public.ride_request_push_nearby(new.id, new.rider_id, new.pickup_lat, new.pickup_lng,
                                            v_reach, v_msg, 'raised', false);
  end if;
  return new;
exception when others then
  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- Stamp the ladder onto an open-to-all request at insert, so the app has it on
-- the very first realtime event (My Ride requests get theirs when the window
-- ends, in ride_request_open_to_all). Extends ride_requests_my_ride_targets:
-- its My Ride targeting is unchanged; it now also freezes the ladder.
-- ----------------------------------------------------------------------------
create or replace function public.ride_requests_my_ride_targets()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg jsonb := public.vehicle_service_dispatch_config(new.service);
  v_rider_max double precision := case when new.my_ride_max_km > 0 then new.my_ride_max_km end;
  v_max double precision;
  v_targets uuid[];
  v_direct text := nullif(btrim(coalesce(new.direct_qr_token, '')), '');
  q public.personal_qr_codes;
  p public.partners;
begin
  new.targeted_until := null;
  new.fallback_pushed_at := null;
  new.widened_pushed_at := null;
  -- Server-set; the token itself is never stored.
  new.direct_qr_token := null;
  new.direct_driver_id := null;
  new.direct_qr_id := null;

  -- GET.now.
  if v_direct is not null then
    select * into q from public.personal_qr_codes where token = public.personal_qr_token_of(v_direct);
    if q.id is null or q.kind <> 'now' or public.personal_qr_status(q.expires_at, q.revoked_at) <> 'active' then
      raise exception 'QR_EXPIRED' using errcode = 'P0001',
        hint = 'This GET.now code has expired. Ask the driver for their current code.';
    end if;
    if new.rider_id is null or new.status is distinct from 'open' then
      raise exception 'QR_EXPIRED' using errcode = 'P0001',
        hint = 'A GET.now code books a new, open request only.';
    end if;
    if q.owner_id = new.rider_id then
      raise exception 'QR_SELF_BOOKING' using errcode = 'P0001',
        hint = 'You can''t book yourself with your own GET.now code.';
    end if;
    p := public.my_ride_partner_of(q.owner_id);
    if p.id is null or not public.partner_status_bookable(p.status::text)
       or exists (select 1 from public.favourite_drivers f
                   where f.rider_id = new.rider_id and f.driver_id = q.owner_id and f.hidden_by_driver) then
      raise exception 'QR_DRIVER_UNAVAILABLE' using errcode = 'P0001',
        hint = 'This driver can''t take rides right now.';
    end if;
    new.direct_driver_id := q.owner_id;
    new.direct_qr_id := q.id;
    new.target_driver_ids := array[q.owner_id];
    -- Longer than an open request lives (7 minutes, 0139) plus its cron's lag.
    new.targeted_until := now() + interval '10 minutes';
    new.my_ride_max_km := null;
    return new;
  end if;

  -- The smaller of the rider's and the service's caps (least() skips nulls).
  v_max := least(v_rider_max, (cfg->>'my_ride_max_km')::double precision);
  new.my_ride_max_km := v_max;

  if coalesce(cardinality(new.target_driver_ids), 0) > 0 and new.status = 'open' and new.rider_id is not null then
    v_targets := public.my_ride_valid_targets(new.rider_id, new.target_driver_ids, new.pickup_lat, new.pickup_lng, v_max);
  end if;
  if coalesce(cardinality(v_targets), 0) > 0 then
    new.target_driver_ids := v_targets;
    new.targeted_until := now() + make_interval(secs => (cfg->>'my_ride_window_sec')::int);
  else
    new.target_driver_ids := null;
  end if;

  -- Open to everybody from the start: where nobody is within the min
  -- radius, the insert push goes straight to the max radius.
  if new.status = 'open' and new.targeted_until is null
     and not exists (select 1 from public.nearby_online_drivers(new.pickup_lat, new.pickup_lng,
                                                                (cfg->>'search_radius_min_km')::double precision) d
                      where d is distinct from new.rider_id) then
    new.widened_pushed_at := now();
  end if;

  -- Freeze the ladder from the pickup point now, so the app has it on the first
  -- realtime event and the push path and the on-screen gate read the same steps
  -- (0417) -- but only for an ordinary nearby, open-to-all request: not a stand
  -- order dispatched its own way, not an airport-held one, not the targeted /
  -- direct window (those get theirs when the window ends, in
  -- ride_request_open_to_all). Resolution must never block the insert -- on any
  -- error the ladder is left for advance() to stamp.
  if new.status = 'open' and new.targeted_until is null
     and not coalesce(new.airport_hold, false)
     and (new.stand_id is null or new.dispatch_mode = 'nearby') then
    new.dispatch_opened_at := now();
    new.dispatch_step := 0;
    begin
      new.dispatch_ladder := public.dispatch_ladder_for(new.service, new.pickup_lat, new.pickup_lng);
    exception when others then
      new.dispatch_ladder := null;
    end;
  end if;
  return new;
end;
$$;

revoke execute on function public.ride_requests_my_ride_targets() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_c_my_ride on public.ride_requests;
create trigger trg_ride_requests_c_my_ride
  before insert on public.ride_requests
  for each row execute function public.ride_requests_my_ride_targets();

-- The guard protects the server's own columns from client writes; the three
-- dispatch columns join that set.
create or replace function public.ride_requests_my_ride_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;
  -- The server's columns.
  new.target_driver_ids := old.target_driver_ids;
  new.targeted_until := old.targeted_until;
  new.my_ride_max_km := old.my_ride_max_km;
  new.fallback_pushed_at := old.fallback_pushed_at;
  new.widened_pushed_at := old.widened_pushed_at;
  new.direct_qr_token := old.direct_qr_token;
  new.direct_driver_id := old.direct_driver_id;
  new.direct_qr_id := old.direct_qr_id;
  new.dispatch_ladder := old.dispatch_ladder;
  new.dispatch_opened_at := old.dispatch_opened_at;
  new.dispatch_step := old.dispatch_step;
  -- Inside the window, only the rider and the targeted drivers.
  if old.status = 'open'
     and public.ride_request_targeting(old.target_driver_ids, old.targeted_until)
     and auth.uid() is distinct from old.rider_id
     and not coalesce(auth.uid() = any(old.target_driver_ids), false) then
    raise exception 'RIDE_TARGETED_TO_FAVOURITES' using errcode = '42501',
      hint = 'This request is offered to the rider''s favourite drivers first.';
  end if;
  return new;
end;
$$;

revoke execute on function public.ride_requests_my_ride_guard() from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- The favourites window of [p_request] is over (or the rider ended it): open it
-- to everybody, freeze the ladder from here, and start walking it. Returns how
-- many rings were pushed (-1 when there was nothing to do).
-- ----------------------------------------------------------------------------
create or replace function public.ride_request_open_to_all(p_request uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_ladder jsonb;
begin
  select * into r from public.ride_requests where id = p_request for update;
  if not found or r.status <> 'open' or r.targeted_until is null or r.fallback_pushed_at is not null then
    return -1;
  end if;

  -- Resolve the ladder from the pickup point; a resolver error leaves it NULL
  -- for advance() to stamp lazily rather than wedging the window-end.
  begin
    v_ladder := public.dispatch_ladder_for(r.service, r.pickup_lat, r.pickup_lng);
  exception when others then
    v_ladder := null;
  end;

  update public.ride_requests
     set targeted_until = least(targeted_until, now()),
         fallback_pushed_at = now(),
         dispatch_ladder = v_ladder,
         dispatch_opened_at = now(),
         dispatch_step = 0
   where id = p_request;

  return public.ride_request_dispatch_advance(p_request);
end;
$$;

revoke execute on function public.ride_request_open_to_all(uuid) from public, anon, authenticated;

-- Kept for compatibility: widening is now one more turn of the ladder.
create or replace function public.ride_request_widen(p_request uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.ride_request_dispatch_advance(p_request);
end;
$$;

revoke execute on function public.ride_request_widen(uuid) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- The scheduled pass: end windows that lapsed, then advance every open-to-all
-- request whose ladder has rings still to push.
-- ----------------------------------------------------------------------------
create or replace function public.ride_requests_dispatch_tick()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  n int := 0;
begin
  for v_id in
    select id from public.ride_requests
     where status = 'open'
       and (stand_id is null or dispatch_mode = 'nearby')
       and created_at > now() - interval '15 minutes'
       and targeted_until is not null and targeted_until <= now()
       and fallback_pushed_at is null
       and direct_driver_id is null
       and not airport_hold
  loop
    if public.ride_request_open_to_all(v_id) >= 0 then
      n := n + 1;
    end if;
  end loop;

  for v_id in
    select id from public.ride_requests
     where status = 'open'
       and (stand_id is null or dispatch_mode = 'nearby')
       and created_at > now() - interval '15 minutes'
       and (targeted_until is null or fallback_pushed_at is not null)
       and direct_driver_id is null
       and not airport_hold
       and (dispatch_ladder is null or dispatch_step < jsonb_array_length(dispatch_ladder))
  loop
    if public.ride_request_dispatch_advance(v_id) >= 0 then
      n := n + 1;
    end if;
  end loop;

  delete from public.ride_request_pushes where at < now() - interval '1 day';
  return n;
end;
$$;

revoke execute on function public.ride_requests_dispatch_tick() from public, anon, authenticated;
grant execute on function public.ride_requests_dispatch_tick() to service_role;
