-- AI verification metadata for provider_documents.
-- Stores the latest result returned by the vision verifier so admins can
-- see whether an upload is likely real and relevant.

alter table public.provider_documents
  add column if not exists ai_verification jsonb;

-- Lightweight flag so we can list "needs human review" quickly.
alter table public.provider_documents
  add column if not exists ai_verified boolean;

notify pgrst, 'reload schema';
