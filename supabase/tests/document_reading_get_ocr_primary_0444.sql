-- ============================================================================
-- Regression test for migration 0444: get.ocr is the primary document reader.
-- A fresh config leads with get.ocr (on); a reader missing from a saved list
-- joins on (get.ocr included); and the one-time move leads an existing chain
-- with get.ocr while keeping the admin's order and switches for the rest.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/document_reading_get_ocr_primary_0444.sql
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

-- 1. A fresh config leads with get.ocr, on.
select pg_temp.check(
  (select string_agg(r->>'id', ',') from jsonb_array_elements(public.document_reading_normalize('{}')->'readers') r)
    = 'getOcr,phone,nas,gpu,cloud',
  'fresh order leads with get.ocr');
select pg_temp.check(
  (public.document_reading_normalize('{}')->'readers'->0->>'id') = 'getOcr'
  and (public.document_reading_normalize('{}')->'readers'->0->>'on')::boolean,
  'get.ocr is first and on by default');

-- 2. A reader missing from a saved list joins on, get.ocr included; the saved
--    order and switches are kept.
select pg_temp.check(
  (select string_agg((r->>'id')||':'||(r->>'on'), ',')
     from jsonb_array_elements(public.document_reading_normalize(
       '{"readers":[{"id":"cloud","on":false},{"id":"phone","on":true}]}')->'readers') r)
    = 'cloud:false,phone:true,getOcr:true,nas:true,gpu:true',
  'missing readers join on, get.ocr included');

-- 3. The one-time move leads an existing chain with get.ocr (on), keeping the
--    admin's order and switches for the rest (the same update the migration runs).
delete from public.app_settings where key = 'document_reading';
insert into public.app_settings (key, value) values ('document_reading',
  '{"readers":[{"id":"phone","on":true},{"id":"nas","on":false},{"id":"gpu","on":true},
    {"id":"cloud","on":true},{"id":"getOcr","on":false}],"passOnBelow":90}');
update public.app_settings
set value = jsonb_set(
  public.document_reading_normalize(value),
  '{readers}',
  jsonb_build_array(jsonb_build_object('id', 'getOcr', 'on', true))
    || coalesce((
         select jsonb_agg(r order by ord)
         from jsonb_array_elements(public.document_reading_normalize(value) -> 'readers')
              with ordinality as t(r, ord)
         where r ->> 'id' <> 'getOcr'
       ), '[]'::jsonb))
where key = 'document_reading';
select pg_temp.check(
  (select string_agg((r->>'id')||':'||(r->>'on'), ',')
     from jsonb_array_elements((select value from public.app_settings where key = 'document_reading')->'readers') r)
    = 'getOcr:true,phone:true,nas:false,gpu:true,cloud:true',
  'get.ocr moved to the front and on; the rest kept in order and state');

rollback;
