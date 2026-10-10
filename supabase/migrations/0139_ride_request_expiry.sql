-- ============================================================================
-- 0139: an open request expires on its own
--
-- A request nobody took used to expire only when a screen noticed: the
-- rider's tracking screen at 7 minutes, or the next time the app listed the
-- rider's rides. A rider who left the app saw "Finding a driver" long after
-- the search was over, and the expiry notice only when they opened the ride.
--
-- Now the database does it:
--   * expire_open_ride_requests() moves every request still open after 7
--     minutes (REQUEST_EXPIRY_MS / AppConfig.requestExpiry) to `expired`;
--   * pg_cron runs it every minute, so the change reaches every open screen
--     through realtime within a minute, app open or not;
--   * the rider gets a push when their request expires, so a closed app
--     hears about it too (type `ride_expired`, opening the home screen).
-- The apps still expire their own request on time while they are open; this
-- is what happens when nobody is looking.
-- ============================================================================

create or replace function public.expire_open_ride_requests()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  update public.ride_requests
     set status = 'expired'
   where status = 'open'
     and created_at < now() - interval '7 minutes';
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke execute on function public.expire_open_ride_requests() from public, anon, authenticated;
grant execute on function public.expire_open_ride_requests() to service_role;

-- {title, body, data} of the push for a request that just expired, or null.
create or replace function public.ride_expired_message(p_old_status text, p_new_status text, p_request_id uuid)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when p_old_status = 'open' and p_new_status = 'expired' then jsonb_build_object(
      'title', 'No driver found',
      'body', 'Your ride request expired. Open GET.ride to try again.',
      'data', jsonb_build_object('type', 'ride_expired', 'request_id', p_request_id)
    )
  end;
$$;

create or replace function public.notify_ride_expired_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  m jsonb := public.ride_expired_message(old.status, new.status, new.id);
begin
  if m is not null and new.rider_id is not null then
    perform public.send_push_webhook(m || jsonb_build_object('profileId', new.rider_id));
  end if;
  return new;
exception when others then
  return new;
end;
$$;

revoke execute on function public.notify_ride_expired_push() from public, anon, authenticated;

create or replace trigger trg_ride_requests_expired_push after update of status on public.ride_requests
  for each row execute function public.notify_ride_expired_push();

-- Every minute. Guarded as 0097's daily job is: a Postgres without pg_cron
-- (local, CI) gets a notice instead of failing the migration.
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule(
    'expire-open-ride-requests',
    '* * * * *',
    $cmd$ select public.expire_open_ride_requests(); $cmd$
  );
exception
  when undefined_table or undefined_file or undefined_function or feature_not_supported or insufficient_privilege then
    raise notice 'pg_cron not available, so open requests are not expired on a schedule. Call public.expire_open_ride_requests() from a scheduled job instead.';
end$$;

notify pgrst, 'reload schema';
