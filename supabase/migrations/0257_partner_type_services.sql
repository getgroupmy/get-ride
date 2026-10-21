-- 0257 Partner type services: which ride services each partner type sees in open requests.
-- Applied live as version 20261021031514 (partner_type_allowed_services) before it was in
-- the repo; this file records it. The one difference: admin writes go through
-- caller_admin_can_write (the repo rule) where the live copy used caller_is_admin; 0259
-- brings live in line. Safe to run again.

create table if not exists public.partner_type_services (
  type_key text primary key,
  type_name text not null,
  all_services boolean not null default true,
  services text[] not null default '{}',
  note text,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
comment on table public.partner_type_services is 'Which vehicle services (ride_requests.service) each partner type may receive. all_services=true or no row = unrestricted. A partner with several types gets the union.';

alter table public.partner_type_services enable row level security;
drop policy if exists "pts read" on public.partner_type_services;
create policy "pts read" on public.partner_type_services for select to authenticated using (true);
drop policy if exists "pts admin write" on public.partner_type_services;
create policy "pts admin write" on public.partner_type_services for all to authenticated
  using ((select public.caller_admin_can_write('partner_type_services')))
  with check ((select public.caller_admin_can_write('partner_type_services')));

create or replace function public.partner_type_allows_service(p_type text, p_service text)
returns boolean language sql stable security definer set search_path to '' as $$
  select coalesce((
    select s.all_services
        or exists (select 1 from unnest(s.services) x where public.ptr_key(x) = public.ptr_key(p_service))
      from public.partner_type_services s
     where s.type_key = public.ptr_key(p_type)), true);
$$;

create or replace function public.caller_partner_service_ok(p_service text)
returns boolean language plpgsql stable security definer set search_path to '' as $$
declare
  v_types text[];
  t text;
begin
  if nullif(btrim(coalesce(p_service, '')), '') is null then
    return true;
  end if;
  select array(select btrim(x) from unnest(
           case when coalesce(cardinality(p.partner_types), 0) > 0 then p.partner_types
                else array[p.partner_type] end) x
         where btrim(coalesce(x, '')) <> '')
    into v_types
    from public.partners p where p.auth_user_id = auth.uid()
   order by p.created_at limit 1;
  if v_types is null or cardinality(v_types) = 0 then
    return true;
  end if;
  foreach t in array v_types loop
    if public.partner_type_allows_service(t, p_service) then
      return true;
    end if;
  end loop;
  return false;
end;
$$;

drop policy if exists "ride_requests partner type services" on public.ride_requests;
create policy "ride_requests partner type services" on public.ride_requests
  as restrictive for select to authenticated
  using (
    status <> 'open'
    or rider_id = (select auth.uid())
    or partner_id = (select auth.uid())
    or (select public.caller_is_admin())
    or (stand_id is not null and array[stand_id] <@ (select public.dispatch_caller_stand_ids()))
    or public.caller_partner_service_ok(service)
  );

insert into public.partner_type_services (type_key, type_name, all_services, services, note) values
  ('ehailing', 'eHailing', false, array['Ride','Comfort','6-seater','Premium'], 'Passenger e-hailing (eVP)'),
  ('teksi',    'Teksi',    false, array['Teksi','Ride','Comfort','6-seater'], 'Licensed taxi: meter + standard rides'),
  ('phailing', 'pHailing', false, array['Delivery','Food','Mart'], 'p-hailing = goods/food delivery, no passengers'),
  ('delivery', 'Delivery', false, array['Delivery','Food','Mart'], 'Parcel, food & mart only'),
  ('dealer', 'Dealer', true, '{}', 'Unrestricted'),
  ('fleet', 'Fleet', true, '{}', 'Unrestricted'),
  ('serviceprovider', 'Service Provider', true, '{}', 'Unrestricted')
on conflict (type_key) do nothing;
