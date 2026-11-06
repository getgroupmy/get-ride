-- ============================================================================
-- 0348: tell the admins when a document reader (the office NAS doc-reader, or
-- a GPU reader) goes offline, and when it is back — the same as the SMS
-- gateway alert (0178) and the face server alert (0347).
--
-- Unlike the face match server (0347, reached on demand over HTTP), a document
-- reader checks in: it calls out to the doc-reader edge function and sends a
-- heartbeat (doc_reader_heartbeat → doc_readers.last_seen_at), and the app
-- already treats it as online when last_seen_at is within 3 minutes (0293,
-- 0320). So this is the gateway model exactly — a per-minute pg_cron job over
-- doc_readers.last_seen_at, no health ping needed.
--
--   * doc_readers.offline_alerted_at: when its admins were told, so each
--     outage is one push;
--   * doc_reader_offline_check(): every minute, for each paired reader whose
--     kind is switched on (document_reader_on): no heartbeat for 5 minutes →
--     push "Document reader offline" to the same admins the face/selfie
--     alerts reach (face_server_alert_admins, 0347); a heartbeat again →
--     "Document reader back online".
-- ============================================================================

alter table public.doc_readers
  add column if not exists offline_alerted_at timestamptz;

-- Been down for 5 minutes with no heartbeat. (The reader is shown "online" at
-- 3 minutes, 0293; the alert waits longer so a brief hiccup is not an outage.)
create or replace function public.doc_reader_offline_check(p_now timestamptz default now())
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  d       record;
  v_name  text;
  v_msg   jsonb;
  v_admin uuid;
  v_sent  int := 0;
begin
  for d in
    select r.id, r.kind, r.label, r.device_id, r.offline_alerted_at,
           (r.last_seen_at is null or r.last_seen_at < p_now - interval '5 minutes') as offline
      from public.doc_readers r
     where public.document_reader_on(r.kind)
  loop
    v_name := coalesce(nullif(btrim(d.label), ''), 'A document reader');
    if d.offline and d.offline_alerted_at is null then
      update public.doc_readers set offline_alerted_at = p_now where id = d.id;
      v_msg := jsonb_build_object(
        'title', 'Document reader offline',
        'body', v_name || ' has not checked in for 5 minutes. '
          || 'IDs and documents it reads are passed to the next reader, if any, until it is back. '
          || 'Check the reader and its connection.');
    elsif not d.offline and d.offline_alerted_at is not null then
      update public.doc_readers set offline_alerted_at = null where id = d.id;
      v_msg := jsonb_build_object(
        'title', 'Document reader back online',
        'body', v_name || ' is reading again.');
    else
      continue;
    end if;
    for v_admin in select public.face_server_alert_admins() loop
      perform public.approval_push_send(
        v_admin, v_msg, jsonb_build_object('type', 'doc_reader_status', 'reader', d.id, 'online', not d.offline));
      v_sent := v_sent + 1;
    end loop;
  end loop;
  return v_sent;
end;
$$;
revoke execute on function public.doc_reader_offline_check(timestamptz) from public, anon, authenticated;

do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule(
      'doc-reader-offline-check',
      '* * * * *',
      $sql$select public.doc_reader_offline_check()$sql$
    );
  end if;
end
$$;

notify pgrst, 'reload schema';
