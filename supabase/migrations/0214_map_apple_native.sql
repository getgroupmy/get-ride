-- ============================================================================
-- 0214 · Admin → Settings → Maps: Apple's own map on iPhones and iPads.
--
--   tiles.light / dark / satellite
--     "apple_native"  iOS only: Apple's map (MapKit, built into the phone, no
--                     key) under the app's own layers. The iPhone app also
--                     falls back to it whenever the map set here can't draw.
--
-- map_config_clean (0213) is kept as map_config_clean_0213.
-- ============================================================================

alter function public.map_config_clean(jsonb) rename to map_config_clean_0213;

create or replace function public.map_config_clean(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := public.map_config_clean_0213(p);
  prof text;
  slot text;
begin
  p := coalesce(p, '{}');
  for prof in select jsonb_object_keys(v->'profiles') loop
    continue when prof not like '%.ios';
    foreach slot in array array['light', 'dark', 'satellite'] loop
      if p->'profiles'->prof->'tiles'->>slot = 'apple_native' then
        v := jsonb_set(v, array['profiles', prof, 'tiles', slot], '"apple_native"');
      end if;
    end loop;
  end loop;
  return v;
end;
$$;

notify pgrst, 'reload schema';
