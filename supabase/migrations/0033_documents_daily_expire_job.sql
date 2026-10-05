-- ============================================================================
-- 0033_documents_daily_expire_job.sql
--
-- Part 2 of the daily-expire setup. Runs after 0032 has committed the new
-- 'Expired' enum label so we're allowed to reference it in SQL here.
--
-- Creates:
--   * public.expire_documents_daily() — flips rows whose expiry is in the
--     past to status = 'Expired' across the three document surfaces
--   * a pg_cron job that calls it at 00:00 UTC daily
--   * runs the function once now so existing-but-expired rows get caught up
--
-- Safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Daily expire function — touches all three tables
-- ---------------------------------------------------------------------------
create or replace function public.expire_documents_daily()
returns void
language plpgsql
security definer
as $$
begin
  -- provider_documents
  update public.provider_documents
     set status = 'Expired'
   where expiry_date is not null
     and expiry_date < current_date
     and status not in ('Expired', 'Rejected');

  -- vehicle_documents
  update public.vehicle_documents
     set status = 'Expired'
   where expiry_date is not null
     and expiry_date < current_date
     and status not in ('Expired', 'Rejected');

  -- profiles (user IDs)
  update public.profiles
     set id_verified = 'Expired'
   where id_expiry_date is not null
     and id_expiry_date < current_date
     and (id_verified is null or id_verified::text not in ('Expired', 'Failed'));
end;
$$;

grant execute on function public.expire_documents_daily() to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Schedule via pg_cron — daily at 00:00 UTC
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron;

do $$
declare
  existing_jobid bigint;
begin
  select jobid into existing_jobid
    from cron.job
   where jobname = 'expire-documents-daily';

  if existing_jobid is not null then
    perform cron.unschedule(existing_jobid);
  end if;

  perform cron.schedule(
    'expire-documents-daily',
    '0 0 * * *',
    $cmd$ select public.expire_documents_daily(); $cmd$
  );
exception
  when undefined_table then
    -- pg_cron not available in this environment; the function can still be
    -- invoked manually or via a scheduled Edge Function as a fallback.
    raise notice 'pg_cron not available — daily job not scheduled. Call public.expire_documents_daily() from a scheduled job instead.';
end$$;

-- ---------------------------------------------------------------------------
-- 3. Run once now so existing-but-expired rows get flipped immediately.
-- ---------------------------------------------------------------------------
select public.expire_documents_daily();

notify pgrst, 'reload schema';
