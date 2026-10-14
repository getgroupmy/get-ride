-- ============================================================================
-- 0186: the server decides who drives, and old traces are cleared
-- (audit 14 Oct 2026).
--
--   1. Going online only checked that a partner row existed: an unapproved,
--      rejected or blocked driver was "online" and pushed ride requests
--      (only the app's own check, which lets the driver through when it
--      fails, stood in the way). Now only an approved driver is online.
--   2. claim_vehicle took any vehicle the caller owned or was assigned,
--      approved or not. Now only an approved vehicle (approved or
--      permit-verified, as the app) can be driven.
--   3. Retention: the location trail (one point per 30 s per signed-in
--      user) is kept 90 days, pg_cron's run log 7 days. Both grew forever.
-- ============================================================================

-- ---- 1. Online is for approved drivers ---------------------------------------------
create or replace function public.set_driver_presence(
  p_online boolean,
  p_lat double precision default null,
  p_lng double precision default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lat double precision := case when p_lat between -90 and 90 then p_lat end;
  v_lng double precision := case when p_lng between -180 and 180 then p_lng end;
begin
  if auth.uid() is null then
    raise exception 'not_authorized';
  end if;
  -- Only a driver has a presence.
  if not exists (select 1 from public.partners where auth_user_id = auth.uid()) then
    return;
  end if;
  -- Online is for approved drivers: anyone else is recorded offline, so
  -- they get no ride pushes (and the claim guard already refuses their
  -- claims). Quietly, so an older app shows no error.
  insert into public.driver_presence (profile_id, online, lat, lng, updated_at)
  values (auth.uid(), coalesce(p_online, false) and public.caller_is_approved_partner(), v_lat, v_lng, now())
  on conflict (profile_id) do update
    set online = excluded.online,
        -- A report without a fix keeps the last known position.
        lat = coalesce(excluded.lat, driver_presence.lat),
        lng = coalesce(excluded.lng, driver_presence.lng),
        updated_at = now();
end;
$$;

revoke execute on function public.set_driver_presence(boolean, double precision, double precision) from public, anon;
grant execute on function public.set_driver_presence(boolean, double precision, double precision) to authenticated;

-- An approved driver blocked or rejected while online goes offline at once.
update public.driver_presence d set online = false
 where d.online and not exists (
   select 1 from public.partners p
    where p.auth_user_id = d.profile_id and (p.status = 'approved' or p.status::text like 'permit-%'));

create or replace function public.partners_offline_unless_approved()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (new.status = 'approved' or new.status::text like 'permit-%') and new.auth_user_id is not null then
    update public.driver_presence set online = false where profile_id = new.auth_user_id and online;
  end if;
  return new;
end;
$$;
revoke execute on function public.partners_offline_unless_approved() from public, anon, authenticated;

drop trigger if exists trg_partners_offline_unless_approved on public.partners;
create trigger trg_partners_offline_unless_approved
  after update of status on public.partners
  for each row execute function public.partners_offline_unless_approved();

-- ---- 2. Only an approved vehicle is driven -----------------------------------------
create or replace function public.claim_vehicle(
  p_vehicle_id uuid,
  p_user_id    uuid
) returns public.vehicle_active_session
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assignment public.vehicle_user_assignment%rowtype;
  v_session    public.vehicle_active_session%rowtype;
  v_partner_id uuid;
  v_is_owner   boolean := false;
begin
  if p_user_id is distinct from auth.uid() and not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  -- Active explicit assignment?
  select * into v_assignment
    from public.vehicle_user_assignment
   where vehicle_id = p_vehicle_id
     and user_id    = p_user_id
     and is_active  = true
   limit 1;

  if not found then
    -- Owner of the vehicle counts as an implicit active assignee.
    select true into v_is_owner
      from public.vehicle
     where id = p_vehicle_id
       and auth_user_id = p_user_id
     limit 1;

    -- No row leaves v_is_owner NULL, and `not NULL` is not true, so 0035's
    -- `if not v_is_owner` let every caller through.
    if not coalesce(v_is_owner, false) then
      raise exception 'not_assigned'
        using hint = 'User is not an active assignee or owner of this vehicle.';
    end if;
  end if;

  -- Only an approved vehicle is driven (the app offers no other; a direct
  -- call no longer gets round it).
  if not public.caller_is_admin() and not exists (
    select 1 from public.vehicle
     where id = p_vehicle_id and status::text in ('approved', 'permit-verified')
  ) then
    raise exception 'vehicle_not_approved'
      using hint = 'This vehicle is not approved to drive.';
  end if;

  -- Vehicle already in use?
  select * into v_session
    from public.vehicle_active_session
   where vehicle_id = p_vehicle_id
   limit 1;

  if found then
    if v_session.user_id = p_user_id then
      update public.vehicle_active_session
         set last_seen_at = now(),
             status       = 'online'
       where id = v_session.id
      returning * into v_session;
      return v_session;
    end if;
    raise exception 'vehicle_in_use'
      using hint = 'Vehicle is currently used by another user.';
  end if;

  -- User already driving something else?
  if exists (
    select 1 from public.vehicle_active_session where user_id = p_user_id
  ) then
    raise exception 'user_busy'
      using hint = 'User is already in an active session on another vehicle.';
  end if;

  v_partner_id := v_assignment.partner_id;

  insert into public.vehicle_active_session (vehicle_id, user_id, partner_id)
       values (p_vehicle_id, p_user_id, v_partner_id)
    returning * into v_session;

  return v_session;
end;
$$;

revoke execute on function public.claim_vehicle(uuid, uuid) from public, anon;
grant execute on function public.claim_vehicle(uuid, uuid) to authenticated;

-- ---- 3. Retention -------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'purge-location-history';
    perform cron.schedule('purge-location-history', '41 3 * * *',
      $job$delete from public.user_location_history where created_at < now() - interval '90 days'$job$);
    perform cron.unschedule(jobid) from cron.job where jobname = 'purge-cron-run-log';
    perform cron.schedule('purge-cron-run-log', '47 3 * * *',
      $job$delete from cron.job_run_details where end_time < now() - interval '7 days'$job$);
  end if;
end $$;
