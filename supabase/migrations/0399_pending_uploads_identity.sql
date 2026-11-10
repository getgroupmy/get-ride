-- ============================================================================
-- 0399 — Pending Upload lists ID / Passport where the country requires it.
--
-- Migration 0398 stopped listing partner/driver documents for plain users and
-- split the list into Partners and Users. This fills the Users side (and adds
-- to partners too): where the person's country requires a verified photo ID,
-- and they have not verified one yet, the list shows an "ID / Passport" row so
-- the approver can nudge them — whether they are a partner or a plain user.
--
-- "Required by the local authorities" reuses the existing per-country rule the
-- admin already manages (migration 0342, rider_id_gate, in Admin → Settings),
-- keyed by the person's profile country (profiles.nationality, else master) —
-- no second setting. A person needs the row when that rule's `require` is on,
-- their id_verified is not 'Verified', and they have no ID check already
-- uploaded (Pending Review or Approved). The nudge path
-- (approver_request_document_upload) already accepts the 'identity' source.
-- ============================================================================

create or replace function public.approver_pending_uploads(
  p_query text default null, p_limit int default 300)
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  a public.approvers; v_me uuid := auth.uid();
  v_lim int := greatest(1, least(coalesce(p_limit, 300), 1000));
  v_q   text := nullif(btrim(coalesce(p_query, '')), '');
  v_tags text[]; v jsonb;
  v_gate jsonb := public.rider_id_gate_config();
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
  -- actually partners (migration 0398).
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
  -- ID / Passport, for partner and user alike, where the person's country
  -- requires it (rider_id_gate, migration 0342) and they have not verified or
  -- uploaded one yet (migration 0399).
  identity_rows as (
    select c.id as member_id, c.name as member_name, c.phone as member_phone, c.reachable, c.location,
           c.is_partner,
           'identity'::text as source, 'id'::text as doc_key,
           'ID / Passport'::text as doc_name,
           null::uuid as vehicle_id, null::text as plate,
           coalesce(dur.sent_count, 0) as sent_count, dur.last_sent_at
      from covered c
      join public.profiles p on p.id = c.id
      left join public.document_upload_requests dur
        on dur.target_user_id = c.id and dur.source = 'identity'
       and dur.doc_key = 'id' and dur.vehicle_id is null
     where coalesce((coalesce(v_gate -> p.nationality, v_gate -> 'master') ->> 'require')::boolean, false)
       and coalesce(p.id_verified::text, '') is distinct from 'Verified'
       and not exists (select 1 from public.identity_checks ic
                        where ic.user_id = c.id and ic.kind = 'id'
                          and ic.status in ('Pending Review', 'Approved'))
  ),
  rows as (
    select * from (
      select * from partner_rows
      union all
      select * from vehicle_rows
      union all
      select * from identity_rows
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
