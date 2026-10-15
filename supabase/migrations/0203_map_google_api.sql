-- ============================================================================
-- 0203 · Admin → Settings → Maps: which Google API answers place search and
-- routes.
--
-- Google has two of each: the newer Places API (New) and Routes API, and the
-- older Places API (Text Search) and Directions API. A key or project may
-- have only one of them on, so the admin picks:
--
--   map_config.googleApi   "new"      the newer APIs only
--                          "old"      the older APIs only
--                          "new_old"  the newer first, the older when it refuses (default)
--
-- Address lookup (Geocoding API) has one version and is not affected.
--
-- map_config_clean (0200) is kept as map_config_clean_0200; the new one adds
-- googleApi to what it returns, so map_config() and set_map_config() keep it.
-- ============================================================================

alter function public.map_config_clean(jsonb) rename to map_config_clean_0200;

create or replace function public.map_config_clean(p jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select public.map_config_clean_0200(p) || jsonb_build_object('googleApi',
    case when p->>'googleApi' in ('new', 'old', 'new_old') then p->>'googleApi' else 'new_old' end);
$$;
