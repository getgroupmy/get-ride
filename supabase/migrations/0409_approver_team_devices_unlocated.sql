-- ============================================================================
-- 0409: Team Location reaches full God View parity — the device/battery/network
-- panel and the "No location" list, scoped to the approver's team.
--
-- Slice 5 reuses the God View screen itself for Team Location (teamScoped), so
-- it needs the same two reads God View's body makes, team-scoped:
--
--   * god_view_devices — widened like 0408's locate functions: an approver who
--     covers the member (approver_may_see_location) may read their devices, the
--     same gate God View uses. (Powers the person sheet's Device/Battery/Network
--     and the "centre on this device" panel.)
--
--   * approver_team_unlocated(query, limit) — the team-scoped twin of
--     god_view_unlocated: everyone the approver COVERS (approver_covers) who is
--     not currently on the map, with the same reason vocabulary (no_app /
--     never_located / stale) and the SAME RETURNS TABLE shape god_view_unlocated
--     has, so the God View People panel renders it unchanged. It drops God
--     View's admin region-scoping machinery (god_view_caller / people_rule /
--     region polys) and gates on the approver grant + approver_covers instead.
-- ============================================================================

-- ---- god_view_devices: widen the gate to a covering approver -------------------------------------
create or replace function public.god_view_devices(p_profile_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $function$
declare
  v_devices jsonb;
begin
  if p_profile_id is null or not (public.god_view_may_see(p_profile_id) or public.approver_may_see_location(p_profile_id)) then
    raise exception 'You can only see the devices of someone on your map.' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(d order by d.located_at desc nulls last), '[]'::jsonb)
    into v_devices
    from (
      select distinct on (coalesce(t.device_key, t.id::text)) jsonb_build_object(
               'device_key', t.device_key,
               'token_id', t.id,
               'platform', t.platform,
               'lat', t.last_lat,
               'lng', t.last_lng,
               'located_at', t.located_at,
               'located_bg', t.located_bg,
               'location_always', t.location_always,
               'moved_at', t.moved_at) as d,
             t.located_at
        from public.push_tokens t
       where t.profile_id = p_profile_id
         and t.last_lat is not null and t.last_lng is not null
       order by coalesce(t.device_key, t.id::text), t.located_at desc nulls last
    ) d;
  return jsonb_build_object('profile_id', p_profile_id, 'devices', v_devices, 'now', now());
end;
$function$;

-- ---- approver_team_unlocated: the team-scoped "No location" list ---------------------------------
create or replace function public.approver_team_unlocated(p_query text default null, p_limit integer default 500)
returns table(kind text, id uuid, partner_row_id uuid, name text, vehicle text, plate text,
              reason text, last_seen_at timestamptz, app_version text, app_platform text, token_platform text)
language plpgsql stable security definer set search_path to '' as $function$
declare
  v_t text := nullif(btrim(lower(coalesce(p_query, ''))), '');
  v_digits text := nullif(regexp_replace(coalesce(p_query, ''), '\D', '', 'g'), '');
  v_limit int := least(greatest(coalesce(p_limit, 500), 1), 2000);
  v_week timestamptz := now() - interval '7 days';
begin
  if not exists (select 1 from public.approvers a
                  where a.profile_id = auth.uid() and a.active
                    and (a.ends_at is null or a.ends_at > now()) and a.can_view_location) then
    raise exception 'You do not have Team Location.' using errcode = '42501';
  end if;
  return query
  with
  on_map as (
    select t.profile_id as pid from public.push_tokens t
     where t.profile_id is not null and t.last_lat is not null and t.last_lng is not null and t.located_at > v_week
    union select d.profile_id from public.driver_presence d
     where d.updated_at > v_week and d.lat is not null and d.lng is not null
    union select unnest(array[rr.rider_id, rr.partner_id]) from public.ride_requests rr
     where rr.status in ('open', 'accepted', 'arrived', 'on_trip') and rr.updated_at > now() - interval '12 hours'
    union select unnest(array[s.reporter_id, s.rider_id, s.partner_id]) from public.safety_incidents s
     where s.status in ('open', 'acknowledged')
  ),
  tok as (
    select t.profile_id as pid,
           max(t.located_at) filter (where t.last_lat is not null and t.last_lng is not null) as located_at,
           (array_agg(t.platform order by t.updated_at desc))[1] as platform
      from public.push_tokens t
     where t.profile_id is not null
     group by t.profile_id
  ),
  presence_old as (
    select d.profile_id as pid, d.updated_at
      from public.driver_presence d
     where d.lat is not null and d.lng is not null
  ),
  partner as (
    select distinct on (p.auth_user_id) p.auth_user_id as pid, p.id as partner_row_id, p.name, p.plate,
           coalesce(nullif(btrim(concat_ws(' ', p.make, p.model)), ''), p.vehicle) as vehicle
      from public.partners p
     where p.auth_user_id is not null
     order by p.auth_user_id, p.updated_at desc
  ),
  people as (
    select case when pa.pid is not null then 'partner' else 'user' end as kind,
           pf.id, pa.partner_row_id,
           coalesce(nullif(btrim(pf.name), ''), nullif(btrim(pa.name), '')) as name,
           pa.vehicle, pa.plate,
           case when tk.pid is null then 'no_app'
                when tk.located_at is null and po.pid is null then 'never_located'
                else 'stale' end as reason,
           nullif(greatest(coalesce(tk.located_at, '-infinity'::timestamptz),
                           coalesce(po.updated_at, '-infinity'::timestamptz)), '-infinity'::timestamptz) as last_seen_at,
           nullif(btrim(pf.app_version), '') as app_version,
           nullif(btrim(pf.app_platform), '') as app_platform,
           tk.platform as token_platform,
           pf.phone
      from public.profiles pf
      left join partner pa on pa.pid = pf.id
      left join tok tk on tk.pid = pf.id
      left join presence_old po on po.pid = pf.id
     where pf.deleted_at is null
       and not exists (select 1 from on_map m where m.pid = pf.id)
  )
  select x.kind, x.id, x.partner_row_id, x.name, x.vehicle, x.plate, x.reason, x.last_seen_at,
         x.app_version, x.app_platform, x.token_platform
    from people x
   where public.approver_covers(x.id)
     and (v_t is null
          or lower(coalesce(x.name, '')) like '%' || v_t || '%'
          or replace(lower(coalesce(x.plate, '')), ' ', '') like '%' || replace(v_t, ' ', '') || '%'
          or (length(coalesce(v_digits, '')) >= 4
              and regexp_replace(coalesce(x.phone, ''), '\D', '', 'g') like '%' || v_digits || '%'))
   order by lower(coalesce(x.name, '')), x.id
   limit v_limit;
end;
$function$;
revoke execute on function public.approver_team_unlocated(text, integer) from public, anon;
grant execute on function public.approver_team_unlocated(text, integer) to authenticated;

notify pgrst, 'reload schema';
