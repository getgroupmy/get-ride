-- ============================================================================
-- 0390: Pending-upload reminders for every covering approver, and vehicle docs.
--
-- Two changes, both about who sees what needs uploading and who may nudge:
--
-- 1. Sub-approver visibility. Seeing the missing documents and sending an
--    upload reminder is no longer gated on can_upload. A verify-only or
--    approve-only approver can see what a covered member still has to upload
--    and nudge them; only uploading the document *on their behalf* still needs
--    can_upload (that gate stays, in approver_create_document and in the app).
--    So approver_addable_documents, approver_pending_uploads and
--    approver_request_document_upload drop their can_upload checks (coverage is
--    still required).
--
-- 2. Vehicle documents in the Pending Upload list. approver_pending_uploads now
--    also returns the required vehicle-category documents a covered member's
--    vehicles have not uploaded, each with its vehicle id + plate, so they can
--    be nudged from the same list (source 'vehicle', keyed per vehicle).
-- ============================================================================

-- 1a. Missing partner documents visible to any covering approver (My Team).
create or replace function public.approver_addable_documents(p_member uuid)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare a public.approvers; v_me uuid := auth.uid(); v jsonb;
begin
  if v_me is null then return '[]'::jsonb; end if;
  select * into a from public.approvers where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or p_member is null or not public.approver_covers(p_member) then
    return '[]'::jsonb;
  end if;
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v from (
    select jsonb_build_object(
             'doc_id', rd.id,
             'name', coalesce(nullif(btrim(rd.values->>'name'), ''), 'Document'),
             'required', coalesce((rd.values->>'required')::boolean, false),
             'is_pwd', coalesce((rd.values->>'isPwd')::boolean, false),
             'requires_number', coalesce((rd.values->>'requireDocumentNumber')::boolean, false),
             'requires_start', coalesce((rd.values->>'requireStartDate')::boolean, false),
             'requires_expiry', coalesce((rd.values->>'requireExpiryDate')::boolean, false)) as x
      from public.required_document rd
     where coalesce((rd.values->>'active')::boolean, false)
       and not (coalesce(nullif(rd.values->>'docTypes', ''), '[]')::jsonb ?| public._vehicle_doc_categories())
       and not exists (select 1 from public.provider_documents d
                        where d.auth_user_id = p_member and d.doc_id = rd.id::text)
  ) q;
  return v;
end;
$function$;

-- 1b. Sending an upload reminder is open to any covering approver.
create or replace function public.approver_request_document_upload(
  p_member uuid, p_source text, p_doc_key text, p_label text DEFAULT NULL::text, p_vehicle uuid DEFAULT NULL::uuid)
 returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  a public.approvers; v_me uuid := auth.uid();
  v_source text := lower(btrim(coalesce(p_source, '')));
  v_key    text := btrim(coalesce(p_doc_key, ''));
  v_label  text := nullif(btrim(coalesce(p_label, '')), '');
  v_count  int; v_at timestamptz;
begin
  if v_me is null then raise exception 'not_authorized' using errcode = '42501'; end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found then raise exception 'not_allowed'; end if;
  if p_member is null or v_key = '' then raise exception 'bad_input' using errcode = '22023'; end if;
  if v_source not in ('partner', 'vehicle', 'identity') then
    raise exception 'bad_input' using errcode = '22023';
  end if;
  if not public.approver_covers(p_member) then raise exception 'out_of_scope'; end if;

  insert into public.document_upload_requests
      (target_user_id, source, doc_key, vehicle_id, doc_label, sent_count, last_sent_at, last_sent_by)
    values (p_member, v_source, v_key, p_vehicle, v_label, 1, now(), v_me)
  on conflict (target_user_id, source, doc_key,
               coalesce(vehicle_id, '00000000-0000-0000-0000-000000000000'::uuid))
    do update set sent_count   = public.document_upload_requests.sent_count + 1,
                  last_sent_at = now(),
                  last_sent_by = v_me,
                  doc_label    = coalesce(excluded.doc_label, public.document_upload_requests.doc_label)
  returning sent_count, last_sent_at into v_count, v_at;

  perform public.approval_push_send(
    p_member,
    jsonb_build_object(
      'title', 'Document needed',
      'body', case when v_label is not null
                   then 'Please upload your ' || v_label || ' to continue.'
                   else 'Please upload a pending document to continue.' end),
    jsonb_build_object('type', 'document_request', 'source', v_source, 'doc_key', v_key));

  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_me, 'approver.request_document', p_member,
          jsonb_build_object('source', v_source, 'doc_key', v_key,
                             'vehicle_id', p_vehicle, 'count', v_count));

  return jsonb_build_object('ok', true, 'sent_count', v_count, 'last_sent_at', v_at);
end;
$function$;

-- 2. Pending uploads across covered members: partner docs + vehicle docs, open
--    to any covering approver.
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
    select p.id, coalesce(nullif(btrim(p.name), ''), 'User') as name, p.phone
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
  partner_rows as (
    select c.id as member_id, c.name as member_name, c.phone as member_phone,
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
     where not exists (select 1 from public.provider_documents d
                        where d.auth_user_id = c.id and d.doc_id = rd.id::text)
  ),
  vehicle_rows as (
    select c.id as member_id, c.name as member_name, c.phone as member_phone,
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
    select * from partner_rows
    union all
    select * from vehicle_rows
    order by lower(member_name), member_id, source, coalesce(plate, ''), lower(doc_name)
    limit v_lim
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'member_id',    member_id,
           'member_name',  member_name,
           'member_phone', member_phone,
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

revoke all on function public.approver_pending_uploads(text, int) from public;
grant execute on function public.approver_pending_uploads(text, int) to authenticated;

-- 1c. Missing vehicle documents visible to any covering approver (the vehicle
--     sheet gates the section on can_manage_vehicle; uploading still needs
--     can_upload, in the app and in approver_create_vehicle_document).
create or replace function public.approver_addable_vehicle_documents(p_vehicle uuid)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare a public.approvers; v_me uuid := auth.uid(); v_owner uuid; v jsonb;
begin
  if v_me is null then return '[]'::jsonb; end if;
  select * into a from public.approvers where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or p_vehicle is null then return '[]'::jsonb; end if;
  select auth_user_id into v_owner from public.vehicle where id = p_vehicle;
  if v_owner is null or not public.approver_covers(v_owner) then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v from (
    select jsonb_build_object('doc_id', rd.id,
             'name', coalesce(nullif(btrim(rd.values->>'name'), ''), 'Document'),
             'required', coalesce((rd.values->>'required')::boolean, false),
             'is_pwd', coalesce((rd.values->>'isPwd')::boolean, false)) as x
      from public.required_document rd
     where coalesce((rd.values->>'active')::boolean, false)
       and (coalesce(nullif(rd.values->>'docTypes', ''), '[]')::jsonb ? 'a7d71867-ac2a-4c0c-ae07-87e5d500693c')
       and not exists (select 1 from public.vehicle_documents d where d.vehicle_id = p_vehicle and d.doc_id = rd.id::text)
  ) q;
  return v;
end;
$function$;
