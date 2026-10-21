-- ============================================================================
-- 0263: Driver services -- the services a driver takes with each car, and the
-- locks get.ride keeps on them
--
-- The driver's Services page (side menu > Services) lists what the car they
-- are driving can do -- the Vehicle Services their partner type allows, its
-- service and permits fit -- with a switch for each, the two street hail
-- modes and the ride add-ons. Admin > Services & catalogue > Driver service
-- locks keeps a service on or off for some drivers.
--
--   * driver_service_prefs: per driver AND vehicle, the switches the driver
--     set (service_key, enabled). No row: on. The driver writes their own
--     rows, for a vehicle they may drive; admins read every row.
--   * driver_service_locks: get.ride keeps a service 'on' or 'off', for one
--     driver (scope 'driver'; "several drivers" is one row per driver with
--     the same batch_id), a partner type (ptr_key form), a fleet
--     (dispatch_groups, kind 'fleet', 0251), a region (country, and a state
--     and a city by name, as the Country / States / Cities tables name
--     them and the vehicle's registration region holds them,
--     ptr_vehicle_context) or everyone, optionally until a time. One lock
--     per target and service. Writes: caller_admin_can_write on the new
--     page admin-settings-driver-service-locks. Drivers read the locks that
--     apply to them; admins every one.
--   * driver_service_lock_events: who set, changed or removed each lock
--     (written by the server only; admins read it).
--
-- Service keys (driver_service_key):
--   * a Vehicle Service: its name in ptr_key form ('Ride' -> 'ride',
--     '6-seater' -> '6seater'), as ride_requests.service is compared;
--   * street hail: 'hail:meter' (the meter for a walk-up passenger) and
--     'hail:destination' (a street hail with the destination set first);
--   * a ride add-on: 'extra:' + the driver_ride_extras key (0253), e.g.
--     'extra:child-seat', 'extra:pet:dog'. The driver's own choice of add-ons
--     stays in driver_ride_extras (one list per driver); a lock applies on
--     top of it.
--
-- What is on for a driver with a vehicle (driver_service_effective): the
-- most specific active lock -- driver, then fleet, then region (city, state,
-- country), then partner type, then everyone; the latest of equals -- else
-- the driver's own switch for that vehicle, else on. A lock past its
-- `until` counts for nothing.
--
-- Enforcement, for the vehicle the driver is driving (vehicle_active_session):
--   * an open request whose service is off is not read by that driver
--     (restrictive policy; the rider, the driver on it, admins and the
--     stand's operators still read it, as 0257) -- the caller's off list is
--     worked out once per query, nothing is looked up per row;
--   * a bid or a take on such a request is refused (DRIVER_SERVICE_OFF);
--     a GET.now booking naming such a driver is refused
--     (DRIVER_SERVICE_OFF_DIRECT); My Ride favourites who have it off are
--     left out of the targets;
--   * the new-request, widening, everyone, stand group and airport pushes
--     and offers, and the scheduled rides list, skip those drivers;
--   * add-on locks reach every place the 0253 extras do (driver_extras_off);
--   * street hail: the meter and a hail trip run on the phone and reach the
--     server only when finished (meter_trips, 0219), so the app refuses to
--     start them while off.
-- The guide dog stays an add-on the driver may turn off, as 0253 has it.
-- ============================================================================

-- ---- 1. Keys ------------------------------------------------------------------------------------
-- A service key as stored: 'extra:' / 'hail:' keys in lower case, a
-- Vehicle Service name in ptr_key form.
create or replace function public.driver_service_key(p text)
returns text
language sql
immutable
set search_path to ''
as $$
  select case when lower(btrim(coalesce(p, ''))) ~ '^(extra|hail):'
              then lower(btrim(p))
              else public.ptr_key(p) end;
$$;

-- ---- 2. The driver's switches, per vehicle -------------------------------------------------------
create table if not exists public.driver_service_prefs (
  driver_id   uuid not null references public.profiles(id) on delete cascade,
  vehicle_id  uuid not null references public.vehicle(id) on delete cascade,
  service_key text not null,
  enabled     boolean not null,
  updated_at  timestamptz not null default now(),
  primary key (driver_id, vehicle_id, service_key),
  constraint driver_service_prefs_key check (char_length(service_key) between 1 and 130
                                             and service_key = public.driver_service_key(service_key))
);
comment on table public.driver_service_prefs is
  'The services a driver switched on or off for one vehicle (0263). No row: on. Locks (driver_service_locks) win.';
create index if not exists driver_service_prefs_vehicle_idx on public.driver_service_prefs (vehicle_id);
create index if not exists driver_service_prefs_off_idx on public.driver_service_prefs (service_key) where not enabled;

create or replace function public.driver_service_prefs_normalise()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.service_key := public.driver_service_key(new.service_key);
  new.updated_at := now();
  return new;
end;
$$;
revoke execute on function public.driver_service_prefs_normalise() from public, anon, authenticated;
drop trigger if exists trg_driver_service_prefs_normalise on public.driver_service_prefs;
create trigger trg_driver_service_prefs_normalise before insert or update on public.driver_service_prefs
  for each row execute function public.driver_service_prefs_normalise();

-- Whether [p_driver] may drive [p_vehicle]: theirs, assigned to them, or
-- the one they have taken.
create or replace function public.driver_may_drive(p_driver uuid, p_vehicle uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_driver is not null and p_vehicle is not null and (
    exists (select 1 from public.vehicle v where v.id = p_vehicle and v.auth_user_id = p_driver)
    or exists (select 1 from public.vehicle_user_assignment a
                where a.vehicle_id = p_vehicle and a.user_id = p_driver and a.is_active
                  and coalesce(a.approval, 'approved') = 'approved')
    or exists (select 1 from public.vehicle_active_session s where s.vehicle_id = p_vehicle and s.user_id = p_driver));
$$;
revoke execute on function public.driver_may_drive(uuid, uuid) from public, anon;
grant execute on function public.driver_may_drive(uuid, uuid) to authenticated, service_role;

alter table public.driver_service_prefs enable row level security;
revoke all on public.driver_service_prefs from anon;
grant select, insert, update, delete on public.driver_service_prefs to authenticated;

drop policy if exists "driver_service_prefs read" on public.driver_service_prefs;
create policy "driver_service_prefs read" on public.driver_service_prefs for select to authenticated
  using (driver_id = (select auth.uid()) or (select public.caller_is_admin()));
drop policy if exists "driver_service_prefs own insert" on public.driver_service_prefs;
create policy "driver_service_prefs own insert" on public.driver_service_prefs for insert to authenticated
  with check (driver_id = (select auth.uid()) and public.driver_may_drive(driver_id, vehicle_id));
drop policy if exists "driver_service_prefs own update" on public.driver_service_prefs;
create policy "driver_service_prefs own update" on public.driver_service_prefs for update to authenticated
  using (driver_id = (select auth.uid()))
  with check (driver_id = (select auth.uid()) and public.driver_may_drive(driver_id, vehicle_id));
drop policy if exists "driver_service_prefs own delete" on public.driver_service_prefs;
create policy "driver_service_prefs own delete" on public.driver_service_prefs for delete to authenticated
  using (driver_id = (select auth.uid()));

-- ---- 3. Locks -----------------------------------------------------------------------------------
create table if not exists public.driver_service_locks (
  id             uuid primary key default gen_random_uuid(),
  -- One save for several drivers shares it.
  batch_id       uuid not null default gen_random_uuid(),
  scope          text not null,
  driver_id      uuid references public.profiles(id) on delete cascade,
  partner_type   text,
  fleet_id       uuid references public.dispatch_groups(id) on delete cascade,
  region_country text,
  region_state   text,
  region_city    text,
  service_key    text not null,
  mode           text not null,
  until          timestamptz,
  note           text,
  created_by     uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_by     uuid references public.profiles(id) on delete set null,
  updated_at     timestamptz not null default now(),
  constraint driver_service_locks_scope check (scope in ('driver', 'partner_type', 'fleet', 'region', 'everyone')),
  constraint driver_service_locks_mode check (mode in ('on', 'off')),
  constraint driver_service_locks_key check (char_length(service_key) between 1 and 130
                                             and service_key = public.driver_service_key(service_key)),
  constraint driver_service_locks_sizes check (coalesce(char_length(note), 0) <= 500
                                               and coalesce(char_length(partner_type), 0) <= 80
                                               and coalesce(char_length(region_country), 0) <= 120
                                               and coalesce(char_length(region_state), 0) <= 120
                                               and coalesce(char_length(region_city), 0) <= 120),
  constraint driver_service_locks_target check (case scope
    when 'driver' then driver_id is not null and partner_type is null and fleet_id is null
                       and region_country is null and region_state is null and region_city is null
    when 'partner_type' then coalesce(partner_type, '') <> '' and partner_type = public.ptr_key(partner_type)
                       and driver_id is null and fleet_id is null
                       and region_country is null and region_state is null and region_city is null
    when 'fleet' then fleet_id is not null and driver_id is null and partner_type is null
                       and region_country is null and region_state is null and region_city is null
    when 'region' then coalesce(btrim(region_country), '') <> '' and driver_id is null and partner_type is null
                       and fleet_id is null
    else driver_id is null and partner_type is null and fleet_id is null
         and region_country is null and region_state is null and region_city is null
  end)
);
comment on table public.driver_service_locks is
  'get.ride keeps a service on or off for a driver, several drivers (one row each, same batch_id), a partner type, a fleet, a region or everyone (0263).';

-- One lock per target and service.
create unique index if not exists driver_service_locks_one on public.driver_service_locks (
  scope, coalesce(driver_id::text, ''), coalesce(partner_type, ''), coalesce(fleet_id::text, ''),
  lower(coalesce(region_country, '')), lower(coalesce(region_state, '')), lower(coalesce(region_city, '')),
  service_key);
create index if not exists driver_service_locks_service_idx on public.driver_service_locks (service_key);
create index if not exists driver_service_locks_driver_idx on public.driver_service_locks (driver_id);
create index if not exists driver_service_locks_fleet_idx on public.driver_service_locks (fleet_id);
create index if not exists driver_service_locks_created_by_idx on public.driver_service_locks (created_by);
create index if not exists driver_service_locks_updated_by_idx on public.driver_service_locks (updated_by);
create index if not exists driver_service_locks_batch_idx on public.driver_service_locks (batch_id);

-- Who changed what.
create table if not exists public.driver_service_lock_events (
  id          bigint generated always as identity primary key,
  lock_id     uuid,
  batch_id    uuid,
  action      text not null check (action in ('added', 'changed', 'removed')),
  scope       text not null,
  target      jsonb not null default '{}'::jsonb,
  service_key text not null,
  mode        text,
  until       timestamptz,
  note        text,
  actor_id    uuid references public.profiles(id) on delete set null,
  at          timestamptz not null default now()
);
comment on table public.driver_service_lock_events is
  'Every lock set, changed or removed, with who did it (0263). Server-written; admins read.';
create index if not exists driver_service_lock_events_at_idx on public.driver_service_lock_events (at desc);
create index if not exists driver_service_lock_events_actor_idx on public.driver_service_lock_events (actor_id);

-- Kept in the forms the rule compares, and stamped by the server.
create or replace function public.driver_service_locks_normalise()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app boolean := coalesce(current_setting('role', true), '') in ('anon', 'authenticated');
begin
  new.service_key := public.driver_service_key(new.service_key);
  new.partner_type := nullif(public.ptr_key(new.partner_type), '');
  new.region_country := nullif(btrim(coalesce(new.region_country, '')), '');
  new.region_state := nullif(btrim(coalesce(new.region_state, '')), '');
  new.region_city := nullif(btrim(coalesce(new.region_city, '')), '');
  new.note := nullif(btrim(coalesce(new.note, '')), '');
  new.updated_at := now();
  if v_app then
    new.updated_by := auth.uid();
  end if;
  if tg_op = 'INSERT' then
    new.created_at := now();
    if v_app then
      new.created_by := auth.uid();
    end if;
  else
    new.created_at := old.created_at;
    new.created_by := old.created_by;
  end if;
  return new;
end;
$$;
revoke execute on function public.driver_service_locks_normalise() from public, anon, authenticated;
drop trigger if exists trg_driver_service_locks_normalise on public.driver_service_locks;
create trigger trg_driver_service_locks_normalise before insert or update on public.driver_service_locks
  for each row execute function public.driver_service_locks_normalise();

create or replace function public.driver_service_locks_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.driver_service_locks;
  v_action text;
begin
  if tg_op = 'DELETE' then
    r := old;
    v_action := 'removed';
  else
    r := new;
    v_action := case when tg_op = 'INSERT' then 'added' else 'changed' end;
    if tg_op = 'UPDATE' and (new.mode, new.until, new.note) is not distinct from (old.mode, old.until, old.note) then
      return null;
    end if;
  end if;
  insert into public.driver_service_lock_events (lock_id, batch_id, action, scope, target, service_key, mode, until, note, actor_id)
  values (r.id, r.batch_id, v_action, r.scope,
          jsonb_strip_nulls(jsonb_build_object('driver_id', r.driver_id, 'partner_type', r.partner_type,
                                               'fleet_id', r.fleet_id, 'country', r.region_country,
                                               'state', r.region_state, 'city', r.region_city)),
          r.service_key, r.mode, r.until, r.note, auth.uid());
  return null;
end;
$$;
revoke execute on function public.driver_service_locks_log() from public, anon, authenticated;
drop trigger if exists trg_driver_service_locks_log on public.driver_service_locks;
create trigger trg_driver_service_locks_log after insert or update or delete on public.driver_service_locks
  for each row execute function public.driver_service_locks_log();

-- ---- 4. The rule --------------------------------------------------------------------------------
-- The vehicle a driver is driving now.
create or replace function public.driver_session_vehicle(p_driver uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select s.vehicle_id from public.vehicle_active_session s where s.user_id = p_driver limit 1;
$$;

-- What a lock is matched against: the vehicle's partner types and
-- registration region (ptr_vehicle_context: its own, else its owner's),
-- else the driver's partner row's. Types in ptr_key form, places in
-- ptr_name form.
create or replace function public.driver_service_context(p_driver uuid, p_vehicle uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ctx jsonb;
  p public.partners;
  v_types text[];
  v_countries text[];
  v_states text[];
  v_cities text[];
begin
  if p_vehicle is not null then
    v_ctx := public.ptr_vehicle_context(p_vehicle);
  end if;
  select * into p from public.partners where auth_user_id = p_driver order by created_at limit 1;
  v_types := public.ptr_text_array(v_ctx -> 'types');
  if coalesce(cardinality(v_types), 0) = 0 then
    v_types := case when coalesce(cardinality(p.partner_types), 0) > 0 then p.partner_types
                    else array[p.partner_type] end;
  end if;
  v_countries := public.ptr_text_array(v_ctx -> 'countries');
  v_states := public.ptr_text_array(v_ctx -> 'states');
  v_cities := public.ptr_text_array(v_ctx -> 'cities');
  if coalesce(cardinality(v_countries), 0) = 0 then
    v_countries := coalesce(p.service_countries, '{}');
    v_states := coalesce(p.service_states, '{}');
    v_cities := coalesce(p.service_cities, '{}');
  end if;
  return jsonb_build_object(
    'types', coalesce((select jsonb_agg(distinct public.ptr_key(t)) from unnest(v_types) t where coalesce(btrim(t), '') <> ''), '[]'),
    'countries', coalesce((select jsonb_agg(distinct public.ptr_name(c)) from unnest(v_countries) c where coalesce(btrim(c), '') <> ''), '[]'),
    'states', coalesce((select jsonb_agg(distinct public.ptr_name(c)) from unnest(v_states) c where coalesce(btrim(c), '') <> ''), '[]'),
    'cities', coalesce((select jsonb_agg(distinct public.ptr_name(c)) from unnest(v_cities) c where coalesce(btrim(c), '') <> ''), '[]'));
end;
$$;

-- How specific a lock is for this driver and vehicle (higher wins), or
-- null when it does not apply: driver 50, fleet 40, region 30 (+2 a city,
-- +1 a state), partner type 20, everyone 10.
create or replace function public.driver_service_lock_rank(
  p_scope text, p_driver_id uuid, p_partner_type text, p_fleet uuid,
  p_country text, p_state text, p_city text,
  p_driver uuid, p_vehicle uuid, p_ctx jsonb
)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select case p_scope
    when 'driver' then case when p_driver_id = p_driver then 50 end
    when 'fleet' then case when public.dispatch_member_of(p_fleet, p_driver)
                                or exists (select 1 from public.vehicle v
                                            where v.id = p_vehicle and v.dispatch_fleet_id = p_fleet)
                           then 40 end
    when 'region' then case
      when (p_ctx -> 'countries') ? public.ptr_name(p_country)
       and (p_state is null or (p_ctx -> 'states') ? public.ptr_name(p_state))
       and (p_city is null or (p_ctx -> 'cities') ? public.ptr_name(p_city))
      then 30 + case when p_city is not null then 2 when p_state is not null then 1 else 0 end end
    when 'partner_type' then case when (p_ctx -> 'types') ? public.ptr_key(p_partner_type) then 20 end
    when 'everyone' then 10
  end;
$$;

-- The lock that decides [p_service] for [p_driver] driving [p_vehicle]; a
-- row of nulls when none does.
create or replace function public.driver_service_lock(p_driver uuid, p_vehicle uuid, p_service text)
returns public.driver_service_locks
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_key text := public.driver_service_key(p_service);
  v_ctx jsonb;
  r public.driver_service_locks;
begin
  if p_driver is null or coalesce(v_key, '') = ''
     or not exists (select 1 from public.driver_service_locks l
                     where l.service_key = v_key and (l.until is null or l.until > now())) then
    return r;
  end if;
  v_ctx := public.driver_service_context(p_driver, p_vehicle);
  select l.* into r
    from public.driver_service_locks l
    cross join lateral (select public.driver_service_lock_rank(l.scope, l.driver_id, l.partner_type, l.fleet_id,
                                 l.region_country, l.region_state, l.region_city, p_driver, p_vehicle, v_ctx) as rank) k
   where l.service_key = v_key and (l.until is null or l.until > now()) and k.rank is not null
   order by k.rank desc, l.updated_at desc, l.id
   limit 1;
  return r;
end;
$$;

-- Whether [p_service] is on for [p_driver] with [p_vehicle]: the lock that
-- decides it, else the driver's switch for that vehicle, else on.
create or replace function public.driver_service_effective(p_driver uuid, p_vehicle uuid, p_service text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_key text := public.driver_service_key(p_service);
  l public.driver_service_locks;
begin
  if p_driver is null or coalesce(v_key, '') = '' then
    return true;
  end if;
  l := public.driver_service_lock(p_driver, p_vehicle, v_key);
  if l.id is not null then
    return l.mode = 'on';
  end if;
  return coalesce((select p.enabled from public.driver_service_prefs p
                    where p.driver_id = p_driver and p.vehicle_id = p_vehicle and p.service_key = v_key), true);
end;
$$;

-- Whether [p_driver] takes [p_service] now, with the vehicle they drive.
create or replace function public.driver_takes_service(p_driver uuid, p_service text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(btrim(p_service), '') = ''
      or public.driver_service_effective(p_driver, public.driver_session_vehicle(p_driver), p_service);
$$;

-- The Vehicle Service keys off for [p_driver] now (street hail and add-ons
-- left out): their switches off for the vehicle they drive, and the keys of
-- 'off' locks, each judged by the rule.
create or replace function public.driver_services_off(p_driver uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_vehicle uuid;
begin
  if p_driver is null then
    return '{}';
  end if;
  v_vehicle := public.driver_session_vehicle(p_driver);
  return coalesce((
    select array_agg(k order by k) from (
      select p.service_key as k from public.driver_service_prefs p
       where p.driver_id = p_driver and p.vehicle_id = v_vehicle and not p.enabled
      union
      select l.service_key from public.driver_service_locks l
       where l.mode = 'off' and (l.until is null or l.until > now())
    ) x
    where k !~ '^(extra|hail):' and not public.driver_service_effective(p_driver, v_vehicle, k)), '{}');
end;
$$;

create or replace function public.caller_services_off()
returns text[]
language sql
stable
security definer
set search_path = public
as $$ select public.driver_services_off(auth.uid()); $$;

-- Whether a lock applies to the caller (their own vehicle session), for
-- the drivers' read rule.
create or replace function public.driver_service_lock_applies(
  p_scope text, p_driver_id uuid, p_partner_type text, p_fleet uuid,
  p_country text, p_state text, p_city text, p_driver uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_driver is not null and public.driver_service_lock_rank(
    p_scope, p_driver_id, p_partner_type, p_fleet, p_country, p_state, p_city, p_driver,
    public.driver_session_vehicle(p_driver),
    public.driver_service_context(p_driver, public.driver_session_vehicle(p_driver))) is not null;
$$;

revoke execute on function public.driver_session_vehicle(uuid) from public, anon, authenticated;
revoke execute on function public.driver_service_context(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.driver_service_lock_rank(text, uuid, text, uuid, text, text, text, uuid, uuid, jsonb)
  from public, anon, authenticated;
revoke execute on function public.driver_service_lock(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.driver_service_effective(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.driver_takes_service(uuid, text) from public, anon, authenticated;
revoke execute on function public.driver_services_off(uuid) from public, anon, authenticated;
revoke execute on function public.caller_services_off() from public, anon;
revoke execute on function public.driver_service_lock_applies(text, uuid, text, uuid, text, text, text, uuid)
  from public, anon;
grant execute on function public.caller_services_off(),
  public.driver_service_lock_applies(text, uuid, text, uuid, text, text, text, uuid) to authenticated, service_role;
grant execute on function public.driver_service_effective(uuid, uuid, text), public.driver_takes_service(uuid, text),
  public.driver_services_off(uuid), public.driver_service_lock(uuid, uuid, text) to service_role;

-- ---- 5. Who reads and writes the locks ------------------------------------------------------------
insert into public.admin_table_pages (target, page) values
  ('driver_service_locks', 'admin-settings-driver-service-locks')
on conflict do nothing;

alter table public.driver_service_locks enable row level security;
revoke all on public.driver_service_locks from anon;
grant select, insert, update, delete on public.driver_service_locks to authenticated;

drop policy if exists "driver_service_locks read" on public.driver_service_locks;
create policy "driver_service_locks read" on public.driver_service_locks for select to authenticated
  using ((select public.caller_is_admin())
         or public.driver_service_lock_applies(scope, driver_id, partner_type, fleet_id,
                                               region_country, region_state, region_city, (select auth.uid())));
drop policy if exists "driver_service_locks admin insert" on public.driver_service_locks;
create policy "driver_service_locks admin insert" on public.driver_service_locks for insert to authenticated
  with check ((select public.caller_admin_can_write('driver_service_locks')));
drop policy if exists "driver_service_locks admin update" on public.driver_service_locks;
create policy "driver_service_locks admin update" on public.driver_service_locks for update to authenticated
  using ((select public.caller_admin_can_write('driver_service_locks')))
  with check ((select public.caller_admin_can_write('driver_service_locks')));
drop policy if exists "driver_service_locks admin delete" on public.driver_service_locks;
create policy "driver_service_locks admin delete" on public.driver_service_locks for delete to authenticated
  using ((select public.caller_admin_can_write('driver_service_locks')));

alter table public.driver_service_lock_events enable row level security;
revoke all on public.driver_service_lock_events from anon, authenticated;
grant select on public.driver_service_lock_events to authenticated;
drop policy if exists "driver_service_lock_events admin read" on public.driver_service_lock_events;
create policy "driver_service_lock_events admin read" on public.driver_service_lock_events for select to authenticated
  using ((select public.caller_is_admin()));

-- Admin > Driver service locks > Save: for each target, each service set
-- to 'on' or 'off' is kept so (until p_until), 'driver' gives it back to
-- the driver. One save is one batch. Runs as the caller, so the table's
-- write rule decides.
--   p_targets: [{scope, driver_id?, partner_type?, fleet_id?, country?, state?, city?}]
--   p_rules:   {service key: 'on' | 'off' | 'driver'}
create or replace function public.driver_service_locks_set(
  p_targets jsonb, p_rules jsonb, p_until timestamptz default null, p_note text default null
)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  t jsonb;
  r record;
  v_batch uuid := gen_random_uuid();
  v_scope text;
  v_driver uuid;
  v_type text;
  v_fleet uuid;
  v_country text;
  v_state text;
  v_city text;
  v_key text;
  v_id uuid;
  n integer := 0;
begin
  if not public.caller_admin_can_write('driver_service_locks') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if jsonb_typeof(p_targets) is distinct from 'array' or jsonb_array_length(p_targets) not between 1 and 500 then
    raise exception 'DRIVER_SERVICE_LOCK_TARGETS' using errcode = '22023', hint = 'Choose who the locks are for.';
  end if;
  if jsonb_typeof(p_rules) is distinct from 'object' then
    raise exception 'DRIVER_SERVICE_LOCK_RULES' using errcode = '22023', hint = 'Choose a setting for each service.';
  end if;
  if exists (select 1 from jsonb_each(p_rules) e where e.value #>> '{}' not in ('on', 'off', 'driver')) then
    raise exception 'DRIVER_SERVICE_LOCK_RULES' using errcode = '22023',
      hint = 'Each service is Driver decides, Keep on or Keep off.';
  end if;
  if p_until is not null and p_until <= now() then
    raise exception 'DRIVER_SERVICE_LOCK_UNTIL' using errcode = '22023', hint = 'Pick an end date after today.';
  end if;
  for t in select * from jsonb_array_elements(p_targets) loop
    v_scope := t->>'scope';
    v_driver := nullif(t->>'driver_id', '')::uuid;
    v_type := nullif(public.ptr_key(t->>'partner_type'), '');
    v_fleet := nullif(t->>'fleet_id', '')::uuid;
    v_country := nullif(btrim(coalesce(t->>'country', '')), '');
    v_state := nullif(btrim(coalesce(t->>'state', '')), '');
    v_city := nullif(btrim(coalesce(t->>'city', '')), '');
    for r in select e.key, e.value #>> '{}' as v from jsonb_each(p_rules) e loop
      v_key := public.driver_service_key(r.key);
      select l.id into v_id from public.driver_service_locks l
       where l.scope = v_scope and l.service_key = v_key
         and l.driver_id is not distinct from v_driver and l.partner_type is not distinct from v_type
         and l.fleet_id is not distinct from v_fleet
         and lower(coalesce(l.region_country, '')) = lower(coalesce(v_country, ''))
         and lower(coalesce(l.region_state, '')) = lower(coalesce(v_state, ''))
         and lower(coalesce(l.region_city, '')) = lower(coalesce(v_city, ''));
      if r.v = 'driver' then
        if v_id is not null then
          delete from public.driver_service_locks where id = v_id;
        end if;
        continue;
      end if;
      if v_id is not null then
        update public.driver_service_locks
           set mode = r.v, until = p_until, note = p_note, batch_id = v_batch
         where id = v_id;
      else
        insert into public.driver_service_locks (batch_id, scope, driver_id, partner_type, fleet_id,
                                                 region_country, region_state, region_city,
                                                 service_key, mode, until, note)
        values (v_batch, v_scope, v_driver, v_type, v_fleet, v_country, v_state, v_city, v_key, r.v, p_until, p_note);
      end if;
      n := n + 1;
    end loop;
  end loop;
  return n;
end;
$$;
revoke execute on function public.driver_service_locks_set(jsonb, jsonb, timestamptz, text) from public, anon;
grant execute on function public.driver_service_locks_set(jsonb, jsonb, timestamptz, text) to authenticated;

-- Admin > Driver service locks: how many drivers switched each service off
-- (for any of their vehicles), and each add-on ('extra:' keys, 0253).
create or replace function public.driver_service_off_counts()
returns table (service_key text, drivers integer)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select k, count(distinct d)::integer from (
      select p.service_key as k, p.driver_id as d from public.driver_service_prefs p where not p.enabled
      union all
      select 'extra:' || x.k, e.driver_id from public.driver_ride_extras e cross join lateral unnest(e.off) as x(k)
    ) z
    group by k
    order by k;
end;
$$;
revoke execute on function public.driver_service_off_counts() from public, anon;
grant execute on function public.driver_service_off_counts() to authenticated;

-- ---- 6. The driver's Services page ------------------------------------------------------------------
-- What the page shows for [p_vehicle] (null: the vehicle the caller is
-- driving), for a vehicle the caller may drive:
--   vehicle: plate, make, model, colour, type, energy, its service;
--   types: its partner types (else the partner's);
--   order_enforced: whether the service order applies to every booking (0250);
--   services: each active Vehicle Service with whether the partner types
--     allow it (0257), whether the vehicle's service may take it (0250),
--     a required permit missing for it (0254), the driver's switch, the
--     lock that decides it and whether it is on;
--   keys: the same switch / lock / on for street hail and every add-on key
--     a switch or a lock names.
create or replace function public.driver_services_for(p_vehicle uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_vehicle uuid := coalesce(p_vehicle, public.driver_session_vehicle(auth.uid()));
  v public.vehicle;
  v_ctx jsonb;
  v_types text[];
  v_service text;
  v_names jsonb;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_vehicle is null then
    return jsonb_build_object('vehicle', null);
  end if;
  if not public.driver_may_drive(v_uid, v_vehicle) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into v from public.vehicle where id = v_vehicle;
  v_ctx := public.ptr_vehicle_context(v_vehicle);
  v_types := public.ptr_text_array(v_ctx -> 'types');
  if coalesce(cardinality(v_types), 0) = 0 then
    select case when coalesce(cardinality(p.partner_types), 0) > 0 then p.partner_types
                when coalesce(btrim(p.partner_type), '') <> '' then array[p.partner_type] else '{}' end
      into v_types
      from public.partners p where p.auth_user_id = v_uid order by p.created_at limit 1;
  end if;
  v_types := coalesce(v_types, '{}');
  v_service := coalesce(nullif(v.service_approved_id, ''), nullif(v.service_id, ''));

  return jsonb_build_object(
    'vehicle', jsonb_build_object(
      'id', v.id, 'plate', v.plate, 'make', v.make, 'model', v.model, 'color', v.color,
      'vehicle_type', v.vehicle_type, 'energy', public.vehicle_energy(v.id), 'service_id', v_service,
      'service_name', (select e.values->>'name' from public.settings_entries e
                        where e.category = 'vehicle-services' and e.id::text = v_service)),
    'types', to_jsonb(v_types),
    'order_enforced', public.service_order_enforced(),
    'services', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', e.id, 'name', e.values->>'name', 'key', public.driver_service_key(e.values->>'name'),
               'types', e.values->'serviceTypes',
               'parents', e.values->'parentServices',
               'description', coalesce(e.values->>'shortDescription', e.values->>'description', ''),
               'max_pax', e.values->'maxPax',
               'partner_ok', cardinality(v_types) = 0
                             or exists (select 1 from unnest(v_types) t
                                         where public.partner_type_allows_service(t, e.values->>'name')),
               'order_ok', public.service_order_allows(v_service, e.values->>'name'),
               'permit_missing', exists (
                 select 1 from public.permit_types pt
                  where pt.active and pt.applies_to = 'vehicle' and pt.required
                    and (public.permit_settings_for(pt.country)).enforce
                    and coalesce(cardinality(pt.services), 0) > 0
                    and exists (select 1 from unnest(public.ptr_text_array(v_ctx -> 'countries')) c
                                 where public.ptr_name(c) = public.ptr_name(pt.country))
                    and public.permit_type_covers(pt.partner_types, pt.services, v_types, e.id::text)
                    and coalesce((select v2.permit_bypass_until > now() from public.vehicle v2 where v2.id = v.id), false) = false
                    and coalesce((select public.permit_doc_state(d.status, d.expiry_date) from public.vehicle_documents d
                                   where d.vehicle_id = v.id and d.permit_type_id = pt.id
                                   order by d.uploaded_at desc limit 1), 'without') <> 'with'),
               'pref', (select p.enabled from public.driver_service_prefs p
                         where p.driver_id = v_uid and p.vehicle_id = v.id
                           and p.service_key = public.driver_service_key(e.values->>'name')),
               'lock', public.driver_service_lock_json(v_uid, v.id, e.values->>'name'),
               'on', public.driver_service_effective(v_uid, v.id, e.values->>'name'))
             order by coalesce((e.values->>'displayPriority')::numeric, 1e9), e.position, e.created_at)
        from public.settings_entries e
       where e.category = 'vehicle-services'
         and coalesce(btrim(e.values->>'name'), '') <> ''
         and lower(coalesce(e.values->>'status', 'true')) not in ('false', '0', 'off', 'inactive')), '[]'::jsonb),
    'keys', coalesce((
      select jsonb_object_agg(k, jsonb_build_object(
               'pref', (select p.enabled from public.driver_service_prefs p
                         where p.driver_id = v_uid and p.vehicle_id = v.id and p.service_key = k),
               'lock', public.driver_service_lock_json(v_uid, v.id, k),
               'on', public.driver_service_effective(v_uid, v.id, k)))
        from (select 'hail:meter' as k union select 'hail:destination'
              union select p.service_key from public.driver_service_prefs p
                     where p.driver_id = v_uid and p.vehicle_id = v.id and p.service_key ~ '^(extra|hail):'
              union select l.service_key from public.driver_service_locks l
                     where l.service_key ~ '^(extra|hail):' and (l.until is null or l.until > now())) ks), '{}'::jsonb));
end;
$$;

-- The deciding lock as the page shows it: {mode, until, scope}, or null.
create or replace function public.driver_service_lock_json(p_driver uuid, p_vehicle uuid, p_service text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when l.id is null then null
              else jsonb_build_object('mode', l.mode, 'until', l.until, 'scope', l.scope) end
    from (select (public.driver_service_lock(p_driver, p_vehicle, p_service)).*) l;
$$;

revoke execute on function public.driver_service_lock_json(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function public.driver_services_for(uuid) from public, anon;
grant execute on function public.driver_services_for(uuid) to authenticated;

-- ---- 7. Who reads an open request ---------------------------------------------------------------
-- Restrictive, beside 0257's partner type rule, with its exceptions.
drop policy if exists "ride_requests driver services" on public.ride_requests;
create policy "ride_requests driver services" on public.ride_requests as restrictive for select to authenticated
  using (status <> 'open'
         or rider_id = (select auth.uid()) or partner_id = (select auth.uid())
         or (select public.caller_is_admin())
         or (stand_id is not null and array[stand_id] <@ (select public.dispatch_caller_stand_ids()))
         or not (public.driver_service_key(service) = any ((select public.caller_services_off())::text[])));

-- ---- 8. Bids, takes, direct bookings and favourites -----------------------------------------------
-- After My Ride and GET.now (c_my_ride) have named the targets.
create or replace function public.ride_requests_driver_services()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app boolean := coalesce(current_setting('role', true), '') in ('anon', 'authenticated');
  v_keep uuid[];
  l public.driver_service_locks;
begin
  if tg_op = 'INSERT' then
    if coalesce(btrim(new.service), '') = '' then
      return new;
    end if;
    if v_app and new.status = 'open' and new.direct_driver_id is not null
       and not public.driver_takes_service(new.direct_driver_id, new.service) then
      raise exception 'DRIVER_SERVICE_OFF_DIRECT' using errcode = '42501',
        hint = format('This driver doesn''t take %s requests right now. Choose another service, or book without the code.',
                      new.service);
    end if;
    if new.direct_driver_id is null and coalesce(cardinality(new.target_driver_ids), 0) > 0 then
      select coalesce(array_agg(d), '{}') into v_keep
        from unnest(new.target_driver_ids) d
       where public.driver_takes_service(d, new.service);
      if cardinality(v_keep) = 0 then
        new.target_driver_ids := null;
        new.targeted_until := null;
      else
        new.target_driver_ids := v_keep;
      end if;
    end if;
    return new;
  end if;
  -- A driver's own bid or take from the app.
  if v_app and old.status = 'open'
     and new.partner_id is not null and new.partner_id is distinct from old.partner_id
     and new.partner_id = auth.uid()
     and not public.driver_takes_service(new.partner_id, old.service) then
    l := public.driver_service_lock(new.partner_id, public.driver_session_vehicle(new.partner_id), old.service);
    raise exception 'DRIVER_SERVICE_OFF' using errcode = '42501',
      hint = case when l.id is not null
                  then format('get.ride keeps %s off for you. Contact support to change it.', old.service)
                  else format('You turned %s off in Services. Turn it on to take these requests.', old.service) end;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_driver_services() from public, anon, authenticated;
drop trigger if exists trg_ride_requests_c_services on public.ride_requests;
create trigger trg_ride_requests_c_services
  before insert or update of partner_id on public.ride_requests
  for each row execute function public.ride_requests_driver_services();

-- ---- 9. Add-ons: a lock applies on top of the driver's own list ---------------------------------
-- As 0253, then: an 'extra:' lock 'on' takes the add-on back, 'off' adds it.
create or replace function public.driver_extras_off(p_driver uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_own text[] := coalesce((select x.off from public.driver_ride_extras x where x.driver_id = p_driver), '{}');
  v_vehicle uuid;
  v_on text[] := '{}';
  v_off text[] := '{}';
  l public.driver_service_locks;
  k text;
begin
  if p_driver is not null and exists (select 1 from public.driver_service_locks x
                                       where x.service_key like 'extra:%' and (x.until is null or x.until > now())) then
    v_vehicle := public.driver_session_vehicle(p_driver);
    for k in select distinct x.service_key from public.driver_service_locks x
              where x.service_key like 'extra:%' and (x.until is null or x.until > now()) loop
      l := public.driver_service_lock(p_driver, v_vehicle, k);
      continue when l.id is null;
      if l.mode = 'on' then
        v_on := v_on || substr(k, 7);
      else
        v_off := v_off || substr(k, 7);
      end if;
    end loop;
  end if;
  return coalesce((select array_agg(distinct x order by x)
                     from unnest(v_own || v_off) x
                    where not (x = any (v_on))), '{}');
end;
$$;
revoke execute on function public.driver_extras_off(uuid) from public, anon, authenticated;
grant execute on function public.driver_extras_off(uuid) to service_role;

-- ---- 10. Who is pushed and offered --------------------------------------------------------------
-- As 0253, the everyone push leaving out the drivers who don't take the
-- ride's extras (with the add-on locks) or its service now.
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
begin
  select r.rider_id, r.service, public.ride_extra_keys(r.pets, r.assistance, r.option_names, r.passengers)
    into v_rider, v_service, v_keys
    from public.ride_requests r where r.id = p_request;
  v_key := public.driver_service_key(v_service);
  -- A lock other than one driver's may cover anybody: then every partner is
  -- asked; else only those with a switch or a lock of their own.
  v_broad := exists (select 1 from public.driver_service_locks l
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
        and not (public.driver_takes_extras(c.d, v_keys) and public.driver_takes_service(c.d, v_service))
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
-- current definition (as 0254 did).
do $edit$
declare
  e record;
  v_def text;
  v_n int;
begin
  for e in
    select * from (values
      ('ride_request_push_nearby', 'continue when public.driver_permit_problem(v_driver) is not null;',
         'continue when public.driver_permit_problem(v_driver) is not null;' || chr(10)
         || '    continue when not public.driver_takes_service(v_driver, v_service);'),
      ('dispatch_push', 'and public.driver_permit_problem(d.profile_id) is null',
         'and public.driver_permit_problem(d.profile_id) is null' || chr(10)
         || '         and public.driver_takes_service(d.profile_id, r.service)'),
      ('airport_dispatch', 'and public.driver_permit_problem(l.driver_id) is null',
         'and public.driver_permit_problem(l.driver_id) is null' || chr(10)
         || '       and public.driver_takes_service(l.driver_id, r.service)'),
      ('airport_dispatch', 'and public.driver_permit_problem(z.driver_id) is null',
         'and public.driver_permit_problem(z.driver_id) is null' || chr(10)
         || '         and public.driver_takes_service(z.driver_id, r.service)'),
      ('scheduled_rides_open', 'and public.driver_permit_problem(auth.uid()) is null',
         'and public.driver_permit_problem(auth.uid()) is null' || chr(10)
         || '     and public.driver_takes_service(auth.uid(), s.service)')
    ) as t(fn, anchor, added)
  loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = e.fn;
    if v_def is null then
      raise exception '0263: public.% is missing', e.fn;
    end if;
    -- Run again: a place already edited is left alone.
    continue when position(e.added in v_def) > 0;
    v_n := (length(v_def) - length(replace(v_def, e.anchor, ''))) / length(e.anchor);
    if v_n <> 1 then
      raise exception '0263: public.% should have "%" once (has %); update this migration', e.fn, e.anchor, v_n;
    end if;
    execute replace(v_def, e.anchor, e.added);
  end loop;
end
$edit$;

-- ---- 11. Live ---------------------------------------------------------------------------------
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['driver_service_prefs', 'driver_service_locks', 'driver_service_lock_events'] loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
