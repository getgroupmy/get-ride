-- ============================================================================
-- 0240 — pg_net is not for the API roles
--
-- Supabase's pg_net setup (extensions.grant_pg_net_access, run when the
-- extension is created) grants USAGE on schema net and EXECUTE on
-- net.http_get / net.http_post to anon and authenticated, and the extension
-- leaves the other net.* functions and both net tables
-- (http_request_queue, _http_response) open to PUBLIC. http_get and
-- http_post are SECURITY DEFINER, so any caller that reaches them makes the
-- database send an HTTP request (SSRF), and could read or clear other
-- requests' responses. Today the net schema is not exposed through the API
-- (config.toml: public and graphql_public only), so nothing reaches it, but
-- nothing should be able to.
--
-- The app never calls net.* as anon or authenticated. The one function that
-- does, public.send_push_webhook, is SECURITY DEFINER owned by postgres, and
-- postgres keeps every grant below, so pushes keep going. Database Webhooks
-- (supabase_functions.http_request) run as supabase_functions_admin, which
-- keeps its grants too.
--
-- The catch: those grants were made by supabase_admin, and only
-- supabase_admin (a superuser) can revoke them. Migrations run as postgres,
-- which cannot, so this migration defines the lock-down as
-- public.net_api_roles_revoke() and runs it only when it can. Otherwise it
-- warns and changes nothing; on the hosted project, Supabase support (or
-- anyone with the superuser) runs, once:
--
--     select public.net_api_roles_revoke();
--
-- It is safe to re-run, and needs re-running if pg_net is ever dropped and
-- created again, since the creation grants come back with it. CI runs it as
-- supabase_admin on the local stack, and supabase/tests/net_grants.sql
-- checks the result.
-- ============================================================================

create or replace function public.net_api_roles_revoke()
returns void
language plpgsql
security invoker
set search_path = pg_catalog
as $$
declare
  v_keep text;
begin
  if not exists (select 1 from pg_namespace where nspname = 'net') then
    return;  -- pg_net is not installed
  end if;

  revoke execute on all functions in schema net from public, anon, authenticated;
  revoke all on all tables in schema net from public, anon, authenticated;
  revoke all on all sequences in schema net from public, anon, authenticated;
  revoke usage on schema net from public, anon, authenticated;

  -- What PUBLIC used to give the roles that do use pg_net, given by name.
  select string_agg(quote_ident(rolname), ', ') into v_keep
    from pg_roles where rolname in ('postgres', 'service_role', 'supabase_functions_admin');
  execute format('grant usage on schema net to %s', v_keep);
  execute format('grant execute on all functions in schema net to %s', v_keep);
  execute format('grant select, insert, update, delete on all tables in schema net to %s', v_keep);
  execute format('grant usage, select on all sequences in schema net to %s', v_keep);
end;
$$;
revoke execute on function public.net_api_roles_revoke() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_roles where rolname = current_user and rolsuper) then
    perform public.net_api_roles_revoke();
  elsif has_function_privilege('anon', 'net.http_post(text, jsonb, jsonb, jsonb, integer)', 'execute') then
    raise warning using
      message = '0240: anon and authenticated can still execute net.http_post; only a superuser can revoke it.',
      hint = 'Run "select public.net_api_roles_revoke();" as supabase_admin (Supabase support on the hosted project).';
  end if;
exception when undefined_function or invalid_schema_name then
  null;  -- no pg_net, or another signature: nothing to warn about here
end $$;
