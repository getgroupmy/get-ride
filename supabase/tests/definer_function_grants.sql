-- ============================================================================
-- Regression test for migration 0103: three SECURITY DEFINER functions that
-- the client must not be able to call.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/definer_function_grants.sql
--
-- Read-only. A failed assertion raises an exception.
-- ============================================================================
do $$
declare
  r record;
begin
  for r in
    select * from (values
      ('public.fare_ai_record_usage(text, text, boolean, timestamptz, text)', 'anon',          false),
      ('public.fare_ai_record_usage(text, text, boolean, timestamptz, text)', 'authenticated', false),
      ('public.fare_ai_record_usage(text, text, boolean, timestamptz, text)', 'service_role',  true),
      ('public.expire_documents_daily()',                                     'anon',          false),
      ('public.expire_documents_daily()',                                     'authenticated', false),
      ('public.expire_documents_daily()',                                     'service_role',  true),
      ('public.admin_access_bootstrap()',                                     'anon',          false),
      ('public.admin_access_bootstrap()',                                     'authenticated', true)
    ) as t(fn, role, expected)
  loop
    if has_function_privilege(r.role, r.fn, 'execute') is distinct from r.expected then
      raise exception '% EXECUTE for % should be %', r.fn, r.role, r.expected;
    end if;
  end loop;
end
$$;

select 'definer_function_grants: all passed';
