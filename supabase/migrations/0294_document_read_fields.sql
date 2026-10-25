-- ============================================================================
-- 0294: document reading, part 3 — what the partner confirmed at upload.
--
-- At upload the app reads every field of the document's kind off the photo
-- (part 2) and the partner checks and fixes each one before sending; the
-- photo is checked too (sharp, no glare, all four corners). Kept on the
-- document as read_fields:
--   {"kind": "cover", "fields": {"<key>": "<value>"}, "changed": ["<key>"],
--    "photo": {"sharp": bool, "glare": bool, "corners": bool}}
-- "changed" lists the fields the partner changed from what was read, so a
-- reviewer sees both. The owner writes it with the upload, like
-- ai_verification; an object of at most 20 kB.
-- ============================================================================
alter table public.provider_documents add column if not exists read_fields jsonb;
alter table public.vehicle_documents add column if not exists read_fields jsonb;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'provider_documents_read_fields_shape') then
    alter table public.provider_documents add constraint provider_documents_read_fields_shape
      check (read_fields is null or (jsonb_typeof(read_fields) = 'object' and length(read_fields::text) <= 20000));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'vehicle_documents_read_fields_shape') then
    alter table public.vehicle_documents add constraint vehicle_documents_read_fields_shape
      check (read_fields is null or (jsonb_typeof(read_fields) = 'object' and length(read_fields::text) <= 20000));
  end if;
end $$;

comment on column public.provider_documents.read_fields is
  'Document reading (0294): fields read off the photo as the partner confirmed them, the ones they changed, and the photo check.';
comment on column public.vehicle_documents.read_fields is
  'Document reading (0294): fields read off the photo as the partner confirmed them, the ones they changed, and the photo check.';

notify pgrst, 'reload schema';

insert into supabase_migrations.schema_migrations (version, name)
values ('20261025220000', '0294_document_read_fields')
on conflict (version) do nothing;
