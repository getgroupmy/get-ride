-- ============================================================================
-- 0357: Approver — "My Team": the people an approver's grant reaches, and one
-- person's documents across every status.
--
-- The approver inbox (0350, approver_pending_documents) lists the documents
-- waiting for review. "My Team" turns that around: it lists the PEOPLE the
-- approver covers, so the approver can open one and manage their documents
-- (and, in later phases, their profile, vehicle and statistics).
--
-- Two functions, both reusing the 0350 scope rules so the server stays the one
-- source of truth for who an approver reaches:
--
--   approver_covered_partners(query, after_name, after_id, limit)
--       one keyset-paginated, searchable page of covered people with the card
--       fields the list shows. Ordered by display name then id; the caller
--       pages by passing the last row's (name, owner_id) back as the cursor.
--
--   approver_owner_documents(owner)
--       one covered person's documents across all three stores, every status,
--       in the same 18-column shape approver_pending_documents returns (0356),
--       so the same viewer and the same approve/reject/edit/replace actions
--       work unchanged. Guarded by approver_covers, like every approver read.
--
-- doc_types narrows the document inbox, not the team: a person is covered (or
-- not) regardless of which document types the grant is limited to. The
-- conflict_guard exclusions from 0350 (never yourself; off the referral scope,
-- not people you referred) still apply to the team list.
-- ============================================================================

-- A keyset cursor sorts and compares on the display name, so a blank name and
-- the 'User' fallback sort together rather than drifting apart between the
-- page and the cursor.
create index if not exists profiles_display_name_id_idx
  on public.profiles (lower(coalesce(nullif(btrim(name), ''), 'User')), id);

-- ---- 1. One page of the people the caller's grant reaches -----------------------------------------
create or replace function public.approver_covered_partners(
  p_query      text default null,
  p_after_name text default null,
  p_after_id   uuid default null,
  p_limit      int  default 20)
returns table (
  owner_id      uuid,
  display_id    text,
  name          text,
  phone         text,
  avatar_url    text,
  status        text,
  id_verified   text,
  ic            text,
  nationality   text,
  plate         text,
  vehicle_label text,
  pending_docs  int)
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
         )::int
    from covered cov
    join public.profiles p on p.id = cov.id
    left join lateral (
      select vv.plate, vv.make, vv.model
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

-- ---- 2. One covered person's documents, every status ----------------------------------------------
-- The same 18 columns approver_pending_documents returns (0356), so the app's
-- ApproverDoc and its viewer read this unchanged. Returns nothing when the
-- caller's grant does not reach the owner.
create or replace function public.approver_owner_documents(p_owner uuid)
returns table (
  source          text,
  doc_pk          uuid,
  owner_id        uuid,
  owner_name      text,
  owner_phone     text,
  doc_key         text,
  doc_label       text,
  file_url        text,
  file_url_back   text,
  status          text,
  submitted_at    timestamptz,
  document_number text,
  start_date      date,
  expiry_date     date,
  requires_number boolean,
  requires_start  boolean,
  requires_expiry boolean,
  plate           text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or p_owner is null or not public.approver_covers(p_owner) then
    return;
  end if;

  return query
  -- Partner registration documents.
  select 'partner'::text, d.id, d.auth_user_id,
         coalesce(nullif(btrim(p.name), ''), 'User'), p.phone,
         d.doc_id, coalesce(nullif(btrim(d.doc_name), ''), d.doc_id, 'Document'),
         d.file_url, d.file_url_back, d.status, null::timestamptz,
         d.document_number, d.start_date, d.expiry_date,
         public.approver_doc_requires(d.doc_id, 'requireDocumentNumber'),
         public.approver_doc_requires(d.doc_id, 'requireStartDate'),
         public.approver_doc_requires(d.doc_id, 'requireExpiryDate'),
         null::text
    from public.provider_documents d
    join public.profiles p on p.id = d.auth_user_id
   where d.auth_user_id = p_owner
  union all
  -- Vehicle documents & permits (with the car's plate).
  select 'vehicle'::text, d.id, d.auth_user_id,
         coalesce(nullif(btrim(p.name), ''), 'User'), p.phone,
         d.doc_id, coalesce(nullif(btrim(d.doc_name), ''), d.doc_id, 'Document'),
         d.file_url, d.file_url_back, d.status, null::timestamptz,
         d.document_number, d.start_date, d.expiry_date,
         public.approver_doc_requires(d.doc_id, 'requireDocumentNumber'),
         public.approver_doc_requires(d.doc_id, 'requireStartDate'),
         public.approver_doc_requires(d.doc_id, 'requireExpiryDate'),
         nullif(btrim(v.plate), '')
    from public.vehicle_documents d
    join public.profiles p on p.id = d.auth_user_id
    left join public.vehicle v on v.id = d.vehicle_id
   where d.auth_user_id = p_owner
  union all
  -- User ID / selfie documents.
  select 'identity'::text, c.id, c.user_id,
         coalesce(nullif(btrim(p.name), ''), 'User'), p.phone,
         coalesce(c.doc_type, c.kind),
         case when c.kind = 'selfie'    then 'Selfie'
              when c.doc_type = 'mykad' then 'MyKad'
              when c.doc_type = 'passport' then 'Passport'
              else coalesce(c.doc_type, c.kind, 'ID') end,
         c.file_url, c.file_url_back, c.status, c.created_at,
         null::text, null::date, c.expiry_date,
         false, false, false,
         null::text
    from public.identity_checks c
    join public.profiles p on p.id = c.user_id
   where c.user_id = p_owner
     and c.status is not null  -- skip the profile-photo rows (purpose = 'profile')
  order by 10, 2;  -- status, then doc_pk
end;
$$;
revoke execute on function public.approver_owner_documents(uuid) from public, anon;
grant execute on function public.approver_owner_documents(uuid) to authenticated;

notify pgrst, 'reload schema';
