-- ============================================================================
-- 0425: look a point's place up once per request
--
-- ptr_point_place (0421) names the country / state / city / suburb holding a
-- point -- ~5 ms, most of it testing the large outlines (Malaysia, Selangor,
-- Kuala Lumpur) that do hold it. Callers ask for the same point again and
-- again within one request: mygig_config reaches it 8 times through
-- mygig_place -> ride_option_place (42 of its 53 ms, measured live).
--
-- Now ptr_point_place remembers its answer for the rest of the transaction
-- (one API request is one transaction) in a transaction-local setting keyed
-- by the exact point. Nothing outlives the transaction. A write to any region
-- table in the same transaction moves a revision that is part of the key, so
-- a lookup after an outline or name change is worked out afresh. Same
-- answers; repeated lookups cost almost nothing.
-- ============================================================================

-- The region revision of this transaction: moves on every write to a region
-- table (statement trigger below), so remembered lookups made before it are
-- not used after it.
create or replace function public.region_lookup_rev()
returns text
language sql
stable
set search_path to ''
as $$
  select coalesce(nullif(pg_catalog.current_setting('getride_ptr.rev', true), ''), '0');
$$;

create or replace function public.regions_bump_lookup_rev()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  perform pg_catalog.set_config('getride_ptr.rev', (public.region_lookup_rev()::bigint + 1)::text, true);
  return null;
end;
$$;

revoke all on function public.region_lookup_rev() from public;
grant execute on function public.region_lookup_rev() to authenticated, service_role;
revoke all on function public.regions_bump_lookup_rev() from public, anon, authenticated;

do $$
declare t text;
begin
  foreach t in array array['countries', 'states', 'cities', 'suburbs'] loop
    execute format('drop trigger if exists trg_%1$s_lookup_rev on public.%1$I', t);
    execute format('create trigger trg_%1$s_lookup_rev after insert or update or delete or truncate on public.%1$I
                      for each statement execute function public.regions_bump_lookup_rev()', t);
  end loop;
end $$;

-- 0421's ptr_point_place, remembering its answer for the transaction.
create or replace function public.ptr_point_place(p_lat double precision, p_lng double precision)
returns table (country text, state text, city text, suburb text)
language plpgsql
stable
security definer
set search_path to ''
as $$
declare
  pt point;
  v_country text := '';
  v_state text := '';
  v_city text := '';
  v_suburb text := '';
  v_key text;
  v_hit text;
  v_parts text[];
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return query select '', '', '', '';
    return;
  end if;
  -- The exact point and this transaction's region revision, spelt as a setting
  -- name ('.', '-' and '+' are not allowed in one).
  v_key := 'getride_ptr.k' || translate(p_lat::text || '_' || p_lng::text || '_' || public.region_lookup_rev(),
                                        '.-+', 'dmp');
  v_hit := pg_catalog.current_setting(v_key, true);
  if coalesce(v_hit, '') <> '' then
    v_parts := string_to_array(v_hit, chr(31));
    return query select v_parts[1], v_parts[2], v_parts[3], v_parts[4];
    return;
  end if;
  pt := point(p_lng, p_lat);
  select c.name into v_country from public.countries c
   where coalesce(cardinality(c.boundary_polys), 0) > 0
     and (c.boundary_box is null or c.boundary_box @> pt)
     and public.region_holding_area(c.boundary_polys, pt) is not null
   order by public.region_holding_area(c.boundary_polys, pt) limit 1;
  if coalesce(v_country, '') <> '' then
    select s.name into v_state from public.states s
     where public.ptr_name(s.country) = public.ptr_name(v_country)
       and coalesce(cardinality(s.boundary_polys), 0) > 0
       and (s.boundary_box is null or s.boundary_box @> pt)
       and public.region_holding_area(s.boundary_polys, pt) is not null
     order by public.region_holding_area(s.boundary_polys, pt) limit 1;
  end if;
  if coalesce(v_state, '') <> '' then
    select c.name into v_city from public.cities c
     where public.ptr_name(c.country) = public.ptr_name(v_country)
       and public.ptr_name(c.state) = public.ptr_name(v_state)
       and coalesce(cardinality(c.boundary_polys), 0) > 0
       and (c.boundary_box is null or c.boundary_box @> pt)
       and public.region_holding_area(c.boundary_polys, pt) is not null
     order by public.region_holding_area(c.boundary_polys, pt) limit 1;
  end if;
  if coalesce(v_city, '') <> '' then
    select b.name into v_suburb from public.suburbs b
     where public.ptr_name(b.country) = public.ptr_name(v_country)
       and public.ptr_name(b.state) = public.ptr_name(v_state)
       and public.ptr_name(b.city) = public.ptr_name(v_city)
       and coalesce(cardinality(b.boundary_polys), 0) > 0
       and (b.boundary_box is null or b.boundary_box @> pt)
       and public.region_holding_area(b.boundary_polys, pt) is not null
     order by public.region_holding_area(b.boundary_polys, pt) limit 1;
  end if;
  v_country := coalesce(v_country, ''); v_state := coalesce(v_state, '');
  v_city := coalesce(v_city, ''); v_suburb := coalesce(v_suburb, '');
  -- Remembered for this transaction only. A trailing marker keeps an
  -- all-blank answer from reading as "not remembered".
  perform pg_catalog.set_config(v_key,
    v_country || chr(31) || v_state || chr(31) || v_city || chr(31) || v_suburb || chr(31) || '1', true);
  return query select v_country, v_state, v_city, v_suburb;
end;
$$;

revoke all on function public.ptr_point_place(double precision, double precision) from public, anon;
grant execute on function public.ptr_point_place(double precision, double precision) to authenticated, service_role;
