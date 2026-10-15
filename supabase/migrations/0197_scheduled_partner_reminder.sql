-- ============================================================================
-- 0197: the driver's reminder before a scheduled ride they accepted.
--
-- Riders are reminded (0189, Admin → App Settings → Scheduled rides →
-- reminder); the driver who took a booking ahead of time only heard at
-- release ("time to go"). Now they get "Scheduled ride coming up" the same
-- reminder time before pickup. Nothing is sent when the reminder would come
-- at or after release (the release message says it), nor with the reminder
-- off. A driver who takes over a booking someone gave up is reminded too:
-- the reminder is kept per driver, not per booking.
--
-- Runs every minute next to scheduled-rides-tick. Independent of 0195.
-- ============================================================================

alter table public.scheduled_rides add column if not exists partner_reminded_id uuid;

create or replace function public.scheduled_rides_partner_reminders()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c jsonb := public.scheduled_rides_config();
  v_remind int := (c->>'reminderMinutes')::int;
  v_release int := (c->>'releaseMinutes')::int;
  s record;
begin
  if v_remind <= 0 or v_remind <= v_release then
    return;
  end if;
  for s in
    select id, partner_id, pickup_at, pickup_address
      from public.scheduled_rides
     where status = 'assigned' and partner_id is not null
       and partner_reminded_id is distinct from partner_id
       and pickup_at - make_interval(mins => v_remind) <= now()
       and pickup_at - make_interval(mins => v_release) > now()
     for update skip locked
  loop
    perform public.enqueue_notification(s.partner_id, 'sched-partner-remind-' || s.id || '-' || s.partner_id,
      'scheduled_ride', 'normal', 'Scheduled ride coming up',
      'Pickup at ' || to_char(s.pickup_at at time zone 'Asia/Kuala_Lumpur', 'HH24:MI') ||
      coalesce(', ' || nullif(trim(s.pickup_address), ''), '') ||
      '. It is sent to you ' || v_release || ' minutes before pickup.',
      jsonb_build_object('type', 'scheduled_reminder', 'scheduled_ride_id', s.id, 'role', 'partner'));
    update public.scheduled_rides set partner_reminded_id = s.partner_id where id = s.id;
  end loop;
end;
$$;
revoke execute on function public.scheduled_rides_partner_reminders() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'scheduled-rides-partner-reminders';
    perform cron.schedule('scheduled-rides-partner-reminders', '* * * * *',
      $job$select public.scheduled_rides_partner_reminders()$job$);
  end if;
end $$;
