-- ============================================================================
-- 0210 · Admin → Settings → Maps: Google's map on phones and desktop.
--
--   tiles.light / dark / satellite
--     "google_native"  Android, iPhone and iPad: Google's own map (the Maps
--                      SDK in the app, with the key the release build carries),
--                      under the app's own layers
--     "google_js"      now also on desktop (Windows, macOS): Google's
--                      JavaScript map in a web view, the backup there; Linux
--                      has no web view and keeps the app's own map
--   tiles.traffic "google"  Google's own traffic, as on the web, wherever Map
--                      and Map (dark mode) are both one of these Google maps
--
-- map_config_clean (0208) is kept as map_config_clean_0208; the new one keeps
-- what it returns and takes these where the input asked for them.
-- ============================================================================

alter function public.map_config_clean(jsonb) rename to map_config_clean_0208;

create or replace function public.map_config_clean(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := public.map_config_clean_0208(p);
  prof text;
  slot text;
  src jsonb;
  google text;
begin
  p := coalesce(p, '{}');
  for prof in select jsonb_object_keys(v->'profiles') loop
    google := case
      when prof like '%.android' or prof like '%.ios' then 'google_native'
      when prof like '%.desktop' then 'google_js'
    end;
    continue when google is null;
    src := coalesce(p->'profiles'->prof->'tiles', '{}');
    foreach slot in array array['light', 'dark', 'satellite'] loop
      if src->>slot = google then
        v := jsonb_set(v, array['profiles', prof, 'tiles', slot], to_jsonb(google));
      end if;
    end loop;
    if src->>'traffic' = 'google'
       and v->'profiles'->prof->'tiles'->>'light' = google
       and v->'profiles'->prof->'tiles'->>'dark' = google then
      v := jsonb_set(v, array['profiles', prof, 'tiles', 'traffic'], '"google"');
    end if;
  end loop;
  return v;
end;
$$;

notify pgrst, 'reload schema';
