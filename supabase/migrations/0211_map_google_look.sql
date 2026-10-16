-- ============================================================================
-- 0211 · Admin → Settings → Maps: how Google's map looks, and Google's
-- unofficial tile address for testing.
--
--   googleSatellite  "satellite" (imagery only, as before) | "hybrid" (imagery
--                    with Google's roads and names on it)
--   googleMap        "roadmap" (as before) | "terrain" (hills and relief, the
--                    light map only; the dark map stays the night roadmap)
--     Both apply to every Google map: Map Tiles, the native map on phones,
--     the JavaScript map, and the tiles below.
--   tiles.light / dark / satellite "google_xyz"
--                    Google's own tile address (mt1.google.com/vt), with no
--                    key: for testing only. It is not one of Google's APIs
--                    and its terms don't allow it in a released app; the
--                    admin page says so wherever it is set.
--
-- map_config_clean (0210) is kept as map_config_clean_0210.
-- ============================================================================

alter function public.map_config_clean(jsonb) rename to map_config_clean_0210;

create or replace function public.map_config_clean(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := public.map_config_clean_0210(p);
  prof text;
  slot text;
begin
  p := coalesce(p, '{}');
  for prof in select jsonb_object_keys(v->'profiles') loop
    foreach slot in array array['light', 'dark', 'satellite'] loop
      if p->'profiles'->prof->'tiles'->>slot = 'google_xyz' then
        v := jsonb_set(v, array['profiles', prof, 'tiles', slot], '"google_xyz"');
      end if;
    end loop;
  end loop;
  return v || jsonb_build_object(
    'googleSatellite', case when p->>'googleSatellite' = 'hybrid' then 'hybrid' else 'satellite' end,
    'googleMap', case when p->>'googleMap' = 'terrain' then 'terrain' else 'roadmap' end);
end;
$$;

notify pgrst, 'reload schema';
