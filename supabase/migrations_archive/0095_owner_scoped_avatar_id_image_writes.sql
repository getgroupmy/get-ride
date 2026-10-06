-- ============================================================================
-- 0095 — avatars / ID_Image: writes limited to the uploader's own folder
-- ----------------------------------------------------------------------------
-- The `avatars` and `ID_Image` buckets let any signed-in account insert,
-- overwrite or delete ANY object in them (policies "auth upload/update/delete
-- avatars|id_image": bucket check only). File names follow a guessable
-- pattern (<country>/<phone>_<name|id>_<date>.png), so one user could replace
-- or delete another user's profile photo or IC photo.
--
-- Now a non-admin may only write objects under a top-level folder named after
-- their own auth uid: `<auth.uid()>/...`. Admins (caller_is_admin(): admin
-- profiles, service role, direct DB sessions) keep full write access, which
-- the admin user screens use. Reading is unchanged: both buckets stay public,
-- so every existing getPublicUrl link keeps working, including files already
-- stored under the old country folders.
--
-- Client uploads must use the `<uid>/…` layout before this is applied; the
-- Expo app (edit-profile) and the Flutter app (Edit profile, partner
-- onboarding, TEKSI EV order) do as of this change.
-- ============================================================================

drop policy if exists "auth upload avatars" on storage.objects;
drop policy if exists "auth update avatars" on storage.objects;
drop policy if exists "auth delete avatars" on storage.objects;
drop policy if exists "auth upload id_image" on storage.objects;
drop policy if exists "auth update id_image" on storage.objects;
drop policy if exists "auth delete id_image" on storage.objects;

create policy "auth upload avatars"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  );

create policy "auth update avatars"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'avatars'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  )
  with check (
    bucket_id = 'avatars'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  );

create policy "auth delete avatars"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'avatars'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  );

create policy "auth upload id_image"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'ID_Image'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  );

create policy "auth update id_image"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'ID_Image'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  )
  with check (
    bucket_id = 'ID_Image'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  );

create policy "auth delete id_image"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'ID_Image'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.caller_is_admin())
  );
