-- ============================================================================
-- 0144: trip pushes that are retried until the app has them
--
-- Pushes left the database fire-and-forget (send_push_webhook swallows any
-- failure) and nothing at all was sent when a trip changed state: "driver
-- assigned", "driver arrived", "trip started", "trip cancelled" reached the
-- passenger only if their app happened to be open. This adds:
--
--   * notification_outbox: one row per recipient per event (event_id is
--     unique per recipient), the server's record of what each person must
--     be told and whether their app has it;
--   * enqueue_notification: writes the row and sends at once;
--   * dispatch_notification_outbox (pg_cron, every 15 s): sends again what
--     no app has acknowledged, on a short schedule (critical events 20 s,
--     1 min, 3 min; others once after 2 min), and stops as soon as the
--     event no longer matters (the trip moved on) or it expires;
--   * ack_notification / ack_ride_notifications / ack_pending_notifications:
--     the app says it has the event (received in the foreground, tapped,
--     or the trip shown on screen);
--   * ride status pushes (accepted, arrived, on_trip, cancelled, a
--     cancellation asked for or declined), each to the side that did not
--     make the change, and 0142's payment pushes, now through the outbox;
--   * notification_delivery_stats: delivery rate and time to acknowledge,
--     per kind, for the admin.
--
-- Retries carry the event id, which the push function uses as the Android
-- tag and the iOS collapse id, so a retry replaces the earlier notification
-- instead of stacking a second one.
-- ============================================================================

create table if not exists public.notification_outbox (
  id              uuid primary key default gen_random_uuid(),
  event_id        text not null,
  profile_id      uuid not null references public.profiles(id) on delete cascade,
  request_id      uuid,
  kind            text not null,
  priority        text not null default 'normal' check (priority in ('critical', 'normal')),
  title           text not null,
  body            text not null,
  data            jsonb not null default '{}'::jsonb,
  attempts        int not null default 0,
  next_attempt_at timestamptz,
  last_attempt_at timestamptz,
  delivered_at    timestamptz,
  read_at         timestamptz,
  stopped_reason  text,
  expires_at      timestamptz not null default now() + interval '10 minutes',
  created_at      timestamptz not null default now(),
  unique (event_id, profile_id)
);

create index if not exists notification_outbox_due
  on public.notification_outbox (next_attempt_at)
  where delivered_at is null and next_attempt_at is not null;
create index if not exists notification_outbox_profile
  on public.notification_outbox (profile_id, created_at desc);
create index if not exists notification_outbox_request
  on public.notification_outbox (request_id)
  where request_id is not null;

alter table public.notification_outbox enable row level security;

drop policy if exists "notification_outbox own or admin read" on public.notification_outbox;
create policy "notification_outbox own or admin read" on public.notification_outbox
  for select using (profile_id = auth.uid() or public.caller_is_admin());
-- No client writes: rows are made and updated by the functions below.

-- ---- When to send again ------------------------------------------------------
-- After the [attempts]-th send: critical events at 20 s, 1 min and 3 min,
-- others once after 2 min; null when there is no next try.
create or replace function public.notification_retry_delay(p_priority text, p_attempts int)
returns interval
language sql
immutable
as $$
  select case
    when p_priority = 'critical' then
      (array[interval '20 seconds', interval '60 seconds', interval '180 seconds'])[p_attempts]
    else
      (array[interval '120 seconds'])[p_attempts]
  end;
$$;

-- ---- Sending one row ---------------------------------------------------------
create or replace function public.send_outbox_row(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.notification_outbox;
  v_attempts int;
  v_delay interval;
begin
  select * into r from public.notification_outbox where id = p_id for update skip locked;
  if not found or r.delivered_at is not null then
    return;
  end if;
  v_attempts := r.attempts + 1;
  v_delay := public.notification_retry_delay(r.priority, v_attempts);
  begin
    perform public.send_push_webhook(jsonb_build_object(
      'title', r.title,
      'body', r.body,
      'profileId', r.profile_id,
      'data', r.data || jsonb_build_object('event_id', r.event_id, 'attempt', v_attempts)
    ));
  exception when others then
    null; -- counted as an attempt all the same; the next one may get through
  end;
  update public.notification_outbox
     set attempts = v_attempts,
         last_attempt_at = now(),
         next_attempt_at = case
           when v_delay is null or now() + v_delay > r.expires_at then null
           else now() + v_delay
         end,
         stopped_reason = case
           when v_delay is null then 'retries_used'
           when now() + v_delay > r.expires_at then 'expired'
           else stopped_reason
         end
   where id = p_id;
end;
$$;

revoke execute on function public.send_outbox_row(uuid) from public, anon, authenticated;

-- ---- Queue one event for one person, and send it ------------------------------
create or replace function public.enqueue_notification(
  p_profile uuid,
  p_event_id text,
  p_kind text,
  p_priority text,
  p_title text,
  p_body text,
  p_data jsonb default '{}'::jsonb,
  p_request uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_profile is null or coalesce(p_event_id, '') = '' then
    return null;
  end if;
  insert into public.notification_outbox (event_id, profile_id, request_id, kind, priority, title, body, data)
  values (p_event_id, p_profile, p_request, p_kind,
          case when p_priority = 'critical' then 'critical' else 'normal' end,
          p_title, p_body, coalesce(p_data, '{}'::jsonb))
  on conflict (event_id, profile_id) do nothing
  returning id into v_id;
  if v_id is not null then
    perform public.send_outbox_row(v_id);
  end if;
  return v_id;
end;
$$;

revoke execute on function public.enqueue_notification(uuid, text, text, text, text, text, jsonb, uuid)
  from public, anon, authenticated;

-- ---- Whether a queued event still matters --------------------------------------
-- "Your driver has arrived" is not worth resending once the trip started.
create or replace function public.notification_still_relevant(r public.notification_outbox)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.ride_requests;
begin
  if r.request_id is null then
    return true;
  end if;
  select * into v from public.ride_requests where id = r.request_id;
  if not found then
    return false;
  end if;
  if r.data ? 'status' and v.status is distinct from r.data->>'status' then
    return false;
  end if;
  if r.data ? 'payment_status' and v.payment_status is distinct from r.data->>'payment_status' then
    return false;
  end if;
  if r.data->>'type' = 'ride_cancel_request' and v.cancel_requested_at is null then
    return false;
  end if;
  return true;
end;
$$;

revoke execute on function public.notification_still_relevant(public.notification_outbox) from public, anon, authenticated;

-- ---- The dispatcher (pg_cron, every 15 s) ----------------------------------------
create or replace function public.dispatch_notification_outbox()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.notification_outbox;
  n int := 0;
begin
  -- What expired or stopped mattering is closed off first.
  update public.notification_outbox
     set next_attempt_at = null, stopped_reason = 'expired'
   where delivered_at is null and next_attempt_at is not null and expires_at <= now();

  for r in
    select * from public.notification_outbox
     where delivered_at is null and next_attempt_at is not null and next_attempt_at <= now()
     order by priority = 'critical' desc, next_attempt_at
     limit 200
  loop
    if not public.notification_still_relevant(r) then
      update public.notification_outbox set next_attempt_at = null, stopped_reason = 'moved_on' where id = r.id;
      continue;
    end if;
    perform public.send_outbox_row(r.id);
    n := n + 1;
  end loop;
  return n;
end;
$$;

revoke execute on function public.dispatch_notification_outbox() from public, anon, authenticated;

-- ---- The app says it has it ---------------------------------------------------------
create or replace function public.ack_notification(p_event_id text, p_state text default 'delivered')
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  if auth.uid() is null then
    return 0;
  end if;
  update public.notification_outbox
     set delivered_at = coalesce(delivered_at, now()),
         read_at = case when p_state = 'read' then coalesce(read_at, now()) else read_at end,
         next_attempt_at = null
   where profile_id = auth.uid() and event_id = p_event_id;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- The trip is on the caller's screen: whatever they were being told about it,
-- they can see.
create or replace function public.ack_ride_notifications(p_request uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  if auth.uid() is null then
    return 0;
  end if;
  update public.notification_outbox
     set delivered_at = coalesce(delivered_at, now()), next_attempt_at = null
   where profile_id = auth.uid() and request_id = p_request and delivered_at is null;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- The app is open and has read the caller's current state.
create or replace function public.ack_pending_notifications()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  if auth.uid() is null then
    return 0;
  end if;
  update public.notification_outbox
     set delivered_at = coalesce(delivered_at, now()), next_attempt_at = null
   where profile_id = auth.uid() and delivered_at is null;
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke execute on function public.ack_notification(text, text) from public, anon;
revoke execute on function public.ack_ride_notifications(uuid) from public, anon;
revoke execute on function public.ack_pending_notifications() from public, anon;
grant execute on function public.ack_notification(text, text) to authenticated;
grant execute on function public.ack_ride_notifications(uuid) to authenticated;
grant execute on function public.ack_pending_notifications() to authenticated;

-- ---- What each side is told when a trip changes -------------------------------------
-- A list of {to: 'rider'|'partner', event, priority, title, body, data}. The
-- side that made the change ([p_actor]) is not told about it; a change made
-- server-side (null actor) tells both.
create or replace function public.ride_status_messages(o public.ride_requests, n public.ride_requests, p_actor uuid)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  out jsonb := '[]'::jsonb;
  v_plate text := coalesce(nullif(btrim(n.partner_plate), ''), 'your car');
  v_driver text := coalesce(nullif(btrim(n.partner_name), ''), 'Your driver');
  v_pickup text := coalesce(nullif(n.pickup_name, ''), nullif(n.pickup_address, ''), 'the pickup');
  v_rider_is_actor boolean := p_actor is not null and p_actor = n.rider_id;
  v_partner_is_actor boolean := p_actor is not null and p_actor = n.partner_id;
  v_ts text;
begin
  if n.status is distinct from o.status then
    if n.status = 'accepted' and n.partner_id is not null then
      if not v_rider_is_actor then
        out := out || jsonb_build_array(jsonb_build_object(
          'to', 'rider', 'event', n.id || ':accepted:r', 'priority', 'critical',
          'title', 'Driver assigned',
          'body', v_driver || ' is on the way in ' || v_plate || '.',
          'data', jsonb_build_object('type', 'ride_status', 'request_id', n.id, 'status', 'accepted', 'role', 'rider')));
      end if;
      if not v_partner_is_actor then
        out := out || jsonb_build_array(jsonb_build_object(
          'to', 'partner', 'event', n.id || ':accepted:p', 'priority', 'critical',
          'title', 'Ride confirmed',
          'body', 'Pick up at ' || v_pickup || '.',
          'data', jsonb_build_object('type', 'ride_status', 'request_id', n.id, 'status', 'accepted', 'role', 'partner')));
      end if;
    elsif n.status = 'arrived' and not v_rider_is_actor then
      out := out || jsonb_build_array(jsonb_build_object(
        'to', 'rider', 'event', n.id || ':arrived:r', 'priority', 'critical',
        'title', 'Your driver has arrived',
        'body', v_plate || ' is waiting at ' || v_pickup || '.',
        'data', jsonb_build_object('type', 'ride_status', 'request_id', n.id, 'status', 'arrived', 'role', 'rider')));
    elsif n.status = 'on_trip' and not v_rider_is_actor then
      out := out || jsonb_build_array(jsonb_build_object(
        'to', 'rider', 'event', n.id || ':on_trip:r', 'priority', 'normal',
        'title', 'Trip started',
        'body', 'Enjoy your ride. You can share your trip from the app.',
        'data', jsonb_build_object('type', 'ride_status', 'request_id', n.id, 'status', 'on_trip', 'role', 'rider')));
    elsif n.status = 'cancelled' and n.partner_id is not null
          and o.status in ('accepted', 'arrived', 'on_trip') then
      if not v_rider_is_actor then
        out := out || jsonb_build_array(jsonb_build_object(
          'to', 'rider', 'event', n.id || ':cancelled:r', 'priority', 'critical',
          'title', 'Trip cancelled',
          'body', 'Your trip was cancelled. Open the app to book again.',
          'data', jsonb_build_object('type', 'ride_status', 'request_id', n.id, 'status', 'cancelled', 'role', 'rider')));
      end if;
      if not v_partner_is_actor then
        out := out || jsonb_build_array(jsonb_build_object(
          'to', 'partner', 'event', n.id || ':cancelled:p', 'priority', 'critical',
          'title', 'Trip cancelled',
          'body', 'The passenger''s trip was cancelled. You are free for the next one.',
          'data', jsonb_build_object('type', 'ride_status', 'request_id', n.id, 'status', 'cancelled', 'role', 'partner')));
      end if;
    end if;
  elsif n.status in ('accepted', 'arrived', 'on_trip') then
    -- A cancellation asked for: the other side answers it.
    if n.cancel_requested_at is not null and o.cancel_requested_at is null then
      v_ts := extract(epoch from n.cancel_requested_at)::bigint::text;
      out := out || jsonb_build_array(jsonb_build_object(
        'to', case when n.cancel_requested_by = 'rider' then 'partner' else 'rider' end,
        'event', n.id || ':cr:' || v_ts, 'priority', 'critical',
        'title', 'Cancellation requested',
        'body', case when n.cancel_requested_by = 'rider'
                  then 'Your passenger asked to cancel. Open the app to answer.'
                  else 'Your driver asked to cancel. Open the app to answer.' end,
        'data', jsonb_build_object('type', 'ride_cancel_request', 'request_id', n.id,
                                   'role', case when n.cancel_requested_by = 'rider' then 'partner' else 'rider' end)));
    elsif n.cancel_requested_at is null and o.cancel_requested_at is not null then
      v_ts := extract(epoch from o.cancel_requested_at)::bigint::text;
      out := out || jsonb_build_array(jsonb_build_object(
        'to', case when o.cancel_requested_by = 'rider' then 'rider' else 'partner' end,
        'event', n.id || ':cd:' || v_ts, 'priority', 'normal',
        'title', 'Cancellation declined',
        'body', 'The ride continues.',
        'data', jsonb_build_object('type', 'ride_status', 'request_id', n.id, 'status', n.status,
                                   'role', case when o.cancel_requested_by = 'rider' then 'rider' else 'partner' end)));
    end if;
  end if;
  return out;
end;
$$;

revoke execute on function public.ride_status_messages(public.ride_requests, public.ride_requests, uuid)
  from public, anon, authenticated;

create or replace function public.notify_ride_status_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  m jsonb;
  v_to uuid;
begin
  for m in select value from jsonb_array_elements(public.ride_status_messages(old, new, auth.uid())) loop
    v_to := case m->>'to' when 'rider' then new.rider_id else new.partner_id end;
    perform public.enqueue_notification(
      v_to, m->>'event', 'ride_status', m->>'priority', m->>'title', m->>'body', m->'data', new.id);
  end loop;
  return new;
exception when others then
  return new;
end;
$$;

revoke execute on function public.notify_ride_status_push() from public, anon, authenticated;

create or replace trigger trg_ride_requests_status_push
  after update of status, cancel_requested_at on public.ride_requests
  for each row execute function public.notify_ride_status_push();

-- ---- 0142's payment pushes, through the outbox ---------------------------------------
create or replace function public.notify_ride_payment_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  m jsonb;
  v_to uuid;
begin
  for m in select value from jsonb_array_elements(public.ride_payment_messages(old, new)) loop
    v_to := case m->>'to' when 'rider' then new.rider_id else new.partner_id end;
    perform public.enqueue_notification(
      v_to,
      new.id || ':pay:' || coalesce(new.payment_status, '') || ':' || left(m->>'to', 1),
      'ride_payment',
      case when new.payment_status in ('due', 'cash_pending') then 'critical' else 'normal' end,
      m->>'title', m->>'body',
      (m->'data') || jsonb_build_object('payment_status', new.payment_status),
      new.id);
  end loop;
  return new;
exception when others then
  return new;
end;
$$;

-- ---- How well it is working (admin) -------------------------------------------------
create or replace function public.notification_delivery_stats(p_hours int default 24)
returns table (
  kind text,
  priority text,
  sent bigint,
  delivered bigint,
  pending bigint,
  gave_up bigint,
  avg_ack_seconds numeric,
  avg_attempts numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized';
  end if;
  return query
  select o.kind, o.priority,
         count(*),
         count(*) filter (where o.delivered_at is not null),
         count(*) filter (where o.delivered_at is null and o.next_attempt_at is not null),
         count(*) filter (where o.delivered_at is null and o.next_attempt_at is null),
         round(avg(extract(epoch from o.delivered_at - o.created_at))::numeric, 1),
         round(avg(o.attempts)::numeric, 2)
    from public.notification_outbox o
   where o.created_at > now() - make_interval(hours => greatest(1, least(coalesce(p_hours, 24), 24 * 30)))
   group by o.kind, o.priority
   order by o.kind, o.priority;
end;
$$;

revoke execute on function public.notification_delivery_stats(int) from public, anon;
grant execute on function public.notification_delivery_stats(int) to authenticated;

-- The admin's delivery card follows it live (rows are visible to their owner
-- and to admins only).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
        where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notification_outbox'
     ) then
    alter publication supabase_realtime add table public.notification_outbox;
  end if;
end $$;

-- ---- Schedule -----------------------------------------------------------------------
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule(
    'dispatch-notification-outbox',
    '15 seconds',
    $cmd$ select public.dispatch_notification_outbox(); $cmd$
  );
  -- A week of rows is plenty for the stats.
  perform cron.schedule(
    'prune-notification-outbox',
    '17 3 * * *',
    $cmd$ delete from public.notification_outbox where created_at < now() - interval '7 days'; $cmd$
  );
exception
  when undefined_table or undefined_file or undefined_function or feature_not_supported or insufficient_privilege then
    raise notice 'pg_cron not available, so the outbox is not retried on a schedule. Call public.dispatch_notification_outbox() from a scheduled job instead.';
end$$;

notify pgrst, 'reload schema';
