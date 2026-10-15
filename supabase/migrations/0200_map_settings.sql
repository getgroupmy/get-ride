-- ============================================================================
-- 0200 · Admin → Settings → Maps: which map tiles, place search, reverse
-- geocoding and routing each kind of user (rider, partner) gets on each kind
-- of device (Android, iOS, web, desktop), and which saved API key each
-- provider uses.
--
--   app_settings 'map_config' = {
--     profiles: { "rider.android": { tiles: {light, dark, satellite, traffic},
--                                    search: [..], reverse: [..], routing: [..] },
--                 … eight in all (rider|partner × android|ios|web|desktop) },
--     keys: { google_tiles: "google/maps", mapbox: "mapbox/tiles#<key id>", … }
--   }
--
-- A tile slot set to 'app' keeps what the app was built with (today's OSM
-- tiles, Esri imagery, TomTom/HERE traffic), so nothing changes until an
-- admin picks something else. Search, reverse and routing are fallback
-- orders (up to three); 'nominatim' and 'osrm' are called by the device
-- itself, every other provider through the `geo` function, which holds the
-- keys. Keys point into Admin → API Keys (app_settings 'api_providers') as
-- "<provider>/<service>", optionally "#<key id>" for one key; the secrets
-- never leave the server except tile keys, which a map has to send.
--
-- Google's terms: results from Google's place search and geocoding may
-- only be shown on a Google map, so a profile that uses Google for either
-- must draw Google tiles (light and dark).
--
-- Also: the `geo` function's cache, usage counts and per-caller rate limit
-- (service role only), and Google's map tile sessions.
-- ============================================================================

-- ---- The settings ----------------------------------------------------------------------------
insert into public.app_settings (key, value) values ('map_config', '{}'::jsonb)
on conflict (key) do nothing;

create or replace function public.map_config_clean(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  roles   text[] := array['rider', 'partner'];
  devices text[] := array['android', 'ios', 'web', 'desktop'];
  tile_options jsonb := jsonb_build_object(
    'light', jsonb_build_array('app', 'osm', 'google', 'mapbox', 'here', 'tomtom', 'maptiler'),
    'dark', jsonb_build_array('app', 'osm', 'google', 'mapbox', 'here', 'tomtom', 'maptiler'),
    'satellite', jsonb_build_array('app', 'esri', 'google', 'mapbox', 'here', 'tomtom', 'maptiler'),
    'traffic', jsonb_build_array('app', 'tomtom', 'here', 'none'));
  place_options text[] := array['nominatim', 'google', 'mapbox', 'here', 'tomtom', 'locationiq', 'maptiler'];
  route_options text[] := array['osrm', 'google', 'mapbox', 'here', 'tomtom', 'locationiq'];
  key_slots text[] := array['google_tiles', 'google_places', 'google_geocoding', 'google_routes', 'mapbox', 'here',
                            'tomtom', 'maptiler', 'locationiq', 'nominatim', 'osrm'];
  key_defaults jsonb := jsonb_build_object(
    'google_tiles', 'google/maps', 'google_places', 'google/places', 'google_geocoding', 'google/geocoding',
    'google_routes', 'google/directions', 'mapbox', 'mapbox/tiles', 'here', 'here/api', 'tomtom', 'tomtom/api',
    'maptiler', 'tiles/maptiler', 'locationiq', 'geocoding/locationiq', 'nominatim', 'openstreetmap/nominatim',
    'osrm', 'openstreetmap/osrm');
  profiles jsonb := '{}';
  keys     jsonb := '{}';
  r text; d text; slot text; k text;
  src jsonb; tiles jsonb; t jsonb; v text;
  lists jsonb;
  kind text;
  opts text[];
  picked text[];
begin
  p := coalesce(p, '{}');
  foreach r in array roles loop
    foreach d in array devices loop
      src := coalesce(p->'profiles'->(r || '.' || d), '{}');
      tiles := '{}';
      foreach slot in array array['light', 'dark', 'satellite', 'traffic'] loop
        v := src->'tiles'->>slot;
        tiles := tiles || jsonb_build_object(slot,
          case when v is not null and tile_options->slot ? v then v else 'app' end);
      end loop;
      lists := '{}';
      foreach kind in array array['search', 'reverse', 'routing'] loop
        opts := case when kind = 'routing' then route_options else place_options end;
        picked := '{}';
        if jsonb_typeof(src->kind) = 'array' then
          for v in select jsonb_array_elements_text(src->kind) loop
            if v = any(opts) and not v = any(picked) and cardinality(picked) < 3 then
              picked := picked || v;
            end if;
          end loop;
        end if;
        if cardinality(picked) = 0 then picked := array[opts[1]]; end if;
        lists := lists || jsonb_build_object(kind, to_jsonb(picked));
      end loop;
      profiles := profiles || jsonb_build_object(r || '.' || d, jsonb_build_object('tiles', tiles) || lists);
    end loop;
  end loop;

  foreach k in array key_slots loop
    v := nullif(trim(coalesce(p->'keys'->>k, '')), '');
    -- "<provider>/<service>" or "<provider>/<service>#<key id>".
    if v is null or v !~ '^[a-z0-9_]+/[a-z0-9_]+(#[A-Za-z0-9_.:-]+)?$' then
      v := key_defaults->>k;
    end if;
    keys := keys || jsonb_build_object(k, v);
  end loop;

  return jsonb_build_object('profiles', profiles, 'keys', keys);
end;
$$;

-- Profiles breaking Google's terms (Google search or geocoding on a map
-- that isn't Google's), as "rider.android, partner.web"; null when none.
create or replace function public.map_config_google_conflicts(p jsonb)
returns text
language sql
immutable
set search_path = public
as $$
  select string_agg(e.key, ', ' order by e.key)
    from jsonb_each(coalesce(p->'profiles', '{}')) e
   where (e.value->'search' ? 'google' or e.value->'reverse' ? 'google')
     and (e.value->'tiles'->>'light' <> 'google' or e.value->'tiles'->>'dark' <> 'google');
$$;

-- Admin: the whole setting (key references only, no secrets).
create or replace function public.map_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'Only an admin can read the map settings.' using errcode = '42501';
  end if;
  return public.map_config_clean((select value from public.app_settings where key = 'map_config'));
end;
$$;
revoke execute on function public.map_config() from public, anon;
grant execute on function public.map_config() to authenticated;

create or replace function public.set_map_config(p_config jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := public.map_config_clean(p_config);
  bad text := public.map_config_google_conflicts(v);
begin
  if not public.caller_is_admin() then
    raise exception 'Only an admin can change the map settings.' using errcode = '42501';
  end if;
  if bad is not null then
    raise exception 'MAP_GOOGLE_TERMS'
      using hint = 'Google search or address lookup must be shown on Google map tiles (light and dark): ' || bad || '.';
  end if;
  insert into public.app_settings (key, value, updated_at) values ('map_config', v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return v;
end;
$$;
revoke execute on function public.set_map_config(jsonb) from public, anon;
grant execute on function public.set_map_config(jsonb) to authenticated;

-- ---- The geo function's cache, usage and rate limit (service role only) -------------------
create table if not exists public.geo_cache (
  key        text primary key,
  value      jsonb not null,
  expires_at timestamptz not null
);
create index if not exists geo_cache_expires_idx on public.geo_cache (expires_at);

create table if not exists public.geo_usage_daily (
  day      date not null default current_date,
  provider text not null,
  kind     text not null check (kind in ('tiles', 'search', 'reverse', 'routing')),
  calls    integer not null default 0,
  cached   integer not null default 0,
  failures integer not null default 0,
  primary key (day, provider, kind)
);

create table if not exists public.geo_rate (
  bucket       text primary key,
  window_start timestamptz not null,
  hits         integer not null
);

-- Google's map tile sessions (one per map type and style), reused until
-- they near their expiry.
create table if not exists public.map_tile_sessions (
  kind       text primary key,
  session    text not null,
  expires_at timestamptz not null
);

alter table public.geo_cache enable row level security;
alter table public.geo_usage_daily enable row level security;
alter table public.geo_rate enable row level security;
alter table public.map_tile_sessions enable row level security;
revoke all on public.geo_cache, public.geo_usage_daily, public.geo_rate, public.map_tile_sessions
  from anon, authenticated;

-- One call counted against [p_bucket]'s minute; false once it is over [p_limit].
create or replace function public.geo_take(p_bucket text, p_limit integer)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  n integer;
begin
  insert into public.geo_rate as g (bucket, window_start, hits) values (p_bucket, now(), 1)
  on conflict (bucket) do update
    set hits = case when g.window_start < now() - interval '1 minute' then 1 else g.hits + 1 end,
        window_start = case when g.window_start < now() - interval '1 minute' then now() else g.window_start end
  returning hits into n;
  return n <= p_limit;
end;
$$;
revoke execute on function public.geo_take(text, integer) from public, anon, authenticated;
grant execute on function public.geo_take(text, integer) to service_role;

create or replace function public.geo_count(p_provider text, p_kind text, p_ok boolean, p_cached boolean)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.geo_usage_daily as u (provider, kind, calls, cached, failures)
  values (p_provider, p_kind, 1, case when p_cached then 1 else 0 end, case when p_ok then 0 else 1 end)
  on conflict (day, provider, kind) do update
    set calls = u.calls + 1,
        cached = u.cached + excluded.cached,
        failures = u.failures + excluded.failures;
$$;
revoke execute on function public.geo_count(text, text, boolean, boolean) from public, anon, authenticated;
grant execute on function public.geo_count(text, text, boolean, boolean) to service_role;

-- Admin: calls per provider and kind over the last [p_days] days.
create or replace function public.map_usage(p_days integer default 30)
returns table (provider text, kind text, calls bigint, cached bigint, failures bigint)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select u.provider, u.kind, sum(u.calls)::bigint, sum(u.cached)::bigint, sum(u.failures)::bigint
      from public.geo_usage_daily u
     where u.day > current_date - greatest(1, least(coalesce(p_days, 30), 365))
     group by u.provider, u.kind
     order by sum(u.calls) desc;
end;
$$;
revoke execute on function public.map_usage(integer) from public, anon;
grant execute on function public.map_usage(integer) to authenticated;

-- Expired cache rows and old rate windows go hourly.
create or replace function public.geo_cache_prune()
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.geo_cache where expires_at < now();
  delete from public.geo_rate where window_start < now() - interval '10 minutes';
  delete from public.geo_usage_daily where day < current_date - 400;
$$;
revoke execute on function public.geo_cache_prune() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'geo-cache-prune';
    perform cron.schedule('geo-cache-prune', '17 * * * *', $job$select public.geo_cache_prune()$job$);
  end if;
end $$;

notify pgrst, 'reload schema';
