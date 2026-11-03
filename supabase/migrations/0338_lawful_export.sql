-- ============================================================================
-- 0338 — Lawful-request export: answer a valid authority request (police /
-- MCMC / court order) by EXPORTING the data get.ride already lawfully holds
-- about ONE user. This is NOT new tracking: it only reads existing rows.
--
-- Version 20261103110000 (0338_lawful_export). Re-runnable: the table,
-- indexes and constraints "if not exists", functions "create or replace",
-- policies dropped first.
--
-- THE RULES
--   * Read-only. Nothing in a subject's own data is written or changed; the
--     only writes are the register row and the audit-log row that record THAT
--     an export was made.
--   * Full admins only. A lawful export is a whole-account disclosure, not a
--     sub-admin action, so it is gated on BOTH caller_admin_can_write
--     ('rpc:admin_lawful_export') — left unmapped in admin_table_pages, so a
--     page '*' EDIT grant is the only one that passes — AND caller_is_full_admin()
--     explicitly. No sub-admin page unlocks it.
--   * Every export is logged: a public.lawful_requests register row (who asked,
--     when, the agency, officer, reference and legal basis) and a
--     public.admin_audit_log row ('lawful_export', identifiers only — never the
--     exported data itself).
--   * The register survives the subject: subject_user_id is ON DELETE SET NULL
--     so the record of the request outlives the account.
--
-- 1. lawful_requests — the register of requests received.
-- 2. admin_lawful_export(...) — gate, log, and return the one jsonb document.
-- 3. admin_lawful_requests() — the recent register, for the audit list.
-- ============================================================================

-- ---- 1. The register ----------------------------------------------------------------------------
create table if not exists public.lawful_requests (
  id              uuid primary key default gen_random_uuid(),
  -- The person the request is about. Kept if the account is later deleted:
  -- the register of a disclosure to the authorities must survive.
  subject_user_id uuid references public.profiles(id) on delete set null,
  agency          text not null,
  officer         text,
  reference       text not null,
  legal_basis     text not null,
  notes           text,
  requested_by    uuid,
  requested_at    timestamptz not null default now(),
  exported_at     timestamptz,
  created_at      timestamptz not null default now(),
  constraint lawful_requests_lengths check (
    char_length(agency) between 1 and 120
    and char_length(reference) between 1 and 200
    and char_length(legal_basis) between 1 and 200
    and char_length(coalesce(officer, '')) <= 160
    and char_length(coalesce(notes, '')) <= 4000)
);
comment on table public.lawful_requests is
  'The register of lawful requests from the authorities answered by exporting a user''s held data (0338). No client reads it directly; full admins go through admin_lawful_requests() / admin_lawful_export().';

create index if not exists lawful_requests_subject_idx
  on public.lawful_requests (subject_user_id, requested_at desc);
create index if not exists lawful_requests_recent_idx
  on public.lawful_requests (requested_at desc);

-- No client read of the table. Admins go through the RPCs below, which are
-- SECURITY DEFINER and enforce full-admin themselves.
alter table public.lawful_requests enable row level security;
revoke all on public.lawful_requests from anon, authenticated;

-- ---- 2. The export ------------------------------------------------------------------------------
-- Reads ONLY existing rows for p_subject and returns one jsonb document.
-- Writes exactly two things that record the disclosure itself: a
-- lawful_requests register row and an admin_audit_log row.
create or replace function public.admin_lawful_export(
  p_subject     uuid,
  p_agency      text,
  p_officer     text default null,
  p_reference   text default null,
  p_legal_basis text default null,
  p_notes       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_agency  text := nullif(btrim(coalesce(p_agency, '')), '');
  v_officer text := nullif(btrim(coalesce(p_officer, '')), '');
  v_ref     text := nullif(btrim(coalesce(p_reference, '')), '');
  v_basis   text := nullif(btrim(coalesce(p_legal_basis, '')), '');
  v_notes   text := nullif(btrim(coalesce(p_notes, '')), '');
  v_profile public.profiles;
  v_request_id uuid;
  v_now     timestamptz := now();
  -- Caps, with the total counts reported beside the capped rows.
  c_trips     int := 1000;
  c_payments  int := 1000;
  c_locations int := 5000;
  v_doc jsonb;
begin
  -- Full admins only, two ways: the unmapped 'rpc:' target passes only a page
  -- '*' EDIT grant (or a direct database / service-role session), and the
  -- full-admin check is required on top of it.
  if not (public.caller_admin_can_write('rpc:admin_lawful_export')
          and public.caller_is_full_admin()) then
    raise exception 'Only a full admin can make a lawful-request export.' using errcode = '42501';
  end if;

  if v_agency is null then
    raise exception 'The agency is required (e.g. PDRM, MCMC).' using errcode = '22023';
  end if;
  if v_ref is null then
    raise exception 'A reference (case / warrant / report number) is required.' using errcode = '22023';
  end if;
  if v_basis is null then
    raise exception 'The legal basis is required (e.g. court order, CPC s.116).' using errcode = '22023';
  end if;

  select * into v_profile from public.profiles where id = p_subject;
  if not found then
    raise exception 'No such account.' using errcode = 'P0002';
  end if;

  -- Register the request first (records that the disclosure was made).
  insert into public.lawful_requests
    (subject_user_id, agency, officer, reference, legal_basis, notes, requested_by, requested_at, exported_at)
  values
    (p_subject, v_agency, v_officer, v_ref, v_basis, v_notes, v_uid, v_now, v_now)
  returning id into v_request_id;

  -- Audit: counts / identifiers only, never the exported data.
  insert into public.admin_audit_log (actor_id, action, target_profile_id, detail)
  values (v_uid, 'lawful_export', p_subject,
          jsonb_build_object('request_id', v_request_id, 'agency', v_agency,
                             'reference', v_ref, 'legal_basis', v_basis));

  -- Assemble the document by reading existing data only.
  v_doc := jsonb_build_object(
    'meta', jsonb_build_object(
      'generated_at', v_now,
      'subject_id', p_subject,
      'request', jsonb_build_object(
        'id', v_request_id, 'agency', v_agency, 'officer', v_officer,
        'reference', v_ref, 'legal_basis', v_basis, 'notes', v_notes,
        'requested_by', v_uid, 'requested_at', v_now)),

    -- Account. The FULL id number is here: this is the lawful disclosure, not
    -- a screen (the UI masks it). display_id is the public account code.
    'account', jsonb_build_object(
      'id', v_profile.id,
      'display_id', v_profile.display_id,
      'name', v_profile.name,
      'phone', v_profile.phone,
      'email', v_profile.email,
      'gender', v_profile.gender,
      'date_of_birth', v_profile.birth_date,
      'nationality', v_profile.nationality,
      'address', v_profile.address,
      'id_type', v_profile.id_type,
      'id_number', v_profile.ic,
      'id_number_typed', v_profile.id_number_typed,
      'id_number_read', v_profile.id_number_read,
      'id_name', v_profile.id_name,
      'status', v_profile.status,
      'profile_status', v_profile.profile_status,
      'created_at', v_profile.created_at,
      'joined_at', v_profile.joined_at,
      'deleted_at', v_profile.deleted_at),

    -- Devices / sessions.
    'sessions', (
      with s as (
        select * from public.user_sessions
         where user_id = p_subject
         order by captured_at desc
         limit 500)
      select jsonb_build_object(
        'total', (select count(*) from public.user_sessions where user_id = p_subject),
        'returned', (select count(*) from s),
        'rows', coalesce((select jsonb_agg(jsonb_build_object(
          'event_type', s.event_type,
          'ip_address', s.ip_address,
          'isp', s.network_operator,
          'network_type', s.network_type,
          'os_name', s.os_name,
          'os_version', s.os_version,
          'device_brand', s.device_brand,
          'device_model_name', s.device_model_name,
          'is_physical_device', s.is_physical_device,
          'app_version', s.app_version,
          'app_build_version', s.app_build_version,
          'app_id', s.app_id,
          'captured_at', s.captured_at) order by s.captured_at desc) from s), '[]'::jsonb))),

    -- Trips, as rider or as partner. The other party's id is included.
    'trips', (
      with t as (
        select * from public.ride_requests
         where rider_id = p_subject or partner_id = p_subject
         order by created_at desc
         limit c_trips)
      select jsonb_build_object(
        'total', (select count(*) from public.ride_requests
                   where rider_id = p_subject or partner_id = p_subject),
        'returned', (select count(*) from t),
        'rows', coalesce((select jsonb_agg(jsonb_build_object(
          'id', t.id,
          'role', case when t.rider_id = p_subject then 'rider' else 'partner' end,
          'status', t.status,
          'service', t.service,
          'pickup_name', t.pickup_name,
          'pickup_lat', t.pickup_lat,
          'pickup_lng', t.pickup_lng,
          'drop_name', t.drop_name,
          'drop_lat', t.drop_lat,
          'drop_lng', t.drop_lng,
          'fare', t.fare,
          'ride_fare', t.ride_fare,
          'rider_id', t.rider_id,
          'partner_id', t.partner_id,
          'other_party_id', case when t.rider_id = p_subject then t.partner_id else t.rider_id end,
          'created_at', t.created_at,
          'accepted_at', t.accepted_at,
          'started_at', t.started_at,
          'completed_at', t.completed_at,
          'cancelled_at', t.cancelled_at) order by t.created_at desc) from t), '[]'::jsonb))),

    -- Payments and current balances.
    'payments', (
      with w as (
        select * from public.wallet_transactions
         where user_id = p_subject
         order by created_at desc
         limit c_payments)
      select jsonb_build_object(
        'total', (select count(*) from public.wallet_transactions where user_id = p_subject),
        'returned', (select count(*) from w),
        'balances', coalesce((select jsonb_agg(jsonb_build_object(
            'wallet_type', b.wallet_type, 'balance', b.balance, 'currency', b.currency,
            'updated_at', b.updated_at)) from public.wallets b where b.user_id = p_subject), '[]'::jsonb),
        'rows', coalesce((select jsonb_agg(jsonb_build_object(
          'kind', w.kind,
          'wallet_type', w.wallet_type,
          'amount', w.amount,
          'balance_after', w.balance_after,
          'method', w.method,
          'note', w.note,
          'ride_id', w.ride_id,
          'created_at', w.created_at) order by w.created_at desc) from w), '[]'::jsonb))),

    -- Location history.
    'location_history', (
      with l as (
        select * from public.user_location_history
         where user_id = p_subject
         order by captured_at desc
         limit c_locations)
      select jsonb_build_object(
        'total', (select count(*) from public.user_location_history where user_id = p_subject),
        'returned', (select count(*) from l),
        'earliest', (select min(captured_at) from public.user_location_history where user_id = p_subject),
        'latest', (select max(captured_at) from public.user_location_history where user_id = p_subject),
        'rows', coalesce((select jsonb_agg(jsonb_build_object(
          'lat', l.latitude,
          'lng', l.longitude,
          'accuracy', l.accuracy,
          'speed', l.speed,
          'heading', l.heading,
          'captured_at', l.captured_at) order by l.captured_at desc) from l), '[]'::jsonb))),

    -- Safety incidents involving the subject (as reporter, rider or partner).
    'safety', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', si.id,
        'ride_id', si.ride_id,
        'reporter_role', si.reporter_role,
        'is_reporter', si.reporter_id = p_subject,
        'status', si.status,
        'lat', si.lat,
        'lng', si.lng,
        'location_at', si.location_at,
        'note', si.note,
        'created_at', si.created_at,
        'acknowledged_at', si.acknowledged_at,
        'resolved_at', si.resolved_at) order by si.created_at desc), '[]'::jsonb)
      from public.safety_incidents si
      where si.reporter_id = p_subject or si.rider_id = p_subject or si.partner_id = p_subject),

    -- Deletion: any request rows + whether the account is deleted.
    'deletion', jsonb_build_object(
      'account_deleted', (v_profile.deleted_at is not null
                          or v_profile.final_deleted_at is not null
                          or v_profile.profile_status = 'Deleted'),
      'deleted_at', v_profile.deleted_at,
      'final_deleted_at', v_profile.final_deleted_at,
      'deletion_reason', v_profile.deletion_reason,
      'requests', coalesce((select jsonb_agg(jsonb_build_object(
          'id', d.id,
          'method', d.method,
          'source', d.source,
          'status', d.status,
          'reason', d.reason,
          'confirmed_at', d.confirmed_at,
          'grace_until', d.grace_until,
          'deleted_at', d.deleted_at,
          'cancelled_at', d.cancelled_at,
          'cancel_reason', d.cancel_reason,
          'created_at', d.created_at) order by d.created_at desc)
        from public.account_deletion_requests d where d.user_id = p_subject), '[]'::jsonb)));

  return v_doc;
end;
$$;
revoke execute on function public.admin_lawful_export(uuid, text, text, text, text, text) from public, anon;
grant execute on function public.admin_lawful_export(uuid, text, text, text, text, text) to authenticated;

-- ---- 3. The register, for the audit list --------------------------------------------------------
create or replace function public.admin_lawful_requests(p_limit integer default 200)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 200), 1), 1000);
begin
  if not (public.caller_admin_can_write('rpc:admin_lawful_export')
          and public.caller_is_full_admin()) then
    raise exception 'Only a full admin can read the lawful-request register.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(row_to_json(x)::jsonb order by x.requested_at desc)
    from (
      select r.id, r.subject_user_id, p.name as subject_name, p.display_id as subject_display_id,
             r.agency, r.officer, r.reference, r.legal_basis,
             r.requested_by, r.requested_at, r.exported_at
        from public.lawful_requests r
        left join public.profiles p on p.id = r.subject_user_id
       order by r.requested_at desc
       limit v_limit
    ) x), '[]'::jsonb);
end;
$$;
revoke execute on function public.admin_lawful_requests(integer) from public, anon;
grant execute on function public.admin_lawful_requests(integer) to authenticated;

notify pgrst, 'reload schema';
