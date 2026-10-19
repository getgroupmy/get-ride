-- ============================================================================
-- 0239 — Empty support tickets are cleared after 30 minutes
--
-- The app makes a support ticket with the user's first message: it inserts
-- the ticket, then the message (after uploading a photo, video or voice note
-- to support-media/<ticket id>/). There is no single call for both, so a send
-- that fails after the ticket insert leaves an open ticket with nothing in
-- it. The app hides those from the user's list after 30 minutes, but the
-- admin's open-ticket count (status <> 'closed') still includes them.
--
-- An empty ticket here is one that is older than 30 minutes, has no
-- support_messages row, and never had one: last_message_at is null and
-- last_message is blank (the app's own test for an empty ticket). A ticket
-- whose messages an admin deleted keeps its last_message, so it stays.
--
-- What refers to a ticket, and why most empty ones are deleted:
--   * support_messages.ticket_id  FK, on delete cascade. None, by definition.
--   * support_calls.ticket_id     FK, on delete set null. A ticket with any
--     call is left alone entirely: deleting it would detach the call
--     history from it (calls normally carry no ticket, so this is rare).
--   * support-media/<ticket id>/  storage objects, no FK. A failed send can
--     leave the upload behind without its message. Deleting the ticket would
--     orphan the file (storage is not cleaned from SQL), so such a ticket is
--     closed instead and its files stay reachable by an admin.
--   * voice_protection_recordings.ticket_id  no FK; an admin asking a phone
--     for a recording on behalf of a ticket. Closed instead of deleted, so the
--     link still resolves.
--   * ride_requests.cancel_ticket_id (0191)  no FK. Those tickets are made
--     with their first message and last_message already set, so they are
--     never empty; not checked.
--   * support_tickets.ticket_number  a sequence; a deleted ticket leaves a
--     gap in the numbers, as an admin's delete already does.
-- Nothing else points at support_tickets. So an empty ticket with none of
-- the above is deleted (nothing is lost: there is nothing in it); one with
-- media or a recording link is set to 'closed' with " (closed
-- automatically: its first message never arrived)" added to the subject,
-- the only free-text field that is not part of what makes it empty (setting
-- last_message would bring it back to the user's list). An already-closed
-- one is not touched again, so the job is idempotent.
--
-- support_purge_empty_tickets() does the work: it locks the candidates
-- (FOR UPDATE SKIP LOCKED, which also holds off a message or call being
-- inserted for them, since those take a key-share lock through their FK),
-- then checks again under the lock that none has appeared before deleting
-- or closing. It runs once now, and hourly from pg_cron
-- ('purge-empty-support-tickets', at :37) where pg_cron is installed, in the
-- same guarded way as 'purge-auth-rate-counts' (0229 / 0234). SECURITY
-- DEFINER, owned by postgres; only service_role may call it.
-- ============================================================================

create or replace function public.support_purge_empty_tickets()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
  v_deleted integer;
  v_closed integer;
begin
  select coalesce(array_agg(c.id), '{}')
    into v_ids
    from (select t.id
            from public.support_tickets t
           where t.created_at < now() - interval '30 minutes'
             and t.last_message_at is null
             and coalesce(btrim(t.last_message), '') = ''
             and not exists (select 1 from public.support_messages m where m.ticket_id = t.id)
             and not exists (select 1 from public.support_calls k where k.ticket_id = t.id)
             for update of t skip locked) c;

  if cardinality(v_ids) = 0 then
    return jsonb_build_object('deleted', 0, 'closed', 0);
  end if;

  -- Checked again now the rows are locked: a message or call that committed
  -- before the lock is seen by this statement's snapshot.
  with gone as (
    delete from public.support_tickets t
     where t.id = any(v_ids)
       and t.last_message_at is null
       and not exists (select 1 from public.support_messages m where m.ticket_id = t.id)
       and not exists (select 1 from public.support_calls k where k.ticket_id = t.id)
       and not exists (select 1 from storage.objects o
                        where o.bucket_id = 'support-media' and o.name like t.id::text || '/%')
       and not exists (select 1 from public.voice_protection_recordings v where v.ticket_id = t.id)
    returning 1
  )
  select count(*) into v_deleted from gone;

  with shut as (
    update public.support_tickets t
       set status = 'closed',
           subject = t.subject || ' (closed automatically: its first message never arrived)'
     where t.id = any(v_ids)
       and t.status <> 'closed'
       and t.last_message_at is null
       and not exists (select 1 from public.support_messages m where m.ticket_id = t.id)
       and not exists (select 1 from public.support_calls k where k.ticket_id = t.id)
    returning 1
  )
  select count(*) into v_closed from shut;

  return jsonb_build_object('deleted', v_deleted, 'closed', v_closed);
end;
$$;

revoke execute on function public.support_purge_empty_tickets() from public, anon, authenticated;
grant execute on function public.support_purge_empty_tickets() to service_role;

-- The ones already there.
select public.support_purge_empty_tickets();

-- Hourly from now on.
do $cron$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'purge-empty-support-tickets';
    perform cron.schedule('purge-empty-support-tickets', '37 * * * *',
      $job$select public.support_purge_empty_tickets()$job$);
  end if;
end
$cron$;
