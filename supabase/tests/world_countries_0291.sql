-- ============================================================================
-- Regression test for migration 0291: every country in the world is listed
-- under Admin › Country / States / Cities, once each, with its ISO code; the
-- ones added are blocked for pickups and drop-offs until the admin opens
-- them; countries already listed keep their settings; and with no country
-- listed at all nothing is added (every place stays served).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/world_countries_0291.sql
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

-- The callers of the app can't run it.
select pg_temp.check(
  not has_function_privilege('authenticated', 'public.regions_add_world_countries()', 'execute')
  and not has_function_privilege('anon', 'public.regions_add_world_countries()', 'execute'),
  'only the database owner adds the world list');

-- With no country listed, the migration added none: everywhere is still served.
delete from public.countries;
select pg_temp.check(
  public.ride_point_gap(48.8566, 2.3522, 'France', null, null, null) is null,
  'with no regions a point anywhere is served');

-- An admin who has listed Malaysia (open, with its own settings) and the UAE
-- by its short name.
insert into public.countries (name, values, position) values
  ('Malaysia', '{"timezone": "Asia/Kuala_Lumpur", "callingCode": "+60"}', 10),
  ('UAE', '{}', 20);

select pg_temp.check(public.regions_add_world_countries() = 247, 'the 247 not yet listed are added');
select pg_temp.check(public.regions_add_world_countries() = 0, 'a second run adds nothing');

select pg_temp.check((select count(*) from public.countries) = 249, 'one row per country');
select pg_temp.check(
  (select count(distinct upper(values->>'isoCode')) from public.countries) = 249,
  'every country has its code');

-- The listed ones keep everything and gain their code.
select pg_temp.check(
  (select values from public.countries where name = 'Malaysia')
    = '{"timezone": "Asia/Kuala_Lumpur", "callingCode": "+60", "isoCode": "MY"}'::jsonb,
  'Malaysia keeps its settings and stays open');
select pg_temp.check(
  (select values from public.countries where name = 'UAE') = '{"isoCode": "AE"}'::jsonb,
  'the UAE is matched by its short name, not added again');
select pg_temp.check(
  not exists (select 1 from public.countries where name = 'United Arab Emirates'),
  'no second United Arab Emirates');

-- An added one is closed: no ride starts, stops or ends there.
select pg_temp.check(
  (select public.region_blocks(values, true) and public.region_blocks(values, false)
     from public.countries where name = 'Norway' and values->>'isoCode' = 'NO'),
  'Norway is listed and blocked for pickups and drop-offs');
select pg_temp.check(
  exists (select 1 from public.countries where name = 'Côte d''Ivoire' and values->>'isoCode' = 'CI'),
  'names with accents are stored as written');

rollback;
