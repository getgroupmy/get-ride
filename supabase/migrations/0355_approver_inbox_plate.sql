-- Approver inbox: return the vehicle's plate with each vehicle document, so the
-- Approvals list and review sheet can show which car a document belongs to
-- (e.g. "Ali · Vehicle document · ABC 1234"). Adds a trailing `plate` column to
-- approver_pending_documents() (0350); partner and identity rows return null.
-- The return type changes, so the function is dropped and recreated.

drop function if exists public.approver_pending_documents();

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
  submitted_at  timestamptz,
  plate         text)          -- vehicle plate (vehicle rows only)
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
         d.file_url, d.file_url_back, d.status, null::timestamptz, null::text
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
         d.file_url, d.file_url_back, d.status, null::timestamptz, nullif(btrim(v.plate), '')
    from public.vehicle_documents d
    join public.profiles p on p.id = d.auth_user_id
    left join public.vehicle v on v.id = d.vehicle_id
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
         c.file_url, c.file_url_back, c.status, c.created_at, null::text
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
