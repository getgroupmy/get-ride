-- Live admin settings: the apps re-read a settings table the moment an admin
-- changes it (Flutter `lib/src/data/live_tables.dart`, Expo's
-- DisplaySettingsContext pattern). That needs each table in the
-- `supabase_realtime` publication; these five settings tables were not.
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
    'get_coin_settings', 'commission_rates', 'ip_access_rules', 'airport_areas', 'multi_gate'
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
