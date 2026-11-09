-- ============================================================================
-- 0382: My Team filters.
--
-- The My Team screen gains filter bullets:
--   • Partners | Vehicles  — which list to show,
--   • Approved | Unapproved — filter by status,
--   • Online | Offline      — filter by presence (partners only).
--
-- Two changes back it:
--   * approver_covered_partners gains p_status and p_presence (both nullable =
--     "no filter"). 'approved'/'unapproved' filter profiles.status; 'online'/
--     'offline' filter on a live vehicle session with a fresh heartbeat — the
--     same signal the card's dot shows. Adding params changes the return
--     signature's argument list, so the function is dropped and recreated.
--   * approver_covered_vehicles(query, after_plate, after_id, limit, status,
--     usage) — every vehicle owned by someone the approver covers, keyset-
--     paginated by plate, searchable by plate / make / model / owner. Two
--     orthogonal filters: p_status ('approved'/'unapproved', the approval) and
--     p_usage, the live state from vehicle_active_session:
--       'online'     — a claimed session with a fresh heartbeat,
--       'offline'    — claimed (a session row) but not live right now,
--       'unassigned' — no session: nobody is using the car.
--     The scope (who the approver covers) is resolved exactly as
--     approver_covered_partners does, so a vehicle only ever appears for an
--     owner in scope.
-- ============================================================================

-- The presence/status filters only reduce rows, so the search, cursor and
-- conflict-guard rules are unchanged from 0368.
drop function if exists public.approver_covered_partners(text, text, uuid, int);

create function public.approver_covered_partners(
  p_query      text default null,
  p_after_name text default null,
  p_after_id   uuid default null,
  p_limit      int  default 20,
  p_status     text default null,
  p_presence   text default null)
returns table (
  owner_id       uuid,
  display_id     text,
  name           text,
  phone          text,
  avatar_url     text,
  status         text,
  id_verified    text,
  ic             text,
  nationality    text,
  plate          text,
  vehicle_label  text,
  pending_docs   int,
  wallet_balance numeric,
  service_city   text,
  registered_at  timestamptz,
  updated_at     timestamptz,
  online         boolean)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a         public.approvers;
  v_me      uuid := auth.uid();
  v_lim     int  := greatest(1, least(coalesce(p_limit, 20), 100));
  v_q       text := nullif(btrim(coalesce(p_query, '')), '');
  v_status  text := nullif(lower(btrim(coalesce(p_status, ''))), '');
  v_presence text := nullif(lower(btrim(coalesce(p_presence, ''))), '');
  v_my_tags text[];
begin
  if v_me is null then
    return;
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found then
    return;
  end if;

  if a.scope = 'region' then
    v_my_tags := case when a.use_own_region then public.approver_region_tags(v_me) else '{}'::text[] end
               || coalesce(array(select lower(btrim(x))
                                   from jsonb_array_elements_text(a.regions) as x
                                  where btrim(coalesce(x, '')) <> ''), '{}'::text[]);
  end if;

  return query
  with covered as (
    select p.id
      from public.profiles p
     where case a.scope
             when 'all'      then true
             when 'referral' then exists (select 1 from public.referrals r
                                           where r.referrer_user_id = v_me and r.referred_user_id = p.id)
             when 'region'   then coalesce(array_length(v_my_tags, 1), 0) > 0
                               and public.approver_region_tags(p.id) && v_my_tags
             else false
           end
       and not (a.conflict_guard and p.id = v_me)
       and not (a.conflict_guard and a.scope <> 'referral'
                and exists (select 1 from public.referrals r
                             where r.referrer_user_id = v_me and r.referred_user_id = p.id))
  )
  select p.id,
         p.display_id,
         coalesce(nullif(btrim(p.name), ''), 'User') as disp_name,
         p.phone,
         coalesce(nullif(btrim(p.avatar_url), ''), nullif(btrim(p.profile_image), '')),
         nullif(p.status::text, ''),
         nullif(p.id_verified::text, ''),
         nullif(btrim(p.ic), ''),
         nullif(btrim(p.nationality), ''),
         v.plate,
         nullif(btrim(concat_ws(' ', nullif(btrim(v.make), ''), nullif(btrim(v.model), ''))), ''),
         (
           coalesce((select count(*) from public.provider_documents d
                      where d.auth_user_id = p.id and d.status = 'Pending Review'), 0)
         + coalesce((select count(*) from public.vehicle_documents d
                      where d.auth_user_id = p.id and d.status = 'Pending Review'), 0)
         + coalesce((select count(*) from public.identity_checks c
                      where c.user_id = p.id and c.status = 'Pending Review'), 0)
         )::int,
         (select w.balance from public.wallets w
           where w.user_id = p.id and w.wallet_type = 'get_wallet' limit 1),
         (select nullif(btrim(coalesce(
                   (pr.service_cities)[1], (pr.service_states)[1], (pr.service_countries)[1])), '')
            from public.partners pr where pr.auth_user_id = p.id limit 1),
         coalesce(p.joined_at, p.created_at),
         p.updated_at,
         exists (select 1 from public.vehicle_active_session s
                  where s.user_id = p.id and s.status = 'online'
                    and s.last_seen_at > now() - interval '2 minutes')
    from covered cov
    join public.profiles p on p.id = cov.id
    left join lateral (
      select nullif(btrim(vv.plate), '') as plate, vv.make, vv.model
        from public.vehicle vv
       where vv.auth_user_id = p.id
       order by (vv.status = 'approved') desc, vv.created_at
       limit 1
    ) v on true
   where (v_q is null
          or p.name       ilike '%' || v_q || '%'
          or p.phone      ilike '%' || v_q || '%'
          or p.display_id ilike '%' || v_q || '%'
          or p.ic         ilike '%' || v_q || '%'
          or v.plate      ilike '%' || v_q || '%')
     -- status filter: approved, or anything-but-approved for "unapproved".
     and (v_status is null
          or (v_status = 'approved'   and p.status::text = 'approved')
          or (v_status = 'unapproved' and coalesce(p.status::text, '') is distinct from 'approved'))
     -- presence filter: a fresh live session means online.
     and (v_presence is null
          or (exists (select 1 from public.vehicle_active_session s
                       where s.user_id = p.id and s.status = 'online'
                         and s.last_seen_at > now() - interval '2 minutes'))
              = (v_presence = 'online'))
     and (p_after_name is null
          or (lower(coalesce(nullif(btrim(p.name), ''), 'User')), p.id)
             > (lower(coalesce(nullif(btrim(p_after_name), ''), 'User')),
                coalesce(p_after_id, '00000000-0000-0000-0000-000000000000'::uuid)))
   order by lower(coalesce(nullif(btrim(p.name), ''), 'User')), p.id
   limit v_lim;
end;
$$;
revoke execute on function public.approver_covered_partners(text, text, uuid, int, text, text) from public, anon;
grant execute on function public.approver_covered_partners(text, text, uuid, int, text, text) to authenticated;

-- Every vehicle owned by a covered person (the "All Vehicles" list).
drop function if exists public.approver_covered_vehicles(text, text, uuid, int, text);

create function public.approver_covered_vehicles(
  p_query       text default null,
  p_after_plate text default null,
  p_after_id    uuid default null,
  p_limit       int  default 20,
  p_status      text default null,
  p_usage       text default null)
returns table (
  id               uuid,
  plate            text,
  make             text,
  model            text,
  year             text,
  color            text,
  status           text,
  usage            text,
  owner_id         uuid,
  owner_name       text,
  owner_display_id text,
  service_city     text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a         public.approvers;
  v_me      uuid := auth.uid();
  v_lim     int  := greatest(1, least(coalesce(p_limit, 20), 100));
  v_q       text := nullif(btrim(coalesce(p_query, '')), '');
  v_status  text := nullif(lower(btrim(coalesce(p_status, ''))), '');
  v_usage   text := nullif(lower(btrim(coalesce(p_usage, ''))), '');
  v_my_tags text[];
begin
  if v_me is null then
    return;
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found then
    return;
  end if;

  if a.scope = 'region' then
    v_my_tags := case when a.use_own_region then public.approver_region_tags(v_me) else '{}'::text[] end
               || coalesce(array(select lower(btrim(x))
                                   from jsonb_array_elements_text(a.regions) as x
                                  where btrim(coalesce(x, '')) <> ''), '{}'::text[]);
  end if;

  return query
  with covered as (
    select p.id
      from public.profiles p
     where case a.scope
             when 'all'      then true
             when 'referral' then exists (select 1 from public.referrals r
                                           where r.referrer_user_id = v_me and r.referred_user_id = p.id)
             when 'region'   then coalesce(array_length(v_my_tags, 1), 0) > 0
                               and public.approver_region_tags(p.id) && v_my_tags
             else false
           end
       and not (a.conflict_guard and p.id = v_me)
       and not (a.conflict_guard and a.scope <> 'referral'
                and exists (select 1 from public.referrals r
                             where r.referrer_user_id = v_me and r.referred_user_id = p.id))
  )
  select v.id,
         coalesce(nullif(btrim(v.plate), ''), '—'),
         nullif(btrim(v.make), ''),
         nullif(btrim(v.model), ''),
         nullif(btrim(v.year::text), ''),
         nullif(btrim(v.color), ''),
         nullif(v.status::text, ''),
         -- Live usage from vehicle_active_session: online (fresh), offline
         -- (claimed but stale), else unassigned (no session).
         case
           when exists (select 1 from public.vehicle_active_session s
                         where s.vehicle_id = v.id and s.status = 'online'
                           and s.last_seen_at > now() - interval '2 minutes') then 'online'
           when exists (select 1 from public.vehicle_active_session s
                         where s.vehicle_id = v.id) then 'offline'
           else 'unassigned'
         end,
         p.id,
         coalesce(nullif(btrim(p.name), ''), 'User'),
         p.display_id,
         (select nullif(btrim(coalesce(
                   (pr.service_cities)[1], (pr.service_states)[1], (pr.service_countries)[1])), '')
            from public.partners pr where pr.auth_user_id = p.id limit 1)
    from covered cov
    join public.profiles p on p.id = cov.id
    join public.vehicle v on v.auth_user_id = p.id
   where (v_q is null
          or v.plate ilike '%' || v_q || '%'
          or v.make  ilike '%' || v_q || '%'
          or v.model ilike '%' || v_q || '%'
          or p.name  ilike '%' || v_q || '%')
     and (v_status is null
          or (v_status = 'approved'   and v.status::text = 'approved')
          or (v_status = 'unapproved' and coalesce(v.status::text, '') is distinct from 'approved'))
     -- usage filter (orthogonal to approval).
     and (v_usage is null
          or (v_usage = 'online'
              and exists (select 1 from public.vehicle_active_session s
                           where s.vehicle_id = v.id and s.status = 'online'
                             and s.last_seen_at > now() - interval '2 minutes'))
          or (v_usage = 'offline'
              and not exists (select 1 from public.vehicle_active_session s
                               where s.vehicle_id = v.id and s.status = 'online'
                                 and s.last_seen_at > now() - interval '2 minutes')
              and exists (select 1 from public.vehicle_active_session s where s.vehicle_id = v.id))
          or (v_usage = 'unassigned'
              and not exists (select 1 from public.vehicle_active_session s where s.vehicle_id = v.id)))
     and (p_after_plate is null
          or (lower(coalesce(nullif(btrim(v.plate), ''), '—')), v.id)
             > (lower(coalesce(nullif(btrim(p_after_plate), ''), '—')),
                coalesce(p_after_id, '00000000-0000-0000-0000-000000000000'::uuid)))
   order by lower(coalesce(nullif(btrim(v.plate), ''), '—')), v.id
   limit v_lim;
end;
$$;
revoke execute on function public.approver_covered_vehicles(text, text, uuid, int, text, text) from public, anon;
grant execute on function public.approver_covered_vehicles(text, text, uuid, int, text, text) to authenticated;

notify pgrst, 'reload schema';
