-- ============================================================================
-- 0204 · Admin → Settings → Maps: Google's JavaScript map, and Google traffic.
--
--   tiles.light / dark / satellite  "google_js"  Google Maps JavaScript API drawn
--                                                 under the app's own map layers
--                                                 (web only; elsewhere it stays 'app')
--   tiles.traffic                   "google"     Google's live traffic on that map
--                                                 (web only, and only with google_js
--                                                 for Map and Map (dark mode))
--   keys.google_js                  "google/maps_js" by default: a browser key,
--                                                 restricted to the site in Google's console
--
-- Google's place search and address lookup may be shown on either Google map
-- (map_config_google_conflicts).
--
-- map_config_clean (0203) is kept as map_config_clean_0203; the new one keeps
-- what it returns and adds the above back where the input asked for it.
-- ============================================================================

alter function public.map_config_clean(jsonb) rename to map_config_clean_0203;

create or replace function public.map_config_clean(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := public.map_config_clean_0203(p);
  prof text;
  slot text;
  src jsonb;
  k text;
begin
  p := coalesce(p, '{}');
  foreach prof in array array['rider.web', 'partner.web'] loop
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

  k := nullif(trim(coalesce(p->'keys'->>'google_js', '')), '');
  if k is null or k !~ '^[a-z0-9_]+/[a-z0-9_]+(#[A-Za-z0-9_.:-]+)?$' then
    k := 'google/maps_js';
  end if;
  return jsonb_set(v, '{keys,google_js}', to_jsonb(k));
end;
$$;

-- Google's search or address lookup only on a Google map: its tiles or its
-- JavaScript map, for both Map and Map (dark mode).
create or replace function public.map_config_google_conflicts(p jsonb)
returns text
language sql
immutable
set search_path = public
as $$
  select string_agg(e.key, ', ' order by e.key)
    from jsonb_each(coalesce(p->'profiles', '{}')) e
   where (e.value->'search' ? 'google' or e.value->'reverse' ? 'google')
     and (e.value->'tiles'->>'light' not in ('google', 'google_js')
          or e.value->'tiles'->>'dark' not in ('google', 'google_js'));
$$;
