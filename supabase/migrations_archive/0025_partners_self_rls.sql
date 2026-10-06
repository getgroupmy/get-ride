-- Allow authenticated users to create and update their own partner row so the
-- user-facing Partner onboarding flow can write to the table.

alter table public.partners enable row level security;

drop policy if exists "partners self insert" on public.partners;
create policy "partners self insert"
  on public.partners for insert
  to authenticated
  with check (auth_user_id = auth.uid());

drop policy if exists "partners self update" on public.partners;
create policy "partners self update"
  on public.partners for update
  to authenticated
  using (auth_user_id = auth.uid())
  with check (auth_user_id = auth.uid());

-- Also allow self-read so the onboarding screen can fetch the row it just made
-- (the existing "partners read" policy already covers authenticated reads, but
-- keeping this here is harmless and self-documenting).
drop policy if exists "partners self select" on public.partners;
create policy "partners self select"
  on public.partners for select
  to authenticated
  using (auth_user_id = auth.uid() or auth.role() = 'authenticated');

notify pgrst, 'reload schema';
