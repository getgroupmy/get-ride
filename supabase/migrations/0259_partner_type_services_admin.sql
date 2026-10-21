-- ============================================================================
-- 0259: Partner type services -- the admin page's writes
--
-- public.partner_type_services says, per partner type, which ride services
-- (ride_requests.service, the Vehicle Services names) its partners see in
-- open requests. It went to the live project outside the repo (version
-- 20261021031514, partner_type_allowed_services, recorded by 0257). This
-- migration gives it its admin page (Admin -> Services & catalogue ->
-- Partner type services):
--
--   * Writes follow the repo rule: caller_admin_can_write('partner_type_services'),
--     an EDIT grant on the new page (admin-settings-partner-type-services)
--     or on Partner Type (admin-settings-partner-type), and full admins.
--     The live "pts admin write" policy (any admin, read grants too) goes.
--     Every admin and partner still reads the rules ("pts read").
--   * updated_at and updated_by are the server's on every change.
--   * The table is in the realtime publication, so the page and the apps
--     follow a change at once.
--
-- The rule (unchanged from live):
--   * A row: all_services, or the service is in services (compared as
--     ptr_key: no case, spaces, _ or -). No row: every service.
--   * A partner sees an open request when any of their types allows its
--     service (partner_types, else partner_type; none: every service).
--   * The rider, the partner on it, admins and the stand's operators always
--     see it.
--
-- The table, the two functions, the ride_requests policy and the seed rows
-- are repeated here as they are live (create if not exists / create or
-- replace / on conflict do nothing), so a replay works with or without 0257.
-- ============================================================================

-- ---- 1. The table (as live) ---------------------------------------------------------------------
create table if not exists public.partner_type_services (
  type_key     text primary key,
  type_name    text not null,
  all_services boolean not null default true,
  services     text[] not null default '{}',
  note         text,
  updated_at   timestamptz not null default now(),
  updated_by   uuid default auth.uid()
);
comment on table public.partner_type_services is
  'Per partner type (type_key = ptr_key of its name): the ride services its partners see in open requests. No row: every service (0257, 0259).';

-- A key the rule can find (ptr_key form) and sizes the page keeps to.
alter table public.partner_type_services drop constraint if exists partner_type_services_key;
alter table public.partner_type_services add constraint partner_type_services_key
  check (type_key <> '' and type_key = public.ptr_key(type_key));
alter table public.partner_type_services drop constraint if exists partner_type_services_sizes;
alter table public.partner_type_services add constraint partner_type_services_sizes
  check (char_length(btrim(type_name)) between 1 and 80
         and coalesce(char_length(note), 0) <= 500
         and coalesce(cardinality(services), 0) <= 200);

-- ---- 2. Who reads and writes --------------------------------------------------------------------
insert into public.admin_table_pages (target, page) values
  ('partner_type_services', 'admin-settings-partner-type-services'),
  ('partner_type_services', 'admin-settings-partner-type')
on conflict do nothing;

alter table public.partner_type_services enable row level security;
revoke all on public.partner_type_services from anon;
grant select, insert, update, delete on public.partner_type_services to authenticated;

drop policy if exists "pts read" on public.partner_type_services;
create policy "pts read" on public.partner_type_services for select to authenticated using (true);

drop policy if exists "pts admin write" on public.partner_type_services;
drop policy if exists "partner_type_services admin insert" on public.partner_type_services;
create policy "partner_type_services admin insert" on public.partner_type_services for insert to authenticated
  with check ((select public.caller_admin_can_write('partner_type_services')));
drop policy if exists "partner_type_services admin update" on public.partner_type_services;
create policy "partner_type_services admin update" on public.partner_type_services for update to authenticated
  using ((select public.caller_admin_can_write('partner_type_services')))
  with check ((select public.caller_admin_can_write('partner_type_services')));
drop policy if exists "partner_type_services admin delete" on public.partner_type_services;
create policy "partner_type_services admin delete" on public.partner_type_services for delete to authenticated
  using ((select public.caller_admin_can_write('partner_type_services')));

-- The editor's stamps.
create or replace function public.partner_type_services_touch()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;
revoke execute on function public.partner_type_services_touch() from public, anon, authenticated;
drop trigger if exists trg_partner_type_services_touch on public.partner_type_services;
create trigger trg_partner_type_services_touch before update on public.partner_type_services
  for each row execute function public.partner_type_services_touch();

-- ---- 3. The rule (as live) -----------------------------------------------------------------------
-- Whether partners of type p_type see p_service: the type's row, else true.
create or replace function public.partner_type_allows_service(p_type text, p_service text)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select coalesce((select s.all_services
                          or exists (select 1 from unnest(s.services) x
                                      where public.ptr_key(x) = public.ptr_key(p_service))
                     from public.partner_type_services s
                    where s.type_key = public.ptr_key(p_type)), true);
$$;

-- Whether the calling partner sees p_service: any of their types allows it.
-- Not a partner, no type or no service: true.
create or replace function public.caller_partner_service_ok(p_service text)
returns boolean
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  v_types text[];
begin
  if coalesce(btrim(p_service), '') = '' then
    return true;
  end if;
  select array(select btrim(t)
                 from unnest(case when coalesce(cardinality(p.partner_types), 0) > 0
                                  then p.partner_types else array[p.partner_type] end) as t
                where coalesce(btrim(t), '') <> '')
    into v_types
    from public.partners p
   where p.auth_user_id = auth.uid()
   order by p.created_at
   limit 1;
  if coalesce(cardinality(v_types), 0) = 0 then
    return true;
  end if;
  return exists (select 1 from unnest(v_types) as t where public.partner_type_allows_service(t, p_service));
end;
$$;

revoke execute on function public.partner_type_allows_service(text, text) from public, anon;
revoke execute on function public.caller_partner_service_ok(text) from public, anon;
grant execute on function public.partner_type_allows_service(text, text),
  public.caller_partner_service_ok(text) to authenticated, service_role;

-- An open request reaches only the partners whose types allow its service.
drop policy if exists "ride_requests partner type services" on public.ride_requests;
create policy "ride_requests partner type services" on public.ride_requests as restrictive for select to authenticated
  using (status <> 'open'
         or rider_id = (select auth.uid()) or partner_id = (select auth.uid())
         or (select public.caller_is_admin())
         or (stand_id is not null and array[stand_id] <@ (select public.dispatch_caller_stand_ids()))
         or public.caller_partner_service_ok(service));

-- ---- 4. Seed (as live) ---------------------------------------------------------------------------
insert into public.partner_type_services (type_key, type_name, all_services, services, note) values
  ('ehailing',        'eHailing',         false, array['Ride', 'Comfort', '6-seater', 'Premium'], 'Passenger e-hailing (eVP)'),
  ('teksi',           'Teksi',            false, array['Teksi', 'Ride', 'Comfort', '6-seater'],   'Licensed taxi: meter + standard rides'),
  ('phailing',        'pHailing',         false, array['Delivery', 'Food', 'Mart'],               'p-hailing = goods/food delivery, no passengers'),
  ('delivery',        'Delivery',         false, array['Delivery', 'Food', 'Mart'],               'Parcel, food & mart only'),
  ('dealer',          'Dealer',           true,  '{}',                                            'Unrestricted'),
  ('fleet',           'Fleet',            true,  '{}',                                            'Unrestricted'),
  ('serviceprovider', 'Service Provider', true,  '{}',                                            'Unrestricted')
on conflict do nothing;

-- ---- 5. Live --------------------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public'
                    and tablename = 'partner_type_services') then
    alter publication supabase_realtime add table public.partner_type_services;
  end if;
end $$;

notify pgrst, 'reload schema';
