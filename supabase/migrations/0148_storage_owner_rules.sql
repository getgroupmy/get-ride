-- ============================================================================
-- 0148: document storage — who may write and read each file (security
-- audit 1.2, first step)
--
-- `provider-documents`, `vehicle-documents` and `support-media` took a write
-- from any signed-in account anywhere in the bucket (they only checked the
-- bucket name), so one driver could overwrite another's licence. And reads
-- relied on the buckets being public.
--
-- Files are not all filed under the uploader's own id, so "first folder =
-- auth.uid()" would refuse real uploads. Each bucket is checked against what
-- its first folder actually is in both apps:
--
--   ID_Image            <auth uid>/…                 (unchanged: already own)
--   provider-documents  <partners.id>/<doc>/…        the caller's partner row
--                       (or <auth uid>/… for older uploads)
--   vehicle-documents   <vehicle.id>/…               a vehicle the caller owns,
--                       owns through their partner row, or is assigned to
--   support-media       <support_tickets.id>/…       the caller's own ticket
--
-- Admins pass everywhere (caller_is_admin). Owner READ policies are added
-- now, so signed links keep working once the buckets turn private — that
-- switch is a later migration, after both apps read through signed links.
--
-- Also: size and type limits on the four buckets, and a fixed search_path
-- on the two functions the security advisor flagged (0144, 0145).
-- ============================================================================

-- ---- Ownership of a first folder -----------------------------------------------
create or replace function public.storage_owns_partner_folder(p_folder text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and (
    p_folder = auth.uid()::text
    or exists (select 1 from public.partners p where p.id::text = p_folder and p.auth_user_id = auth.uid())
  );
$$;

create or replace function public.storage_owns_vehicle_folder(p_folder text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and (
    exists (
      select 1 from public.vehicle v
       where v.id::text = p_folder
         and (
           v.auth_user_id = auth.uid()
           or exists (select 1 from public.partners p where p.id = v.owner_partner_id and p.auth_user_id = auth.uid())
           or exists (
             select 1 from public.vehicle_user_assignment a
              where a.vehicle_id::text = v.id::text and a.user_id = auth.uid() and coalesce(a.is_active, true)
           )
         )
    )
  );
$$;

create or replace function public.storage_owns_ticket_folder(p_folder text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1 from public.support_tickets t where t.id::text = p_folder and t.profile_id = auth.uid()
  );
$$;

revoke execute on function public.storage_owns_partner_folder(text) from public, anon;
revoke execute on function public.storage_owns_vehicle_folder(text) from public, anon;
revoke execute on function public.storage_owns_ticket_folder(text) from public, anon;
grant execute on function public.storage_owns_partner_folder(text) to authenticated, service_role;
grant execute on function public.storage_owns_vehicle_folder(text) to authenticated, service_role;
grant execute on function public.storage_owns_ticket_folder(text) to authenticated, service_role;

-- ---- Policies --------------------------------------------------------------------
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
create policy "support-media owner read" on storage.objects for select to authenticated
  using (bucket_id = 'support-media'
    and (public.storage_owns_ticket_folder((storage.foldername(name))[1]) or public.caller_is_admin()));

create policy "ID_Image owner read" on storage.objects for select to authenticated
  using (bucket_id = 'ID_Image'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin()));

-- ---- Limits --------------------------------------------------------------------------
update storage.buckets set file_size_limit = 10485760,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/heic', 'application/pdf']
 where id in ('ID_Image', 'vehicle-documents', 'provider-documents');
update storage.buckets set file_size_limit = 15728640,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/heic',
                                  'audio/mp4', 'audio/m4a', 'audio/x-m4a', 'audio/aac', 'audio/mpeg',
                                  'audio/ogg', 'audio/webm', 'audio/wav', 'video/mp4', 'video/quicktime',
                                  'application/pdf', 'application/octet-stream']
 where id = 'support-media';

-- ---- search_path on two functions from 0144 / 0145 -------------------------------------
alter function public.notification_retry_delay(text, int) set search_path = public;
alter function public.ride_request_push_radius_km() set search_path = public;
