-- ============================================================================
-- 0350: Approver — Phase 1c: the scoped, read-only "pending documents" inbox.
--
-- Builds on 0349 (the grant model). This adds the two server-side rules that
-- decide what an approver may see, so the app never has to be trusted with the
-- scope:
--   * approver_covers(owner)        does the caller's grant reach this owner?
--   * approver_pending_documents()  every pending document in the caller's
--                                   scope, across the three document stores.
--
-- Scope (from 0349):
--   all       every owner.
--   referral  owners the approver referred (public.referrals).
--   region    owners whose partner service area (countries/states/cities)
--             overlaps the approver's — their own service area when
--             use_own_region, plus any regions an admin set.
-- conflict_guard: when on, an approver never sees their own documents, and —
--   off the referral scope — not the documents of people they referred.
-- doc_types (empty = every type): limits the inbox to chosen document types.
--
-- The three document stores this reads (all reviewed as 'Pending Review'):
--   provider_documents  partner registration documents (owner = auth_user_id)
--   vehicle_documents   vehicle documents & permits     (owner = auth_user_id)
--   identity_checks     user ID / selfie images         (owner = user_id)
--
-- Read only: approve / reject / upload / delete come in later phases and will
-- re-check the very same approver_covers rule before they write.
-- ============================================================================

-- ---- 0. A profile's region tags -------------------------------------------------------------------
-- The normalised union of a profile's partner service area (countries + states
-- + cities). Empty when the profile is not a partner or has no service area.
create or replace function public.approver_region_tags(p_profile uuid)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(distinct lower(btrim(t))), '{}'::text[])
    from public.partners p,
         unnest(coalesce(p.service_countries, '{}'::text[]) ||
                coalesce(p.service_states,    '{}'::text[]) ||
                coalesce(p.service_cities,    '{}'::text[])) as t
   where p.auth_user_id = p_profile
     and btrim(coalesce(t, '')) <> '';
$$;
revoke execute on function public.approver_region_tags(uuid) from public, anon;
grant execute on function public.approver_region_tags(uuid) to authenticated;

-- ---- 1. Does the caller's grant cover this owner? -------------------------------------------------
create or replace function public.approver_covers(p_owner uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a            public.approvers;
  v_me         uuid := auth.uid();
  v_my_tags    text[];
  v_owner_tags text[];
begin
  if v_me is null or p_owner is null then
    return false;
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found then
    return false;
  end if;

  -- Conflict guard: never your own documents; off the referral scope, not the
  -- documents of people you referred.
  if a.conflict_guard then
    if p_owner = v_me then
      return false;
    end if;
    if a.scope <> 'referral'
       and exists (select 1 from public.referrals
                    where referrer_user_id = v_me and referred_user_id = p_owner) then
      return false;
    end if;
  end if;

  if a.scope = 'all' then
    return true;
  elsif a.scope = 'referral' then
    return exists (select 1 from public.referrals
                    where referrer_user_id = v_me and referred_user_id = p_owner);
  elsif a.scope = 'region' then
    v_my_tags := case when a.use_own_region
                      then public.approver_region_tags(v_me) else '{}'::text[] end
               || coalesce(array(select lower(btrim(x))
                                   from jsonb_array_elements_text(a.regions) as x
                                  where btrim(coalesce(x, '')) <> ''), '{}'::text[]);
    v_owner_tags := public.approver_region_tags(p_owner);
    return coalesce(array_length(v_my_tags, 1), 0) > 0
       and coalesce(array_length(v_owner_tags, 1), 0) > 0
       and v_my_tags && v_owner_tags;
  end if;
  return false;
end;
$$;
revoke execute on function public.approver_covers(uuid) from public, anon;
grant execute on function public.approver_covers(uuid) to authenticated;

-- ---- 2. The caller's pending-documents inbox ------------------------------------------------------
-- Every pending document the caller's grant reaches, across the three stores.
-- Returns nothing when the caller is not an active approver.
create or replace function public.approver_pending_documents()
returns table (
  source        text,          -- 'partner' | 'vehicle' | 'identity'
  doc_pk        uuid,          -- the document row's id (for later actions)
  owner_id      uuid,
  owner_name    text,
  owner_phone   text,
  doc_key       text,          -- doc_id (partner/vehicle) or doc_type/kind (identity)
  doc_label     text,
  file_url      text,
  file_url_back text,
  status        text,
  submitted_at  timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  a    public.approvers;
  v_me uuid := auth.uid();
begin
  if v_me is null then
    return;
  end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found then
    return;
  end if;

  return query
  -- Partner registration documents.
  select 'partner'::text, d.id, d.auth_user_id,
         coalesce(nullif(btrim(p.name), ''), 'User'), p.phone,
         d.doc_id, coalesce(nullif(btrim(d.doc_name), ''), d.doc_id, 'Document'),
         d.file_url, d.file_url_back, d.status, null::timestamptz
    from public.provider_documents d
    join public.profiles p on p.id = d.auth_user_id
   where d.status = 'Pending Review'
     and (a.doc_types = '{}'::text[] or d.doc_id = any(a.doc_types))
     and public.approver_covers(d.auth_user_id)
  union all
  -- Vehicle documents & permits.
  select 'vehicle'::text, d.id, d.auth_user_id,
         coalesce(nullif(btrim(p.name), ''), 'User'), p.phone,
         d.doc_id, coalesce(nullif(btrim(d.doc_name), ''), d.doc_id, 'Document'),
         d.file_url, d.file_url_back, d.status, null::timestamptz
    from public.vehicle_documents d
    join public.profiles p on p.id = d.auth_user_id
   where d.status = 'Pending Review'
     and (a.doc_types = '{}'::text[] or d.doc_id = any(a.doc_types))
     and public.approver_covers(d.auth_user_id)
  union all
  -- User ID / selfie documents.
  select 'identity'::text, c.id, c.user_id,
         coalesce(nullif(btrim(p.name), ''), 'User'), p.phone,
         coalesce(c.doc_type, c.kind),
         case when c.kind = 'selfie'    then 'Selfie'
              when c.doc_type = 'mykad' then 'MyKad'
              when c.doc_type = 'passport' then 'Passport'
              else coalesce(c.doc_type, c.kind, 'ID') end,
         c.file_url, c.file_url_back, c.status, c.created_at
    from public.identity_checks c
    join public.profiles p on p.id = c.user_id
   where c.status = 'Pending Review'
     and (a.doc_types = '{}'::text[] or coalesce(c.doc_type, c.kind) = any(a.doc_types))
     and public.approver_covers(c.user_id)
  order by 4, 1;
end;
$$;
revoke execute on function public.approver_pending_documents() from public, anon;
grant execute on function public.approver_pending_documents() to authenticated;

notify pgrst, 'reload schema';
