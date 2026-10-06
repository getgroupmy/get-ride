-- ============================================================================
-- 0034_partner_type_icons.sql
-- Public storage bucket for partner-type icons uploaded from the admin panel.
-- Safe to re-run.
-- ============================================================================

insert into storage.buckets (id, name, public)
values ('partner-type-icons', 'partner-type-icons', true)
on conflict (id) do update set public = excluded.public;

drop policy if exists "partner-type-icons read"   on storage.objects;
drop policy if exists "partner-type-icons insert" on storage.objects;
drop policy if exists "partner-type-icons update" on storage.objects;
drop policy if exists "partner-type-icons delete" on storage.objects;

create policy "partner-type-icons read"
  on storage.objects for select
  using (bucket_id = 'partner-type-icons');

create policy "partner-type-icons insert"
  on storage.objects for insert
  to public
  with check (bucket_id = 'partner-type-icons');

create policy "partner-type-icons update"
  on storage.objects for update
  to public
  using (bucket_id = 'partner-type-icons')
  with check (bucket_id = 'partner-type-icons');

create policy "partner-type-icons delete"
  on storage.objects for delete
  to public
  using (bucket_id = 'partner-type-icons');
