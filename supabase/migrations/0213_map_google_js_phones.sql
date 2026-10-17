-- ============================================================================
-- 0213 · Admin → Settings → Maps: Google's JavaScript map on Android and iOS
-- too, in a web view of this site's google_map.html (as on Windows and macOS),
-- beside Google's own map. Google traffic goes with it when both Map and Map
-- (dark mode) are the JavaScript map, as on the web.
--
-- map_config_clean (0211) is kept as map_config_clean_0211.
-- ============================================================================

alter function public.map_config_clean(jsonb) rename to map_config_clean_0211;

create or replace function public.map_config_clean(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := public.map_config_clean_0211(p);
  prof text;
  slot text;
  src jsonb;
begin
  p := coalesce(p, '{}');
  for prof in select jsonb_object_keys(v->'profiles') loop
    continue when not (prof like '%.android' or prof like '%.ios');
    src := coalesce(p->'profiles'->prof->'tiles', '{}');
    foreach slot in array array['light', 'dark', 'satellite'] loop
      if src->>slot = 'google_js' then
        v := jsonb_set(v, array['profiles', prof, 'tiles', slot], '"google_js"');
      end if;
    end loop;
    if src->>'traffic' = 'google'
       and v->'profiles'->prof->'tiles'->>'light' = 'google_js'
       and v->'profiles'->prof->'tiles'->>'dark' = 'google_js' then
      v := jsonb_set(v, array['profiles', prof, 'tiles', 'traffic'], '"google"');
    end if;
  end loop;
  return v;
end;
$$;

notify pgrst, 'reload schema';
