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
-- This adds an explicit grace grant an admin runs as part of the rollout:
-- permit_enable_grace(country) gives every currently-approved vehicle of that
-- country that lacks a required permit the country's bypass window, so the fleet
-- keeps earning for the grace days (APAD's 3) and is blocked only after that if
-- the permit still isn't on file. It is deliberately NOT tied to the enforce
-- flag: enforcement itself keeps its plain meaning (on = blocked unless on
-- bypass), and the grace is a separate, auditable step the admin takes when
-- rolling enforcement out — grant the fleet its grace, then switch enforcement
-- on (either order works, since the grant does not depend on enforce being on).

-- The bypass columns are protected by vehicle_permit_bypass_guard, which only
-- lets an admin with the bypass permission change them. The grace grant is that
-- same admin path, and it may touch many rows at once, so the guard is widened
-- to also allow a write flagged by a transaction-local setting that only
-- permit_enable_grace sets (belt-and-braces alongside the admin check it keeps).
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

-- Give every currently-approved vehicle of [p_country] that lacks a required
-- permit the country's bypass window, so switching enforcement on is a soft
-- rollout rather than an instant cut-off. Works whether or not enforcement is
-- already on. Only ever extends a grace (never shortens one already longer) and
-- only touches vehicles that actually lack a required permit, so re-running it
-- or calling it when nothing needs grace is a no-op. Admin-only; returns how
-- many vehicles were graced.
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
  if not public.caller_admin_can_write('rpc:vehicle_permit_bypass') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  v_days := coalesce((public.permit_settings_for(p_country)).bypass_days,
                     (public.permit_settings_for(null)).bypass_days, 3);
  v_until := now() + make_interval(days => v_days);
  -- Let the bypass guard through for this bulk grant only (transaction-local).
  perform set_config('app.permit_enable_grace', '1', true);
  update public.vehicle v
     set permit_bypass_until  = v_until,
         permit_bypass_set_at = now(),
         permit_bypass_set_by = auth.uid()
   where v.status::text = 'approved'
     and (v.permit_bypass_until is null or v.permit_bypass_until < v_until)
     and exists (
       select 1 from public.vehicle_permit_rows(v.id) r
        where r.required
          and coalesce(r.state, '') <> 'with'
          and public.ptr_name(r.country) = public.ptr_name(p_country));
  get diagnostics v_count = row_count;
  perform set_config('app.permit_enable_grace', '', true);
  return v_count;
end;
$$;
revoke execute on function public.permit_enable_grace(text) from public, anon;
grant execute on function public.permit_enable_grace(text) to authenticated;
