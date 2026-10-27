-- ============================================================================
-- 0302 — Region service switches: Inherit / On / Off, and a server check
-- that the service is offered at the pickup (docs/KIV.md M4).
--
-- Version 20261027190000 (0302_region_service_switches). Re-runnable:
-- functions "create or replace", the table, index and settings rows "if not
-- exists" / "on conflict do nothing", policies and triggers dropped first.
--
-- 1. What a region stores (countries / states / cities / suburbs `values`),
--    kept so apps from before read it as they always have:
--      serviceSwitches  {id: "on" | "off"}  master services set here
--                       (new; only this says Off for a master service);
--      subServices      {id: true | false}  sub-services set here (as before);
--      services         a JSON string of {id: true}: older apps read only
--                       this, "a non-empty list offers only those". The
--                       editor writes it as what is on there when saved.
--    Missing from both maps is Inherit.
-- 2. service_offered_at(service, country, state, city, suburb): for each id
--    in the service's line (itself, the sub-services above it, its master
--    services) the most specific region that says something decides; none
--    says anything: On. A region saved before switches (no serviceSwitches)
--    with a non-empty services list says On for the master services in it
--    and Off for every other one, as before. Offered: the service and each
--    sub-service above it on, and one of its master services on (when it
--    has any). Null (allowed) for an unknown service or place, and where a
--    region around has a scheduled "Service hours" rule (the app decides
--    those by the clock). The app's twin is
--    lib/src/core/region_service_switches.dart, tested on the same cases.
-- 3. The check on a booking (ride_requests and scheduled_rides inserts by
--    the app): Admin → Regions → Service check, app_settings
--    'region_service_check' {mode}: 'off' does nothing; 'record' (the
--    default) lets the booking through and keeps a row in
--    region_service_check_log; 'refuse' raises SERVICE_NOT_OFFERED_HERE
--    with the reason as the hint. A refusal rolls back with the booking, so
--    refusals are not logged (the page says so). Street hail, a stand's
--    order, a scheduled booking's release (checked when it was booked),
--    admins and the server are not checked.
-- 4. No data moves: lists from before mean what they meant, and a region
--    the editor saves with switches carries them next to its list.
-- ============================================================================

-- ---- 1. Reading a region's values ------------------------------------------------------------------
-- A value that is a JSON object, or a JSON string holding one; else {}.
create or replace function public.region_json_object(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v jsonb;
begin
  if jsonb_typeof(p) = 'object' then
    return p;
  end if;
  if jsonb_typeof(p) = 'string' then
    begin
      v := (p #>> '{}')::jsonb;
    exception when others then
      return '{}'::jsonb;
    end;
    if jsonb_typeof(v) = 'object' then
      return v;
    end if;
  end if;
  return '{}'::jsonb;
end;
$$;

-- What one region ([p_values]) says about [p_id] (a master service when
-- [p_master]): true, false, or null when it leaves it to the regions around.
create or replace function public.region_service_say(p_values jsonb, p_id text, p_master boolean)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  sw jsonb := public.region_json_object(p_values->'serviceSwitches');
  sub jsonb := public.region_json_object(p_values->'subServices');
  list jsonb;
begin
  if sw->p_id in ('"on"'::jsonb, '"off"'::jsonb) then
    return sw->p_id = '"on"'::jsonb;
  end if;
  if jsonb_typeof(sub->p_id) = 'boolean' then
    return (sub->p_id)::boolean;
  end if;
  if p_master and not exists (select 1 from jsonb_each(sw) e where e.value in ('"on"'::jsonb, '"off"'::jsonb)) then
    list := public.region_json_object(p_values->'services');
    if exists (select 1 from jsonb_each(list) e
                where e.value = 'true'::jsonb or (jsonb_typeof(e.value) = 'number' and (e.value)::numeric <> 0)) then
      return exists (select 1 from jsonb_each(list) e
                      where e.key = p_id
                        and (e.value = 'true'::jsonb or (jsonb_typeof(e.value) = 'number' and (e.value)::numeric <> 0)));
    end if;
  end if;
  return null;
end;
$$;

-- [p_id] at a place whose regions' values are [p_levels], most specific
-- first: the first that says something decides; none: On.
create or replace function public.region_service_resolve(p_levels jsonb[], p_id text, p_master boolean)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v jsonb;
  s boolean;
begin
  foreach v in array coalesce(p_levels, '{}'::jsonb[]) loop
    s := public.region_service_say(v, p_id, p_master);
    if s is not null then
      return s;
    end if;
  end loop;
  return true;
end;
$$;

-- Whether a region's scheduled rules include a "Service hours" one.
create or replace function public.region_has_service_hours(p_values jsonb)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  r jsonb := p_values->'rules';
begin
  if jsonb_typeof(r) = 'string' then
    begin
      r := (r #>> '{}')::jsonb;
    exception when others then
      return false;
    end;
  end if;
  return jsonb_typeof(r) = 'array'
     and exists (select 1 from jsonb_array_elements(r) x where x->>'kind' = 'availability');
end;
$$;

-- The regions at a place by name, most specific first (suburb, city,
-- state, country): one row each level that has a region of that name.
create or replace function public.region_service_levels(p_country text, p_state text, p_city text, p_suburb text)
returns table (lvl integer, name text, vals jsonb)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c_name text;
  c_vals jsonb;
  s_name text;
  s_vals jsonb;
  t_name text;
  t_vals jsonb;
  b_name text;
  b_vals jsonb;
begin
  if coalesce(btrim(p_country), '') = '' then
    return;
  end if;
  select x.name, x.values into c_name, c_vals from public.countries x
   where lower(btrim(x.name)) = lower(btrim(p_country)) or public.region_name_matches(x.name, p_country)
   order by (lower(btrim(x.name)) = lower(btrim(p_country))) desc, x.position limit 1;
  if c_name is null then
    return;
  end if;
  if coalesce(btrim(p_state), '') <> '' then
    select x.name, x.values into s_name, s_vals from public.states x
     where lower(btrim(x.country)) = lower(btrim(c_name))
       and (lower(btrim(x.name)) = lower(btrim(p_state)) or public.region_name_matches(x.name, p_state))
     order by (lower(btrim(x.name)) = lower(btrim(p_state))) desc, x.position limit 1;
  end if;
  if s_name is not null and coalesce(btrim(p_city), '') <> '' then
    select x.name, x.values into t_name, t_vals from public.cities x
     where lower(btrim(x.country)) = lower(btrim(c_name)) and lower(btrim(x.state)) = lower(btrim(s_name))
       and (lower(btrim(x.name)) = lower(btrim(p_city)) or public.region_name_matches(x.name, p_city))
     order by (lower(btrim(x.name)) = lower(btrim(p_city))) desc, x.position limit 1;
  end if;
  if t_name is not null and coalesce(btrim(p_suburb), '') <> '' then
    select x.name, x.values into b_name, b_vals from public.suburbs x
     where lower(btrim(x.country)) = lower(btrim(c_name)) and lower(btrim(x.state)) = lower(btrim(s_name))
       and lower(btrim(x.city)) = lower(btrim(t_name))
       and (lower(btrim(x.name)) = lower(btrim(p_suburb)) or public.region_name_matches(x.name, p_suburb))
     order by (lower(btrim(x.name)) = lower(btrim(p_suburb))) desc, x.position limit 1;
  end if;
  if b_name is not null then
    return query select 3, b_name, coalesce(b_vals, '{}'::jsonb);
  end if;
  if t_name is not null then
    return query select 2, t_name, coalesce(t_vals, '{}'::jsonb);
  end if;
  if s_name is not null then
    return query select 1, s_name, coalesce(s_vals, '{}'::jsonb);
  end if;
  return query select 0, c_name, coalesce(c_vals, '{}'::jsonb);
end;
$$;
revoke execute on function public.region_service_levels(text, text, text, text) from public, anon, authenticated;

-- ---- 2. The service and its line ---------------------------------------------------------------
-- A booking's service (a Vehicle Services or Service Settings name, or a
-- settings entry id) as a settings entry id; null when unknown, blank,
-- street hail or an add-on.
create or replace function public.region_service_id(p_service text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when coalesce(btrim(p_service), '') = '' or lower(btrim(p_service)) ~ '^(extra|hail):' then null
    else coalesce(
      (select e.id::text from public.settings_entries e where e.id::text = lower(btrim(p_service)) limit 1),
      public.vehicle_service_id_of(p_service),
      (select e.id::text from public.settings_entries e
        where e.category = 'service-settings' and lower(btrim(e.values->>'name')) = lower(btrim(p_service))
        order by e.position limit 1))
  end;
$$;
revoke execute on function public.region_service_id(text) from public, anon, authenticated;

-- [p_id] and everything above it: the entries in its `parentServices`
-- (ids) and the master services its `serviceTypes` name, to any depth (as
-- the app's ServiceTree.lineage). [master]: a Service Settings entry.
create or replace function public.service_lineage(p_id text)
returns table (id text, master boolean)
language sql
stable
security definer
set search_path = public
as $$
  with recursive line(id) as (
    select p_id
    union
    select par.pid
      from line l
      join public.settings_entries e on e.id::text = l.id and e.category <> 'service-settings'
      cross join lateral (
        select p.id::text as pid
          from jsonb_array_elements_text(case jsonb_typeof(e.values->'parentServices')
                                           when 'array' then e.values->'parentServices'
                                           when 'string' then jsonb_build_array(e.values->'parentServices')
                                           else '[]'::jsonb end) x
          join public.settings_entries p on p.id::text = btrim(x)
        union
        select m.id::text
          from jsonb_array_elements_text(case when jsonb_typeof(e.values->'serviceTypes') = 'array'
                                              then e.values->'serviceTypes' else '[]'::jsonb end) t
          join public.settings_entries m on m.category = 'service-settings'
                                        and lower(btrim(m.values->>'name')) = lower(btrim(t))
      ) par
  )
  select l.id, exists (select 1 from public.settings_entries e where e.id::text = l.id and e.category = 'service-settings')
    from line l;
$$;
revoke execute on function public.service_lineage(text) from public, anon, authenticated;

-- ---- 3. Offered at a place -------------------------------------------------------------------------
-- Whether [p_service] is offered at the place named; null (allowed) when
-- the service or the place is unknown, or a region around has a scheduled
-- "Service hours" rule. lib/src/core/region_service_switches.dart is the
-- app's twin.
create or replace function public.service_offered_at(p_service text, p_country text, p_state text default null,
                                                     p_city text default null, p_suburb text default null)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id text := public.region_service_id(p_service);
  v_levels jsonb[];
  r record;
  v_masters boolean := false;
  v_master_on boolean := false;
begin
  if v_id is null then
    return null;
  end if;
  select array_agg(l.vals order by l.lvl desc) into v_levels
    from public.region_service_levels(p_country, p_state, p_city, p_suburb) l;
  if coalesce(cardinality(v_levels), 0) = 0 then
    return null;
  end if;
  if exists (select 1 from unnest(v_levels) x(v) where public.region_has_service_hours(x.v)) then
    return null;
  end if;
  for r in select * from public.service_lineage(v_id) loop
    if r.master then
      v_masters := true;
      v_master_on := v_master_on or public.region_service_resolve(v_levels, r.id, true);
    elsif not public.region_service_resolve(v_levels, r.id, false) then
      return false;
    end if;
  end loop;
  return not v_masters or v_master_on;
end;
$$;
revoke execute on function public.service_offered_at(text, text, text, text, text) from public, anon;
grant execute on function public.service_offered_at(text, text, text, text, text) to authenticated, service_role;

-- ---- 4. The check's setting and log ----------------------------------------------------------------
insert into public.app_settings (key, value, updated_at) values
  ('region_service_check', '{"mode": "record"}'::jsonb, now())
on conflict (key) do nothing;

-- 'off', 'record' or 'refuse'; 'record' when unset.
create or replace function public.region_service_check_mode()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select s.value->>'mode' from public.app_settings s
                    where s.key = 'region_service_check' and s.value->>'mode' in ('off', 'record', 'refuse')),
                  'record');
$$;
revoke execute on function public.region_service_check_mode() from public, anon;
grant execute on function public.region_service_check_mode() to authenticated, service_role;

create table if not exists public.region_service_check_log (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  source text not null default 'ride' check (source in ('ride', 'scheduled')),
  ride_id uuid,
  rider_id uuid,
  service text,
  country text,
  state text,
  city text,
  mode text not null check (mode in ('record', 'refuse')),
  refused boolean not null default false
);
create index if not exists region_service_check_log_created_idx
  on public.region_service_check_log (created_at desc);

alter table public.region_service_check_log enable row level security;
revoke all on public.region_service_check_log from public, anon, authenticated;
grant select on public.region_service_check_log to authenticated;
grant all on public.region_service_check_log to service_role;
drop policy if exists region_service_check_log_admin_read on public.region_service_check_log;
create policy region_service_check_log_admin_read on public.region_service_check_log
  for select to authenticated using ((select public.caller_is_admin()));

-- A booking whose service is off at its pickup: refused in 'refuse' mode,
-- else kept in the log (now and then the rows past 90 days go).
create or replace function public.region_service_not_offered(p_mode text, p_source text, p_ride uuid, p_rider uuid,
                                                             p_service text, p_country text, p_state text,
                                                             p_city text, p_suburb text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place text := coalesce(nullif(btrim(p_suburb), ''), nullif(btrim(p_city), ''), nullif(btrim(p_state), ''),
                           nullif(btrim(p_country), ''), 'this area');
begin
  if p_mode = 'refuse' then
    raise exception 'SERVICE_NOT_OFFERED_HERE' using errcode = '22023',
      hint = btrim(p_service) || ' isn''t offered for pickups in ' || v_place
             || '. Choose another service for this trip.';
  end if;
  insert into public.region_service_check_log (source, ride_id, rider_id, service, country, state, city, mode, refused)
  values (p_source, p_ride, p_rider, btrim(p_service), nullif(btrim(p_country), ''), nullif(btrim(p_state), ''),
          nullif(btrim(coalesce(nullif(btrim(p_suburb), ''), p_city)), ''), 'record', false);
  if random() < 0.02 then
    delete from public.region_service_check_log where created_at < now() - interval '90 days';
  end if;
end;
$$;
revoke execute on function public.region_service_not_offered(text, text, uuid, uuid, text, text, text, text, text)
  from public, anon, authenticated;

-- ---- 5. The check on a booking ---------------------------------------------------------------------
-- App bookings only (the session's role, as 0253's option check); a
-- stand's order and a scheduled booking's release are not checked. Named to
-- run after the coverage and option checks.
create or replace function public.ride_requests_service_offered()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mode text;
  p record;
begin
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated')
     or new.stand_id is not null or new.scheduled_ride_id is not null
     or coalesce(btrim(new.service), '') = '' or lower(btrim(new.service)) ~ '^(extra|hail):'
     or public.caller_admin_can_write('ride_requests') then
    return new;
  end if;
  v_mode := public.region_service_check_mode();
  if v_mode = 'off' then
    return new;
  end if;
  select * into p from public.ride_option_place(new.pickup_lat, new.pickup_lng, new.country, new.state, new.city);
  if public.service_offered_at(new.service, p.country, p.state, p.city, p.suburb) is distinct from false then
    return new;
  end if;
  perform public.region_service_not_offered(v_mode, 'ride', new.id, new.rider_id, new.service,
                                            p.country, p.state, p.city, p.suburb);
  return new;
end;
$$;
revoke execute on function public.ride_requests_service_offered() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_b_service_offered on public.ride_requests;
create trigger trg_ride_requests_b_service_offered
  before insert on public.ride_requests
  for each row execute function public.ride_requests_service_offered();

create or replace function public.scheduled_rides_service_offered()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  q jsonb := coalesce(new.request, '{}'::jsonb);
  v_service text := coalesce(nullif(btrim(new.service), ''), q->>'service');
  v_mode text;
  p record;
begin
  if coalesce(current_setting('role', true), '') not in ('anon', 'authenticated')
     or new.stand_id is not null
     or coalesce(btrim(v_service), '') = '' or lower(btrim(v_service)) ~ '^(extra|hail):'
     or public.caller_admin_can_write('scheduled_rides') then
    return new;
  end if;
  v_mode := public.region_service_check_mode();
  if v_mode = 'off' then
    return new;
  end if;
  select * into p from public.ride_option_place(new.pickup_lat, new.pickup_lng, q->>'country', q->>'state', q->>'city');
  if public.service_offered_at(v_service, p.country, p.state, p.city, p.suburb) is distinct from false then
    return new;
  end if;
  perform public.region_service_not_offered(v_mode, 'scheduled', new.id, new.rider_id, v_service,
                                            p.country, p.state, p.city, p.suburb);
  return new;
end;
$$;
revoke execute on function public.scheduled_rides_service_offered() from public, anon, authenticated;

drop trigger if exists trg_scheduled_rides_service_offered on public.scheduled_rides;
create trigger trg_scheduled_rides_service_offered
  before insert on public.scheduled_rides
  for each row execute function public.scheduled_rides_service_offered();

-- ---- 6. Admin → Regions → Service check ------------------------------------------------------------
-- Changing it: EDIT on the Regions page.
insert into public.admin_table_pages (target, page) values
  ('rpc:set_region_service_check', 'admin-settings-country-states-cities')
on conflict do nothing;

create or replace function public.set_region_service_check(p_mode text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.caller_admin_can_write('rpc:set_region_service_check') then
    raise exception 'Only an admin who can edit Regions can change the service check.' using errcode = '42501';
  end if;
  if coalesce(p_mode, '') not in ('off', 'record', 'refuse') then
    raise exception 'The service check is off, record or refuse.' using errcode = '22023';
  end if;
  v := jsonb_build_object('mode', p_mode);
  insert into public.app_settings (key, value, updated_at) values ('region_service_check', v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return v;
end;
$$;
revoke execute on function public.set_region_service_check(text) from public, anon;
grant execute on function public.set_region_service_check(text) to authenticated;

-- For the page: the mode, whether the caller may change it, the counts of
-- bookings kept in the log (24 hours, 7 and 30 days) and the latest rows.
create or replace function public.admin_region_service_check(p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'Only an admin can read the service check.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'mode', public.region_service_check_mode(),
    'canEdit', public.caller_admin_can_write('rpc:set_region_service_check'),
    'day', (select count(*) from public.region_service_check_log where created_at > now() - interval '24 hours'),
    'week', (select count(*) from public.region_service_check_log where created_at > now() - interval '7 days'),
    'month', (select count(*) from public.region_service_check_log where created_at > now() - interval '30 days'),
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object('at', l.created_at, 'source', l.source, 'service', l.service,
                                          'country', l.country, 'state', l.state, 'city', l.city,
                                          'mode', l.mode, 'refused', l.refused) order by l.created_at desc, l.id desc)
        from (select * from public.region_service_check_log
               order by created_at desc, id desc
               limit greatest(1, least(coalesce(p_limit, 20), 100))) l), '[]'::jsonb));
end;
$$;
revoke execute on function public.admin_region_service_check(integer) from public, anon;
grant execute on function public.admin_region_service_check(integer) to authenticated;

notify pgrst, 'reload schema';
