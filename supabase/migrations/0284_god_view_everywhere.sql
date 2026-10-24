-- ============================================================================
-- 0284 — God View: a sub-admin can be given Everywhere.
--
-- Applied by hand as version 20261024140000 (0284_god_view_everywhere in
-- supabase_migrations.schema_migrations). Re-runnable.
--
-- A sub-admin's God View grant is limited to the region on it (0270), and a
-- grant with no region sees nobody, so a new sub-admin never sees the whole
-- country by mistake. Admin → Sub-admins can now set the grant's region to
-- {"everywhere": true} on purpose: that sub-admin sees everyone on God View,
-- as a full admin does. Everything that asks god_view_caller() (the
-- snapshot, the trail, ping, live) follows.
-- ============================================================================

create or replace function public.god_view_caller(out ok boolean, out scoped boolean, out region jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_uid uuid;
begin
  ok := false;
  scoped := false;
  region := null;
  if v_claims is null or v_claims = '' or coalesce(auth.jwt() ->> 'role', '') = 'service_role' then
    ok := true;  -- a direct database session (migrations, psql) or the service role
    return;
  end if;
  v_uid := auth.uid();
  if v_uid is null then
    return;
  end if;
  if exists (select 1 from public.admin_access a where a.profile_id = v_uid and a.page = '*') then
    ok := true;
    return;
  end if;
  select true, true, a.region into ok, scoped, region
    from public.admin_access a
   where a.profile_id = v_uid and a.page = 'admin-god-view';
  ok := coalesce(ok, false);
  scoped := coalesce(scoped, false);
  -- Everywhere, set on purpose in Admin → Sub-admins: no region limit.
  if ok and coalesce(region ->> 'everywhere', '') = 'true' then
    scoped := false;
    region := null;
  end if;
end;
$$;
revoke execute on function public.god_view_caller() from public, anon, authenticated;

comment on column public.admin_access.region is
  'The region a page grant is limited to, {country, state, city, suburb} by region names (0270). Read by God View (admin-god-view): a sub-admin sees the people inside it only; {"everywhere": true} sees everyone (0284).';

notify pgrst, 'reload schema';
insert into supabase_migrations.schema_migrations (version, name) values ('20261024140000', '0284_god_view_everywhere') on conflict do nothing;
