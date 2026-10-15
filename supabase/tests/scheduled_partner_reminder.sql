-- ============================================================================
-- Regression test for migration 0197: the driver who accepted a scheduled
-- ride is reminded once before pickup, ahead of release; a driver who takes
-- over the booking is reminded too.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/scheduled_partner_reminder.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000197a1'),  -- rider
  ('00000000-0000-0000-0000-0000000197b1'),  -- driver
  ('00000000-0000-0000-0000-0000000197b2')   -- the driver who takes over
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000197%'
on conflict do nothing;

update public.app_settings
   set value = value || '{"reminderMinutes": 60, "releaseMinutes": 20}'::jsonb
 where key = 'scheduled_rides';

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.reminders(p uuid) returns int language sql as $$
  select count(*)::int from public.notification_outbox
   where profile_id = p and event_id like 'sched-partner-remind-%'
$$;

-- Due (45 min away), not yet due (3 h away), and one past its reminder
-- window that is about to be released (10 min away).
insert into public.scheduled_rides (id, rider_id, pickup_at, status, request, fare, partner_id, pickup_address) values
  ('00000000-0000-0000-0000-0000000197d1', '00000000-0000-0000-0000-0000000197a1',
   now() + interval '45 minutes', 'assigned', '{}', 20, '00000000-0000-0000-0000-0000000197b1', 'KLCC'),
  ('00000000-0000-0000-0000-0000000197d2', '00000000-0000-0000-0000-0000000197a1',
   now() + interval '3 hours', 'assigned', '{}', 20, '00000000-0000-0000-0000-0000000197b1', null),
  ('00000000-0000-0000-0000-0000000197d3', '00000000-0000-0000-0000-0000000197a1',
   now() + interval '10 minutes', 'assigned', '{}', 20, '00000000-0000-0000-0000-0000000197b1', null);

-- 1. Reminded once, for the booking that is due -----------------------------------------
select public.scheduled_rides_partner_reminders();
select public.scheduled_rides_partner_reminders();
select pg_temp.check(pg_temp.reminders('00000000-0000-0000-0000-0000000197b1') = 1, 'one reminder, sent once');
select pg_temp.check((select data ->> 'role' = 'partner' and data ->> 'type' = 'scheduled_reminder'
                             and body like '%KLCC%'
                        from public.notification_outbox
                       where profile_id = '00000000-0000-0000-0000-0000000197b1'
                         and event_id like 'sched-partner-remind-%'), 'opens the driver''s side, says where');

-- 2. A driver who takes it over is reminded too ----------------------------------------
update public.scheduled_rides set partner_id = '00000000-0000-0000-0000-0000000197b2'
 where id = '00000000-0000-0000-0000-0000000197d1';
select public.scheduled_rides_partner_reminders();
select pg_temp.check(pg_temp.reminders('00000000-0000-0000-0000-0000000197b2') = 1, 'the new driver is reminded');

-- 3. Off, or no earlier than release: nothing -----------------------------------------
update public.scheduled_rides set pickup_at = now() + interval '30 minutes', partner_reminded_id = null
 where id = '00000000-0000-0000-0000-0000000197d2';
update public.app_settings set value = value || '{"reminderMinutes": 15}'::jsonb where key = 'scheduled_rides';
select public.scheduled_rides_partner_reminders();
select pg_temp.check(pg_temp.reminders('00000000-0000-0000-0000-0000000197b1') = 1,
  'a reminder after release is not sent');

select 'scheduled_partner_reminder: all passed';
rollback;
