-- ============================================================================
-- Regression test for migrations 0163 and 0227: no row-level policy in
-- `public` calls auth.uid() & co. (or current_setting) per row, and none in
-- `public` or `storage` calls the caller-only admin / partner checks per row
-- -- each is wrapped in a scalar sub-select -- and the foreign keys 0163 and
-- 0227 indexed have an index.
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

  select string_agg(format('%s on %s.%s', p.policyname, p.schemaname, p.tablename), '; ')
    into bad
    from pg_policies p
   where p.schemaname in ('public', 'storage')
     and (coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''))
         ~ '(?<![[:alnum:]_.])(?<!SELECT )(public\.)?(caller_is_admin|caller_is_approved_partner|caller_admin_can_write|is_admin)\(';
  if bad is not null then
    raise exception 'policies still check the caller per row: %', bad;
  end if;

  -- Still the same checks, only wrapped.
  if (select count(*) from pg_policies p
       where p.schemaname = 'public'
         and (coalesce(p.qual, '') || coalesce(p.with_check, '')) like '%SELECT caller_is_admin() AS caller_is_admin%') < 20 then
    raise exception 'the admin read policies lost their caller_is_admin() check';
  end if;

  select string_agg(format('%s.%s', c.conrelid::regclass, a.attname), ', ')
    into bad
    from pg_constraint c
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
   where c.contype = 'f'
     and c.connamespace = 'public'::regnamespace
     and (c.conname in (
       'help_questions_matched_article_id_fkey', 'ride_call_signals_sender_fkey',
       'ride_calls_caller_id_fkey', 'ride_lost_items_request_id_fkey',
       'ride_request_views_viewer_id_fkey', 'ride_requests_direct_qr_id_fkey',
       'sms_inbox_device_id_fkey', 'sms_outbox_device_id_fkey',
       'support_call_signals_sender_fkey', 'support_calls_answered_by_fkey',
       'support_calls_caller_id_fkey', 'support_calls_ticket_id_fkey')
       -- 0227
       or (c.conrelid::regclass::text, a.attname) in (
       ('safety_incidents', 'ride_id'), ('scheduled_rides', 'ride_id'),
       ('scheduled_ride_offers', 'rider_id'), ('scheduled_ride_offers', 'from_id'),
       ('trip_handovers', 'rider_id'), ('trip_handovers', 'from_partner_id'),
       ('trip_handovers', 'to_partner_id'), ('gateway_pairings', 'created_by'),
       ('gateway_pairings', 'device_row'), ('gateway_keys', 'paired_by'),
       ('ev_profiles', 'updated_by')))
     and not exists (
       select 1 from pg_index i
        where i.indrelid = c.conrelid and i.indkey[0] = c.conkey[1]);
  if bad is not null then
    raise exception 'foreign keys without an index: %', bad;
  end if;
end
$$;

select 'rls_initplan: all passed';
