-- ============================================================================
-- Regression test for migration 0319: own maps on the office NAS.
-- 'nas' in Admin → Maps (lists everywhere, the map on the web only); the
-- Default and region rules (most specific wins, a region overrides only what
-- it sets, timeout kept to 300..5000 ms); who may change them; pairing with
-- a one-time code; the heartbeat (nas_services 'maps', the secret kept from
-- admins); what the geo function is told (offline after 3 minutes, a part
-- off when its service is down); the usage counts; removing the NAS.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/nas_maps_0319.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;
create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
create or replace function pg_temp.as_db() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'FAILED: % was allowed', p_what;
exception when insufficient_privilege then
  null;
end $$;

delete from public.app_settings where key = 'nas_maps';
delete from public.nas_services where service = 'maps';
delete from public.nas_map_servers;
delete from public.nas_maps_daily;

-- 1. 'nas' in Admin → Maps ------------------------------------------------------------------
create temp table m on commit drop as select public.map_config_clean('{"profiles": {
  "rider.web": {"tiles": {"light": "nas", "dark": "nas", "satellite": "nas"},
                "routing": ["nas", "google", "nas", "osrm"], "distance": ["nas", "straight"],
                "search": ["nas", "google"], "reverse": ["nas"], "locate": ["nas", "amazon", "evil"]},
  "rider.android": {"tiles": {"light": "nas"}, "routing": ["nas", "google"]},
  "partner.ios": {"routing": ["google", "osrm"]}
}}') v;
select pg_temp.check((select v->'profiles'->'rider.web'->'routing' = '["nas", "google", "osrm"]' from m),
  'routes: the NAS then Google, once each');
select pg_temp.check((select v->'profiles'->'rider.web'->'distance' = '["nas", "straight"]'
                         and v->'profiles'->'rider.web'->'search' = '["nas", "google"]'
                         and v->'profiles'->'rider.web'->'reverse' = '["nas"]'
                         and v->'profiles'->'rider.web'->'locate' = '["nas", "amazon"]' from m),
  'distance, search, address lookup and locate take the NAS too; unknown names dropped');
select pg_temp.check((select v->'profiles'->'rider.web'->'tiles'->>'light' = 'nas'
                         and v->'profiles'->'rider.web'->'tiles'->>'dark' = 'nas'
                         and v->'profiles'->'rider.web'->'tiles'->>'satellite' = 'app' from m),
  'the NAS map on the web, for Map and Map (dark mode); it has no imagery');
select pg_temp.check((select v->'profiles'->'rider.android'->'tiles'->>'light' = 'app'
                         and v->'profiles'->'rider.android'->'routing' = '["nas", "google"]' from m),
  'phones keep their map, and may ask the NAS for routes');
select pg_temp.check((select v->'profiles'->'partner.ios'->'routing' = '["google", "osrm"]'
                         and v->'profiles'->'partner.web'->'routing' = '["osrm"]' from m),
  'profiles without the NAS are as before');

-- 2. The rules -------------------------------------------------------------------------------
select pg_temp.check(public.nas_maps_settings()->'default' = '{"routes": true, "search": true, "tiles": true, "timeoutMs": 1500}',
  'Default: everything on, 1.5 s');
select pg_temp.check(public.nas_maps_settings()->'googleCost' = '{"route": 5, "search": 17}', 'Google prices by default');
create temp table cfg on commit drop as select '{
  "default": {"routes": true, "search": true, "tiles": false, "timeoutMs": 99999},
  "regions": [
    {"country": "Malaysia", "search": false},
    {"country": "Malaysia", "state": "Sabah", "routes": false, "timeoutMs": 2500},
    {"country": "Malaysia", "state": "Sabah", "city": "Kota Kinabalu", "routes": true},
    {"country": "Malaysia", "city": "Ipoh", "routes": false},
    {"country": "", "routes": false},
    {"country": "Brunei", "tiles": true, "timeoutMs": 120}
  ]}'::jsonb as c;
select pg_temp.check((select public.nas_maps_normalize(c)->'default'->>'timeoutMs' = '5000' from cfg),
  'timeout at most 5 s');
select pg_temp.check((select jsonb_array_length(public.nas_maps_normalize(c)->'regions') = 4 from cfg),
  'a region needs its country and each level its parent');
select pg_temp.check((select public.nas_maps_normalize(c)->'regions'->0 = '{"country": "Malaysia", "state": null,
  "city": null, "suburb": null, "search": false}' from cfg), 'a region rule keeps only what it sets');
select pg_temp.check((select public.nas_maps_rule(c, 'Singapore') = '{"routes": true, "search": true, "tiles": false,
  "timeoutMs": 5000, "region": null}' from cfg), 'no region rule: the Default');
select pg_temp.check((select public.nas_maps_rule(c, 'malaysia', 'Selangor') @> '{"routes": true, "search": false,
  "region": "Malaysia"}' from cfg), 'a country rule overrides only search');
select pg_temp.check((select public.nas_maps_rule(c, 'Malaysia', 'Sabah', 'Sandakan') @> '{"routes": false,
  "search": false, "timeoutMs": 2500, "region": "Sabah, Malaysia"}' from cfg), 'the state rule on top of the country''s');
select pg_temp.check((select public.nas_maps_rule(c, 'Malaysia', 'Sabah', 'Kota Kinabalu', 'Likas') @> '{"routes": true,
  "search": false, "timeoutMs": 2500, "region": "Kota Kinabalu, Sabah, Malaysia"}' from cfg), 'the most specific wins');
select pg_temp.check((select public.nas_maps_rule(c, 'Brunei') @> '{"tiles": true, "timeoutMs": 300}' from cfg),
  'timeout at least 300 ms');
select pg_temp.check(public.nas_maps_rule_at(null, null) @> '{"routes": true, "region": null}', 'no point: the Default');

-- 3. Who may change them --------------------------------------------------------------------
insert into auth.users (id) values
  ('00000000-0000-0000-0000-000000319a01'),  -- full admin
  ('00000000-0000-0000-0000-000000319a02'),  -- sub-admin with the page
  ('00000000-0000-0000-0000-000000319a03'),  -- sub-admin, another page
  ('00000000-0000-0000-0000-000000319a04')   -- rider
on conflict do nothing;
insert into public.profiles (id) values
  ('00000000-0000-0000-0000-000000319a01'), ('00000000-0000-0000-0000-000000319a02'),
  ('00000000-0000-0000-0000-000000319a03'), ('00000000-0000-0000-0000-000000319a04')
on conflict (id) do update set id = excluded.id;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-000000319a01', '*', 'edit'),
  ('00000000-0000-0000-0000-000000319a02', 'admin-settings-office-nas', 'edit'),
  ('00000000-0000-0000-0000-000000319a03', 'admin-settings-maps', 'edit')
on conflict do nothing;

select pg_temp.as_user('00000000-0000-0000-0000-000000319a02');
select pg_temp.check((public.admin_nas_maps_set((select c from cfg))->'default'->>'tiles') = 'false',
  'a sub-admin with the Office NAS page saves the rules');
select pg_temp.check(public.nas_maps_config()->'regions'->1->>'state' = 'Sabah', 'and reads them back');
select pg_temp.refused($q$select public.admin_nas_maps_pairing_code('DS224+')$q$, 'a sub-admin connecting the NAS');
select pg_temp.as_user('00000000-0000-0000-0000-000000319a03');
select pg_temp.refused($q$select public.admin_nas_maps_set('{}')$q$, 'another page''s sub-admin changing the rules');
select pg_temp.as_user('00000000-0000-0000-0000-000000319a04');
select pg_temp.refused($q$select public.nas_maps_config()$q$, 'a rider reading the rules');
select pg_temp.refused($q$select public.admin_nas_maps_status()$q$, 'a rider reading the NAS status');
select pg_temp.check(not has_function_privilege('authenticated', 'public.nas_maps_link(double precision, double precision)',
  'execute'), 'only the geo function reads the link');
select pg_temp.check(not has_function_privilege('authenticated',
  'public.nas_maps_heartbeat(text, text, jsonb, text, text, text, text, text)', 'execute')
  and not has_function_privilege('anon', 'public.nas_maps_pair(text, text, text, text, text)', 'execute'),
  'only the nas-maps function pairs and checks in');
select pg_temp.check(not has_table_privilege('authenticated', 'public.nas_map_servers', 'select'),
  'nobody in the app reads the servers table (it holds the secret)');

-- 4. Pairing -------------------------------------------------------------------------------
select pg_temp.as_db();
select pg_temp.check(public.nas_maps_link() is null, 'nothing paired: no link');
select pg_temp.as_user('00000000-0000-0000-0000-000000319a01');
create temp table code_t on commit drop as select public.admin_nas_maps_pairing_code('DS224+') ->> 'code' as code;
select pg_temp.check((select code ~ '^[A-Z2-9]{4}-[A-Z2-9]{4}$' from code_t), 'code shown as XXXX-XXXX');
select pg_temp.as_db();
select pg_temp.check((public.nas_maps_pair('WRONG-CODE', 'nas-1') ->> 'error') = 'NAS_PAIR_CODE', 'a wrong code');
create temp table key_t on commit drop as
  select public.nas_maps_pair((select lower(code) from code_t), 'nas-1', null, 'DS224+ J4125', '1.0.0') as r;
select pg_temp.check((select r ? 'key' and r->>'label' = 'DS224+' from key_t), 'the code gives a key, with the label');
select pg_temp.check((public.nas_maps_pair((select code from code_t), 'nas-2') ->> 'error') = 'NAS_PAIR_CODE',
  'a code works once');
select pg_temp.check((select key_hash <> (select r->>'key' from key_t) from public.nas_map_servers), 'only a hash is kept');
select pg_temp.check(public.nas_maps_link() is null, 'no tunnel address yet: no link');

-- 5. Heartbeat -----------------------------------------------------------------------------
do $$
begin
  perform public.nas_maps_heartbeat('wrong-key', 'ok');
  raise exception 'FAILED: an unknown key checked in';
exception when insufficient_privilege then null;
end $$;
select public.nas_maps_heartbeat((select r->>'key' from key_t), 'degraded',
  '{"osrm": {"ok": true, "ms": 80}, "photon": {"ok": false}, "tiles": {"ok": true, "bytes": 1200000000}}',
  'DS224+ J4125', '1.0.1', 'https://maps.example.my/', 'https://tiles.example.my', repeat('s', 64));
select pg_temp.check((select status = 'degraded' and version = '1.0.1' and detail->>'mapsUrl' = 'https://maps.example.my'
                         and not detail::text like '%ssss%' and (detail->>'secretSet')::boolean
                         from public.nas_services where service = 'maps'),
  'nas_services shows the check-in, never the secret');
select pg_temp.check((select l->>'url' = 'https://maps.example.my' and l->>'secret' = repeat('s', 64)
                         and (l->>'online')::boolean and (l->>'routes')::boolean and not (l->>'search')::boolean
                         and not (l->>'tiles')::boolean and (l->>'timeoutMs')::int = 5000
                         from (select public.nas_maps_link() l) x),
  'the geo function: routes on; search off (Photon down); tiles off (the Default rule)');
select public.nas_maps_heartbeat((select r->>'key' from key_t), 'ok', '{}', null, null,
  'http://insecure.example', 'not a url', 'short');
select pg_temp.check((select maps_url = 'https://maps.example.my' and tiles_url = 'https://tiles.example.my'
                         and gateway_secret = repeat('s', 64) from public.nas_map_servers),
  'bad addresses and a short secret are not taken');
update public.nas_services set last_seen = now() - interval '4 minutes' where service = 'maps';
select pg_temp.check((select not (l->>'online')::boolean and not (l->>'routes')::boolean
                         from (select public.nas_maps_link() l) x), 'not heard from in 3 minutes: offline');

-- 6. Usage ---------------------------------------------------------------------------------
select public.nas_maps_count('routing', true, 80);
select public.nas_maps_count('routing', true, 120);
select public.nas_maps_count('routing', false, 1500, true);
select public.nas_maps_count('search', false, 0);
select public.nas_maps_count('evil', true, 1);
select pg_temp.as_user('00000000-0000-0000-0000-000000319a03');
select pg_temp.check((select s->'usage'->'routing'->'today' = '{"served": 2, "failed": 0, "timedOut": 1, "avgMs": 100}'
                         and s->'usage'->'search'->'today'->>'failed' = '1'
                         and not s->'usage' ? 'evil'
                         and jsonb_array_length(s->'servers') = 1
                         and not (s->'servers'->0)::text like '%ssss%'
                         and (s->'servers'->0->>'secret_set')::boolean
                         from (select public.admin_nas_maps_status() s) x),
  'any admin reads the counts and the NAS, without its secret');
set local role authenticated;
select pg_temp.check(exists (select 1 from public.nas_services where service = 'maps'), 'admins read the heartbeat');
select pg_temp.as_user('00000000-0000-0000-0000-000000319a04');
select pg_temp.check(not exists (select 1 from public.nas_services), 'a rider does not');
reset role;
select pg_temp.as_user('00000000-0000-0000-0000-000000319a03');

-- 7. Removing it ---------------------------------------------------------------------------
select pg_temp.refused($q$select public.admin_nas_maps_remove((select id from public.nas_map_servers))$q$,
  'a sub-admin disconnecting the NAS');
select pg_temp.as_user('00000000-0000-0000-0000-000000319a01');
select public.admin_nas_maps_remove((select id from public.nas_map_servers));
select pg_temp.as_db();
select pg_temp.check(not exists (select 1 from public.nas_map_servers)
                     and not exists (select 1 from public.nas_services where service = 'maps')
                     and public.nas_maps_link() is null, 'disconnected: key, heartbeat and link gone');
do $$
begin
  perform public.nas_maps_heartbeat((select r->>'key' from key_t), 'ok');
  raise exception 'FAILED: a removed NAS checked in';
exception when insufficient_privilege then null;
end $$;

select 'nas_maps_0319: all passed';
rollback;
