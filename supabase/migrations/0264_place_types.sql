-- ============================================================================
-- 0264 — Place types with icons.
--
-- Every Multi-Gate place has a type (Mall, Airport, Train / LRT / MRT,
-- Hospital, ...), each with an icon and a colour, shown next to the place in
-- the rider's search results, saved places and on the map, and to the driver
-- next to a pickup or drop-off at a place.
--
-- 1. public.place_types: key (a Google Places (New) "Table A" type name:
--    shopping_mall, airport, train_station, ...), a friendly name, icon (a
--    Material icon name from the app's curated set: Google's open-source
--    glyphs, drawn by the app, never Google's marker images), the chip
--    colour for light and dark (Google Maps' category colours to start),
--    sort order and active. Everyone signed in reads it; writes are
--    caller_admin_can_write('place_types'): an EDIT grant on Admin > Place
--    types (admin-settings-place-types) or on Multi-Gate Places.
--    point_of_interest ("Other") is the fallback and stays (it can't be
--    removed or switched off).
-- 2. A place keeps its type in multi_gate.values: placeType (the key) and
--    placeTypeSet (true once the admin chose it; false while it is the
--    guess). place_type_guess() guesses from Google's main type
--    (values.primaryType, from a Google Places search), then the
--    OpenStreetMap type (values.osmType), then the name; the app's
--    lib/src/core/place_types.dart does the same. A place inside an
--    airport's boundary is an airport.
-- 3. A trigger keeps every place typed: a save without placeType (an older
--    app writes the whole values) keeps the type it had, or guesses one; an
--    unknown key becomes the guess. The existing places are typed here
--    (backfill); one the admin already set keeps it.
-- 4. A type in use is not removed: delete raises PLACE_TYPE_IN_USE.
--    place_type_remove(key, move_to) moves its places to another type
--    (point_of_interest, Other, by default) and removes it.
-- 5. Rides: ride_requests.pickup_place_type / drop_place_type, stamped by
--    the server in the ride trigger (0258's ride_requests_airport): the
--    airport or place area the end is in, else the place of the door, else
--    the place the point is at (a gate within 80 m or the place within
--    150 m). Clients can't set them.
-- ============================================================================

-- ---- 1. The types ---------------------------------------------------------------------------------
create table if not exists public.place_types (
  key        text primary key,
  name       text not null,
  icon       text not null default 'place',
  color      text not null default '#7b9eb0',
  color_dark text not null default '#7b9eb0',
  sort_order integer not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
comment on table public.place_types is
  'Multi-Gate place types: icon and colours shown to riders and drivers; multi_gate.values.placeType holds the key (0264).';

alter table public.place_types drop constraint if exists place_types_shape;
alter table public.place_types add constraint place_types_shape check (
  key ~ '^[a-z][a-z0-9_]{0,39}$'
  and char_length(btrim(name)) between 1 and 60
  and icon ~ '^[a-z0-9_]{1,60}$'
  and color ~ '^#[0-9A-Fa-f]{6}$'
  and color_dark ~ '^#[0-9A-Fa-f]{6}$'
  and sort_order between -100000 and 100000
  and (key <> 'point_of_interest' or active));

create index if not exists place_types_sort_idx on public.place_types (sort_order, name);

-- Google Maps' category colours: shopping #4b96f3, transport #10bdff,
-- health #f88181, lodging #e94e4e, civic #7b9eb0, parks #4db546,
-- attractions #13b5c7.
insert into public.place_types (key, name, icon, color, color_dark, sort_order) values
  ('shopping_mall',           'Mall',                      'local_mall',      '#4b96f3', '#4b96f3', 10),
  ('airport',                 'Airport',                   'flight',          '#10bdff', '#10bdff', 20),
  ('train_station',           'Train station',             'train',           '#10bdff', '#10bdff', 30),
  ('subway_station',          'MRT / LRT station',         'subway',          '#10bdff', '#10bdff', 40),
  ('bus_station',             'Bus terminal',              'directions_bus',  '#10bdff', '#10bdff', 50),
  ('ferry_terminal',          'Ferry terminal',            'directions_boat', '#10bdff', '#10bdff', 60),
  ('hospital',                'Hospital',                  'local_hospital',  '#f88181', '#f88181', 70),
  ('lodging',                 'Hotel',                     'hotel',           '#e94e4e', '#e94e4e', 80),
  ('university',              'University / School',       'school',          '#7b9eb0', '#7b9eb0', 90),
  ('corporate_office',        'Office',                    'business',        '#7b9eb0', '#7b9eb0', 100),
  ('stadium',                 'Stadium',                   'stadium',         '#13b5c7', '#13b5c7', 110),
  ('convention_center',       'Convention centre',         'groups',          '#13b5c7', '#13b5c7', 120),
  ('mosque',                  'Mosque / Place of worship', 'mosque',          '#7b9eb0', '#7b9eb0', 130),
  ('market',                  'Market',                    'storefront',      '#4b96f3', '#4b96f3', 140),
  ('local_government_office', 'Government office',         'account_balance', '#7b9eb0', '#7b9eb0', 150),
  ('tourist_attraction',      'Attraction',                'attractions',     '#13b5c7', '#13b5c7', 160),
  ('park',                    'Park',                      'park',            '#4db546', '#4db546', 170),
  ('point_of_interest',       'Other',                     'place',           '#7b9eb0', '#7b9eb0', 1000)
on conflict (key) do nothing;

-- ---- Who reads and writes ---------------------------------------------------------------------------
insert into public.admin_table_pages (target, page) values
  ('place_types', 'admin-settings-place-types'),
  ('place_types', 'admin-settings-multi-gate-places')
on conflict do nothing;

alter table public.place_types enable row level security;
revoke all on public.place_types from anon;
grant select, insert, update, delete on public.place_types to authenticated;

drop policy if exists "place_types read" on public.place_types;
create policy "place_types read" on public.place_types for select to authenticated using (true);
drop policy if exists "place_types admin insert" on public.place_types;
create policy "place_types admin insert" on public.place_types for insert to authenticated
  with check ((select public.caller_admin_can_write('place_types')));
drop policy if exists "place_types admin update" on public.place_types;
create policy "place_types admin update" on public.place_types for update to authenticated
  using ((select public.caller_admin_can_write('place_types')))
  with check ((select public.caller_admin_can_write('place_types')));
drop policy if exists "place_types admin delete" on public.place_types;
create policy "place_types admin delete" on public.place_types for delete to authenticated
  using ((select public.caller_admin_can_write('place_types')));

-- The key stays (places hold it); the editor's stamps; a type in use or
-- Other is not removed.
create or replace function public.place_types_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    if old.key = 'point_of_interest' then
      raise exception 'PLACE_TYPE_REQUIRED' using errcode = '42501',
        hint = 'Other is where places go when their type is removed; it stays.';
    end if;
    if exists (select 1 from public.multi_gate g
                where g.kind = 'place' and g.values->>'placeType' = old.key) then
      raise exception 'PLACE_TYPE_IN_USE' using errcode = '23503',
        hint = 'Places use this type. Move them to another type first.';
    end if;
    return old;
  end if;
  if tg_op = 'UPDATE' then
    if new.key is distinct from old.key then
      raise exception 'PLACE_TYPE_KEY_FIXED' using errcode = '22023',
        hint = 'A type''s key does not change; add a new type instead.';
    end if;
    new.created_at := old.created_at;
  end if;
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;
revoke execute on function public.place_types_guard() from public, anon, authenticated;
drop trigger if exists trg_place_types_guard on public.place_types;
create trigger trg_place_types_guard before insert or update or delete on public.place_types
  for each row execute function public.place_types_guard();

-- ---- 2. The guess ------------------------------------------------------------------------------------
-- (Earlier drafts of these took two arguments.)
drop function if exists public.place_type_pick(text, text);
drop function if exists public.place_type_guess(text, text);

-- The name rules, in order: the first that matches wins. The name is
-- lower-cased with everything but letters and digits made spaces, and
-- padded with a space: ' klia' is a word starting with klia, ' mrt ' the
-- word mrt, 'mall' mall anywhere (Megamall). lib/src/core/place_types.dart
-- has the same rules.
create or replace function public.place_type_name_rules()
returns table (key text, pat text)
language sql
immutable
set search_path = public
as $$
  select r.key, p.pat
    from (values
      (1,  'airport',                 array[' klia', ' airport', ' lapangan terbang', ' aerodrome', ' lcct ']),
      (2,  'ferry_terminal',          array[' ferry', ' feri ', ' jetty', ' jeti ']),
      (3,  'bus_station',             array[' bus ', ' bas ', ' tbs ', ' terminal bersepadu', ' hentian ', ' puduraya']),
      (4,  'subway_station',          array[' mrt ', ' lrt ', ' monorail']),
      (5,  'train_station',           array[' sentral', ' ktm ', ' station', ' stesen ', ' erl ', ' ets ']),
      (6,  'hospital',                array[' hospital', ' medical', ' clinic', ' klinik', ' perubatan']),
      (7,  'university',              array[' university', ' universiti', ' college', ' school', ' kolej', ' sekolah',
                                            ' politeknik', ' campus', ' kampus']),
      (8,  'mosque',                  array[' masjid', ' mosque', ' temple', ' church', ' kuil', ' surau', ' gereja',
                                            ' tokong', ' gurdwara']),
      (9,  'market',                  array[' pasar', ' market']),
      (10, 'local_government_office', array[' jabatan', ' kementerian', ' majlis', ' dewan bandaraya', ' dbkl ', ' jpj ',
                                            ' imigresen', ' immigration', ' government', ' city hall', ' mahkamah',
                                            ' balai polis', ' police']),
      (11, 'lodging',                 array[' hotel', ' resort', ' hostel', ' inn ']),
      (12, 'stadium',                 array[' stadium', ' arena']),
      (13, 'convention_center',       array[' convention', ' exhibition', ' auditorium', ' expo ']),
      (14, 'tourist_attraction',      array[' museum', ' muzium', ' zoo ', ' aquarium', ' aquaria', ' theme park']),
      (15, 'park',                    array[' park ', ' tasik ', ' gardens', ' botanical']),
      (16, 'corporate_office',        array[' tower', ' menara', ' office', ' wisma ']),
      (17, 'shopping_mall',           array['mall', ' plaza', ' centre', ' center', ' square', ' shopping', ' galleria',
                                            ' klcc ', ' aeon '])
    ) as r(n, key, pats)
    cross join lateral unnest(r.pats) with ordinality as p(pat, i)
   order by r.n, p.i;
$$;

-- The type a place's Google main type (p_google: Places (New) primaryType),
-- OpenStreetMap type (p_osm) and name suggest, in that order, else
-- point_of_interest (Other).
create or replace function public.place_type_guess(p_name text, p_osm text default null, p_google text default null)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  s text := ' ' || btrim(regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', ' ', 'g')) || ' ';
  o text := lower(btrim(coalesce(p_osm, '')));
  g text := lower(btrim(coalesce(p_google, '')));
  r record;
begin
  -- Google's main type: one of the starting types, or a type that means one.
  if g <> '' then
    case
      when g in ('shopping_mall', 'airport', 'train_station', 'subway_station', 'bus_station', 'ferry_terminal',
                 'hospital', 'lodging', 'university', 'corporate_office', 'stadium', 'convention_center', 'mosque',
                 'market', 'local_government_office', 'tourist_attraction', 'park') then return g;
      when g in ('international_airport', 'airstrip') then return 'airport';
      when g = 'light_rail_station' then return 'subway_station';
      when g = 'transit_station' then return 'train_station';
      when g in ('bus_stop', 'transit_depot') then return 'bus_station';
      when g in ('department_store', 'outlet_mall') then return 'shopping_mall';
      when g in ('hotel', 'resort_hotel', 'motel', 'hostel', 'guest_house', 'bed_and_breakfast', 'inn') then return 'lodging';
      when g in ('school', 'primary_school', 'secondary_school') then return 'university';
      when g in ('doctor', 'medical_lab') then return 'hospital';
      when g = 'business_center' then return 'corporate_office';
      when g in ('arena', 'sports_complex') then return 'stadium';
      when g = 'event_venue' then return 'convention_center';
      when g in ('place_of_worship', 'church', 'hindu_temple', 'buddhist_temple', 'synagogue') then return 'mosque';
      when g in ('city_hall', 'courthouse', 'police', 'embassy', 'post_office') then return 'local_government_office';
      when g in ('museum', 'amusement_park', 'zoo', 'aquarium', 'art_gallery', 'historical_landmark') then
        return 'tourist_attraction';
      when g in ('national_park', 'botanical_garden', 'garden') then return 'park';
      else null;
    end case;
  end if;
  -- Then OpenStreetMap's own type.
  if o <> '' then
    case
      when o in ('aerodrome', 'airport', 'terminal', 'apron') then return 'airport';
      when o in ('ferry_terminal', 'pier', 'harbour', 'jetty') then return 'ferry_terminal';
      when o in ('bus_station', 'bus_stop') then return 'bus_station';
      when o in ('subway_entrance', 'subway', 'light_rail', 'monorail', 'tram_stop') then return 'subway_station';
      when o in ('station', 'halt', 'train_station', 'railway') then return 'train_station';
      when o in ('hospital', 'clinic', 'doctors') then return 'hospital';
      when o in ('university', 'college', 'school', 'kindergarten') then return 'university';
      when o in ('place_of_worship', 'mosque', 'temple', 'church', 'shrine') then return 'mosque';
      when o in ('marketplace', 'market') then return 'market';
      when o in ('townhall', 'government', 'courthouse', 'police', 'embassy', 'public_building',
                 'post_office') then return 'local_government_office';
      when o in ('hotel', 'motel', 'resort', 'guest_house', 'hostel') then return 'lodging';
      when o in ('stadium', 'sports_centre', 'arena') then return 'stadium';
      when o in ('events_venue', 'conference_centre', 'exhibition_centre') then return 'convention_center';
      when o in ('attraction', 'museum', 'zoo', 'theme_park', 'aquarium', 'theatre', 'viewpoint') then
        return 'tourist_attraction';
      when o in ('park', 'garden', 'nature_reserve') then return 'park';
      when o in ('office', 'commercial') then return 'corporate_office';
      when o in ('mall', 'department_store', 'shopping_centre') then return 'shopping_mall';
      else null;
    end case;
  end if;
  -- Then the name.
  for r in select * from public.place_type_name_rules() loop
    if strpos(s, r.pat) > 0 then
      return r.key;
    end if;
  end loop;
  return 'point_of_interest';
end;
$$;

-- The guess as a key that exists and is on, else point_of_interest. A
-- Google main type the admin added as a type of its own is taken as it is.
create or replace function public.place_type_pick(p_name text, p_osm text default null, p_google text default null)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select t.key from public.place_types t
      where t.key = lower(btrim(coalesce(p_google, ''))) and t.key <> 'point_of_interest' and t.active),
    (select t.key from public.place_types t
      where t.key = public.place_type_guess(p_name, p_osm, p_google) and t.active),
    'point_of_interest');
$$;

-- Whether a point is inside an airport's boundary (Airport Areas).
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
       and public.airport_in_rings(p_lat, p_lng, public.airport_rings(a.values->'boundary')));
$$;

-- A place's guess: an airport when it is inside one, else from Google's
-- main type, its OpenStreetMap type and its name.
create or replace function public.place_type_for(p_values jsonb)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_lat float8;
  v_lng float8;
begin
  if p_values->>'lat' ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$' and p_values->>'lon' ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$' then
    v_lat := btrim(p_values->>'lat')::float8;
    v_lng := btrim(p_values->>'lon')::float8;
    if public.place_in_airport(v_lat, v_lng) then
      return 'airport';
    end if;
  end if;
  return public.place_type_pick(p_values->>'name', p_values->>'osmType', p_values->>'primaryType');
end;
$$;

revoke execute on function public.place_type_pick(text, text, text) from public, anon;
revoke execute on function public.place_type_for(jsonb) from public, anon;
revoke execute on function public.place_in_airport(float8, float8) from public, anon;
grant execute on function public.place_type_pick(text, text, text), public.place_type_for(jsonb),
  public.place_in_airport(float8, float8) to authenticated, service_role;
grant execute on function public.place_type_guess(text, text, text), public.place_type_name_rules()
  to authenticated, service_role;

-- ---- 3. Every place has a type ------------------------------------------------------------------------
create or replace function public.multi_gate_place_type()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := nullif(btrim(coalesce(new.values->>'placeType', '')), '');
  v_set boolean := lower(coalesce(new.values->>'placeTypeSet', 'false')) in ('true', '1', 'yes', 'on');
begin
  if new.kind <> 'place' or jsonb_typeof(new.values) is distinct from 'object' then
    return new;
  end if;
  -- Saved without one (an older app writes the whole values): the type it
  -- had when the admin chose it, else the guess again (the name may have
  -- changed).
  if v_key is null and tg_op = 'UPDATE'
     and lower(coalesce(old.values->>'placeTypeSet', 'false')) in ('true', '1', 'yes', 'on')
     and nullif(btrim(coalesce(old.values->>'placeType', '')), '') is not null then
    v_key := btrim(old.values->>'placeType');
    v_set := true;
  end if;
  if v_key is not null and not exists (select 1 from public.place_types t where t.key = v_key) then
    v_key := null;
  end if;
  if v_key is null or not v_set then
    v_key := coalesce(case when v_set then v_key end, public.place_type_for(new.values));
    v_set := false;
  end if;
  new.values := new.values || jsonb_build_object('placeType', v_key, 'placeTypeSet', v_set);
  return new;
end;
$$;
revoke execute on function public.multi_gate_place_type() from public, anon, authenticated;
drop trigger if exists trg_multi_gate_place_type on public.multi_gate;
create trigger trg_multi_gate_place_type before insert or update on public.multi_gate
  for each row execute function public.multi_gate_place_type();

-- The places already added: each gets the guess; one the admin set keeps it.
update public.multi_gate g
   set values = g.values || jsonb_build_object('placeType', public.place_type_for(g.values), 'placeTypeSet', false)
 where g.kind = 'place'
   and jsonb_typeof(g.values) = 'object'
   and lower(coalesce(g.values->>'placeTypeSet', 'false')) not in ('true', '1', 'yes', 'on');

-- The rider's search and the admin page find a place by its type.
create index if not exists multi_gate_place_type_idx on public.multi_gate ((values->>'placeType'))
  where kind = 'place';

-- ---- 4. Removing a type -------------------------------------------------------------------------------
-- Moves the places of p_key to p_move_to (point_of_interest, Other, by
-- default; set by the admin) and removes p_key. Answers how many places moved.
create or replace function public.place_type_remove(p_key text, p_move_to text default 'point_of_interest')
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_to text := coalesce(nullif(btrim(p_move_to), ''), 'point_of_interest');
  v_n integer;
begin
  if not public.caller_admin_can_write('place_types') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You can''t change place types.';
  end if;
  if p_key = 'point_of_interest' then
    raise exception 'PLACE_TYPE_REQUIRED' using errcode = '42501',
      hint = 'Other is where places go when their type is removed; it stays.';
  end if;
  if not exists (select 1 from public.place_types where key = p_key) then
    raise exception 'PLACE_TYPE_NOT_FOUND' using errcode = '22023', hint = 'That type is already gone.';
  end if;
  if v_to = p_key or not exists (select 1 from public.place_types where key = v_to) then
    raise exception 'PLACE_TYPE_MOVE_TO' using errcode = '22023', hint = 'Choose another type for its places.';
  end if;
  update public.multi_gate g
     set values = g.values || jsonb_build_object('placeType', v_to, 'placeTypeSet', true)
   where g.kind = 'place' and g.values->>'placeType' = p_key;
  get diagnostics v_n = row_count;
  delete from public.place_types where key = p_key;
  return v_n;
end;
$$;
revoke execute on function public.place_type_remove(text, text) from public, anon;
grant execute on function public.place_type_remove(text, text) to authenticated, service_role;

-- ---- 5. Rides: the type of the place at each end ---------------------------------------------------
alter table public.ride_requests
  add column if not exists pickup_place_type text,
  add column if not exists drop_place_type   text;
comment on column public.ride_requests.pickup_place_type is
  'place_types.key of the airport or Multi-Gate place the pickup is at; stamped by the server (0264).';
comment on column public.ride_requests.drop_place_type is
  'place_types.key of the airport or Multi-Gate place the drop-off is at; stamped by the server (0264).';

-- The type of the place a ride's end is at: the area it is in (an airport,
-- or a place with its boundary on), else the place of its door, else the
-- place whose gate (80 m) or point (150 m) it is at. Null for none.
create or replace function public.place_type_at(p_area uuid, p_door uuid, p_lat float8, p_lng float8)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_kind text;
  v_place uuid;
  v_type text;
  kx float8;
begin
  if p_area is not null then
    select a.kind, a.place_id into v_kind, v_place from public.airport_areas a where a.id = p_area;
    if v_kind = 'airport' then
      return 'airport';
    end if;
  end if;
  if v_place is null and p_door is not null then
    select coalesce(g.values->>'parentKey', ''), (g.values->>'placeId')::uuid
      into v_kind, v_place
      from public.multi_gate g
     where g.id = p_door and g.kind = 'gate'
       and g.values->>'placeId' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
    if v_kind = 'airport-areas' then
      return 'airport';
    end if;
  end if;
  if v_place is null and p_lat is not null and p_lng is not null then
    kx := 111320 * cos(radians(p_lat));
    -- A gate of an active place, within 80 m.
    select (g.values->>'placeId')::uuid into v_place
      from public.multi_gate g
      join public.multi_gate p on p.kind = 'place' and p.active
                              and p.id::text = g.values->>'placeId'
     where g.kind = 'gate' and g.active
       and coalesce(nullif(g.values->>'parentKey', ''), 'multi-gate-places') = 'multi-gate-places'
       and g.values->>'lat' ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$' and g.values->>'lon' ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$'
       and abs(btrim(g.values->>'lat')::float8 - p_lat) < 0.002
       and abs(btrim(g.values->>'lon')::float8 - p_lng) < 0.002
       and sqrt(power((btrim(g.values->>'lat')::float8 - p_lat) * 110540, 2)
              + power((btrim(g.values->>'lon')::float8 - p_lng) * kx, 2)) <= 80
     order by power((btrim(g.values->>'lat')::float8 - p_lat) * 110540, 2)
            + power((btrim(g.values->>'lon')::float8 - p_lng) * kx, 2)
     limit 1;
    if v_place is null then
      -- The place itself, within 150 m.
      select p.id into v_place
        from public.multi_gate p
       where p.kind = 'place' and p.active
         and lower(coalesce(p.values->>'active', 'true')) not in ('false', '0', 'no', 'off')
         and p.values->>'lat' ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$' and p.values->>'lon' ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$'
         and abs(btrim(p.values->>'lat')::float8 - p_lat) < 0.003
         and abs(btrim(p.values->>'lon')::float8 - p_lng) < 0.003
         and sqrt(power((btrim(p.values->>'lat')::float8 - p_lat) * 110540, 2)
                + power((btrim(p.values->>'lon')::float8 - p_lng) * kx, 2)) <= 150
       order by power((btrim(p.values->>'lat')::float8 - p_lat) * 110540, 2)
              + power((btrim(p.values->>'lon')::float8 - p_lng) * kx, 2)
       limit 1;
    end if;
  end if;
  if v_place is null then
    return null;
  end if;
  select coalesce(nullif(btrim(g.values->>'placeType'), ''), 'point_of_interest') into v_type
    from public.multi_gate g where g.id = v_place and g.kind = 'place';
  return v_type;
end;
$$;
revoke execute on function public.place_type_at(uuid, uuid, float8, float8) from public, anon, authenticated;
grant execute on function public.place_type_at(uuid, uuid, float8, float8) to service_role;

-- ---- 6. The ride trigger: 0258's ride_requests_airport (its latest definition), now also
-- stamping the type of the place at each end. Nothing else changes.
create or replace function public.ride_requests_airport()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_client boolean := public.airport_caller_is_client();
  cp public.airport_settings;
  cd public.airport_settings;
  v_rest jsonb;
  v_charges jsonb;
  v_quote jsonb;
  v_name text;
  v_end text;
begin
  if tg_op = 'INSERT' then
    new.airport_pickup_id := public.airport_at(new.pickup_lat, new.pickup_lng);
    new.airport_drop_id := public.airport_at(new.drop_lat, new.drop_lng);
    new.airport_hold := false;
    new.airport_open_at := null;
    new.pickup_door_name := null;
    new.drop_door_name := null;
    if new.airport_pickup_id is not null then
      select * into cp from public.airport_settings where airport_id = new.airport_pickup_id;
    end if;
    if new.airport_drop_id is not null then
      select * into cd from public.airport_settings where airport_id = new.airport_drop_id;
    end if;

    -- The doors the rider chose: a door of that airport, for that side.
    if new.pickup_door_id is not null then
      new.pickup_door_name := public.airport_door_name(new.pickup_door_id, new.airport_pickup_id, 'pick');
      if new.pickup_door_name is null then
        raise exception 'AIRPORT_DOOR_INVALID' using errcode = '22023',
          hint = 'That door is not a pickup door of this airport.';
      end if;
    elsif (v_client or new.scheduled_ride_id is not null) and cp.airport_id is not null and cp.pick_door_required
          and exists (select 1 from public.airport_doors d
                       where d.airport_id = new.airport_pickup_id and d.active and d.kind in ('pick', 'both')) then
      raise exception 'AIRPORT_DOOR_REQUIRED' using errcode = '22023',
        hint = 'Choose where the driver should pick you up.';
    end if;
    if new.drop_door_id is not null then
      new.drop_door_name := public.airport_door_name(new.drop_door_id, new.airport_drop_id, 'drop');
      if new.drop_door_name is null then
        raise exception 'AIRPORT_DOOR_INVALID' using errcode = '22023',
          hint = 'That door is not a drop-off door of this airport.';
      end if;
    elsif (v_client or new.scheduled_ride_id is not null) and cd.airport_id is not null and cd.drop_door_required
          and exists (select 1 from public.airport_doors d
                       where d.airport_id = new.airport_drop_id and d.active and d.kind in ('drop', 'both')) then
      raise exception 'AIRPORT_DOOR_REQUIRED' using errcode = '22023',
        hint = 'Choose the door you are going to.';
    end if;

    -- The type of the place at each end (0264): the server's.
    new.pickup_place_type := public.place_type_at(new.airport_pickup_id, new.pickup_door_id,
                                                  new.pickup_lat, new.pickup_lng);
    new.drop_place_type := public.place_type_at(new.airport_drop_id, new.drop_door_id,
                                                new.drop_lat, new.drop_lng);

    -- The airport fare and charges are the server's: what a client sent is
    -- dropped and worked out again. (A row the server already stamped, such
    -- as a scheduled ride's, keeps its own.)
    if v_client or new.airport_fare is null then
      new.airport_fare := null;
      select coalesce(jsonb_agg(e), '[]'::jsonb) into v_rest
        from jsonb_array_elements(case when jsonb_typeof(new.charges) = 'array' then new.charges else '[]'::jsonb end) e
       where e->'airport' is null;
      v_charges := public.airport_ride_charges(new.airport_pickup_id, new.airport_drop_id);
      v_rest := v_rest || v_charges;
      new.charges := case when v_rest = '[]'::jsonb then null else v_rest end;
      -- The fare step, then the charges on top (airport_quote).
      if new.airport_pickup_id is not null or new.airport_drop_id is not null then
        -- Which end's fares (0258): an airport's before a place's, a place's
        -- own fares before one without; the pickup end first.
        v_end := public.airport_fare_end(new.airport_pickup_id, new.airport_drop_id);
        v_quote := public.airport_quote(
          case when v_end = 'from' then new.airport_pickup_id else new.airport_drop_id end,
          v_end,
          new.service, new.distance_km,
          -- The route fare: the app's fare has the option charges in it (0248).
          greatest(0, coalesce(new.ride_fare, new.fare, 0) - public.ride_option_charges_total(new.option_charges)),
          public.airport_per_km(new.service, new.country, new.state, new.city, new.suburb),
          case when v_end = 'from' then new.drop_lat else new.pickup_lat end,
          case when v_end = 'from' then new.drop_lng else new.pickup_lng end,
          v_charges, new.option_charges);
        if v_quote is not null then
          new.airport_fare := v_quote;
          new.fare := (v_quote->>'fare')::numeric;
          new.ride_fare := new.fare;
          -- A fixed airport fare isn't bid on.
          if (v_quote->>'fixed')::boolean then
            new.offer_me := false;
            new.auto_accept_fare := null;
          end if;
        end if;
      end if;
    end if;

    -- A pickup the airport keeps for its queue / zone drivers.
    if new.status = 'open' and cp.airport_id is not null and cp.restrict_pickups then
      if new.direct_driver_id is not null then
        raise exception 'AIRPORT_QUEUE_ONLY' using errcode = '42501',
          hint = 'Pickups at this airport go to the drivers waiting for them; a driver''s code can''t be used here.';
      end if;
      new.airport_hold := true;
      new.target_driver_ids := null;
      new.targeted_until := null;
      if not public.airport_has_candidates(new.airport_pickup_id, new.service, new.rider_id,
                                           new.pickup_lat, new.pickup_lng) then
        if cp.empty_action = 'decline' then
          new.status := 'expired';
          new.cancel_reason := 'AIRPORT_NO_DRIVER';
        elsif cp.empty_action = 'nearby' then
          if cp.nearby_after_min = 0 then
            new.airport_hold := false;
          else
            new.airport_open_at := now() + make_interval(mins => cp.nearby_after_min);
          end if;
        end if;
      end if;
    end if;
    return new;
  end if;

  -- UPDATE
  if v_client then
    new.airport_pickup_id := old.airport_pickup_id;
    new.airport_drop_id := old.airport_drop_id;
    new.airport_hold := old.airport_hold;
    new.airport_open_at := old.airport_open_at;
    new.airport_fare := old.airport_fare;
    new.pickup_door_name := old.pickup_door_name;
    new.drop_door_name := old.drop_door_name;
    new.pickup_place_type := old.pickup_place_type;
    new.drop_place_type := old.drop_place_type;

    -- The airport charges stay as stamped.
    if new.charges is distinct from old.charges then
      select coalesce(jsonb_agg(e), '[]'::jsonb) into v_rest
        from jsonb_array_elements(case when jsonb_typeof(new.charges) = 'array' then new.charges else '[]'::jsonb end) e
       where e->'airport' is null;
      select v_rest || coalesce(jsonb_agg(e), '[]'::jsonb) into v_rest
        from jsonb_array_elements(case when jsonb_typeof(old.charges) = 'array' then old.charges else '[]'::jsonb end) e
       where e->'airport' is not null;
      new.charges := case when v_rest = '[]'::jsonb then null else v_rest end;
    end if;

    -- The doors are the rider's to choose, while the ride hasn't started.
    if new.pickup_door_id is distinct from old.pickup_door_id or new.drop_door_id is distinct from old.drop_door_id then
      if auth.uid() is distinct from old.rider_id then
        raise exception 'AIRPORT_DOOR_RIDER_ONLY' using errcode = '42501',
          hint = 'Only the passenger chooses the door.';
      end if;
      if old.status not in ('open', 'accepted', 'arrived') then
        raise exception 'AIRPORT_DOOR_LOCKED' using errcode = '42501',
          hint = 'The door can''t be changed once the trip has started.';
      end if;
      if new.pickup_door_id is distinct from old.pickup_door_id then
        v_name := case when new.pickup_door_id is null then null
                       else public.airport_door_name(new.pickup_door_id, old.airport_pickup_id, 'pick') end;
        if new.pickup_door_id is not null and v_name is null then
          raise exception 'AIRPORT_DOOR_INVALID' using errcode = '22023',
            hint = 'That door is not a pickup door of this airport.';
        end if;
        new.pickup_door_name := v_name;
      end if;
      if new.drop_door_id is distinct from old.drop_door_id then
        v_name := case when new.drop_door_id is null then null
                       else public.airport_door_name(new.drop_door_id, old.airport_drop_id, 'drop') end;
        if new.drop_door_id is not null and v_name is null then
          raise exception 'AIRPORT_DOOR_INVALID' using errcode = '22023',
            hint = 'That door is not a drop-off door of this airport.';
        end if;
        new.drop_door_name := v_name;
      end if;
    end if;

    -- A held pickup is taken (or bid on) only by a driver it is offered to.
    if old.airport_hold and old.status = 'open'
       and new.partner_id is not null and new.partner_id is distinct from old.partner_id
       and not public.airport_ride_offered(old.id, new.partner_id) then
      raise exception 'AIRPORT_QUEUE_ONLY' using errcode = '42501',
        hint = 'This airport pickup is offered to the drivers waiting for it.';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function public.ride_requests_airport() from public, anon, authenticated;

-- ---- Live ---------------------------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public'
                    and tablename = 'place_types') then
    alter publication supabase_realtime add table public.place_types;
  end if;
end $$;

notify pgrst, 'reload schema';
