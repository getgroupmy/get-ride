-- ============================================================================
-- 0419: skip far-away areas before the outline check
--
-- area_at (0266) runs on every ride request -- twice, for the pickup and the
-- drop -- and parsed and ray-cast the outline of EVERY active airport/place
-- area (515 on the live project) for each point. Timed on the live project
-- that was ~110 ms of a ~190 ms booking insert. place_in_airport (0264) does
-- the same over every airport.
--
--   * airport_areas gets a stored lat/lng box (min_lat, max_lat, min_lng,
--     max_lng), kept up to date by a trigger from the same outline the check
--     reads (shape for a place, values->'boundary' for an airport);
--   * area_at and place_in_airport skip a row whose box does not hold the
--     point, then run the unchanged outline check on what is left.
--
-- The box always contains the outline, so the same areas match as before. A
-- row with no box (no outline, or one that straddles the 180th meridian)
-- is never skipped -- it gets the full check, as before.
-- ============================================================================

alter table public.airport_areas add column if not exists min_lat float8;
alter table public.airport_areas add column if not exists max_lat float8;
alter table public.airport_areas add column if not exists min_lng float8;
alter table public.airport_areas add column if not exists max_lng float8;

-- The box round every ring of an outline, as {min_lat,max_lat,min_lng,max_lng},
-- or NULL when there is no usable ring or it straddles the 180th meridian.
create or replace function public.airport_rings_bbox(p_rings jsonb)
returns float8[]
language plpgsql
immutable
set search_path = public
as $$
declare
  v float8[];
begin
  if jsonb_typeof(p_rings) is distinct from 'array' or jsonb_array_length(p_rings) = 0 then
    return null;
  end if;
  select array[min(lat), max(lat), min(lng), max(lng)]
    into v
    from (select (pt->>'latitude')::float8 as lat, (pt->>'longitude')::float8 as lng
            from jsonb_array_elements(p_rings) r, jsonb_array_elements(r) pt) p;
  if v[1] is null or v[3] is null or v[4] - v[3] > 180 then
    return null;
  end if;
  return v;
exception when others then
  return null;
end;
$$;

revoke execute on function public.airport_rings_bbox(jsonb) from public, anon;
grant execute on function public.airport_rings_bbox(jsonb) to authenticated, service_role;

create or replace function public.airport_areas_set_bbox()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  b float8[] := public.airport_rings_bbox(
    public.airport_rings(case when new.kind = 'place' then new.shape else new.values->'boundary' end));
begin
  new.min_lat := b[1];
  new.max_lat := b[2];
  new.min_lng := b[3];
  new.max_lng := b[4];
  return new;
end;
$$;

revoke execute on function public.airport_areas_set_bbox() from public, anon, authenticated;

-- "zz" so it runs after the kind guard, which can reset kind and shape.
drop trigger if exists trg_airport_areas_zz_bbox on public.airport_areas;
create trigger trg_airport_areas_zz_bbox
  before insert or update on public.airport_areas
  for each row execute function public.airport_areas_set_bbox();

-- Fill the box on the rows already there, without touching anything else
-- (no updated_at bump, no guard): a direct write of the four columns only.
alter table public.airport_areas disable trigger user;
update public.airport_areas a
   set min_lat = b[1], max_lat = b[2], min_lng = b[3], max_lng = b[4]
  from (select id, public.airport_rings_bbox(
                 public.airport_rings(case when kind = 'place' then shape else values->'boundary' end)) as b
          from public.airport_areas) x
 where x.id = a.id;
alter table public.airport_areas enable trigger user;

-- Same as 0266, plus the box test ahead of the outline check.
create or replace function public.area_at(p_lat float8, p_lng float8)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  with holding as (
    select a.id, a.kind, a.size_m2, a.position, a.created_at,
           public.area_part_of_key(case when a.kind = 'place' then g.values->>'partOf' else a.values->>'partOf' end) as part_of
      from public.airport_areas a
      left join public.multi_gate g on a.kind = 'place' and g.id = a.place_id
     where a.active and p_lat is not null and p_lng is not null
       and (a.min_lat is null
            or (p_lat between a.min_lat and a.max_lat and p_lng between a.min_lng and a.max_lng))
       and public.airport_in_rings(p_lat, p_lng,
             public.airport_rings(case when a.kind = 'place' then a.shape else a.values->'boundary' end))
  ),
  place as (
    select * from holding where kind = 'place'
     order by coalesce(size_m2, 'infinity'::float8), position, created_at
     limit 1
  ),
  airport as (
    select * from holding where kind = 'airport'
     order by position, created_at
     limit 1
  )
  select case
           when p.id is null then a.id
           when a.id is null then p.id
           when m.mode = 'airport' then a.id
           when m.mode = 'place' then p.id
           when p.part_of <> '' and p.part_of = a.part_of then a.id
           else p.id
         end
    from (select coalesce((select mode from public.area_precedence_settings where id = 1), 'part_of') as mode) m
    left join place p on true
    left join airport a on true;
$$;
revoke execute on function public.area_at(float8, float8) from public, anon;
grant execute on function public.area_at(float8, float8) to authenticated, service_role;

-- Same as 0264, plus the box test.
create or replace function public.place_in_airport(p_lat float8, p_lng float8)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_lat is not null and p_lng is not null and exists (
    select 1 from public.airport_areas a
     where a.kind = 'airport' and a.active
       and (a.min_lat is null
            or (p_lat between a.min_lat and a.max_lat and p_lng between a.min_lng and a.max_lng))
       and public.airport_in_rings(p_lat, p_lng, public.airport_rings(a.values->'boundary')));
$$;

notify pgrst, 'reload schema';
