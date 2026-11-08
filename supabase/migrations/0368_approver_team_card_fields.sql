-- ============================================================================
-- 0368: approver_covered_partners — the extra fields the My Team list card shows.
--
-- The mockup's member card carries more than the name/plate/phone the first cut
-- returned (0357). It also shows, at a glance:
--   • the member's GET.wallet balance (RM …) beside their account number,
--   • where they drive (service city),
--   • when they joined (registered) and when their record last changed,
--   • whether they are online right now.
--
-- All of it already exists; this only surfaces it on the same covered-people
-- page, so the card can render without a per-row round trip:
--   wallets                 GET.wallet balance
--   partners.service_*      service city (first city, else state, else country)
--   profiles.joined_at      registered (falls back to created_at)
--   profiles.updated_at     last updated
--   vehicle_active_session  live presence (status online + a fresh heartbeat)
--
-- The scope, search, cursor and conflict-guard rules are unchanged from 0357 —
-- this is the same query with five more columns. Adding columns changes the
-- function's return type, so it is dropped and recreated rather than replaced.
-- ============================================================================
drop function if exists public.approver_covered_partners(text, text, uuid, int);

create function public.approver_covered_partners(
  p_query      text default null,
  p_after_name text default null,
  p_after_id   uuid default null,
  p_limit      int  default 20)
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

  -- The approver's own region tags (region scope only), as approver_covers builds them.
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
       -- conflict guard: never yourself; off the referral scope, not people you referred.
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
         -- GET.wallet balance (null when the wallet row doesn't exist yet).
         (select w.balance from public.wallets w
           where w.user_id = p.id and w.wallet_type = 'get_wallet' limit 1),
         -- Service city: first city on file, else a state, else a country.
         (select nullif(btrim(coalesce(
                   (pr.service_cities)[1], (pr.service_states)[1], (pr.service_countries)[1])), '')
            from public.partners pr where pr.auth_user_id = p.id limit 1),
         coalesce(p.joined_at, p.created_at),
         p.updated_at,
         -- Online right now: a live vehicle session with a fresh heartbeat.
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
     and (p_after_name is null
          or (lower(coalesce(nullif(btrim(p.name), ''), 'User')), p.id)
             > (lower(coalesce(nullif(btrim(p_after_name), ''), 'User')),
                coalesce(p_after_id, '00000000-0000-0000-0000-000000000000'::uuid)))
   order by lower(coalesce(nullif(btrim(p.name), ''), 'User')), p.id
   limit v_lim;
end;
$$;
revoke execute on function public.approver_covered_partners(text, text, uuid, int) from public, anon;
grant execute on function public.approver_covered_partners(text, text, uuid, int) to authenticated;

notify pgrst, 'reload schema';
