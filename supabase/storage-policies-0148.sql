-- ============================================================================
-- storage-policies-0148.sql: run once by the project OWNER, in the Supabase
-- SQL Editor (Dashboard > SQL Editor > New query > paste > Run).
--
-- Why a separate file: migration 0148 was applied, but its policies on
-- storage.objects need the table's owner, which the migration role isn't,
-- so on the live project they were never created. Until they are:
--   * any signed-in account can overwrite any file in provider-documents,
--     vehicle-documents and support-media (the live write rules check only
--     the bucket name), and
--   * 0156 could not make the four document buckets private, so ID cards,
--     licences and permits still open for anyone holding the link.
--
-- What it does, in one transaction:
--   1. replaces the bucket-only write rules with owner rules: a partner's own
--      folder, a vehicle the caller owns / drives, the caller's own support
--      ticket; admins pass everywhere (the 0148 helper functions, already
--      live);
--   2. adds the owner READ rules the apps' signed links rely on, and an owner
--      UPDATE rule on support-media (attachments upload with upsert);
--   3. makes ID_Image, provider-documents, vehicle-documents and
--      support-media private (0156's guarded function, already live);
--   4. lists the result.
--
-- Safe to run again. Both apps already open these files through signed
-- links, so nothing they show changes for the owner or an admin.
--
-- Rollback (buckets public again; the rules can stay):
--   update storage.buckets set public = true
--    where id in ('ID_Image','provider-documents','vehicle-documents','support-media');
-- ============================================================================

begin;

-- The bucket-only rules (live names) and the open ones from the baseline go.
drop policy if exists "provider-documents auth write" on storage.objects;
drop policy if exists "provider-documents auth update" on storage.objects;
drop policy if exists "vehicle-documents auth write" on storage.objects;
drop policy if exists "vehicle-documents auth update" on storage.objects;
drop policy if exists "support-media auth write" on storage.objects;
drop policy if exists "public read support-media" on storage.objects;
drop policy if exists "anon upload support-media" on storage.objects;
drop policy if exists "auth update support-media" on storage.objects;
drop policy if exists "auth delete support-media" on storage.objects;
drop policy if exists "public read id_image" on storage.objects;

drop policy if exists "provider-documents owner write" on storage.objects;
drop policy if exists "provider-documents owner update" on storage.objects;
drop policy if exists "provider-documents owner read" on storage.objects;
drop policy if exists "vehicle-documents owner write" on storage.objects;
drop policy if exists "vehicle-documents owner update" on storage.objects;
drop policy if exists "vehicle-documents owner read" on storage.objects;
drop policy if exists "support-media owner write" on storage.objects;
drop policy if exists "support-media owner read" on storage.objects;
drop policy if exists "ID_Image owner read" on storage.objects;

create policy "provider-documents owner write" on storage.objects for insert to authenticated
  with check (bucket_id = 'provider-documents'
    and (public.storage_owns_partner_folder((storage.foldername(name))[1]) or public.caller_is_admin()));
create policy "provider-documents owner update" on storage.objects for update to authenticated
  using (bucket_id = 'provider-documents'
    and (public.storage_owns_partner_folder((storage.foldername(name))[1]) or public.caller_is_admin()))
  with check (bucket_id = 'provider-documents'
    and (public.storage_owns_partner_folder((storage.foldername(name))[1]) or public.caller_is_admin()));
create policy "provider-documents owner read" on storage.objects for select to authenticated
  using (bucket_id = 'provider-documents'
    and (public.storage_owns_partner_folder((storage.foldername(name))[1]) or public.caller_is_admin()));

create policy "vehicle-documents owner write" on storage.objects for insert to authenticated
  with check (bucket_id = 'vehicle-documents'
    and (public.storage_owns_vehicle_folder((storage.foldername(name))[1]) or public.caller_is_admin()));
create policy "vehicle-documents owner update" on storage.objects for update to authenticated
  using (bucket_id = 'vehicle-documents'
    and (public.storage_owns_vehicle_folder((storage.foldername(name))[1]) or public.caller_is_admin()))
  with check (bucket_id = 'vehicle-documents'
    and (public.storage_owns_vehicle_folder((storage.foldername(name))[1]) or public.caller_is_admin()));
create policy "vehicle-documents owner read" on storage.objects for select to authenticated
  using (bucket_id = 'vehicle-documents'
    and (public.storage_owns_vehicle_folder((storage.foldername(name))[1]) or public.caller_is_admin()));

create policy "support-media owner write" on storage.objects for insert to authenticated
  with check (bucket_id = 'support-media'
    and (public.storage_owns_ticket_folder((storage.foldername(name))[1]) or public.caller_is_admin()));
-- Not in 0148: the apps upload attachments with upsert, which Storage only
-- allows with an UPDATE rule as well (the live one is admin-only).
drop policy if exists "support-media owner update" on storage.objects;
create policy "support-media owner update" on storage.objects for update to authenticated
  using (bucket_id = 'support-media'
    and (public.storage_owns_ticket_folder((storage.foldername(name))[1]) or public.caller_is_admin()))
  with check (bucket_id = 'support-media'
    and (public.storage_owns_ticket_folder((storage.foldername(name))[1]) or public.caller_is_admin()));
create policy "support-media owner read" on storage.objects for select to authenticated
  using (bucket_id = 'support-media'
    and (public.storage_owns_ticket_folder((storage.foldername(name))[1]) or public.caller_is_admin()));

create policy "ID_Image owner read" on storage.objects for select to authenticated
  using (bucket_id = 'ID_Image'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin()));

-- Turn the four buckets private now that the owner read rules exist.
select public.storage_make_document_buckets_private() as made_private;

commit;

-- Check: all four should read public = false, with an "owner read" rule each.
select b.id, b.public,
       exists (select 1 from pg_policies p
                where p.schemaname = 'storage' and p.tablename = 'objects'
                  and p.policyname = b.id || ' owner read') as owner_read_rule
  from storage.buckets b
 where b.id in ('ID_Image', 'provider-documents', 'vehicle-documents', 'support-media')
 order by b.id;
