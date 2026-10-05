-- ============================================================================
-- 0032_documents_daily_expire.sql
--
-- Part 1 of the daily-expire setup.
--
-- Postgres requires that a new enum value be committed BEFORE it can be
-- referenced in SQL (you can't add 'Expired' and use it in the same
-- transaction). So this migration only does the schema additions:
--
--   * adds 'Expired' to the id_verification_status enum
--   * adds the id_expiry_date column on public.profiles
--
-- The function + pg_cron job + initial backfill live in
-- 0033_documents_daily_expire_job.sql, which runs in a separate transaction
-- after this one has committed the new enum label.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Profiles: add Expired to enum
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_enum e on e.enumtypid = t.oid
    where t.typname = 'id_verification_status' and e.enumlabel = 'Expired'
  ) then
    alter type id_verification_status add value 'Expired';
  end if;
end$$;

-- ---------------------------------------------------------------------------
-- 2. Profiles: add id_expiry_date column
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists id_expiry_date date;

create index if not exists profiles_id_expiry_idx
  on public.profiles(id_expiry_date);

notify pgrst, 'reload schema';
