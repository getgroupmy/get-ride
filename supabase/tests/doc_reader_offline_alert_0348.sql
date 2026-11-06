-- ============================================================================
-- Regression test for migration 0348: the document reader (NAS) offline alert.
--   * doc_reader_offline_check: a reader seen within 5 minutes is fine; no
--     heartbeat for 5 minutes alerts the face/document admins, once; a
--     continuing outage doesn't alert again; a heartbeat again sends "back
--     online" and clears; a reader whose kind is switched off is not alerted.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/doc_reader_offline_alert_0348.sql
--
-- Runs in one transaction and is rolled back. Made-up devices only.
-- ============================================================================
begin;

insert into auth.users (id) values ('00000000-0000-0000-0000-0000000348a1') on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000348a1') on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000348a1', 'admin-documents', 'edit') on conflict do nothing;

-- base = a fixed time the reader was last seen.
insert into public.doc_readers (id, kind, label, device_id, key_hash, last_seen_at, offline_alerted_at)
values ('00000000-0000-0000-0000-0000000348d1', 'nas', 'Office NAS', 'test-0348',
        'keyhash-0348', timestamptz '2026-11-06 00:00:00Z', null);

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if; end $$;

-- 1. Seen 1 minute ago: fine, no alert.
select pg_temp.check(public.doc_reader_offline_check(timestamptz '2026-11-06 00:01:00Z') = 0,
  'a reader seen within 5 minutes is not alerted');
select pg_temp.check((select offline_alerted_at is null from public.doc_readers where id = '00000000-0000-0000-0000-0000000348d1'),
  'nothing stamped');

-- 2. No heartbeat for 6 minutes: one alert, to the Documents admin.
select pg_temp.check(public.doc_reader_offline_check(timestamptz '2026-11-06 00:06:00Z') = 1,
  'after 5 minutes without a heartbeat it alerts the one Documents admin');
select pg_temp.check((select offline_alerted_at is not null from public.doc_readers where id = '00000000-0000-0000-0000-0000000348d1'),
  'the alert is stamped so it is not repeated');

-- 3. Still down: no second alert.
select pg_temp.check(public.doc_reader_offline_check(timestamptz '2026-11-06 00:07:00Z') = 0,
  'a continuing outage does not alert again');

-- 4. Heartbeat again: "back online", and the stamp clears.
update public.doc_readers set last_seen_at = timestamptz '2026-11-06 00:07:30Z'
 where id = '00000000-0000-0000-0000-0000000348d1';
select pg_temp.check(public.doc_reader_offline_check(timestamptz '2026-11-06 00:08:00Z') = 1,
  'a heartbeat again sends "back online"');
select pg_temp.check((select offline_alerted_at is null from public.doc_readers where id = '00000000-0000-0000-0000-0000000348d1'),
  'the outage is cleared');

-- 5. The reader's kind switched off: not alerted, however stale.
update public.doc_readers set last_seen_at = timestamptz '2026-11-06 00:00:00Z', offline_alerted_at = null
 where id = '00000000-0000-0000-0000-0000000348d1';
insert into public.app_settings (key, value, updated_at) values
  ('document_reading', jsonb_build_object('readers', jsonb_build_array(jsonb_build_object('id', 'nas', 'on', false))), now())
on conflict (key) do update set value = excluded.value, updated_at = now();
select pg_temp.check(not public.document_reader_on('nas'), 'the nas reader is switched off');
select pg_temp.check(public.doc_reader_offline_check(timestamptz '2026-11-06 00:10:00Z') = 0,
  'a switched-off reader is not alerted');

rollback;
