-- ============================================================================
-- 0383: My Team — approver sets a member's availability, and a docs-expiring
-- count on the member list.
--
--   * approver_set_member_presence(member, online) — an approver with
--     can_edit_profile, covering the member, can set that member offline (ends
--     their live vehicle session and clears their dispatch presence) or back
--     online (best-effort: re-activates an existing claimed session and marks
--     them dispatch-available; it cannot start a session the driver's device
--     never opened). Logged.
--   * approver_covered_partners gains docs_expiring — how many of the member's
--     APPROVED documents expire within 30 days (provider, vehicle and identity
--     docs together), for a badge on the member card and header. Adding a
--     column changes the return type, so the function is dropped and recreated;
--     it is otherwise identical to 0382.
-- ============================================================================

create or replace function public.approver_set_member_presence(p_member uuid, p_online boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare a public.approvers; v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_edit_profile then raise exception 'not_allowed'; end if;
  if p_member is null then raise exception 'bad_input' using errcode = '22023'; end if;
  if not public.approver_covers(p_member) then raise exception 'out_of_scope'; end if;

  if p_online then
    -- Best-effort: a session can only be re-activated, not conjured — a driver
    -- whose device never opened one stays offline on the live chip.
    update public.vehicle_active_session set status = 'online', last_seen_at = now()
     where user_id = p_member;
    insert into public.driver_presence (profile_id, online, updated_at)
      values (p_member, true, now())
      on conflict (profile_id) do update set online = true, updated_at = now();
  else
    update public.vehicle_active_session set status = 'offline', last_seen_at = now()
     where user_id = p_member;
    update public.driver_presence set online = false, updated_at = now()
     where profile_id = p_member;
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.set_presence', p_member, jsonb_build_object('online', p_online));

  return jsonb_build_object('ok', true, 'online', p_online);
end;
$$;
revoke execute on function public.approver_set_member_presence(uuid, boolean) from public, anon;
grant execute on function public.approver_set_member_presence(uuid, boolean) to authenticated;

-- Recreate approver_covered_partners with docs_expiring (otherwise unchanged
-- from 0382).
drop function if exists public.approver_covered_partners(text, text, uuid, int, text, text);

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
  online         boolean,
  docs_expiring  int)
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
                    and s.last_seen_at > now() - interval '2 minutes'),
         -- Approved documents whose expiry is within 30 days (or already past).
         (
           coalesce((select count(*) from public.provider_documents d
                      where d.auth_user_id = p.id and d.status = 'Approved'
                        and d.expiry_date is not null and d.expiry_date <= current_date + 30), 0)
         + coalesce((select count(*) from public.vehicle_documents d
                      where d.auth_user_id = p.id and d.status = 'Approved'
                        and d.expiry_date is not null and d.expiry_date <= current_date + 30), 0)
         + coalesce((select count(*) from public.identity_checks c
                      where c.user_id = p.id and c.status = 'Approved'
                        and c.expiry_date is not null and c.expiry_date <= current_date + 30), 0)
         )::int
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
     and (v_status is null
          or (v_status = 'approved'   and p.status::text = 'approved')
          or (v_status = 'unapproved' and coalesce(p.status::text, '') is distinct from 'approved'))
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

notify pgrst, 'reload schema';
