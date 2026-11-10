-- Soft rollout for vehicle-permit enforcement.
--
-- Vehicle-permit enforcement (migration 0254) is a hard go-online gate: while a
-- country's permit_country_settings.enforce is on, a vehicle without its
-- required permits can't take rides (the ride_requests trigger blocks accepting
-- a trip and the RLS policy hides open requests). The grace window
-- (vehicle.permit_bypass_until) existed only as a per-vehicle switch an admin
-- flips by hand, so turning enforcement on for a country cut off, in one stroke,
-- every approved vehicle that didn't already have its permit on file — including
-- drivers who are mid-compliance and, in Malaysia's case, waiting on the
-- platform to upload their eVP.
--
-- This adds a soft rollout: when a country's enforcement is switched on, every
-- currently-approved vehicle that the new rule would block is given that
-- country's bypass window automatically, so the fleet keeps earning for the
-- grace days (APAD's 3) and is blocked only after that if the permit still
-- isn't on file. It fires however enforce is set — the admin toggle (a direct
-- upsert), a service-role flip, or a migration — because it hangs off a trigger
-- on the settings row, not off any one write path.

-- The bypass columns are protected by vehicle_permit_bypass_guard, which only
-- lets an admin with the bypass permission change them. The grace grant is a
-- trusted server path, so the guard is widened to also allow a write flagged by
-- a transaction-local setting that only permit_enable_grace sets.
create or replace function public.vehicle_permit_bypass_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('role', true), '') in ('anon', 'authenticated')
     and (new.permit_bypass_until, new.permit_bypass_set_at, new.permit_bypass_set_by)
         is distinct from (old.permit_bypass_until, old.permit_bypass_set_at, old.permit_bypass_set_by)
     and coalesce(current_setting('app.permit_enable_grace', true), '') <> '1'
     and not public.caller_admin_can_write('rpc:vehicle_permit_bypass') then
    raise exception 'VEHICLE_PROTECTED_COLUMN:permit_bypass_until' using errcode = '42501';
  end if;
  return new;
end;
$$;

-- Give every currently-approved vehicle in [p_country] that the country's
-- enforcement would block the country's bypass window, so switching enforcement
-- on is a soft rollout, not an instant cut-off. Returns how many vehicles were
-- graced. Only extends a grace (never shortens one already longer), and only
-- touches vehicles the rule actually blocks right now, so re-running it or
-- calling it when nothing needs grace is a no-op.
create or replace function public.permit_enable_grace(p_country text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_days  integer;
  v_until timestamptz;
  v_count integer := 0;
begin
  v_days := coalesce((public.permit_settings_for(p_country)).bypass_days,
                     (public.permit_settings_for(null)).bypass_days, 3);
  v_until := now() + make_interval(days => v_days);
  -- Let the bypass guard through for this grant only (transaction-local).
  perform set_config('app.permit_enable_grace', '1', true);
  update public.vehicle v
     set permit_bypass_until  = v_until,
         permit_bypass_set_at = now(),
         permit_bypass_set_by = auth.uid()
   where v.status::text = 'approved'
     and (v.permit_bypass_until is null or v.permit_bypass_until < v_until)
     and p_country = any (public.ptr_text_array(public.ptr_vehicle_context(v.id) -> 'countries'))
     and public.vehicle_permit_problem(v.id) is not null;
  get diagnostics v_count = row_count;
  perform set_config('app.permit_enable_grace', '', true);
  return v_count;
end;
$$;
revoke execute on function public.permit_enable_grace(text) from public, anon, authenticated;

-- Fire the grace grant whenever a country's enforcement goes from off to on.
create or replace function public.permit_country_settings_grace()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.enforce, false) and (tg_op = 'INSERT' or coalesce(old.enforce, false) = false) then
    perform public.permit_enable_grace(new.country);
  end if;
  return null;
end;
$$;
revoke execute on function public.permit_country_settings_grace() from public, anon, authenticated;

drop trigger if exists trg_permit_country_settings_grace on public.permit_country_settings;
create trigger trg_permit_country_settings_grace
  after insert or update of enforce on public.permit_country_settings
  for each row execute function public.permit_country_settings_grace();
