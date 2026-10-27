-- ============================================================================
-- 0304 — Renaming a Vehicle Service or a Partner Service type keeps every
-- place that uses the name working (docs/KIV.md M2).
--
-- Version 20261027210000 (0304_safe_renames). Re-runnable: the table and its
-- indexes "if not exists", functions "create or replace", policies and
-- triggers dropped first, the page rows "on conflict do nothing".
--
-- Services, types, switches, locks and promotions find a Vehicle Service or a
-- Partner Service type by its NAME, so an admin who renamed one cut them off
-- without a word. The names stay the links (nothing moves to ids); a rename
-- now changes every place that holds the old name in the same transaction:
--
-- 1. A Vehicle Service (settings_entries 'vehicle-services'):
--      * the services each partner type sees (partner_type_services.services,
--        0259);
--      * drivers' switches and get.ride's locks (driver_service_prefs and
--        driver_service_locks.service_key, driver_service_key form, 0263);
--      * promo codes (promo_codes.services, 0242), commission promotions
--        (commission_promotions.services, lower case, 0224) and the permit
--        types asked for it (permit_types.services, 0254);
--      * open requests (open, accepted, arrived, on trip) and bookings for
--        later (scheduled, assigned: the service and the saved request), so
--        they keep running under the new name. Finished rides keep the name
--        they had: they are history.
-- 2. A Partner Service type (settings_entries 'partner-type'):
--      * the services it sees (partner_type_services.type_key / type_name);
--      * partners (partner_types, and the older partner_type list) and
--        vehicles (partner_types). Approved partners keep their approval:
--        the change is the server's (PARTNER_TYPES_LOCKED, 0299, holds the
--        partner's own edits only; an admin's and the server's pass);
--      * the per-vehicle service checks (vehicle_service_status.service and
--        limit_type, 0288/0301), kept as set (set_by_admin stays);
--      * permit types (permit_types.partner_types), push audiences (saved
--        pushes' partnerTypes, pushes still to send), required documents'
--        partnerTypes and the other types' vehiclePermitAlsoFor and
--        ageLimitCovers[].types (lists, JSON text or comma lists);
--      * driver locks on the type (driver_service_locks.partner_type).
--      The type's own entry keeps its "Vehicle required" default as a stored
--      value (eHailing and pHailing need one by name, 0245). Teksi is built
--      in by name (the meter, the taxi rules) and is not renamed.
--      Sent pushes (push_notifications) are history and keep the name.
-- 3. admin_rename_preview(category, entry, new name): per place, how many
--    rows change and a few examples; the open requests, bookings and
--    finished rides; and the problem with the name, if any (taken: the same
--    name in the category without case or extra spaces, or the same key).
--    admin_rename_apply(...) renames the entry and every place at once and
--    keeps a settings_renames row (who, when, old, new, the counts).
--    admin_rename_undo(rename) changes the latest rename of an entry back
--    the same way, once. EDIT on the Vehicle Services or Partner Service
--    type page (caller_admin_can_write, 'rpc:admin_rename:<category>').
-- 4. A name change of either category saved straight to settings_entries
--    from the apps is refused (RENAME_THROUGH_PREVIEW): only the RPCs above
--    change it (a transaction-local flag they set). An entry with no name
--    yet, the server and migrations are not held.
-- ============================================================================

-- ---- 1. Rename history ---------------------------------------------------------------------------
create table if not exists public.settings_renames (
  id         uuid primary key default gen_random_uuid(),
  category   text not null check (category in ('vehicle-services', 'partner-type')),
  entry_id   uuid not null,
  old_name   text not null check (char_length(old_name) <= 200),
  new_name   text not null check (char_length(new_name) <= 200),
  -- Rows changed per place ({"driver_switches": 12, ...}) and their sum.
  places     jsonb not null default '{}'::jsonb check (jsonb_typeof(places) = 'object'),
  total      integer not null default 0,
  renamed_by uuid references public.profiles(id) on delete set null,
  -- The admin's name then, for the history card.
  by_name    text check (by_name is null or char_length(by_name) <= 200),
  at         timestamptz not null default clock_timestamp(),
  undone_at  timestamptz,
  undone_by  uuid references public.profiles(id) on delete set null
);
comment on table public.settings_renames is
  'Renames of a Vehicle Service or Partner Service type and the places they changed (0304). Written by admin_rename_apply / admin_rename_undo only.';
create index if not exists settings_renames_entry_idx on public.settings_renames (entry_id, at desc);
create index if not exists settings_renames_renamed_by_idx on public.settings_renames (renamed_by);
create index if not exists settings_renames_undone_by_idx on public.settings_renames (undone_by);

alter table public.settings_renames enable row level security;
revoke all on public.settings_renames from anon, authenticated;
grant select on public.settings_renames to authenticated;
grant all on public.settings_renames to service_role;
drop policy if exists "settings_renames admin read" on public.settings_renames;
create policy "settings_renames admin read" on public.settings_renames
  for select to authenticated using ((select public.caller_is_admin()));

-- Who may rename (and preview, and undo) in each category.
insert into public.admin_table_pages (target, page) values
  ('rpc:admin_rename:vehicle-services', 'admin-settings-vehicle-services'),
  ('rpc:admin_rename:partner-type', 'admin-settings-partner-type')
on conflict do nothing;

-- ---- 2. Lists --------------------------------------------------------------------------------------
-- Whether [p] holds [p_old] (compared as ptr_key: no case, spaces, _ or -).
create or replace function public.safe_rename_has(p text[], p_old text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select public.ptr_key(p_old) <> ''
     and exists (select 1 from unnest(coalesce(p, '{}'::text[])) x where public.ptr_key(x) = public.ptr_key(p_old));
$$;

-- [p] with [p_old] as [p_new], in place; the new name once (its first place).
create or replace function public.safe_rename_list(p text[], p_old text, p_new text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(b.y order by b.n), '{}'::text[])
    from (select a.y, a.n,
                 min(a.n) filter (where public.ptr_key(a.y) = public.ptr_key(p_new)) over () as first_new
            from (select case when public.ptr_key(x) = public.ptr_key(p_old) then p_new else x end as y, n
                    from unnest(coalesce(p, '{}'::text[])) with ordinality u(x, n)) a) b
   where public.ptr_key(b.y) <> public.ptr_key(p_new) or b.n = b.first_new;
$$;

-- The names in a stored list: a JSON array, the same as JSON text, or an
-- older comma list.
create or replace function public.safe_rename_items(p jsonb)
returns text[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  v jsonb;
begin
  if p is null then
    return '{}';
  end if;
  v := case when jsonb_typeof(p) = 'string' then public.ptr_json(p) else p end;
  if jsonb_typeof(v) = 'array' then
    return array(select x from jsonb_array_elements_text(v) x);
  end if;
  if jsonb_typeof(p) = 'string' then
    return array(select btrim(x) from unnest(string_to_array(p #>> '{}', ',')) x where btrim(x) <> '');
  end if;
  return '{}';
end;
$$;

-- [p] with [p_old] as [p_new], kept in the form it had; unchanged when it
-- doesn't hold the old name.
create or replace function public.safe_rename_json_list(p jsonb, p_old text, p_new text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_items text[] := public.safe_rename_items(p);
  v_new   text[];
begin
  if not public.safe_rename_has(v_items, p_old) then
    return p;
  end if;
  v_new := public.safe_rename_list(v_items, p_old, p_new);
  if jsonb_typeof(p) = 'array' then
    return to_jsonb(v_new);
  end if;
  if jsonb_typeof(public.ptr_json(p)) = 'array' then
    return to_jsonb(to_jsonb(v_new)::text);
  end if;
  return to_jsonb(array_to_string(v_new, ','));
end;
$$;

-- A Partner Service type's ageLimitCovers with [p_old] as [p_new] in each
-- rule's types (an array or JSON text, kept as it was).
create or replace function public.safe_rename_covers(p jsonb, p_old text, p_new text)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v       jsonb := public.ptr_json(p);
  v_out   jsonb := '[]'::jsonb;
  r       jsonb;
  t       jsonb;
  changed boolean := false;
begin
  if v is null or jsonb_typeof(v) <> 'array' then
    return p;
  end if;
  for r in select x from jsonb_array_elements(v) x loop
    if jsonb_typeof(r) = 'object' and r ? 'types' then
      t := public.safe_rename_json_list(r -> 'types', p_old, p_new);
      if t is distinct from r -> 'types' then
        changed := true;
        r := jsonb_set(r, '{types}', t);
      end if;
    end if;
    v_out := v_out || jsonb_build_array(r);
  end loop;
  if not changed then
    return p;
  end if;
  return case when jsonb_typeof(p) = 'string' then to_jsonb(v_out::text) else v_out end;
end;
$$;

-- Whether a Partner Service type's values name [p_old] in another type's
-- settings (vehiclePermitAlsoFor, ageLimitCovers).
create or replace function public.safe_rename_type_values_have(v jsonb, p_old text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select public.safe_rename_has(public.safe_rename_items(v -> 'vehiclePermitAlsoFor'), p_old)
      or public.safe_rename_covers(v -> 'ageLimitCovers', p_old, '~') is distinct from v -> 'ageLimitCovers';
$$;

revoke execute on function public.safe_rename_has(text[], text), public.safe_rename_list(text[], text, text),
  public.safe_rename_items(jsonb), public.safe_rename_json_list(jsonb, text, text),
  public.safe_rename_covers(jsonb, text, text), public.safe_rename_type_values_have(jsonb, text)
  from public, anon, authenticated;

-- One place of a preview: its key, the rows it changes and up to three
-- examples.
create or replace function public.safe_rename_place(p_key text, p_count bigint, p_examples text[])
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'key', p_key,
    'count', coalesce(p_count, 0),
    'examples', to_jsonb(coalesce((p_examples)[1:3], '{}'::text[])),
    'more', greatest(coalesce(p_count, 0) - coalesce(cardinality((p_examples)[1:3]), 0), 0));
$$;
revoke execute on function public.safe_rename_place(text, bigint, text[]) from public, anon, authenticated;

-- ---- 3. The checks ---------------------------------------------------------------------------------
-- What is wrong with renaming [p_entry] of [p_category] from [p_old] to
-- [p_new] ({code, message, conflict_name}), or null.
create or replace function public.safe_rename_problem(p_category text, p_entry uuid, p_old text, p_new text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_label text := case p_category when 'vehicle-services' then 'Vehicle Service' else 'Partner Service type' end;
  v_other text;
begin
  if public.ptr_key(p_new) = '' then
    return jsonb_build_object('code', 'RENAME_NAME_EMPTY', 'message', 'Enter a name.');
  end if;
  if char_length(p_new) > 80 then
    return jsonb_build_object('code', 'RENAME_NAME_LONG', 'message', 'A name can be at most 80 characters.');
  end if;
  if p_new = p_old then
    return jsonb_build_object('code', 'RENAME_SAME', 'message', 'The name is the same as before.');
  end if;
  if p_category = 'partner-type' and position(',' in p_new) > 0 then
    return jsonb_build_object('code', 'RENAME_NAME_COMMA', 'message', 'A Partner Service type name can''t have a comma.');
  end if;
  if p_category = 'partner-type' and (public.ptr_key(p_old) = 'teksi') <> (public.ptr_key(p_new) = 'teksi') then
    return jsonb_build_object('code', 'RENAME_BUILT_IN', 'message',
      'Teksi is built into the app (the meter and the taxi rules) by its name, so it keeps it.');
  end if;
  if p_category = 'vehicle-services' and lower(p_new) ~ '^(extra|hail):' then
    return jsonb_build_object('code', 'RENAME_NAME_RESERVED', 'message',
      'A Vehicle Service name can''t start with "extra:" or "hail:".');
  end if;
  select btrim(e.values ->> 'name') into v_other
    from public.settings_entries e
   where e.category = p_category and e.id <> p_entry
     and (lower(btrim(coalesce(e.values ->> 'name', ''))) = lower(p_new)
          or public.ptr_key(e.values ->> 'name') = public.ptr_key(p_new))
   order by e.position, e.created_at
   limit 1;
  if v_other is not null then
    return jsonb_build_object('code', 'RENAME_NAME_TAKEN', 'conflict_name', v_other,
      'message', format('A %s named %s already exists.', v_label, v_other));
  end if;
  return null;
end;
$$;
revoke execute on function public.safe_rename_problem(text, uuid, text, text) from public, anon, authenticated;

-- The caller may rename in [p_category]: EDIT on its page.
create or replace function public.safe_rename_allowed(p_category text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_category in ('vehicle-services', 'partner-type')
     and public.caller_admin_can_write('rpc:admin_rename:' || p_category);
$$;
revoke execute on function public.safe_rename_allowed(text) from public, anon, authenticated;

-- ---- 4. The cascade ------------------------------------------------------------------------------
-- Every place that uses [p_old] in [p_category]: what changes (a preview),
-- and with [p_apply] the change itself, the entry [p_entry] first. Answers
-- {places: [{key, count, examples, more}], total, open_requests, bookings,
-- finished_rides}; the counts are the rows changed.
create or replace function public.safe_rename_run(
  p_category text, p_entry uuid, p_old text, p_new text, p_apply boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ok       text := public.ptr_key(p_old);
  nk       text := public.ptr_key(p_new);
  dk_old   text := public.driver_service_key(p_old);
  dk_new   text := public.driver_service_key(p_new);
  lo       text := lower(btrim(coalesce(p_old, '')));
  v_places jsonb := '[]'::jsonb;
  n        bigint;
  ex       text[];
  v_open   bigint := 0;
  v_book   bigint := 0;
  v_done   bigint := 0;
begin
  -- ---- What changes -------------------------------------------------------------------------
  if ok = '' then
    null; -- An entry with no name yet: nothing uses it.
  elsif p_category = 'vehicle-services' then
    select count(*), (array_agg(s.type_name order by s.type_name))[1:3] into n, ex
      from public.partner_type_services s where public.safe_rename_has(s.services, p_old);
    v_places := v_places || public.safe_rename_place('type_services', n, ex);

    select count(*), (array_agg(distinct coalesce(nullif(btrim(pr.name), ''), 'A driver')))[1:3] into n, ex
      from public.driver_service_prefs d left join public.profiles pr on pr.id = d.driver_id
     where d.service_key = dk_old and dk_old <> dk_new;
    v_places := v_places || public.safe_rename_place('driver_switches', n, ex);

    select count(*),
           (array_agg(case l.scope
                        when 'driver' then coalesce(nullif(btrim(pr.name), ''), 'A driver')
                        when 'fleet' then 'A fleet'
                        when 'region' then concat_ws(', ', l.region_city, l.region_state, l.region_country)
                        else 'Everyone' end
                      || case l.mode when 'on' then ' (kept on)' else ' (kept off)' end
                      order by l.created_at))[1:3]
      into n, ex
      from public.driver_service_locks l left join public.profiles pr on pr.id = l.driver_id
     where l.service_key = dk_old and dk_old <> dk_new and l.scope <> 'partner_type';
    v_places := v_places || public.safe_rename_place('service_locks', n, ex);

    select count(*),
           (array_agg(coalesce(s.type_name, l.partner_type)
                      || case l.mode when 'on' then ': locked on' else ': locked off' end
                      order by l.created_at))[1:3]
      into n, ex
      from public.driver_service_locks l left join public.partner_type_services s on s.type_key = l.partner_type
     where l.service_key = dk_old and dk_old <> dk_new and l.scope = 'partner_type';
    v_places := v_places || public.safe_rename_place('partner_type_locks', n, ex);

    select count(*), (array_agg(c.code order by c.code))[1:3] into n, ex
      from public.promo_codes c where public.safe_rename_has(c.services, p_old);
    v_places := v_places || public.safe_rename_place('promo_codes', n, ex);

    select count(*), (array_agg(c.name order by c.name))[1:3] into n, ex
      from public.commission_promotions c where public.safe_rename_has(c.services, p_old);
    v_places := v_places || public.safe_rename_place('commission_promotions', n, ex);

    select count(*), (array_agg(t.name order by t.name))[1:3] into n, ex
      from public.permit_types t where public.safe_rename_has(t.services, p_old);
    v_places := v_places || public.safe_rename_place('permit_services', n, ex);

    select count(*) into v_open from public.ride_requests r
     where lower(btrim(r.service)) = lo and r.status in ('open', 'accepted', 'arrived', 'on_trip');
    select count(*) into v_book from public.scheduled_rides b
     where b.status in ('scheduled', 'assigned')
       and (lower(btrim(b.service)) = lo or lower(btrim(b.request ->> 'service')) = lo);
    select count(*) into v_done from public.ride_requests r
     where lower(btrim(r.service)) = lo and r.status not in ('open', 'accepted', 'arrived', 'on_trip');
  else
    select count(*), array['Services each type sees'] into n, ex
      from public.partner_type_services s where s.type_key = ok;
    v_places := v_places || public.safe_rename_place('type_services', n, case when n > 0 then ex end);

    select count(*), (array_agg(coalesce(nullif(btrim(p.name), ''), 'A partner') order by p.name))[1:3] into n, ex
      from public.partners p
     where public.safe_rename_has(p.partner_types, p_old)
        or public.safe_rename_has(string_to_array(coalesce(p.partner_type, ''), ','), p_old);
    v_places := v_places || public.safe_rename_place('partners', n, ex);

    select count(*), (array_agg(v.plate order by v.plate))[1:3] into n, ex
      from public.vehicle v where public.safe_rename_has(v.partner_types, p_old);
    v_places := v_places || public.safe_rename_place('vehicles', n, ex);

    select count(*), (array_agg(distinct v.plate))[1:3] into n, ex
      from public.vehicle_service_status s join public.vehicle v on v.id = s.vehicle_id
     where public.ptr_key(s.service) = ok or public.ptr_key(s.limit_type) = ok;
    v_places := v_places || public.safe_rename_place('vehicle_checks', n, ex);

    select count(*), (array_agg(t.name order by t.name))[1:3] into n, ex
      from public.permit_types t where public.safe_rename_has(t.partner_types, p_old);
    v_places := v_places || public.safe_rename_place('permit_types', n, ex);

    select count(*), (array_agg(x.title order by x.title))[1:3] into n, ex
      from (select coalesce(nullif(btrim(e.values ->> 'title'), ''), 'A saved push') as title
              from public.settings_entries e
             where e.category = 'push-notification'
               and public.safe_rename_has(public.safe_rename_items(e.values -> 'partnerTypes'), p_old)
            union all
            select coalesce(nullif(btrim(s.title), ''), 'A push to send')
              from public.push_schedules s
             where s.status = 'active' and public.safe_rename_has(s.partner_types, p_old)) x;
    v_places := v_places || public.safe_rename_place('push_audiences', n, ex);

    select count(*), (array_agg(x.name order by x.name))[1:3] into n, ex
      from (select 'Required documents: ' || coalesce(nullif(btrim(d.values ->> 'name'), ''), 'a document') as name
              from public.required_document d
             where public.safe_rename_has(public.safe_rename_items(d.values -> 'partnerTypes'), p_old)
            union all
            select coalesce(nullif(btrim(e.values ->> 'name'), ''), 'A type') || ': vehicle permit and age limit'
              from public.settings_entries e
             where e.category = 'partner-type' and public.safe_rename_type_values_have(e.values, p_old)) x;
    v_places := v_places || public.safe_rename_place('document_rules', n, ex);

    select count(*),
           (array_agg(l.service_key || case l.mode when 'on' then ' locked on' else ' locked off' end
                      order by l.created_at))[1:3]
      into n, ex
      from public.driver_service_locks l where l.partner_type = ok and ok <> nk;
    v_places := v_places || public.safe_rename_place('driver_locks', n, ex);
  end if;

  if p_apply then
    perform set_config('app.safe_rename', 'on', true);

    -- The entry itself. A type keeps its "Vehicle required" default (0245
    -- gives eHailing and pHailing one by name) as a stored value.
    update public.settings_entries e
       set values = jsonb_set(e.values, '{name}', to_jsonb(p_new))
                    || case when p_category = 'partner-type' and not (e.values ? 'vehicleRequired')
                            then jsonb_build_object('vehicleRequired', ok in ('teksi', 'ehailing', 'phailing'))
                            else '{}'::jsonb end,
           updated_at = now()
     where e.id = p_entry;

    if ok = '' then
      null;
    elsif p_category = 'vehicle-services' then
      update public.partner_type_services s
         set services = public.safe_rename_list(s.services, p_old, p_new)
       where public.safe_rename_has(s.services, p_old);

      if dk_old <> dk_new then
        -- A switch or lock left on the new key from a service gone before
        -- gives way to the live one.
        delete from public.driver_service_prefs t
         where t.service_key = dk_new
           and exists (select 1 from public.driver_service_prefs o
                        where o.driver_id = t.driver_id and o.vehicle_id = t.vehicle_id and o.service_key = dk_old);
        update public.driver_service_prefs set service_key = dk_new where service_key = dk_old;

        delete from public.driver_service_locks t
         where t.service_key = dk_new
           and exists (select 1 from public.driver_service_locks o
                        where o.service_key = dk_old and o.scope = t.scope
                          and o.driver_id is not distinct from t.driver_id
                          and o.partner_type is not distinct from t.partner_type
                          and o.fleet_id is not distinct from t.fleet_id
                          and lower(coalesce(o.region_country, '')) = lower(coalesce(t.region_country, ''))
                          and lower(coalesce(o.region_state, '')) = lower(coalesce(t.region_state, ''))
                          and lower(coalesce(o.region_city, '')) = lower(coalesce(t.region_city, '')));
        update public.driver_service_locks set service_key = dk_new where service_key = dk_old;
      end if;

      update public.promo_codes c
         set services = public.safe_rename_list(c.services, p_old, p_new)
       where public.safe_rename_has(c.services, p_old);
      update public.commission_promotions c
         set services = public.safe_rename_list(c.services, p_old, lower(btrim(p_new)))
       where public.safe_rename_has(c.services, p_old);
      update public.permit_types t
         set services = public.safe_rename_list(t.services, p_old, p_new)
       where public.safe_rename_has(t.services, p_old);

      -- What is still running follows; finished rides keep their name.
      update public.ride_requests r
         set service = p_new
       where lower(btrim(r.service)) = lo and r.status in ('open', 'accepted', 'arrived', 'on_trip');
      update public.scheduled_rides b
         set service = case when lower(btrim(b.service)) = lo then p_new else b.service end,
             request = case when lower(btrim(b.request ->> 'service')) = lo
                            then jsonb_set(b.request, '{service}', to_jsonb(p_new)) else b.request end
       where b.status in ('scheduled', 'assigned')
         and (lower(btrim(b.service)) = lo or lower(btrim(b.request ->> 'service')) = lo);
    else
      if ok <> nk then
        delete from public.partner_type_services s
         where s.type_key = nk and exists (select 1 from public.partner_type_services o where o.type_key = ok);
      end if;
      update public.partner_type_services s set type_key = nk, type_name = p_new where s.type_key = ok;

      -- The checks before the vehicles: a submitted vehicle's new types run
      -- the checks again (0301), which then find these rows.
      perform set_config('app.vehicle_service_fill', 'on', true);
      if ok <> nk then
        delete from public.vehicle_service_status t
         where public.ptr_key(t.service) = nk
           and exists (select 1 from public.vehicle_service_status o
                        where o.vehicle_id = t.vehicle_id and public.ptr_key(o.service) = ok);
      end if;
      update public.vehicle_service_status s
         set service = case when public.ptr_key(s.service) = ok then p_new else s.service end,
             limit_type = case when public.ptr_key(s.limit_type) = ok then p_new else s.limit_type end
       where public.ptr_key(s.service) = ok or public.ptr_key(s.limit_type) = ok;
      perform set_config('app.vehicle_service_fill', '', true);

      update public.partners p
         set partner_types = case when public.safe_rename_has(p.partner_types, p_old)
                                  then public.safe_rename_list(p.partner_types, p_old, p_new)
                                  else p.partner_types end,
             partner_type = case when public.safe_rename_has(string_to_array(coalesce(p.partner_type, ''), ','), p_old)
                                 then array_to_string(public.safe_rename_list(
                                        array(select btrim(x) from unnest(string_to_array(p.partner_type, ',')) x),
                                        p_old, p_new), ',')
                                 else p.partner_type end
       where public.safe_rename_has(p.partner_types, p_old)
          or public.safe_rename_has(string_to_array(coalesce(p.partner_type, ''), ','), p_old);
      update public.vehicle v
         set partner_types = public.safe_rename_list(v.partner_types, p_old, p_new)
       where public.safe_rename_has(v.partner_types, p_old);

      update public.permit_types t
         set partner_types = public.safe_rename_list(t.partner_types, p_old, p_new)
       where public.safe_rename_has(t.partner_types, p_old);

      update public.settings_entries e
         set values = jsonb_set(e.values, '{partnerTypes}',
                                public.safe_rename_json_list(e.values -> 'partnerTypes', p_old, p_new)),
             updated_at = now()
       where e.category = 'push-notification'
         and public.safe_rename_has(public.safe_rename_items(e.values -> 'partnerTypes'), p_old);
      update public.push_schedules s
         set partner_types = public.safe_rename_list(s.partner_types, p_old, p_new)
       where s.status = 'active' and public.safe_rename_has(s.partner_types, p_old);

      update public.required_document d
         set values = jsonb_set(d.values, '{partnerTypes}',
                                public.safe_rename_json_list(d.values -> 'partnerTypes', p_old, p_new)),
             updated_at = now()
       where public.safe_rename_has(public.safe_rename_items(d.values -> 'partnerTypes'), p_old);
      update public.settings_entries e
         set values = e.values
                      || case when e.values ? 'vehiclePermitAlsoFor'
                              then jsonb_build_object('vehiclePermitAlsoFor',
                                     public.safe_rename_json_list(e.values -> 'vehiclePermitAlsoFor', p_old, p_new))
                              else '{}'::jsonb end
                      || case when e.values ? 'ageLimitCovers'
                              then jsonb_build_object('ageLimitCovers',
                                     public.safe_rename_covers(e.values -> 'ageLimitCovers', p_old, p_new))
                              else '{}'::jsonb end,
             updated_at = now()
       where e.category = 'partner-type' and public.safe_rename_type_values_have(e.values, p_old);

      if ok <> nk then
        delete from public.driver_service_locks t
         where t.partner_type = nk
           and exists (select 1 from public.driver_service_locks o
                        where o.partner_type = ok and o.scope = t.scope and o.service_key = t.service_key);
        update public.driver_service_locks set partner_type = nk where partner_type = ok;
      end if;
    end if;

    perform set_config('app.safe_rename', '', true);
  end if;

  return jsonb_build_object(
    'places', v_places,
    'total', coalesce((select sum((x ->> 'count')::bigint) from jsonb_array_elements(v_places) x), 0),
    'open_requests', v_open,
    'bookings', v_book,
    'finished_rides', v_done);
end;
$$;
revoke execute on function public.safe_rename_run(text, uuid, text, text, boolean) from public, anon, authenticated;

-- ---- 5. The admin's RPCs -----------------------------------------------------------------------------
-- What renaming [p_entry] of [p_category] to [p_new_name] would change:
-- {category, entry_id, old_name, new_name, problem ({code, message,
-- conflict_name}) or null, conflict, places, total, open_requests, bookings,
-- finished_rides}. With a problem the places are left out.
create or replace function public.admin_rename_preview(p_category text, p_entry uuid, p_new_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  e         public.settings_entries;
  v_old     text;
  v_new     text := btrim(coalesce(p_new_name, ''));
  v_problem jsonb;
  v_run     jsonb := '{}'::jsonb;
begin
  if not public.safe_rename_allowed(p_category) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into e from public.settings_entries where id = p_entry and category = p_category;
  if not found then
    raise exception 'RENAME_NOT_FOUND' using errcode = 'P0002', hint = 'This entry is no longer there.';
  end if;
  v_old := btrim(coalesce(e.values ->> 'name', ''));
  v_problem := public.safe_rename_problem(p_category, p_entry, v_old, v_new);
  if v_problem is null then
    v_run := public.safe_rename_run(p_category, p_entry, v_old, v_new, false);
  end if;
  return jsonb_build_object(
    'category', p_category, 'entry_id', p_entry, 'old_name', v_old, 'new_name', v_new,
    'problem', v_problem,
    'conflict', coalesce(v_problem ->> 'code' = 'RENAME_NAME_TAKEN', false),
    'places', coalesce(v_run -> 'places', '[]'::jsonb),
    'total', coalesce((v_run ->> 'total')::bigint, 0),
    'open_requests', coalesce((v_run ->> 'open_requests')::bigint, 0),
    'bookings', coalesce((v_run ->> 'bookings')::bigint, 0),
    'finished_rides', coalesce((v_run ->> 'finished_rides')::bigint, 0));
end;
$$;

-- Renames [p_entry] of [p_category] to [p_new_name] and every place that
-- uses the old name, in one go, and keeps the history row. Answers
-- {id, old_name, new_name, total, places ({key: count}), open_requests,
-- bookings}.
create or replace function public.admin_rename_apply(p_category text, p_entry uuid, p_new_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  e         public.settings_entries;
  v_old     text;
  v_new     text := btrim(coalesce(p_new_name, ''));
  v_problem jsonb;
  v_run     jsonb;
  v_counts  jsonb;
  v_id      uuid;
begin
  if not public.safe_rename_allowed(p_category) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select * into e from public.settings_entries where id = p_entry and category = p_category for update;
  if not found then
    raise exception 'RENAME_NOT_FOUND' using errcode = 'P0002', hint = 'This entry is no longer there.';
  end if;
  v_old := btrim(coalesce(e.values ->> 'name', ''));
  v_problem := public.safe_rename_problem(p_category, p_entry, v_old, v_new);
  if v_problem is not null then
    raise exception '%', v_problem ->> 'code' using errcode = '23505', hint = v_problem ->> 'message';
  end if;

  v_run := public.safe_rename_run(p_category, p_entry, v_old, v_new, true);
  v_counts := coalesce((select jsonb_object_agg(x ->> 'key', (x ->> 'count')::bigint)
                          from jsonb_array_elements(v_run -> 'places') x), '{}'::jsonb);

  insert into public.settings_renames (category, entry_id, old_name, new_name, places, total, renamed_by, by_name, at)
  values (p_category, p_entry, v_old, v_new, v_counts, (v_run ->> 'total')::integer, auth.uid(),
          (select nullif(btrim(pr.name), '') from public.profiles pr where pr.id = auth.uid()), clock_timestamp())
  returning id into v_id;

  return jsonb_build_object(
    'id', v_id, 'old_name', v_old, 'new_name', v_new, 'total', (v_run ->> 'total')::bigint, 'places', v_counts,
    'open_requests', (v_run ->> 'open_requests')::bigint, 'bookings', (v_run ->> 'bookings')::bigint);
end;
$$;

-- Changes the rename [p_rename_id] back: the latest rename of its entry, not
-- undone yet, while the entry still has the new name. Every place is changed
-- back the same way. Answers {id, old_name, new_name, total}, the names as
-- the rename had them.
create or replace function public.admin_rename_undo(p_rename_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r         public.settings_renames;
  e         public.settings_entries;
  v_problem jsonb;
  v_run     jsonb;
begin
  select * into r from public.settings_renames where id = p_rename_id for update;
  if not found then
    if not public.caller_is_admin() then
      raise exception 'not_authorized' using errcode = '42501';
    end if;
    raise exception 'RENAME_NOT_FOUND' using errcode = 'P0002', hint = 'This rename is no longer in the history.';
  end if;
  if not public.safe_rename_allowed(r.category) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if r.undone_at is not null then
    raise exception 'RENAME_ALREADY_UNDONE' using errcode = '55000', hint = 'This rename was changed back already.';
  end if;
  if exists (select 1 from public.settings_renames o
              where o.entry_id = r.entry_id and o.id <> r.id and (o.at, o.id) > (r.at, r.id)) then
    raise exception 'RENAME_NOT_LATEST' using errcode = '55000', hint = 'Only the latest rename can be undone.';
  end if;
  select * into e from public.settings_entries where id = r.entry_id and category = r.category for update;
  if not found then
    raise exception 'RENAME_NOT_FOUND' using errcode = 'P0002', hint = 'This entry is no longer there.';
  end if;
  if btrim(coalesce(e.values ->> 'name', '')) <> r.new_name then
    raise exception 'RENAME_CHANGED_SINCE' using errcode = '55000',
      hint = format('The name is %s now, not %s, so it can''t be changed back.',
                    btrim(coalesce(e.values ->> 'name', '')), r.new_name);
  end if;
  v_problem := public.safe_rename_problem(r.category, r.entry_id, r.new_name, r.old_name);
  if v_problem is not null then
    raise exception '%', v_problem ->> 'code' using errcode = '23505', hint = v_problem ->> 'message';
  end if;

  v_run := public.safe_rename_run(r.category, r.entry_id, r.new_name, r.old_name, true);
  update public.settings_renames set undone_at = clock_timestamp(), undone_by = auth.uid() where id = r.id;
  return jsonb_build_object('id', r.id, 'old_name', r.old_name, 'new_name', r.new_name,
                            'total', (v_run ->> 'total')::bigint);
end;
$$;

revoke execute on function public.admin_rename_preview(text, uuid, text), public.admin_rename_apply(text, uuid, text),
  public.admin_rename_undo(uuid) from public, anon;
grant execute on function public.admin_rename_preview(text, uuid, text), public.admin_rename_apply(text, uuid, text),
  public.admin_rename_undo(uuid) to authenticated, service_role;

-- ---- 6. Renames go through the RPCs ------------------------------------------------------------------
-- A Vehicle Service's or Partner Service type's name changed straight from
-- the apps is refused: it would cut off every place that uses it. The RPCs
-- set app.safe_rename for their own change; the server and migrations
-- (no claims, the service role) and an entry with no name yet pass.
create or replace function public.settings_entries_rename_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.category not in ('vehicle-services', 'partner-type')
     or btrim(coalesce(old.values ->> 'name', '')) = ''
     or (new.category = old.category
         and btrim(coalesce(new.values ->> 'name', '')) = btrim(coalesce(old.values ->> 'name', ''))) then
    return new;
  end if;
  if coalesce(current_setting('app.safe_rename', true), '') = 'on'
     or coalesce(nullif(current_setting('request.jwt.claims', true), ''), '') = ''
     or coalesce(auth.jwt() ->> 'role', '') not in ('authenticated', 'anon') then
    return new;
  end if;
  raise exception 'RENAME_THROUGH_PREVIEW' using errcode = '42501',
    hint = 'Renaming changes every place that uses the name. Save it from the edit sheet ("Save and update"), '
           'in an up-to-date admin app.';
end;
$$;
revoke execute on function public.settings_entries_rename_guard() from public, anon, authenticated;
drop trigger if exists trg_settings_entries_rename_guard on public.settings_entries;
create trigger trg_settings_entries_rename_guard
  before update of values, category on public.settings_entries
  for each row execute function public.settings_entries_rename_guard();

notify pgrst, 'reload schema';
