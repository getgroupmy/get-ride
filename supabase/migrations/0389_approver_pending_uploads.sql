-- ============================================================================
-- 0389: Approvals → "Pending Upload" — every required document still missing
-- across the people an approver covers, so they can nudge each one from one
-- list (the same push the My Team document tab sends, migration 0384).
--
-- This aggregates what approver_addable_documents(member) returns per member
-- (required, active, non-vehicle documents the member has not uploaded) across
-- every covered member, using the same coverage rule as
-- approver_covered_partners, and joins the per-(member, document) reminder
-- counters so each row shows how many times it has been nudged and when last.
--
-- Gated on can_upload (the list exists to request uploads, which can_upload
-- already governs). Capped so an 'all'-scope approver can't pull an unbounded
-- payload; p_query filters by member name.
-- ============================================================================

create or replace function public.approver_pending_uploads(
  p_query text default null,
  p_limit int default 300
) returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  a        public.approvers;
  v_me     uuid := auth.uid();
  v_lim    int  := greatest(1, least(coalesce(p_limit, 300), 1000));
  v_q      text := nullif(btrim(coalesce(p_query, '')), '');
  v_tags   text[];
  v        jsonb;
begin
  if v_me is null then return '[]'::jsonb; end if;
  select * into a from public.approvers
   where profile_id = v_me and active and (ends_at is null or ends_at > now());
  if not found or not a.can_upload then return '[]'::jsonb; end if;

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
  rows as (
    select c.id as member_id, c.name as member_name, c.phone as member_phone,
           rd.id as doc_id,
           coalesce(nullif(btrim(rd.values->>'name'), ''), 'Document') as doc_name,
           coalesce(dur.sent_count, 0) as sent_count,
           dur.last_sent_at
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
     order by lower(c.name), c.id, lower(coalesce(nullif(btrim(rd.values->>'name'), ''), 'Document'))
     limit v_lim
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'member_id',    member_id,
           'member_name',  member_name,
           'member_phone', member_phone,
           'source',       'partner',
           'doc_id',       doc_id,
           'doc_key',      doc_id::text,
           'name',         doc_name,
           'sent_count',   sent_count,
           'last_sent_at', last_sent_at)), '[]'::jsonb)
    into v from rows;

  return v;
end;
$function$;

revoke all on function public.approver_pending_uploads(text, int) from public;
grant execute on function public.approver_pending_uploads(text, int) to authenticated;
