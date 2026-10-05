-- Persist the AI-detected document name and issuance country as top-level
-- columns so admins / analytics can filter by them without parsing the
-- ai_verification JSON blob.

alter table public.provider_documents
  add column if not exists issuance_country text;

alter table public.provider_documents
  add column if not exists detected_document_name text;

notify pgrst, 'reload schema';
