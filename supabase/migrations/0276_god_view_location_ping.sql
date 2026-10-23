-- ============================================================================
-- 0276 — God View: "Still there?" pings, "Always on" phones that stay put,
-- and the admin's God View settings.
--
-- Applied by hand as version 20261021033400 (0276_god_view_location_ping in
-- supabase_migrations.schema_migrations). Re-runnable: every object is
-- created with "if not exists" / "or replace", the trigger and the cron job
-- are dropped first, god_view_people is dropped and created again (its
-- result gains a column).
--
-- Why: an iPhone with location "Always" and the background key (0272) went
-- grey "Last known" on God View two and a half hours after its last report:
-- iOS wakes a closed app only after a move of ~500 m, and God View called
-- anyone silent for 30 minutes "last known", though the phone was simply
-- not moving. Now:
--
-- 1. push_tokens, new columns:
--      moved_at, moved_lat, moved_lng  when and where the phone last moved
--                       more than 200 m (trigger push_tokens_moved, on every
--                       write of last_lat / last_lng: push_checkin,
--                       push_set_location, push_background_location);
--                       filled from located_at for the rows there are;
--      ping_sent_at     when a "Still there?" ping was last sent to it.
-- 2. god_view_settings() (internal): Admin -> God View -> Settings, kept in
--    admin_display_settings.settings.godView (the row every device reads;
--    nothing in it is private):
--      pings          send the scheduled pings (default on);
--      pingMinutes    ping an "Always on" phone silent this long (default
--                     30, 10..240);
--      alwaysOnHours  an "Always on" phone stays "Always on" this long
--                     after its last report (default 12, 1..48).
--    god_view_save_settings(pings, minutes, hours): full admins only (edit
--    on '*'), clamped, logged in admin_audit_log; returns the settings.
-- 3. The ping. A silent push (FCM data `type: location_ping`; on an iPhone a
--    background push, `content-available`) that the app's native code
--    answers with one location fix through push_background_location (the
--    install's key), with the app closed, no Flutter engine needed:
--      location_ping_kick(ids, reason) (internal): POSTs { tokenIds, reason }
--        to /functions/v1/location-ping over pg_net with the existing push
--        webhook secret (`x-push-secret`, Vault `push_webhook_secret`, 0128)
--        and nothing else, as trip_card_push_kick (0274);
--      location_ping_targets(ids) (service role only): what the function
--        sends to, of the rows just claimed (ping_sent_at in the last 10
--        minutes): FCM tokens (ios / android, never a PushKit or Expo token)
--        of a signed-in, not deleted account, still location always with
--        the background key;
--      location_ping_due() (pg_cron, every 5 minutes): claims (at most 500
--        a run, oldest first) the phones whose last report is older than
--        pingMinutes and not pinged in pingMinutes, located in the past 7
--        days, and kicks the function. Nothing while pings are off.
--      god_view_ping(profile): Admin -> God View -> Details -> "Ping now":
--        the same caller check as god_view_snapshot, and only for someone
--        the caller may see (god_view_may_see: a sub-admin's region); each
--        phone at most once in 2 minutes; at most 60 a caller in 10
--        minutes; logged in admin_audit_log ('god_view.ping'); never a phone
--        number. Returns { phones, sent, recent, sent_at, retry_at, posted }.
--      god_view_ping_answer(profile, since): whether a report came in since
--        (the page asks for up to a minute), same check.
--    The button goes through the database rather than calling the function
--    with the admin's token: the access rule (god_view_caller,
--    god_view_may_see) is checked in one place, the function accepts only
--    the database's secret or the service role and never an admin JWT, and
--    the audit row and the rate limit sit in the same transaction as the
--    claim.
-- 4. god_view_people / god_view_snapshot, redefined from 0272 (same
--    arguments, scope, row cap and no phones). "Always on" also covers a
--    phone that has gone quiet: location always with the background key and
--    a report in the last alwaysOnHours (it reports when it moves, and
--    answers the pings), unless its freshest report is the open app's of the
--    last 30 minutes (App open). After that it is "Last known" as before.
--    Each row gains moved_at (the phone's, for Always on: "Not moved since
--    4:31 PM"); the snapshot gains settings ({pings, pingMinutes,
--    alwaysOnHours, editable}). Counts, the row cap and the "Last known"
--    toggle follow the new status.
--
-- The function: supabase/functions/location-ping (deploy --no-verify-jwt;
-- secret FCM_SERVICE_ACCOUNT, as send-push). The phones: a new build
-- (AppDelegate.swift, LocationPingReceiver.kt).
-- ============================================================================

-- ---- 1. When the phone last moved, and was last pinged --------------------------------------
alter table public.push_tokens
  add column if not exists moved_at timestamptz,
  add column if not exists moved_lat double precision,
  add column if not exists moved_lng double precision,
  add column if not exists ping_sent_at timestamptz;
comment on column public.push_tokens.moved_at is
  'When the phone last moved more than 200 m (moved_lat / moved_lng, 0276): God View''s "Not moved since".';
comment on column public.push_tokens.ping_sent_at is
  'When a "Still there?" location ping (location-ping, 0276) was last sent to this phone.';

update public.push_tokens
   set moved_at = located_at, moved_lat = last_lat, moved_lng = last_lng
 where moved_at is null and located_at is not null and last_lat is not null and last_lng is not null;

create or replace function public.push_tokens_moved()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.last_lat is null or new.last_lng is null then
    return new;
  end if;
  if new.moved_lat is null or new.moved_lng is null
     or public.km_between(new.moved_lat, new.moved_lng, new.last_lat, new.last_lng) > 0.2 then
    new.moved_lat := new.last_lat;
    new.moved_lng := new.last_lng;
    new.moved_at := coalesce(new.located_at, now());
  end if;
  return new;
end;
$$;
revoke execute on function public.push_tokens_moved() from public, anon, authenticated;

drop trigger if exists trg_push_tokens_moved on public.push_tokens;
create trigger trg_push_tokens_moved
  before insert or update of last_lat, last_lng on public.push_tokens
  for each row execute function public.push_tokens_moved();

create index if not exists push_tokens_ping_due_idx on public.push_tokens (located_at)
  where bg_key_hash is not null and location_always;

-- ---- 2. The admin's God View settings -----------------------------------------------------------
create or replace function public.god_view_settings()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'pings', case when jsonb_typeof(g -> 'pings') = 'boolean' then (g ->> 'pings')::boolean else true end,
    'pingMinutes', least(greatest(round(coalesce(
      case when jsonb_typeof(g -> 'pingMinutes') = 'number' then (g ->> 'pingMinutes')::numeric end, 30)), 10), 240)::int,
    'alwaysOnHours', least(greatest(round(coalesce(
      case when jsonb_typeof(g -> 'alwaysOnHours') = 'number' then (g ->> 'alwaysOnHours')::numeric end, 12)), 1), 48)::int)
  from (select coalesce(
          (select case when jsonb_typeof(s.settings -> 'godView') = 'object' then s.settings -> 'godView' end
             from public.admin_display_settings s where s.id = 'global'),
          '{}'::jsonb) as g) x;
$$;
revoke execute on function public.god_view_settings() from public, anon, authenticated;

create or replace function public.god_view_save_settings(
  p_pings boolean,
  p_ping_minutes integer,
  p_always_on_hours integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new jsonb;
begin
  if not public.caller_is_full_admin() then
    raise exception 'Only a full admin can change the God View settings.' using errcode = '42501';
  end if;
  v_new := jsonb_build_object(
    'pings', coalesce(p_pings, true),
    'pingMinutes', least(greatest(coalesce(p_ping_minutes, 30), 10), 240),
    'alwaysOnHours', least(greatest(coalesce(p_always_on_hours, 12), 1), 48));
  insert into public.admin_display_settings as s (id, settings, updated_at)
  values ('global', jsonb_build_object('godView', v_new), now())
  on conflict (id) do update
    set settings = coalesce(s.settings, '{}'::jsonb)
                   || jsonb_build_object('godView',
                        case when jsonb_typeof(s.settings -> 'godView') = 'object' then s.settings -> 'godView'
                             else '{}'::jsonb end || v_new),
        updated_at = now();
  insert into public.admin_audit_log (actor_id, action, detail)
  values (auth.uid(), 'god_view.settings', v_new);
  return public.god_view_settings();
end;
$$;
revoke execute on function public.god_view_save_settings(boolean, integer, integer) from public, anon;
grant execute on function public.god_view_save_settings(boolean, integer, integer) to authenticated;

-- ---- 3. The ping --------------------------------------------------------------------------------
-- The call: { tokenIds, reason } to the function, with the push webhook
-- secret and nothing else. False when it could not be queued.
create or replace function public.location_ping_kick(p_ids uuid[], p_reason text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url    text;
  v_secret text;
begin
  if coalesce(cardinality(p_ids), 0) = 0 then
    return false;
  end if;
  begin
    select decrypted_secret into v_url
      from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_secret
      from vault.decrypted_secrets where name = 'push_webhook_secret' limit 1;
  exception when others then
    return false;
  end;
  if v_url is null or v_secret is null then
    return false;
  end if;
  perform net.http_post(
    url     := v_url || '/functions/v1/location-ping',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body    := jsonb_build_object('tokenIds', to_jsonb(p_ids), 'reason', left(coalesce(p_reason, ''), 20))
  );
  return true;
exception when others then
  return false;
end;
$$;
revoke execute on function public.location_ping_kick(uuid[], text) from public, anon, authenticated;

-- What the function sends to: of [p_ids], the rows just claimed that may
-- still be pinged. Never the phone number, never the key.
create or replace function public.location_ping_targets(p_ids uuid[])
returns table (id uuid, token text, platform text)
language sql
stable
security definer
set search_path = ''
as $$
  select t.id, t.token, t.platform
    from public.push_tokens t
    join public.profiles p on p.id = t.profile_id and p.deleted_at is null
   where t.id = any(coalesce(p_ids, '{}'))
     and t.bg_key_hash is not null
     and t.location_always
     and t.platform in ('ios', 'android')
     and t.token not like 'ExponentPushToken[%'
     and t.token not like 'ExpoPushToken[%'
     and t.ping_sent_at > now() - interval '10 minutes'
   order by t.id
   limit 1000;
$$;
revoke execute on function public.location_ping_targets(uuid[]) from public, anon, authenticated;
grant execute on function public.location_ping_targets(uuid[]) to service_role;

-- The scheduled run: every phone due, claimed, then the function kicked.
-- How many were claimed.
create or replace function public.location_ping_due()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  s jsonb := public.god_view_settings();
  v_every interval := make_interval(mins => (s ->> 'pingMinutes')::int);
  v_ids uuid[];
begin
  if not (s ->> 'pings')::boolean then
    return 0;
  end if;
  with due as (
    select t.id
      from public.push_tokens t
      join public.profiles p on p.id = t.profile_id and p.deleted_at is null
     where t.bg_key_hash is not null
       and t.location_always
       and t.platform in ('ios', 'android')
       and t.located_at < now() - v_every
       and t.located_at > now() - interval '7 days'
       and (t.ping_sent_at is null or t.ping_sent_at < now() - v_every)
     order by t.located_at asc
     limit 500
       for update of t skip locked
  ),
  claimed as (
    update public.push_tokens t
       set ping_sent_at = now()
      from due
     where t.id = due.id
    returning t.id
  )
  select array_agg(c.id order by c.id) into v_ids from claimed c;
  if coalesce(cardinality(v_ids), 0) = 0 then
    return 0;
  end if;
  perform public.location_ping_kick(v_ids, 'scheduled');
  return cardinality(v_ids);
end;
$$;
revoke execute on function public.location_ping_due() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'god-view-location-ping';
    perform cron.schedule('god-view-location-ping', '*/5 * * * *', $job$select public.location_ping_due()$job$);
  end if;
end $$;

-- "Ping now" from God View's Details: the person's phones, each at most once
-- in 2 minutes.
create or replace function public.god_view_ping(p_profile_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_phones int;
  v_ids uuid[];
  v_retry timestamptz;
  v_posted boolean := false;
begin
  if p_profile_id is null or not public.god_view_may_see(p_profile_id) then
    raise exception 'You can only ping someone on your God View map.' using errcode = '42501';
  end if;
  if v_uid is not null and (select count(*) from public.admin_audit_log l
                             where l.actor_id = v_uid and l.action = 'god_view.ping'
                               and l.created_at > now() - interval '10 minutes') >= 60 then
    raise exception 'Too many pings in 10 minutes. Wait a few minutes and try again.' using errcode = 'P0001';
  end if;
  with mine as (
    select t.id, t.ping_sent_at
      from public.push_tokens t
      join public.profiles p on p.id = t.profile_id and p.deleted_at is null
     where t.profile_id = p_profile_id
       and t.bg_key_hash is not null
       and t.location_always
       and t.platform in ('ios', 'android')
       for update of t
  ),
  claimed as (
    update public.push_tokens t
       set ping_sent_at = now()
      from mine m
     where t.id = m.id
       and (m.ping_sent_at is null or m.ping_sent_at < now() - interval '2 minutes')
    returning t.id
  )
  select (select count(*) from mine),
         (select array_agg(c.id order by c.id) from claimed c),
         (select min(m.ping_sent_at) + interval '2 minutes' from mine m
           where m.ping_sent_at >= now() - interval '2 minutes')
    into v_phones, v_ids, v_retry;
  if coalesce(cardinality(v_ids), 0) > 0 then
    v_posted := public.location_ping_kick(v_ids, 'manual');
  end if;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'god_view.ping', p_profile_id,
          jsonb_build_object('phones', v_phones, 'sent', coalesce(cardinality(v_ids), 0), 'posted', v_posted));
  return jsonb_build_object(
    'phones', v_phones,
    'sent', coalesce(cardinality(v_ids), 0),
    'recent', v_phones - coalesce(cardinality(v_ids), 0),
    'posted', v_posted,
    'sent_at', now(),
    'retry_at', case when coalesce(cardinality(v_ids), 0) = 0 then v_retry end);
end;
$$;
revoke execute on function public.god_view_ping(uuid) from public, anon;
grant execute on function public.god_view_ping(uuid) to authenticated;

-- Whether a report came in from any of the person's phones since [p_since]
-- (the ping's sent_at). Only the time: never where, never a phone.
create or replace function public.god_view_ping_answer(p_profile_id uuid, p_since timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_at timestamptz;
begin
  if p_profile_id is null or not public.god_view_may_see(p_profile_id) then
    raise exception 'You can only ping someone on your God View map.' using errcode = '42501';
  end if;
  select max(t.located_at) into v_at
    from public.push_tokens t
   where t.profile_id = p_profile_id;
  return jsonb_build_object('answered', p_since is not null and v_at >= p_since, 'located_at', v_at);
end;
$$;
revoke execute on function public.god_view_ping_answer(uuid, timestamptz) from public, anon;
grant execute on function public.god_view_ping_answer(uuid, timestamptz) to authenticated;

-- ---- 4. The people ------------------------------------------------------------------------------
-- As 0272, "Always on" for alwaysOnHours, and each row's moved_at. Dropped
-- first: the result gains a column. p_offline: also the last known
-- positions, up to 7 days old.
drop function if exists public.god_view_people(double precision[], boolean, text, uuid, boolean, jsonb, polygon[]);
create function public.god_view_people(
  p_box double precision[],
  p_offline boolean,
  p_query text,
  p_only uuid,
  p_scoped boolean,
  p_region jsonb,
  p_polys polygon[]
)
returns table (
  kind text, id uuid, partner_row_id uuid, name text, service text, vehicle text, plate text,
  status text, lat double precision, lng double precision, updated_at timestamptz,
  ride_id uuid, ride_code text, other_id uuid, other_name text, eta_min integer,
  next_lat double precision, next_lng double precision, area text, sos boolean, incident_id uuid,
  moved_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  with
  q as (
    select nullif(regexp_replace(lower(btrim(coalesce(p_query, ''))), '[%_\\]', '', 'g'), '') as t,
           nullif(regexp_replace(coalesce(p_query, ''), '\D', '', 'g'), '') as digits,
           -- Live: an app-open or background report in the last 30 minutes.
           now() - interval '30 minutes' as live_after,
           -- Always on: a phone with location always and the background key,
           -- reporting when it moves and answering the pings, stays so this long.
           now() - make_interval(hours => (public.god_view_settings() ->> 'alwaysOnHours')::int) as quiet_after,
           -- Phones: live ones (Always on included), or with the last known positions a week of them.
           now() - case when coalesce(p_offline, false) then interval '7 days'
                        else greatest(interval '30 minutes',
                                      make_interval(hours => (public.god_view_settings() ->> 'alwaysOnHours')::int)) end
             as seen_after,
           -- Partners' presence: 24 h for "online, not responding", a week for the last known.
           now() - case when coalesce(p_offline, false) then interval '7 days' else interval '24 hours' end as presence_after
  ),
  rides as materialized (
    select r.id, r.status, r.rider_id, r.partner_id, r.service, r.partner_vehicle, r.partner_plate,
           r.rider_name, r.partner_name,
           r.pickup_lat, r.pickup_lng, r.drop_lat, r.drop_lng,
           r.partner_live_lat, r.partner_live_lng, r.partner_live_at,
           r.user_live_lat, r.user_live_lng, r.user_live_at,
           r.country, r.state, r.city, r.suburb,
           r.created_at, r.updated_at, r.started_at, r.duration_min,
           'R-' || upper(left(replace(r.id::text, '-', ''), 6)) as code
      from public.ride_requests r
     where r.status in ('open', 'accepted', 'arrived', 'on_trip')
       and r.updated_at > now() - interval '12 hours'
  ),
  partner_ride as (
    select distinct on (r.partner_id) r.*
      from rides r
     where r.partner_id is not null and r.status in ('accepted', 'arrived', 'on_trip')
     order by r.partner_id, r.updated_at desc
  ),
  rider_ride as (
    select distinct on (r.rider_id) r.*
      from rides r
     where r.rider_id is not null
     order by r.rider_id, (r.status <> 'open') desc, r.updated_at desc
  ),
  eta as (
    select distinct on (o.request_id) o.request_id, o.eta_min
      from public.ride_offers o
      join rides r on r.id = o.request_id
     where o.status = 'accepted'
     order by o.request_id, o.created_at desc
  ),
  sos as materialized (
    select distinct on (x.pid) x.pid, x.id as incident_id,
           case when x.pid = x.reporter_id then x.lat end as lat,
           case when x.pid = x.reporter_id then x.lng end as lng,
           case when x.pid = x.reporter_id then x.location_at end as location_at
      from (select s.*, unnest(array[s.reporter_id, s.rider_id, s.partner_id,
                                     r.rider_id, r.partner_id]) as pid
              from public.safety_incidents s
              left join public.ride_requests r on r.id = s.ride_id
             where s.status in ('open', 'acknowledged')) x
     where x.pid is not null
     order by x.pid, x.created_at desc
  ),
  -- The phone's freshest position (the open app's or the background's),
  -- for app-open, always-on and last-known people, and every area name.
  -- Always on: a fresh background report with location always (0272), or
  -- (0276) a quiet phone still set to always with the background key whose
  -- last report is within alwaysOnHours; a fresh open-app report is App open.
  phone as materialized (
    select distinct on (t.profile_id) t.profile_id, t.last_lat, t.last_lng, t.located_at,
           t.area_country, t.area_state, t.area_city, t.area_suburb,
           coalesce(t.moved_at, t.located_at) as moved_at,
           (t.location_always
            and ((t.located_at > q.live_after and t.located_bg)
                 or (t.located_at <= q.live_after and t.located_at > q.quiet_after and t.bg_key_hash is not null)))
             as always_on,
           (t.located_at > q.live_after and not t.located_bg) as app_open
      from public.push_tokens t, q
     where t.located_at > q.seen_after
       and t.profile_id is not null and t.last_lat is not null and t.last_lng is not null
     order by t.profile_id, t.located_at desc
  ),
  -- Partners: a recent presence, a phone report, a job or an SOS.
  partner_ids as (
    select d.profile_id as pid from public.driver_presence d, q where d.updated_at > q.presence_after
    union select ph.profile_id from phone ph
    union select r.partner_id from partner_ride r
    union select s.pid from sos s
  ),
  presence as (
    select distinct on (p.auth_user_id) p.auth_user_id as profile_id,
           coalesce(d.online, false) as online, d.lat, d.lng, d.updated_at,
           p.id as partner_row_id, p.name as partner_name, p.vehicle, p.make, p.model, p.plate,
           p.vehicle_type, p.partner_type
      from partner_ids i
      join public.partners p on p.auth_user_id = i.pid
      cross join q
      left join public.driver_presence d on d.profile_id = p.auth_user_id and d.updated_at > q.presence_after
     order by p.auth_user_id, p.updated_at desc
  ),
  partner_rows as (
    select 'partner'::text as kind, pr.profile_id as id, pr.partner_row_id,
           coalesce(nullif(btrim(pf.name), ''), pr.partner_name) as name,
           coalesce(nullif(btrim(ar.service), ''), nullif(btrim(pr.vehicle_type), ''), pr.partner_type) as service,
           coalesce(nullif(btrim(ar.partner_vehicle), ''), nullif(btrim(concat_ws(' ', pr.make, pr.model)), ''),
                    pr.vehicle) as vehicle,
           coalesce(nullif(btrim(ar.partner_plate), ''), pr.plate) as plate,
           case when sp.pid is not null then 'sos'
                when ar.status in ('accepted', 'arrived') then 'pickup'
                when ar.status = 'on_trip' then 'trip'
                when pr.online and pr.updated_at > now() - interval '3 minutes' then 'free'
                when pr.online and pr.updated_at > now() - interval '24 hours' then 'not_responding'
                when ph.always_on then 'always_on'
                when ph.app_open then 'app_open'
                else 'last_known' end as status,
           pos.lat, pos.lng, pos.at as updated_at,
           ar.id as ride_id, ar.code as ride_code, ar.rider_id as other_id,
           (select nullif(btrim(o.name), '') from public.profiles o where o.id = ar.rider_id) as other_name,
           case when ar.status in ('accepted', 'arrived') then e.eta_min
                when ar.status = 'on_trip' and ar.started_at is not null and ar.duration_min is not null
                  then greatest(0, ar.duration_min - (extract(epoch from now() - ar.started_at) / 60)::int)
           end as eta_min,
           case when ar.status in ('accepted', 'arrived') then ar.pickup_lat
                when ar.status = 'on_trip' then ar.drop_lat end as next_lat,
           case when ar.status in ('accepted', 'arrived') then ar.pickup_lng
                when ar.status = 'on_trip' then ar.drop_lng end as next_lng,
           coalesce(nullif(btrim(ph.area_suburb), ''), nullif(btrim(ph.area_city), ''),
                    nullif(btrim(ar.suburb), ''), nullif(btrim(ar.city), '')) as area,
           sp.pid is not null as sos, sp.incident_id,
           ph.moved_at,
           coalesce(ph.area_country, ar.country) as country, coalesce(ph.area_state, ar.state) as state,
           coalesce(ph.area_city, ar.city) as city, coalesce(ph.area_suburb, ar.suburb) as suburb,
           (q.t is null
            or lower(coalesce(pf.name, pr.partner_name, '')) like '%' || q.t || '%'
            or replace(lower(coalesce(ar.partner_plate, pr.plate, '')), ' ', '') like '%' || replace(q.t, ' ', '') || '%'
            or lower(coalesce(ar.code, '')) like '%' || q.t || '%'
            or (ar.id is not null and ar.id::text like q.t || '%')
            or (length(coalesce(q.digits, '')) >= 4
                and regexp_replace(coalesce(pf.phone, ''), '\D', '', 'g') like '%' || q.digits || '%')) as hit
      from presence pr
      cross join q
      left join public.profiles pf on pf.id = pr.profile_id
      left join partner_ride ar on ar.partner_id = pr.profile_id
      left join eta e on e.request_id = ar.id
      left join sos sp on sp.pid = pr.profile_id
      left join phone ph on ph.profile_id = pr.profile_id
      left join lateral (
        -- The freshest of presence, the ride's live share, their SOS and the phone.
        select v.lat, v.lng, v.at
          from (values (pr.lat, pr.lng, pr.updated_at),
                       (ar.partner_live_lat, ar.partner_live_lng, ar.partner_live_at),
                       (sp.lat, sp.lng, sp.location_at),
                       (ph.last_lat, ph.last_lng, ph.located_at)) v(lat, lng, at)
         where v.lat is not null and v.lng is not null
         order by v.at desc nulls last
         limit 1
      ) pos on true
  ),
  user_ids as (
    select r.rider_id as pid from rider_ride r
    union select ph.profile_id from phone ph
    union select s.pid from sos s
  ),
  user_rows as (
    select 'user'::text as kind, u.pid as id, null::uuid as partner_row_id,
           nullif(btrim(pf.name), '') as name,
           ur.service, null::text as vehicle, null::text as plate,
           case when sp.pid is not null then 'sos'
                when ur.status = 'open' then 'searching'
                when ur.status is not null then 'ride'
                when ph.always_on then 'always_on'
                when ph.app_open then 'app_open'
                else 'last_known' end as status,
           pos.lat, pos.lng, pos.at as updated_at,
           ur.id as ride_id, ur.code as ride_code, ur.partner_id as other_id,
           (select nullif(btrim(o.name), '') from public.profiles o where o.id = ur.partner_id) as other_name,
           null::integer as eta_min,
           case when ur.status = 'on_trip' then ur.drop_lat end as next_lat,
           case when ur.status = 'on_trip' then ur.drop_lng end as next_lng,
           coalesce(nullif(btrim(ur.suburb), ''), nullif(btrim(ur.city), ''),
                    nullif(btrim(ph.area_suburb), ''), nullif(btrim(ph.area_city), '')) as area,
           sp.pid is not null as sos, sp.incident_id,
           ph.moved_at,
           coalesce(ur.country, ph.area_country) as country, coalesce(ur.state, ph.area_state) as state,
           coalesce(ur.city, ph.area_city) as city, coalesce(ur.suburb, ph.area_suburb) as suburb,
           (q.t is null
            or lower(coalesce(pf.name, '')) like '%' || q.t || '%'
            or lower(coalesce(ur.code, '')) like '%' || q.t || '%'
            or (ur.id is not null and ur.id::text like q.t || '%')
            or (length(coalesce(q.digits, '')) >= 4
                and regexp_replace(coalesce(pf.phone, ''), '\D', '', 'g') like '%' || q.digits || '%')) as hit
      from user_ids u
      cross join q
      left join public.profiles pf on pf.id = u.pid
      left join rider_ride ur on ur.rider_id = u.pid
      left join sos sp on sp.pid = u.pid
      left join phone ph on ph.profile_id = u.pid
      left join lateral (
        select v.lat, v.lng, v.at
          from (values
                  -- The rider's GPS share during this ride.
                  (case when ur.user_live_at >= ur.created_at then ur.user_live_lat end,
                   case when ur.user_live_at >= ur.created_at then ur.user_live_lng end, ur.user_live_at, 1),
                  -- Their own SOS location.
                  (sp.lat, sp.lng, sp.location_at, 0),
                  -- Searching: the pickup. In a ride: with the driver, else the pickup.
                  (case when ur.status = 'open' then ur.pickup_lat end,
                   case when ur.status = 'open' then ur.pickup_lng end, ur.updated_at, 2),
                  (case when ur.status <> 'open' then ur.partner_live_lat end,
                   case when ur.status <> 'open' then ur.partner_live_lng end, ur.partner_live_at, 3),
                  (case when ur.status <> 'open' then ur.pickup_lat end,
                   case when ur.status <> 'open' then ur.pickup_lng end, ur.updated_at, 4),
                  -- No ride: the phone (open app, background or last known).
                  (case when ur.id is null then ph.last_lat end,
                   case when ur.id is null then ph.last_lng end, ph.located_at, 5)
               ) v(lat, lng, at, rank)
         where v.lat is not null and v.lng is not null
         -- Their SOS location when it is newer than the share; the rest in order.
         order by case when v.rank > 0 then v.rank
                       when v.at > coalesce(ur.user_live_at, '-infinity'::timestamptz) then 0
                       else 9 end
         limit 1
      ) pos on true
     where not exists (select 1 from presence pr where pr.profile_id = u.pid)
  ),
  everyone as (
    select * from partner_rows
    union all
    select * from user_rows
  )
  select e.kind, e.id, e.partner_row_id, e.name, e.service, e.vehicle, e.plate, e.status, e.lat, e.lng, e.updated_at,
         e.ride_id, e.ride_code, e.other_id, e.other_name, e.eta_min, e.next_lat, e.next_lng, e.area, e.sos, e.incident_id,
         case when e.status = 'always_on' then e.moved_at end
    from everyone e
   where e.lat is not null and e.lng is not null
     and (coalesce(p_offline, false) or e.status <> 'last_known')
     and (p_only is null or e.id = p_only)
     and e.hit
     and (p_box is null or p_only is not null or nullif(btrim(coalesce(p_query, '')), '') is not null
          or cardinality(p_box) <> 4
          or (e.lat between p_box[1] and p_box[3]
              and case when p_box[2] <= p_box[4] then e.lng between p_box[2] and p_box[4]
                       else e.lng >= p_box[2] or e.lng <= p_box[4] end))
     and public.god_view_in_scope(p_scoped, p_region, p_polys, e.lat, e.lng, e.country, e.state, e.city, e.suburb);
$$;
revoke execute on function public.god_view_people(double precision[], boolean, text, uuid, boolean, jsonb, polygon[])
  from public, anon, authenticated;

-- The page's read, as 0272, with each row's moved_at and the settings.
-- p_show_offline: the "Last known" toggle.
create or replace function public.god_view_snapshot(
  p_min_lat double precision default null,
  p_min_lng double precision default null,
  p_max_lat double precision default null,
  p_max_lng double precision default null,
  p_show_offline boolean default false,
  p_query text default null,
  p_limit integer default 1500
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c record;
  v_polys polygon[];
  v_box double precision[];
  v_limit int := least(greatest(coalesce(p_limit, 1500), 1), 3000);
  v jsonb;
begin
  select * into c from public.god_view_caller();
  if not c.ok then
    raise exception 'Only a full admin, or an admin given the God View page, can open God View.'
      using errcode = '42501';
  end if;
  if c.scoped then
    v_polys := public.god_view_region_polys(c.region);
  end if;
  if p_min_lat is not null and p_min_lng is not null and p_max_lat is not null and p_max_lng is not null then
    v_box := array[least(p_min_lat, p_max_lat), p_min_lng, greatest(p_min_lat, p_max_lat), p_max_lng];
  end if;
  with f as materialized (
    select g.*,
           row_number() over (
             order by case g.status when 'sos' then 0 when 'pickup' then 1 when 'trip' then 1
                                    when 'searching' then 2 when 'ride' then 2 when 'free' then 3
                                    when 'not_responding' then 4 when 'app_open' then 4
                                    when 'always_on' then 5 else 6 end,
                      g.updated_at desc nulls last, g.id) as rn
      from public.god_view_people(v_box, p_show_offline, p_query, null, c.scoped, c.region, v_polys) g
  )
  select jsonb_build_object(
    'at', now(),
    'scoped', c.scoped,
    'region', case when c.scoped then c.region end,
    'scope_missing', c.scoped and (c.region is null or btrim(coalesce(c.region->>'country', '')) = ''),
    'settings', public.god_view_settings()
                || jsonb_build_object('editable', not c.scoped and (auth.uid() is null or public.caller_is_full_admin())),
    'total', count(*),
    'omitted', greatest(count(*) - v_limit, 0),
    'omitted_last_known', count(*) filter (where f.rn > v_limit and f.status = 'last_known'),
    'counts', jsonb_build_object(
      'partners_online', count(*) filter (where f.kind = 'partner' and f.status in ('free', 'pickup', 'trip', 'sos')),
      'partners_free', count(*) filter (where f.kind = 'partner' and f.status = 'free'),
      'partners_on_job', count(*) filter (where f.kind = 'partner' and (f.status in ('pickup', 'trip')
                                                                        or (f.status = 'sos' and f.ride_id is not null))),
      'partners_not_responding', count(*) filter (where f.kind = 'partner' and f.status = 'not_responding'),
      'partners_always_on', count(*) filter (where f.kind = 'partner' and f.status = 'always_on'),
      'partners_app_open', count(*) filter (where f.kind = 'partner' and f.status = 'app_open'),
      'partners_offline', count(*) filter (where f.kind = 'partner' and f.status = 'last_known'),
      'users_searching', count(*) filter (where f.kind = 'user' and f.status = 'searching'),
      'users_in_ride', count(*) filter (where f.kind = 'user' and f.status = 'ride'),
      'users_app_open', count(*) filter (where f.kind = 'user' and f.status = 'app_open'),
      'users_always_on', count(*) filter (where f.kind = 'user' and f.status = 'always_on'),
      'users_offline', count(*) filter (where f.kind = 'user' and f.status = 'last_known'),
      'always_on', count(*) filter (where f.status = 'always_on'),
      'not_responding', count(*) filter (where f.status = 'not_responding'),
      'last_known', count(*) filter (where f.status = 'last_known'),
      'sos', count(*) filter (where f.status = 'sos')),
    'people', coalesce(jsonb_agg(jsonb_build_object(
        'kind', f.kind, 'id', f.id, 'partner_row_id', f.partner_row_id, 'name', f.name, 'service', f.service,
        'vehicle', f.vehicle, 'plate', f.plate, 'status', f.status, 'lat', f.lat, 'lng', f.lng,
        'updated_at', f.updated_at, 'ride_id', f.ride_id, 'ride_code', f.ride_code, 'other_id', f.other_id,
        'other_name', f.other_name, 'eta_min', f.eta_min, 'next_lat', f.next_lat, 'next_lng', f.next_lng,
        'area', f.area, 'sos', f.sos, 'incident_id', f.incident_id, 'moved_at', f.moved_at) order by f.rn)
      filter (where f.rn <= v_limit), '[]'::jsonb))
    into v
    from f;
  return v;
end;
$$;
revoke execute on function public.god_view_snapshot(double precision, double precision, double precision,
  double precision, boolean, text, integer) from public, anon;
grant execute on function public.god_view_snapshot(double precision, double precision, double precision,
  double precision, boolean, text, integer) to authenticated;

notify pgrst, 'reload schema';
