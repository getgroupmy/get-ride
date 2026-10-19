-- 0244: a user can read their own files in `avatars` again.
--
-- The profile photo is uploaded with upsert (a new path each time), and
-- Storage's upsert is an INSERT ... ON CONFLICT DO UPDATE, which needs a
-- SELECT policy on the object as well as INSERT. Live had lost the broad
-- "public read avatars" policy, leaving only the admin read, so every
-- user's upload was refused: "new row violates row-level security policy"
-- (403). The bucket stays public for the photo URLs; this lets a user read
-- (and so upsert) only the files in their own folder, without letting
-- anyone list the whole bucket.

drop policy if exists "avatars owner read" on storage.objects;
create policy "avatars owner read"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
