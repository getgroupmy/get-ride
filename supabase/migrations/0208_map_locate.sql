-- ============================================================================
-- 0208 · Admin → Settings → Maps: where Google's Autocomplete suggestions are.
--
-- Autocomplete (0207) gives a suggestion's name and Google's id but no
-- position until it is picked, so its road distance from the user can't be
-- measured. The app now looks each one up roughly first, by a fallback order
-- per profile like search and reverse:
--
--   profiles.<role>.<device>.locate  up to three of
--     nominatim · google · mapbox · here · tomtom · locationiq · maptiler · amazon
--     ("nominatim", OpenStreetMap, by default)
--
-- Whatever is set, the app asks OpenStreetMap last for place search, address
-- lookup (the pickup point's name) and these positions when none of the set
-- ones answers. The geo function's `locate` action asks a listed provider as
-- a plain search (never Autocomplete) and counts it under kind 'search'.
--
-- map_config_clean (0207) is kept as map_config_clean_0207; the new one keeps
-- what it returns and adds the locate list.
-- ============================================================================

alter function public.map_config_clean(jsonb) rename to map_config_clean_0207;

create or replace function public.map_config_clean(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := public.map_config_clean_0207(p);
  opts text[] := array['nominatim', 'google', 'mapbox', 'here', 'tomtom', 'locationiq', 'maptiler', 'amazon'];
  prof text;
  src jsonb;
  picked text[];
  x text;
begin
  p := coalesce(p, '{}');
  for prof in select jsonb_object_keys(v->'profiles') loop
    src := p->'profiles'->prof->'locate';
    picked := '{}';
    if jsonb_typeof(src) = 'array' then
      for x in select jsonb_array_elements_text(src) loop
        if x = any(opts) and not x = any(picked) and cardinality(picked) < 3 then
          picked := picked || x;
        end if;
      end loop;
    end if;
    if cardinality(picked) = 0 then picked := array['nominatim']; end if;
    v := jsonb_set(v, array['profiles', prof, 'locate'], to_jsonb(picked));
  end loop;
  return v;
end;
$$;

notify pgrst, 'reload schema';
