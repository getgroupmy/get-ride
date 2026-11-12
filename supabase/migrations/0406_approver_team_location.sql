-- ============================================================================
-- 0406 — Team Location: an approver's God View of their own team.
--
-- Admins have God View (0270+): a live map of where people are. Approvers run
-- "My Team" (0350+) — the partners/users they cover (approver_covers) — but
-- could not see them on a map. This is that map, scoped to exactly the people
-- the approver already covers, reusing God View's own people generator.
--
-- This slice is the server foundation (slice 1 of the feature):
--   * approvers.can_view_location — a new grant, off by default, like
--     can_credit (0359) / can_manage_vehicle (0366). approver_self() surfaces
--     it so the app can gate the Team Location entry.
--   * approver_may_see_location(profile) — the per-person gate the later
--     per-person RPCs (trail / ping / reveal / live) will call: the caller is
--     an approver with the grant AND covers that profile.
--   * approver_team_snapshot(...) — the map + list, a team-scoped twin of
--     god_view_snapshot: it runs the same god_view_people generator UNSCOPED
--     (no region), then keeps only rows the approver covers (approver_covers),
--     with the same row shape and counts the God View UI already reads.
--
-- Privacy: the snapshot is a "look" at the map, which God View itself does not
-- log (only per-person actions — reveal phone, trail, ping, live — are logged,
-- and those approver-scoped RPCs land in a later slice, logging to
-- admin_audit_log and opening a my_live_share session so the person still sees
-- the "shared live" notice, exactly as God View does). Nothing here is hidden
-- or covert: it only ever shows people the approver already manages.
-- ============================================================================

-- ---- 0. The grant -------------------------------------------------------------------------------
alter table public.approvers
  add column if not exists can_view_location boolean not null default false;
comment on column public.approvers.can_view_location is
  'The approver may open Team Location — a God View of the team they cover (0406).';

-- approver_self() with the new flag (sql body, same as 0366 plus can_view_location).
create or replace function public.approver_self()
returns jsonb
language sql
stable
security definer
set search_path = 'public'
as $$
  select jsonb_build_object(
           'can_approve', a.can_approve, 'can_upload', a.can_upload,
           'can_delete', a.can_delete, 'delete_hard', a.delete_hard,
           'can_credit', a.can_credit, 'can_edit_profile', a.can_edit_profile,
           'can_verify_id', a.can_verify_id, 'can_manage_vehicle', a.can_manage_vehicle,
           'can_view_location', a.can_view_location,
           'scope', a.scope, 'doc_types', to_jsonb(a.doc_types))
    from public.approvers a
   where a.profile_id = auth.uid() and a.active and (a.ends_at is null or a.ends_at > now());
$$;

-- ---- 1. The per-person gate (for the later trail / ping / reveal / live RPCs) --------------------
-- The caller is an approver with the location grant, and covers this person.
create or replace function public.approver_may_see_location(p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_profile is not null
     and exists (select 1 from public.approvers a
                  where a.profile_id = auth.uid() and a.active
                    and (a.ends_at is null or a.ends_at > now())
                    and a.can_view_location)
     and public.approver_covers(p_profile);
$$;
revoke execute on function public.approver_may_see_location(uuid) from public, anon;
grant execute on function public.approver_may_see_location(uuid) to authenticated;

-- ---- 2. The map + list --------------------------------------------------------------------------
-- A team-scoped twin of god_view_snapshot (0285): the same god_view_people
-- generator, run unscoped, then filtered to the people the approver covers.
-- Same row shape and the counts the God View UI already consumes.
create or replace function public.approver_team_snapshot(
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
  v_box double precision[];
  v_limit int := least(greatest(coalesce(p_limit, 1500), 1), 3000);
  v jsonb;
begin
  if not exists (select 1 from public.approvers a
                  where a.profile_id = auth.uid() and a.active
                    and (a.ends_at is null or a.ends_at > now())
                    and a.can_view_location) then
    raise exception 'You do not have Team Location.' using errcode = '42501';
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
      from public.god_view_people(v_box, p_show_offline, p_query, null, false, null, null) g
     where public.approver_covers(g.id)
  )
  select jsonb_build_object(
    'at', now(),
    'scoped', true,
    'people_mode', 'team',
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
revoke execute on function public.approver_team_snapshot(double precision, double precision, double precision,
  double precision, boolean, text, integer) from public, anon;
grant execute on function public.approver_team_snapshot(double precision, double precision, double precision,
  double precision, boolean, text, integer) to authenticated;

notify pgrst, 'reload schema';
