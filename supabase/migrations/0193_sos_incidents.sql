-- ============================================================================
-- 0193: SOS reaches GET.ride's safety team.
--
-- Until now SOS called the emergency number or texted the person's own
-- emergency contacts; GET.ride never knew. Now every SOS, from a passenger or
-- a driver, also raises a safety incident:
--
--   * the ride, both people and the car's plate, and the reporter's location,
--     kept up to date from their phone for the admin's minutes (default 30);
--   * a critical push to the admin's on-call list, and an SMS to each ops
--     number through the gateway phone carrying the new "Ops alert" channel;
--   * until an admin acknowledges it, it is sent again every N minutes (the
--     admin's, default 2) -- from the second round to every full admin too;
--   * the other person on the ride is never told.
--
-- Admin -> App Settings -> SOS alerts: the on-call admins, the ops numbers,
-- the re-alert minutes and the location minutes (app_settings 'sos_ops').
-- ============================================================================

-- ---- Settings ----------------------------------------------------------------------------
insert into public.app_settings (key, value)
values ('sos_ops', jsonb_build_object('onCall', '[]'::jsonb, 'smsNumbers', '[]'::jsonb,
                                      'smsEnabled', true, 'realertMinutes', 2, 'locationMinutes', 30))
on conflict (key) do nothing;

create or replace function public.sos_ops_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'onCall', coalesce((select jsonb_agg(x) from jsonb_array_elements_text(
                 case when jsonb_typeof(v->'onCall') = 'array' then v->'onCall' else '[]' end) x
               where x ~ '^[0-9a-f-]{36}$'), '[]'::jsonb),
    'smsNumbers', coalesce((select jsonb_agg(x) from jsonb_array_elements_text(
                 case when jsonb_typeof(v->'smsNumbers') = 'array' then v->'smsNumbers' else '[]' end) x
               where x ~ '^\+?[0-9]{6,20}$'), '[]'::jsonb),
    'smsEnabled', coalesce((v->>'smsEnabled')::boolean, true),
    'realertMinutes', least(60, greatest(1, coalesce(
      case when jsonb_typeof(v->'realertMinutes') = 'number' then (v->>'realertMinutes')::numeric end, 2)))::int,
    'locationMinutes', least(240, greatest(5, coalesce(
      case when jsonb_typeof(v->'locationMinutes') = 'number' then (v->>'locationMinutes')::numeric end, 30)))::int)
  from (select (select value from public.app_settings where key = 'sos_ops') as v) s;
$$;
-- The on-call list and ops numbers are the admins' to see.
revoke execute on function public.sos_ops_config() from public, anon, authenticated;

create or replace function public.admin_sos_ops_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return public.sos_ops_config();
end;
$$;
revoke execute on function public.admin_sos_ops_config() from public, anon;
grant execute on function public.admin_sos_ops_config() to authenticated;

create or replace function public.set_sos_ops_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.caller_is_admin() then
    raise exception 'Only an admin can change SOS alerts.' using errcode = '42501';
  end if;
  insert into public.app_settings (key, value, updated_at) values ('sos_ops', coalesce(p_config, '{}'), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  v := public.sos_ops_config();
  update public.app_settings set value = v where key = 'sos_ops';
  return v;
end;
$$;
revoke execute on function public.set_sos_ops_config(jsonb) from public, anon;
grant execute on function public.set_sos_ops_config(jsonb) to authenticated;

-- ---- The "Ops alert" SMS channel -------------------------------------------------------------
alter table public.sms_outbox drop constraint if exists sms_outbox_channel_check;
alter table public.sms_outbox add constraint sms_outbox_channel_check
  check (channel in ('otp', 'marketing', 'support_message', 'ops_alert'));
alter table public.messaging_routes drop constraint if exists messaging_routes_channel_check;
alter table public.messaging_routes add constraint messaging_routes_channel_check
  check (channel in ('otp', 'marketing', 'support_call', 'support_message', 'ops_alert'));

-- Out of the box, ops alerts go through the phone that sends sign-in codes.
insert into public.messaging_routes (channel, direction, transport, device_ids, enabled)
select 'ops_alert', 'outbound', 'sms', r.device_ids, true
  from public.messaging_routes r
 where r.channel = 'otp' and r.direction = 'outbound' and r.transport = 'sms'
on conflict (channel, direction) do nothing;

-- ---- Incidents ---------------------------------------------------------------------------------
create table if not exists public.safety_incidents (
  id               uuid primary key default gen_random_uuid(),
  ride_id          uuid references public.ride_requests(id) on delete set null,
  reporter_id      uuid not null references auth.users(id) on delete cascade,
  reporter_role    text not null check (reporter_role in ('rider', 'partner', 'user')),
  reporter_name    text,
  reporter_phone   text,
  rider_id         uuid,
  partner_id       uuid,
  partner_name     text,
  plate            text,
  vehicle          text,
  pickup_name      text,
  drop_name        text,
  lat              double precision,
  lng              double precision,
  location_at      timestamptz,
  track_until      timestamptz not null,
  status           text not null default 'open' check (status in ('open', 'acknowledged', 'resolved')),
  alert_round      integer not null default 0,
  last_alert_at    timestamptz,
  acknowledged_at  timestamptz,
  acknowledged_by  uuid,
  resolved_at      timestamptz,
  resolved_by      uuid,
  note             text,
  created_at       timestamptz not null default now()
);
create index if not exists safety_incidents_open_idx on public.safety_incidents (status, last_alert_at);
create index if not exists safety_incidents_reporter_idx on public.safety_incidents (reporter_id, created_at desc);

create table if not exists public.safety_incident_locations (
  id          bigserial primary key,
  incident_id uuid not null references public.safety_incidents(id) on delete cascade,
  lat         double precision not null,
  lng         double precision not null,
  at          timestamptz not null default now()
);
create index if not exists safety_incident_locations_idx on public.safety_incident_locations (incident_id, at);

alter table public.safety_incidents enable row level security;
alter table public.safety_incident_locations enable row level security;
revoke all on public.safety_incidents, public.safety_incident_locations from anon, authenticated;
grant select on public.safety_incidents, public.safety_incident_locations to authenticated;

-- The reporter sees their own; admins see all. The other person on the ride
-- is never shown it.
drop policy if exists "safety_incidents read" on public.safety_incidents;
create policy "safety_incidents read" on public.safety_incidents
  for select to authenticated
  using (reporter_id = (select auth.uid()) or (select public.caller_is_admin()));
drop policy if exists "safety_incident_locations read" on public.safety_incident_locations;
create policy "safety_incident_locations read" on public.safety_incident_locations
  for select to authenticated
  using ((select public.caller_is_admin()));

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'safety_incidents') then
    alter publication supabase_realtime add table public.safety_incidents;
  end if;
end $$;

-- ---- Sending the alert -------------------------------------------------------------------------
-- Round 0 goes to the on-call list; later rounds also to every full admin.
create or replace function public.sos_alert(p_incident uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c jsonb := public.sos_ops_config();
  i public.safety_incidents;
  v_to uuid;
  v_num text;
  v_title text;
  v_body text;
  v_map text;
begin
  select * into i from public.safety_incidents where id = p_incident for update;
  if not found or i.status <> 'open' then
    return;
  end if;
  v_map := case when i.lat is null then 'location unknown'
                else 'https://maps.google.com/?q=' || round(i.lat::numeric, 6) || ',' || round(i.lng::numeric, 6) end;
  v_title := case when i.alert_round = 0 then 'SOS: ' else 'SOS still open: ' end
             || case i.reporter_role when 'rider' then 'passenger' when 'partner' then 'driver' else 'user' end
             || ' needs help';
  v_body := coalesce(i.reporter_name, 'Someone') || coalesce(' (' || i.reporter_phone || ')', '')
            || case when i.plate is not null then ' · car ' || i.plate else '' end
            || case when i.pickup_name is not null then ' · ' || i.pickup_name || ' → ' || coalesce(i.drop_name, '?') else '' end
            || ' · ' || v_map;

  for v_to in
    select distinct x::uuid from (
      select jsonb_array_elements_text(c->'onCall') as x
      union all
      select a.profile_id::text from public.admin_access a
       where i.alert_round > 0 and a.page = '*' and a.access_level = 'edit'
    ) s
  loop
    perform public.enqueue_notification(v_to, 'sos-' || i.id || '-' || i.alert_round || '-' || v_to, 'safety_incident',
      'critical', v_title, v_body,
      jsonb_build_object('type', 'safety_incident', 'incident_id', i.id, 'route', '/admin'), null);
  end loop;

  if (c->>'smsEnabled')::boolean then
    for v_num in select jsonb_array_elements_text(c->'smsNumbers') loop
      insert into public.sms_outbox (to_phone, body, channel)
      values (v_num, left('GET.ride ' || v_title || ': ' || v_body || ' · '
                          || to_char(now() at time zone 'Asia/Kuala_Lumpur', 'HH24:MI'), 1600), 'ops_alert');
    end loop;
  end if;

  update public.safety_incidents set alert_round = alert_round + 1, last_alert_at = now() where id = i.id;
end;
$$;
revoke execute on function public.sos_alert(uuid) from public, anon, authenticated;

-- ---- The person in trouble presses SOS -------------------------------------------------------------
create or replace function public.sos_raise(p_ride uuid default null, p_lat double precision default null,
                                            p_lng double precision default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  c jsonb := public.sos_ops_config();
  r public.ride_requests;
  p public.profiles;
  v_role text := 'user';
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_ride is not null then
    select * into r from public.ride_requests where id = p_ride;
    if found and r.rider_id = v_uid then
      v_role := 'rider';
    elsif found and r.partner_id = v_uid then
      v_role := 'partner';
    else
      r := null;  -- not their ride: raised without it
    end if;
  end if;

  -- Pressed again within ten minutes: the same incident, with the new place.
  select id into v_id from public.safety_incidents
   where reporter_id = v_uid and status <> 'resolved' and created_at > now() - interval '10 minutes'
   order by created_at desc limit 1;
  if v_id is not null then
    perform public.sos_location(v_id, p_lat, p_lng);
    return v_id;
  end if;

  select * into p from public.profiles where id = v_uid;
  insert into public.safety_incidents (
    ride_id, reporter_id, reporter_role, reporter_name, reporter_phone, rider_id, partner_id, partner_name,
    plate, vehicle, pickup_name, drop_name, lat, lng, location_at, track_until)
  values (
    r.id, v_uid, v_role, coalesce(p.name, case when v_role = 'partner' then r.partner_name else r.rider_name end),
    coalesce(p.phone, case when v_role = 'partner' then r.partner_phone else r.rider_phone end),
    r.rider_id, r.partner_id, r.partner_name, r.partner_plate, r.partner_vehicle, r.pickup_name, r.drop_name,
    p_lat, p_lng, case when p_lat is not null then now() end,
    now() + make_interval(mins => (c->>'locationMinutes')::int))
  returning id into v_id;
  if p_lat is not null and p_lng is not null then
    insert into public.safety_incident_locations (incident_id, lat, lng) values (v_id, p_lat, p_lng);
  end if;
  perform public.sos_alert(v_id);
  return v_id;
end;
$$;
revoke execute on function public.sos_raise(uuid, double precision, double precision) from public, anon;
grant execute on function public.sos_raise(uuid, double precision, double precision) to authenticated;

-- The reporter's phone keeps the place up to date for the admin's minutes.
create or replace function public.sos_location(p_incident uuid, p_lat double precision, p_lng double precision)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  i public.safety_incidents;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return false;
  end if;
  select * into i from public.safety_incidents where id = p_incident;
  if not found or i.reporter_id is distinct from auth.uid() or now() > i.track_until or i.status = 'resolved' then
    return false;
  end if;
  update public.safety_incidents set lat = p_lat, lng = p_lng, location_at = now() where id = i.id;
  insert into public.safety_incident_locations (incident_id, lat, lng) values (i.id, p_lat, p_lng);
  return true;
end;
$$;
revoke execute on function public.sos_location(uuid, double precision, double precision) from public, anon;
grant execute on function public.sos_location(uuid, double precision, double precision) to authenticated;

-- ---- Admins answer ------------------------------------------------------------------------------
create or replace function public.sos_acknowledge(p_incident uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  update public.safety_incidents
     set status = 'acknowledged', acknowledged_at = now(), acknowledged_by = auth.uid()
   where id = p_incident and status = 'open';
end;
$$;
revoke execute on function public.sos_acknowledge(uuid) from public, anon;
grant execute on function public.sos_acknowledge(uuid) to authenticated;

create or replace function public.sos_resolve(p_incident uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  update public.safety_incidents
     set status = 'resolved', resolved_at = now(), resolved_by = auth.uid(),
         acknowledged_at = coalesce(acknowledged_at, now()), acknowledged_by = coalesce(acknowledged_by, auth.uid()),
         note = coalesce(left(p_note, 1000), note)
   where id = p_incident and status <> 'resolved';
end;
$$;
revoke execute on function public.sos_resolve(uuid, text) from public, anon;
grant execute on function public.sos_resolve(uuid, text) to authenticated;

-- ---- Nobody answered: again, to more people ----------------------------------------------------------
create or replace function public.sos_realert()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mins int := (public.sos_ops_config()->>'realertMinutes')::int;
  v_id uuid;
  n integer := 0;
begin
  for v_id in
    select id from public.safety_incidents
     where status = 'open' and last_alert_at < now() - make_interval(mins => v_mins)
  loop
    perform public.sos_alert(v_id);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke execute on function public.sos_realert() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'sos-realert';
    perform cron.schedule('sos-realert', '* * * * *', $job$select public.sos_realert()$job$);
  end if;
end $$;
