-- ============================================================================
-- 0280 — Reports: an admin asks for a report in plain words.
--
-- Applied by hand as version 20261024100000 (0280_ai_reports in
-- supabase_migrations.schema_migrations). Re-runnable: every object is
-- created with "if not exists" / "or replace", policies and the cron job are
-- dropped first. 0279 is another branch's number; the gap is fine.
--
-- 1. Who may run reports (Admin -> Reports, page key admin-reports):
--      * a full admin (any page '*' grant) sees everything;
--      * a sub-admin holding the Reports page sees, in the datasets that
--        have a place (rides, SOS, ratings by the ride's pickup; partners
--        and vehicles by the areas they serve), only what is inside the
--        region set on that grant (admin_access.region, as God View, 0270).
--        A Reports grant without a region sees none of those rows until a
--        full admin sets one; the datasets without a place are not limited;
--      * names, phone numbers, IC and email are in the catalogue only for a
--        caller who also holds a Users page (riders) or a Partners /
--        Vehicles page (partners, vehicles), read or edit, the pages that
--        already show them. PINs, hashes, ID images and keys never are;
--      * everyone else is refused (42501).
-- 2. The approved dataset catalogue (ai_report_catalogue_all): each dataset
--    is a view (ai_report_v_*, not readable by clients) whose columns are
--    the fields. ai_report_catalogue() hands the caller their part of it:
--    what the AI is told about and what the page offers. The AI never sees
--    a row.
-- 3. ai_report_run(plan): checks a report plan
--      {dataset, columns[], filters[{field, op, value}], period {from, to} |
--       {preset, days}, group_by[], measures[{field, agg}],
--       sort[{field, dir}], limit, title}
--    against the caller's catalogue (an unknown dataset, field, op or value
--    is refused with a reason a person can read, 22023) and runs it: the
--    query is built from the view's own column names only (format %I),
--    values as quoted literals with typed casts (%L), SELECT only, 15 s at
--    most, at most 50,000 rows (truncated says so). Periods and day / week /
--    month / year groups are Malaysia's (UTC+8). Each run is logged in
--    admin_audit_log ('ai_report.run': dataset, rows, the plan).
-- 4. Saved reports (ai_reports_saved) and email schedules
--    (ai_report_schedules): read by anyone who may run reports, written with
--    an EDIT grant on Reports (admin_table_pages) or by a full admin.
--    A schedule runs every day, on chosen weekdays or on a day of the month
--    (1 to 28, or the last day) at a time, Malaysia time; next_run_at is
--    worked out here (ai_report_next_run). Each run covers the previous
--    day / week / month, the month to date or the last N whole days.
-- 5. pg_cron every 5 minutes: ai_report_schedules_due() claims the due
--    schedules (for update skip locked), moves each to its next run and
--    POSTs their ids to the ai-report-email function over pg_net with the
--    push webhook secret (x-push-secret, Vault push_webhook_secret, 0128)
--    exactly as location_ping_kick (0276). "Send now" goes the same way
--    (ai_report_schedule_send_now). The function asks
--    ai_report_schedule_job(id) (service role only) for the report, run with
--    the scope of the admin who made the schedule (checked again each run),
--    and logs each send in ai_report_sends (ai_report_send_log).
-- 6. Link-only emails keep their files in the private ai-reports bucket
--    (signed links for 7 days, made by the function).
--
-- The functions: supabase/functions/ai-report (plain words -> a checked
-- plan, with the AI service set in API Keys) and ai-report-email (both
-- deploy --no-verify-jwt; each checks its callers).
-- ============================================================================

-- ---- 1. Who is asking ---------------------------------------------------------------------------
-- The scope of one admin: ok (may run reports), scoped (limited to region),
-- region, users / partners (may see personal fields), edit (may save).
create or replace function public.ai_report_scope_for(p_uid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_full_edit boolean;
  v_grant record;
  v_users boolean;
  v_partners boolean;
begin
  if p_uid is null then
    return jsonb_build_object('ok', false);
  end if;
  select bool_or(a.access_level = 'edit') into v_full_edit
    from public.admin_access a where a.profile_id = p_uid and a.page = '*';
  if v_full_edit is not null then
    return jsonb_build_object('ok', true, 'scoped', false, 'region', null, 'users', true, 'partners', true,
                              'edit', v_full_edit);
  end if;
  select a.access_level, a.region into v_grant
    from public.admin_access a where a.profile_id = p_uid and a.page = 'admin-reports'
   order by (a.access_level = 'edit') desc limit 1;
  if not found then
    return jsonb_build_object('ok', false);
  end if;
  select coalesce(bool_or(a.page like 'admin-users%' or a.page in ('admin-user-edit', 'admin-user-add')), false),
         coalesce(bool_or(a.page like 'admin-partners%' or a.page in ('admin-partner-edit', 'admin-partner-add')
                          or a.page like 'admin-vehicles%' or a.page in ('admin-vehicle-edit', 'admin-vehicle-add')), false)
    into v_users, v_partners
    from public.admin_access a where a.profile_id = p_uid;
  return jsonb_build_object('ok', true, 'scoped', true, 'region', v_grant.region, 'users', v_users,
                            'partners', v_partners, 'edit', v_grant.access_level = 'edit');
end;
$$;
revoke execute on function public.ai_report_scope_for(uuid) from public, anon, authenticated;

-- The caller's: a direct database session (migrations, psql, cron) and the
-- service role see everything.
create or replace function public.ai_report_caller_scope()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
begin
  if v_claims is null or v_claims = '' or coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    return jsonb_build_object('ok', true, 'scoped', false, 'region', null, 'users', true, 'partners', true,
                              'edit', true);
  end if;
  return public.ai_report_scope_for(auth.uid());
end;
$$;
revoke execute on function public.ai_report_caller_scope() from public, anon, authenticated;

-- For the policies: may the caller run reports at all.
create or replace function public.ai_report_caller_ok()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((public.ai_report_caller_scope() ->> 'ok')::boolean, false);
$$;
revoke execute on function public.ai_report_caller_ok() from public, anon;
grant execute on function public.ai_report_caller_ok() to authenticated, service_role;

-- A partner or vehicle serving [countries] / [states] / [cities] is inside
-- a region {country, state, city, suburb} when each level the region names
-- matches one of them (a suburb is checked as its city). No region, or no
-- country in it: nobody.
create or replace function public.ai_report_in_region_names(
  p_region jsonb, p_countries text[], p_states text[], p_cities text[]
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_c text := btrim(coalesce(p_region ->> 'country', ''));
  v_s text := btrim(coalesce(p_region ->> 'state', ''));
  v_t text := btrim(coalesce(p_region ->> 'city', ''));
begin
  if p_region is null or v_c = '' then
    return false;
  end if;
  if not exists (select 1 from unnest(coalesce(p_countries, '{}')) x(n) where public.region_name_matches(v_c, x.n)) then
    return false;
  end if;
  if v_s <> '' and not exists (select 1 from unnest(coalesce(p_states, '{}')) x(n)
                                where public.region_name_matches(v_s, x.n)) then
    return false;
  end if;
  if v_t <> '' and not exists (select 1 from unnest(coalesce(p_cities, '{}')) x(n)
                                where public.region_name_matches(v_t, x.n)) then
    return false;
  end if;
  return true;
end;
$$;
revoke execute on function public.ai_report_in_region_names(jsonb, text[], text[], text[]) from public, anon, authenticated;

-- ---- 2. The datasets ----------------------------------------------------------------------------
-- Each column is a field of the catalogue; columns starting with "_" are
-- the place used for a sub-admin's region and are never offered.
create or replace view public.ai_report_v_rides as
select r.status, r.service, r.payment_mode as payment_type, r.payment_status,
       r.country, r.state, r.city, r.suburb,
       r.created_at, r.accepted_at, r.completed_at, r.cancelled_at,
       coalesce(r.ride_fare, r.fare) as fare, r.commission_amount as commission,
       r.distance_km, r.duration_min, r.toll_charges, r.promo_discount,
       r.cancel_reason, r.cancel_requested_by as cancelled_by, r.currency,
       r.partner_plate as plate, r.partner_vehicle as vehicle,
       r.partner_id::text as driver_id, r.rider_id::text as rider_id,
       r.rider_name, r.rider_phone, r.partner_name as driver_name, r.partner_phone as driver_phone,
       r.pickup_lat as _lat, r.pickup_lng as _lng,
       r.country as _country, r.state as _state, r.city as _city, r.suburb as _suburb
  from public.ride_requests r;

create or replace view public.ai_report_v_partners as
select p.status::text as status, p.partner_type, array_to_string(p.partner_types, ', ') as partner_types,
       p.vehicle_type, p.energy_type, p.make, p.model, p.plate, p.permit::text as permit, p.documents_ok,
       p.rating, p.total_rides, coalesce(p.joined_at, p.created_at) as joined_at,
       array_to_string(p.service_states, ', ') as service_states,
       array_to_string(p.service_cities, ', ') as service_cities,
       p.name, p.phone, p.email, p.ic,
       p.service_countries as _countries, p.service_states as _states, p.service_cities as _cities
  from public.partners p;

create or replace view public.ai_report_v_users as
select p.status::text as status, p.profile_status::text as profile_status, p.id_verified::text as id_verified,
       p.nationality, p.gender::text as gender, p.total_rides, p.rider_rating,
       coalesce(p.joined_at, p.created_at) as joined_at, p.app_platform, p.app_version,
       (p.deleted_at is not null) as deleted, p.documents_ok,
       p.name, p.phone, p.email, p.ic
  from public.profiles p;

create or replace view public.ai_report_v_vehicles as
select v.status::text as status, v.permit::text as permit, v.documents_ok, v.vehicle_type, v.energy_type,
       v.make, v.model, v.year, v.color, v.plate, coalesce(v.joined_at, v.created_at) as joined_at,
       array_to_string(v.service_states, ', ') as service_states,
       v.owner_name, v.owner_phone,
       v.service_countries as _countries, v.service_states as _states, v.service_cities as _cities
  from public.vehicle v;

create or replace view public.ai_report_v_wallet as
select w.wallet_type, w.kind, w.method, w.status, w.amount, w.created_at
  from public.wallet_transactions w;

create or replace view public.ai_report_v_payments as
select i.purpose, i.provider, i.status, i.amount, i.currency, i.test_mode, i.created_at, i.paid_at
  from public.payment_intents i;

create or replace view public.ai_report_v_sos as
select s.status, s.reporter_role, s.created_at, s.acknowledged_at, s.resolved_at,
       round((extract(epoch from (s.acknowledged_at - s.created_at)) / 60.0)::numeric, 1) as response_min,
       round((extract(epoch from (s.resolved_at - s.created_at)) / 60.0)::numeric, 1) as resolve_min,
       s.alert_round, r.service, r.state, r.city, s.plate,
       s.reporter_name, s.reporter_phone, s.partner_name as driver_name,
       coalesce(s.lat, r.pickup_lat) as _lat, coalesce(s.lng, r.pickup_lng) as _lng,
       r.country as _country, r.state as _state, r.city as _city, r.suburb as _suburb
  from public.safety_incidents s
  left join public.ride_requests r on r.id = s.ride_id;

create or replace view public.ai_report_v_ratings as
select g.stars, g.created_at, (nullif(btrim(coalesce(g.comment, '')), '') is not null) as has_comment,
       r.service, r.state, r.city, g.partner_id::text as driver_id,
       r.partner_name as driver_name, g.comment,
       r.pickup_lat as _lat, r.pickup_lng as _lng,
       r.country as _country, r.state as _state, r.city as _city, r.suburb as _suburb
  from public.ride_ratings g
  join public.ride_requests r on r.id = g.request_id;

create or replace view public.ai_report_v_signups as
select 'User'::text as kind, coalesce(p.joined_at, p.created_at) as joined_at, p.nationality, p.status::text as status
  from public.profiles p
union all
select 'Partner'::text, coalesce(p.joined_at, p.created_at), null::text, p.status::text
  from public.partners p;

do $$
declare
  v text;
begin
  foreach v in array array['ai_report_v_rides', 'ai_report_v_partners', 'ai_report_v_users', 'ai_report_v_vehicles',
                           'ai_report_v_wallet', 'ai_report_v_payments', 'ai_report_v_sos', 'ai_report_v_ratings',
                           'ai_report_v_signups'] loop
    execute format('revoke all on public.%I from public, anon, authenticated', v);
    execute format('comment on view public.%I is %L', v,
                   'A Reports dataset (0280): read only by ai_report_run, never by clients.');
  end loop;
end $$;

-- The approved catalogue: every dataset and field a report may use. type
-- is text, number, time or bool; personal is the People pages a field
-- needs (users or partners); area how a sub-admin's region applies (point:
-- the place in _lat / _lng / _country.. ; names: the _countries / _states /
-- _cities served; none: not limited). list is what a plain list shows.
create or replace function public.ai_report_catalogue_all()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select $cat${
  "datasets": [
    {"id": "rides", "label": "Rides", "view": "ai_report_v_rides", "area": "point", "time": "created_at",
     "about": "Every ride request: booked, completed or cancelled, with its fare and commission.",
     "list": ["created_at", "status", "service", "city", "fare", "commission", "payment_type"],
     "fields": [
      {"id": "status", "label": "Status", "type": "text", "values": ["open", "accepted", "arrived", "on_trip", "completed", "cancelled", "expired"]},
      {"id": "service", "label": "Service", "type": "text"},
      {"id": "payment_type", "label": "Payment type", "type": "text"},
      {"id": "payment_status", "label": "Payment status", "type": "text"},
      {"id": "country", "label": "Country", "type": "text"},
      {"id": "state", "label": "State", "type": "text"},
      {"id": "city", "label": "City", "type": "text"},
      {"id": "suburb", "label": "Area", "type": "text"},
      {"id": "created_at", "label": "Booked", "type": "time"},
      {"id": "accepted_at", "label": "Accepted", "type": "time"},
      {"id": "completed_at", "label": "Completed", "type": "time"},
      {"id": "cancelled_at", "label": "Cancelled", "type": "time"},
      {"id": "fare", "label": "Fare (RM)", "type": "number"},
      {"id": "commission", "label": "Commission (RM)", "type": "number"},
      {"id": "distance_km", "label": "Distance (km)", "type": "number"},
      {"id": "duration_min", "label": "Duration (min)", "type": "number"},
      {"id": "toll_charges", "label": "Tolls (RM)", "type": "number"},
      {"id": "promo_discount", "label": "Promo discount (RM)", "type": "number"},
      {"id": "cancel_reason", "label": "Cancel reason", "type": "text"},
      {"id": "cancelled_by", "label": "Cancelled by", "type": "text"},
      {"id": "currency", "label": "Currency", "type": "text"},
      {"id": "plate", "label": "Plate", "type": "text"},
      {"id": "vehicle", "label": "Vehicle", "type": "text"},
      {"id": "driver_id", "label": "Driver ID", "type": "text"},
      {"id": "rider_id", "label": "Rider ID", "type": "text"},
      {"id": "rider_name", "label": "Rider name", "type": "text", "personal": "users"},
      {"id": "rider_phone", "label": "Rider phone", "type": "text", "personal": "users"},
      {"id": "driver_name", "label": "Driver name", "type": "text", "personal": "partners"},
      {"id": "driver_phone", "label": "Driver phone", "type": "text", "personal": "partners"}
     ]},
    {"id": "partners", "label": "Partners", "view": "ai_report_v_partners", "area": "names", "time": "joined_at",
     "about": "Drivers and other partners: status, type, rating and trips.",
     "list": ["joined_at", "status", "partner_type", "vehicle_type", "rating", "total_rides"],
     "fields": [
      {"id": "status", "label": "Status", "type": "text", "values": ["approved", "unapproved", "blocked", "rejected"]},
      {"id": "partner_type", "label": "Partner type", "type": "text"},
      {"id": "partner_types", "label": "Partner types", "type": "text"},
      {"id": "vehicle_type", "label": "Vehicle type", "type": "text"},
      {"id": "energy_type", "label": "Energy", "type": "text"},
      {"id": "make", "label": "Make", "type": "text"},
      {"id": "model", "label": "Model", "type": "text"},
      {"id": "plate", "label": "Plate", "type": "text"},
      {"id": "permit", "label": "Permit", "type": "text"},
      {"id": "documents_ok", "label": "Documents complete", "type": "bool"},
      {"id": "rating", "label": "Rating", "type": "number"},
      {"id": "total_rides", "label": "Trips", "type": "number"},
      {"id": "joined_at", "label": "Joined", "type": "time"},
      {"id": "service_states", "label": "Service states", "type": "text"},
      {"id": "service_cities", "label": "Service cities", "type": "text"},
      {"id": "name", "label": "Name", "type": "text", "personal": "partners"},
      {"id": "phone", "label": "Phone", "type": "text", "personal": "partners"},
      {"id": "email", "label": "Email", "type": "text", "personal": "partners"},
      {"id": "ic", "label": "IC number", "type": "text", "personal": "partners"}
     ]},
    {"id": "users", "label": "Users", "view": "ai_report_v_users", "area": "none", "time": "joined_at",
     "about": "Rider accounts: when they joined, nationality, status and trips.",
     "list": ["joined_at", "status", "nationality", "total_rides", "rider_rating"],
     "fields": [
      {"id": "status", "label": "Status", "type": "text"},
      {"id": "profile_status", "label": "Profile status", "type": "text"},
      {"id": "id_verified", "label": "ID verified", "type": "text"},
      {"id": "nationality", "label": "Nationality", "type": "text"},
      {"id": "gender", "label": "Gender", "type": "text"},
      {"id": "total_rides", "label": "Trips", "type": "number"},
      {"id": "rider_rating", "label": "Rider rating", "type": "number"},
      {"id": "joined_at", "label": "Joined", "type": "time"},
      {"id": "app_platform", "label": "App platform", "type": "text"},
      {"id": "app_version", "label": "App version", "type": "text"},
      {"id": "deleted", "label": "Deleted", "type": "bool"},
      {"id": "documents_ok", "label": "Documents complete", "type": "bool"},
      {"id": "name", "label": "Name", "type": "text", "personal": "users"},
      {"id": "phone", "label": "Phone", "type": "text", "personal": "users"},
      {"id": "email", "label": "Email", "type": "text", "personal": "users"},
      {"id": "ic", "label": "IC number", "type": "text", "personal": "users"}
     ]},
    {"id": "vehicles", "label": "Vehicles", "view": "ai_report_v_vehicles", "area": "names", "time": "joined_at",
     "about": "Registered vehicles: status, permit, type and make.",
     "list": ["joined_at", "plate", "status", "vehicle_type", "make", "model"],
     "fields": [
      {"id": "status", "label": "Status", "type": "text"},
      {"id": "permit", "label": "Permit", "type": "text"},
      {"id": "documents_ok", "label": "Documents complete", "type": "bool"},
      {"id": "vehicle_type", "label": "Vehicle type", "type": "text"},
      {"id": "energy_type", "label": "Energy", "type": "text"},
      {"id": "make", "label": "Make", "type": "text"},
      {"id": "model", "label": "Model", "type": "text"},
      {"id": "year", "label": "Year", "type": "text"},
      {"id": "color", "label": "Colour", "type": "text"},
      {"id": "plate", "label": "Plate", "type": "text"},
      {"id": "joined_at", "label": "Added", "type": "time"},
      {"id": "service_states", "label": "Service states", "type": "text"},
      {"id": "owner_name", "label": "Owner name", "type": "text", "personal": "partners"},
      {"id": "owner_phone", "label": "Owner phone", "type": "text", "personal": "partners"}
     ]},
    {"id": "wallet", "label": "Wallet transactions", "view": "ai_report_v_wallet", "area": "none", "time": "created_at",
     "about": "Wallet top-ups, payments, refunds and transfers.",
     "list": ["created_at", "wallet_type", "kind", "method", "status", "amount"],
     "fields": [
      {"id": "wallet_type", "label": "Wallet", "type": "text"},
      {"id": "kind", "label": "Kind", "type": "text"},
      {"id": "method", "label": "Method", "type": "text"},
      {"id": "status", "label": "Status", "type": "text"},
      {"id": "amount", "label": "Amount (RM)", "type": "number"},
      {"id": "created_at", "label": "When", "type": "time"}
     ]},
    {"id": "payments", "label": "Online payments", "view": "ai_report_v_payments", "area": "none", "time": "created_at",
     "about": "Payments through the payment gateways.",
     "list": ["created_at", "purpose", "provider", "status", "amount"],
     "fields": [
      {"id": "purpose", "label": "Purpose", "type": "text"},
      {"id": "provider", "label": "Gateway", "type": "text"},
      {"id": "status", "label": "Status", "type": "text"},
      {"id": "amount", "label": "Amount", "type": "number"},
      {"id": "currency", "label": "Currency", "type": "text"},
      {"id": "test_mode", "label": "Test mode", "type": "bool"},
      {"id": "created_at", "label": "Started", "type": "time"},
      {"id": "paid_at", "label": "Paid", "type": "time"}
     ]},
    {"id": "sos", "label": "SOS incidents", "view": "ai_report_v_sos", "area": "point", "time": "created_at",
     "about": "SOS alerts and how fast they were answered and closed.",
     "list": ["created_at", "status", "reporter_role", "response_min", "resolve_min", "city"],
     "fields": [
      {"id": "status", "label": "Status", "type": "text", "values": ["open", "acknowledged", "resolved"]},
      {"id": "reporter_role", "label": "Raised by", "type": "text"},
      {"id": "created_at", "label": "Raised", "type": "time"},
      {"id": "acknowledged_at", "label": "Answered", "type": "time"},
      {"id": "resolved_at", "label": "Closed", "type": "time"},
      {"id": "response_min", "label": "Response time (min)", "type": "number"},
      {"id": "resolve_min", "label": "Time to close (min)", "type": "number"},
      {"id": "alert_round", "label": "Alert rounds", "type": "number"},
      {"id": "service", "label": "Service", "type": "text"},
      {"id": "state", "label": "State", "type": "text"},
      {"id": "city", "label": "City", "type": "text"},
      {"id": "plate", "label": "Plate", "type": "text"},
      {"id": "reporter_name", "label": "Raised by (name)", "type": "text", "personal": "users"},
      {"id": "reporter_phone", "label": "Raised by (phone)", "type": "text", "personal": "users"},
      {"id": "driver_name", "label": "Driver name", "type": "text", "personal": "partners"}
     ]},
    {"id": "ratings", "label": "Ratings", "view": "ai_report_v_ratings", "area": "point", "time": "created_at",
     "about": "Stars riders gave their drivers.",
     "list": ["created_at", "stars", "service", "city", "has_comment"],
     "fields": [
      {"id": "stars", "label": "Stars", "type": "number"},
      {"id": "created_at", "label": "Rated", "type": "time"},
      {"id": "has_comment", "label": "Has a comment", "type": "bool"},
      {"id": "service", "label": "Service", "type": "text"},
      {"id": "state", "label": "State", "type": "text"},
      {"id": "city", "label": "City", "type": "text"},
      {"id": "driver_id", "label": "Driver ID", "type": "text"},
      {"id": "driver_name", "label": "Driver name", "type": "text", "personal": "partners"},
      {"id": "comment", "label": "Comment", "type": "text", "personal": "users"}
     ]},
    {"id": "signups", "label": "Sign-ups", "view": "ai_report_v_signups", "area": "none", "time": "joined_at",
     "about": "New accounts: riders (User) and partners (Partner).",
     "list": ["joined_at", "kind", "nationality", "status"],
     "fields": [
      {"id": "kind", "label": "Kind", "type": "text", "values": ["User", "Partner"]},
      {"id": "joined_at", "label": "Joined", "type": "time"},
      {"id": "nationality", "label": "Nationality", "type": "text"},
      {"id": "status", "label": "Status", "type": "text"}
     ]}
  ],
  "aggs": ["count", "count_distinct", "sum", "avg", "min", "max"],
  "ops": {"text": ["eq", "neq", "in", "not_in", "contains", "is_null", "not_null"],
          "number": ["eq", "neq", "gt", "gte", "lt", "lte", "between", "in", "is_null", "not_null"],
          "time": ["eq", "gt", "gte", "lt", "lte", "between", "is_null", "not_null"],
          "bool": ["eq", "is_null", "not_null"]},
  "buckets": ["day", "week", "month", "year"],
  "presets": ["today", "yesterday", "last_7_days", "last_30_days", "this_week", "last_week", "this_month",
              "last_month", "month_to_date", "this_year", "last_year", "last_n_days",
              "previous_day", "previous_week", "previous_month"],
  "limits": {"max_rows": 50000, "max_columns": 20, "max_group_by": 3, "max_measures": 8, "max_filters": 12,
             "max_sort": 3, "max_in": 50},
  "timezone": "Asia/Kuala_Lumpur"
}$cat$::jsonb;
$$;
revoke execute on function public.ai_report_catalogue_all() from public, anon, authenticated;

-- The catalogue for one scope: personal fields only with the People pages
-- they need; hidden lists the labels left out.
create or replace function public.ai_report_catalogue_for(p_scope jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with c as (select public.ai_report_catalogue_all() as j)
  select (c.j - 'datasets') || jsonb_build_object('datasets', coalesce((
    select jsonb_agg(d.ds || jsonb_build_object(
             'fields', coalesce((select jsonb_agg(f.f order by f.n) from jsonb_array_elements(d.ds -> 'fields')
                                   with ordinality f(f, n)
                                  where coalesce((p_scope ->> coalesce(f.f ->> 'personal', '-'))::boolean,
                                                 f.f ->> 'personal' is null)), '[]'::jsonb),
             'hidden', coalesce((select jsonb_agg(f.f ->> 'label' order by f.n) from jsonb_array_elements(d.ds -> 'fields')
                                   with ordinality f(f, n)
                                  where f.f ->> 'personal' is not null
                                    and not coalesce((p_scope ->> (f.f ->> 'personal'))::boolean, false)), '[]'::jsonb),
             'limited', coalesce((p_scope ->> 'scoped')::boolean, false) and d.ds ->> 'area' <> 'none')
           order by d.n)
      from jsonb_array_elements(c.j -> 'datasets') with ordinality d(ds, n)), '[]'::jsonb))
  from c;
$$;
revoke execute on function public.ai_report_catalogue_for(jsonb) from public, anon, authenticated;

-- A scope's catalogue as clients see it: without the views and how the
-- region applies, with the scope (no region polygons).
create or replace function public.ai_report_public_catalogue(p_scope jsonb)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with c as (select public.ai_report_catalogue_for(p_scope) as j)
  select (c.j - 'datasets') || jsonb_build_object(
    'datasets', (select coalesce(jsonb_agg((d - 'view' - 'area') order by n), '[]'::jsonb)
                   from jsonb_array_elements(c.j -> 'datasets') with ordinality x(d, n)),
    'scope', jsonb_build_object('scoped', p_scope -> 'scoped', 'region', p_scope -> 'region', 'edit', p_scope -> 'edit',
                                'people_users', p_scope -> 'users', 'people_partners', p_scope -> 'partners'))
  from c;
$$;
revoke execute on function public.ai_report_public_catalogue(jsonb) from public, anon, authenticated;

-- What the page and the ai-report function get: the caller's.
create or replace function public.ai_report_catalogue()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  s jsonb := public.ai_report_caller_scope();
begin
  if not coalesce((s ->> 'ok')::boolean, false) then
    raise exception 'Reports: your admin access does not include Reports' using errcode = '42501';
  end if;
  return public.ai_report_public_catalogue(s);
end;
$$;
revoke execute on function public.ai_report_catalogue() from public, anon;
grant execute on function public.ai_report_catalogue() to authenticated, service_role;

-- ---- 3. Periods ---------------------------------------------------------------------------------
-- A period as Malaysia's dates [d_from, d_to] (both null: all time).
--   {from, to}: those dates. {preset}: today, yesterday, last_7_days and
--   last_30_days (ending today), this_week (from Monday), last_week
--   (Monday to Sunday), this_month / month_to_date, last_month, this_year,
--   last_year; last_n_days {days} the N whole days before today;
--   previous_day / previous_week / previous_month as yesterday / last_week
--   / last_month (the schedules' words).
create or replace function public.ai_report_period_dates(p_period jsonb, p_now timestamptz,
                                                         out d_from date, out d_to date)
language plpgsql
stable
set search_path = ''
as $$
declare
  t date := (p_now at time zone 'Asia/Kuala_Lumpur')::date;
  v_preset text;
  v_days int;
  v_monday date := t - (extract(isodow from t)::int - 1);
  v_first date := date_trunc('month', t::timestamp)::date;
begin
  if p_period is null or jsonb_typeof(p_period) <> 'object' or p_period = '{}'::jsonb then
    return;
  end if;
  v_preset := nullif(btrim(coalesce(p_period ->> 'preset', '')), '');
  if v_preset is null then
    begin
      d_from := (p_period ->> 'from')::date;
      d_to := (p_period ->> 'to')::date;
    exception when others then
      raise exception 'Reports: the period''s dates must be written yyyy-mm-dd' using errcode = '22023';
    end;
    if d_from is null or d_to is null then
      raise exception 'Reports: a period needs a from and a to date, or a preset' using errcode = '22023';
    end if;
    if d_to < d_from then
      raise exception 'Reports: the period ends before it starts' using errcode = '22023';
    end if;
    if d_to - d_from > 3660 then
      raise exception 'Reports: a period can cover at most 10 years' using errcode = '22023';
    end if;
    return;
  end if;
  case v_preset
    when 'today' then d_from := t; d_to := t;
    when 'yesterday', 'previous_day' then d_from := t - 1; d_to := t - 1;
    when 'last_7_days' then d_from := t - 6; d_to := t;
    when 'last_30_days' then d_from := t - 29; d_to := t;
    when 'this_week' then d_from := v_monday; d_to := t;
    when 'last_week', 'previous_week' then d_from := v_monday - 7; d_to := v_monday - 1;
    when 'this_month', 'month_to_date' then d_from := v_first; d_to := t;
    when 'last_month', 'previous_month' then
      d_from := date_trunc('month', (v_first - 1)::timestamp)::date; d_to := v_first - 1;
    when 'this_year' then d_from := date_trunc('year', t::timestamp)::date; d_to := t;
    when 'last_year' then
      d_from := (date_trunc('year', t::timestamp) - interval '1 year')::date; d_to := date_trunc('year', t::timestamp)::date - 1;
    when 'last_n_days' then
      begin
        v_days := (p_period ->> 'days')::int;
      exception when others then
        v_days := null;
      end;
      if v_days is null or v_days < 1 or v_days > 366 then
        raise exception 'Reports: "last N days" needs N from 1 to 366' using errcode = '22023';
      end if;
      d_from := t - v_days; d_to := t - 1;
    else
      raise exception 'Reports: unknown period "%"', v_preset using errcode = '22023';
  end case;
end;
$$;
revoke execute on function public.ai_report_period_dates(jsonb, timestamptz) from public, anon;
grant execute on function public.ai_report_period_dates(jsonb, timestamptz) to authenticated, service_role;

-- ---- 4. Running a plan --------------------------------------------------------------------------
-- The report for [p_plan] as [p_scope] would see it. Internal: called by
-- ai_report_run and ai_report_schedule_job only.
create or replace function public.ai_report_exec(p_plan jsonb, p_scope jsonb, p_now timestamptz default now())
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  tz constant text := 'Asia/Kuala_Lumpur';
  v_cat jsonb := public.ai_report_catalogue_for(p_scope);
  v_lim jsonb := v_cat -> 'limits';
  v_cap int := (v_lim ->> 'max_rows')::int;
  v_ds jsonb;
  v_ds_id text;
  v_fields jsonb;
  v_f jsonb;
  v_id text;
  v_item jsonb;
  v_parts text[];
  v_bucket text;
  v_type text;
  v_op text;
  v_val jsonb;
  v_arr text[];
  v_num numeric;
  v_d1 date;
  v_d2 date;
  v_sel text[] := '{}';
  v_out text[] := '{}';
  v_where text[] := '{}';
  v_order text[] := '{}';
  v_cols jsonb := '[]';
  v_groups jsonb := '[]';
  v_measures jsonb := '[]';
  v_filters jsonb := '[]';
  v_sort jsonb := '[]';
  v_columns jsonb := '[]';
  v_mexpr text[] := '{}';
  v_ids text[] := '{}';
  v_alias text;
  v_expr text;
  v_label text;
  v_agg text;
  v_dir text;
  v_limit int;
  v_take int;
  v_title text;
  v_period jsonb;
  v_pfield text;
  v_scoped boolean := coalesce((p_scope ->> 'scoped')::boolean, false);
  v_region jsonb := p_scope -> 'region';
  v_polys polygon[];
  v_sql text;
  v_rows jsonb;
  v_n int;
  v_totals jsonb;
  v_grouped boolean;
begin
  if p_plan is null or jsonb_typeof(p_plan) <> 'object' then
    raise exception 'Reports: the plan must be a JSON object' using errcode = '22023';
  end if;
  v_ds_id := p_plan ->> 'dataset';
  select d into v_ds from jsonb_array_elements(v_cat -> 'datasets') d where d ->> 'id' = v_ds_id;
  if v_ds is null then
    raise exception 'Reports: there is no dataset "%"', coalesce(v_ds_id, '') using errcode = '22023';
  end if;
  select jsonb_object_agg(f ->> 'id', f) into v_fields from jsonb_array_elements(v_ds -> 'fields') f;

  -- Columns (a plain list), group by and measures.
  if jsonb_typeof(coalesce(p_plan -> 'columns', '[]')) <> 'array'
     or jsonb_typeof(coalesce(p_plan -> 'group_by', '[]')) <> 'array'
     or jsonb_typeof(coalesce(p_plan -> 'measures', '[]')) <> 'array'
     or jsonb_typeof(coalesce(p_plan -> 'filters', '[]')) <> 'array'
     or jsonb_typeof(coalesce(p_plan -> 'sort', '[]')) <> 'array' then
    raise exception 'Reports: columns, group_by, measures, filters and sort must be lists' using errcode = '22023';
  end if;
  if jsonb_array_length(coalesce(p_plan -> 'group_by', '[]')) > (v_lim ->> 'max_group_by')::int then
    raise exception 'Reports: group by at most % fields', v_lim ->> 'max_group_by' using errcode = '22023';
  end if;
  if jsonb_array_length(coalesce(p_plan -> 'measures', '[]')) > (v_lim ->> 'max_measures')::int then
    raise exception 'Reports: at most % figures', v_lim ->> 'max_measures' using errcode = '22023';
  end if;
  if jsonb_array_length(coalesce(p_plan -> 'columns', '[]')) > (v_lim ->> 'max_columns')::int then
    raise exception 'Reports: at most % columns', v_lim ->> 'max_columns' using errcode = '22023';
  end if;
  if jsonb_array_length(coalesce(p_plan -> 'filters', '[]')) > (v_lim ->> 'max_filters')::int then
    raise exception 'Reports: at most % filters', v_lim ->> 'max_filters' using errcode = '22023';
  end if;
  if jsonb_array_length(coalesce(p_plan -> 'sort', '[]')) > (v_lim ->> 'max_sort')::int then
    raise exception 'Reports: sort by at most % columns', v_lim ->> 'max_sort' using errcode = '22023';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_plan -> 'group_by', '[]')) loop
    if jsonb_typeof(v_item) <> 'string' then
      raise exception 'Reports: each group by is a field name' using errcode = '22023';
    end if;
    v_parts := string_to_array(v_item #>> '{}', ':');
    v_id := v_parts[1];
    v_bucket := v_parts[2];
    v_f := v_fields -> v_id;
    if v_f is null then
      raise exception 'Reports: % has no field "%"', v_ds ->> 'label', v_id using errcode = '22023';
    end if;
    if v_f ->> 'type' = 'time' then
      v_bucket := coalesce(v_bucket, 'day');
      if not (v_cat -> 'buckets') ? v_bucket then
        raise exception 'Reports: group "%" by day, week, month or year', v_f ->> 'label' using errcode = '22023';
      end if;
      v_alias := v_id || '_' || v_bucket;
      v_expr := format('to_char(date_trunc(%L, d.%I at time zone %L), %L)', v_bucket, v_id, tz,
                       case v_bucket when 'month' then 'YYYY-MM' when 'year' then 'YYYY' else 'YYYY-MM-DD' end);
      v_label := (v_f ->> 'label') || ' (' || v_bucket || ')';
      v_type := 'text';
    else
      if v_bucket is not null then
        raise exception 'Reports: only dates can be grouped by day, week, month or year' using errcode = '22023';
      end if;
      v_alias := v_id;
      v_expr := format('d.%I', v_id);
      v_label := v_f ->> 'label';
      v_type := v_f ->> 'type';
    end if;
    if v_alias = any(v_ids) then
      raise exception 'Reports: "%" is grouped twice', v_label using errcode = '22023';
    end if;
    v_ids := v_ids || v_alias;
    v_sel := v_sel || format('%s as %I', v_expr, v_alias);
    v_groups := v_groups || to_jsonb(v_id || coalesce(':' || v_bucket, ''));
    v_columns := v_columns || jsonb_build_object('id', v_alias, 'label', v_label, 'type', v_type, 'role', 'group',
                                                 'field', v_id, 'bucket', v_bucket);
  end loop;

  for v_item in select * from jsonb_array_elements(coalesce(p_plan -> 'measures', '[]')) loop
    v_id := coalesce(v_item ->> 'field', '*');
    v_agg := coalesce(v_item ->> 'agg', 'count');
    if not (v_cat -> 'aggs') ? v_agg then
      raise exception 'Reports: "%" is not a way to sum up (count, count_distinct, sum, avg, min, max)', v_agg
        using errcode = '22023';
    end if;
    if v_id = '*' then
      if v_agg <> 'count' then
        raise exception 'Reports: % needs a field', v_agg using errcode = '22023';
      end if;
      v_alias := 'count';
      v_expr := 'count(*)';
      v_label := 'Count';
      v_type := 'number';
    else
      v_f := v_fields -> v_id;
      if v_f is null then
        raise exception 'Reports: % has no field "%"', v_ds ->> 'label', v_id using errcode = '22023';
      end if;
      v_type := v_f ->> 'type';
      if v_agg in ('sum', 'avg') and v_type <> 'number' then
        raise exception 'Reports: "%" is not a number, so it can''t be added up or averaged', v_f ->> 'label'
          using errcode = '22023';
      end if;
      if v_agg in ('min', 'max') and v_type not in ('number', 'time') then
        raise exception 'Reports: lowest and highest need a number or a date ("%" is neither)', v_f ->> 'label'
          using errcode = '22023';
      end if;
      v_alias := v_agg || '_' || v_id;
      v_label := case v_agg
        when 'count' then (v_f ->> 'label') || ' (count)'
        when 'count_distinct' then 'Different ' || lower(left(v_f ->> 'label', 1)) || substr(v_f ->> 'label', 2)
        when 'sum' then 'Total ' || lower(left(v_f ->> 'label', 1)) || substr(v_f ->> 'label', 2)
        when 'avg' then 'Average ' || lower(left(v_f ->> 'label', 1)) || substr(v_f ->> 'label', 2)
        when 'min' then 'Lowest ' || lower(left(v_f ->> 'label', 1)) || substr(v_f ->> 'label', 2)
        else 'Highest ' || lower(left(v_f ->> 'label', 1)) || substr(v_f ->> 'label', 2) end;
      v_expr := case v_agg
        when 'count' then format('count(d.%I)', v_id)
        when 'count_distinct' then format('count(distinct d.%I)', v_id)
        when 'sum' then format('sum(d.%I)', v_id)
        when 'avg' then format('round(avg(d.%I)::numeric, 2)', v_id)
        else case when v_type = 'time'
                  then format('to_char(%s(d.%I) at time zone %L, %L)', v_agg, v_id, tz, 'YYYY-MM-DD HH24:MI')
                  else format('%s(d.%I)', v_agg, v_id) end end;
      v_type := case when v_agg in ('count', 'count_distinct') then 'number' else v_type end;
    end if;
    if v_alias = any(v_ids) then
      raise exception 'Reports: "%" is asked for twice', v_label using errcode = '22023';
    end if;
    v_ids := v_ids || v_alias;
    v_sel := v_sel || format('%s as %I', v_expr, v_alias);
    v_mexpr := v_mexpr || v_expr;
    v_measures := v_measures || jsonb_build_object('field', v_id, 'agg', v_agg);
    v_columns := v_columns || jsonb_build_object('id', v_alias, 'label', v_label, 'type', v_type, 'role', 'measure',
                                                 'field', v_id, 'agg', v_agg);
  end loop;

  v_grouped := jsonb_array_length(v_groups) > 0 or jsonb_array_length(v_measures) > 0;
  if not v_grouped then
    -- A plain list: the columns asked for, else the dataset's usual ones.
    for v_item in select * from jsonb_array_elements(
                    case when jsonb_array_length(coalesce(p_plan -> 'columns', '[]')) > 0
                         then p_plan -> 'columns' else v_ds -> 'list' end) loop
      v_id := v_item #>> '{}';
      v_f := v_fields -> v_id;
      if v_f is null then
        -- The usual columns skip what this caller may not see.
        continue when jsonb_array_length(coalesce(p_plan -> 'columns', '[]')) = 0;
        raise exception 'Reports: % has no field "%"', v_ds ->> 'label', coalesce(v_id, '') using errcode = '22023';
      end if;
      continue when v_id = any(v_ids);
      v_ids := v_ids || v_id;
      v_sel := v_sel || case when v_f ->> 'type' = 'time'
                             then format('to_char(d.%I at time zone %L, %L) as %I', v_id, tz, 'YYYY-MM-DD HH24:MI', v_id)
                             else format('d.%I as %I', v_id, v_id) end;
      v_cols := v_cols || to_jsonb(v_id);
      v_columns := v_columns || jsonb_build_object('id', v_id, 'label', v_f ->> 'label', 'type', v_f ->> 'type',
                                                   'role', 'column', 'field', v_id);
    end loop;
  end if;
  if cardinality(v_sel) = 0 then
    raise exception 'Reports: the report has no columns' using errcode = '22023';
  end if;

  -- Filters.
  for v_item in select * from jsonb_array_elements(coalesce(p_plan -> 'filters', '[]')) loop
    v_id := v_item ->> 'field';
    v_op := coalesce(v_item ->> 'op', 'eq');
    v_val := v_item -> 'value';
    v_f := v_fields -> v_id;
    if v_f is null then
      raise exception 'Reports: % has no field "%"', v_ds ->> 'label', coalesce(v_id, '') using errcode = '22023';
    end if;
    v_type := v_f ->> 'type';
    if not (v_cat -> 'ops' -> v_type) ? v_op then
      raise exception 'Reports: "%" can''t be used on "%"', v_op, v_f ->> 'label' using errcode = '22023';
    end if;
    if v_op = 'is_null' then
      v_where := v_where || format('d.%I is null', v_id);
    elsif v_op = 'not_null' then
      v_where := v_where || format('d.%I is not null', v_id);
    elsif v_type = 'text' then
      if v_op in ('in', 'not_in') then
        if jsonb_typeof(v_val) <> 'array' or jsonb_array_length(v_val) = 0
           or jsonb_array_length(v_val) > (v_lim ->> 'max_in')::int then
          raise exception 'Reports: "%" needs a list of 1 to % values', v_f ->> 'label', v_lim ->> 'max_in'
            using errcode = '22023';
        end if;
        select array_agg(x #>> '{}') into v_arr from jsonb_array_elements(v_val) x;
        v_where := v_where || format(case when v_op = 'in' then 'd.%I = any(%L::text[])'
                                          else 'not (d.%I = any(%L::text[])) or d.%I is null' end,
                                     v_id, v_arr::text, v_id);
      else
        if v_val is null or jsonb_typeof(v_val) not in ('string', 'number', 'boolean') then
          raise exception 'Reports: "%" needs a value', v_f ->> 'label' using errcode = '22023';
        end if;
        if v_op = 'eq' then
          v_where := v_where || format('lower(d.%I) = lower(%L)', v_id, v_val #>> '{}');
        elsif v_op = 'neq' then
          v_where := v_where || format('lower(d.%I) is distinct from lower(%L)', v_id, v_val #>> '{}');
        else
          v_where := v_where || format('d.%I ilike %L', v_id,
                                       '%' || regexp_replace(v_val #>> '{}', '([%_\\])', '\\\1', 'g') || '%');
        end if;
      end if;
    elsif v_type = 'number' then
      begin
        if v_op in ('between', 'in') then
          if jsonb_typeof(v_val) <> 'array' or jsonb_array_length(v_val) = 0
             or jsonb_array_length(v_val) > (v_lim ->> 'max_in')::int
             or (v_op = 'between' and jsonb_array_length(v_val) <> 2) then
            raise exception 'list';
          end if;
          select array_agg((x #>> '{}')::numeric::text) into v_arr from jsonb_array_elements(v_val) x;
        else
          v_num := (v_val #>> '{}')::numeric;
          if v_num is null then
            raise exception 'null';
          end if;
        end if;
      exception when others then
        raise exception 'Reports: "%" needs % for "%"', v_f ->> 'label',
          case v_op when 'between' then 'two numbers' when 'in' then 'a list of numbers' else 'a number' end, v_op
          using errcode = '22023';
      end;
      v_where := v_where || case v_op
        when 'eq' then format('d.%I = %L::numeric', v_id, v_num::text)
        when 'neq' then format('d.%I is distinct from %L::numeric', v_id, v_num::text)
        when 'gt' then format('d.%I > %L::numeric', v_id, v_num::text)
        when 'gte' then format('d.%I >= %L::numeric', v_id, v_num::text)
        when 'lt' then format('d.%I < %L::numeric', v_id, v_num::text)
        when 'lte' then format('d.%I <= %L::numeric', v_id, v_num::text)
        when 'between' then format('d.%I between %L::numeric and %L::numeric', v_id, v_arr[1], v_arr[2])
        else format('d.%I = any(%L::numeric[])', v_id, v_arr::text) end;
    elsif v_type = 'time' then
      begin
        if v_op = 'between' then
          if jsonb_typeof(v_val) <> 'array' or jsonb_array_length(v_val) <> 2 then
            raise exception 'list';
          end if;
          v_d1 := (v_val ->> 0)::date;
          v_d2 := (v_val ->> 1)::date;
        else
          v_d1 := (v_val #>> '{}')::date;
        end if;
        if v_d1 is null or (v_op = 'between' and v_d2 is null) then
          raise exception 'null';
        end if;
      exception when others then
        raise exception 'Reports: "%" needs % (yyyy-mm-dd)', v_f ->> 'label',
          case when v_op = 'between' then 'two dates' else 'a date' end using errcode = '22023';
      end;
      -- Malaysia's days: "on or before 5 Oct" is before the 6th starts there.
      v_where := v_where || case v_op
        when 'eq' then format('d.%I >= (%L::timestamp at time zone %L) and d.%I < (%L::timestamp at time zone %L)',
                              v_id, v_d1::text, tz, v_id, (v_d1 + 1)::text, tz)
        when 'gt' then format('d.%I >= (%L::timestamp at time zone %L)', v_id, (v_d1 + 1)::text, tz)
        when 'gte' then format('d.%I >= (%L::timestamp at time zone %L)', v_id, v_d1::text, tz)
        when 'lt' then format('d.%I < (%L::timestamp at time zone %L)', v_id, v_d1::text, tz)
        when 'lte' then format('d.%I < (%L::timestamp at time zone %L)', v_id, (v_d1 + 1)::text, tz)
        else format('d.%I >= (%L::timestamp at time zone %L) and d.%I < (%L::timestamp at time zone %L)',
                    v_id, least(v_d1, v_d2)::text, tz, v_id, (greatest(v_d1, v_d2) + 1)::text, tz) end;
    else
      if v_val is null or jsonb_typeof(v_val) not in ('boolean', 'string') or lower(v_val #>> '{}') not in ('true', 'false') then
        raise exception 'Reports: "%" needs yes (true) or no (false)', v_f ->> 'label' using errcode = '22023';
      end if;
      v_where := v_where || format('d.%I = %L::boolean', v_id, lower(v_val #>> '{}'));
    end if;
    v_filters := v_filters || jsonb_build_object('field', v_id, 'op', v_op, 'value', v_val);
  end loop;

  -- The period, on the dataset's date unless the plan names another.
  v_period := p_plan -> 'period';
  if v_period is not null and jsonb_typeof(v_period) = 'object' and v_period <> '{}'::jsonb then
    v_pfield := coalesce(nullif(v_period ->> 'field', ''), v_ds ->> 'time');
    if coalesce(v_fields -> v_pfield ->> 'type', '') <> 'time' then
      raise exception 'Reports: % has no date "%"', v_ds ->> 'label', v_pfield using errcode = '22023';
    end if;
    select x.d_from, x.d_to into v_d1, v_d2 from public.ai_report_period_dates(v_period, p_now) x;
    v_where := v_where || format('d.%I >= (%L::timestamp at time zone %L) and d.%I < (%L::timestamp at time zone %L)',
                                 v_pfield, v_d1::text, tz, v_pfield, (v_d2 + 1)::text, tz);
    v_period := (v_period - 'field') || jsonb_build_object('field', v_pfield);
  else
    v_period := null;
  end if;

  -- A sub-admin's region.
  if v_scoped and v_ds ->> 'area' = 'point' then
    v_polys := public.god_view_region_polys(v_region);
    v_where := v_where || 'public.god_view_in_scope(true, $1, $2, d._lat, d._lng, d._country, d._state, d._city, d._suburb)'::text;
  elsif v_scoped and v_ds ->> 'area' = 'names' then
    v_where := v_where || 'public.ai_report_in_region_names($1, d._countries, d._states, d._cities)'::text;
  end if;

  -- Sort: by a column of the report (a measure also by its field's name).
  for v_item in select * from jsonb_array_elements(coalesce(p_plan -> 'sort', '[]')) loop
    v_id := v_item ->> 'field';
    v_dir := lower(coalesce(v_item ->> 'dir', 'asc'));
    if v_dir not in ('asc', 'desc') then
      raise exception 'Reports: sort is asc or desc' using errcode = '22023';
    end if;
    if not (v_id = any(v_ids)) then
      select c ->> 'id' into v_alias from jsonb_array_elements(v_columns) c
       where c ->> 'field' = v_id or (v_id = 'count' and c ->> 'id' = 'count') limit 1;
      if v_alias is null then
        raise exception 'Reports: can''t sort by "%": it isn''t a column of the report', coalesce(v_id, '')
          using errcode = '22023';
      end if;
      v_id := v_alias;
      v_alias := null;
    end if;
    v_order := v_order || format('%I %s nulls last', v_id, v_dir);
    v_sort := v_sort || jsonb_build_object('field', v_id, 'dir', v_dir);
  end loop;
  if cardinality(v_order) = 0 then
    if not v_grouped then
      -- Newest first, on the dataset's date when it is a column.
      if (v_ds ->> 'time') = any(v_ids) then
        v_order := array[format('%I desc nulls last', v_ds ->> 'time')];
      end if;
    elsif exists (select 1 from jsonb_array_elements(v_columns) c where c ->> 'bucket' is not null) then
      select array_agg(format('%I asc nulls last', c ->> 'id') order by n) into v_order
        from jsonb_array_elements(v_columns) with ordinality x(c, n) where c ->> 'role' = 'group';
    elsif jsonb_array_length(v_measures) > 0 then
      select array[format('%I desc nulls last', c ->> 'id')] into v_order
        from jsonb_array_elements(v_columns) c where c ->> 'role' = 'measure' limit 1;
    end if;
  end if;

  -- How many rows.
  begin
    v_limit := nullif(p_plan ->> 'limit', '')::int;
  exception when others then
    raise exception 'Reports: limit must be a whole number' using errcode = '22023';
  end;
  if v_limit is not null and v_limit < 1 then
    raise exception 'Reports: limit must be at least 1' using errcode = '22023';
  end if;
  v_limit := least(coalesce(v_limit, v_cap), v_cap);
  v_take := case when v_limit >= v_cap then v_cap + 1 else v_limit end;
  v_title := left(btrim(coalesce(p_plan ->> 'title', '')), 120);

  v_sql := format('select %s from public.%I d%s%s%s limit %s',
                  array_to_string(v_sel, ', '),
                  v_ds ->> 'view',
                  case when cardinality(v_where) > 0 then ' where (' || array_to_string(v_where, ') and (') || ')' else '' end,
                  case when jsonb_array_length(v_groups) > 0
                       then ' group by ' || (select string_agg(i::text, ', ') from generate_series(1, jsonb_array_length(v_groups)) i)
                       else '' end,
                  case when cardinality(v_order) > 0 then ' order by ' || array_to_string(v_order, ', ') else '' end,
                  v_take);
  select array_agg(format('x.%I', c ->> 'id') order by n) into v_out
    from jsonb_array_elements(v_columns) with ordinality y(c, n);
  execute format(
    'select coalesce(jsonb_agg(jsonb_build_array(%s) order by x._rn) filter (where x._rn <= %s), ''[]''::jsonb), count(*)::int
       from (select l.*, row_number() over () as _rn from (%s) l) x',
    array_to_string(v_out, ', '), v_cap, v_sql)
    into v_rows, v_n
    using v_region, v_polys;

  -- The total row: the figures over everything the report covers.
  if jsonb_array_length(v_groups) > 0 and cardinality(v_mexpr) > 0 then
    execute format('select jsonb_build_array(%s) from public.%I d%s',
                   array_to_string(v_mexpr, ', '), v_ds ->> 'view',
                   case when cardinality(v_where) > 0 then ' where (' || array_to_string(v_where, ') and (') || ')' else '' end)
      into v_totals
      using v_region, v_polys;
  end if;

  return jsonb_build_object(
    'dataset', v_ds_id,
    'dataset_label', v_ds ->> 'label',
    'columns', v_columns,
    'rows', v_rows,
    'totals', v_totals,
    'row_count', least(v_n, v_cap),
    'truncated', v_n > v_cap,
    'max_rows', v_cap,
    'period', case when v_period is null then null
                   else v_period || jsonb_build_object('from', v_d1, 'to', v_d2) end,
    'hidden', v_ds -> 'hidden',
    'limited', v_scoped and v_ds ->> 'area' <> 'none',
    'plan', jsonb_strip_nulls(jsonb_build_object(
              'dataset', v_ds_id, 'columns', v_cols, 'filters', v_filters,
              'period', case when v_period is null then null else v_period end,
              'group_by', v_groups, 'measures', v_measures, 'sort', v_sort,
              'limit', case when v_limit >= v_cap then null else v_limit end,
              'title', nullif(v_title, ''))));
end;
$$;
revoke execute on function public.ai_report_exec(jsonb, jsonb, timestamptz) from public, anon, authenticated;

-- The page's "Make report" and re-runs: the caller's own scope, logged.
-- statement_timeout is applied by PostgREST from the function's settings.
create or replace function public.ai_report_run(p_plan jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
set statement_timeout = '15s'
as $$
declare
  s jsonb := public.ai_report_caller_scope();
  v jsonb;
begin
  if not coalesce((s ->> 'ok')::boolean, false) then
    raise exception 'Reports: your admin access does not include Reports' using errcode = '42501';
  end if;
  v := public.ai_report_exec(p_plan, s);
  insert into public.admin_audit_log (actor_id, action, detail)
  values (auth.uid(), 'ai_report.run',
          jsonb_build_object('dataset', v ->> 'dataset', 'rows', (v ->> 'row_count')::int,
                             'truncated', (v ->> 'truncated')::boolean, 'plan', v -> 'plan'));
  return v;
end;
$$;
revoke execute on function public.ai_report_run(jsonb) from public, anon;
grant execute on function public.ai_report_run(jsonb) to authenticated, service_role;

-- ---- 5. Saved reports, schedules, sends ---------------------------------------------------------
create table if not exists public.ai_reports_saved (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(btrim(name)) between 1 and 120),
  request     text check (request is null or length(request) <= 2000),
  plan        jsonb not null check (jsonb_typeof(plan) = 'object' and pg_column_size(plan) <= 16384),
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  last_run_at timestamptz,
  last_rows   integer
);
comment on table public.ai_reports_saved is
  'Admin -> Reports: a saved report (its name, the words asked and the checked plan; 0280). Run again with ai_report_run.';

create or replace function public.ai_report_emails_ok(p_emails text[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(cardinality(p_emails), 0) <= 20
     and not exists (select 1 from unnest(coalesce(p_emails, '{}')) e
                      where e !~ '^[^@\s<>(),;:"]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$'
                         or length(e) > 254);
$$;

create table if not exists public.ai_report_schedules (
  id              uuid primary key default gen_random_uuid(),
  saved_id        uuid not null references public.ai_reports_saved (id) on delete cascade,
  frequency       text not null default 'daily' check (frequency in ('daily', 'weekly', 'monthly')),
  at_time         time not null default '08:00',
  weekdays        smallint[] not null default '{1}' check (weekdays <@ '{1,2,3,4,5,6,7}'::smallint[]),
  month_day       smallint not null default 1 check (month_day between 1 and 28 or month_day = -1),
  period          jsonb not null default '{"preset": "previous_day"}'
                    check (jsonb_typeof(period) = 'object'
                           and period ->> 'preset' in ('previous_day', 'previous_week', 'previous_month',
                                                        'month_to_date', 'last_n_days')
                           and (period ->> 'preset' <> 'last_n_days'
                                or coalesce(period ->> 'days', '') ~ '^[0-9]{1,3}$'
                                   and (period ->> 'days')::int between 1 and 366)),
  emails          text[] not null default '{}' check (public.ai_report_emails_ok(emails)),
  admin_ids       uuid[] not null default '{}' check (cardinality(admin_ids) <= 20),
  formats         text[] not null default '{csv}'
                    check (cardinality(formats) between 1 and 3 and formats <@ '{csv,xlsx,pdf}'::text[]),
  link_only       boolean not null default false,
  subject         text not null default '{report} for {period}' check (length(subject) between 1 and 200),
  message         text not null default '' check (length(message) <= 2000),
  skip_empty      boolean not null default false,
  paused          boolean not null default false,
  next_run_at     timestamptz,
  last_claimed_at timestamptz,
  last_run_at     timestamptz,
  last_status     text check (last_status is null or last_status in ('sent', 'skipped', 'failed')),
  last_error      text,
  send_now_at     timestamptz,
  created_by      uuid default auth.uid(),
  scope           jsonb,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint ai_report_schedules_someone check (cardinality(emails) + cardinality(admin_ids) >= 1),
  constraint ai_report_schedules_weekdays check (frequency <> 'weekly' or cardinality(weekdays) >= 1)
);
comment on table public.ai_report_schedules is
  'Admin -> Reports: a saved report emailed on a schedule, Malaysia time (0280). Claimed by ai_report_schedules_due (pg_cron) and sent by the ai-report-email function.';
create index if not exists ai_report_schedules_due_idx on public.ai_report_schedules (next_run_at) where not paused;

create table if not exists public.ai_report_sends (
  id          uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references public.ai_report_schedules (id) on delete cascade,
  at          timestamptz not null default now(),
  reason      text,
  rows        integer,
  recipients  integer,
  ok          boolean not null,
  skipped     boolean not null default false,
  error       text
);
comment on table public.ai_report_sends is 'Each email of a report schedule (0280): when, rows, recipients, sent or why not.';
create index if not exists ai_report_sends_schedule_idx on public.ai_report_sends (schedule_id, at desc);

-- The sender the emails come from (one row).
create table if not exists public.ai_report_settings (
  id         boolean primary key default true check (id),
  email_from text not null default 'GET.ride Reports <reports@getride.my>' check (length(email_from) between 3 and 200),
  updated_at timestamptz not null default now()
);
insert into public.ai_report_settings (id) values (true) on conflict do nothing;

-- The next run strictly after [p_after], Malaysia time.
create or replace function public.ai_report_next_run(
  p_frequency text, p_at time, p_weekdays smallint[], p_month_day smallint, p_after timestamptz
)
returns timestamptz
language plpgsql
stable
set search_path = ''
as $$
declare
  tz constant text := 'Asia/Kuala_Lumpur';
  v_day date := (p_after at time zone tz)::date;
  d date;
  v_c timestamptz;
  i int;
begin
  for i in 0..62 loop
    d := v_day + i;
    v_c := (d + p_at) at time zone tz;
    continue when v_c <= p_after;
    if p_frequency = 'daily'
       or (p_frequency = 'weekly' and extract(isodow from d)::smallint = any(coalesce(p_weekdays, '{}')))
       or (p_frequency = 'monthly' and ((p_month_day = -1 and extract(day from d + 1) = 1)
                                        or extract(day from d) = p_month_day)) then
      return v_c;
    end if;
  end loop;
  return null;
end;
$$;
revoke execute on function public.ai_report_next_run(text, time, smallint[], smallint, timestamptz) from public, anon;
grant execute on function public.ai_report_next_run(text, time, smallint[], smallint, timestamptz) to authenticated, service_role;

create or replace function public.ai_report_schedules_stamp()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at := now();
  if tg_op = 'INSERT' then
    if auth.uid() is not null then
      new.created_by := auth.uid();
    end if;
    new.scope := public.ai_report_scope_for(new.created_by) - 'edit';
    new.last_claimed_at := null;
    new.last_run_at := null;
    new.last_status := null;
    new.last_error := null;
    new.send_now_at := null;
  else
    new.created_by := old.created_by;
    new.scope := old.scope;
  end if;
  new.weekdays := coalesce((select array_agg(distinct w order by w) from unnest(new.weekdays) w), '{}');
  if tg_op = 'INSERT' or new.frequency is distinct from old.frequency or new.at_time is distinct from old.at_time
     or new.weekdays is distinct from old.weekdays or new.month_day is distinct from old.month_day
     or (old.paused and not new.paused) then
    new.next_run_at := public.ai_report_next_run(new.frequency, new.at_time, new.weekdays, new.month_day, now());
  end if;
  return new;
end;
$$;
revoke execute on function public.ai_report_schedules_stamp() from public, anon, authenticated;

drop trigger if exists trg_ai_report_schedules_stamp on public.ai_report_schedules;
create trigger trg_ai_report_schedules_stamp
  before insert or update on public.ai_report_schedules
  for each row execute function public.ai_report_schedules_stamp();

create or replace function public.ai_reports_saved_stamp()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at := now();
  if tg_op = 'INSERT' then
    if auth.uid() is not null then
      new.created_by := auth.uid();
    end if;
  else
    new.created_by := old.created_by;
  end if;
  return new;
end;
$$;
revoke execute on function public.ai_reports_saved_stamp() from public, anon, authenticated;

drop trigger if exists trg_ai_reports_saved_stamp on public.ai_reports_saved;
create trigger trg_ai_reports_saved_stamp
  before insert or update on public.ai_reports_saved
  for each row execute function public.ai_reports_saved_stamp();

-- RLS: anyone who may run reports reads; an edit grant on Reports writes.
insert into public.admin_table_pages (target, page) values
  ('ai_reports_saved', 'admin-reports'),
  ('ai_report_schedules', 'admin-reports'),
  ('ai_report_settings', 'admin-reports'),
  ('rpc:ai_report_schedule_send_now', 'admin-reports')
on conflict do nothing;

alter table public.ai_reports_saved enable row level security;
alter table public.ai_report_schedules enable row level security;
alter table public.ai_report_sends enable row level security;
alter table public.ai_report_settings enable row level security;
revoke all on public.ai_reports_saved, public.ai_report_schedules, public.ai_report_sends, public.ai_report_settings
  from anon, authenticated;
grant select, insert, update, delete on public.ai_reports_saved, public.ai_report_schedules to authenticated;
grant select on public.ai_report_sends to authenticated;
grant select, update on public.ai_report_settings to authenticated;

drop policy if exists "ai_reports_saved read" on public.ai_reports_saved;
create policy "ai_reports_saved read" on public.ai_reports_saved
  for select to authenticated using ((select public.ai_report_caller_ok()));
drop policy if exists "ai_reports_saved insert" on public.ai_reports_saved;
create policy "ai_reports_saved insert" on public.ai_reports_saved
  for insert to authenticated
  with check ((select public.ai_report_caller_ok()) and (select public.caller_admin_can_write('ai_reports_saved')));
drop policy if exists "ai_reports_saved update" on public.ai_reports_saved;
create policy "ai_reports_saved update" on public.ai_reports_saved
  for update to authenticated
  using ((select public.ai_report_caller_ok()) and (select public.caller_admin_can_write('ai_reports_saved')))
  with check ((select public.ai_report_caller_ok()) and (select public.caller_admin_can_write('ai_reports_saved')));
drop policy if exists "ai_reports_saved delete" on public.ai_reports_saved;
create policy "ai_reports_saved delete" on public.ai_reports_saved
  for delete to authenticated
  using ((select public.ai_report_caller_ok()) and (select public.caller_admin_can_write('ai_reports_saved')));

drop policy if exists "ai_report_schedules read" on public.ai_report_schedules;
create policy "ai_report_schedules read" on public.ai_report_schedules
  for select to authenticated using ((select public.ai_report_caller_ok()));
drop policy if exists "ai_report_schedules insert" on public.ai_report_schedules;
create policy "ai_report_schedules insert" on public.ai_report_schedules
  for insert to authenticated
  with check ((select public.ai_report_caller_ok()) and (select public.caller_admin_can_write('ai_report_schedules')));
drop policy if exists "ai_report_schedules update" on public.ai_report_schedules;
create policy "ai_report_schedules update" on public.ai_report_schedules
  for update to authenticated
  using ((select public.ai_report_caller_ok()) and (select public.caller_admin_can_write('ai_report_schedules')))
  with check ((select public.ai_report_caller_ok()) and (select public.caller_admin_can_write('ai_report_schedules')));
drop policy if exists "ai_report_schedules delete" on public.ai_report_schedules;
create policy "ai_report_schedules delete" on public.ai_report_schedules
  for delete to authenticated
  using ((select public.ai_report_caller_ok()) and (select public.caller_admin_can_write('ai_report_schedules')));

drop policy if exists "ai_report_sends read" on public.ai_report_sends;
create policy "ai_report_sends read" on public.ai_report_sends
  for select to authenticated using ((select public.ai_report_caller_ok()));

drop policy if exists "ai_report_settings read" on public.ai_report_settings;
create policy "ai_report_settings read" on public.ai_report_settings
  for select to authenticated using ((select public.ai_report_caller_ok()));
drop policy if exists "ai_report_settings update" on public.ai_report_settings;
create policy "ai_report_settings update" on public.ai_report_settings
  for update to authenticated
  using ((select public.ai_report_caller_ok()) and (select public.caller_admin_can_write('ai_report_settings')))
  with check ((select public.ai_report_caller_ok()) and (select public.caller_admin_can_write('ai_report_settings')));

-- Admins a schedule can send to: who holds any admin page and has an email.
create or replace function public.ai_report_admins()
returns table (id uuid, name text, email text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not coalesce((public.ai_report_caller_scope() ->> 'edit')::boolean, false)
     or not public.caller_admin_can_write('ai_report_schedules') then
    raise exception 'Reports: you need edit access to Reports' using errcode = '42501';
  end if;
  return query
    select p.id, p.name, p.email
      from public.profiles p
     where p.deleted_at is null
       and nullif(btrim(coalesce(p.email, '')), '') is not null
       and exists (select 1 from public.admin_access a where a.profile_id = p.id)
     order by lower(coalesce(p.name, p.email)) asc
     limit 500;
end;
$$;
revoke execute on function public.ai_report_admins() from public, anon;
grant execute on function public.ai_report_admins() to authenticated;

-- ---- 6. Sending ---------------------------------------------------------------------------------
-- POSTs { ids, reason } to the ai-report-email function, with the push
-- webhook's Vault secret as location_ping_kick (0276) does.
create or replace function public.ai_report_email_kick(p_ids uuid[], p_reason text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url    text;
  v_secret text;
begin
  if coalesce(cardinality(p_ids), 0) = 0 then
    return false;
  end if;
  begin
    select decrypted_secret into v_url
      from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_secret
      from vault.decrypted_secrets where name = 'push_webhook_secret' limit 1;
  exception when others then
    return false;
  end;
  if v_url is null or v_secret is null then
    return false;
  end if;
  perform net.http_post(
    url     := v_url || '/functions/v1/ai-report-email',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body    := jsonb_build_object('ids', to_jsonb(p_ids), 'reason', left(coalesce(p_reason, ''), 20)),
    timeout_milliseconds := 60000
  );
  return true;
exception when others then
  return false;
end;
$$;
revoke execute on function public.ai_report_email_kick(uuid[], text) from public, anon, authenticated;

-- pg_cron, every 5 minutes: claims the due schedules (at most 20 a run),
-- moves each to its next run and hands them to the function.
create or replace function public.ai_report_schedules_due()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ids uuid[];
begin
  with due as (
    select s.id
      from public.ai_report_schedules s
     where not s.paused and s.next_run_at is not null and s.next_run_at <= now()
     order by s.next_run_at asc
     limit 20
       for update of s skip locked
  ),
  claimed as (
    update public.ai_report_schedules s
       set next_run_at = public.ai_report_next_run(s.frequency, s.at_time, s.weekdays, s.month_day,
                                                   greatest(now(), s.next_run_at)),
           last_claimed_at = now()
      from due
     where s.id = due.id
    returning s.id
  )
  select array_agg(c.id order by c.id) into v_ids from claimed c;
  if coalesce(cardinality(v_ids), 0) = 0 then
    return 0;
  end if;
  perform public.ai_report_email_kick(v_ids, 'scheduled');
  return cardinality(v_ids);
end;
$$;
revoke execute on function public.ai_report_schedules_due() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'ai-report-schedules';
    perform cron.schedule('ai-report-schedules', '*/5 * * * *', $job$select public.ai_report_schedules_due()$job$);
  end if;
end $$;

-- "Send now" from the page: an edit grant on Reports, at most once a
-- minute a schedule; the next scheduled run is left as it is.
create or replace function public.ai_report_schedule_send_now(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s jsonb := public.ai_report_caller_scope();
  v_at timestamptz;
  v_found boolean;
begin
  if not coalesce((s ->> 'ok')::boolean, false) or not public.caller_admin_can_write('rpc:ai_report_schedule_send_now') then
    raise exception 'Reports: you need edit access to Reports' using errcode = '42501';
  end if;
  select true, x.send_now_at into v_found, v_at from public.ai_report_schedules x where x.id = p_id for update;
  if not coalesce(v_found, false) then
    raise exception 'Reports: no such schedule' using errcode = 'P0002';
  end if;
  if v_at is not null and v_at > now() - interval '1 minute' then
    return jsonb_build_object('posted', false, 'retry_at', v_at + interval '1 minute');
  end if;
  update public.ai_report_schedules set send_now_at = now() where id = p_id;
  insert into public.admin_audit_log (actor_id, action, detail)
  values (auth.uid(), 'ai_report.send_now', jsonb_build_object('schedule_id', p_id));
  return jsonb_build_object('posted', public.ai_report_email_kick(array[p_id], 'now'));
end;
$$;
revoke execute on function public.ai_report_schedule_send_now(uuid) from public, anon;
grant execute on function public.ai_report_schedule_send_now(uuid) to authenticated;

-- What the function sends for one schedule: the report, run as the admin
-- who made it (their access is checked again), for this run's period, and
-- where to send it. Service role only; logged as a run.
create or replace function public.ai_report_schedule_job(p_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
set statement_timeout = '15s'
as $$
declare
  v record;
  v_scope jsonb;
  v_report jsonb;
  v_emails text[];
  v_from text;
begin
  select s.*, r.name as report_name, r.plan as report_plan
    into v
    from public.ai_report_schedules s
    join public.ai_reports_saved r on r.id = s.saved_id
   where s.id = p_id;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'The schedule is gone.');
  end if;
  v_scope := public.ai_report_scope_for(v.created_by);
  if not coalesce((v_scope ->> 'ok')::boolean, false) then
    return jsonb_build_object('ok', false, 'error',
      'The admin who made this schedule no longer has access to Reports.');
  end if;
  v_report := public.ai_report_exec((v.report_plan - 'period') || jsonb_build_object('period', v.period), v_scope);
  insert into public.admin_audit_log (actor_id, action, detail)
  values (v.created_by, 'ai_report.run',
          jsonb_build_object('dataset', v_report ->> 'dataset', 'rows', (v_report ->> 'row_count')::int,
                             'truncated', (v_report ->> 'truncated')::boolean, 'plan', v_report -> 'plan',
                             'schedule_id', v.id));
  update public.ai_reports_saved set last_run_at = now(), last_rows = (v_report ->> 'row_count')::int
   where id = v.saved_id;
  select array_agg(distinct lower(e)) into v_emails
    from (select unnest(v.emails) e
          union all
          select p.email from public.profiles p
           where p.id = any(v.admin_ids) and p.deleted_at is null
             and nullif(btrim(coalesce(p.email, '')), '') is not null
             and exists (select 1 from public.admin_access a where a.profile_id = p.id)) x;
  select email_from into v_from from public.ai_report_settings where id;
  return jsonb_build_object(
    'ok', true,
    'schedule', jsonb_build_object('id', v.id, 'name', v.report_name, 'subject', v.subject, 'message', v.message,
                                   'formats', to_jsonb(v.formats), 'link_only', v.link_only,
                                   'skip_empty', v.skip_empty, 'period', v.period),
    'from', v_from,
    'recipients', to_jsonb(coalesce(v_emails, '{}')),
    'catalogue', public.ai_report_public_catalogue(v_scope),
    'report', v_report);
end;
$$;
revoke execute on function public.ai_report_schedule_job(uuid) from public, anon, authenticated;
grant execute on function public.ai_report_schedule_job(uuid) to service_role;

-- Each send, logged by the function (service role only).
create or replace function public.ai_report_send_log(
  p_schedule uuid, p_reason text, p_rows integer, p_recipients integer, p_ok boolean, p_skipped boolean, p_error text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.ai_report_sends (schedule_id, reason, rows, recipients, ok, skipped, error)
  select p_schedule, left(p_reason, 20), p_rows, p_recipients, p_ok, coalesce(p_skipped, false), left(p_error, 500)
   where exists (select 1 from public.ai_report_schedules where id = p_schedule);
  update public.ai_report_schedules
     set last_run_at = now(),
         last_status = case when not p_ok then 'failed' when p_skipped then 'skipped' else 'sent' end,
         last_error = case when p_ok then null else left(p_error, 500) end
   where id = p_schedule;
end;
$$;
revoke execute on function public.ai_report_send_log(uuid, text, integer, integer, boolean, boolean, text)
  from public, anon, authenticated;
grant execute on function public.ai_report_send_log(uuid, text, integer, integer, boolean, boolean, text) to service_role;

-- Link-only emails: their files, kept private (the function signs links).
insert into storage.buckets (id, name, public) values ('ai-reports', 'ai-reports', false)
on conflict (id) do update set public = false;

notify pgrst, 'reload schema';
insert into supabase_migrations.schema_migrations (version, name) values ('20261024100000', '0280_ai_reports') on conflict do nothing;
