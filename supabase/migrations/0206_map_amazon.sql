-- ============================================================================
-- 0206 · Admin → Settings → Maps: Amazon Location Service, which in its
-- Malaysia and Singapore regions answers with GrabMaps data (Grab's own map
-- of Southeast Asia).
--
--   search / reverse / routing / distance  "amazon"  through the geo function
--   tiles.light / dark (web)               "amazon_js"  Amazon's map, drawn in the
--                                                     browser by MapLibre (its
--                                                     tiles are vector only)
--   keys.amazon       "amazon/location" by default: an Amazon Location API key
--                     allowed place search, address lookup, routes and matrices
--   keys.amazon_maps  "amazon/maps" by default: a key allowed only the map
--                     (GetTile), restricted to the site, since the browser sends it
--   amazonRegion      "ap-southeast-5" (Malaysia, default) or "ap-southeast-1"
--                     (Singapore): GrabMaps is served from these two
--
-- map_config_clean (0205) is kept as map_config_clean_0205; the new one keeps
-- what it returns and adds the above where the input asked for it. The lists
-- are read again with "amazon" allowed, by the same rules (known, once, three
-- at most, the free default when empty).
-- ============================================================================

alter function public.map_config_clean(jsonb) rename to map_config_clean_0205;

create or replace function public.map_config_clean(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := public.map_config_clean_0205(p);
  lists jsonb := jsonb_build_object(
    'search', jsonb_build_array('nominatim', 'google', 'mapbox', 'here', 'tomtom', 'locationiq', 'maptiler', 'amazon'),
    'reverse', jsonb_build_array('nominatim', 'google', 'mapbox', 'here', 'tomtom', 'locationiq', 'maptiler', 'amazon'),
    'routing', jsonb_build_array('osrm', 'google', 'mapbox', 'here', 'tomtom', 'locationiq', 'amazon'),
    'distance', jsonb_build_array('osrm', 'google', 'mapbox', 'here', 'tomtom', 'locationiq', 'straight', 'amazon'));
  prof text;
  kind text;
  slot text;
  src jsonb;
  picked text[];
  x text;
  k text;
  region text;
begin
  p := coalesce(p, '{}');
  for prof in select jsonb_object_keys(v->'profiles') loop
    foreach kind in array array['search', 'reverse', 'routing', 'distance'] loop
      src := p->'profiles'->prof->kind;
      if jsonb_typeof(src) = 'array' and src ? 'amazon' then
        picked := '{}';
        for x in select jsonb_array_elements_text(src) loop
          if lists->kind ? x and not x = any(picked) and cardinality(picked) < 3 then
            picked := picked || x;
          end if;
        end loop;
        v := jsonb_set(v, array['profiles', prof, kind], to_jsonb(picked));
      end if;
    end loop;
    if prof like '%.web' then
      foreach slot in array array['light', 'dark'] loop
        if p->'profiles'->prof->'tiles'->>slot = 'amazon_js' then
          v := jsonb_set(v, array['profiles', prof, 'tiles', slot], '"amazon_js"');
        end if;
      end loop;
    end if;
  end loop;

  foreach slot in array array['amazon', 'amazon_maps'] loop
    k := nullif(trim(coalesce(p->'keys'->>slot, '')), '');
    if k is null or k !~ '^[a-z0-9_]+/[a-z0-9_]+(#[A-Za-z0-9_.:-]+)?$' then
      k := case slot when 'amazon' then 'amazon/location' else 'amazon/maps' end;
    end if;
    v := jsonb_set(v, array['keys', slot], to_jsonb(k));
  end loop;

  region := p->>'amazonRegion';
  if region is null or region not in ('ap-southeast-5', 'ap-southeast-1') then
    region := 'ap-southeast-5';
  end if;
  return v || jsonb_build_object('amazonRegion', region);
end;
$$;

notify pgrst, 'reload schema';
