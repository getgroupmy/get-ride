-- ============================================================================
-- 0398 — My Team splits Providers/Partners/Drivers from plain Users, and shows
--        (and sets) the right approval status for each.
--
-- The problem: My Team read and wrote profiles.status (the account/user
-- approval). The admin "Partners" page reads and writes partners.status (the
-- provider approval). So a member approved as a user but not yet approved as a
-- partner showed "Approved" in My Team yet "Unapproved" in admin — two names for
-- two different facts, conflated into one badge.
--
-- This migration:
--   1. approver_covered_partners now returns is_partner (the member has a
--      partners row) and partner_status (partners.status), and takes p_kind
--      ('partner' | 'user') to list one group. The Approved/Unapproved filter
--      now matches the *effective* status — the partner status for a partner,
--      the account status for a plain user.
--   2. approver_pending_uploads tags each row with is_partner, so the app can
--      split that list the same way.
--   3. approver_set_member_approval(member, approved) is the partner-aware
--      Approve: approving a partner approves the PARTNER (partners.status) and
--      cascades to approve the user account too (profiles.status) — "if the
--      partner is approved the user is approved as well". Un-approving a partner
--      touches only the partner row, leaving the user account as it was. A
--      member with no partner row is approved/un-approved at the account level,
--      exactly as before. So a user approved as a user who later applies as a
--      partner starts the partner unapproved, while their user account stays
--      approved.
-- ============================================================================

-- ---- 1. The covered-people list, split by kind --------------------------------------------------
drop function if exists public.approver_covered_partners(text, text, uuid, int, text, text);

create function public.approver_covered_partners(
  p_query      text default null,
  p_after_name text default null,
  p_after_id   uuid default null,
  p_limit      int  default 20,
  p_status     text default null,
  p_presence   text default null,
  p_kind       text default null)
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
  docs_expiring  int,
  is_partner     boolean,
  partner_status text)
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
  v_kind    text := nullif(lower(btrim(coalesce(p_kind, ''))), '');
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
         pr.service_city,
         coalesce(p.joined_at, p.created_at),
         p.updated_at,
         exists (select 1 from public.vehicle_active_session s
                  where s.user_id = p.id and s.status = 'online'
                    and s.last_seen_at > now() - interval '2 minutes'),
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
         )::int,
         (pr.partner_id is not null),
         pr.partner_status
    from covered cov
    join public.profiles p on p.id = cov.id
    left join lateral (
      select nullif(btrim(vv.plate), '') as plate, vv.make, vv.model
        from public.vehicle vv
       where vv.auth_user_id = p.id
       order by (vv.status = 'approved') desc, vv.created_at
       limit 1
    ) v on true
    left join lateral (
      select pp.id as partner_id, pp.status::text as partner_status,
             nullif(btrim(coalesce(
               (pp.service_cities)[1], (pp.service_states)[1], (pp.service_countries)[1])), '') as service_city
        from public.partners pp
       where pp.auth_user_id = p.id
       order by pp.updated_at desc nulls last
       limit 1
    ) pr on true
   where (v_q is null
          or p.name       ilike '%' || v_q || '%'
          or p.phone      ilike '%' || v_q || '%'
          or p.display_id ilike '%' || v_q || '%'
          or p.ic         ilike '%' || v_q || '%'
          or v.plate      ilike '%' || v_q || '%')
     -- The effective status: a partner's provider status, else the account status.
     and (v_status is null
          or (v_status = 'approved'
              and coalesce(pr.partner_status, p.status::text) = 'approved')
          or (v_status = 'unapproved'
              and coalesce(pr.partner_status, p.status::text) is distinct from 'approved'))
     and (v_kind is null
          or (v_kind = 'partner' and pr.partner_id is not null)
          or (v_kind = 'user'    and pr.partner_id is null))
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
revoke execute on function public.approver_covered_partners(text, text, uuid, int, text, text, text) from public, anon;
grant execute on function public.approver_covered_partners(text, text, uuid, int, text, text, text) to authenticated;

-- ---- 2. Partner-aware Approve, with the cascade to the user account ------------------------------
-- Approving a partner approves the partner row AND the user account; approving a
-- plain user approves the account. Un-approving touches only the row it is set
-- on (a partner's partner row; a user's account), so an approved user who later
-- applies as a partner keeps their account while the partner awaits approval.
create or replace function public.approver_set_member_approval(p_member uuid, p_approved boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  a            public.approvers;
  v_me         uuid := auth.uid();
  v_part       public.partners%rowtype;
  v_is_partner boolean;
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_edit_profile then
    raise exception 'not_allowed';
  end if;
  if p_member is null then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  if not public.approver_covers(p_member) then
    raise exception 'out_of_scope';
  end if;

  select * into v_part from public.partners where auth_user_id = p_member
   order by updated_at desc nulls last limit 1;
  v_is_partner := found;

  if v_is_partner then
    -- The member is a partner: act on the partner row.
    if p_approved then
      -- Don't clobber an already-approved or permit-verified partner.
      if not (v_part.status::text = 'approved' or v_part.status::text like 'permit-%') then
        update public.partners
           set status = 'approved', status_note = null, documents_ok = true, updated_at = now()
         where id = v_part.id;
      end if;
      -- Cascade: an approved partner means an approved user account.
      update public.profiles
         set status = 'approved'::public.user_status,
             profile_status = 'Approved'::public.profile_status,
             updated_at = now()
       where id = p_member and status::text is distinct from 'approved';
    else
      update public.partners
         set status = 'unapproved', updated_at = now()
       where id = v_part.id
         and v_part.status::text not in ('blocked', 'rejected');
    end if;
  else
    -- A plain user: act on the account, as before.
    update public.profiles
       set status = case when p_approved then 'approved' else 'unapproved' end::public.user_status,
           profile_status = case when p_approved then 'Approved' else 'Un-Approved' end::public.profile_status,
           updated_at = now()
     where id = p_member;
    if not found then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
  end if;

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.set_member_approval', p_member,
          jsonb_build_object('approved', p_approved, 'is_partner', v_is_partner));

  return jsonb_build_object('ok', true, 'is_partner', v_is_partner, 'approved', p_approved);
end;
$$;
revoke execute on function public.approver_set_member_approval(uuid, boolean) from public, anon;
grant execute on function public.approver_set_member_approval(uuid, boolean) to authenticated;

-- ---- 2b. The member-detail read carries the partner status too ----------------------------------
-- The detail sheet's status chip and Approve button use the effective status
-- (partner status for a partner), so the read exposes both (migration 0398).
create or replace function public.approver_member_detail(p_member uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  p   public.profiles;
  pay public.partner_payout_accounts;
begin
  if auth.uid() is null or p_member is null or not public.approver_covers(p_member) then
    return null;
  end if;
  select * into p from public.profiles where id = p_member;
  if not found then
    return null;
  end if;
  select * into pay from public.partner_payout_accounts where profile_id = p_member;
  return jsonb_build_object(
    'id', p.id,
    'name', p.name,
    'email', p.email,
    'phone', p.phone,
    'ic', p.ic,
    'nationality', p.nationality,
    'address', p.address,
    'status', p.status,
    'id_verified', p.id_verified,
    'is_partner', exists (select 1 from public.partners where auth_user_id = p_member),
    -- The provider status, for the detail sheet's effective-status badge (0398).
    'partner_status', (select pp.status::text from public.partners pp
                        where pp.auth_user_id = p_member
                        order by pp.updated_at desc nulls last limit 1),
    'partner_types', coalesce((select to_jsonb(partner_types) from public.partners
                                where auth_user_id = p_member limit 1), '[]'::jsonb),
    'payout', case when pay.profile_id is null then null else jsonb_build_object(
                'type', pay.account_type, 'provider', pay.bank_name,
                'account', pay.account_no, 'holder', pay.holder_name) end);
end;
$$;
revoke execute on function public.approver_member_detail(uuid) from public, anon;
grant execute on function public.approver_member_detail(uuid) to authenticated;

-- ---- 3. Tag each pending-upload row with whether the member is a partner -------------------------
create or replace function public.approver_pending_uploads(
  p_query text default null, p_limit int default 300)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  a public.approvers; v_me uuid := auth.uid();
  v_lim int := greatest(1, least(coalesce(p_limit, 300), 1000));
  v_q   text := nullif(btrim(coalesce(p_query, '')), '');
  v_tags text[]; v jsonb;
begin
  if v_me is null then return '[]'::jsonb; end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found then return '[]'::jsonb; end if;

  if a.scope = 'region' then
    v_tags := case when a.use_own_region then public.approver_region_tags(v_me) else '{}'::text[] end
            || coalesce(array(select lower(btrim(x)) from jsonb_array_elements_text(a.regions) as x
                               where btrim(coalesce(x, '')) <> ''), '{}'::text[]);
  end if;

  with covered as (
    select p.id, coalesce(nullif(btrim(p.name), ''), 'User') as name, p.phone,
           exists (select 1 from public.push_tokens pt where pt.profile_id = p.id) as reachable,
           exists (select 1 from public.partners pr where pr.auth_user_id = p.id) as is_partner,
           (select public._service_location_label(pr.service_countries, pr.service_states, pr.service_cities)
              from public.partners pr where pr.auth_user_id = p.id
             order by pr.updated_at desc nulls last limit 1) as location
      from public.profiles p
     where case a.scope
             when 'all'      then true
             when 'referral' then exists (select 1 from public.referrals r
                                           where r.referrer_user_id = v_me and r.referred_user_id = p.id)
             when 'region'   then coalesce(array_length(v_tags, 1), 0) > 0
                               and public.approver_region_tags(p.id) && v_tags
             else false
           end
       and not (a.conflict_guard and p.id = v_me)
       and not (a.conflict_guard and a.scope <> 'referral'
                and exists (select 1 from public.referrals r
                             where r.referrer_user_id = v_me and r.referred_user_id = p.id))
       and (v_q is null or p.name ilike '%' || v_q || '%')
  ),
  -- Partner/driver required documents are listed only for people who are
  -- actually partners (migration 0398). A plain user is never asked to upload a
  -- provider document they'd have no reason to hold.
  partner_rows as (
    select c.id as member_id, c.name as member_name, c.phone as member_phone, c.reachable, c.location,
           c.is_partner,
           'partner'::text as source, rd.id::text as doc_key,
           coalesce(nullif(btrim(rd.values->>'name'), ''), 'Document') as doc_name,
           null::uuid as vehicle_id, null::text as plate,
           coalesce(dur.sent_count, 0) as sent_count, dur.last_sent_at
      from covered c
      join public.required_document rd
        on coalesce((rd.values->>'active')::boolean, false)
       and coalesce((rd.values->>'required')::boolean, false)
       and not (coalesce(nullif(rd.values->>'docTypes', ''), '[]')::jsonb ?| public._vehicle_doc_categories())
      left join public.document_upload_requests dur
        on dur.target_user_id = c.id and dur.source = 'partner'
       and dur.doc_key = rd.id::text and dur.vehicle_id is null
     where c.is_partner
       and not exists (select 1 from public.provider_documents d
                        where d.auth_user_id = c.id and d.doc_id = rd.id::text)
  ),
  vehicle_rows as (
    select c.id as member_id, c.name as member_name, c.phone as member_phone, c.reachable, c.location,
           c.is_partner,
           'vehicle'::text as source, rd.id::text as doc_key,
           coalesce(nullif(btrim(rd.values->>'name'), ''), 'Document') as doc_name,
           veh.id as vehicle_id, nullif(btrim(veh.plate), '') as plate,
           coalesce(dur.sent_count, 0) as sent_count, dur.last_sent_at
      from covered c
      join public.vehicle veh on veh.auth_user_id = c.id
      join public.required_document rd
        on coalesce((rd.values->>'active')::boolean, false)
       and coalesce((rd.values->>'required')::boolean, false)
       and (coalesce(nullif(rd.values->>'docTypes', ''), '[]')::jsonb ?| public._vehicle_doc_categories())
      left join public.document_upload_requests dur
        on dur.target_user_id = c.id and dur.source = 'vehicle'
       and dur.doc_key = rd.id::text and dur.vehicle_id = veh.id
     where not exists (select 1 from public.vehicle_documents d
                        where d.vehicle_id = veh.id and d.doc_id = rd.id::text)
  ),
  rows as (
    select * from (
      select * from partner_rows
      union all
      select * from vehicle_rows
    ) u
    order by lower(member_name), member_id, source, coalesce(plate, ''), lower(doc_name)
    limit v_lim
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'member_id',    member_id,
           'member_name',  member_name,
           'member_phone', member_phone,
           'reachable',    reachable,
           'is_partner',   is_partner,
           'location',     location,
           'source',       source,
           'doc_id',       doc_key,
           'doc_key',      doc_key,
           'name',         doc_name,
           'vehicle_id',   vehicle_id,
           'plate',        plate,
           'sent_count',   sent_count,
           'last_sent_at', last_sent_at)), '[]'::jsonb)
    into v from rows;

  return v;
end;
$function$;

notify pgrst, 'reload schema';
