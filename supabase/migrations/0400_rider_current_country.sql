-- ============================================================================
-- 0400 — A rider's current country drives the ID requirement by where they are.
--
-- The ID / Passport rule is "the country they are using the service in"
-- (migration 0342 rider_id_gate). For a partner that is their service country
-- (0399). For a plain user (rider) it is their live location — not stored
-- anywhere queryable. This adds profiles.current_country, which the app writes
-- from the device's location (reverse-geocoded country), and uses it:
--   * set_my_current_country(country) — the signed-in person records their own
--     current country (owner-only; cleared with NULL/'' when unknown).
--   * approver_pending_uploads lists a plain USER for ID when their current
--     country requires it (partners stay on service_countries, 0399).
--   * rider_id_gate_block keys on current_country first, then nationality, then
--     the master rule — so the booking gate also follows where they are.
--
-- Backward compatible: current_country starts NULL for everyone, so the gate
-- falls back to nationality exactly as before until the app populates it.
-- ============================================================================

alter table public.profiles
  add column if not exists current_country    text,
  add column if not exists current_country_at timestamptz;

-- ---- The signed-in person records their own current country ---------------------------------------
create or replace function public.set_my_current_country(p_country text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me  uuid := auth.uid();
  v_val text := nullif(btrim(coalesce(p_country, '')), '');
begin
  if v_me is null then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  update public.profiles
     set current_country = left(v_val, 80),
         current_country_at = now()
   where id = v_me
     and current_country is distinct from left(v_val, 80);
end;
$$;
revoke execute on function public.set_my_current_country(text) from public, anon;
grant execute on function public.set_my_current_country(text) to authenticated;

-- ---- Pending Upload: list a plain USER for ID by their current country -----------------------------
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
  -- ID / Passport, for a PARTNER by service country (0399) or a plain USER by
  -- their current country (0400), when the rider_id_gate rule (0342; master as
  -- the per-country default) requires it and they have not verified or uploaded
  -- one yet.
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
     where coalesce(p.id_verified::text, '') is distinct from 'Verified'
       and not exists (select 1 from public.identity_checks ic
                        where ic.user_id = c.id and ic.kind = 'id'
                          and ic.status in ('Pending Review', 'Approved'))
       and case when c.is_partner then
             exists (select 1 from public.partners pr
                      where pr.auth_user_id = c.id
                        and exists (select 1 from unnest(pr.service_countries) sc
                                     where coalesce((coalesce(v_gate -> sc, v_gate -> 'master') ->> 'require')::boolean, false)))
           else
             (p.current_country is not null
              and coalesce((coalesce(v_gate -> p.current_country, v_gate -> 'master') ->> 'require')::boolean, false))
           end
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

-- ---- The booking gate follows where they are (current country), then nationality -----------------
create or replace function public.rider_id_gate_block(p_rider uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_prof public.profiles;
  v_cfg jsonb := public.rider_id_gate_config();
  v_rule jsonb;
  v_nth int;
begin
  if p_rider is null then
    return false;
  end if;
  select * into v_prof from public.profiles where id = p_rider;
  if not found then
    return false;
  end if;
  -- Where they are using the service (current country) wins over their passport
  -- country (nationality); the master rule is the default (migration 0400).
  v_rule := coalesce(v_cfg -> nullif(btrim(coalesce(v_prof.current_country, '')), ''),
                     v_cfg -> v_prof.nationality,
                     v_cfg -> 'master');
  if v_rule is null or not (v_rule->>'require')::boolean then
    return false;
  end if;
  if v_prof.id_verified = 'Verified' then
    return false;
  end if;
  v_nth := coalesce((v_rule->>'nthBooking')::int, 1);
  return coalesce(v_prof.total_rides, 0) >= (v_nth - 1);
end;
$$;
revoke execute on function public.rider_id_gate_block(uuid) from public, anon;
grant execute on function public.rider_id_gate_block(uuid) to authenticated;

notify pgrst, 'reload schema';
