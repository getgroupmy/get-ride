-- ============================================================================
-- 0319 — Own maps on the office NAS: routes and ETAs (OSRM), address search
-- (Photon) and map tiles (Protomaps vector tiles), OpenStreetMap data for
-- Malaysia, Singapore and Brunei. deploy/nas-maps/ runs them in Docker.
--
-- Version 20261028120000 (0319_nas_maps). Re-runnable: tables and indexes
-- "if not exists", functions "create or replace", the map_config_clean
-- rename only once, policies dropped first, seed rows only where missing.
--
-- 1. A provider "Office NAS (OpenStreetMap)", id 'nas', in Admin → Maps:
--    allowed in every profile's search, reverse, locate, routing and
--    distance lists, and for Map and Map (dark mode) on the web (a MapLibre
--    map of the NAS's vector tiles; phones and desktop keep their tiles).
--    The admin sets the order as for any provider, e.g. routes NAS then
--    Google, search NAS then Google, tiles NAS (then the app's own when the
--    NAS map can't load). map_config_clean (0214) is kept as
--    map_config_clean_0214; the new one keeps what it returns and adds 'nas'
--    back where the input asked for it.
-- 2. app_settings 'nas_maps': a Default rule and region rules (country /
--    state / city / suburb; the most specific region holding the point wins,
--    and a region rule only overrides the parts it sets): routes on/off,
--    search on/off, tiles on/off, and how long the geo function waits for the
--    NAS before it gives the next provider a turn (timeoutMs, default 1500,
--    300..5000). googleCost: USD per 1,000 Google routes / searches, for
--    the "saved" figure on Admin → Office NAS → Maps.
--      nas_maps_config()            admins read
--      admin_nas_maps_set(p)        EDIT on admin-settings-office-nas
--      nas_maps_rule(cfg, names)    the rule for a place's names (pure)
--      nas_maps_rule_at(lat, lng)   the rule where a point is (regions_at, 0170)
-- 3. The NAS pairs like the document reader (0293): a full admin makes a
--    code good for 10 minutes, the NAS trades it once for its own key, and
--    only the key's hash is kept. The NAS only calls out (the nas-maps edge
--    function); it checks in every minute with the health of OSRM, Photon,
--    the tiles and the weekly data refresh, and with the address of its
--    Cloudflare Tunnel and the secret the geo function must send there.
--    That secret is kept for the geo function only (service role), never
--    shown to an admin.
-- 4. nas_services (shared by every NAS batch): one row per service, the
--    heartbeat. This one writes service 'maps'. Admins read it.
-- 5. nas_maps_daily: per day and kind, the calls the NAS answered (served
--    instead of a paid provider), the ones it failed or timed out, and their
--    time. nas_maps_count() is the geo function's (service role).
-- 6. nas_maps_link(lat, lng): what the geo function needs to ask the NAS
--    (its tunnel address, secret, whether it is up, and the rule there).
-- 7. admin_nas_maps_status(): the Office NAS → Maps tab.
--
-- get.ride keeps working when the NAS is off: the geo function stops
-- offering 'nas' once the NAS hasn't checked in for 3 minutes, and a NAS
-- that is slower than the timeout hands the call to the next provider.
-- ============================================================================

-- ---- 4. The NAS heartbeat table (shared) ------------------------------------------------------
create table if not exists public.nas_services (
  service   text primary key,
  last_seen timestamptz,
  status    text,
  detail    jsonb,
  version   text
);
alter table public.nas_services enable row level security;
revoke all on public.nas_services from anon, authenticated;
grant select on public.nas_services to authenticated;
drop policy if exists "nas_services admin read" on public.nas_services;
create policy "nas_services admin read"
  on public.nas_services for select to authenticated
  using ((select public.caller_is_admin()));

-- ---- 1. 'nas' in Admin → Maps ------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_proc
                  where proname = 'map_config_clean_0214' and pronamespace = 'public'::regnamespace) then
    alter function public.map_config_clean(jsonb) rename to map_config_clean_0214;
  end if;
end $$;

create or replace function public.map_config_clean(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := public.map_config_clean_0214(p);
  places constant jsonb :=
    '["nominatim", "google", "mapbox", "here", "tomtom", "locationiq", "maptiler", "amazon", "nas"]';
  routes constant jsonb := '["osrm", "google", "mapbox", "here", "tomtom", "locationiq", "amazon", "nas"]';
  lists jsonb := jsonb_build_object(
    'search', places, 'reverse', places, 'locate', places,
    'routing', routes, 'distance', routes || '["straight"]');
  prof text;
  kind text;
  slot text;
  src jsonb;
  picked text[];
  x text;
begin
  p := coalesce(p, '{}');
  for prof in select jsonb_object_keys(v->'profiles') loop
    -- A list naming the NAS is read again with it allowed, by the same rules
    -- (known, once, three at most).
    foreach kind in array array['search', 'reverse', 'locate', 'routing', 'distance'] loop
      src := p->'profiles'->prof->kind;
      if jsonb_typeof(src) = 'array' and src ? 'nas' then
        picked := '{}';
        for x in select jsonb_array_elements_text(src) loop
          if lists->kind ? x and not x = any(picked) and cardinality(picked) < 3 then
            picked := picked || x;
          end if;
        end loop;
        v := jsonb_set(v, array['profiles', prof, kind], to_jsonb(picked));
      end if;
    end loop;
    -- The NAS's map is drawn by MapLibre, which the app has on the web only.
    if prof like '%.web' then
      foreach slot in array array['light', 'dark'] loop
        if p->'profiles'->prof->'tiles'->>slot = 'nas' then
          v := jsonb_set(v, array['profiles', prof, 'tiles', slot], '"nas"');
        end if;
      end loop;
    end if;
  end loop;
  return v;
end;
$$;

-- ---- 2. The settings ---------------------------------------------------------------------------
insert into public.app_settings (key, value) values ('nas_maps', '{}'::jsonb)
on conflict (key) do nothing;

-- One rule's parts: [p_full] fills every part (the Default rule); otherwise
-- only the parts set are kept (a region rule overrides only those).
create or replace function public.nas_maps_rule_parts(p jsonb, p_full boolean)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v jsonb := '{}';
  part text;
  t numeric;
begin
  p := case when jsonb_typeof(p) = 'object' then p else '{}' end;
  foreach part in array array['routes', 'search', 'tiles'] loop
    if jsonb_typeof(p->part) = 'boolean' then
      v := v || jsonb_build_object(part, (p->>part)::boolean);
    elsif p_full then
      v := v || jsonb_build_object(part, true);
    end if;
  end loop;
  t := case when (p->>'timeoutMs') ~ '^\d+(\.\d+)?$' then (p->>'timeoutMs')::numeric end;
  if t is not null then
    v := v || jsonb_build_object('timeoutMs', (greatest(300, least(5000, round(t / 100) * 100)))::int);
  elsif p_full then
    v := v || jsonb_build_object('timeoutMs', 1500);
  end if;
  return v;
end;
$$;
revoke execute on function public.nas_maps_rule_parts(jsonb, boolean) from public, anon, authenticated;

create or replace function public.nas_maps_normalize(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_regions jsonb := '[]';
  r jsonb;
  v_rule jsonb;
  v_names jsonb;
  lvl text;
  n text;
  v_cost jsonb := coalesce(p->'googleCost', '{}');
  c numeric;
  v_costs jsonb := '{}';
  k text;
begin
  p := case when jsonb_typeof(p) = 'object' then p else '{}' end;
  if jsonb_typeof(p->'regions') = 'array' then
    for r in select * from jsonb_array_elements(p->'regions') loop
      continue when jsonb_typeof(r) <> 'object';
      v_names := '{}';
      foreach lvl in array array['country', 'state', 'city', 'suburb'] loop
        n := nullif(left(btrim(coalesce(r->>lvl, '')), 80), '');
        v_names := v_names || jsonb_build_object(lvl, n);
      end loop;
      -- A region needs its country, and each level its parent.
      continue when v_names->>'country' is null
        or (v_names->>'city' is not null and v_names->>'state' is null)
        or (v_names->>'suburb' is not null and v_names->>'city' is null);
      v_rule := v_names || public.nas_maps_rule_parts(r, false);
      v_regions := v_regions || jsonb_build_array(v_rule);
      exit when jsonb_array_length(v_regions) >= 200;
    end loop;
  end if;
  foreach k in array array['route', 'search'] loop
    c := case when (v_cost->>k) ~ '^\d+(\.\d+)?$' then (v_cost->>k)::numeric end;
    v_costs := v_costs || jsonb_build_object(k,
      round(greatest(0, least(100, coalesce(c, case k when 'route' then 5 else 17 end))), 2));
  end loop;
  return jsonb_build_object(
    'default', public.nas_maps_rule_parts(p->'default', true),
    'regions', v_regions,
    'googleCost', v_costs);
end;
$$;
revoke execute on function public.nas_maps_normalize(jsonb) from public, anon, authenticated;

create or replace function public.nas_maps_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.nas_maps_normalize(coalesce((select value from public.app_settings where key = 'nas_maps'), '{}'));
$$;
revoke execute on function public.nas_maps_settings() from public, anon, authenticated;

create or replace function public.nas_maps_config()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'Admins only.' using errcode = '42501';
  end if;
  return public.nas_maps_settings();
end;
$$;
revoke execute on function public.nas_maps_config() from public, anon;
grant execute on function public.nas_maps_config() to authenticated;

create or replace function public.admin_nas_maps_set(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := public.nas_maps_normalize(coalesce(p, '{}'));
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:admin_nas_maps_set') then
    raise exception 'You can''t change the office NAS maps.' using errcode = '42501';
  end if;
  insert into public.app_settings (key, value) values ('nas_maps', v)
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return v;
end;
$$;
revoke execute on function public.admin_nas_maps_set(jsonb) from public, anon;
grant execute on function public.admin_nas_maps_set(jsonb) to authenticated;

insert into public.admin_table_pages (target, page) values
  ('rpc:admin_nas_maps_set', 'admin-settings-office-nas')
on conflict do nothing;

-- The rule for a place named [country, state, city, suburb]: the Default
-- rule, then each matching region rule from the widest to the most specific
-- (the later of two equals last), each overriding the parts it sets. A
-- region rule matches when every level it names is the place's.
create or replace function public.nas_maps_rule(
  p_cfg jsonb, p_country text, p_state text default null, p_city text default null, p_suburb text default null)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_cfg jsonb := public.nas_maps_normalize(p_cfg);
  v jsonb := v_cfg->'default';
  r record;
  v_from text := null;
begin
  for r in
    select x.rule, x.ord,
           case when x.rule->>'suburb' is not null then 4 when x.rule->>'city' is not null then 3
                when x.rule->>'state' is not null then 2 else 1 end as depth
      from jsonb_array_elements(v_cfg->'regions') with ordinality x(rule, ord)
     where public.region_name_norm(x.rule->>'country') = public.region_name_norm(p_country)
       and (x.rule->>'state' is null or public.region_name_norm(x.rule->>'state') = public.region_name_norm(p_state))
       and (x.rule->>'city' is null or public.region_name_norm(x.rule->>'city') = public.region_name_norm(p_city))
       and (x.rule->>'suburb' is null
            or public.region_name_norm(x.rule->>'suburb') = public.region_name_norm(p_suburb))
     order by depth, ord
  loop
    v := v || (r.rule - 'country' - 'state' - 'city' - 'suburb');
    v_from := concat_ws(', ', r.rule->>'suburb', r.rule->>'city', r.rule->>'state', r.rule->>'country');
  end loop;
  return v || jsonb_build_object('region', v_from);
end;
$$;
revoke execute on function public.nas_maps_rule(jsonb, text, text, text, text) from public, anon, authenticated;

-- The rule where a point is: the most specific region holding it.
create or replace function public.nas_maps_rule_at(p_lat double precision, p_lng double precision)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_country text;
  v_state text;
  v_city text;
  v_suburb text;
begin
  if p_lat is not null and p_lng is not null then
    select r.country, r.state, r.city, r.suburb into v_country, v_state, v_city, v_suburb
      from public.regions_at(p_lat, p_lng) r
     where r.inside
     order by case r.region_table when 'suburbs' then 4 when 'cities' then 3 when 'states' then 2 else 1 end desc,
              r.area nulls last
     limit 1;
  end if;
  return public.nas_maps_rule(public.nas_maps_settings(), v_country, nullif(v_state, ''), nullif(v_city, ''),
                              nullif(v_suburb, ''));
end;
$$;
revoke execute on function public.nas_maps_rule_at(double precision, double precision) from public, anon, authenticated;

-- ---- 3. The NAS, its key and pairing codes -----------------------------------------------------
create table if not exists public.nas_map_servers (
  id             uuid primary key default gen_random_uuid(),
  label          text not null,
  device_id      text not null unique,
  model          text,
  app_version    text,
  key_hash       text not null unique,
  -- Its Cloudflare Tunnel: routes and search (maps_url, secret header) and
  -- the public tile address. The secret is the geo function's alone.
  maps_url       text,
  tiles_url      text,
  gateway_secret text,
  paired_by      uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now(),
  last_seen_at   timestamptz
);
alter table public.nas_map_servers enable row level security;
revoke all on public.nas_map_servers from anon, authenticated;

create table if not exists public.nas_map_pairings (
  id          uuid primary key default gen_random_uuid(),
  code_hash   text not null unique,
  label       text,
  created_by  uuid not null references auth.users(id) on delete cascade,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  server_id   uuid references public.nas_map_servers(id) on delete set null,
  created_at  timestamptz not null default now()
);
alter table public.nas_map_pairings enable row level security;
revoke all on public.nas_map_pairings from anon, authenticated;

create table if not exists public.nas_map_pair_failures (
  at timestamptz not null default now()
);
create index if not exists nas_map_pair_failures_at_idx on public.nas_map_pair_failures (at);
alter table public.nas_map_pair_failures enable row level security;
revoke all on public.nas_map_pair_failures from anon, authenticated;

-- A full admin makes a code: the NAS's tunnel secret passes through it.
create or replace function public.admin_nas_maps_pairing_code(p_label text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_bytes bytea := extensions.gen_random_bytes(8);
  v_code text := '';
  v_expires timestamptz := now() + interval '10 minutes';
begin
  if not public.caller_is_full_admin() then
    raise exception 'Only a full admin can connect the NAS maps.' using errcode = '42501';
  end if;
  for i in 0..7 loop
    v_code := v_code || substr(v_alphabet, 1 + (get_byte(v_bytes, i) % length(v_alphabet)), 1);
  end loop;
  delete from public.nas_map_pairings where created_by = auth.uid() and used_at is null;
  insert into public.nas_map_pairings (code_hash, label, created_by, expires_at)
  values (public.gateway_secret_hash(v_code), nullif(left(btrim(coalesce(p_label, '')), 80), ''), auth.uid(),
          v_expires);
  return jsonb_build_object('code', substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4), 'expires_at', v_expires);
end;
$$;
revoke execute on function public.admin_nas_maps_pairing_code(text) from public, anon;
grant execute on function public.admin_nas_maps_pairing_code(text) to authenticated;

create or replace function public.admin_nas_maps_remove(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_is_full_admin() then
    raise exception 'Only a full admin can disconnect the NAS maps.' using errcode = '42501';
  end if;
  delete from public.nas_map_servers where id = p_id;
  -- No server left: the heartbeat row goes too, so nothing shows it online.
  if not exists (select 1 from public.nas_map_servers) then
    delete from public.nas_services where service = 'maps';
  end if;
end;
$$;
revoke execute on function public.admin_nas_maps_remove(uuid) from public, anon;
grant execute on function public.admin_nas_maps_remove(uuid) to authenticated;

-- An https base address (no path, query or credentials), or null.
create or replace function public.nas_maps_url(p text)
returns text
language sql
immutable
set search_path = public
as $$
  select case when btrim(coalesce(p, '')) ~ '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$'
              then rtrim(btrim(p), '/') end;
$$;
revoke execute on function public.nas_maps_url(text) from public, anon, authenticated;

create or replace function public.nas_maps_pair(
  p_code text, p_device_id text, p_label text default null, p_model text default null,
  p_app_version text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_pair public.nas_map_pairings;
  v_server public.nas_map_servers;
  v_key text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  if (select count(*) from public.nas_map_pair_failures where at > now() - interval '10 minutes') >= 20 then
    return jsonb_build_object('error', 'NAS_PAIR_BUSY', 'hint', 'Too many wrong codes. Wait 10 minutes and try again.');
  end if;
  if coalesce(btrim(p_device_id), '') = '' then
    return jsonb_build_object('error', 'NAS_PAIR_DEVICE', 'hint', 'The NAS sent no device id.');
  end if;
  select * into v_pair from public.nas_map_pairings
   where code_hash = public.gateway_secret_hash(v_code) and used_at is null and expires_at > now()
   for update;
  if not found then
    insert into public.nas_map_pair_failures default values;
    return jsonb_build_object('error', 'NAS_PAIR_CODE',
      'hint', 'That code is wrong or has expired. Make a new one in Admin -> Settings -> Office NAS -> Maps.');
  end if;
  insert into public.nas_map_servers (label, device_id, model, app_version, key_hash, paired_by, last_seen_at)
  values (coalesce(v_pair.label, nullif(left(btrim(coalesce(p_label, '')), 80), ''), 'Office NAS'),
          left(p_device_id, 200), left(p_model, 120), left(p_app_version, 40),
          public.gateway_secret_hash(v_key), v_pair.created_by, now())
  on conflict (device_id) do update
     set label = coalesce(v_pair.label, public.nas_map_servers.label),
         model = coalesce(excluded.model, public.nas_map_servers.model),
         app_version = excluded.app_version,
         key_hash = excluded.key_hash,
         paired_by = excluded.paired_by,
         last_seen_at = now()
  returning * into v_server;
  update public.nas_map_pairings set used_at = now(), server_id = v_server.id where id = v_pair.id;
  return jsonb_build_object('key', v_key, 'server', v_server.id, 'label', v_server.label);
end;
$$;

-- The NAS a key belongs to; refuses an unknown (or removed) key.
create or replace function public.nas_maps_by_key(p_key text)
returns public.nas_map_servers
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.nas_map_servers;
begin
  update public.nas_map_servers set last_seen_at = now()
   where key_hash = public.gateway_secret_hash(p_key)
  returning * into v;
  if not found then
    raise exception 'NAS_KEY_INVALID' using errcode = '42501',
      hint = 'This NAS is no longer connected. Connect it again from Admin -> Settings -> Office NAS -> Maps.';
  end if;
  return v;
end;
$$;

-- Check-in, every minute. p_status 'ok' | 'degraded' | 'refreshing' | 'down';
-- p_detail {osrm: {ok, ms}, photon: {ok, ms}, tiles: {ok, ms, bytes}, refresh: {...}, data: {...}}
-- (at most 20 kB; never the secret). Answers the settings, so the NAS can
-- say on its own page what is switched on.
create or replace function public.nas_maps_heartbeat(
  p_key text, p_status text, p_detail jsonb default null, p_model text default null,
  p_app_version text default null, p_maps_url text default null, p_tiles_url text default null,
  p_secret text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.nas_map_servers := public.nas_maps_by_key(p_key);
  v_status text := case when p_status in ('ok', 'degraded', 'refreshing', 'down') then p_status else 'degraded' end;
  v_detail jsonb := case when jsonb_typeof(p_detail) = 'object' then p_detail else '{}' end;
begin
  if length(v_detail::text) > 20000 then
    v_detail := jsonb_build_object('error', 'detail too large');
  end if;
  update public.nas_map_servers
     set model = coalesce(left(p_model, 120), model),
         app_version = coalesce(left(p_app_version, 40), app_version),
         maps_url = coalesce(public.nas_maps_url(p_maps_url), maps_url),
         tiles_url = coalesce(public.nas_maps_url(p_tiles_url), tiles_url),
         gateway_secret = case when length(btrim(coalesce(p_secret, ''))) between 32 and 200
                               then btrim(p_secret) else gateway_secret end
   where id = v.id
  returning * into v;
  insert into public.nas_services (service, last_seen, status, detail, version)
  values ('maps', now(), v_status,
          v_detail || jsonb_build_object('server', v.id, 'label', v.label, 'model', v.model,
                                         'mapsUrl', v.maps_url, 'tilesUrl', v.tiles_url,
                                         'secretSet', v.gateway_secret is not null),
          left(p_app_version, 40))
  on conflict (service) do update
     set last_seen = excluded.last_seen, status = excluded.status, detail = excluded.detail,
         version = excluded.version;
  return jsonb_build_object('server', v.id, 'label', v.label, 'settings', public.nas_maps_settings()->'default');
end;
$$;

revoke execute on function public.nas_maps_pair(text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.nas_maps_by_key(text) from public, anon, authenticated;
revoke execute on function public.nas_maps_heartbeat(text, text, jsonb, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.nas_maps_pair(text, text, text, text, text) to service_role;
grant execute on function public.nas_maps_heartbeat(text, text, jsonb, text, text, text, text, text) to service_role;

-- ---- 5. What the NAS answered -----------------------------------------------------------------
create table if not exists public.nas_maps_daily (
  day        date not null default current_date,
  kind       text not null check (kind in ('routing', 'distance', 'search', 'reverse')),
  served     integer not null default 0,
  failed     integer not null default 0,
  timed_out  integer not null default 0,
  ms_total   bigint not null default 0,
  primary key (day, kind)
);
alter table public.nas_maps_daily enable row level security;
revoke all on public.nas_maps_daily from anon, authenticated;

-- One call to the NAS: answered (p_ok), else failed, or timed out.
create or replace function public.nas_maps_count(p_kind text, p_ok boolean, p_ms integer, p_timed_out boolean default false)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.nas_maps_daily as d (kind, served, failed, timed_out, ms_total)
  select p_kind,
         case when p_ok then 1 else 0 end,
         case when not p_ok and not coalesce(p_timed_out, false) then 1 else 0 end,
         case when not p_ok and coalesce(p_timed_out, false) then 1 else 0 end,
         case when p_ok then greatest(0, least(coalesce(p_ms, 0), 60000)) else 0 end
   where p_kind in ('routing', 'distance', 'search', 'reverse')
  on conflict (day, kind) do update
     set served = d.served + excluded.served,
         failed = d.failed + excluded.failed,
         timed_out = d.timed_out + excluded.timed_out,
         ms_total = d.ms_total + excluded.ms_total;
$$;
revoke execute on function public.nas_maps_count(text, boolean, integer, boolean) from public, anon, authenticated;
grant execute on function public.nas_maps_count(text, boolean, integer, boolean) to service_role;

-- ---- 6. What the geo function needs -----------------------------------------------------------
-- The NAS last heard from, with the rule at [p_lat, p_lng] (the Default rule
-- without a point). online: checked in within 3 minutes and not down; each
-- part is on only when the rule says so and its service said it was well.
-- Null when no NAS is paired, or it hasn't told its tunnel address yet.
create or replace function public.nas_maps_link(p_lat double precision default null, p_lng double precision default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  s public.nas_map_servers;
  h public.nas_services;
  v_rule jsonb := public.nas_maps_rule_at(p_lat, p_lng);
  v_online boolean;
begin
  select * into s from public.nas_map_servers
   where maps_url is not null and gateway_secret is not null
   order by last_seen_at desc nulls last limit 1;
  if not found then
    return null;
  end if;
  select * into h from public.nas_services where service = 'maps';
  v_online := coalesce(h.last_seen > now() - interval '3 minutes' and h.status <> 'down', false);
  return jsonb_build_object(
    'url', s.maps_url,
    'tilesUrl', s.tiles_url,
    'secret', s.gateway_secret,
    'online', v_online,
    'routes', v_online and (v_rule->>'routes')::boolean and coalesce((h.detail #>> '{osrm,ok}')::boolean, false),
    'search', v_online and (v_rule->>'search')::boolean and coalesce((h.detail #>> '{photon,ok}')::boolean, false),
    'tiles', v_online and (v_rule->>'tiles')::boolean and s.tiles_url is not null
             and coalesce((h.detail #>> '{tiles,ok}')::boolean, false),
    'timeoutMs', (v_rule->>'timeoutMs')::int);
end;
$$;
revoke execute on function public.nas_maps_link(double precision, double precision) from public, anon, authenticated;
grant execute on function public.nas_maps_link(double precision, double precision) to service_role;

-- ---- 7. The admin's tab -----------------------------------------------------------------------
create or replace function public.admin_nas_maps_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_per jsonb;
begin
  if not public.caller_is_admin() then
    raise exception 'Admins only.' using errcode = '42501';
  end if;
  select coalesce(jsonb_object_agg(d.kind, jsonb_build_object(
           'today', jsonb_build_object('served', d.t_served, 'failed', d.t_failed, 'timedOut', d.t_timed,
                                      'avgMs', case when d.t_served > 0 then round(d.t_ms::numeric / d.t_served) end),
           'days30', jsonb_build_object('served', d.m_served, 'failed', d.m_failed, 'timedOut', d.m_timed,
                                       'avgMs', case when d.m_served > 0 then round(d.m_ms::numeric / d.m_served) end))),
         '{}')
    into v_per
    from (
      select kind,
             sum(served) filter (where day = current_date) as t_served,
             sum(failed) filter (where day = current_date) as t_failed,
             sum(timed_out) filter (where day = current_date) as t_timed,
             sum(ms_total) filter (where day = current_date) as t_ms,
             sum(served) as m_served, sum(failed) as m_failed, sum(timed_out) as m_timed, sum(ms_total) as m_ms
        from public.nas_maps_daily
       where day > current_date - 30
       group by kind
    ) d;
  return jsonb_build_object(
    'settings', public.nas_maps_settings(),
    'service', (select jsonb_build_object('last_seen', n.last_seen, 'status', n.status, 'detail', n.detail,
                                          'version', n.version,
                                          'online', coalesce(n.last_seen > now() - interval '3 minutes', false))
                  from public.nas_services n where n.service = 'maps'),
    'servers', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'label', s.label, 'model', s.model, 'app_version', s.app_version,
               'created_at', s.created_at, 'last_seen_at', s.last_seen_at,
               'online', coalesce(s.last_seen_at > now() - interval '3 minutes', false),
               'maps_url', s.maps_url, 'tiles_url', s.tiles_url,
               'secret_set', s.gateway_secret is not null)
             order by s.created_at)
        from public.nas_map_servers s), '[]'),
    'usage', v_per);
end;
$$;
revoke execute on function public.admin_nas_maps_status() from public, anon;
grant execute on function public.admin_nas_maps_status() to authenticated;

-- ---- Housekeeping -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'purge-nas-maps';
    perform cron.schedule('purge-nas-maps', '29 * * * *', $job$
      delete from public.nas_map_pairings where expires_at < now() - interval '1 day';
      delete from public.nas_map_pair_failures where at < now() - interval '1 day';
      delete from public.nas_maps_daily where day < current_date - 400;
    $job$);
  end if;
end $$;

notify pgrst, 'reload schema';
