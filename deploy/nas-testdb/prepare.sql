-- ============================================================================
-- GET.ride test copy: what a fresh database needs before last night's
-- backup is restored into it (deploy/nas-testdb, runner.py).
--
-- The database container is Supabase's own Postgres image, so the roles
-- (anon, authenticated, service_role, authenticator, supabase_admin,
-- supabase_auth_admin, supabase_storage_admin …) already exist in the
-- cluster. A new database still needs the extensions schema and the
-- extensions the migrations use. pg_cron is not added: it lives in the
-- "postgres" database only, the migrations check for it before scheduling,
-- and a test copy must not run the live jobs anyway.
--
-- The database container has no internet (docker-compose.yml: an internal
-- network), so pg_net calls a migration makes go nowhere.
-- ============================================================================

create schema if not exists extensions;
grant usage on schema extensions to public;

do $$
declare
  e text;
begin
  foreach e in array array['pgcrypto', 'uuid-ossp', 'pg_trgm', 'pgjwt', 'pg_stat_statements', 'pg_net'] loop
    begin
      execute format('create extension if not exists %I with schema extensions', e);
    exception when others then
      begin
        -- pg_net (and a few others) keep their own schema.
        execute format('create extension if not exists %I', e);
      exception when others then
        raise notice 'extension % not added: %', e, sqlerrm;
      end;
    end;
  end loop;
end $$;
