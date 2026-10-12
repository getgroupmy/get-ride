-- ============================================================================
-- 0156: document buckets go private (security audit 1.2, last step)
--
-- 0148 limited who may write each document file and added the owner READ
-- policies; the apps have opened those files through signed links since
-- #262 (and this build signs every remaining place). With both in place the
-- four document buckets stop serving files to anyone who has the link:
--
--   ID_Image, provider-documents, vehicle-documents, support-media
--
-- Guarded: a bucket only turns private when its owner read policy exists.
-- On a database where 0148's storage policies haven't been applied yet (the
-- live project needs them run by its owner, storage-policies-0148.sql), this
-- changes nothing and says why, so it can never lock owners out of their
-- own files. Run `select public.storage_make_document_buckets_private();`
-- again after the policies are in.
--
-- Rollback: update storage.buckets set public = true where id in (…);
-- ============================================================================

create or replace function public.storage_make_document_buckets_private()
returns text[]
language plpgsql
set search_path = public
as $$
declare
  b record;
  v_private text[] := '{}';
  v_skipped text[] := '{}';
begin
  for b in
    select * from (values
      ('ID_Image', 'ID_Image owner read'),
      ('provider-documents', 'provider-documents owner read'),
      ('vehicle-documents', 'vehicle-documents owner read'),
      ('support-media', 'support-media owner read')
    ) as t(bucket, read_policy)
  loop
    if exists (select 1 from pg_policies
                where schemaname = 'storage' and tablename = 'objects' and policyname = b.read_policy) then
      update storage.buckets set public = false where id = b.bucket and public;
      v_private := v_private || b.bucket;
    else
      v_skipped := v_skipped || b.bucket;
    end if;
  end loop;
  if cardinality(v_skipped) > 0 then
    raise notice 'Left public (owner read policy missing; run storage-policies-0148.sql first): %', v_skipped;
  end if;
  return v_private;
end;
$$;
revoke execute on function public.storage_make_document_buckets_private() from public, anon, authenticated;

select public.storage_make_document_buckets_private();
