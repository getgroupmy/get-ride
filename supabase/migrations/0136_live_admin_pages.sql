-- Admin pages show every change live, made by another admin, by the apps'
-- users or by the page itself (Flutter lib/src/data/live_tables.dart:
-- liveAdminTables, followed only while an admin page reading them is open).
-- These five tables were in no realtime publication, so the push history,
-- EV orders, help articles and questions, and the Fare AI response log could
-- only be refreshed by hand. Row-level security still decides who receives
-- a row: each table is readable by admins (and ev_orders / help_questions
-- by the owning account).
--
-- Idempotent: a table already in the publication, or missing from this
-- database, is skipped.
do $$
declare
  t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array[
    'push_notifications', 'ev_orders', 'help_articles', 'help_questions', 'fare_ai_responses'
  ] loop
    if to_regclass('public.' || t) is not null and not exists (
      select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end
$$;
