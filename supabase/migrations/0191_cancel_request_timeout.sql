-- ============================================================================
-- 0191: a cancellation request no longer waits forever.
--
-- Once a driver has the ride, either side asks to cancel and the other side
-- answers (cancel_requested_at / _by). Until now an unanswered request
-- stayed open for the rest of the trip. Now it lapses after the admin's time
-- (Admin -> App Settings -> Trip cancellation, default 2 minutes): the ride
-- carries on, and the side that asked is told nobody answered, so they can
-- ask again, contact support, or use SOS. The ride is never cancelled on its
-- own: the passenger may still be in the car.
--
-- A request that is declined or lapses is recorded on the ride
-- (cancel_request_outcome) and, when the admin keeps it on, opens a support
-- ticket for the side that asked, so ops sees the disputed trip.
-- ============================================================================

-- ---- Settings ----------------------------------------------------------------------------
insert into public.app_settings (key, value)
values ('ride_cancel_request', jsonb_build_object('timeoutSeconds', 120, 'openTicket', true))
on conflict (key) do nothing;

create or replace function public.ride_cancel_request_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'timeoutSeconds', least(1800, greatest(30, coalesce(
      case when jsonb_typeof(v->'timeoutSeconds') = 'number' then (v->>'timeoutSeconds')::numeric end, 120)))::int,
    'openTicket', coalesce((v->>'openTicket')::boolean, true))
  from (select (select value from public.app_settings where key = 'ride_cancel_request') as v) s;
$$;
revoke execute on function public.ride_cancel_request_config() from public;
grant execute on function public.ride_cancel_request_config() to anon, authenticated;

create or replace function public.set_ride_cancel_request_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.caller_is_admin() then
    raise exception 'Only an admin can change trip cancellation.' using errcode = '42501';
  end if;
  insert into public.app_settings (key, value, updated_at) values ('ride_cancel_request', coalesce(p_config, '{}'), now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  v := public.ride_cancel_request_config();
  update public.app_settings set value = v where key = 'ride_cancel_request';
  return v;
end;
$$;
revoke execute on function public.set_ride_cancel_request_config(jsonb) from public, anon;
grant execute on function public.set_ride_cancel_request_config(jsonb) to authenticated;

-- ---- What became of a request ---------------------------------------------------------------
alter table public.ride_requests
  add column if not exists cancel_request_outcome text
    check (cancel_request_outcome is null or cancel_request_outcome in ('declined', 'expired')),
  add column if not exists cancel_request_outcome_by text,
  add column if not exists cancel_request_outcome_at timestamptz,
  add column if not exists cancel_ticket_id uuid;

-- Not a definer function: current_user is the caller, so a client can't
-- write the outcome itself; the server's own updates pass.
create or replace function public.ride_requests_cancel_outcome()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.cancel_requested_at is not null and new.cancel_requested_at is distinct from old.cancel_requested_at then
    -- Asked (again): no outcome yet.
    new.cancel_request_outcome := null;
    new.cancel_request_outcome_by := null;
    new.cancel_request_outcome_at := null;
  elsif old.cancel_requested_at is not null and new.cancel_requested_at is null
        and new.status = old.status and new.status in ('accepted', 'arrived', 'on_trip') then
    -- Taken back without the ride ending: lapsed (the server's job) or declined.
    new.cancel_request_outcome := case when current_setting('getride.cancel_lapsing', true) = '1'
                                       then 'expired' else 'declined' end;
    new.cancel_request_outcome_by := old.cancel_requested_by;
    new.cancel_request_outcome_at := now();
  elsif current_user in ('anon', 'authenticated') and not public.caller_is_admin() then
    new.cancel_request_outcome := old.cancel_request_outcome;
    new.cancel_request_outcome_by := old.cancel_request_outcome_by;
    new.cancel_request_outcome_at := old.cancel_request_outcome_at;
    new.cancel_ticket_id := old.cancel_ticket_id;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_cancel_outcome() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_c_cancel_outcome on public.ride_requests;
create trigger trg_ride_requests_c_cancel_outcome
  before update on public.ride_requests
  for each row execute function public.ride_requests_cancel_outcome();

-- ---- The ticket for ops ----------------------------------------------------------------------
create or replace function public.ride_requests_cancel_ticket()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile uuid;
  v_ticket uuid;
  v_text text;
begin
  if new.cancel_request_outcome is null
     or (old.cancel_request_outcome is not distinct from new.cancel_request_outcome
         and old.cancel_request_outcome_at is not distinct from new.cancel_request_outcome_at)
     or not (public.ride_cancel_request_config()->>'openTicket')::boolean then
    return null;
  end if;
  v_profile := case when new.cancel_request_outcome_by = 'rider' then new.rider_id else new.partner_id end;
  if v_profile is null then
    return null;
  end if;

  v_text := format('Automatic note: your request to cancel the trip from %s to %s was %s at %s. '
                   'Our team has been told and will look at it. Reply here if you need help.',
                   coalesce(new.pickup_name, 'pickup'), coalesce(new.drop_name, 'destination'),
                   case when new.cancel_request_outcome = 'expired'
                        then 'not answered by the ' || case when new.cancel_request_outcome_by = 'rider' then 'driver' else 'passenger' end
                        else 'declined by the ' || case when new.cancel_request_outcome_by = 'rider' then 'driver' else 'passenger' end end,
                   to_char(now() at time zone 'Asia/Kuala_Lumpur', 'DD Mon HH24:MI'));

  -- One ticket per ride while it is open; later events add to it.
  select id into v_ticket from public.support_tickets
   where id = new.cancel_ticket_id and profile_id = v_profile and status <> 'closed';
  if v_ticket is null then
    insert into public.support_tickets (profile_id, subject, status, last_message, last_message_at,
                                        last_sender_role, unread_admin, unread_user)
    values (v_profile, 'Trip cancellation ' || case when new.cancel_request_outcome = 'expired'
                                                    then 'not answered' else 'declined' end,
            'open', v_text, now(), 'admin', 1, 1)
    returning id into v_ticket;
    update public.ride_requests set cancel_ticket_id = v_ticket where id = new.id;
  else
    update public.support_tickets
       set last_message = v_text, last_message_at = now(), last_sender_role = 'admin',
           unread_admin = unread_admin + 1, unread_user = unread_user + 1, updated_at = now()
     where id = v_ticket;
  end if;
  insert into public.support_messages (ticket_id, sender_role, sender_name, type, body)
  values (v_ticket, 'admin', 'GET.ride', 'text', v_text);
  return null;
end;
$$;
revoke execute on function public.ride_requests_cancel_ticket() from public, anon, authenticated;

drop trigger if exists trg_ride_requests_cancel_ticket on public.ride_requests;
create trigger trg_ride_requests_cancel_ticket
  after update of cancel_requested_at on public.ride_requests
  for each row execute function public.ride_requests_cancel_ticket();

-- ---- The push says which it was ----------------------------------------------------------------
create or replace function public.ride_status_messages(o ride_requests, n ride_requests, p_actor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
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
        'title', case when n.cancel_request_outcome = 'expired' then 'No answer to your cancellation'
                      else 'Cancellation declined' end,
        'body', case when n.cancel_request_outcome = 'expired'
                     then case when o.cancel_requested_by = 'rider'
                               then 'Your driver didn''t respond. Ask again, contact support, or use SOS.'
                               else 'Your passenger didn''t respond. Ask again or contact support.' end
                     else 'The ride continues.' end,
        'data', jsonb_build_object('type', 'ride_status', 'request_id', n.id, 'status', n.status,
                                   'role', case when o.cancel_requested_by = 'rider' then 'rider' else 'partner' end)));
    end if;
  end if;
  return out;
end;
$function$;

-- ---- Lapse unanswered requests -----------------------------------------------------------------
create or replace function public.ride_cancel_requests_lapse()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  perform set_config('getride.cancel_lapsing', '1', true);
  update public.ride_requests
     set cancel_requested_at = null, cancel_requested_by = null
   where cancel_requested_at is not null
     and status in ('accepted', 'arrived', 'on_trip')
     and cancel_requested_at < now() - make_interval(
           secs => (public.ride_cancel_request_config()->>'timeoutSeconds')::int);
  get diagnostics n = row_count;
  perform set_config('getride.cancel_lapsing', '', true);
  return n;
end;
$$;
revoke execute on function public.ride_cancel_requests_lapse() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'lapse-ride-cancel-requests';
    perform cron.schedule('lapse-ride-cancel-requests', '* * * * *', $job$select public.ride_cancel_requests_lapse()$job$);
  end if;
end $$;
