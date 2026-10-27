-- ============================================================================
-- 0299 — Services, partner types and vehicle services: quick fixes from the
-- study of 26 Oct 2026 (docs/KIV.md H1, M5, H2, M7, M8).
--
-- Version 20261027110000 (0299_services_quick_fixes). Re-runnable: functions
-- "create or replace", triggers dropped first, the one-off updates only touch
-- rows still missing what they fill.
--
-- 1. H1: a vehicle its driver owns (owner_match 'driver', 0288) gets the
--    driver's own ID and phone as the owner's where they are missing. The
--    registration flow saved the owner's ID only when the grant showed one,
--    so the car stayed "half set up" in the app once approved. The app now
--    saves them (and counts an approved vehicle as complete); this fills the
--    vehicles registered before.
-- 2. M5: an approved vehicle permit switches its services back on. The 0288
--    trigger compared vehicle_service_status.permit_type with the permit's
--    type id, but the app keeps the permit type's KEY there (Admin → Partner
--    Type → permit, partner_registration.dart). It now matches the key (and
--    the id, as before). The services already held up by a permit that is
--    approved are switched on once.
-- 3. H2: a service none of the partner's types allows (partner_type_services,
--    0259) is off for that driver in driver_service_effective, so pushes,
--    direct and targeted offers, scheduled rides, freight and courier
--    (everything through driver_takes_service) follow the same rule as the
--    open-request list. A partner with no type, or a type with no row, keeps
--    every service; street hail and add-ons are left out. A bid or take on
--    such a service says it is not one of their types.
-- 4. M7: an approved partner can't change their own Partner Service types
--    (PARTNER_TYPES_LOCKED): a new type is reviewed again, so an admin makes
--    the change. Admins, the server and sessions without claims are not held.
-- 5. M8: admin_same_ic_accounts(profile): the other accounts with the same ID
--    number (letters and digits only, as 0288's reg_id_key: 900101-14-5678 is
--    900101145678), for the "Same ID as another account" flag on the partner
--    review. Admins only. No unique index (still in docs/KIV.md).
-- ============================================================================

-- ---- 1. H1: the owner's ID and phone for vehicles the driver owns -------------------------------
update public.vehicle v
   set owner_ic = coalesce(nullif(btrim(v.owner_ic), ''), nullif(btrim(pr.ic), ''), nullif(btrim(p.ic), '')),
       owner_phone = coalesce(nullif(btrim(v.owner_phone), ''), nullif(btrim(p.phone), ''), nullif(btrim(pr.phone), ''))
  from public.partners p
  left join public.profiles pr on pr.id = p.auth_user_id
 where p.id = v.owner_partner_id
   and v.owner_match = 'driver'
   and (coalesce(btrim(v.owner_ic), '') = '' or coalesce(btrim(v.owner_phone), '') = '');

-- ---- 2. M5: an approved permit turns on the services waiting for it --------------------------------
-- As 0288, matching the permit type's key too.
create or replace function public.vehicle_documents_permit_turns_on()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.permit_type_id is null or new.status <> 'Approved'
     or (new.expiry_date is not null and new.expiry_date < current_date) then
    return null;
  end if;
  update public.vehicle_service_status s
     set status = 'active'
   where s.vehicle_id = new.vehicle_id
     and s.status = 'waiting_permit'
     and (s.permit_type is null
          or s.permit_type = new.permit_type_id::text
          or s.permit_type = (select pt.key from public.permit_types pt where pt.id = new.permit_type_id));
  return null;
end;
$$;
revoke execute on function public.vehicle_documents_permit_turns_on() from public, anon, authenticated;
drop trigger if exists trg_vehicle_documents_permit_turns_on on public.vehicle_documents;
create trigger trg_vehicle_documents_permit_turns_on
  after insert or update of status, permit_type_id, expiry_date on public.vehicle_documents
  for each row execute function public.vehicle_documents_permit_turns_on();

-- Once: the services still waiting for a permit that is already approved.
update public.vehicle_service_status s
   set status = 'active'
 where s.status = 'waiting_permit'
   and s.permit_type is not null
   and exists (
     select 1 from public.vehicle_documents d
       join public.permit_types pt on pt.id = d.permit_type_id
      where d.vehicle_id = s.vehicle_id
        and d.status = 'Approved'
        and (d.expiry_date is null or d.expiry_date >= current_date)
        and (s.permit_type = pt.key or s.permit_type = pt.id::text));

-- ---- 3. H2: the partner type's services, for every way a driver gets a job ---------------------------
-- Whether [p_driver]'s partner types allow [p_service] (0259's
-- caller_partner_service_ok for any driver): any of their types (partner_types,
-- else partner_type) allows it. Not a partner, no type, no service, street
-- hail or an add-on: true.
create or replace function public.driver_partner_service_ok(p_driver uuid, p_service text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_types text[];
begin
  if p_driver is null or coalesce(btrim(p_service), '') = '' or lower(btrim(p_service)) ~ '^(extra|hail):' then
    return true;
  end if;
  select array(select btrim(t)
                 from unnest(case when coalesce(cardinality(p.partner_types), 0) > 0
                                  then p.partner_types else array[p.partner_type] end) as t
                where coalesce(btrim(t), '') <> '')
    into v_types
    from public.partners p
   where p.auth_user_id = p_driver
   order by p.created_at
   limit 1;
  if coalesce(cardinality(v_types), 0) = 0 then
    return true;
  end if;
  return exists (select 1 from unnest(v_types) as t where public.partner_type_allows_service(t, p_service));
end;
$$;
revoke execute on function public.driver_partner_service_ok(uuid, text) from public, anon, authenticated;
grant execute on function public.driver_partner_service_ok(uuid, text) to service_role;

-- As 0288, and off when none of the driver's partner types allows it.
create or replace function public.driver_service_effective(p_driver uuid, p_vehicle uuid, p_service text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_key text := public.driver_service_key(p_service);
  l public.driver_service_locks;
begin
  if p_driver is null or coalesce(v_key, '') = '' then
    return true;
  end if;
  -- 0299: not a service of the driver's partner types (0259): off, as the
  -- open-request list already hides it, whatever the switch or a lock.
  if v_key !~ '^(extra|hail):' and not public.driver_partner_service_ok(p_driver, v_key) then
    return false;
  end if;
  -- 0288: paused for this vehicle (over its age limit, or waiting for the
  -- vehicle permit GET.ride uploads): off, whatever the switch or a lock.
  if p_vehicle is not null and v_key !~ '^(extra|hail):'
     and public.vehicle_service_block(p_vehicle, v_key) is not null then
    return false;
  end if;
  l := public.driver_service_lock(p_driver, p_vehicle, v_key);
  if l.id is not null then
    return l.mode = 'on';
  end if;
  return coalesce((select p.enabled from public.driver_service_prefs p
                    where p.driver_id = p_driver and p.vehicle_id = p_vehicle and p.service_key = v_key), true);
end;
$$;
revoke execute on function public.driver_service_effective(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.driver_service_effective(uuid, uuid, text) to service_role;

-- As 0288, and a bid or take on a service the driver's types don't allow
-- says so (not "You turned it off").
create or replace function public.ride_requests_driver_services()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app boolean := coalesce(current_setting('role', true), '') in ('anon', 'authenticated');
  v_keep uuid[];
  l public.driver_service_locks;
  v_block jsonb;
begin
  if tg_op = 'INSERT' then
    if coalesce(btrim(new.service), '') = '' then
      return new;
    end if;
    if v_app and new.status = 'open' and new.direct_driver_id is not null
       and not public.driver_takes_service(new.direct_driver_id, new.service) then
      raise exception 'DRIVER_SERVICE_OFF_DIRECT' using errcode = '42501',
        hint = format('This driver doesn''t take %s requests right now. Choose another service, or book without the code.',
                      new.service);
    end if;
    if new.direct_driver_id is null and coalesce(cardinality(new.target_driver_ids), 0) > 0 then
      select coalesce(array_agg(d), '{}') into v_keep
        from unnest(new.target_driver_ids) d
       where public.driver_takes_service(d, new.service);
      if cardinality(v_keep) = 0 then
        new.target_driver_ids := null;
        new.targeted_until := null;
      else
        new.target_driver_ids := v_keep;
      end if;
    end if;
    return new;
  end if;
  -- A driver's own bid or take from the app.
  if v_app and old.status = 'open'
     and new.partner_id is not null and new.partner_id is distinct from old.partner_id
     and new.partner_id = auth.uid()
     and not public.driver_takes_service(new.partner_id, old.service) then
    -- 0299: not a service of the driver's partner types.
    if not public.driver_partner_service_ok(new.partner_id, old.service) then
      raise exception 'DRIVER_SERVICE_OFF' using errcode = '42501',
        hint = format('Your Partner Service types don''t take %s requests.', old.service);
    end if;
    -- 0288: paused for this vehicle.
    v_block := public.vehicle_service_block(public.driver_session_vehicle(new.partner_id), old.service);
    if v_block is not null then
      raise exception 'VEHICLE_SERVICE_PAUSED' using errcode = '42501',
        hint = public.vehicle_service_block_text(v_block);
    end if;
    l := public.driver_service_lock(new.partner_id, public.driver_session_vehicle(new.partner_id), old.service);
    raise exception 'DRIVER_SERVICE_OFF' using errcode = '42501',
      hint = case when l.id is not null
                  then format('get.ride keeps %s off for you. Contact support to change it.', old.service)
                  else format('You turned %s off in Services. Turn it on to take these requests.', old.service) end;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_driver_services() from public, anon, authenticated;

-- ---- 4. M7: an approved partner's types are changed by an admin ---------------------------------------
-- The types a row has, as the rules compare them (no case, spaces, _ or -),
-- each once and in order: re-saving the same types is no change.
create or replace function public.partner_type_set(p_types text[], p_type text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(distinct public.ptr_key(t) order by public.ptr_key(t)), '{}')
    from unnest(case when coalesce(cardinality(p_types), 0) > 0 then p_types
                     else string_to_array(coalesce(p_type, ''), ',') end) as t
   where public.ptr_key(t) <> '';
$$;
grant execute on function public.partner_type_set(text[], text) to authenticated, service_role;

create or replace function public.partners_types_locked()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(nullif(current_setting('request.jwt.claims', true), ''), '') = ''
     or coalesce(auth.jwt() ->> 'role', '') not in ('authenticated', 'anon')
     or public.caller_is_admin() then
    return new;
  end if;
  if (old.status::text = 'approved' or old.status::text like 'permit-%')
     and public.partner_type_set(new.partner_types, new.partner_type)
         is distinct from public.partner_type_set(old.partner_types, old.partner_type) then
    raise exception 'PARTNER_TYPES_LOCKED' using errcode = '42501',
      hint = 'Your account is approved, so your Partner Service types can''t be changed here. '
             'Contact support to add or change one: an admin reviews it first.';
  end if;
  return new;
end;
$$;
revoke execute on function public.partners_types_locked() from public, anon, authenticated;
-- "a_" so it refuses before 0245's type rules look at the new types.
drop trigger if exists trg_partners_a_types_locked on public.partners;
create trigger trg_partners_a_types_locked
  before update of partner_types, partner_type on public.partners
  for each row execute function public.partners_types_locked();

-- ---- 5. M8: other accounts with the same ID number ---------------------------------------------------
-- For the partner review: the accounts (not [p_profile], not deleted) whose
-- ID number is [p_profile]'s, compared as reg_id_key. Under 6 characters:
-- none.
create or replace function public.admin_same_ic_accounts(p_profile uuid)
returns table (profile_id uuid, display_id text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_key text;
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select public.reg_id_key(pr.ic) into v_key
    from public.profiles pr where pr.id = p_profile;
  if coalesce(length(v_key), 0) < 6 then
    return;
  end if;
  return query
    select pr.id, coalesce(nullif(btrim(pr.display_id), ''), left(pr.id::text, 8))
      from public.profiles pr
     where pr.id <> p_profile
       and pr.deleted_at is null
       and lower(pr.profile_status::text) <> 'deleted'
       and public.reg_id_key(pr.ic) = v_key
     order by pr.created_at, pr.id
     limit 20;
end;
$$;
revoke execute on function public.admin_same_ic_accounts(uuid) from public, anon;
grant execute on function public.admin_same_ic_accounts(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
