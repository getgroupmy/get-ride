-- ============================================================================
-- 0103 — close three SECURITY DEFINER functions that were open to anyone
--
-- Supabase's security advisor flags every SECURITY DEFINER function callable
-- by `anon`. Most of them check the caller themselves. These three did not
-- need to be callable by the client at all:
--
--   * fare_ai_record_usage — had no caller check, so anyone (signed in or
--     not) could mark every AI fare key as failed with a far-future
--     `disabled_until`, taking AI pricing offline, or write made-up errors
--     into the admin stats. Its only real caller is the `ai-route-proxy`
--     edge function, which uses the service role. (Expo's legacy client-side
--     fallback also calls it, but that only runs when the proxy is not
--     deployed, and it already ignores the error.)
--   * expire_documents_daily — only marks documents already past expiry, the
--     same thing the 00:00 pg_cron job does as `postgres`. Nobody else needs
--     to run it.
--   * admin_access_bootstrap — signed-out callers already get `false`; it is
--     signed-in users that need it (first-admin setup on an empty
--     admin_access), so only `anon` loses it.
--
-- `public` is revoked too: a function created without an explicit revoke
-- keeps PostgreSQL's default EXECUTE for PUBLIC, which anon inherits.
-- Idempotent; a function missing from this database is skipped.
-- ============================================================================
do $$
begin
  if to_regprocedure('public.fare_ai_record_usage(text, text, boolean, timestamptz, text)') is not null then
    revoke execute on function public.fare_ai_record_usage(text, text, boolean, timestamptz, text)
      from public, anon, authenticated;
    grant execute on function public.fare_ai_record_usage(text, text, boolean, timestamptz, text)
      to service_role;
  end if;

  if to_regprocedure('public.expire_documents_daily()') is not null then
    revoke execute on function public.expire_documents_daily() from public, anon, authenticated;
    grant execute on function public.expire_documents_daily() to service_role;
  end if;

  if to_regprocedure('public.admin_access_bootstrap()') is not null then
    revoke execute on function public.admin_access_bootstrap() from public, anon;
    grant execute on function public.admin_access_bootstrap() to authenticated;
  end if;
end
$$;
