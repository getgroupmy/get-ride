-- ============================================================================
-- Regression test for migration 0119: a ride's pricing columns take only
-- sensible values.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ride_region_pricing.sql
--
-- Read-only. A failed assertion raises.
-- ============================================================================
do $$
declare
  c record;
begin
  for c in
    select * from (values
      ('whole_fare', 'boolean'),
      ('tax_name', 'text'),
      ('tax_kind', 'text'),
      ('tax_value', 'numeric')
    ) as t(col, typ)
  loop
    if not exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'ride_requests' and column_name = c.col and data_type = c.typ
    ) then
      raise exception 'FAILED: ride_requests.% (%) missing', c.col, c.typ;
    end if;
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'ride_requests_tax_percent') then
    raise exception 'FAILED: no cap on a percentage tax';
  end if;
end
$$;

select 'ride_region_pricing: all passed';
