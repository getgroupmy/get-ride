-- ============================================================================
-- 0163: row-level policies read the caller once per query, not once per row
--       (performance advisor: auth_rls_initplan, unindexed_foreign_keys)
--
-- A policy written `user_id = auth.uid()` calls auth.uid() for every row the
-- query scans. Written `user_id = (select auth.uid())` Postgres evaluates it
-- once as an InitPlan and reuses the value -- same caller, same answer, so
-- who may read or write what is unchanged. On profiles, ride_requests,
-- partners, wallets and ride_messages that is the difference between a
-- function call per row and one per query.
--
-- Rather than restate 79 policies by hand (and risk changing one), each
-- policy in `public` is rewritten from its own stored expression: every bare
-- auth.uid() / auth.jwt() / auth.role() / auth.email() and current_setting(...)
-- is wrapped in a scalar sub-select, and USING / WITH CHECK are set back only
-- where the text changed. A call already inside `(SELECT ...)` is left alone,
-- so the migration is idempotent and replays on any older copy.
--
-- Also indexes the twelve foreign keys the advisor found without one, so
-- deleting a parent row (a profile, a ticket, a device) doesn't scan the
-- child table. A table this database doesn't have is skipped.
-- ============================================================================

do $$
declare
  pol record;
  new_using text;
  new_check text;
  stmt text;
begin
  for pol in
    select p.schemaname, p.tablename, p.policyname, p.qual, p.with_check
      from pg_policies p
     where p.schemaname = 'public'
  loop
    new_using := regexp_replace(regexp_replace(pol.qual,
      '(?<!SELECT )auth\.(uid|jwt|role|email)\(\)', '(SELECT auth.\1())', 'g'),
      '(?<!SELECT )(current_setting\([^()]*\))', '(SELECT \1)', 'g');
    new_check := regexp_replace(regexp_replace(pol.with_check,
      '(?<!SELECT )auth\.(uid|jwt|role|email)\(\)', '(SELECT auth.\1())', 'g'),
      '(?<!SELECT )(current_setting\([^()]*\))', '(SELECT \1)', 'g');

    if new_using is not distinct from pol.qual and new_check is not distinct from pol.with_check then
      continue;
    end if;

    stmt := format('alter policy %I on %I.%I', pol.policyname, pol.schemaname, pol.tablename);
    if new_using is distinct from pol.qual then
      stmt := stmt || format(' using (%s)', new_using);
    end if;
    if new_check is distinct from pol.with_check then
      stmt := stmt || format(' with check (%s)', new_check);
    end if;
    execute stmt;
  end loop;
end
$$;

do $$
declare
  fk record;
begin
  for fk in
    select * from (values
      ('help_questions',       'matched_article_id'),
      ('ride_call_signals',    'sender'),
      ('ride_calls',           'caller_id'),
      ('ride_lost_items',      'request_id'),
      ('ride_request_views',   'viewer_id'),
      ('ride_requests',        'direct_qr_id'),
      ('sms_inbox',            'device_id'),
      ('sms_outbox',           'device_id'),
      ('support_call_signals', 'sender'),
      ('support_calls',        'answered_by'),
      ('support_calls',        'caller_id'),
      ('support_calls',        'ticket_id')
    ) as t(tbl, col)
  loop
    if exists (
      select 1 from pg_attribute a
       where a.attrelid = to_regclass('public.' || fk.tbl)
         and a.attname = fk.col and not a.attisdropped
    ) then
      execute format('create index if not exists %I on public.%I (%I)',
                     fk.tbl || '_' || fk.col || '_idx', fk.tbl, fk.col);
    end if;
  end loop;
end
$$;
