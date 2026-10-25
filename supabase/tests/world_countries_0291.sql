-- ============================================================================
-- Regression test for migration 0291: every country in the world is listed
-- under Admin › Country / States / Cities, once each, with its ISO code, and
-- the ones added are blocked for pickups and drop-offs until the admin opens
-- them.
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

-- All 249 ISO 3166-1 codes, each on one country.
select pg_temp.check(
  (select count(distinct upper(values->>'isoCode')) from public.countries where coalesce(values->>'isoCode', '') <> '') = 249,
  'every ISO country has a row with its code');
select pg_temp.check(
  not exists (
    select 1 from public.countries where coalesce(values->>'isoCode', '') <> ''
     group by upper(values->>'isoCode') having count(*) > 1),
  'no code is on two countries');

-- A country added by 0291 is closed: no ride starts, stops or ends there.
select pg_temp.check(
  (select public.region_blocks(values, true) and public.region_blocks(values, false)
     from public.countries where values->>'isoCode' = 'NO' and name = 'Norway'),
  'Norway is listed and blocked for pickups and drop-offs');

-- Known names keep their spelling.
select pg_temp.check(
  exists (select 1 from public.countries where name = 'Côte d''Ivoire' and values->>'isoCode' = 'CI'),
  'names with accents are stored as written');

rollback;
