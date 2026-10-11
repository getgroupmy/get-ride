-- ============================================================================
-- Regression test for migration 0143: credential rows in app_settings are
-- readable by admins only.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/app_settings_secrets.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000143a1'),  -- admin
  ('00000000-0000-0000-0000-0000000143b1')   -- rider
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000143%'
on conflict do nothing;
insert into public.admin_access (profile_id, page) values ('00000000-0000-0000-0000-0000000143a1', 'admin-settings-api-keys')
on conflict do nothing;

insert into public.app_settings (key, value) values
  ('api_providers', '[{"name":"Google","services":[{"name":"Places","keys":[{"value":"test-key"}]}]}]'),
  ('fare_ai_provider', '{"keys":["test"]}'),
  ('elife_api_connection', '{"clientSecret":"test"}'),
  ('app', '{"name":"GET.ride"}')
on conflict (key) do nothing;

create or replace function pg_temp.visible(p_claims text) returns text language plpgsql as $$
declare
  out text;
begin
  perform set_config('request.jwt.claims', p_claims, true);
  select string_agg(key, ',' order by key) into out from public.app_settings
   where key in ('api_providers', 'fare_ai_provider', 'elife_api_connection', 'app');
  return coalesce(out, '');
end $$;
grant execute on function pg_temp.visible(text) to anon, authenticated;

set local role anon;
do $$ begin
  if pg_temp.visible('{"role":"anon"}') <> 'app' then
    raise exception 'FAILED: anon sees %', pg_temp.visible('{"role":"anon"}');
  end if;
end $$;
reset role;

set local role authenticated;
do $$ begin
  if pg_temp.visible('{"role":"authenticated","sub":"00000000-0000-0000-0000-0000000143b1"}') <> 'app' then
    raise exception 'FAILED: a rider sees credential rows';
  end if;
  if pg_temp.visible('{"role":"authenticated","sub":"00000000-0000-0000-0000-0000000143a1"}')
     <> 'api_providers,app,elife_api_connection,fare_ai_provider' then
    raise exception 'FAILED: an admin lost access: %',
      pg_temp.visible('{"role":"authenticated","sub":"00000000-0000-0000-0000-0000000143a1"}');
  end if;
end $$;
reset role;

select 'app_settings_secrets: all passed';
rollback;
