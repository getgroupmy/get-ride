-- ============================================================================
-- Regression test for migration 0156: the document buckets go private, but
-- only where the owner read policy (0148) is there to let owners in.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/private_document_buckets.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;

-- All four buckets, public, plus one that must be left alone.
insert into storage.buckets (id, name, public) values
  ('ID_Image', 'ID_Image', true),
  ('provider-documents', 'provider-documents', true),
  ('vehicle-documents', 'vehicle-documents', true),
  ('support-media', 'support-media', true),
  ('avatars', 'avatars', true)
on conflict (id) do update set public = true;

-- 1. With 0148's read policies in place, all four go private ------------------------------
select pg_temp.check(cardinality(public.storage_make_document_buckets_private()) = 4, 'all four reported private');
select pg_temp.check((select count(*) = 4 from storage.buckets
                       where id in ('ID_Image', 'provider-documents', 'vehicle-documents', 'support-media')
                         and not public),
                     'the four document buckets are private');
select pg_temp.check((select public from storage.buckets where id = 'avatars'), 'other buckets are left public');

-- 2. A bucket whose owner read policy is missing stays public ----------------------------------
update storage.buckets set public = true where id = 'support-media';
drop policy "support-media owner read" on storage.objects;
select pg_temp.check(not ('support-media' = any (public.storage_make_document_buckets_private())),
                     'not reported private without its read policy');
select pg_temp.check((select public from storage.buckets where id = 'support-media'),
                     'support-media stays public: owners could not read their own files otherwise');

-- 3. No client may run it ------------------------------------------------------------------------
select pg_temp.check(not has_function_privilege('authenticated', 'public.storage_make_document_buckets_private()', 'execute'),
                     'clients can''t flip buckets');

rollback;

select 'private_document_buckets: all passed';
