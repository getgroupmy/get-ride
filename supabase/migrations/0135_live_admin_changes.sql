-- Every admin change reaches running apps live (Flutter
-- lib/src/data/live_tables.dart): the booking fare tariffs (0109) and the
-- GET.coin rate history were never added to the `supabase_realtime`
-- publication, so the app could only pick them up on its next launch.
--
-- The account's own rows an admin decides on (profiles, partners, documents,
-- vehicles) and the other settings tables the app now follows are already
-- in it (0097, 0102).
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
  foreach t in array array['fare_tariffs', 'get_coin_rate_history'] loop
    if to_regclass('public.' || t) is not null and not exists (
      select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end
$$;
