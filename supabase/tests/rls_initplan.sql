-- ============================================================================
-- Regression test for migration 0163: no row-level policy in `public` calls
-- auth.uid() & co. (or current_setting) per row -- each is wrapped in a
-- scalar sub-select -- and the foreign keys 0163 indexed have an index.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_initplan.sql
--
-- Read-only. A failed assertion raises an exception.
-- ============================================================================
do $$
declare
  bad text;
begin
  select string_agg(format('%s on %s', p.policyname, p.tablename), '; ')
    into bad
    from pg_policies p
   where p.schemaname = 'public'
     and (coalesce(p.qual, '') ~ '(?<!SELECT )auth\.(uid|jwt|role|email)\(\)'
       or coalesce(p.with_check, '') ~ '(?<!SELECT )auth\.(uid|jwt|role|email)\(\)'
       or coalesce(p.qual, '') ~ '(?<!SELECT )current_setting\('
       or coalesce(p.with_check, '') ~ '(?<!SELECT )current_setting\(');
  if bad is not null then
    raise exception 'policies still read the caller per row: %', bad;
  end if;

  select string_agg(format('%s.%s', c.conrelid::regclass, a.attname), ', ')
    into bad
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
   where c.contype = 'f'
     and c.connamespace = 'public'::regnamespace
     and c.conname in (
       'help_questions_matched_article_id_fkey', 'ride_call_signals_sender_fkey',
       'ride_calls_caller_id_fkey', 'ride_lost_items_request_id_fkey',
       'ride_request_views_viewer_id_fkey', 'ride_requests_direct_qr_id_fkey',
       'sms_inbox_device_id_fkey', 'sms_outbox_device_id_fkey',
       'support_call_signals_sender_fkey', 'support_calls_answered_by_fkey',
       'support_calls_caller_id_fkey', 'support_calls_ticket_id_fkey')
     and not exists (
       select 1 from pg_index i
        where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1]);
  if bad is not null then
    raise exception 'foreign keys without an index: %', bad;
  end if;
end
$$;

select 'rls_initplan: all passed';
