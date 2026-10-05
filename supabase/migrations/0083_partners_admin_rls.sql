-- Admin writes on public.partners.
--
-- Migration 0025 gave `partners` self-scoped insert/update policies so the
-- partner onboarding flow could write its own row, and the 0069 lockdown left
-- the table alone (its self-write path had to survive). The result is that the
-- table has *no* admin write policy at all: Admin → Partner Edit could never
-- persist a change to somebody else's partner row, and `adminSync.upsertPartner`
-- swallowed the RLS rejection while the screen still reported "Saved".
--
-- This adds admin insert/update/delete alongside the self policies (multiple
-- permissive policies OR together, so the onboarding path is unaffected).

alter table public.partners enable row level security;

drop policy if exists "partners admin insert" on public.partners;
create policy "partners admin insert"
  on public.partners for insert
  to public
  with check (public.caller_is_admin());

drop policy if exists "partners admin update" on public.partners;
create policy "partners admin update"
  on public.partners for update
  to public
  using (public.caller_is_admin())
  with check (public.caller_is_admin());

drop policy if exists "partners admin delete" on public.partners;
create policy "partners admin delete"
  on public.partners for delete
  to public
  using (public.caller_is_admin());

notify pgrst, 'reload schema';
