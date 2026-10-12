-- ============================================================================
-- 0154: trip safety signals (reliability Phase D4)
--
-- Three signals, each behind its own switch in the reliability-messaging
-- settings row (0152), all off until the admin turns them on:
--
--   * safety_start_check: when a trip starts, was the passenger there? It is
--     flagged (ride_requests.start_flag) when the two phones' live GPS fixes
--     were more than safety_far_apart_m apart ('far_apart'), or when both
--     phones were taking part in the Bluetooth handshake (0153) and the
--     passenger's never saw the car in the last 10 minutes ('no_proximity').
--     The passenger is asked "Are you in the car?";
--   * safety_separation: mid-trip, the two phones' live GPS fixes staying
--     more than safety_far_apart_m apart for safety_separation_min minutes
--     (checked every 30 s by pg_cron) marks the ride separated and asks the
--     passenger "Are you still on your trip?". A Bluetooth sighting of the
--     car in the last 2 minutes vetoes it;
--   * safety_lost_items: after a trip, the passenger reports something left
--     behind (report_lost_item, up to 7 days); the driver is told, answers
--     found / not found / returned (respond_lost_item) and the passenger is
--     told the answer.
--
-- The passenger answers either question with trip_safety_ok (or SOS in the
-- app). trip_safety_summary(days) is what happened, for the admin.
-- ============================================================================

alter table public.ride_requests add column if not exists start_flag text
  check (start_flag is null or start_flag in ('far_apart', 'no_proximity'));
alter table public.ride_requests add column if not exists start_flag_at timestamptz;
alter table public.ride_requests add column if not exists apart_since timestamptz;
alter table public.ride_requests add column if not exists separated_at timestamptz;
alter table public.ride_requests add column if not exists safety_ack_at timestamptz;

-- Which side of a ride fetched its Bluetooth token: a phone that never did
-- isn't taking part, so its silence says nothing.
alter table public.ride_ble_secrets add column if not exists rider_seen_at timestamptz;
alter table public.ride_ble_secrets add column if not exists driver_seen_at timestamptz;

-- ---- The switches ------------------------------------------------------------------
create or replace function public.reliability_safety()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with v as (
    select coalesce((select e.values from public.settings_entries e
                      where e.id = '72656c69-6162-4c69-8000-000000000001'), '{}'::jsonb) as j
  )
  select jsonb_build_object(
    'start_check', coalesce(j->>'safety_start_check', '') in ('true', 't', '1', 'on'),
    'separation', coalesce(j->>'safety_separation', '') in ('true', 't', '1', 'on'),
    'lost_items', coalesce(j->>'safety_lost_items', '') in ('true', 't', '1', 'on'),
    'far_apart_m', greatest(100, least(5000, coalesce(
        case when j->>'safety_far_apart_m' ~ '^[0-9]+$' then (j->>'safety_far_apart_m')::int end, 300))),
    'separation_min', greatest(1, least(30, coalesce(
        case when j->>'safety_separation_min' ~ '^[0-9]+$' then (j->>'safety_separation_min')::int end, 3)))
  ) from v;
$$;
revoke execute on function public.reliability_safety() from public, anon;
grant execute on function public.reliability_safety() to authenticated;

-- ---- Tokens: remember which side asked -----------------------------------------------
create or replace function public.get_trip_ble_token(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  r public.ride_requests;
  v_side text;
  v_secret bytea;
  v_window bigint := public.ble_window();
  s jsonb := public.reliability_ble();
begin
  v_side := public.ble_ride_side(p_request);
  select * into r from public.ride_requests where id = p_request;
  if not (s->>'enabled')::boolean then
    return jsonb_build_object('enabled', false);
  end if;
  if r.status not in ('accepted', 'arrived') then
    return jsonb_build_object('enabled', true, 'status', r.status);
  end if;
  insert into public.ride_ble_secrets (request_id, secret) values (p_request, gen_random_bytes(32))
  on conflict (request_id) do nothing;
  update public.ride_ble_secrets
     set rider_seen_at = case when v_side = 'rider' then now() else rider_seen_at end,
         driver_seen_at = case when v_side = 'driver' then now() else driver_seen_at end
   where request_id = p_request
  returning secret into v_secret;
  return jsonb_build_object(
    'enabled', true,
    'status', r.status,
    'side', v_side,
    'token', public.ble_token(v_secret, p_request, v_side, v_window),
    'peer_token', public.ble_token(v_secret, p_request,
                                   case v_side when 'driver' then 'rider' else 'driver' end, v_window),
    'expires_at', to_timestamp((v_window + 1) * 300),
    'settings', s
  );
end;
$$;
revoke execute on function public.get_trip_ble_token(uuid) from public, anon;
grant execute on function public.get_trip_ble_token(uuid) to authenticated;

-- ---- Was the passenger there when the trip started? -----------------------------------
-- 'far_apart', 'no_proximity' or null. Fixes older than 2 minutes say nothing.
create or replace function public.trip_start_flag(r public.ride_requests, p_now timestamptz default now())
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s jsonb := public.reliability_safety();
  b jsonb := public.reliability_ble();
  k public.ride_ble_secrets;
begin
  if r.partner_live_lat is not null and r.user_live_lat is not null
     and r.partner_live_at > p_now - interval '2 minutes' and r.user_live_at > p_now - interval '2 minutes'
     and public.geo_distance_m(r.partner_live_lat, r.partner_live_lng, r.user_live_lat, r.user_live_lng)
         > (s->>'far_apart_m')::int then
    return 'far_apart';
  end if;
  if (b->>'enabled')::boolean and r.start_method is distinct from 'ble' then
    select * into k from public.ride_ble_secrets where request_id = r.id;
    if found and k.rider_seen_at > p_now - interval '10 minutes' and k.driver_seen_at > p_now - interval '10 minutes'
       and not exists (
         select 1 from public.ride_proximity_events e
          where e.request_id = r.id and e.side = 'rider' and e.matched
            and e.at > p_now - interval '10 minutes'
            and e.rssi >= (b->>'rssi_threshold_dbm')::int
       ) then
      return 'no_proximity';
    end if;
  end if;
  return null;
end;
$$;
revoke execute on function public.trip_start_flag(public.ride_requests, timestamptz) from public, anon, authenticated;

create or replace function public.ride_requests_start_check()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'on_trip' and old.status is distinct from 'on_trip'
     and (public.reliability_safety()->>'start_check')::boolean then
    new.start_flag := public.trip_start_flag(new);
    if new.start_flag is not null then
      new.start_flag_at := now();
      perform public.enqueue_notification(
        new.rider_id, new.id || ':start_check', 'trip_safety', 'critical',
        'Your trip has started',
        'Are you in the car? If not, open GET.ride to tell us, or get help.',
        jsonb_build_object('type', 'trip_start_check', 'request_id', new.id, 'status', 'on_trip'),
        new.id);
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_start_check() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_start_check on public.ride_requests;
create trigger trg_ride_requests_start_check before update of status on public.ride_requests
  for each row execute function public.ride_requests_start_check();

-- ---- Mid-trip: the phones drifting apart ------------------------------------------------
create or replace function public.check_trip_separation(p_now timestamptz default now())
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  s jsonb := public.reliability_safety();
  r public.ride_requests;
  v_apart boolean;
  n int := 0;
begin
  if not (s->>'separation')::boolean then
    return 0;
  end if;
  for r in
    select * from public.ride_requests q
     where q.status = 'on_trip' and q.separated_at is null
     for update skip locked
  loop
    v_apart := r.partner_live_lat is not null and r.user_live_lat is not null
      and r.partner_live_at > p_now - interval '90 seconds' and r.user_live_at > p_now - interval '90 seconds'
      and public.geo_distance_m(r.partner_live_lat, r.partner_live_lng, r.user_live_lat, r.user_live_lng)
          > (s->>'far_apart_m')::int
      -- The phones seeing each other over Bluetooth says they're together.
      and not exists (
        select 1 from public.ride_proximity_events e
         where e.request_id = r.id and e.matched and e.at > p_now - interval '2 minutes'
      );
    if not v_apart then
      if r.apart_since is not null then
        update public.ride_requests set apart_since = null where id = r.id;
      end if;
      continue;
    end if;
    if r.apart_since is null then
      update public.ride_requests set apart_since = p_now where id = r.id;
      continue;
    end if;
    if r.apart_since <= p_now - make_interval(mins => (s->>'separation_min')::int) then
      update public.ride_requests set separated_at = p_now where id = r.id;
      perform public.enqueue_notification(
        r.rider_id, r.id || ':separated', 'trip_safety', 'critical',
        'Are you still on your trip?',
        'Your phone and your driver''s seem to be apart. Open GET.ride to say you''re OK, or get help.',
        jsonb_build_object('type', 'trip_separation', 'request_id', r.id, 'status', 'on_trip'),
        r.id);
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;
revoke execute on function public.check_trip_separation(timestamptz) from public, anon, authenticated;

-- ---- The passenger answers: all fine ------------------------------------------------------
create or replace function public.trip_safety_ok(p_request uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.ride_requests set safety_ack_at = now()
   where id = p_request and rider_id = auth.uid();
  if not found then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
end;
$$;
revoke execute on function public.trip_safety_ok(uuid) from public, anon;
grant execute on function public.trip_safety_ok(uuid) to authenticated;

-- ---- Left something behind ------------------------------------------------------------------
create table if not exists public.ride_lost_items (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null references public.ride_requests(id) on delete cascade,
  rider_id    uuid not null,
  partner_id  uuid not null,
  description text not null check (char_length(description) between 2 and 500),
  status      text not null default 'open' check (status in ('open', 'found', 'not_found', 'returned')),
  driver_note text check (driver_note is null or char_length(driver_note) <= 500),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists ride_lost_items_partner on public.ride_lost_items (partner_id, created_at desc);
create index if not exists ride_lost_items_rider on public.ride_lost_items (rider_id, created_at desc);

alter table public.ride_lost_items enable row level security;
create policy "ride_lost_items parties read" on public.ride_lost_items
  for select using (rider_id = auth.uid() or partner_id = auth.uid() or public.caller_is_admin());
revoke all on public.ride_lost_items from anon, authenticated;
grant select on public.ride_lost_items to authenticated;

create or replace function public.report_lost_item(p_request uuid, p_description text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.ride_requests;
  v_id uuid;
  v_text text := btrim(coalesce(p_description, ''));
begin
  if not (public.reliability_safety()->>'lost_items')::boolean then
    raise exception 'lost_items_off';
  end if;
  select * into r from public.ride_requests where id = p_request;
  if not found or r.rider_id is distinct from auth.uid() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.status <> 'completed' or r.partner_id is null
     or coalesce(r.completed_at, r.updated_at) < now() - interval '7 days' then
    raise exception 'too_late';
  end if;
  if char_length(v_text) < 2 then
    raise exception 'describe_it';
  end if;
  if public.auth_rate_take('lost_item', p_request::text, 3, interval '1 day') > 0 then
    raise exception 'too_many';
  end if;
  insert into public.ride_lost_items (request_id, rider_id, partner_id, description)
  values (p_request, r.rider_id, r.partner_id, left(v_text, 500))
  returning id into v_id;
  perform public.enqueue_notification(
    r.partner_id, v_id || ':lost', 'lost_item', 'critical',
    'A passenger left something behind',
    left(v_text, 140) || ' — check your car and answer in GET.ride.',
    jsonb_build_object('type', 'lost_item', 'item_id', v_id, 'request_id', p_request),
    p_request);
  return v_id;
end;
$$;
revoke execute on function public.report_lost_item(uuid, text) from public, anon;
grant execute on function public.report_lost_item(uuid, text) to authenticated;

create or replace function public.respond_lost_item(p_item uuid, p_status text, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  i public.ride_lost_items;
begin
  if p_status not in ('found', 'not_found', 'returned') then
    raise exception 'bad_status';
  end if;
  update public.ride_lost_items
     set status = p_status, driver_note = nullif(left(btrim(coalesce(p_note, '')), 500), ''), updated_at = now()
   where id = p_item and partner_id = auth.uid()
  returning * into i;
  if not found then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  perform public.enqueue_notification(
    i.rider_id, i.id || ':' || p_status, 'lost_item', 'normal',
    case p_status when 'found' then 'Your driver found it'
                  when 'returned' then 'Your item was returned'
                  else 'Your driver couldn''t find it' end,
    coalesce(i.driver_note, left(i.description, 140)),
    jsonb_build_object('type', 'lost_item', 'item_id', i.id, 'request_id', i.request_id),
    i.request_id);
end;
$$;
revoke execute on function public.respond_lost_item(uuid, text, text) from public, anon;
grant execute on function public.respond_lost_item(uuid, text, text) to authenticated;

-- ---- Admin: what happened ----------------------------------------------------------------------
create or replace function public.trip_safety_summary(p_days int default 7)
returns table (start_flags bigint, separations bigint, answered_ok bigint, lost_open bigint, lost_found bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 90)));
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
  select (select count(*) from public.ride_requests r where r.start_flag_at > v_since),
         (select count(*) from public.ride_requests r where r.separated_at > v_since),
         (select count(*) from public.ride_requests r
           where greatest(r.start_flag_at, r.separated_at) > v_since and r.safety_ack_at is not null),
         (select count(*) from public.ride_lost_items l where l.created_at > v_since and l.status = 'open'),
         (select count(*) from public.ride_lost_items l
           where l.created_at > v_since and l.status in ('found', 'returned'));
end;
$$;
revoke execute on function public.trip_safety_summary(int) from public, anon;
grant execute on function public.trip_safety_summary(int) to authenticated;

-- ---- Schedule and live updates ------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'check-trip-separation';
    perform cron.schedule('check-trip-separation', '30 seconds', $job$select public.check_trip_separation()$job$);
  end if;
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and tablename = 'ride_lost_items') then
    alter publication supabase_realtime add table public.ride_lost_items;
  end if;
end $$;

notify pgrst, 'reload schema';
