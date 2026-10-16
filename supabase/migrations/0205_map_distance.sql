-- ============================================================================
-- 0205 · Admin → Settings → Maps: distance in place search results.
--
-- Each place search result shows its road distance from where the user is
-- now ("8.59km"), as Grab does. Which provider measures it is a fallback
-- order per profile, like search, reverse and routing:
--
--   profiles.<role>.<device>.distance  up to three of
--     osrm · google · mapbox · here · tomtom · locationiq · straight
--     ("osrm" by default; osrm and straight are worked out on the device,
--      straight being the distance as the crow flies)
--
-- Google's distances are Google content too, so a profile that uses them
-- must draw a Google map (map_config_google_conflicts), as for its search.
--
-- map_config_clean (0204) is kept as map_config_clean_0204; the new one keeps
-- what it returns and adds the distance list. The geo function counts these
-- calls under kind 'distance'.
-- ============================================================================

alter function public.map_config_clean(jsonb) rename to map_config_clean_0204;

create or replace function public.map_config_clean(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := public.map_config_clean_0204(p);
  opts text[] := array['osrm', 'google', 'mapbox', 'here', 'tomtom', 'locationiq', 'straight'];
  prof text;
  src jsonb;
  picked text[];
  x text;
begin
  p := coalesce(p, '{}');
  for prof in select jsonb_object_keys(v->'profiles') loop
    src := p->'profiles'->prof->'distance';
    picked := '{}';
    if jsonb_typeof(src) = 'array' then
      for x in select jsonb_array_elements_text(src) loop
        if x = any(opts) and not x = any(picked) and cardinality(picked) < 3 then
          picked := picked || x;
        end if;
      end loop;
    end if;
    if cardinality(picked) = 0 then picked := array['osrm']; end if;
    v := jsonb_set(v, array['profiles', prof, 'distance'], to_jsonb(picked));
  end loop;
  return v;
end;
$$;

-- Google's search, address lookup or distances only on a Google map: its
-- tiles or its JavaScript map, for both Map and Map (dark mode).
create or replace function public.map_config_google_conflicts(p jsonb)
returns text
language sql
immutable
set search_path = public
as $$
  select string_agg(e.key, ', ' order by e.key)
    from jsonb_each(coalesce(p->'profiles', '{}')) e
   where (e.value->'search' ? 'google' or e.value->'reverse' ? 'google' or e.value->'distance' ? 'google')
     and (e.value->'tiles'->>'light' not in ('google', 'google_js')
          or e.value->'tiles'->>'dark' not in ('google', 'google_js'));
$$;

alter table public.geo_usage_daily drop constraint if exists geo_usage_daily_kind_check;
alter table public.geo_usage_daily add constraint geo_usage_daily_kind_check
  check (kind in ('tiles', 'search', 'reverse', 'routing', 'distance'));

notify pgrst, 'reload schema';
