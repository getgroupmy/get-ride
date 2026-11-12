-- ============================================================================
-- 0408: Team Location per-person actions (slice 3) — an approver with
-- can_view_location may do, to a member they cover, exactly what God View does
-- to anyone: reveal phone, trail, ping, and Live now.
--
-- The design principle here is the same one the Family layer follows ("call
-- the shared functions, never your own copy"): rather than fork the heavy
-- ping / live-share machinery (push-token claiming, location_ping_kick, the
-- god_view_live_sessions table and its my_live_share() notice, point
-- streaming, rate limits), this widens the ONE gate each locate function
-- already has. Each god_view_* locate function gated on
--   not god_view_may_see(profile)
-- now gates on
--   not (god_view_may_see(profile) or approver_may_see_location(profile))
-- so an approver who covers the member and holds the grant (0406) passes the
-- same gate an admin does — and everything downstream (the member's "shared
-- live" notice via my_live_share(), the audit row, the rate limit) is
-- identical. The audit row additionally records detail.via = 'admin' | 'approver'
-- so the owner's log distinguishes an approver's look from an admin's; the
-- actor_id already names who.
--
-- Only the seven LOCATE functions are widened (reveal_phone, trail, ping,
-- ping_answer, live_start, live_stop, live_status). The admin-only actions —
-- suspend, god_view_people's sub-admin scoping, settings — are untouched, so
-- an approver gets location, never God View's write powers.
--
-- Bodies are the deployed definitions verbatim; only the gate line (and, on
-- the audited ones, the detail.via tag) changes. Grants persist across CREATE
-- OR REPLACE, so they are not restated.
-- ============================================================================

-- ---- reveal phone --------------------------------------------------------------------------------
create or replace function public.god_view_reveal_phone(p_profile_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_uid uuid := auth.uid();
  v_phone text;
begin
  if p_profile_id is null or not (public.god_view_may_see(p_profile_id) or public.approver_may_see_location(p_profile_id)) then
    raise exception 'You can only see the phone of someone on your map.' using errcode = '42501';
  end if;
  if v_uid is not null and (select count(*) from public.admin_audit_log l
                             where l.actor_id = v_uid and l.action = 'god_view.reveal_phone'
                               and l.created_at > now() - interval '10 minutes') >= 60 then
    raise exception 'Too many phone numbers shown in 10 minutes. Wait a few minutes and try again.'
      using errcode = 'P0001';
  end if;
  select coalesce(nullif(btrim(pf.phone), ''),
                  (select nullif(btrim(p.phone), '') from public.partners p
                    where p.auth_user_id = p_profile_id order by p.updated_at desc limit 1))
    into v_phone
    from public.profiles pf
   where pf.id = p_profile_id;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'god_view.reveal_phone', p_profile_id,
          jsonb_build_object('found', v_phone is not null,
                             'via', case when public.god_view_may_see(p_profile_id) then 'admin' else 'approver' end));
  return jsonb_build_object('phone', v_phone);
end;
$function$;

-- ---- trail (movement history) --------------------------------------------------------------------
create or replace function public.god_view_trail(p_profile_id uuid, p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_uid uuid := auth.uid();
  v_from timestamptz := greatest(p_from, now() - interval '90 days');
  v_to timestamptz := least(coalesce(p_to, now()), now());
  v_total int;
  v_step int;
  v_points jsonb;
begin
  if p_profile_id is null or not (public.god_view_may_see(p_profile_id) or public.approver_may_see_location(p_profile_id)) then
    raise exception 'You can only see the movement of someone on your map.' using errcode = '42501';
  end if;
  if p_from is null or v_to <= v_from then
    raise exception 'Choose a start time before the end time.' using errcode = '22023';
  end if;
  if v_to - v_from > interval '48 hours' then
    raise exception 'Choose at most 48 hours at a time.' using errcode = '22023';
  end if;

  select count(*) into v_total
    from public.user_location_history h
   where h.user_id = p_profile_id and h.captured_at >= v_from and h.captured_at <= v_to;
  v_step := greatest(1, ceil(v_total / 4000.0)::int);

  select coalesce(jsonb_agg(jsonb_build_array(
           round(x.latitude::numeric, 6), round(x.longitude::numeric, 6),
           floor(extract(epoch from x.captured_at))::bigint, x.speed) order by x.captured_at), '[]'::jsonb)
    into v_points
    from (
      select h.latitude, h.longitude, h.captured_at, h.speed,
             row_number() over (order by h.captured_at) as rn
        from public.user_location_history h
       where h.user_id = p_profile_id and h.captured_at >= v_from and h.captured_at <= v_to
    ) x
   where (x.rn - 1) % v_step = 0 or x.rn = v_total;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'god_view.trail', p_profile_id,
          jsonb_build_object('from', v_from, 'to', v_to, 'points', v_total,
                             'via', case when public.god_view_may_see(p_profile_id) then 'admin' else 'approver' end));

  return jsonb_build_object(
    'from', v_from,
    'to', v_to,
    'total', v_total,
    'thinned', v_step > 1,
    'points', v_points);
end;
$function$;

-- ---- ping ("still there?") -----------------------------------------------------------------------
create or replace function public.god_view_ping(p_profile_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_uid uuid := auth.uid();
  v_phones int;
  v_ids uuid[];
  v_retry timestamptz;
  v_posted boolean := false;
begin
  if p_profile_id is null or not (public.god_view_may_see(p_profile_id) or public.approver_may_see_location(p_profile_id)) then
    raise exception 'You can only ping someone on your map.' using errcode = '42501';
  end if;
  if v_uid is not null and (select count(*) from public.admin_audit_log l
                             where l.actor_id = v_uid and l.action = 'god_view.ping'
                               and l.created_at > now() - interval '10 minutes') >= 60 then
    raise exception 'Too many pings in 10 minutes. Wait a few minutes and try again.' using errcode = 'P0001';
  end if;
  with mine as (
    select t.id, t.ping_sent_at
      from public.push_tokens t
      join public.profiles p on p.id = t.profile_id and p.deleted_at is null
     where t.profile_id = p_profile_id
       and t.bg_key_hash is not null
       and t.location_always
       and t.platform in ('ios', 'android')
       for update of t
  ),
  claimed as (
    update public.push_tokens t
       set ping_sent_at = now()
      from mine m
     where t.id = m.id
       and (m.ping_sent_at is null or m.ping_sent_at < now() - interval '2 minutes')
    returning t.id
  )
  select (select count(*) from mine),
         (select array_agg(c.id order by c.id) from claimed c),
         (select min(m.ping_sent_at) + interval '2 minutes' from mine m
           where m.ping_sent_at >= now() - interval '2 minutes')
    into v_phones, v_ids, v_retry;
  if coalesce(cardinality(v_ids), 0) > 0 then
    v_posted := public.location_ping_kick(v_ids, 'manual');
  end if;
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'god_view.ping', p_profile_id,
          jsonb_build_object('phones', v_phones, 'sent', coalesce(cardinality(v_ids), 0), 'posted', v_posted,
                             'via', case when public.god_view_may_see(p_profile_id) then 'admin' else 'approver' end));
  return jsonb_build_object(
    'phones', v_phones,
    'sent', coalesce(cardinality(v_ids), 0),
    'recent', v_phones - coalesce(cardinality(v_ids), 0),
    'posted', v_posted,
    'sent_at', now(),
    'retry_at', case when coalesce(cardinality(v_ids), 0) = 0 then v_retry end);
end;
$function$;

-- ---- ping answer (poll, not audited) -------------------------------------------------------------
create or replace function public.god_view_ping_answer(p_profile_id uuid, p_since timestamptz)
returns jsonb language plpgsql stable security definer set search_path to '' as $function$
declare
  v_at timestamptz;
  v_details timestamptz;
begin
  if p_profile_id is null or not (public.god_view_may_see(p_profile_id) or public.approver_may_see_location(p_profile_id)) then
    raise exception 'You can only ping someone on your map.' using errcode = '42501';
  end if;
  select max(t.located_at) into v_at
    from public.push_tokens t
   where t.profile_id = p_profile_id;
  select s.captured_at into v_details
    from public.user_sessions s
   where s.user_id = p_profile_id
   order by s.captured_at desc
   limit 1;
  return jsonb_build_object(
    'answered', p_since is not null and v_at >= p_since,
    'located_at', v_at,
    'details', p_since is not null and v_details >= p_since,
    'details_at', v_details);
end;
$function$;

-- ---- live start ----------------------------------------------------------------------------------
create or replace function public.god_view_live_start(p_profile_id uuid, p_minutes integer)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_uid uuid := auth.uid();
  v_minutes int := least(greatest(coalesce(p_minutes, 15), 1), 60);
  v_ids uuid[];
  v_posted boolean := false;
  v_via text := case when public.god_view_may_see(p_profile_id) then 'admin' else 'approver' end;
  s public.god_view_live_sessions;
begin
  if p_profile_id is null or not (public.god_view_may_see(p_profile_id) or public.approver_may_see_location(p_profile_id)) then
    raise exception 'You can only go live with someone on your map.' using errcode = '42501';
  end if;
  if v_uid is not null and (select count(*) from public.admin_audit_log l
                             where l.actor_id = v_uid and l.action = 'god_view.live_start'
                               and l.created_at > now() - interval '10 minutes') >= 20 then
    raise exception 'Too many live shares in 10 minutes. Wait a few minutes and try again.' using errcode = 'P0001';
  end if;
  -- One person at a time: [p_profile_id]'s rows, in order.
  perform pg_advisory_xact_lock(hashtextextended('god_view_live|' || p_profile_id::text, 282));
  perform public.god_view_live_expire(p_profile_id);
  select * into s from public.god_view_live_sessions x
   where x.profile_id = p_profile_id and x.stopped_at is null;
  if s.id is not null then
    return jsonb_build_object('already', true, 'phones', null, 'posted', null, 'session', public.god_view_live_json(s));
  end if;
  -- The phones a ping goes to (0276), claimed as a ping: they answer once
  -- like one, then stream.
  with mine as (
    select t.id
      from public.push_tokens t
      join public.profiles p on p.id = t.profile_id and p.deleted_at is null
     where t.profile_id = p_profile_id
       and t.bg_key_hash is not null
       and t.location_always
       and t.platform in ('ios', 'android')
       for update of t
  ),
  claimed as (
    update public.push_tokens t
       set ping_sent_at = now()
      from mine m
     where t.id = m.id
    returning t.id
  )
  select array_agg(c.id order by c.id) into v_ids from claimed c;
  if coalesce(cardinality(v_ids), 0) = 0 then
    insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
    values (v_uid, 'god_view.live_start', p_profile_id, jsonb_build_object('minutes', v_minutes, 'phones', 0, 'via', v_via));
    return jsonb_build_object('already', false, 'phones', 0, 'posted', false, 'session', null);
  end if;
  insert into public.god_view_live_sessions (profile_id, ends_at)
  values (p_profile_id, now() + make_interval(mins => v_minutes))
  returning * into s;
  v_posted := public.location_ping_kick(v_ids, 'live');
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'god_view.live_start', p_profile_id,
          jsonb_build_object('minutes', v_minutes, 'phones', cardinality(v_ids), 'posted', v_posted, 'session', s.id, 'via', v_via));
  return jsonb_build_object('already', false, 'phones', cardinality(v_ids), 'posted', v_posted,
                            'session', public.god_view_live_json(s));
end;
$function$;

-- ---- live stop -----------------------------------------------------------------------------------
create or replace function public.god_view_live_stop(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  v_uid uuid := auth.uid();
  s public.god_view_live_sessions;
begin
  select * into s from public.god_view_live_sessions x where x.id = p_session_id;
  if s.id is null or not (public.god_view_may_see(s.profile_id) or public.approver_may_see_location(s.profile_id)) then
    raise exception 'You can only stop a live share of someone on your map.' using errcode = '42501';
  end if;
  update public.god_view_live_sessions x
     set stopped_at = now(), stop_reason = 'admin'
   where x.id = s.id and x.stopped_at is null
  returning * into s;
  if s.id is null then
    select * into s from public.god_view_live_sessions x where x.id = p_session_id;
  else
    insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
    values (v_uid, 'god_view.live_stop', s.profile_id,
            jsonb_build_object('session', s.id, 'points', s.points,
                               'via', case when public.god_view_may_see(s.profile_id) then 'admin' else 'approver' end));
  end if;
  perform public.god_view_live_flush(s.id);
  return public.god_view_live_json(s);
end;
$function$;

-- ---- live status (poll, not audited) -------------------------------------------------------------
create or replace function public.god_view_live_status(p_profile_id uuid, p_after bigint default 0)
returns jsonb language plpgsql security definer set search_path to '' as $function$
declare
  s public.god_view_live_sessions;
  v_points jsonb;
begin
  if p_profile_id is null or not (public.god_view_may_see(p_profile_id) or public.approver_may_see_location(p_profile_id)) then
    raise exception 'You can only see the live share of someone on your map.' using errcode = '42501';
  end if;
  perform public.god_view_live_expire(p_profile_id);
  select * into s from public.god_view_live_sessions x
   where x.profile_id = p_profile_id
     and (x.stopped_at is null or x.stopped_at > now() - interval '10 minutes')
   order by x.started_at desc
   limit 1;
  if s.id is null then
    return jsonb_build_object('session', null, 'points', '[]'::jsonb, 'now', now());
  end if;
  perform public.god_view_live_flush(s.id);
  select coalesce(jsonb_agg(jsonb_build_array(
           x.id, round(x.lat::numeric, 6), round(x.lng::numeric, 6),
           floor(extract(epoch from x.captured_at))::bigint, x.speed) order by x.id), '[]'::jsonb)
    into v_points
    from (select p.* from public.god_view_live_points p
           where p.session_id = s.id and p.id > coalesce(p_after, 0)
           order by p.id
           limit 1000) x;
  return jsonb_build_object('session', public.god_view_live_json(s), 'points', v_points, 'now', now());
end;
$function$;

notify pgrst, 'reload schema';
