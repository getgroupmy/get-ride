-- ============================================================================
-- Regression test for migration 0227: realtime publishes only the tables an
-- app listens to, the region lists' boundary marks are stored columns that
-- follow the geofence, the eleven foreign keys have an index, and anonymous
-- requests are cut within 8 s. (The policy rewrite is checked in
-- rls_initplan.sql.)
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/perf_cheap_0227.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;

create or replace function pg_temp.published(p_table text) returns boolean language sql as $$
  select exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = p_table)
$$;

-- 1. Realtime ---------------------------------------------------------------------
select pg_temp.check(not pg_temp.published(t), t || ' is out of supabase_realtime (nobody subscribes)')
  from unnest(array['user_location_history', 'notification_outbox', 'wallet_transactions',
                    'vehicle_active_session', 'emergency_contacts', 'vehicles', 'auth_rate_hits']) as t;

-- What the app does follow stays: rides, chat, calls, settings, own rows, admin lists.
select pg_temp.check(pg_temp.published(t), t || ' is still in supabase_realtime')
  from unnest(array['ride_requests', 'ride_messages', 'ride_calls', 'ride_call_signals',
                    'support_calls', 'support_call_signals', 'support_messages', 'active_sessions',
                    'user_notifications', 'wallet_transfer_requests', 'voice_protection_recordings',
                    'app_branding', 'wallets', 'countries', 'states', 'cities', 'suburbs',
                    'settings_entries', 'sms_log', 'profiles', 'partners',  -- messaging_devices: out since 0229
                    'user_sessions', 'ev_orders', 'safety_incidents', 'trip_handovers']) as t;

-- 2. Boundary marks ---------------------------------------------------------------
select pg_temp.check(
  (select count(*) from information_schema.columns
    where table_schema = 'public'
      and table_name in ('countries', 'states', 'cities', 'suburbs')
      and column_name in ('geofence_source', 'geofence_updated_at')
      and is_generated = 'ALWAYS' and data_type = 'text') = 8,
  'each region table has geofence_source and geofence_updated_at, generated');

insert into public.countries (name, geofence) values
  ('Perfland 227', '{"boundary": "{}", "source": "osm", "updatedAt": "2026-10-18T00:00:00Z"}');
insert into public.states (country, name, geofence) values ('Perfland 227', 'Plain 227', null);

select pg_temp.check(
  (select geofence_source = 'osm' and geofence_updated_at = '2026-10-18T00:00:00Z'
     from public.countries where name = 'Perfland 227'),
  'the marks are read from the geofence');
select pg_temp.check(
  (select geofence_source is null and geofence_updated_at is null
     from public.states where name = 'Plain 227'),
  'no geofence, no marks');

update public.countries set geofence = '{"boundary": "{}", "source": "manual"}' where name = 'Perfland 227';
select pg_temp.check(
  (select geofence_source = 'manual' and geofence_updated_at is null
     from public.countries where name = 'Perfland 227'),
  'the marks follow a changed geofence');

update public.countries set geofence = null where name = 'Perfland 227';
select pg_temp.check(
  (select geofence_source is null from public.countries where name = 'Perfland 227'),
  'a cleared geofence clears the marks');

-- 3. Foreign key indexes ------------------------------------------------------------
select pg_temp.check(to_regclass('public.' || i) is not null, i || ' exists')
  from unnest(array['safety_incidents_ride_id_idx', 'scheduled_rides_ride_id_idx',
                    'scheduled_ride_offers_rider_id_idx', 'scheduled_ride_offers_from_id_idx',
                    'trip_handovers_rider_id_idx', 'trip_handovers_from_partner_id_idx',
                    'trip_handovers_to_partner_id_idx', 'gateway_pairings_created_by_idx',
                    'gateway_pairings_device_row_idx', 'gateway_keys_paired_by_idx',
                    'ev_profiles_updated_by_idx']) as i;

-- 4. Anonymous statement timeout ---------------------------------------------------
do $$
declare
  v_current text;
  v_ms bigint;
begin
  select split_part(cfg, '=', 2) into v_current
    from pg_db_role_setting s
    cross join lateral unnest(s.setconfig) as cfg
   where s.setrole = 'anon'::regrole and s.setdatabase = 0
     and cfg like 'statement_timeout=%';
  perform pg_temp.check(v_current is not null, 'anon has a statement timeout');
  perform set_config('statement_timeout', v_current, true);
  v_ms := (select ps.setting::bigint from pg_settings ps where ps.name = 'statement_timeout');
  perform set_config('statement_timeout', '0', true);
  perform pg_temp.check(v_ms between 1 and 8000, format('anon times out within 8 s (%s)', v_current));
end
$$;

select 'perf_cheap_0227: all passed';
rollback;
