-- ============================================================================
-- 0207 · Admin → Settings → Maps: Google search over any map, Google's
-- Autocomplete, the smart address options, and two more key slots.
--
--   Google's place search, address lookup and distances may now be used
--   over any map (the admin's choice): map_config_google_conflicts no longer
--   reports anything, so set_map_config no longer refuses them. The admin
--   page still shows a note.
--
--   googleSearch   "text" (Text Search, as before) | "autocomplete" (Google
--                  suggests as the rider types; the place is looked up when picked)
--   smartAddress   "normal" | "a" (clean two-line suggestions)
--                  | "b" (places first, the rider's saved and recent on top)
--                  | "c" (Google checks and completes a picked street address)
--                  | "all" (A, B and C together)
--   keys.google_address  "google/address_validation" by default (option C)
--   keys.google_tiles    unchanged; its function secret is now
--                  GOOGLE_MAP_TILES_API_KEY first, then GOOGLE_MAP_API_KEY
--
-- map_config_clean (0206) is kept as map_config_clean_0206.
-- ============================================================================

alter function public.map_config_clean(jsonb) rename to map_config_clean_0206;

create or replace function public.map_config_clean(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := public.map_config_clean_0206(p);
  k text;
begin
  p := coalesce(p, '{}');
  k := nullif(trim(coalesce(p->'keys'->>'google_address', '')), '');
  if k is null or k !~ '^[a-z0-9_]+/[a-z0-9_]+(#[A-Za-z0-9_.:-]+)?$' then
    k := 'google/address_validation';
  end if;
  return jsonb_set(v, '{keys,google_address}', to_jsonb(k)) || jsonb_build_object(
    'googleSearch', case when p->>'googleSearch' = 'autocomplete' then 'autocomplete' else 'text' end,
    'smartAddress', case when p->>'smartAddress' in ('a', 'b', 'c', 'all') then p->>'smartAddress' else 'normal' end);
end;
$$;

-- Google's results over any map: nothing to report.
create or replace function public.map_config_google_conflicts(p jsonb)
returns text
language sql
immutable
set search_path = public
as $$
  select null::text;
$$;

notify pgrst, 'reload schema';
